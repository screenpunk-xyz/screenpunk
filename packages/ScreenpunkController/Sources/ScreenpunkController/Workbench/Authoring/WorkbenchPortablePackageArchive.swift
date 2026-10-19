import Foundation
import ScreenpunkCore
#if os(macOS)
import Darwin

public struct WorkbenchPortablePackageExportReceipt: Codable, Sendable, Equatable {
    public let path: String
    public let dashboardId: String
    public let revision: String
    public let digest: String
    public let fileCount: Int
    public let includedBytes: Int
}

/// Rename published the verified destination, but its parent sync failed.
/// The path may exist now; durability after a crash is unknown.
public struct WorkbenchPortablePackageExportPublicationUncertain: Error, Sendable, Equatable {
    public let receipt: WorkbenchPortablePackageExportReceipt
}

public struct WorkbenchPortablePackageArchiveEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: String
    public let manifestSHA256: String
    public let digest: String
    public let fileCount: Int
    public let includedBytes: Int
}

/// Closed V1 directory layout: package-archive.json and manifest.json are
/// descriptors; all runtime paths live below files/. This preserves a runtime
/// file named manifest.json without giving archive metadata path authority.
public final class WorkbenchPortablePackageArchive {
    private let workspace: WorkspaceStore
    private let syncPublishedParent: (Int32) -> Int32
    public init(workspace: WorkspaceStore) {
        self.workspace = workspace; syncPublishedParent = { fsync($0) }
    }
    init(workspace: WorkspaceStore, syncPublishedParent: @escaping (Int32) -> Int32) {
        self.workspace = workspace; self.syncPublishedParent = syncPublishedParent
    }

    public func export(dashboardId: String, revision: String, to destination: String,
                       deadline: TimeInterval? = nil,
                       cancelled: @escaping () -> Bool = { false }) throws
        -> WorkbenchPortablePackageExportReceipt {
        guard WorkspaceValidation.id(dashboardId), WorkspaceValidation.id(revision),
              WorkspaceValidation.absolute(destination),
              let selected = try workspace.current() else { throw WorkspaceError.invalidPath }
        let sourceKey = WorkspaceValidation.portableKey(selected.path)
        let outputKey = WorkspaceValidation.portableKey(destination)
        guard outputKey != sourceKey, !outputKey.hasPrefix(sourceKey + "/"),
              !sourceKey.hasPrefix(outputKey + "/") else { throw WorkspaceError.invalidPath }
        let budget = WorkspaceReadBudget(deadline: deadline ??
            ProcessInfo.processInfo.systemUptime + 120, cancelled: cancelled)
        try budget.check()
        let package = try WorkbenchPortablePackages(workspace: workspace,
            localReadTimeout: 120).exportVerified(dashboardId: dashboardId,
                revision: revision, deadline: budget.deadline, cancelled: cancelled)
        let manifestBytes = try JSONEncoder().encode(package.manifest)
        let envelope = WorkbenchPortablePackageArchiveEnvelope(schemaVersion: 1,
            kind: "immutable-runtime-package", manifestSHA256: WorkbenchTransactionDigest.hex(manifestBytes),
            digest: package.manifest.digest!, fileCount: package.files.count,
            includedBytes: package.files.values.reduce(0) { $0 + $1.count })
        let envelopeBytes = try WorkspaceJSON.encode(envelope)
        let parentPath = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        guard WorkspaceValidation.absolute(parentPath), WorkspaceValidation.member(name),
              !name.contains("/") else { throw WorkspaceError.invalidPath }
        let parent = try WorkspaceFiles(path: parentPath, requiredPrivateRoot: false)
        guard !(try parent.exists(parent.fd, name)) else { throw WorkspaceError.conflict }
        let stageName = ".screenpunk-package-export-" + UUID().uuidString.lowercased()
        guard mkdirat(parent.fd, stageName, 0o700) == 0, fsync(parent.fd) == 0 else {
            throw WorkspaceError.unavailable
        }
        let stage = try WorkspaceFiles(path: parentPath + "/" + stageName)
        var published = false
        defer { if !published { try? removeOwnedStage(parent: parent, name: stageName, stage: stage) } }
        try stage.write(stage.fd, "package-archive.json", data: envelopeBytes, expected: nil)
        try stage.write(stage.fd, "manifest.json", data: manifestBytes, expected: nil)
        for file in package.manifest.files {
            try budget.check()
            let parts = file.path.split(separator: "/").map(String.init)
            let folder = try stage.directory(["files"] + Array(parts.dropLast()), create: true)
            defer { close(folder) }
            try stage.write(folder, parts.last!, data: package.files[file.path]!, expected: nil)
        }
        try budget.check()
        guard try read(stage, path: "package-archive.json", budget: budget) == envelopeBytes,
              try read(stage, path: "manifest.json", budget: budget) == manifestBytes else {
            throw WorkspaceError.conflict
        }
        for file in package.manifest.files {
            try budget.check()
            guard try read(stage, path: "files/" + file.path, budget: budget) == package.files[file.path] else {
                throw WorkspaceError.conflict
            }
        }
        let expectedPaths = Set(package.manifest.files.map { "files/" + $0.path } +
            ["package-archive.json", "manifest.json"])
        let observed = try inventory(stage, budget: budget)
        guard observed.files == expectedPaths,
              observed.directories == expectedDirectories(for: expectedPaths),
              try workspace.current(readBudget: budget)?.selectionGeneration == selected.selectionGeneration,
              try WorkbenchPortablePackages(workspace: workspace,
                  localReadTimeout: 120).exportVerified(dashboardId: dashboardId,
                      revision: revision, deadline: budget.deadline,
                      cancelled: cancelled).files == package.files else {
            throw WorkspaceError.conflict
        }
        try stage.verifyRoot(); try parent.verifyRoot(); try budget.check()
        guard renameatx_np(parent.fd, stageName, parent.fd, name, UInt32(RENAME_EXCL)) == 0 else {
            throw WorkspaceError.unavailable
        }
        published = true
        let receipt = WorkbenchPortablePackageExportReceipt(path: destination,
            dashboardId: dashboardId, revision: revision,
            digest: package.manifest.digest!, fileCount: package.files.count,
            includedBytes: package.files.values.reduce(0) { $0 + $1.count })
        guard syncPublishedParent(parent.fd) == 0 else {
            throw WorkbenchPortablePackageExportPublicationUncertain(receipt: receipt)
        }
        return receipt
    }

