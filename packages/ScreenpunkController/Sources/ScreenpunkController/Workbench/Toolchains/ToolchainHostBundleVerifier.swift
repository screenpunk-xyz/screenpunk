import Foundation
#if os(macOS)
import Darwin
import Security

protocol ToolchainHostBundleSignatureVerifying {
    func verify(bundlePath: String, expected: ToolchainPublisher) throws
}

/// A host bundle is a release-signed, headless app. Its private XPC service and exact kit are
/// sealed before publication; the local installer never mutates or re-signs that bundle.
struct MacOSToolchainHostBundleSignatureVerifier: ToolchainHostBundleSignatureVerifying {
    func verify(bundlePath: String, expected: ToolchainPublisher) throws {
        try expected.validate()
        guard WorkspaceValidation.absolute(bundlePath) else { throw ToolchainTrustError.unsafePath }
        var before = stat()
        guard lstat(bundlePath, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw ToolchainTrustError.publisherUnverified
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundlePath) as CFURL,
                                          SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { throw ToolchainTrustError.publisherUnverified }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(expected.teamIdentifier)\" and identifier \"\(expected.signingIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement else { throw ToolchainTrustError.publisherUnverified }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess else {
            throw ToolchainTrustError.publisherUnverified
        }
        var after = stat()
        guard lstat(bundlePath, &after) == 0, before.st_dev == after.st_dev,
              before.st_ino == after.st_ino, before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ToolchainTrustError.unsafePath
        }
    }
}

enum ToolchainHostBundleContract {
    static let bundle = "Host/ScreenpunkBuildHost.app"
    static let service = bundle + "/Contents/XPCServices/ScreenpunkBuildService.xpc"
    static let embeddedKits = service + "/Contents/Resources/AuthoringKit"

    static func validate(_ approved: ApprovedToolchainKit) throws {
        let byPath = Dictionary(uniqueKeysWithValues: approved.entry.inventory.map { ($0.path, $0) })
        guard byPath[bundle + "/Contents/MacOS/ScreenpunkBuildHost"]?.role == "executable",
              byPath[service + "/Contents/MacOS/ScreenpunkBuildService"]?.role == "executable" else {
            throw ToolchainTrustError.inventoryMismatch
        }
        // The embedded name cannot contain inventoryHash: that hash covers these very paths.
        // The future host adapter passes this fixed, catalog-derived name to its private XPC.
        let kitPrefix = embeddedKits + "/" + approved.entry.catalogEntryId + "/"
        for item in approved.entry.inventory where !item.path.hasPrefix("Host/") {
            guard let embedded = byPath[kitPrefix + item.path],
                  embedded.sha256 == item.sha256, embedded.bytes == item.bytes,
                  embedded.role == item.role, embedded.publisher == item.publisher else {
                throw ToolchainTrustError.inventoryMismatch
            }
        }
        for item in approved.entry.inventory where item.path.hasPrefix(embeddedKits + "/") {
            guard item.path.hasPrefix(kitPrefix),
                  let root = byPath[String(item.path.dropFirst(kitPrefix.count))],
                  root.sha256 == item.sha256, root.bytes == item.bytes,
                  root.role == item.role, root.publisher == item.publisher else {
                throw ToolchainTrustError.inventoryMismatch
            }
        }
        guard byPath[kitPrefix + "kit.json"] != nil else { throw ToolchainTrustError.inventoryMismatch }
    }
}
#endif
