import XCTest
import ScreenpunkController
@testable import WorkbenchCommand

final class WorkbenchCloudOriginResolverTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/Screenpunk.app")
    private let trusted = "https://staging.screenpunk.xyz"
    private let ambient = ["SCREENPUNK_CLOUD_BASE_URL": "https://attacker.invalid", "SCREENPUNK_CLOUD_AUTHORIZE_URL": "https://attacker.invalid/auth"]
    private var helper: URL { app.appendingPathComponent("Contents/MacOS/screenpunk-service") }
    private func code(_ url: URL, app: Bool = false, identifier: String? = nil, team: String? = "77KASWDGM6", origin: String? = "https://staging.screenpunk.xyz") -> WorkbenchCloudOriginResolver.SignedCode {
        var plist: [String: Any] = ["ScreenpunkWorkbenchOwnershipProtocol": "workbench-owner-lock-v1"]
        if app { plist["CFBundleIdentifier"] = "xyz.screenpunk.macos"; plist["ScreenpunkCloudAPIOrigin"] = origin }
        return .init(identifier: identifier ?? (app ? "xyz.screenpunk.macos" : "xyz.screenpunk.workbench.tool"), team: team, executable: url, plist: plist)
    }
    private func inputs(executable: URL? = nil,
                        helper: ((URL) throws -> WorkbenchCloudOriginResolver.SignedCode)? = nil,
                        app: ((URL) throws -> WorkbenchCloudOriginResolver.SignedCode)? = nil) -> WorkbenchCloudOriginResolver.Inputs {
        .init(executable: executable ?? self.helper, homebrewRoot: { _ in nil },
            homebrewConfiguration: { _ in XCTFail("Unexpected Homebrew read"); throw ControllerCloudError.invalidConfiguration },
            runningHelper: helper ?? { self.code($0) }, containingApp: app ?? { self.code($0, app: true) })
    }
    func testExactEmbeddedRunningHelpersUseSignedOriginAndDropAmbientOverrides() throws {
        for name in ["screenpunk-service", "screenpunk-workbench", "screenpunk-broker-mcp"] {
            XCTAssertEqual(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient,
                inputs: inputs(executable: app.appendingPathComponent("Contents/MacOS/" + name))), ["SCREENPUNK_CLOUD_BASE_URL": trusted])
        }
    }
    func testMissingUnsignedOrWrongRunningHelperFailsClosed() {
        let bad: [(URL) throws -> WorkbenchCloudOriginResolver.SignedCode] = [
            { _ in throw ControllerCloudError.invalidConfiguration },
            { self.code($0, identifier: "wrong.helper") },
            { self.code($0, team: "wrong-team") },
            { _ in self.code(URL(fileURLWithPath: "/tmp/copied-helper")) },
            { self.code($0, team: nil) },
        ]
        for verify in bad { XCTAssertThrowsError(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient, inputs: inputs(helper: verify))) }
    }
    func testMissingUnsignedWrongAppOrTeamFailsClosed() {
        let bad: [(URL) throws -> WorkbenchCloudOriginResolver.SignedCode] = [
            { _ in throw ControllerCloudError.invalidConfiguration },
            { self.code($0, app: true, identifier: "wrong.app") },
            { self.code($0, app: true, team: "wrong-team") },
            { self.code($0, app: true, origin: nil) },
            { self.code($0, app: true, origin: "") },
        ]
        for verify in bad { XCTAssertThrowsError(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient, inputs: inputs(app: verify))) }
    }
    func testUnsignedOwnershipAndForgedParentPlistAreNotOrigins() {
        var missing = code(helper)
        missing = .init(identifier: missing.identifier, team: missing.team, executable: missing.executable, plist: [:])
        XCTAssertThrowsError(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient, inputs: inputs(helper: { _ in missing })))
        XCTAssertThrowsError(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient,
            inputs: inputs(executable: app.appendingPathComponent("Contents/Helpers/screenpunk-service"))))
        XCTAssertThrowsError(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient,
            inputs: inputs(executable: app.appendingPathComponent("Contents/MacOS/forged-helper"))))
    }
    func testMalformedInstalledLayoutsNeverFallBackToDevelopmentOverrides() {
        for path in ["/Applications/Screenpunk.APP/Contents/Helpers/screenpunk-service",
                     "/opt/homebrew/Caskroom/screenpunk-cli/broken/libexec/screenpunk-service"] {
            XCTAssertThrowsError(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient,
                inputs: inputs(executable: URL(fileURLWithPath: path))))
        }
    }
    func testVerifiedHomebrewUsesMeasuredConfigurationWithoutAppLookup() throws {
        let input = WorkbenchCloudOriginResolver.Inputs(executable: URL(fileURLWithPath: "/opt/homebrew/bin/screenpunk"),
            homebrewRoot: { _ in URL(fileURLWithPath: "/verified/package") },
            homebrewConfiguration: { _ in Data(#"{"schemaVersion":1,"apiOrigin":"https://staging.screenpunk.xyz"}"#.utf8) },
            runningHelper: { _ in XCTFail("Not embedded"); throw ControllerCloudError.invalidConfiguration },
            containingApp: { _ in XCTFail("Not embedded"); throw ControllerCloudError.invalidConfiguration })
        XCTAssertEqual(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient, inputs: input), ["SCREENPUNK_CLOUD_BASE_URL": trusted])
    }
    func testUnverifiedHomebrewFailsInsteadOfUsingAmbientOverride() {
        let input = WorkbenchCloudOriginResolver.Inputs(executable: URL(fileURLWithPath: "/opt/homebrew/bin/screenpunk"),
            homebrewRoot: { _ in URL(fileURLWithPath: "/verified/package") },
            homebrewConfiguration: { _ in throw ControllerCloudError.invalidConfiguration },
            runningHelper: { self.code($0) }, containingApp: { self.code($0, app: true) })
        XCTAssertThrowsError(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient, inputs: input))
    }
    func testExplicitDevelopmentConfigurationIsPreservedOutsideInstalledLayouts() throws {
        XCTAssertEqual(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient,
            inputs: inputs(executable: URL(fileURLWithPath: "/private/tmp/source/.build/debug/screenpunk-service"))), ambient)
        XCTAssertThrowsError(try WorkbenchCloudOriginResolver.deploymentEnvironment(ambient,
            inputs: .init(executable: nil, homebrewRoot: { _ in nil }, homebrewConfiguration: { _ in Data() }, runningHelper: { self.code($0) }, containingApp: { self.code($0, app: true) })))
    }
}