    /// Reads only the explicit versioned layout. The existing public importer
    /// may continue accepting its legacy flat package directory separately.
    public func readVerified(from path: String, deadline: TimeInterval? = nil,
                             cancelled: @escaping () -> Bool = { false }) throws
        -> WorkbenchPortablePackage {
        guard WorkspaceValidation.absolute(path) else { throw WorkspaceError.invalidPath }
        let budget = WorkspaceReadBudget(deadline: deadline ??
            ProcessInfo.processInfo.systemUptime + 120, cancelled: cancelled)
        let root = try WorkspaceFiles(path: path, requiredPrivateRoot: false)
        let envelopeBytes = try read(root, path: "package-archive.json", budget: budget)
        guard envelopeBytes.count <= 8 * 1024 * 1024,
              let shape = try JSONSerialization.jsonObject(with: envelopeBytes) as? [String: Any],
              Set(shape.keys) == ["schemaVersion", "kind", "manifestSHA256", "digest", "fileCount", "includedBytes"],
              let envelope = try? JSONDecoder().decode(WorkbenchPortablePackageArchiveEnvelope.self,
                  from: envelopeBytes),
              envelope.schemaVersion == 1, envelope.kind == "immutable-runtime-package",
              WorkspaceValidation.sha256(envelope.manifestSHA256),
              WorkspaceValidation.sha256(envelope.digest),
              (1...2_000).contains(envelope.fileCount),
              (0...50 * 1024 * 1024).contains(envelope.includedBytes) else {
            throw WorkspaceError.invalidSchema
        }
        let manifestBytes = try read(root, path: "manifest.json", budget: budget)
        guard manifestBytes.count <= 4 * 1024 * 1024,
              WorkbenchTransactionDigest.hex(manifestBytes) == envelope.manifestSHA256,
              let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: manifestBytes),
              manifest.digest == envelope.digest,
              manifest.files.count == envelope.fileCount else { throw WorkspaceError.invalidSchema }
        var files: [String: Data] = [:]
        var total = 0
        for file in manifest.files {
            try budget.check()
            guard WorkspaceValidation.member(file.path),
                  file.bytes >= 0, file.bytes <= 50 * 1024 * 1024 - total,
                  files[file.path] == nil else { throw WorkspaceError.invalidSchema }
            let bytes = try read(root, path: "files/" + file.path, budget: budget)
            guard bytes.count == file.bytes,
                  WorkbenchTransactionDigest.hex(bytes) == file.sha256 else { throw WorkspaceError.conflict }
            files[file.path] = bytes; total += bytes.count
        }
        let expectedPaths = Set(files.keys.map { "files/" + $0 } +
            ["package-archive.json", "manifest.json"])
        let observed = try inventory(root, budget: budget)
        guard observed.files == expectedPaths,
              observed.directories == expectedDirectories(for: expectedPaths),
              total == envelope.includedBytes else { throw WorkspaceError.invalidSchema }
        let package = WorkbenchPortablePackage(manifest: manifest, files: files)
        try WorkbenchPortablePackages(workspace: workspace).validate(package, budget: budget)
        try root.verifyRoot(); try budget.check()
        return package
    }

    private func read(_ root: WorkspaceFiles, path: String,
                      budget: WorkspaceReadBudget) throws -> Data {
        let parts = path.split(separator: "/").map(String.init)
        let folder = try root.directory(Array(parts.dropLast())); defer { close(folder) }
        return try root.read(folder, parts.last!, maxBytes: 50 * 1024 * 1024,
                             readBudget: budget)
    }

    private struct ArchiveInventory {
        var files = Set<String>()
        var directories = Set<String>()
    }
    private func expectedDirectories(for files: Set<String>) -> Set<String> {
        var result = Set<String>()
        for file in files {
            let parts = file.split(separator: "/").map(String.init)
            for length in 1..<parts.count {
                result.insert(parts.prefix(length).joined(separator: "/"))
            }
        }
        return result
    }
    private func inventory(_ root: WorkspaceFiles,
                           budget: WorkspaceReadBudget) throws -> ArchiveInventory {
        var result = ArchiveInventory(), members = 0
        func walk(_ parts: [String]) throws {
            try budget.check()
            guard parts.count <= 32, members <= 4_004 else { throw WorkspaceError.limitExceeded }
            let folder = try root.directory(parts); defer { close(folder) }
            let copy = dup(folder)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
            }
            defer { closedir(stream) }
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
                if name == "." || name == ".." { continue }
                members += 1
                guard members <= 4_004 else { throw WorkspaceError.limitExceeded }
                guard WorkspaceValidation.member(name), !name.contains("/") else {
                    throw WorkspaceError.unsafeFile
                }
                var info = stat()
                guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_uid == geteuid() else {
                    throw WorkspaceError.unsafeFile
                }
                let child = parts + [name]
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    guard result.directories.insert(child.joined(separator: "/")).inserted else {
                        throw WorkspaceError.conflict
                    }
                    try walk(child)
                } else if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 {
                    guard result.files.insert(child.joined(separator: "/")).inserted else {
                        throw WorkspaceError.conflict
                    }
                } else { throw WorkspaceError.unsafeFile }
            }
        }
        try walk([])
        return result
    }

    private func removeOwnedStage(parent: WorkspaceFiles, name: String,
                                  stage: WorkspaceFiles) throws {
        let opened = try parent.directory([name]); defer { close(opened) }
        var info = stat()
        guard fstat(opened, &info) == 0, WorkspaceNodeID(info) == stage.identity else {
            throw WorkspaceError.conflict
        }
        func remove(_ directory: Int32, depth: Int) throws {
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
                    pointer.withMemoryRebound(to: CChar.self,
                        capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                            String(validatingUTF8: $0)
                        }
                }
                guard let name else { throw WorkspaceError.unsafeFile }
                if name != "." && name != ".." { names.append(name) }
            }
            guard names.count <= 4_004 else { throw WorkspaceError.limitExceeded }
            for name in names {
                guard WorkspaceValidation.member(name), !name.contains("/") else {
                    throw WorkspaceError.unsafeFile
                }
                var childInfo = stat()
                guard fstatat(directory, name, &childInfo, AT_SYMLINK_NOFOLLOW) == 0,
                      childInfo.st_uid == geteuid() else { throw WorkspaceError.unsafeFile }
                if childInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw WorkspaceError.unsafeFile }
                    defer { close(child) }
                    try remove(child, depth: depth + 1)
                    guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw WorkspaceError.unavailable }
                } else if childInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), childInfo.st_nlink == 1 {
                    guard unlinkat(directory, name, 0) == 0 else { throw WorkspaceError.unavailable }
                } else { throw WorkspaceError.unsafeFile }
            }
        }
        try remove(opened, depth: 0)
        guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0,
              fsync(parent.fd) == 0 else { throw WorkspaceError.unavailable }
    }
}
#endif
