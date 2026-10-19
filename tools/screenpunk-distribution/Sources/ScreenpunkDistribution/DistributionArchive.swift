import Foundation
import CryptoKit
import Darwin

public enum DistributionError: Error, Equatable {
    case invalidPath, unsafeFile, invalidManifest, incompletePayload, integrity, incompatible
    case untrustedRelease, alreadyExists, conflict, insufficientSpace, unavailable, recoveryRequired
}

public struct DistributionFile: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String
    public let executable: Bool
}

public struct DistributionManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let provenance: String // local-test or authenticated-release
    public let protocolVersion: Int
    public let minimumWorkspaceSchema: Int
    public let maximumWorkspaceSchema: Int
    public let authoringKitComplete: Bool
    public let files: [DistributionFile]
}

public struct DistributionAuthentication: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let keyId: String
    public let signatureBase64: String

    public init(keyId: String, signatureBase64: String) {
        self.schemaVersion = 1
        self.keyId = keyId
        self.signatureBase64 = signatureBase64
    }
}

/// Production implementations must bind the complete manifest and payload to an
/// independently approved release publisher/channel and native code signature.
/// Workspace files, environment overrides, and bundle-local claims cannot implement it.
public protocol DistributionReleaseTrust {
    func authenticateRelease(root: URL, manifestBytes: Data, manifest: DistributionManifest) throws
}

public struct RejectUnconfiguredReleaseTrust: DistributionReleaseTrust {
    public init() {}
    public func authenticateRelease(root: URL, manifestBytes: Data,
                                    manifest: DistributionManifest) throws {
        throw DistributionError.untrustedRelease
    }
}

public enum DistributionArchive {
    public static let required: Set<String> = ["bin/screenpunk", "bin/screenpunk-mcp",
        "libexec/screenpunk-service", "SBOM.json"]
    private static let maxFiles = 100_000
    private static let maxBytes: Int64 = 8 * 1024 * 1024 * 1024
    public static let authenticationFile = "release-auth.json"
    public static let manifestFile = "release-manifest.json"
    public static let signatureDomain = "screenpunk/distribution-manifest/v1"

    public static func signatureMessage(_ manifestBytes: Data) -> Data {
        var message = Data(signatureDomain.utf8)
        message.append(0)
        message.append(manifestBytes)
        return message
    }

