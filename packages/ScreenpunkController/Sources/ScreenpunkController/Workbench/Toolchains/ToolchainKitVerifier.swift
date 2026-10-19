import Foundation
import CryptoKit
#if os(macOS)
import Darwin

struct ToolchainFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    init(_ value: stat) { device = UInt64(value.st_dev); inode = value.st_ino }
}

struct ToolchainKitVerifier {
    let signature: any ToolchainExecutableSignatureVerifying

    func verify(root path: String, approved: ApprovedToolchainKit) throws -> VerifiedToolchainKit {
        let root = try openDirectory(path)
        defer { close(root) }
        let before = try metadata(root)
        guard before.st_uid == geteuid(), before.st_mode & 0o7777 == 0o500 else {
            throw ToolchainTrustError.unsafePath
        }
        let identity = ToolchainFileIdentity(before)
        let expected = Dictionary(uniqueKeysWithValues: approved.entry.inventory.map { ($0.path, $0) })
        var directories = Set<String>()
        for item in approved.entry.inventory {
            let parts = item.path.split(separator: "/").map(String.init)
            for count in 1..<parts.count { directories.insert(parts.prefix(count).joined(separator: "/")) }
        }
        var state = ScanState()
        try scan(root, rootPath: path, relative: "", depth: 0, expected: expected,
                 directories: directories, state: &state)
        guard state.files == Set(expected.keys), state.directories == directories else {
            throw ToolchainTrustError.inventoryMismatch
        }
        let after = try openDirectory(path)
        defer { close(after) }
        guard ToolchainFileIdentity(try metadata(after)) == identity,
              stable(before, try metadata(root)) else { throw ToolchainTrustError.inventoryMismatch }
        return VerifiedToolchainKit(approved: approved, includedFiles: state.files.count,
                                    includedBytes: state.bytes, installedPath: path, rootIdentity: identity)
    }

    func verifyArtifact(path: String, approved: ApprovedToolchainKit) throws {
        guard WorkspaceValidation.absolute(path) else { throw ToolchainTrustError.unsafePath }
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw ToolchainTrustError.unsafePath }
        let parentPath = "/" + parts.dropLast().joined(separator: "/")
        let parent = try openDirectory(parentPath)
        defer { close(parent) }
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw ToolchainTrustError.artifactMismatch }
        defer { close(file) }
        let before = try metadata(file)
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_uid == geteuid(),
              before.st_nlink == 1, before.st_mode & 0o7022 == 0,
              before.st_size >= 0, before.st_size <= 1_073_741_824,
              before.st_size == approved.entry.artifactBytes else { throw ToolchainTrustError.artifactMismatch }
        let digest = try hash(file, limit: 1_073_741_824)
        guard digest == approved.entry.artifactSha256,
              stable(before, try metadata(file)) else { throw ToolchainTrustError.artifactMismatch }
    }

    private struct ScanState {
        var members = 0
        var bytes: Int64 = 0
        var files = Set<String>()
        var directories = Set<String>()
        var portable = [String: String]()
    }

    private func scan(_ directory: Int32, rootPath: String, relative: String, depth: Int,
                      expected: [String: ToolchainInventoryItem], directories: Set<String>,
                      state: inout ScanState) throws {
        guard depth <= 32 else { throw ToolchainTrustError.limitExceeded }
        let beforeDirectory = try metadata(directory)
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }; throw ToolchainTrustError.unsafePath
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ToolchainTrustError.unsafePath }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw ToolchainTrustError.unsafePath }
            if name == "." || name == ".." { continue }
            guard WorkspaceValidation.member(name), name == name.precomposedStringWithCanonicalMapping,
                  state.members < 100_000 else { throw ToolchainTrustError.limitExceeded }
            state.members += 1
            let path = relative.isEmpty ? name : relative + "/" + name
            let key = WorkspaceValidation.portableKey(path)
            if let prior = state.portable[key], prior != path { throw ToolchainTrustError.inventoryMismatch }
            state.portable[key] = path
            var observed = stat()
            guard fstatat(directory, name, &observed, AT_SYMLINK_NOFOLLOW) == 0,
                  observed.st_uid == geteuid(), observed.st_mode & 0o7022 == 0 else {
                throw ToolchainTrustError.unsafePath
            }
            switch observed.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                guard directories.contains(path), observed.st_mode & 0o7777 == 0o500 else {
                    throw ToolchainTrustError.inventoryMismatch
                }
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ToolchainTrustError.unsafePath }
                try withFD(child) { opened in
                    guard ToolchainFileIdentity(try metadata(opened)) == ToolchainFileIdentity(observed) else {
                        throw ToolchainTrustError.unsafePath
                    }
                    state.directories.insert(path)
                    try scan(opened, rootPath: rootPath, relative: path, depth: depth + 1,
                             expected: expected, directories: directories, state: &state)
                }
            case mode_t(S_IFREG):
                guard let item = expected[path], observed.st_nlink == 1,
                      observed.st_size >= 0, observed.st_size == item.bytes,
                      observed.st_size <= 2_147_483_648 - state.bytes else {
                    throw ToolchainTrustError.inventoryMismatch
                }
                let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard file >= 0 else { throw ToolchainTrustError.unsafePath }
                try withFD(file) { opened in
                    guard ToolchainFileIdentity(try metadata(opened)) == ToolchainFileIdentity(observed),
                          observed.st_mode & 0o200 == 0,
                          item.role == "executable" ? observed.st_mode & 0o100 != 0 : observed.st_mode & 0o111 == 0 else {
                        throw ToolchainTrustError.unsafePath
                    }
                    let digest = try hash(opened, limit: 2_147_483_648 - state.bytes)
                    guard digest == item.sha256 else { throw ToolchainTrustError.inventoryMismatch }
                    if let publisher = item.publisher {
                        guard lseek(opened, 0, SEEK_SET) == 0 else { throw ToolchainTrustError.unsafePath }
                        try signature.verify(fd: opened, path: rootPath + "/" + path, expected: publisher)
                    }
                    guard stable(observed, try metadata(opened)) else { throw ToolchainTrustError.inventoryMismatch }
                    state.bytes += observed.st_size
                    state.files.insert(path)
                }
            default: throw ToolchainTrustError.unsafePath
            }
        }
        guard stable(beforeDirectory, try metadata(directory)) else { throw ToolchainTrustError.inventoryMismatch }
    }

    private func openDirectory(_ path: String) throws -> Int32 {
        guard WorkspaceValidation.absolute(path) else { throw ToolchainTrustError.unsafePath }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw ToolchainTrustError.unsafePath }
        do {
            for part in path.split(separator: "/") {
                let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ToolchainTrustError.kitMissing }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }

    private func metadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ToolchainTrustError.unsafePath }
        return value
    }
    private func withFD<T>(_ fd: Int32, _ body: (Int32) throws -> T) rethrows -> T {
        defer { close(fd) }
        return try body(fd)
    }
    private func stable(_ before: stat, _ after: stat) -> Bool {
        ToolchainFileIdentity(before) == ToolchainFileIdentity(after) && before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }
    private func hash(_ fd: Int32, limit: Int64) throws -> String {
        var digest = SHA256()
        var seen: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ToolchainTrustError.unsafePath }
            if count == 0 { break }
            guard Int64(count) <= limit - seen else { throw ToolchainTrustError.limitExceeded }
            seen += Int64(count)
            digest.update(data: Data(buffer.prefix(count)))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
