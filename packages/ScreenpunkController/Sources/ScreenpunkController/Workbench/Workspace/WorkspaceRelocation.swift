import Foundation
import CryptoKit
#if os(macOS)
import Darwin

public struct WorkspaceRelocationResult: Codable, Sendable, Equatable {
    public let path: String
    public let originalPath: String
    public let workspaceId: String
    public let generation: Int
    public let fileCount: Int
    public let copiedBytes: Int64
    public let unresolvedExternalProjectIds: [String]
}

/// Copies the complete visible root, verifies both trees, then changes only the
/// local selection. External source bytes and local bindings do not travel with it.
public final class WorkspaceRelocation {
    private let workspace: WorkspaceStore
    private struct Member: Equatable {
        let path: [String]
        let size: Int64
        let directory: Bool
        let ownerExecutable: Bool
    }
    private let maximumFiles = 1_000_000
    private let maximumBytes: Int64 = 64 * 1024 * 1024 * 1024

    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func relocate(to destination: String, timeout: TimeInterval = 300,
                         cancelled: @escaping () -> Bool = { false },
                         progress: @escaping (WorkspaceCopyProgress) -> Void = { _ in })
        throws -> WorkspaceRelocationResult {
        guard WorkspaceValidation.absolute(destination), timeout > 0, timeout <= 3_600,
              let overview = try workspace.current(),
              let selectionGeneration = overview.selectionGeneration else { throw WorkspaceError.invalidPath }
        let original = overview.path
        let sourceKey = WorkspaceValidation.portableKey(original)
        let outputKey = WorkspaceValidation.portableKey(destination)
        guard sourceKey != outputKey, !outputKey.hasPrefix(sourceKey + "/"),
              !sourceKey.hasPrefix(outputKey + "/") else { throw WorkspaceError.invalidPath }
        let budget = WorkspaceReadBudget(deadline: ProcessInfo.processInfo.systemUptime + timeout,
            cancelled: cancelled)
        let source = try WorkspaceFiles(path: original)
        let parentPath = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        guard WorkspaceValidation.absolute(parentPath), WorkspaceValidation.member(name),
              !name.contains("/") else { throw WorkspaceError.invalidPath }
        let parent = try WorkspaceFiles(path: parentPath, requiredPrivateRoot: false)
        return try source.locked(readBudget: budget) {
            try budget.check()
            try budget.requireLocal(parent.fd)
            guard try source.emptyDirectory(["Workbench", "Transactions"]),
                  !(try parent.exists(parent.fd, name)),
                  let selected = try workspace.selection.current(readBudget: budget),
                  selected.activePath == original,
                  selected.selectionGeneration == selectionGeneration,
                  selected.workspaceId == overview.descriptor.workspaceId else {
                throw WorkspaceError.conflict
            }
            let reserved = [workspace.selection.machineRootPath]
                + selected.externalBindings.values.map(\.path)
            guard reserved.allSatisfy({ path in
                let key = WorkspaceValidation.portableKey(path)
                return outputKey != key && !outputKey.hasPrefix(key + "/") &&
                    !key.hasPrefix(outputKey + "/")
            }) else { throw WorkspaceError.invalidPath }
            let members = try collect(source, budget: budget)
            let bytes = members.reduce(Int64(0)) { $0 + $1.size }
            let totalFiles = members.filter { !$0.directory }.count
            var copiedFiles = 0, copiedBytes: Int64 = 0
            func emit(_ phase: WorkspaceCopyProgress.Phase) {
                progress(.init(phase: phase, copiedFiles: copiedFiles,
                    totalFiles: totalFiles, copiedBytes: copiedBytes, totalBytes: bytes))
            }
            try requireSpace(parent.fd, bytes: bytes)
            let stageName = ".screenpunk-relocate-" + UUID().uuidString.lowercased()
            guard mkdirat(parent.fd, stageName, 0o700) == 0, fsync(parent.fd) == 0 else {
                throw WorkspaceError.unavailable
            }
            let stage = try WorkspaceFiles(path: parentPath + "/" + stageName)
            var published = false
            defer { if !published { try? removeOwnedStage(parent: parent, name: stageName, stage: stage) } }
            var hashes: [String] = []
            hashes.reserveCapacity(members.count)
            emit(.copying)
            for member in members {
                try budget.check()
                if member.directory {
                    let fd = try stage.directory(member.path, create: true)
                    close(fd)
                    hashes.append("")
                } else {
                    hashes.append(try stream(member, from: source, into: stage, budget: budget))
                    copiedFiles += 1; copiedBytes += member.size
                    emit(.copying)
                }
            }
            emit(.verifying)
            guard try collect(source, budget: budget) == members,
                  try collect(stage, budget: budget) == members else { throw WorkspaceError.conflict }
            for (index, member) in members.enumerated() {
                try budget.check()
                if member.directory { continue }
                guard try stream(member, from: source, into: nil, budget: budget) == hashes[index],
                      try stream(member, from: stage, into: nil, budget: budget) == hashes[index]
                else { throw WorkspaceError.conflict }
            }
            guard try source.emptyDirectory(["Workbench", "Transactions"]) else {
                throw WorkspaceError.conflict
            }
            let copied = try workspace.inspect(at: stage.path, readBudget: budget)
            guard copied.descriptor == overview.descriptor,
                  copied.catalog == overview.catalog,
                  copied.settings == overview.settings else {
                throw WorkspaceError.conflict
            }
            try budget.check()
            try source.verifyRoot()
            emit(.publishing)
            guard renameatx_np(parent.fd, stageName, parent.fd, name, UInt32(RENAME_EXCL)) == 0,
                  fsync(parent.fd) == 0 else { throw WorkspaceError.unavailable }
            published = true // The verified copy is retained even if selection later fails.
            let output = try WorkspaceFiles(path: destination)
            emit(.switching)
            _ = try workspace.selection.select(path: destination,
                descriptor: overview.descriptor, identity: output.identity,
                readBudget: budget, expectedSelectionGeneration: selectionGeneration,
                beforeCommit: {
                    guard try collect(source, budget: budget) == members else {
                        throw WorkspaceError.conflict
                    }
                    for (index, member) in members.enumerated() {
                        if member.directory { continue }
                        guard try stream(member, from: source, into: nil, budget: budget) == hashes[index]
                        else { throw WorkspaceError.conflict }
                    }
                })
            do {
                guard let current = try workspace.current(), current.path == destination,
                      current.descriptor == overview.descriptor else { throw WorkspaceError.conflict }
            } catch {
                throw WorkspaceAppliedMutationReadUnavailable(operation: "workspaceRelocate",
                    workspaceId: overview.descriptor.workspaceId)
            }
            emit(.complete)
            return WorkspaceRelocationResult(path: destination, originalPath: original,
                workspaceId: overview.descriptor.workspaceId,
                generation: overview.descriptor.generation,
                fileCount: members.filter { !$0.directory }.count,
                copiedBytes: bytes,
                unresolvedExternalProjectIds: overview.catalog.projects.compactMap {
                    $0.location.kind == "external" ? $0.projectId : nil
                }.sorted())
        }
    }

