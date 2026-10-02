import Foundation
import CryptoKit
import Security

/// Immutable publisher policy compiled into the standalone release tooling.
/// No workspace file, environment value, or archive metadata can replace it.
public struct ScreenpunkProductionReleaseTrust: DistributionReleaseTrust {
    public static let keyId = "screenpunk-release-2026-09"
    public static let teamIdentifier = "77KASWDGM6"
    public static let channel = "stable"
    public static let publicKeyRaw = Data(base64Encoded: "LGC9mox5gIz0zhOleiR4X+atIl5pKyL5cFSN11SMCTU=")!

    private static let executableIdentifiers: [String: String] = [
        "bin/screenpunk": "xyz.screenpunk.cli",
        "bin/screenpunk-mcp": "xyz.screenpunk.mcp",
        "libexec/screenpunk-service": "xyz.screenpunk.service"
    ]
    private static let developerIDCommonName =
        "Developer ID Application: Screenpunk, Inc. (77KASWDGM6)"

    public init() {}

    public func authenticateRelease(root: URL, manifestBytes: Data,
                                    manifest: DistributionManifest) throws {
        guard manifest.provenance == "authenticated-release", manifest.authoringKitComplete,
              Set(manifest.files.filter(\.executable).map(\.path)) == Set(Self.executableIdentifiers.keys),
              Set(Self.executableIdentifiers.keys).isSubset(of: Set(manifest.files.map(\.path))) else {
            throw DistributionError.untrustedRelease
        }
        let path = root.appendingPathComponent(DistributionArchive.authenticationFile)
        let bytes = try Data(contentsOf: path)
        guard let authentication = try? JSONDecoder().decode(DistributionAuthentication.self, from: bytes),
              authentication.schemaVersion == 1, authentication.keyId == Self.keyId,
              try DistributionArchive.canonical(authentication) == bytes,
              let signature = Data(base64Encoded: authentication.signatureBase64),
              signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Self.publicKeyRaw),
              key.isValidSignature(signature, for: DistributionArchive.signatureMessage(manifestBytes)) else {
            throw DistributionError.untrustedRelease
        }
        for (member, identifier) in Self.executableIdentifiers {
            try verifyDeveloperID(root.appendingPathComponent(member), identifier: identifier)
        }
    }

    private func verifyDeveloperID(_ executable: URL, identifier: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code else { throw DistributionError.untrustedRelease }
        let expression = "anchor apple generic and certificate leaf[subject.CN] = \"\(Self.developerIDCommonName)\" and identifier \"\(identifier)\""
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess else {
            throw DistributionError.untrustedRelease
        }
    }
}
