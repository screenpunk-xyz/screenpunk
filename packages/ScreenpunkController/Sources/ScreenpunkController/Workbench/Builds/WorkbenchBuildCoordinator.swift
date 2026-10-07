import Foundation
import Darwin
import ScreenpunkCore

struct WorkbenchBuildHead: Codable, Equatable {
    let schemaVersion: Int
    let projectID: String
    let dashboardID: String
    let sourceVersion: String
    let revision: String
    let digest: String
    let selectedToolchain: WorkspaceToolchainRequirements.Requirement?
}

struct WorkbenchBuildResult {
    let head: WorkbenchBuildHead
    let diagnostics: String
}

/// Builds a frozen included-source snapshot, validates every package byte, publishes the
/// immutable package through the contained transaction engine, then CASes the visible head
/// against both live source and the previous head under the workspace lock.
enum WorkbenchBuildConflict: Error {
    case sourceVersion, baseRevision
}

final class WorkbenchBuildCoordinator {
    typealias ReactCompiler = (_ projectID: String, _ sourceVersion: String,
                               _ requirement: WorkspaceToolchainRequirements.Requirement,
                               _ plan: OfflineBuildInputPlan, _ output: String,
                               _ cancelled: @escaping () -> Bool) throws -> String

    private let workspace: WorkspaceStore
    private let compiler: ReactCompiler
    private let checkpoint: ((WorkbenchTransactionCheckpoint) throws -> Void)?
    init(workspace: WorkspaceStore, compiler: @escaping ReactCompiler,
         checkpoint: ((WorkbenchTransactionCheckpoint) throws -> Void)? = nil) {
        self.workspace = workspace; self.compiler = compiler; self.checkpoint = checkpoint
    }
    convenience init(workspace: WorkspaceStore, host: WorkbenchBuildHostAdapter) {
        self.init(workspace: workspace) { project, version, requirement, plan, output, cancelled in
            try host.build(projectID: project, sourceVersion: version, requirement: requirement,
                           inputs: plan, stagingPath: output, cancelled: cancelled).diagnostics
        }
    }

