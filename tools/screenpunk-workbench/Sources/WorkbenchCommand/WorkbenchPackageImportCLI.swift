import Foundation
import Darwin
import ScreenpunkController
import ScreenpunkCore

enum WorkbenchPackageImportCLI {
    static func run(directory: String, selected: WorkbenchWorkspaceStatus,
                    client: WorkbenchBrokerClient, presentation: Presentation) throws {
        guard directory.hasPrefix("/"), let workspaceId = selected.workspaceId,
              let generation = selected.selectionGeneration else {
            throw Options.usage("screen import requires an absolute package directory and selected workspace.")
        }
        let package = try readPackage(directory)
        let digest = try DeploymentDigest.digest(for: package.manifest)
        guard package.manifest.digest == digest else { throw invalidPackage() }
        let started = try client.beginPackageImport(manifest: package.manifest,
            expectedDigest: digest, expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: generation)
        guard let upload = started.uploadId else { throw WorkbenchIPCError(.invalidRequest) }
        var commitSubmitted = false
        defer {
            if !commitSubmitted {
                try? client.abortPackageImport(uploadId: upload, expectedWorkspaceId: workspaceId,
                    expectedSelectionGeneration: generation)
            }
        }
        for (index, file) in package.manifest.files.enumerated() {
            guard let bytes = package.files[file.path] else { throw invalidPackage() }
            if bytes.isEmpty {
                _ = try client.sendPackageImportChunk(uploadId: upload, fileIndex: index,
                    offset: 0, bytes: Data(), expectedWorkspaceId: workspaceId,
                    expectedSelectionGeneration: generation)
            } else {
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + 64 * 1024, bytes.count)
                    _ = try client.sendPackageImportChunk(uploadId: upload, fileIndex: index,
                        offset: offset, bytes: bytes.subdata(in: offset..<end),
                        expectedWorkspaceId: workspaceId,
                        expectedSelectionGeneration: generation)
                    offset = end
                }
            }
        }
        // Once commit is submitted, a missing reply cannot prove that history
        // publication failed. Do not send an abort that implies rollback.
        commitSubmitted = true
        let receipt = try classifySubmittedCommit(workspaceId: workspaceId,
            dashboardId: package.manifest.dashboardId, revision: package.manifest.revision,
            digest: digest) {
            try client.commitPackageImport(uploadId: upload, expectedDigest: digest,
                expectedWorkspaceId: workspaceId, expectedSelectionGeneration: generation)
        }
        let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any]
        guard let result else { throw WorkbenchIPCError(.invalidRequest) }
        do {
            try presentation.checkedSuccess(result,
                human: "Imported historical package \(TerminalPresentation.safe(receipt.dashboardId)) revision \(TerminalPresentation.safe(receipt.revision)) (\(receipt.fileCount) files, \(receipt.includedBytes) bytes).")
        } catch {
            throw CommandFailure("import_applied_display_failed",
                "The historical package was imported, but the result could not be displayed.", 6,
                details: ["dashboardId": receipt.dashboardId, "revision": receipt.revision,
                          "digest": receipt.digest])
        }
    }

    private static func readPackage(_ directory: String) throws -> WorkbenchPortablePackage {
        let root = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw invalidPackage() }
        defer { Darwin.close(root) }
        var marker = stat()
        if fstatat(root, "package-archive.json", &marker, AT_SYMLINK_NOFOLLOW) == 0 {
            return try readVersionedPackage(root: root)
        }
        guard errno == ENOENT else { throw invalidPackage() }
        return try readLegacyPackage(root: root)
    }

    private static func readVersionedPackage(root: Int32) throws -> WorkbenchPortablePackage {
        let envelopeData = try readFile(root: root, path: "package-archive.json", maximum: 8 * 1024 * 1024)
        guard let shape = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
              Set(shape.keys) == ["schemaVersion", "kind", "manifestSHA256", "digest", "fileCount", "includedBytes"],
              let envelope = try? JSONDecoder().decode(WorkbenchPortablePackageArchiveEnvelope.self,
                  from: envelopeData),
              envelope.schemaVersion == 1, envelope.kind == "immutable-runtime-package",
              (1...2_000).contains(envelope.fileCount),
              (0...50 * 1024 * 1024).contains(envelope.includedBytes) else { throw invalidPackage() }
        let manifestData = try readFile(root: root, path: "manifest.json", maximum: 4 * 1024 * 1024)
        guard let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: manifestData),
              manifest.files.count == envelope.fileCount,
              DeploymentDigest.sha256Hex(manifestData) == envelope.manifestSHA256,
              manifest.digest == envelope.digest else { throw invalidPackage() }
        do { try PackageValidator.validate(manifest) }
        catch { throw invalidPackage() }
        var total = 0
        var files: [String: Data] = [:]
        for file in manifest.files {
            guard file.bytes >= 0, file.bytes <= 50 * 1024 * 1024 - total else {
                throw invalidPackage()
            }
            let data = try readFile(root: root, path: "files/" + file.path, maximum: file.bytes)
            guard data.count == file.bytes,
                  DeploymentDigest.sha256Hex(data) == file.sha256 else { throw invalidPackage() }
            files[file.path] = data
            total += data.count
        }
        guard total == envelope.includedBytes else { throw invalidPackage() }
        let expectedFiles = Set(files.keys.map { "files/" + $0 } +
            ["package-archive.json", "manifest.json"])
        let expectedDirectories = directories(for: expectedFiles)
        let actual = try inventory(root: root)
        guard actual.files == expectedFiles, actual.directories == expectedDirectories else {
            throw invalidPackage()
        }
        return WorkbenchPortablePackage(manifest: manifest, files: files)
    }

    private static func readLegacyPackage(root: Int32) throws -> WorkbenchPortablePackage {
        let manifestData = try readFile(root: root, path: "manifest.json", maximum: 4 * 1024 * 1024)
        guard let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: manifestData),
              manifest.files.count <= 2_000 else { throw invalidPackage() }
        do { try PackageValidator.validate(manifest) }
        catch { throw invalidPackage() }
        var total = manifestData.count
        var files: [String: Data] = [:]
        for file in manifest.files {
            guard file.bytes >= 0, file.bytes <= 50 * 1024 * 1024 - total else {
                throw invalidPackage()
            }
            let data = try readFile(root: root, path: file.path, maximum: file.bytes)
            guard data.count == file.bytes,
                  DeploymentDigest.sha256Hex(data) == file.sha256 else { throw invalidPackage() }
            files[file.path] = data
            total += data.count
        }
        return WorkbenchPortablePackage(manifest: manifest, files: files)
    }

    private static func directories(for files: Set<String>) -> Set<String> {
        var result = Set<String>()
        for path in files {
            let parts = path.split(separator: "/").map(String.init)
            for length in 1..<parts.count { result.insert(parts.prefix(length).joined(separator: "/")) }
        }
        return result
    }

    private static func inventory(root: Int32) throws -> (files: Set<String>, directories: Set<String>) {
        var files = Set<String>(), directories = Set<String>(), members = 0
        func walk(_ parent: Int32, _ prefix: String, _ depth: Int) throws {
            guard depth <= 32 else { throw invalidPackage() }
            let copy = dup(parent)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { Darwin.close(copy) }
                throw invalidPackage()
            }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw invalidPackage() }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self,
                        capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                            String(validatingUTF8: $0)
                        }
                }
                guard let name else { throw invalidPackage() }
                if name == "." || name == ".." { continue }
                members += 1
                guard members <= 4_004, !name.isEmpty, name != ".", name != "..",
                      !name.contains("/") else { throw invalidPackage() }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_uid == geteuid() else { throw invalidPackage() }
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    guard directories.insert(path).inserted else { throw invalidPackage() }
                    let child = Darwin.openat(parent, name,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw invalidPackage() }
                    defer { Darwin.close(child) }
                    try walk(child, path, depth + 1)
                } else if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 {
                    guard files.insert(path).inserted else { throw invalidPackage() }
                } else { throw invalidPackage() }
            }
        }
        try walk(root, "", 0)
        return (files, directories)
    }

    private static func readFile(root: Int32, path: String, maximum: Int) throws -> Data {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw invalidPackage()
        }
        var parent = root
        defer { if parent != root { Darwin.close(parent) } }
        for component in components.dropLast() {
            let next = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw invalidPackage() }
            if parent != root { Darwin.close(parent) }
            parent = next
        }
        let fd = Darwin.openat(parent, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw invalidPackage() }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximum else { throw invalidPackage() }
        var data = Data()
        var block = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < before.st_size {
            let size = min(block.count, Int(before.st_size) - data.count)
            let count = Darwin.read(fd, &block, size)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw invalidPackage() }
            data.append(contentsOf: block.prefix(count))
        }
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw invalidPackage() }
        return data
    }

    private static func invalidPackage() -> CommandFailure {
        CommandFailure("invalid_package", "The package directory is invalid or changed during reading.", 6)
    }

    static func classifySubmittedCommit<T>(workspaceId: String, dashboardId: String,
                                           revision: String, digest: String,
                                           send: () throws -> T) throws -> T {
        do { return try send() }
        catch let error as WorkbenchIPCError where [.disconnected, .timedOut, .unavailable].contains(error.code) {
            throw uncertainImport(workspaceId: workspaceId, dashboardId: dashboardId,
                revision: revision, digest: digest)
        }
    }

    private static func uncertainImport(workspaceId: String, dashboardId: String,
                                        revision: String, digest: String) -> CommandFailure {
        CommandFailure("outcome_unknown",
            "The package import lost its broker reply; immutable history may already contain this exact package.", 7,
            nextActions: ["Inspect screen history for this workspace, dashboard ID, revision and digest before another import. Do not assume the upload abort reversed a submitted commit."],
            details: ["workspaceId": workspaceId, "dashboardId": dashboardId,
                      "revision": revision, "digest": digest])
    }
}
