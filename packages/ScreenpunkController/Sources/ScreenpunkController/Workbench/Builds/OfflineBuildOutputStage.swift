import Foundation
import CryptoKit
import Darwin

struct OfflineBuildOutputFile: Decodable {
    let path: String
    let bytes: Int64
    let sha256: String
}

enum OfflineBuildOutputStage {
    static let chunkBytes = 256 * 1024

    static func save(_ files: [OfflineBuildOutputFile], to destination: URL,
                     read: (String, Int64) throws -> Data) throws {
        guard !files.isEmpty, files.count <= 2000 else { throw OfflineBuildError.outputLimit }
        var total: Int64 = 0
        var names = Set<String>()
        for file in files {
            guard safeMember(file.path), names.insert(file.path.lowercased()).inserted,
                  file.bytes >= 0, file.bytes <= 50 * 1024 * 1024 - total,
                  file.sha256.utf8.count == 64,
                  file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw OfflineBuildError.invalidResponse
            }
            total += file.bytes
        }
        var existing = stat()
        guard lstat(destination.path, &existing) != 0, errno == ENOENT else { throw OfflineBuildError.invalidResponse }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".screenpunk-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: stage) } }
        for file in files {
            let target = stage.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw OfflineBuildError.invalidResponse }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            var digest = SHA256()
            var offset: Int64 = 0
            while offset < file.bytes {
                let packet = try read(file.path, offset)
                guard !packet.isEmpty, packet.count <= chunkBytes,
                      Int64(packet.count) <= file.bytes - offset else { throw OfflineBuildError.invalidResponse }
                try handle.write(contentsOf: packet)
                digest.update(data: packet)
                offset += Int64(packet.count)
            }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw OfflineBuildError.invalidResponse
            }
        }
        try FileManager.default.moveItem(at: stage, to: destination)
        committed = true
    }

    private static func safeMember(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("//"),
              path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 64, 95].contains($0) }) else { return false }
        return !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}
