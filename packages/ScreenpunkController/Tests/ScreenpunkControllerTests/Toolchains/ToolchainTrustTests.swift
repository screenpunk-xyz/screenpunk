import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import ScreenpunkController

final class ToolchainTrustTests: XCTestCase {
    private var temporary: URL!
    private var installed: URL!
    private var signer: Curve25519.Signing.PrivateKey!
    private let kitPublisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "xyz.screenpunk.authoring-kit")
    private let nodePublisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "xyz.screenpunk.node")
    private let helperPublisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "xyz.screenpunk.helper")
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let bytes: [String: Data] = [
        "bin/node": Data("synthetic-node".utf8),
        "helpers/native": Data("synthetic-helper".utf8),
        "kit.json": Data("{\"version\":\"1.0.0\"}".utf8),
        "lib/compiler.js": Data("module.exports = 1;".utf8),
        "scripts/build.mjs": Data("export const build = 1;".utf8)
    ]

    override func setUpWithError() throws {
        temporary = URL(fileURLWithPath: "/private/tmp/sp-f1-" + UUID().uuidString.prefix(12))
        installed = temporary.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(chmod(installed.path, 0o700), 0)
        signer = Curve25519.Signing.PrivateKey()
    }
    override func tearDownWithError() throws {
        if let temporary, FileManager.default.fileExists(atPath: temporary.path) {
            if let walker = FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: nil) {
                for case let path as URL in walker {
                    var info = stat()
                    if lstat(path.path, &info) == 0 {
                        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { _ = chmod(path.path, 0o700) }
                        else if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) { _ = chmod(path.path, 0o600) }
                    }
                }
            }
            try FileManager.default.removeItem(at: temporary)
        }
    }

    func testM0InventoryHashVectorAndProductionFailClosed() throws {
        let publisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "xyz.screenpunk.node")
        let items = [
            ToolchainInventoryItem(path: "bin/node", sha256: String(repeating: "b", count: 64), bytes: 1,
                                   role: "executable", publisher: publisher),
            ToolchainInventoryItem(path: "scripts/build.mjs", sha256: String(repeating: "c", count: 64), bytes: 1,
                                   role: "resource", publisher: nil)
        ]
        XCTAssertEqual(try ToolchainCanonical.inventoryHash(items),
                       "fa578b2872844a486883b74bb1467fd7022610198dd30cd29eee5b5ab274228a")
        expect(.trustUnavailable) { _ = try TrustedToolchainResolver.production() }
    }

    func testSyntheticSignedCatalogExactHistoricalOfflineKitAndArtifact() throws {
        let entry = try makeEntry()
        let payload = makePayload(entry: entry, sequence: 1)
        let envelope = try sign(payload)
        let envelopeHash = sha(envelope)
        let native = SyntheticSignatureBackend()
        let resolver = try makeResolver(native: native, acceptedSequence: 2, historical: [envelopeHash])
        let catalog = try resolver.authenticateCatalog(envelope)
        XCTAssertTrue(catalog.historical)
        let approved = try resolver.resolve(requirement(for: entry), catalogs: [catalog])
        let staged = try stage(entry, native: native)
        let verified = try resolver.verifyInstalled(approved)
        XCTAssertEqual(verified.includedFiles, bytes.count)
        XCTAssertEqual(verified.includedBytes, Int64(bytes.values.reduce(0) { $0 + $1.count }))
        XCTAssertNoThrow(try resolver.verifyForUse(verified))
        XCTAssertEqual(staged.path, installed.appendingPathComponent(approved.directoryName).path)
        let archive = temporary.appendingPathComponent("kit.archive")
        try write(Data("archive".utf8), to: archive, permissions: 0o600)
        XCTAssertNoThrow(try resolver.verifyArtifact(at: archive.path, for: approved))

        var wrong = requirement(for: entry)
        wrong = .init(catalogEntryId: wrong.catalogEntryId, kitVersion: wrong.kitVersion,
                      platform: wrong.platform, inventoryHash: String(repeating: "a", count: 64))
        expect(.requirementMismatch) { _ = try resolver.resolve(wrong, catalogs: [catalog]) }
        let missing = WorkspaceToolchainRequirements.Requirement(catalogEntryId: "missing-kit", kitVersion: "1.0.0",
                                                                  platform: "darwin-arm64", inventoryHash: entry.inventoryHash)
        expect(.unknownKit) { _ = try resolver.resolve(missing, catalogs: [catalog]) }
    }

    func testUnknownSignerBadSignatureAndUnknownPublisherReject() throws {
        let entry = try makeEntry()
        let native = SyntheticSignatureBackend()
        let resolver = try makeResolver(native: native)
        let valid = try sign(makePayload(entry: entry, sequence: 2))
        let payload = try resolver.authenticateCatalog(valid).payload
        let unknownSigner = try sign(payload, signerKeyId: "unknown-key")
        expect(.unknownSigner) { _ = try resolver.authenticateCatalog(unknownSigner) }
        let changed = try sign(makePayload(entry: entry, sequence: 3))
        let changedText = String(decoding: changed, as: UTF8.self).replacingOccurrences(of: "\"sequence\":3", with: "\"sequence\":4")
        expect(.signatureInvalid) { _ = try resolver.authenticateCatalog(Data(changedText.utf8)) }

        let alien = ToolchainPublisher(teamIdentifier: "ALIENKEY00", signingIdentifier: "alien.publisher")
        let alienEntry = ToolchainCatalogEntry(catalogEntryId: entry.catalogEntryId, kind: entry.kind,
            version: entry.version, platform: entry.platform, artifactSha256: entry.artifactSha256,
            artifactBytes: entry.artifactBytes, downloadURL: entry.downloadURL, publisher: alien,
            inventoryHash: entry.inventoryHash, inventory: entry.inventory, protocolMajor: nil)
        expect(.unknownPublisher) { _ = try resolver.authenticateCatalog(sign(makePayload(entry: alienEntry, sequence: 2))) }

        let duplicateKey = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"sequence\":2", with: "\"sequence\":2,\"seque\\u006ece\":2")
        expect(.invalidCatalog) { _ = try resolver.authenticateCatalog(Data(duplicateKey.utf8)) }
    }

    func testMacOSBackendRejectsUnsignedSyntheticExecutable() throws {
        let entry = try makeEntry()
        let stage = try self.stage(entry, native: SyntheticSignatureBackend())
        let node = stage.appendingPathComponent("bin/node")
        let fd = open(node.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        expect(.publisherUnverified) {
            try MacOSToolchainSignatureVerifier().verify(fd: fd, path: node.path, expected: nodePublisher)
        }
    }

    func testModifiedCompilerScriptAndNativePublisherRejectEvenWithSameKitMetadata() throws {
        let entry = try makeEntry()
        let native = SyntheticSignatureBackend()
        let resolver = try makeResolver(native: native)
        let catalog = try resolver.authenticateCatalog(sign(makePayload(entry: entry, sequence: 2)))
        let approved = try resolver.resolve(requirement(for: entry), catalogs: [catalog])
        let stage = try self.stage(entry, native: native)
        let verified = try resolver.verifyInstalled(approved)
        let script = stage.appendingPathComponent("scripts/build.mjs")
        XCTAssertEqual(chmod(stage.path, 0o700), 0)
        XCTAssertEqual(chmod(script.deletingLastPathComponent().path, 0o700), 0)
        try write(Data("tampered script".utf8), to: script, permissions: 0o400)
        XCTAssertEqual(chmod(script.deletingLastPathComponent().path, 0o500), 0)
        XCTAssertEqual(chmod(stage.path, 0o500), 0)
        expect(.inventoryMismatch) { _ = try resolver.verifyForUse(verified) }
        XCTAssertEqual(chmod(stage.path, 0o700), 0)
        XCTAssertEqual(chmod(script.deletingLastPathComponent().path, 0o700), 0)
        try write(bytes["scripts/build.mjs"]!, to: script, permissions: 0o400)
        XCTAssertEqual(chmod(script.deletingLastPathComponent().path, 0o500), 0)
        XCTAssertEqual(chmod(stage.path, 0o500), 0)
        native.bind(stage.appendingPathComponent("helpers/native"), publisher: nodePublisher)
        expect(.publisherUnverified) { _ = try resolver.verifyInstalled(approved) }
        native.bind(stage.appendingPathComponent("helpers/native"), publisher: helperPublisher)
        let helper = stage.appendingPathComponent("helpers/native")
        XCTAssertEqual(chmod(stage.path, 0o700), 0)
        XCTAssertEqual(chmod(helper.deletingLastPathComponent().path, 0o700), 0)
        try write(Data("tampered helper".utf8), to: helper, permissions: 0o500)
        XCTAssertEqual(chmod(helper.deletingLastPathComponent().path, 0o500), 0)
        XCTAssertEqual(chmod(stage.path, 0o500), 0)
        expect(.inventoryMismatch) { _ = try resolver.verifyInstalled(approved) }
    }

    func testMatchingArtifactHashDoesNotAuthorizeUnknownNativePublisher() throws {
        let entry = try makeEntry()
        let native = SyntheticSignatureBackend()
        let resolver = try makeResolver(native: native)
        let catalog = try resolver.authenticateCatalog(sign(makePayload(entry: entry, sequence: 2)))
        let approved = try resolver.resolve(requirement(for: entry), catalogs: [catalog])
        let archive = temporary.appendingPathComponent("matching.archive")
        try write(Data("archive".utf8), to: archive, permissions: 0o600)
        XCTAssertNoThrow(try resolver.verifyArtifact(at: archive.path, for: approved))
        let stage = try self.stage(entry, native: native)
        native.bind(stage.appendingPathComponent("bin/node"), publisher: helperPublisher)
        expect(.publisherUnverified) { _ = try resolver.verifyInstalled(approved) }
    }

    func testExtraMissingLinksAndArchiveLimitReject() throws {
        let entry = try makeEntry()
        let native = SyntheticSignatureBackend()
        let resolver = try makeResolver(native: native)
        let catalog = try resolver.authenticateCatalog(sign(makePayload(entry: entry, sequence: 2)))
        let approved = try resolver.resolve(requirement(for: entry), catalogs: [catalog])
        let stage = try self.stage(entry, native: native)
        let extra = stage.appendingPathComponent("extra.txt")
        XCTAssertEqual(chmod(stage.path, 0o700), 0)
        try write(Data("extra".utf8), to: extra, permissions: 0o400)
        XCTAssertEqual(chmod(stage.path, 0o500), 0)
        expect(.inventoryMismatch) { _ = try resolver.verifyInstalled(approved) }
        XCTAssertEqual(chmod(stage.path, 0o700), 0)
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.removeItem(at: stage.appendingPathComponent("kit.json"))
        XCTAssertEqual(chmod(stage.path, 0o500), 0)
        expect(.inventoryMismatch) { _ = try resolver.verifyInstalled(approved) }

        let link = stage.appendingPathComponent("kit.json")
        XCTAssertEqual(chmod(stage.path, 0o700), 0)
        XCTAssertEqual(symlink(temporary.appendingPathComponent("outside").path, link.path), 0)
        XCTAssertEqual(chmod(stage.path, 0o500), 0)
        expect(.unsafePath) { _ = try resolver.verifyInstalled(approved) }

        let huge = temporary.appendingPathComponent("oversized.archive")
        let fd = open(huge.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 1_073_741_825), 0)
        close(fd)
        expect(.artifactMismatch) { try resolver.verifyArtifact(at: huge.path, for: approved) }
    }

    func testDowngradeRevokedExpiredAndInvalidInventoryReject() throws {
        let entry = try makeEntry()
        let old = try sign(makePayload(entry: entry, sequence: 1))
        expect(.staleCatalog) { _ = try makeResolver(native: SyntheticSignatureBackend(), acceptedSequence: 2).authenticateCatalog(old) }
        expect(.revokedSigner) { _ = try makeResolver(native: SyntheticSignatureBackend(), revoked: true).authenticateCatalog(old) }
        expect(.expiredSigner) { _ = try makeResolver(native: SyntheticSignatureBackend(), expired: true).authenticateCatalog(old) }

        let badPaths = (entry.inventory + [
            ToolchainInventoryItem(path: "A/file.js", sha256: String(repeating: "a", count: 64), bytes: 1, role: "resource", publisher: nil),
            ToolchainInventoryItem(path: "a/other.js", sha256: String(repeating: "b", count: 64), bytes: 1, role: "resource", publisher: nil)
        ]).sorted { ToolchainCanonical.utf8Less($0.path, $1.path) }
        let badEntry = ToolchainCatalogEntry(catalogEntryId: entry.catalogEntryId, kind: entry.kind,
            version: entry.version, platform: entry.platform, artifactSha256: entry.artifactSha256,
            artifactBytes: entry.artifactBytes, downloadURL: entry.downloadURL, publisher: entry.publisher,
            inventoryHash: try ToolchainCanonical.inventoryHash(badPaths), inventory: badPaths, protocolMajor: nil)
        expect(.invalidCatalog) { _ = try makeResolver(native: SyntheticSignatureBackend()).authenticateCatalog(sign(makePayload(entry: badEntry, sequence: 2))) }
        let deepPath = Array(repeating: "level", count: 33).joined(separator: "/") + "/file.js"
        let deep = (entry.inventory + [ToolchainInventoryItem(path: deepPath, sha256: String(repeating: "a", count: 64),
                                           bytes: 1, role: "resource", publisher: nil)]).sorted {
            ToolchainCanonical.utf8Less($0.path, $1.path)
        }
        let deepEntry = ToolchainCatalogEntry(catalogEntryId: entry.catalogEntryId, kind: entry.kind,
            version: entry.version, platform: entry.platform, artifactSha256: entry.artifactSha256,
            artifactBytes: entry.artifactBytes, downloadURL: entry.downloadURL, publisher: entry.publisher,
            inventoryHash: try ToolchainCanonical.inventoryHash(deep), inventory: deep, protocolMajor: nil)
        expect(.invalidCatalog) { _ = try makeResolver(native: SyntheticSignatureBackend()).authenticateCatalog(sign(makePayload(entry: deepEntry, sequence: 2))) }
    }

    func testConflictingSignedGenerationPoisonsEitherAuthenticationOrder() throws {
        let first = try makeEntry()
        let second = alternateArtifact(first)
        for entries in [[first, second], [second, first]] {
            let resolver = try makeResolver(native: SyntheticSignatureBackend())
            let accepted = try resolver.authenticateCatalog(sign(makePayload(entry: entries[0], sequence: 2)))
            expect(.conflictingCatalog) {
                _ = try resolver.authenticateCatalog(sign(makePayload(entry: entries[1], sequence: 2)))
            }
            expect(.conflictingCatalog) {
                _ = try resolver.resolve(requirement(for: first), catalogs: [accepted])
            }
        }
    }

    func testSamePayloadDuplicateEnvelopesResolveDeterministically() throws {
        let entry = try makeEntry()
        let original = try sign(makePayload(entry: entry, sequence: 2))
        let secondSigner = Curve25519.Signing.PrivateKey()
        let alternateSignature = try sign(makePayload(entry: entry, sequence: 2), signerKeyId: "alternate-key",
                                          signingKey: secondSigner)
        let alternateEnvelope = Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "{", with: "{ ").utf8)
        let secondTrust = ToolchainTrustedSigner(publicKey: secondSigner.publicKey.rawRepresentation,
            validFrom: instant.addingTimeInterval(-100), validUntil: instant.addingTimeInterval(100), revoked: false)
        let resolver = try makeResolver(native: SyntheticSignatureBackend(), extraSigners: ["alternate-key": secondTrust])
        let first = try resolver.authenticateCatalog(original)
        let second = try resolver.authenticateCatalog(alternateEnvelope)
        let third = try resolver.authenticateCatalog(alternateSignature)
        let a = try resolver.resolve(requirement(for: entry), catalogs: [first, second, third, first])
        let b = try resolver.resolve(requirement(for: entry), catalogs: [third, second, first])
        XCTAssertEqual(a.entry, b.entry)
        XCTAssertEqual(a.catalogEnvelopeHash, b.catalogEnvelopeHash)
    }

    func testHistoricalCurrentPinConflictRejectsBothOrders() throws {
        let oldEntry = try makeEntry()
        let newEntry = alternateArtifact(oldEntry)
        let oldBytes = try sign(makePayload(entry: oldEntry, sequence: 1))
        let currentBytes = try sign(makePayload(entry: newEntry, sequence: 2))
        for envelopes in [[oldBytes, currentBytes], [currentBytes, oldBytes]] {
            let resolver = try makeResolver(native: SyntheticSignatureBackend(), acceptedSequence: 2,
                                            historical: [sha(oldBytes)])
            let accepted = try resolver.authenticateCatalog(envelopes[0])
            expect(.conflictingCatalog) {
                _ = try resolver.authenticateCatalog(envelopes[1])
            }
            expect(.conflictingCatalog) {
                _ = try resolver.resolve(requirement(for: oldEntry), catalogs: [accepted])
            }
        }
    }

    private func alternateArtifact(_ entry: ToolchainCatalogEntry) -> ToolchainCatalogEntry {
        ToolchainCatalogEntry(catalogEntryId: entry.catalogEntryId, kind: entry.kind,
            version: entry.version, platform: entry.platform, artifactSha256: String(repeating: "d", count: 64),
            artifactBytes: entry.artifactBytes, downloadURL: entry.downloadURL, publisher: entry.publisher,
            inventoryHash: entry.inventoryHash, inventory: entry.inventory, protocolMajor: entry.protocolMajor)
    }

    private func makeEntry() throws -> ToolchainCatalogEntry {
        let inventory = bytes.keys.sorted(by: ToolchainCanonical.utf8Less).map { path -> ToolchainInventoryItem in
            let publisher = path == "bin/node" ? nodePublisher : (path == "helpers/native" ? helperPublisher : nil)
            return ToolchainInventoryItem(path: path, sha256: sha(bytes[path]!), bytes: bytes[path]!.count,
                                          role: publisher == nil ? "resource" : "executable", publisher: publisher)
        }
        return ToolchainCatalogEntry(catalogEntryId: "kit-1.0.0", kind: "authoringKit", version: "1.0.0",
            platform: "darwin-arm64", artifactSha256: sha(Data("archive".utf8)), artifactBytes: 7,
            downloadURL: "https://releases.example.test/kit.archive", publisher: kitPublisher,
            inventoryHash: try ToolchainCanonical.inventoryHash(inventory), inventory: inventory, protocolMajor: nil)
    }
    private func makePayload(entry: ToolchainCatalogEntry, sequence: Int) -> ToolchainCatalogPayload {
        ToolchainCatalogPayload(catalogVersion: 1, catalogId: "synthetic-catalog", channel: "stable",
                                sequence: sequence, entries: [entry])
    }
    private func sign(_ payload: ToolchainCatalogPayload, signerKeyId: String = "synthetic-key",
                      signingKey: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
        var message = Data("screenpunk/release-catalog/v1".utf8)
        message.append(0); message.append(try ToolchainCanonical.encode(object))
        let signature = try (signingKey ?? signer).signature(for: message)
        let envelope = ToolchainCatalogEnvelope(signatureVersion: 1, algorithm: "Ed25519", signerKeyId: signerKeyId,
                                                 signatureBase64: signature.base64EncodedString(), payload: payload)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }
    private func makeResolver(native: SyntheticSignatureBackend, acceptedSequence: Int = 1,
                              historical: Set<String> = [], revoked: Bool = false,
                              expired: Bool = false,
                              extraSigners: [String: ToolchainTrustedSigner] = [:]) throws -> TrustedToolchainResolver {
        let trusted = ToolchainTrustedSigner(publicKey: signer.publicKey.rawRepresentation,
            validFrom: instant.addingTimeInterval(-100), validUntil: instant.addingTimeInterval(expired ? -1 : 100), revoked: revoked)
        var signers = extraSigners
        signers["synthetic-key"] = trusted
        let policy = try ToolchainTrustPolicy(signers: signers, channel: "stable",
            acceptedSequence: acceptedSequence, knownHistoricalEnvelopeHashes: historical,
            allowedOrigins: ["https://releases.example.test"],
            approvedPublishers: [kitPublisher, nodePublisher, helperPublisher], installedKitRoot: installed.path)
        return TrustedToolchainResolver(policy: policy, now: { [instant] in instant }, nativeSignature: native)
    }
    private func requirement(for entry: ToolchainCatalogEntry) -> WorkspaceToolchainRequirements.Requirement {
        .init(catalogEntryId: entry.catalogEntryId, kitVersion: entry.version,
              platform: entry.platform, inventoryHash: entry.inventoryHash)
    }
    private func stage(_ entry: ToolchainCatalogEntry, native: SyntheticSignatureBackend) throws -> URL {
        let name = entry.catalogEntryId + "-" + String(entry.inventoryHash.prefix(16))
        let root = installed.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var directories = Set<URL>()
        for item in entry.inventory {
            let destination = root.appendingPathComponent(item.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            directories.insert(destination.deletingLastPathComponent())
            try write(bytes[item.path]!, to: destination, permissions: item.role == "executable" ? 0o500 : 0o400)
            if let publisher = item.publisher { native.bind(destination, publisher: publisher) }
        }
        for directory in directories { XCTAssertEqual(chmod(directory.path, 0o500), 0) }
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        return root
    }
    private func write(_ data: Data, to path: URL, permissions: mode_t) throws {
        if FileManager.default.fileExists(atPath: path.path) { XCTAssertEqual(chmod(path.path, 0o600), 0) }
        try data.write(to: path, options: .atomic)
        XCTAssertEqual(chmod(path.path, permissions), 0)
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func expect(_ expected: ToolchainTrustError, _ action: () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? ToolchainTrustError, expected, file: file, line: line)
        }
    }
}

private final class SyntheticSignatureBackend: ToolchainExecutableSignatureVerifying {
    private var publishers: [UInt64: ToolchainPublisher] = [:]
    func bind(_ path: URL, publisher: ToolchainPublisher) {
        var info = stat()
        precondition(lstat(path.path, &info) == 0)
        publishers[info.st_ino] = publisher
    }
    func verify(fd: Int32, path: String, expected: ToolchainPublisher) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, publishers[info.st_ino] == expected else {
            throw ToolchainTrustError.publisherUnverified
        }
    }
}
