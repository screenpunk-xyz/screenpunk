import XCTest
import Foundation
import CryptoKit
@testable import ScreenpunkDistribution

private struct TestOnlyReleaseTrust: DistributionReleaseTrust {
    let key: Curve25519.Signing.PublicKey
    func authenticateRelease(root: URL, manifestBytes: Data,
                             manifest: DistributionManifest) throws {
        let data = try Data(contentsOf: root.appendingPathComponent(DistributionArchive.authenticationFile))
        let auth = try JSONDecoder().decode(DistributionAuthentication.self, from: data)
        guard data == (try DistributionArchive.canonical(auth)), auth.keyId == "fixture-only",
              let signature = Data(base64Encoded: auth.signatureBase64),
              key.isValidSignature(signature, for: DistributionArchive.signatureMessage(manifestBytes)) else {
            throw DistributionError.untrustedRelease
        }
    }
}

final class AuthenticatedReleaseTests: XCTestCase {
    func testAppOwnedValidatorPolicyPreservesOldReleasesAndRejectsIncompleteClosure() throws {
        let base = ["bin/screenpunk", "bin/screenpunk-mcp", "libexec/screenpunk-service"].map {
            DistributionFile(path: $0, bytes: 1, sha256: String(repeating: "a", count: 64), executable: true)
        }
        func manifest(_ extra: [DistributionFile]) -> DistributionManifest {
            .init(schemaVersion: 1, version: "1.0.0", provenance: "authenticated-release", protocolVersion: 1,
                  minimumWorkspaceSchema: 1, maximumWorkspaceSchema: 1, authoringKitComplete: true, files: base + extra)
        }
        XCTAssertEqual(try ScreenpunkProductionReleaseTrust.executablePolicy(manifest([])).count, 3)
        let node = DistributionFile(path: "Resources/ConnectionValidator/node", bytes: 1, sha256: String(repeating: "a", count: 64), executable: true)
        let parser = DistributionFile(path: "Resources/ConnectionValidator/validate.cjs", bytes: 1, sha256: String(repeating: "b", count: 64), executable: false)
        XCTAssertThrowsError(try ScreenpunkProductionReleaseTrust.executablePolicy(manifest([node])))
        XCTAssertThrowsError(try ScreenpunkProductionReleaseTrust.executablePolicy(manifest([parser])))
        XCTAssertEqual(try ScreenpunkProductionReleaseTrust.executablePolicy(manifest([node, parser]))[node.path], "xyz.screenpunk.connection-validator.node")
        let extra = DistributionFile(path: "Resources/ConnectionValidator/other", bytes: 1, sha256: String(repeating: "b", count: 64), executable: true)
        XCTAssertThrowsError(try ScreenpunkProductionReleaseTrust.executablePolicy(manifest([node, parser, extra])))
    }

    func testDetachedAuthenticationBindsMeasuredPayloadAndSurvivesArchiveCopy() throws {
        let base = URL(fileURLWithPath: "/private/tmp/screenpunk-release-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let payload = base.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let contents = [
            "bin/screenpunk": "cli", "bin/screenpunk-mcp": "mcp",
            "libexec/screenpunk-service": "service", "SBOM.json": "{}",
            "Resources/Toolchains/catalog-envelope.json": "catalog",
            "Resources/Toolchains/authoring-1.0.0-darwin-arm64.tar": "tar",
            "Resources/help/help.json": "{}", "Resources/contracts/contract.json": "{}",
            "LICENSES/LICENSE": "license"
        ]
        for (relative, body) in contents {
            let file = payload.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(body.utf8).write(to: file)
            if relative.hasPrefix("bin/") || relative.hasPrefix("libexec/") {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
        }
        let key = Curve25519.Signing.PrivateKey()
        let trust = TestOnlyReleaseTrust(key: key.publicKey)
        let archive = base.appendingPathComponent("release")
        let assembled = try DistributionArchive.assembleAuthenticatedRelease(payload: payload,
            output: archive, version: "1.0.0", keyId: "fixture-only",
            sign: { try key.signature(for: $0) }, releaseTrust: trust)
        XCTAssertEqual(assembled.provenance, "authenticated-release")
        XCTAssertFalse(assembled.files.contains { $0.path == DistributionArchive.authenticationFile })
        XCTAssertEqual(try DistributionArchive.verify(root: archive, allowLocalTest: false,
            releaseTrust: trust), assembled)
        let authentication = archive.appendingPathComponent(DistributionArchive.authenticationFile)
        var altered = try Data(contentsOf: authentication)
        altered[altered.count - 3] ^= 1
        try altered.write(to: authentication)
        XCTAssertThrowsError(try DistributionArchive.verify(root: archive, allowLocalTest: false,
            releaseTrust: trust))
    }
}
