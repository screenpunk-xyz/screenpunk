import Foundation
import Security
import ScreenpunkController
import ScreenpunkDistribution

/// Installed origin policy belongs to the authenticated release, never to the
/// caller's environment or an arbitrary ancestor Info.plist.
enum WorkbenchCloudOriginResolver {
    struct SignedCode {
        let identifier: String?
        let team: String?
        let executable: URL?
        let plist: [String: Any]
    }
    struct Inputs {
        let executable: URL?
        let homebrewRoot: (URL) -> URL?
        let homebrewConfiguration: (URL) throws -> Data
        let runningHelper: (URL) throws -> SignedCode
        let containingApp: (URL) throws -> SignedCode
    }
    private static let appIdentifier = "xyz.screenpunk.macos"
    private static let helperIdentifier = "xyz.screenpunk.workbench.tool"
    private static let ownershipProtocol = "workbench-owner-lock-v1"
    private static let helperNames = ["screenpunk-service", "screenpunk-workbench", "screenpunk-broker-mcp"]

    static func deploymentEnvironment(_ environment: [String: String]) throws -> [String: String] {
        try deploymentEnvironment(environment, inputs: .init(
            executable: Bundle.main.executableURL,
            homebrewRoot: { WorkbenchProductionTrust.homebrewRoot(executable: $0) },
            homebrewConfiguration: { root in
                _ = try WorkbenchProductionTrust.verifyPackage(root)
                return try Data(contentsOf: root.appendingPathComponent("Resources/Cloud/controller.json"))
            }, runningHelper: signedRunningHelper, containingApp: signedContainingApp))
    }

    static func deploymentEnvironment(_ environment: [String: String], inputs: Inputs) throws -> [String: String] {
        guard let invoked = inputs.executable else {
            throw ControllerCloudError.invalidConfiguration
        }
        let executable = invoked.resolvingSymlinksInPath()
        if let root = inputs.homebrewRoot(executable) {
            let raw = try inputs.homebrewConfiguration(root)
            guard let config = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  config["schemaVersion"] as? Int == 1,
                  let origin = config["apiOrigin"] as? String, !origin.isEmpty else {
                throw ControllerCloudError.invalidConfiguration
            }
            return ["SCREENPUNK_CLOUD_BASE_URL": origin]
        }
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        if app.pathExtension.lowercased() == "app" && contents.lastPathComponent == "Contents" &&
            macOS.lastPathComponent == "MacOS" && helperNames.contains(executable.lastPathComponent) {
            let helper = try inputs.runningHelper(executable)
            let application = try inputs.containingApp(app)
            guard helper.identifier == helperIdentifier,
                  helper.team == ScreenpunkProductionReleaseTrust.teamIdentifier,
                  helper.executable?.resolvingSymlinksInPath() == executable,
                  helper.plist["ScreenpunkWorkbenchOwnershipProtocol"] as? String == ownershipProtocol,
                  application.identifier == appIdentifier,
                  application.team == ScreenpunkProductionReleaseTrust.teamIdentifier,
                  application.plist["CFBundleIdentifier"] as? String == appIdentifier,
                  application.plist["ScreenpunkWorkbenchOwnershipProtocol"] as? String == ownershipProtocol,
                  let origin = application.plist["ScreenpunkCloudAPIOrigin"] as? String,
                  !origin.isEmpty else { throw ControllerCloudError.invalidConfiguration }
            return ["SCREENPUNK_CLOUD_BASE_URL": origin]
        }
        // A malformed/unsupported embedded path is not a development override.
        guard ![invoked, executable].contains(where: { path in
            path.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) ||
                path.path.hasPrefix("/opt/homebrew/Caskroom/screenpunk-cli/")
        }) else {
            throw ControllerCloudError.invalidConfiguration
        }
        // Foreground source builds retain their explicit development configuration.
        // The facade still validates the origin and discovers maintained metadata.
        return environment
    }

    private static func requirement(_ identifier: String) throws -> SecRequirement {
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(ScreenpunkProductionReleaseTrust.teamIdentifier)\" and identifier \"\(identifier)\""
        var value: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &value) == errSecSuccess,
              let value else { throw ControllerCloudError.invalidConfiguration }
        return value
    }
    private static func information(_ code: SecStaticCode) throws -> SignedCode {
        var value: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &value) == errSecSuccess,
              let signed = value as? [String: Any],
              let plist = signed[kSecCodeInfoPList as String] as? [String: Any] else {
            throw ControllerCloudError.invalidConfiguration
        }
        return .init(identifier: signed[kSecCodeInfoIdentifier as String] as? String,
            team: signed[kSecCodeInfoTeamIdentifier as String] as? String,
            executable: signed[kSecCodeInfoMainExecutable as String] as? URL, plist: plist)
    }
    private static func signedRunningHelper(_ expected: URL) throws -> SignedCode {
        let required = try requirement(helperIdentifier)
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], required) == errSecSuccess else {
            throw ControllerCloudError.invalidConfiguration
        }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), required) == errSecSuccess else {
            throw ControllerCloudError.invalidConfiguration
        }
        let signed = try information(code)
        guard signed.executable?.resolvingSymlinksInPath() == expected else {
            throw ControllerCloudError.invalidConfiguration
        }
        return signed
    }
    private static func signedContainingApp(_ app: URL) throws -> SignedCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), try requirement(appIdentifier)) == errSecSuccess else {
            throw ControllerCloudError.invalidConfiguration
        }
        return try information(code)
    }
}
