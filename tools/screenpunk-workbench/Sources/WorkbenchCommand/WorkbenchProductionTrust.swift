import Foundation
import Darwin
import CryptoKit
import ScreenpunkController
import ScreenpunkDistribution

/// The standalone CLI and service share one immutable, compiled release policy.
/// Portable workspaces and package-supplied policy fields cannot alter these values.
enum WorkbenchProductionTrust {
    static let catalogMember = "Resources/Toolchains/catalog-envelope.json"

    /// A production Homebrew installation has a fixed, versioned location.
    /// A signed executable copied elsewhere remains a development invocation.
    static func homebrewRoot(executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let executable else { return nil }
        let actual = executable.resolvingSymlinksInPath()
        let root = actual.deletingLastPathComponent().deletingLastPathComponent()
        let version = root.deletingLastPathComponent().lastPathComponent
        guard DistributionArchive.validVersion(version),
              root.path == "/opt/homebrew/Caskroom/screenpunk-cli/\(version)/Screenpunk CLI \(version)",
              ["bin/screenpunk", "bin/screenpunk-mcp", "libexec/screenpunk-service"].contains(
                String(actual.path.dropFirst(root.path.count + 1))) else { return nil }
        return root
    }

    static func verifyPackage(_ root: URL) throws -> DistributionManifest {
        let manifest = try DistributionArchive.verify(root: root, allowLocalTest: false,
            releaseTrust: ScreenpunkProductionReleaseTrust())
        guard manifest.version == root.deletingLastPathComponent().lastPathComponent else {
            throw DistributionError.untrustedRelease
        }
        return manifest
    }

    static func installedKitTrust(paths: InstallationPaths,
                                  installedReleaseRoot: URL? = nil) throws -> WorkbenchInstalledReleaseTrust {
        let parent = paths.machineState.appendingPathComponent("Toolchains")
        let catalog = parent.appendingPathComponent("Catalog")
        let kits = parent.appendingPathComponent("Kits")
        try ownedParent(paths.home.appendingPathComponent("Library"))
        try ensureOwnedParent(paths.machineState.deletingLastPathComponent())
        try ensurePrivateDirectory(paths.machineState)
        try ensurePrivateDirectory(parent)
        try ensurePrivateDirectory(catalog)
        try ensurePrivateDirectory(kits)
        let team = ScreenpunkProductionReleaseTrust.teamIdentifier
        let publishers = [
            "xyz.screenpunk.build-host",
            "xyz.screenpunk.build-service",
            "xyz.screenpunk.authoring.node",
            "xyz.screenpunk.authoring.esbuild",
            "xyz.screenpunk.authoring.fsevents"
        ].map { WorkbenchInstalledReleaseTrust.Publisher(
            teamIdentifier: team, signingIdentifier: $0) }
        return try WorkbenchInstalledReleaseTrust(signers: [
            .init(keyId: ScreenpunkProductionReleaseTrust.keyId,
                  publicKey: ScreenpunkProductionReleaseTrust.publicKeyRaw,
                  // 2026-09-30T00:00:00Z through 2028-10-01T00:00:00Z, exclusive.
                  validFrom: Date(timeIntervalSince1970: 1_790_726_400),
                  validUntil: Date(timeIntervalSince1970: 1_853_971_200))
        ], channel: ScreenpunkProductionReleaseTrust.channel,
           acceptedSequence: 0, knownHistoricalEnvelopeHashes: [],
           allowedOrigins: [], approvedPublishers: publishers,
           catalogRoot: catalog.path, installedKitRoot: kits.path,
           keychainService: "xyz.screenpunk.workbench.release-catalog",
           keychainAccount: ScreenpunkProductionReleaseTrust.channel,
           installedReleaseRoot: installedReleaseRoot)
    }