    func build(projectID: String, expectedSourceVersion: String, baseRevision: String?,
               cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchBuildResult {
        guard WorkspaceValidation.id(projectID), WorkspaceValidation.sha256(expectedSourceVersion),
              baseRevision == nil || WorkspaceValidation.id(baseRevision!) else {
            throw WorkspaceError.invalidSchema
        }
        let snapshot = try capture(projectID: projectID, cancelled: cancelled)
        guard snapshot.version == expectedSourceVersion else { throw WorkbenchBuildConflict.sourceVersion }
        let work = URL(fileURLWithPath: "/private/tmp/screenpunk-workbench-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let output = work.appendingPathComponent("output")
        let diagnostics: String
        let packageFiles: [String: Data]
        let selectedToolchain: WorkspaceToolchainRequirements.Requirement?
        if snapshot.document.kind == "react" {
            let requirement = try selectedRequirement(snapshot: snapshot)
            selectedToolchain = requirement
            let inputRoot = work.appendingPathComponent("source")
            try materializeReact(snapshot.files, at: inputRoot)
            let plan = try OfflineBuildInputPlan.capture(inputRoot,
                deadline: ProcessInfo.processInfo.systemUptime + 120, cancelled: cancelled)
            guard plan.files.allSatisfy({ snapshot.files[$0.relativePath] == $0.bytes }) else {
                throw WorkspaceError.conflict
            }
            diagnostics = try compiler(projectID, snapshot.version, requirement, plan, output.path, cancelled)
            packageFiles = try captureOutput(output, cancelled: cancelled)
        } else {
            selectedToolchain = nil
            diagnostics = ""
            packageFiles = try plainWebFiles(snapshot.files)
        }
        let package = try makePackage(snapshot: snapshot, files: packageFiles)
        if cancelled() { throw WorkspaceError.unavailable }
        let manifest = package.manifest
        let proposed = WorkbenchBuildHead(schemaVersion: 1, projectID: projectID,
            dashboardID: snapshot.project.dashboardId, sourceVersion: snapshot.version,
            revision: manifest.revision, digest: manifest.digest!, selectedToolchain: selectedToolchain)
        try publishPackageHead(package, proposed: proposed,
                               baseRevision: baseRevision, cancelled: cancelled)
        guard try readHead(projectID: projectID)?.0 == proposed else { throw WorkspaceError.conflict }
        return WorkbenchBuildResult(head: proposed, diagnostics: diagnostics)
    }

    func readHead(projectID: String) throws -> (WorkbenchBuildHead, WorkbenchPortablePackage)? {
        guard WorkspaceValidation.id(projectID), let overview = try workspace.current() else {
            throw WorkspaceError.unavailable
        }
        let root = try WorkspaceFiles(path: overview.path)
        let library = try root.directory(["Workbench", "Library"]); defer { close(library) }
        guard try root.exists(library, "BuildHeads") else { return nil }
        let heads = try root.directory(["Workbench", "Library", "BuildHeads"])
        defer { close(heads) }
        guard try root.exists(heads, projectID + ".json") else { return nil }
        let head = try JSONDecoder().decode(WorkbenchBuildHead.self,
            from: root.read(heads, projectID + ".json", maxBytes: 4096))
        guard head.schemaVersion == 1, head.projectID == projectID,
              WorkspaceValidation.id(head.dashboardID), WorkspaceValidation.sha256(head.sourceVersion),
              WorkspaceValidation.id(head.revision), WorkspaceValidation.sha256(head.digest) else {
            throw WorkspaceError.invalidSchema
        }
        guard overview.catalog.projects.first(where: { $0.projectId == projectID })?.dashboardId == head.dashboardID,
              try WorkbenchContainedAuthoring(workspace: workspace).versions(projectID)
                .contains(where: { $0.sourceVersion == head.sourceVersion && $0.dashboardId == head.dashboardID })
        else { throw WorkspaceError.conflict }
        let package = try WorkbenchPortablePackages(workspace: workspace)
            .get(dashboardId: head.dashboardID, revision: head.revision)
        guard package.manifest.dashboardId == head.dashboardID,
              package.manifest.digest == head.digest else { throw WorkspaceError.conflict }
        return (head, package)
    }

    private struct Snapshot {
        let project: WorkspaceProject
        let document: WorkspaceProjectDocument
        let files: [String: Data]
        let version: String
        let workspacePath: String
    }

    private func capture(projectID: String, cancelled: @escaping () -> Bool) throws -> Snapshot {
        guard let overview = try workspace.current(),
              let project = overview.catalog.projects.first(where: { $0.projectId == projectID }),
              let relative = project.location.path else { throw WorkspaceError.unavailable }
        let budget = WorkspaceReadBudget(deadline: ProcessInfo.processInfo.systemUptime + 15,
                                         cancelled: cancelled)
        let root = try WorkspaceFiles(path: overview.path)
        let parts = relative.split(separator: "/").map(String.init)
        let folder = try root.directory(parts); defer { close(folder) }
        let document = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
            from: root.read(folder, "screenpunk.project.json", readBudget: budget), shape: .project)
        try document.validate(matching: project)
        let hasLock = try root.exists(folder, "screenpunk.lock.json")
        let required = ["screenpunk.project.json", document.screenConfig, document.entry] +
            (hasLock ? ["screenpunk.lock.json"] : [])
        let inventory = try root.inventory(parts, readBudget: budget, required: required)
        var files: [String: Data] = [:]
        for member in inventory.includedFiles.sorted() {
            try budget.check()
            let path = member.split(separator: "/").map(String.init)
            let parent = try root.directory(parts + Array(path.dropLast()))
            defer { close(parent) }
            files[member] = try root.read(parent, path.last!, maxBytes: 5 * 1024 * 1024,
                                          readBudget: budget)
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= 25 * 1024 * 1024 else {
            throw WorkspaceError.limitExceeded
        }
        let version = try WorkbenchSourceHasher.hash(files)
        try budget.check()
        return Snapshot(project: project, document: document, files: files,
                        version: version, workspacePath: overview.path)
    }

    private func selectedRequirement(snapshot: Snapshot) throws -> WorkspaceToolchainRequirements.Requirement {
        let root = try WorkspaceFiles(path: snapshot.workspacePath)
        let directory = try root.directory(["Workbench", "Toolchains"]); defer { close(directory) }
        let requirements = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
            from: root.read(directory, "requirements.json"), shape: .requirements)
        try requirements.validate()
        let matches = requirements.required.filter { $0.kitVersion == snapshot.document.kitVersion }
        guard matches.count == 1 else { throw ToolchainTrustError.requirementMismatch }
        return matches[0]
    }

    private func materializeReact(_ files: [String: Data], at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let extensions: Set<String> = ["ts", "tsx", "js", "jsx", "json", "css", "svg", "png",
                                       "jpg", "jpeg", "webp", "woff", "woff2"]
        for (path, bytes) in files {
            guard !["screenpunk.project.json", "screenpunk.lock.json", "screen.json",
                    ".screenpunkignore"].contains(path),
                  extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { continue }
            let destination = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try bytes.write(to: destination, options: [.atomic])
        }
    }

    private func plainWebFiles(_ files: [String: Data]) throws -> [String: Data] {
        guard files["web/index.html"] != nil else { throw WorkspaceError.invalidSchema }
        let allowed: Set<String> = ["html", "htm", "js", "css", "svg", "png", "jpg", "jpeg",
                                    "webp", "woff", "woff2", "json"]
        var output: [String: Data] = [:]
        for (path, bytes) in files where path.hasPrefix("web/") {
            let member = String(path.dropFirst(4))
            guard WorkspaceValidation.member(member),
                  allowed.contains(URL(fileURLWithPath: member).pathExtension.lowercased()) else {
                throw WorkspaceError.invalidSchema
            }
            output[member] = bytes
        }
        return output
    }

    private func captureOutput(_ url: URL, cancelled: @escaping () -> Bool) throws -> [String: Data] {
        let root = try WorkspaceFiles(path: url.path)
        var result: [String: Data] = [:]
        var total = 0
        var entries = 0
        var collisions = WorkspacePathCollisionDetector()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        func walk(_ parts: [String]) throws {
            if cancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
                throw WorkspaceError.unavailable
            }
            let fd = try root.directory(parts); defer { close(fd) }
            let copy = dup(fd)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { close(copy) }
                throw WorkspaceError.unavailable
            }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw WorkspaceError.unavailable }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                        String(validatingUTF8: $0)
                    }
                }
                guard let name else { throw WorkspaceError.unsafeFile }
                if name == "." || name == ".." { continue }
                entries += 1
                guard entries <= 4_000 else { throw WorkspaceError.limitExceeded }
                let member = (parts + [name]).joined(separator: "/")
                guard WorkspaceValidation.member(member), member.split(separator: "/").count <= 32,
                      member.utf8.count <= 512 else { throw WorkspaceError.invalidPath }
                try collisions.insert(member)
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw WorkspaceError.unsafeFile
                }
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    try walk(parts + [name])
                } else {
                    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                          result.count < 2_000 else { throw WorkspaceError.limitExceeded }
                    let bytes = try root.read(fd, name, maxBytes: 50 * 1024 * 1024)
                    guard bytes.count <= 50 * 1024 * 1024 - total else { throw WorkspaceError.limitExceeded }
                    result[member] = bytes; total += bytes.count
                }
            }
        }
        try walk([])
        return result
    }

    private func makePackage(snapshot: Snapshot, files: [String: Data]) throws -> WorkbenchPortablePackage {
        guard !files.isEmpty, files["index.html"] != nil,
              let config = snapshot.files["screen.json"] else { throw WorkspaceError.invalidSchema }
        let description = try JSONDecoder().decode(BuildScreenDescription.self, from: config)
        let inventory = files.keys.sorted().map { path in
            ManifestFile(path: path, bytes: files[path]!.count,
                         sha256: WorkbenchTransactionDigest.hex(files[path]!))
        }
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: snapshot.project.dashboardId,
            name: description.name, revision: UUID().uuidString.lowercased(), entrypoint: "index.html",
            sdkVersion: "1", target: description.target ?? BuildScreenDescription.defaultTarget,
            connections: description.connections ?? [], files: inventory,
            pages: description.pages, defaultPageId: description.defaultPageId,
            eventRules: description.eventRules, deviceBehavior: description.deviceBehavior)
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        try PackageValidator.validate(manifest)
        return WorkbenchPortablePackage(manifest: manifest, files: files)
    }

    private func publishPackageHead(_ package: WorkbenchPortablePackage,
                                    proposed: WorkbenchBuildHead, baseRevision: String?,
                                    cancelled: @escaping () -> Bool) throws {
        if cancelled() { throw WorkspaceError.unavailable }
        guard let overview = try workspace.current() else { throw WorkspaceError.unavailable }
        let root = try WorkspaceFiles(path: overview.path)
        let library = try root.directory(["Workbench", "Library"]); defer { close(library) }
        let previousBytes: Data?
        if try root.exists(library, "BuildHeads") {
            let heads = try root.directory(["Workbench", "Library", "BuildHeads"])
            defer { close(heads) }
            previousBytes = try root.exists(heads, proposed.projectID + ".json")
                ? root.read(heads, proposed.projectID + ".json", maxBytes: 4096) : nil
        } else { previousBytes = nil }
        let previous = try previousBytes.map { try JSONDecoder().decode(WorkbenchBuildHead.self, from: $0) }
        guard previous?.revision == baseRevision else { throw WorkbenchBuildConflict.baseRevision }
        let objectID = WorkbenchTransactionDigest.hex(Data((proposed.dashboardID + "\0" + proposed.revision).utf8))
        let manifestBytes = try JSONEncoder().encode(package.manifest)
        var payloads: [String: Data] = ["manifest.json": manifestBytes]
        for (path, bytes) in package.files { payloads["files/" + path] = bytes }
        let headBytes = try JSONEncoder().encode(proposed)
        var operations = payloads.keys.sorted().map { path -> WorkbenchTransactionOperation in
            let bytes = payloads[path]!
            return .init(target: .history("package", objectID, path), before: .absent,
                         after: .present(bytes), recoveryBlobHash: WorkbenchTransactionDigest.hex(bytes))
        }
        operations.append(.init(target: .buildHead(proposed.projectID),
            before: previousBytes.map(WorkbenchTransactionImage.present) ?? .absent,
            after: .present(headBytes), recoveryBlobHash: WorkbenchTransactionDigest.hex(headBytes)))
        var blobs: [String: Data] = [:]
        for bytes in Array(payloads.values) + [headBytes] {
            blobs[WorkbenchTransactionDigest.hex(bytes)] = bytes
        }
        var journal = WorkbenchTransactionJournal(schemaVersion: 2,
            transactionId: UUID().uuidString.lowercased(), workspaceId: overview.descriptor.workspaceId,
            kind: .packageHeadCommit, expectedGeneration: overview.descriptor.generation,
            operations: operations)
        journal.publication = .init(projectId: proposed.projectID, dashboardId: proposed.dashboardID,
                                    sourceVersion: proposed.sourceVersion,
                                    selectedToolchain: proposed.selectedToolchain)
        let engine = WorkbenchTransactionEngine(selection: workspace.selection, checkpoint: checkpoint)
        try engine.prepare(journal, blobs: blobs)
        try engine.commit(journal.transactionId)
    }
}

private struct BuildScreenDescription: Decodable {
    let name: String
    let target: ManifestTarget?
    let connections: [ManifestConnection]?
    let pages: [DashboardPage]?
    let defaultPageId: String?
    let eventRules: [ManifestEventRule]?
    let deviceBehavior: DeviceBehavior?
    static let defaultTarget = ManifestTarget(profileId: "fixture-phone", width: 390, height: 844,
        scale: 3, orientation: "portrait",
        safeArea: SafeAreaInsets(top: 47, right: 0, bottom: 34, left: 0))
}