    private func collect(_ root: WorkspaceFiles, budget: WorkspaceReadBudget) throws -> [Member] {
        var result: [Member] = []
        var total: Int64 = 0
        var collisions = WorkspacePathCollisionDetector()
        func walk(_ path: [String]) throws {
            try budget.check()
            guard path.count <= 32 else { throw WorkspaceError.limitExceeded }
            let directory = try root.directory(path); defer { close(directory) }
            let duplicate = dup(directory)
            guard duplicate >= 0, let stream = fdopendir(duplicate) else {
                if duplicate >= 0 { close(duplicate) }; throw WorkspaceError.unavailable
            }
            defer { closedir(stream) }
            rewinddir(stream)
            var names: [String] = []
            while true {
                try budget.check()
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw WorkspaceError.unavailable }; break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self,
                        capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                            String(validatingUTF8: $0)
                        }
                }
                guard let name else { throw WorkspaceError.unsafeFile }
                if name == "." || name == ".." || (path.isEmpty && name == ".screenpunk.lock") {
                    continue
                }
                guard WorkspaceValidation.member(name), !name.contains("/"),
                      names.count < maximumFiles else { throw WorkspaceError.limitExceeded }
                names.append(name)
            }
            for name in names.sorted() {
                let child = path + [name]
                try collisions.insert(child.joined(separator: "/"))
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
                      info.st_mode & 0o7000 == 0 else { throw WorkspaceError.unsafeFile }
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    guard result.count < maximumFiles else { throw WorkspaceError.limitExceeded }
                    result.append(Member(path: child, size: 0, directory: true,
                        ownerExecutable: false))
                    try walk(child)
                } else if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 {
                    guard info.st_size >= 0, info.st_size <= maximumBytes - total,
                          result.count < maximumFiles else { throw WorkspaceError.limitExceeded }
                    total += info.st_size
                    result.append(Member(path: child, size: info.st_size, directory: false,
                        ownerExecutable: info.st_mode & 0o100 != 0))
                } else { throw WorkspaceError.unsafeFile }
            }
        }
        try walk([])
        return result
    }

    private func stream(_ member: Member, from root: WorkspaceFiles,
                        into stage: WorkspaceFiles?, budget: WorkspaceReadBudget) throws -> String {
        let parent = try root.directory(Array(member.path.dropLast())); defer { close(parent) }
        let before = try root.metadata(parent, member.path.last!)
        guard before.st_size == member.size,
              (before.st_mode & 0o100 != 0) == member.ownerExecutable else {
            throw WorkspaceError.conflict
        }
        let input = openat(parent, member.path.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw WorkspaceError.unsafeFile }
        defer { close(input) }
        try budget.requireLocal(input)
        var opened = stat()
        guard fstat(input, &opened) == 0, WorkspaceNodeID(opened) == WorkspaceNodeID(before) else {
            throw WorkspaceError.conflict
        }
        var output: Int32 = -1
        var destinationFolder: Int32 = -1
        defer {
            if output >= 0 { close(output) }
            if destinationFolder >= 0 { close(destinationFolder) }
        }
        if let stage {
            destinationFolder = try stage.directory(Array(member.path.dropLast()), create: true)
            output = openat(destinationFolder, member.path.last!,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw WorkspaceError.conflict }
        }
        var digest = SHA256(), consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try budget.check()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw WorkspaceError.unavailable }
            if count == 0 { break }
            guard Int64(count) <= member.size - consumed else { throw WorkspaceError.conflict }
            consumed += Int64(count)
            digest.update(data: Data(buffer.prefix(count)))
            if output >= 0 {
                var offset = 0
                while offset < count {
                    try budget.check()
                    let written = buffer.withUnsafeBytes { raw in
                        Darwin.write(output, raw.baseAddress!.advanced(by: offset), count - offset)
                    }
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw WorkspaceError.unavailable }
                    offset += written
                }
            }
        }
        var after = stat()
        guard consumed == member.size, fstat(input, &after) == 0,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              WorkspaceNodeID(try root.metadata(parent, member.path.last!)) == WorkspaceNodeID(before)
        else { throw WorkspaceError.conflict }
        if output >= 0 {
            // Preserve only the owner's execute bit. The copy stays private;
            // group/other and special permission bits never travel.
            let mode: mode_t = member.ownerExecutable ? 0o700 : 0o600
            guard fchmod(output, mode) == 0,
                  fsync(output) == 0, fsync(destinationFolder) == 0 else {
                throw WorkspaceError.unavailable
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func requireSpace(_ fd: Int32, bytes: Int64) throws {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { throw WorkspaceError.unavailable }
        guard Double(info.f_bavail) * Double(info.f_bsize) >= Double(bytes) * 1.1 else {
            throw WorkspaceError.limitExceeded
        }
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
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                        String(validatingUTF8: $0)
                    }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name == "." || name == ".." { continue }
            guard WorkspaceValidation.member(name), !name.contains("/") else {
                throw WorkspaceError.unsafeFile
            }
            names.append(name)
            guard names.count <= maximumFiles else { throw WorkspaceError.limitExceeded }
        }
        for name in names {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw WorkspaceError.unsafeFile
            }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw WorkspaceError.unsafeFile }
                do { defer { close(child) }; try removeChildren(child, depth: depth + 1) }
                guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else {
                    throw WorkspaceError.unavailable
                }
            } else {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
                      unlinkat(directory, name, 0) == 0 else { throw WorkspaceError.unsafeFile }
            }
        }
    }
}
#endif