    /// The caller supplies a dedicated release signer. Only public authentication
    /// metadata is copied into the archive; private signing material stays outside it.
    public static func assembleAuthenticatedRelease(payload: URL, output: URL, version: String,
        keyId: String, sign: (Data) throws -> Data,
        releaseTrust: any DistributionReleaseTrust,
        protocolVersion: Int = 1,
        workspaceSchema: ClosedRange<Int> = 1...1) throws -> DistributionManifest {
        guard validVersion(version), validVersion(keyId),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw DistributionError.alreadyExists
        }
        guard output.standardizedFileURL.path != payload.standardizedFileURL.path,
              !output.standardizedFileURL.path.hasPrefix(payload.standardizedFileURL.path + "/") else {
            throw DistributionError.invalidPath
        }
        let files = try inventory(payload, permitMetadata: false)
        let paths = Set(files.map(\.path))
        guard required.isSubset(of: paths),
              paths.contains("Resources/Toolchains/catalog-envelope.json"),
              paths.contains("Resources/Toolchains/authoring-1.0.0-darwin-arm64.tar"),
              paths.contains(where: { $0.hasPrefix("Resources/help/") }),
              paths.contains(where: { $0.hasPrefix("Resources/contracts/") }),
              paths.contains(where: { $0.hasPrefix("LICENSES/") }),
              files.filter({ ["bin/screenpunk", "bin/screenpunk-mcp", "libexec/screenpunk-service"].contains($0.path) })
                .allSatisfy(\.executable) else { throw DistributionError.incompletePayload }
        let manifest = DistributionManifest(schemaVersion: 1, version: version,
            provenance: "authenticated-release", protocolVersion: protocolVersion,
            minimumWorkspaceSchema: workspaceSchema.lowerBound,
            maximumWorkspaceSchema: workspaceSchema.upperBound,
            authoringKitComplete: true, files: files)
        let manifestBytes = try canonical(manifest)
        let signature = try sign(signatureMessage(manifestBytes))
        guard signature.count == 64 else { throw DistributionError.untrustedRelease }
        let authentication = DistributionAuthentication(keyId: keyId,
            signatureBase64: signature.base64EncodedString())
        let authenticationBytes = try canonical(authentication)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            for file in files {
                let target = output.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: payload.appendingPathComponent(file.path), to: target)
            }
            try manifestBytes.write(to: output.appendingPathComponent(manifestFile), options: .atomic)
            try authenticationBytes.write(to: output.appendingPathComponent(authenticationFile), options: .atomic)
            _ = try verify(root: output, allowLocalTest: false, releaseTrust: releaseTrust)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return manifest
    }

    /// Creates a concrete local-test distribution from a preassembled payload.
    /// It is intentionally incapable of declaring a production release.
    public static func assembleLocalTest(payload: URL, output: URL, version: String,
                                         protocolVersion: Int = 1,
                                         workspaceSchema: ClosedRange<Int> = 1...1) throws -> DistributionManifest {
        guard validVersion(version), !FileManager.default.fileExists(atPath: output.path) else {
            throw DistributionError.alreadyExists
        }
        guard output.standardizedFileURL.path != payload.standardizedFileURL.path,
              !output.standardizedFileURL.path.hasPrefix(payload.standardizedFileURL.path + "/") else {
            throw DistributionError.invalidPath
        }
        let files = try inventory(payload, permitMetadata: false)
        let paths = Set(files.map(\.path))
        guard required.isSubset(of: paths),
              paths.contains(where: { $0.hasPrefix("Resources/AuthoringKit/") }),
              paths.contains(where: { $0.hasPrefix("Resources/help/") }),
              paths.contains(where: { $0.hasPrefix("Resources/contracts/") }),
              paths.contains(where: { $0.hasPrefix("LICENSES/") }),
              files.filter({ ["bin/screenpunk", "bin/screenpunk-mcp", "libexec/screenpunk-service"].contains($0.path) })
                .allSatisfy(\.executable) else { throw DistributionError.incompletePayload }
        let manifest = DistributionManifest(schemaVersion: 1, version: version,
            provenance: "local-test", protocolVersion: protocolVersion,
            minimumWorkspaceSchema: workspaceSchema.lowerBound,
            maximumWorkspaceSchema: workspaceSchema.upperBound,
            authoringKitComplete: false, files: files)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            for item in files {
                let target = output.appendingPathComponent(item.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: payload.appendingPathComponent(item.path), to: target)
            }
            let data = try canonical(manifest)
            try data.write(to: output.appendingPathComponent("release-manifest.json"), options: .atomic)
            _ = try verify(root: output, allowLocalTest: true)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return manifest
    }

    @discardableResult public static func verify(root: URL, allowLocalTest: Bool,
        releaseTrust: any DistributionReleaseTrust = RejectUnconfiguredReleaseTrust()) throws -> DistributionManifest {
        let manifestURL = root.appendingPathComponent(manifestFile)
        try requireRegular(manifestURL)
        var manifestInfo = stat()
        guard lstat(manifestURL.path, &manifestInfo) == 0,
              manifestInfo.st_size <= 8 * 1024 * 1024 else { throw DistributionError.invalidManifest }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= 8 * 1024 * 1024,
              let manifest = try? JSONDecoder().decode(DistributionManifest.self, from: data),
              try canonical(manifest) == data, manifest.schemaVersion == 1,
              validVersion(manifest.version), manifest.protocolVersion >= 1,
              manifest.minimumWorkspaceSchema >= 1,
              manifest.minimumWorkspaceSchema <= manifest.maximumWorkspaceSchema,
              manifest.maximumWorkspaceSchema <= 1000 else { throw DistributionError.invalidManifest }
        let actual = try inventory(root, permitMetadata: true)
        guard actual == manifest.files, required.isSubset(of: Set(actual.map(\.path))) else {
            throw DistributionError.integrity
        }
        if manifest.provenance == "local-test" {
            guard allowLocalTest, !manifest.authoringKitComplete,
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent(authenticationFile).path)
            else { throw DistributionError.untrustedRelease }
        } else if manifest.provenance == "authenticated-release" {
            guard manifest.authoringKitComplete else { throw DistributionError.incompletePayload }
            let authenticationURL = root.appendingPathComponent(authenticationFile)
            try requireRegular(authenticationURL)
            var info = stat()
            guard lstat(authenticationURL.path, &info) == 0, info.st_size > 0,
                  info.st_size <= 4096 else { throw DistributionError.invalidManifest }
            try releaseTrust.authenticateRelease(root: root, manifestBytes: data, manifest: manifest)
        } else { throw DistributionError.invalidManifest }
        return manifest
    }

    public static func canonical(_ manifest: DistributionManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    public static func canonical(_ authentication: DistributionAuthentication) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(authentication)
    }

    private static func inventory(_ root: URL, permitMetadata: Bool) throws -> [DistributionFile] {
        try requireDirectory(root)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [], errorHandler: { _, _ in false }) else {
            throw DistributionError.unavailable
        }
        var files: [DistributionFile] = []
        var directories = Set<String>()
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            let path = String(url.path.dropFirst(root.path.count + 1))
            guard validMemberPath(path) else { throw DistributionError.invalidPath }
            var statbuf = stat()
            guard lstat(url.path, &statbuf) == 0, statbuf.st_uid == geteuid(),
                  statbuf.st_mode & 0o022 == 0, statbuf.st_mode & 0o7000 == 0 else {
                throw DistributionError.unsafeFile
            }
            if statbuf.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                guard directories.count < maxFiles else { throw DistributionError.incompletePayload }
                directories.insert(path)
                continue
            }
            guard statbuf.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), statbuf.st_nlink == 1,
                  ![manifestFile, authenticationFile].contains(path) || permitMetadata else {
                throw DistributionError.unsafeFile
            }
            if [manifestFile, authenticationFile].contains(path) { continue }
            guard files.count < maxFiles, statbuf.st_size >= 0,
                  statbuf.st_size <= maxBytes - total else { throw DistributionError.incompletePayload }
            total += statbuf.st_size
            let digest = try hash(url)
            files.append(.init(path: path, bytes: statbuf.st_size, sha256: digest,
                               executable: statbuf.st_mode & 0o111 != 0))
        }
        var folded = Set<String>()
        for path in files.map(\.path) {
            guard folded.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw DistributionError.conflict
            }
        }
        var declaredDirectories = Set<String>()
        for file in files {
            let parts = file.path.split(separator: "/")
            for count in 1..<parts.count {
                declaredDirectories.insert(parts.prefix(count).joined(separator: "/"))
            }
        }
        guard directories == declaredDirectories else { throw DistributionError.integrity }
        return files.sorted { $0.path < $1.path }
    }

    private static func hash(_ url: URL) throws -> String {
        try requireRegular(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DistributionError.unsafeFile }
        defer { close(fd) }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DistributionError.unavailable }
            if count == 0 { break }
            digest.update(data: Data(buffer[0..<count]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func requireRegular(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o022 == 0 else {
            throw DistributionError.unsafeFile
        }
    }
    private static func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw DistributionError.unsafeFile
        }
    }
    public static func validVersion(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 64 && text.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }
    public static func validMemberPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.hasPrefix("/") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
        }
    }
}
