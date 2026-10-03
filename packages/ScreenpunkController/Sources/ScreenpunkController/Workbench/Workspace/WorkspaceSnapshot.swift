import Foundation
import CryptoKit
#if os(macOS)
import Darwin

public struct WorkspaceSnapshotResult: Sendable {
    public let path: String
    public let workspaceId: String
    public let generation: Int
    public let fileCount: Int
    public let includedBytes: Int64
    public let complete: Bool
    public let excludedExternalProjectIds: [String]
    public let unregisteredScreenPaths: [String]
    public let omittedAuxiliaryPaths: [String]
}

private struct SnapshotFileRecord: Codable {
    let path: String
    let bytes: Int64
    let sha256: String
}
private struct SnapshotChunkRecord: Codable {
    let path: String
    let sha256: String
    let count: Int
}
private struct SnapshotManifest: Codable {
    let schemaVersion: Int
    let workspaceId: String
    let generation: Int
    let createdAt: String
    let scope: String
    let complete: Bool
    let includedBytes: Int64
    let excludedExternalProjectIds: [String]
    let unregisteredScreenPaths: [String]
    let omittedAuxiliaryPaths: [String]
    let chunks: [SnapshotChunkRecord]
}

/// One quiesced, descriptor-anchored export attempt. The caller must drain its own
/// writers; the root lock serializes WorkspaceFiles writers, while source hashes
/// before and after copying detect ordinary editors that do not take that lock.
public final class WorkspaceSnapshot {
    private let workspace: WorkspaceStore
    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func create(at destination: String, includeExternal: Bool = false,
                       allowIncomplete: Bool = false, timeout: TimeInterval = 300,
                       cancelled: @escaping () -> Bool = { false },
                       progress: @escaping (WorkspaceCopyProgress) -> Void = { _ in })
        throws -> WorkspaceSnapshotResult {
        guard WorkspaceValidation.absolute(destination), timeout > 0, timeout <= 3_600,
              let overview = try workspace.current() else { throw WorkspaceError.invalidPath }
        let sourcePath = overview.path
        let sourceKey = WorkspaceValidation.portableKey(sourcePath)
        let outputKey = WorkspaceValidation.portableKey(destination)
        guard outputKey != sourceKey, !outputKey.hasPrefix(sourceKey + "/"),
              !sourceKey.hasPrefix(outputKey + "/") else { throw WorkspaceError.invalidPath }
        let budget = WorkspaceReadBudget(deadline: ProcessInfo.processInfo.systemUptime + timeout,
                                         cancelled: cancelled)
        let source = try WorkspaceFiles(path: sourcePath)
        let parentPath = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        guard WorkspaceValidation.member(name), !name.contains("/"),
              WorkspaceValidation.absolute(parentPath) else { throw WorkspaceError.invalidPath }
        let parent = try WorkspaceFiles(path: parentPath, requiredPrivateRoot: false)
        return try source.locked(readBudget: budget) {
            try budget.check()
            guard try source.emptyDirectory(["Workbench", "Transactions"]),
                  !(try parent.exists(parent.fd, name)) else { throw WorkspaceError.conflict }
            let currentDescriptor = try source.read(source.fd, "workspace.json", readBudget: budget)
            let catalogFD = try source.directory(["Workbench", "Library"]); defer { close(catalogFD) }
            let currentCatalog = try source.read(catalogFD, "catalog.json", readBudget: budget)
            guard (try WorkspaceJSON.decode(WorkspaceDescriptor.self, from: currentDescriptor, shape: .descriptor)) == overview.descriptor,
                  (try WorkspaceJSON.decode(WorkspaceCatalog.self, from: currentCatalog, shape: .catalog)) == overview.catalog
            else { throw WorkspaceError.conflict }
            let stageName = ".screenpunk-snapshot-" + UUID().uuidString.lowercased()
            guard mkdirat(parent.fd, stageName, 0o700) == 0, fsync(parent.fd) == 0 else {
                throw WorkspaceError.unavailable
            }
            let stage = try WorkspaceFiles(path: parentPath + "/" + stageName)
            var published = false
            defer { if !published { try? removeOwnedStage(parent: parent, name: stageName, stage: stage) } }
            try scaffold(stage)
            let plan = try collect(source: source, overview: overview,
                                   includeExternal: includeExternal, budget: budget)
            guard (plan.excluded.isEmpty && plan.unregisteredScreens.isEmpty) || allowIncomplete else {
                throw WorkspaceError.incomplete
            }
            let catalogBytes = try WorkspaceJSON.encode(plan.catalog)
            let totalFiles = plan.members.count + 1
            let totalBytes = plan.bytes + Int64(catalogBytes.count)
            var copiedFiles = 0, copiedBytes: Int64 = 0
            func emit(_ phase: WorkspaceCopyProgress.Phase) {
                progress(.init(phase: phase, copiedFiles: copiedFiles,
                    totalFiles: totalFiles, copiedBytes: copiedBytes, totalBytes: totalBytes))
            }
            try requireSpace(parent.fd, bytes: totalBytes)
            var records: [SnapshotFileRecord] = []
            records.reserveCapacity(plan.members.count + 1)
            emit(.copying)
            for member in plan.members {
                try budget.check()
                let hash = try copy(member: member, to: stage, budget: budget)
                records.append(.init(path: member.output.joined(separator: "/"), bytes: member.bytes, sha256: hash))
                copiedFiles += 1; copiedBytes += member.bytes
                emit(.copying)
            }
            let library = try stage.directory(["Workbench", "Library"]); defer { close(library) }
            try stage.write(library, "catalog.json", data: catalogBytes, expected: nil)
            records.append(.init(path: "Workbench/Library/catalog.json", bytes: Int64(catalogBytes.count),
                                 sha256: WorkbenchTransactionDigest.hex(catalogBytes)))
            copiedFiles += 1; copiedBytes += Int64(catalogBytes.count)
            emit(.copying)
            emit(.verifying)
            for (index, member) in plan.members.enumerated() {
                try budget.check()
                guard try hash(member: member, budget: budget) == records[index].sha256,
                      try hash(root: stage, parts: member.output, budget: budget) == records[index].sha256
                else { throw WorkspaceError.conflict }
            }
            for (projectID, destination) in plan.projectDestinations {
                try budget.check()
                let folder = try stage.directory(destination); defer { close(folder) }
                let document = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
                    from: stage.read(folder, "screenpunk.project.json", readBudget: budget), shape: .project)
                let inventory = try stage.inventory(destination, readBudget: budget,
                    required: ["screenpunk.project.json", document.screenConfig, document.entry])
                var files: [String: Data] = [:]
                for member in inventory.includedFiles {
                    let parts = member.split(separator: "/").map(String.init)
                    let parent = try stage.directory(destination + Array(parts.dropLast()))
                    defer { close(parent) }
                    files[member] = try stage.read(parent, parts.last!, maxBytes: 5 * 1024 * 1024,
                                                   readBudget: budget)
                }
                guard try WorkbenchSourceHasher.hash(files) == plan.sourceVersions[projectID] else {
                    throw WorkspaceError.conflict
                }
            }
            guard try source.read(source.fd, "workspace.json", readBudget: budget) == currentDescriptor,
                  try source.read(catalogFD, "catalog.json", readBudget: budget) == currentCatalog,
                  try unregisteredScreens(source, catalog: overview.catalog, budget: budget) == plan.unregisteredScreens,
                  try source.emptyDirectory(["Workbench", "Transactions"]) else { throw WorkspaceError.conflict }
            let checked = try workspace.inspect(at: stage.path)
            guard checked.descriptor.workspaceId == overview.descriptor.workspaceId,
                  checked.descriptor.generation == overview.descriptor.generation,
                  checked.catalog == plan.catalog else { throw WorkspaceError.conflict }
            let chunks = try writeInventory(records: records, stage: stage, budget: budget)
            let manifest = SnapshotManifest(schemaVersion: 1, workspaceId: overview.descriptor.workspaceId,
                generation: overview.descriptor.generation,
                createdAt: ISO8601DateFormatter().string(from: Date()), scope: "authoring",
                complete: plan.excluded.isEmpty && plan.unregisteredScreens.isEmpty,
                includedBytes: plan.bytes + Int64(catalogBytes.count),
                excludedExternalProjectIds: plan.excluded,
                unregisteredScreenPaths: plan.unregisteredScreens,
                omittedAuxiliaryPaths: plan.omitted, chunks: chunks)
            let workbench = try stage.directory(["Workbench"]); defer { close(workbench) }
            try stage.write(workbench, "snapshot-manifest.json", data: WorkspaceJSON.encode(manifest), expected: nil)
            try budget.check()
            try source.verifyRoot()
            emit(.publishing)
            guard renameatx_np(parent.fd, stageName, parent.fd, name, UInt32(RENAME_EXCL)) == 0,
                  fsync(parent.fd) == 0 else { throw WorkspaceError.unavailable }
            published = true
            emit(.complete)
            return WorkspaceSnapshotResult(path: destination, workspaceId: overview.descriptor.workspaceId,
                generation: overview.descriptor.generation, fileCount: records.count,
                includedBytes: manifest.includedBytes, complete: manifest.complete,
                excludedExternalProjectIds: plan.excluded,
                unregisteredScreenPaths: plan.unregisteredScreens,
                omittedAuxiliaryPaths: plan.omitted)
        }
    }

    private struct Member {
        let source: WorkspaceFiles
        let input: [String]
        let output: [String]
        let bytes: Int64
    }
    private struct Plan {
        let members: [Member]
        let catalog: WorkspaceCatalog
        let excluded: [String]
        let unregisteredScreens: [String]
        let omitted: [String]
        let bytes: Int64
        let sourceVersions: [String: String]
        let projectDestinations: [String: [String]]
    }

    private func collect(source: WorkspaceFiles, overview: WorkspaceOverview,
                         includeExternal: Bool, budget: WorkspaceReadBudget) throws -> Plan {
        var members: [Member] = [], omitted = overview.coverage.omittedAuxiliaryPaths
        omitted += try unselected(source, [], allowed: ["workspace.json", "Screens", "Workbench", ".screenpunk.lock"], budget: budget)
        omitted += try unselected(source, ["Workbench"], allowed: ["Library", "Settings", "History", "Attachments", "Toolchains", "Transactions", "Migrations", "snapshot-manifest.json", "SnapshotInventories"], budget: budget)
        omitted += try unselected(source, ["Workbench", "Library"], allowed: ["catalog.json", "BuildHeads"], budget: budget)
        omitted += try unselected(source, ["Workbench", "Settings"], allowed: ["workbench.json", "connections.json"], budget: budget)
        omitted += try unselected(source, ["Workbench", "Toolchains"], allowed: ["requirements.json"], budget: budget)
        let unregistered = try unregisteredScreens(source, catalog: overview.catalog, budget: budget)
        omitted += unregistered
        var excluded: [String] = [], projects: [WorkspaceProject] = []
        var sourceVersions: [String: String] = [:], projectDestinations: [String: [String]] = [:]
        var total: Int64 = 0
        var collisions = WorkspacePathCollisionDetector()
        func add(_ anchor: WorkspaceFiles, _ input: [String], _ output: [String]) throws {
            try budget.check()
            let path = output.joined(separator: "/")
            guard output.count <= 32, path.utf8.count <= 4096,
                  members.count < 1_000_000 else { throw WorkspaceError.limitExceeded }
            try collisions.insert(path)
            let parent = try anchor.directory(Array(input.dropLast())); defer { close(parent) }
            let info = try anchor.metadata(parent, input.last!)
            guard info.st_size >= 0, info.st_size <= Int64.max - total,
                  total + info.st_size <= 64 * 1024 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
            total += info.st_size
            members.append(.init(source: anchor, input: input, output: output, bytes: info.st_size))
        }
        try add(source, ["workspace.json"], ["workspace.json"])
        for path in ["Workbench/Settings/workbench.json", "Workbench/Settings/connections.json",
                     "Workbench/Toolchains/requirements.json"] {
            let parts = path.split(separator: "/").map(String.init)
            try add(source, parts, parts)
        }
        for path in ["Workbench/History", "Workbench/Attachments", "Workbench/Migrations",
                     "Workbench/Library/BuildHeads"] {
            let parts = path.split(separator: "/").map(String.init)
            if try existsDirectory(source, parts) {
                try collectTree(source, parts, budget: budget, add: add)
            }
        }
        let bindings = try workspace.selection.current(readBudget: budget)?.externalBindings ?? [:]
        for project in overview.catalog.projects {
            try budget.check()
            let anchor: WorkspaceFiles
            let destination: [String]
            if let relative = project.location.path {
                anchor = source; destination = relative.split(separator: "/").map(String.init)
                projects.append(project)
            } else if includeExternal, let reference = project.location.referenceId,
                      let binding = bindings[reference] {
                anchor = try WorkspaceFiles(path: binding.path, requiredPrivateRoot: false)
                guard anchor.identity.device == binding.device, anchor.identity.inode == binding.inode else {
                    throw WorkspaceError.conflict
                }
                destination = ["Screens", "external-" + project.projectId]
                projects.append(WorkspaceProject(projectId: project.projectId,
                    dashboardId: project.dashboardId, name: project.name,
                    location: .contained(destination.joined(separator: "/")),
                    collectionIds: project.collectionIds, sortOrder: project.sortOrder))
            } else if includeExternal {
                throw WorkspaceError.unavailable
            } else {
                excluded.append(project.projectId); projects.append(project); continue
            }
            let origin = project.location.path == nil ? [] : destination
            let folder = try anchor.directory(origin); defer { close(folder) }
            let document = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
                from: anchor.read(folder, "screenpunk.project.json", readBudget: budget), shape: .project)
            try document.validate(matching: project)
            let inventory = try anchor.inventory(origin, readBudget: budget,
                required: ["screenpunk.project.json", document.screenConfig, document.entry])
            omitted += inventory.omitted.map { (project.location.path ?? "external:" + project.projectId) + "/" + $0 }
            var sourceFiles: [String: Data] = [:]
            for member in inventory.includedFiles.sorted() {
                let parts = member.split(separator: "/").map(String.init)
                try add(anchor, origin + parts, destination + parts)
                let parent = try anchor.directory(origin + Array(parts.dropLast()))
                defer { close(parent) }
                sourceFiles[member] = try anchor.read(parent, parts.last!, maxBytes: 5 * 1024 * 1024,
                                                       readBudget: budget)
            }
            sourceVersions[project.projectId] = try WorkbenchSourceHasher.hash(sourceFiles)
            projectDestinations[project.projectId] = destination
        }
        guard members.count < 1_000_000 else { throw WorkspaceError.limitExceeded }
        return Plan(members: members,
                    catalog: WorkspaceCatalog(generation: overview.catalog.generation,
                        projects: projects,
                        archivedDashboardIds: overview.catalog.archivedDashboardIds),
                    excluded: excluded.sorted(), unregisteredScreens: unregistered,
                    omitted: Array(Set(omitted)).sorted(), bytes: total,
                    sourceVersions: sourceVersions, projectDestinations: projectDestinations)
    }

    private func unregisteredScreens(_ root: WorkspaceFiles, catalog: WorkspaceCatalog,
                                     budget: WorkspaceReadBudget) throws -> [String] {
        let names = try unselected(root, ["Screens"], allowed: [], budget: budget)
        let screens = try root.directory(["Screens"]); defer { close(screens) }
        // Compare filesystem identity, not spelling alone. A case-only rename
        // resolves to the registered inode on a case-insensitive volume, while
        // two distinct case-variant folders remain distinct on other volumes.
        func key(_ info: stat) -> String { "\(UInt64(info.st_dev)):\(info.st_ino)" }
        var registered = Set<String>()
        for project in catalog.projects {
            try budget.check()
            guard let path = project.location.path else { continue }
            let name = String(path.dropFirst("Screens/".count))
            let node = try { () throws -> String in
                let directory = try root.directory(["Screens", name]); defer { close(directory) }
                var info = stat()
                guard fstat(directory, &info) == 0 else { throw WorkspaceError.unavailable }
                return key(info)
            }()
            registered.insert(node)
        }
        var unknown: [String] = []
        for path in names {
            try budget.check()
            let name = String(path.dropFirst("Screens/".count))
            var info = stat()
            guard fstatat(screens, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw WorkspaceError.unavailable
            }
            if info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) || !registered.contains(key(info)) {
                unknown.append(path)
            }
        }
        return unknown.sorted()
    }

    private func scaffold(_ stage: WorkspaceFiles) throws {
        for path in ["Screens", "Workbench/Library", "Workbench/Settings", "Workbench/History/Builds",
                     "Workbench/History/Packages", "Workbench/History/Prepared",
                     "Workbench/History/Deployments", "Workbench/Attachments", "Workbench/Toolchains",
                     "Workbench/Transactions", "Workbench/Migrations"] {
            let fd = try stage.directory(path.split(separator: "/").map(String.init), create: true)
            close(fd)
        }
    }
    private func unselected(_ root: WorkspaceFiles, _ parts: [String], allowed: Set<String>,
                            budget: WorkspaceReadBudget) throws -> [String] {
        let directory = try root.directory(parts); defer { close(directory) }
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try budget.check()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name == "." || name == ".." { continue }
            guard names.count < 1_000_000, WorkspaceValidation.member(name), !name.contains("/") else {
                throw WorkspaceError.limitExceeded
            }
            if !allowed.contains(name) { names.append((parts + [name]).joined(separator: "/")) }
        }
        return names
    }
    private func existsDirectory(_ root: WorkspaceFiles, _ parts: [String]) throws -> Bool {
        let parent = try root.directory(Array(parts.dropLast())); defer { close(parent) }
        guard try root.exists(parent, parts.last!) else { return false }
        let fd = try root.directory(parts); close(fd); return true
    }
    private func collectTree(_ root: WorkspaceFiles, _ parts: [String], budget: WorkspaceReadBudget,
                             add: (WorkspaceFiles, [String], [String]) throws -> Void) throws {
        try budget.check()
        let directory = try root.directory(parts); defer { close(directory) }
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try budget.check()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name == "." || name == ".." { continue }
            guard WorkspaceValidation.member(name), !name.contains("/"), names.count < 1_000_000 else {
                throw WorkspaceError.limitExceeded
            }
            names.append(name)
        }
        var spelling = WorkspacePathCollisionDetector()
        for name in names.sorted() {
            try spelling.insert(name)
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
                  info.st_mode & 0o7000 == 0 else { throw WorkspaceError.unsafeFile }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                try collectTree(root, parts + [name], budget: budget, add: add)
            } else if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 {
                try add(root, parts + [name], parts + [name])
            } else { throw WorkspaceError.unsafeFile }
        }
    }

    private func copy(member: Member, to stage: WorkspaceFiles, budget: WorkspaceReadBudget) throws -> String {
        let parent = try stage.directory(Array(member.output.dropLast()), create: true)
        defer { close(parent) }
        let file = openat(parent, member.output.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw WorkspaceError.conflict }
        defer { close(file) }
        let digest = try stream(member: member, destination: file, budget: budget)
        guard fsync(file) == 0, fsync(parent) == 0 else { throw WorkspaceError.unavailable }
        return digest
    }
    private func hash(member: Member, budget: WorkspaceReadBudget) throws -> String {
        try stream(member: member, destination: nil, budget: budget)
    }
    private func hash(root: WorkspaceFiles, parts: [String], budget: WorkspaceReadBudget) throws -> String {
        let parent = try root.directory(Array(parts.dropLast())); defer { close(parent) }
        let info = try root.metadata(parent, parts.last!)
        return try stream(member: .init(source: root, input: parts, output: parts, bytes: info.st_size),
                          destination: nil, budget: budget)
    }
    private func stream(member: Member, destination: Int32?, budget: WorkspaceReadBudget) throws -> String {
        let parent = try member.source.directory(Array(member.input.dropLast())); defer { close(parent) }
        let before = try member.source.metadata(parent, member.input.last!)
        guard before.st_size == member.bytes else { throw WorkspaceError.conflict }
        let input = openat(parent, member.input.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw WorkspaceError.unsafeFile }
        defer { close(input) }
        try budget.requireLocal(input)
        var opened = stat()
        guard fstat(input, &opened) == 0, WorkspaceNodeID(opened) == WorkspaceNodeID(before) else {
            throw WorkspaceError.conflict
        }
        var digest = SHA256(), consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try budget.check()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw WorkspaceError.unavailable }
            if count == 0 { break }
            guard Int64(count) <= member.bytes - consumed else { throw WorkspaceError.conflict }
            consumed += Int64(count)
            digest.update(data: Data(buffer.prefix(count)))
            if let destination {
                var offset = 0
                while offset < count {
                    try budget.check()
                    let written = buffer.withUnsafeBytes { raw in
                        Darwin.write(destination, raw.baseAddress!.advanced(by: offset), count - offset)
                    }
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw WorkspaceError.unavailable }
                    offset += written
                }
            }
        }
        var after = stat()
        guard consumed == member.bytes, fstat(input, &after) == 0,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              WorkspaceNodeID(try member.source.metadata(parent, member.input.last!)) == WorkspaceNodeID(before)
        else { throw WorkspaceError.conflict }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func requireSpace(_ fd: Int32, bytes: Int64) throws {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { throw WorkspaceError.unavailable }
        let available = Double(info.f_bavail) * Double(info.f_bsize)
        guard available >= Double(bytes) * 1.1 else { throw WorkspaceError.limitExceeded }
    }
    private func writeInventory(records: [SnapshotFileRecord], stage: WorkspaceFiles,
                                budget: WorkspaceReadBudget) throws -> [SnapshotChunkRecord] {
        let id = UUID().uuidString.lowercased()
        let directory = try stage.directory(["Workbench", "SnapshotInventories", id], create: true)
        defer { close(directory) }
        var chunks: [SnapshotChunkRecord] = []
        for start in stride(from: 0, to: records.count, by: 2_000) {
            try budget.check()
            let slice = Array(records[start..<min(records.count, start + 2_000)])
            let bytes = try WorkspaceJSON.encode(slice)
            let path = "Workbench/SnapshotInventories/\(id)/\(chunks.count).json"
            guard bytes.count <= 8 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
            try stage.write(directory, "\(chunks.count).json", data: bytes, expected: nil)
            chunks.append(.init(path: path, sha256: WorkbenchTransactionDigest.hex(bytes), count: slice.count))
        }
        return chunks
    }
    private func removeOwnedStage(parent: WorkspaceFiles, name: String, stage: WorkspaceFiles) throws {
        let opened = try parent.directory([name]); defer { close(opened) }
        var info = stat()
        guard fstat(opened, &info) == 0, WorkspaceNodeID(info) == stage.identity else {
            throw WorkspaceError.conflict
        }
        try removeChildren(opened, depth: 0)
        guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else { throw WorkspaceError.unavailable }
    }
    private func removeChildren(_ directory: Int32, depth: Int) throws {
        guard depth <= 32 else { throw WorkspaceError.limitExceeded }
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name == "." || name == ".." { continue }
            guard WorkspaceValidation.member(name), !name.contains("/") else { throw WorkspaceError.unsafeFile }
            names.append(name)
            guard names.count <= 1_000_000 else { throw WorkspaceError.limitExceeded }
        }
        for name in names {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw WorkspaceError.unsafeFile }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw WorkspaceError.unsafeFile }
                do { defer { close(child) }; try removeChildren(child, depth: depth + 1) }
                guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw WorkspaceError.unavailable }
            } else {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
                      unlinkat(directory, name, 0) == 0 else { throw WorkspaceError.unsafeFile }
            }
        }
    }
}
#endif
