import Foundation
import CryptoKit
import Darwin

enum OfflineBuildInputError: Error {
    case unsafeSource, unsupportedMember, limitExceeded, changedSource
}

struct OfflineBuildInputFile {
    let relativePath: String
    let bytes: Data
    let sha256: String
}

struct OfflineBuildInputPlan {
    let files: [OfflineBuildInputFile]

    static func capture(_ source: URL, deadline: TimeInterval? = nil,
                        cancelled: () -> Bool = { false }) throws -> OfflineBuildInputPlan {
        let cutoff = deadline ?? ProcessInfo.processInfo.systemUptime + 120
        func check() throws {
            guard !cancelled(), ProcessInfo.processInfo.systemUptime < cutoff else {
                throw OfflineBuildInputError.limitExceeded
            }
        }
        try check()
        let root = try openDirectory(source.path)
        defer { close(root) }
        var files: [OfflineBuildInputFile] = []
        var portable = Set<String>()
        var total = 0
        var entries = 0
        func walk(_ directory: Int32, prefix: String, depth: Int) throws {
            try check()
            var before = stat()
            guard fstat(directory, &before) == 0 else { throw OfflineBuildInputError.unsafeSource }
            let copy = dup(directory)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { close(copy) }
                throw OfflineBuildInputError.unsafeSource
            }
            defer { closedir(stream) }
            while true {
                try check()
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw OfflineBuildInputError.unsafeSource }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                        String(validatingUTF8: $0)
                    }
                }
                guard let name else { throw OfflineBuildInputError.unsupportedMember }
                if name == "." || name == ".." { continue }
                entries += 1
                guard entries <= 4000, depth < 32 else { throw OfflineBuildInputError.limitExceeded }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                guard safePath(relative), portable.insert(relative.lowercased()).inserted else {
                    throw OfflineBuildInputError.unsupportedMember
                }
                var observed = stat()
                guard fstatat(directory, name, &observed, AT_SYMLINK_NOFOLLOW) == 0,
                      observed.st_uid == geteuid() else { throw OfflineBuildInputError.unsafeSource }
                switch observed.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFDIR):
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw OfflineBuildInputError.unsafeSource }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_dev == observed.st_dev,
                          opened.st_ino == observed.st_ino else {
                        close(child); throw OfflineBuildInputError.changedSource
                    }
                    do { try walk(child, prefix: relative, depth: depth + 1) }
                    catch { close(child); throw error }
                    close(child)
                case mode_t(S_IFREG):
                    guard safeMember(relative), observed.st_nlink == 1,
                          observed.st_size >= 0, observed.st_size <= 50 * 1024 * 1024 - total,
                          files.count < 2000 else { throw OfflineBuildInputError.limitExceeded }
                    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard file >= 0 else { throw OfflineBuildInputError.unsafeSource }
                    let data: Data
                    do {
                        var opened = stat()
                        guard fstat(file, &opened) == 0, opened.st_dev == observed.st_dev,
                              opened.st_ino == observed.st_ino else { throw OfflineBuildInputError.changedSource }
                        var captured = Data()
                        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                        while true {
                            try check()
                            let received = Darwin.read(file, &buffer, buffer.count)
                            if received < 0 && errno == EINTR { continue }
                            if received == 0 { break }
                            guard received > 0, captured.count + received <= observed.st_size else {
                                throw OfflineBuildInputError.changedSource
                            }
                            captured.append(contentsOf: buffer.prefix(received))
                        }
                        var after = stat()
                        guard fstat(file, &after) == 0, same(observed, after),
                              captured.count == observed.st_size else { throw OfflineBuildInputError.changedSource }
                        data = captured
                    } catch { close(file); throw error }
                    close(file)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    files.append(OfflineBuildInputFile(relativePath: relative, bytes: data, sha256: digest))
                    total += data.count
                default: throw OfflineBuildInputError.unsafeSource
                }
            }
            var after = stat()
            guard fstat(directory, &after) == 0, same(before, after) else {
                throw OfflineBuildInputError.changedSource
            }
        }
        try walk(root, prefix: "", depth: 0)
        guard files.contains(where: { $0.relativePath == "src/main.tsx" }) else { throw OfflineBuildInputError.unsupportedMember }
        return OfflineBuildInputPlan(files: files.sorted { $0.relativePath < $1.relativePath })
    }

    private static func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/") else { throw OfflineBuildInputError.unsafeSource }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw OfflineBuildInputError.unsafeSource }
        for part in path.split(separator: "/") {
            let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw OfflineBuildInputError.unsafeSource }
            current = next
        }
        return current
    }

    private static func same(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
        before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("//"),
              path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 64, 95].contains($0) }) else { return false }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count <= 32,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.lowercased() == "node_modules" || $0.lowercased() == "dist" || $0.lowercased().hasPrefix(".env") || $0.lowercased().contains(".config.") }) else { return false }
        let forbidden = ["tsconfig.json", "jsconfig.json", "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", ".npmrc"]
        return !parts.contains(where: { forbidden.contains($0.lowercased()) })
    }

    static func safeMember(_ path: String) -> Bool {
        guard safePath(path) else { return false }
        return ["ts", "tsx", "js", "jsx", "json", "css", "svg", "png", "jpg", "jpeg", "webp", "woff", "woff2"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}