    /// Called by the installer only after it has authenticated the staged unit,
    /// and before that unit is selected or its service is registered.
    static func prepareVerifiedPayload(root: URL, manifest: DistributionManifest,
                                       paths: InstallationPaths) throws {
        guard manifest.provenance == "authenticated-release", manifest.authoringKitComplete,
              let measuredCatalog = manifest.files.first(where: { $0.path == catalogMember }) else {
            throw DistributionError.incompletePayload
        }
        let envelope = try readCatalogMember(root)
        let hash = SHA256.hash(data: envelope).map { String(format: "%02x", $0) }.joined()
        guard measuredCatalog.bytes == Int64(envelope.count),
              measuredCatalog.sha256 == hash else { throw DistributionError.integrity }
        let trust = try installedKitTrust(paths: paths, installedReleaseRoot: root)
        _ = try trust.importVerifiedOfflineRelease(root: root, signedCatalogEnvelope: envelope)
    }

    /// Source-built foreground services remain useful for private development, but
    /// receive no production kit authority. An installed service must be the exact
    /// authenticated executable selected by the fixed per-user installer.
    static func installedServiceTrust(options: Options) throws -> WorkbenchInstalledReleaseTrust? {
        let paths = InstallationPaths(home: FileManager.default.homeDirectoryForCurrentUser)
        if let root = homebrewRoot() {
            guard Bundle.main.executableURL?.resolvingSymlinksInPath().path ==
                  root.appendingPathComponent("libexec/screenpunk-service").path else {
                throw DistributionError.untrustedRelease
            }
            try paths.validateServiceDirectories(controllerHome: options.homeURL(), runtimeDirectory: options.runtimeURL())
            _ = try verifyPackage(root)
            return try installedKitTrust(paths: paths, installedReleaseRoot: root)
        }
        let selectedService = paths.current.appendingPathComponent("libexec/screenpunk-service")
        guard FileManager.default.fileExists(atPath: selectedService.path),
              let running = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              running.path == selectedService.resolvingSymlinksInPath().path else { return nil }
        try paths.validateServiceDirectories(controllerHome: options.homeURL(),
                                              runtimeDirectory: options.runtimeURL())
        let releaseRoot = paths.current.resolvingSymlinksInPath()
        _ = try DistributionArchive.verify(root: releaseRoot,
            allowLocalTest: false, releaseTrust: ScreenpunkProductionReleaseTrust())
        return try installedKitTrust(paths: paths, installedReleaseRoot: releaseRoot)
    }

    private static func readCatalogMember(_ root: URL) throws -> Data {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw DistributionError.unsafeFile }
        defer { close(directory) }
        var parent = directory
        for part in catalogMember.split(separator: "/").dropLast() {
            let next = openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if parent != directory { close(parent) }
            guard next >= 0 else { throw DistributionError.unsafeFile }
            parent = next
        }
        defer { if parent != directory { close(parent) } }
        let fd = openat(parent, "catalog-envelope.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DistributionError.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size > 0, info.st_size <= WorkbenchInstalledReleaseTrust.maximumCatalogEnvelopeBytes else {
            throw DistributionError.unsafeFile
        }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while output.count < info.st_size {
            let count = Darwin.read(fd, &chunk, min(chunk.count, Int(info.st_size) - output.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw DistributionError.unsafeFile }
            output.append(contentsOf: chunk.prefix(count))
        }
        return output
    }

    private static func ownedDirectory(_ path: URL) throws {
        var info = stat()
        guard lstat(path.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
            throw DistributionError.unsafeFile
        }
    }

    private static func ownedParent(_ path: URL) throws {
        var info = stat()
        guard lstat(path.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o7022 == 0 else {
            throw DistributionError.unsafeFile
        }
    }

    private static func ensureOwnedParent(_ path: URL) throws {
        if mkdir(path.path, 0o700) != 0 && errno != EEXIST {
            throw DistributionError.unsafeFile
        }
        try ownedParent(path)
    }

    private static func ensurePrivateDirectory(_ path: URL) throws {
        if mkdir(path.path, 0o700) != 0 && errno != EEXIST {
            throw DistributionError.unsafeFile
        }
        try ownedDirectory(path)
    }
}
