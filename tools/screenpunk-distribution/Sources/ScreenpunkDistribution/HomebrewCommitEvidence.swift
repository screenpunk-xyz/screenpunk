import Foundation
import Darwin
import CryptoKit

public protocol PackageCommitChecking {
    func prepareInstall(stateDirectory: Int32) throws
    func assertReady(stateDirectory: Int32) throws
}

/// Homebrew writes config.json atomically only after every artifact succeeds,
/// and its receipt after install/upgrade commits. The installer captures the
/// previous config inode before binary links are exposed. Startup requires a
/// new config plus a matching receipt and both direct command links.
public final class HomebrewCommitEvidence: PackageCommitChecking {
    private struct Stamp: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let seconds: Int
        let nanoseconds: Int
    }
    private struct Gate: Codable {
        let schema: Int
        let root: String
        let priorConfig: Stamp?
    }
    private let root: URL
    private let version: String
    private let metadata: URL
    private let bin: URL
    public init(root: URL, version: String, metadata: URL, bin: URL) {
        self.root = root; self.version = version; self.metadata = metadata; self.bin = bin
    }
    private var gateName: String {
        ".package-install-" + SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    private func configStamp() throws -> Stamp? {
        let file = open(metadata.appendingPathComponent("config.json").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw DistributionError.conflict }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o022 == 0 else {
            throw DistributionError.conflict
        }
        return Stamp(device: info.st_dev, inode: info.st_ino,
            seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
    public func prepareInstall(stateDirectory: Int32) throws {
        let bytes = try JSONEncoder().encode(Gate(schema: 1, root: root.path, priorConfig: configStamp()))
        let temporary = ".package-install-temp-" + UUID().uuidString
        let file = openat(stateDirectory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw DistributionError.unavailable }
        defer { close(file); _ = unlinkat(stateDirectory, temporary, 0) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DistributionError.unavailable }
                offset += count
            }
        }
        guard fsync(file) == 0,
              renameat(stateDirectory, temporary, stateDirectory, gateName) == 0,
              fsync(stateDirectory) == 0 else { throw DistributionError.unavailable }
    }
    public func assertReady(stateDirectory: Int32) throws {
        let file = openat(stateDirectory, gateName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw DistributionError.conflict }
        defer { close(file) }
        let gate = try JSONDecoder().decode(Gate.self, from: readOwned(file, maximum: 4096, privateFile: true))
        guard gate.schema == 1, gate.root == root.path,
              let config = try configStamp(), config != gate.priorConfig else { throw DistributionError.conflict }
        let receipt = open(metadata.appendingPathComponent("INSTALL_RECEIPT.json").path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard receipt >= 0 else { throw DistributionError.conflict }
        defer { close(receipt) }
        guard let value = try JSONSerialization.jsonObject(with: readOwned(receipt, maximum: 65_536)) as? [String: Any],
              let source = value["source"] as? [String: Any], source["version"] as? String == version,
              value["arch"] as? String == "arm64",
              let artifacts = value["uninstall_artifacts"] as? [[String: Any]] else { throw DistributionError.conflict }
        for name in ["screenpunk", "screenpunk-mcp"] {
            let member = "Screenpunk CLI \(version)/bin/\(name)"
            guard artifacts.contains(where: { ($0["binary"] as? [String])?.first == member }) else {
                throw DistributionError.conflict
            }
            let link = bin.appendingPathComponent(name)
            var info = stat()
            guard lstat(link.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                  info.st_uid == geteuid(), link.resolvingSymlinksInPath().path == root.appendingPathComponent("bin/" + name).resolvingSymlinksInPath().path else {
                throw DistributionError.conflict
            }
        }
    }
    private func readOwned(_ file: Int32, maximum: Int, privateFile: Bool = false) throws -> Data {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o022 == 0,
              !privateFile || info.st_mode & 0o7777 == 0o600,
              info.st_size > 0, info.st_size <= maximum else { throw DistributionError.conflict }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(file, raw.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw DistributionError.unavailable }
            offset += count
        }
        return Data(bytes)
    }
}
