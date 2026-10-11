import Foundation
import Darwin
import CryptoKit

/// Device-local, nonsecret retirement receipt. Completion permanently stops the
/// old reset from inspecting any future enrollment journal at the original path.
struct NativeEnrollmentIntentRetirement {
    enum Failure: Error { case changedOriginal, invalidRecord, persistence }
    enum Phase: String, Codable { case prepared, deleting, retired }
    struct Node: Codable, Equatable { let device: UInt64, inode: UInt64 }
    struct File: Codable, Equatable { let name: String, node: Node, sha256: String }
    struct Record: Codable {
        let version: Int, resetID: UUID, scopeDigest: String, installationID: UUID
        let enrollmentID: UUID, claimRequestID: UUID, activationRequestID: UUID
        let originalPath: String, anchorNode: Node, sidecarNode: Node, directoryNode: Node, files: [File]
        var phase: Phase
    }
    let original: URL
    var directory: URL { original.deletingLastPathComponent().appendingPathComponent("xyz.screenpunk.enrollment-reset", isDirectory: true) }
    var file: URL { directory.appendingPathComponent("retirement.json") }
    func load() throws -> Record? {
        guard exists(directory) else { return nil }
        _ = try node(directory, kind: S_IFDIR)
        guard exists(file) else { return nil }
        _ = try node(file, kind: S_IFREG)
        let bytes = try bounded(file, maximum: 65536)
        let result = try JSONDecoder().decode(Record.self, from: bytes)
        guard result.version == 1, result.originalPath == original.path,
              result.scopeDigest.count == 64, (1...256).contains(result.files.count),
              Set(result.files.map(\.name)).count == result.files.count,
              result.files.contains(where: { $0.name == "original.json" }),
              result.files.allSatisfy({ validName($0.name) && $0.sha256.count == 64 }) else { throw Failure.invalidRecord }
        return result
    }
    func capture(resetID: UUID, scopeDigest: String, installationID: UUID,
        expected: NativeEnrollmentIntentRecord, journal: NativeEnrollmentIntentJournal) throws {
        if let saved = try load(), saved.phase != .retired {
            guard saved.resetID == resetID, saved.scopeDigest == scopeDigest,
                  saved.installationID == installationID else { throw Failure.changedOriginal }
            if saved.phase == .prepared { try verify(original, record: saved) }
            return
        }
        guard journal.directory == original, let actual = try journal.load() else { throw Failure.changedOriginal }
        var normalized = expected; normalized.restoreRecordedInstallation = actual.restoreRecordedInstallation
        guard actual == normalized else { throw Failure.changedOriginal }
        try ensureDirectory()
        let anchor = try node(original.deletingLastPathComponent(), kind: S_IFDIR)
        let sidecar = try node(directory, kind: S_IFDIR)
        let root = try node(original, kind: S_IFDIR)
        let rootFD = try openDirectory(original); defer { close(rootFD) }
        let names = try FileManager.default.contentsOfDirectory(atPath: original.path).sorted()
        guard (1...256).contains(names.count), names.allSatisfy(validName) else { throw Failure.changedOriginal }
        var entries: [File] = []
        for name in names {
            let url = original.appendingPathComponent(name), identity = try node(url, kind: S_IFREG)
            let bytes = try bounded(rootFD, name: name, maximum: 65536, expected: identity)
            if name != "original.json" {
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let raw = object["installationID"] as? String,
                      UUID(uuidString: raw) == installationID else { throw Failure.changedOriginal }
            }
            guard try node(url, kind: S_IFREG) == identity else { throw Failure.changedOriginal }
            entries.append(.init(name: name, node: identity, sha256: digest(bytes)))
        }
        guard try node(original, kind: S_IFDIR) == root,
              try FileManager.default.contentsOfDirectory(atPath: original.path).sorted() == names else { throw Failure.changedOriginal }
        try save(.init(version: 1, resetID: resetID, scopeDigest: scopeDigest, installationID: installationID,
            enrollmentID: actual.enrollmentID, claimRequestID: actual.requestID,
            activationRequestID: actual.activationRequestID, originalPath: original.path,
            anchorNode: anchor, sidecarNode: sidecar, directoryNode: root, files: entries, phase: .prepared))
    }
    func retire(resetID: UUID, scopeDigest: String, validateCompletion: () throws -> Void) throws {
        guard var record = try load() else { throw Failure.invalidRecord }
        guard record.resetID == resetID, record.scopeDigest == scopeDigest else { throw Failure.changedOriginal }
        if record.phase == .retired { return }
        try validateCompletion()
        let anchorFD = try openDirectory(original.deletingLastPathComponent()); defer { close(anchorFD) }
        let sidecarFD = try openDirectory(directory); defer { close(sidecarFD) }
        guard try descriptorNode(anchorFD, kind: S_IFDIR) == record.anchorNode,
              try descriptorNode(sidecarFD, kind: S_IFDIR) == record.sidecarNode else { throw Failure.changedOriginal }
        let quarantine = directory.appendingPathComponent("retired-" + resetID.uuidString.lowercased(), isDirectory: true)
        if record.phase == .prepared {
            try verify(original, record: record)
            record.phase = .deleting; try save(record)
            try validateCompletion()
        }
        if exists(quarantine) {
            guard try node(quarantine, kind: S_IFDIR) == record.directoryNode else { throw Failure.changedOriginal }
        } else if exists(original) {
            // A newer or replaced original is never moved or deleted.
            guard try node(original, kind: S_IFDIR) == record.directoryNode else { throw Failure.changedOriginal }
            try verify(original, record: record)
            guard renameatx_np(anchorFD, original.lastPathComponent, sidecarFD, quarantine.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw Failure.persistence }
            try sync(original.deletingLastPathComponent()); try sync(directory)
            guard try node(quarantine, kind: S_IFDIR) == record.directoryNode else { throw Failure.changedOriginal }
        }
        if exists(quarantine) {
            let retiredFD = openat(sidecarFD, quarantine.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard retiredFD >= 0 else { throw Failure.changedOriginal }; defer { close(retiredFD) }
            guard try descriptorNode(retiredFD, kind: S_IFDIR) == record.directoryNode else { throw Failure.changedOriginal }
            let live = try FileManager.default.contentsOfDirectory(atPath: quarantine.path)
            guard Set(live).isSubset(of: Set(record.files.map(\.name))) else { throw Failure.changedOriginal }
            for entry in record.files {
                let url = quarantine.appendingPathComponent(entry.name)
                guard exists(url) else { continue }
                try validateCompletion()
                guard try node(quarantine, kind: S_IFDIR) == record.directoryNode,
                      try node(url, kind: S_IFREG) == entry.node,
                      digest(try bounded(retiredFD, name: entry.name, maximum: 65536, expected: entry.node)) == entry.sha256 else { throw Failure.changedOriginal }
                guard unlinkat(retiredFD, entry.name, 0) == 0 else { throw Failure.persistence }
                try sync(quarantine)
            }
            try validateCompletion()
            guard try node(quarantine, kind: S_IFDIR) == record.directoryNode,
                  try FileManager.default.contentsOfDirectory(atPath: quarantine.path).isEmpty,
                  unlinkat(sidecarFD, quarantine.lastPathComponent, AT_REMOVEDIR) == 0 else { throw Failure.changedOriginal }
            try sync(directory)
        }
        try validateCompletion()
        record.phase = .retired; try save(record)
    }
    private func verify(_ root: URL, record: Record) throws {
        guard try node(root, kind: S_IFDIR) == record.directoryNode,
              try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == record.files.map(\.name).sorted() else { throw Failure.changedOriginal }
        let rootFD = try openDirectory(root); defer { close(rootFD) }
        guard try descriptorNode(rootFD, kind: S_IFDIR) == record.directoryNode else { throw Failure.changedOriginal }
        for entry in record.files {
            let url = root.appendingPathComponent(entry.name)
            guard try node(url, kind: S_IFREG) == entry.node,
                  digest(try bounded(rootFD, name: entry.name, maximum: 65536, expected: entry.node)) == entry.sha256 else { throw Failure.changedOriginal }
        }
    }
    private func exists(_ url: URL) -> Bool {
        var value = stat(); return lstat(url.path, &value) == 0
    }
    private func validName(_ value: String) -> Bool {
        if value == "original.json" { return true }
        for prefix in ["local-command-", "cloud-command-"] where value.hasPrefix(prefix) && value.hasSuffix(".json") {
            return UUID(uuidString: String(value.dropFirst(prefix.count).dropLast(5))) != nil
        }
        return false
    }
    private func node(_ url: URL, kind: mode_t) throws -> Node {
        // Foundation can rewrite a genuine /private/var path to its /var alias.
        // Compare the POSIX physical path instead; descriptor/inode checks remain mandatory.
        let path = url.path
        guard path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let physical = realpath(path, nil) else { throw Failure.changedOriginal }
        defer { free(physical) }
        guard String(cString: physical) == path else { throw Failure.changedOriginal }
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == kind,
              kind == S_IFDIR || value.st_nlink == 1 else { throw Failure.changedOriginal }
        return .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino))
    }
    private func openDirectory(_ url: URL) throws -> Int32 {
        _ = try node(url, kind: S_IFDIR)
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.changedOriginal }; return fd
    }
    private func descriptorNode(_ fd: Int32, kind: mode_t) throws -> Node {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == kind,
              kind == S_IFDIR || value.st_nlink == 1 else { throw Failure.changedOriginal }
        return .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino))
    }
    private func bounded(_ directoryFD: Int32, name: String, maximum: Int, expected: Node) throws -> Data {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.changedOriginal }; defer { close(fd) }
        guard try descriptorNode(fd, kind: S_IFREG) == expected else { throw Failure.changedOriginal }
        let result = try readBytes(fd, maximum: maximum)
        guard try descriptorNode(fd, kind: S_IFREG) == expected else { throw Failure.changedOriginal }
        return result
    }
    private func bounded(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.changedOriginal }; defer { close(fd) }
        return try readBytes(fd, maximum: maximum)
    }
    private func readBytes(_ fd: Int32, maximum: Int) throws -> Data {
        var st = stat(); guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
            st.st_nlink == 1, st.st_size >= 0, st.st_size <= maximum else { throw Failure.changedOriginal }
        var bytes = Data(count: Int(st.st_size))
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw Failure.changedOriginal }; return bytes
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func ensureDirectory() throws {
        if !exists(directory) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try sync(directory.deletingLastPathComponent())
        }
        _ = try node(directory, kind: S_IFDIR)
    }
    private func save(_ record: Record) throws {
        if !exists(directory) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let identity = try node(directory, kind: S_IFDIR)
        guard identity == record.sidecarNode,
              try node(directory.deletingLastPathComponent(), kind: S_IFDIR) == record.anchorNode else { throw Failure.changedOriginal }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record); guard bytes.count <= 65536 else { throw Failure.invalidRecord }
        let rootFD = try openDirectory(directory); defer { close(rootFD) }
        guard try descriptorNode(rootFD, kind: S_IFDIR) == identity else { throw Failure.changedOriginal }
        let temporary = ".retirement-" + UUID().uuidString.lowercased() + ".tmp"
        let fd = openat(rootFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.persistence }; defer { close(fd) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            guard count > 0 else { throw Failure.persistence }; offset += count
        }
        guard fsync(fd) == 0,
              try descriptorNode(rootFD, kind: S_IFDIR) == identity,
              try node(directory, kind: S_IFDIR) == identity,
              try node(directory.deletingLastPathComponent(), kind: S_IFDIR) == record.anchorNode else { throw Failure.changedOriginal }
        guard renameat(rootFD, temporary, rootFD, file.lastPathComponent) == 0,
              fsync(rootFD) == 0 else { throw Failure.persistence }
        guard try node(directory, kind: S_IFDIR) == identity else { throw Failure.changedOriginal }
    }
    private func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.persistence }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.persistence }
    }
}
