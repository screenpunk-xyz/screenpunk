import Foundation
import ScreenpunkController

/// The service chooses its GUI peer requirement from release-owned constants.
/// Neither a wire request nor an environment string can provide a requirement.
enum WorkbenchGUIVerifierPolicy {
    private static let team = "77KASWDGM6"
    private static let productionIdentifier = "xyz.screenpunk.macos"
    private static let testIdentifier = "xyz.screenpunk.macos.gui-test"
    private static let testPrefix = "/private/tmp/screenpunk-gui-test-"

    static var productionRequirement: String { signedRequirement(identifier: productionIdentifier) }

    static func requirement(executable: Bool, home: URL, runtime: URL,
                            environment: [String: String]) -> String? {
        let homePath = home.resolvingSymlinksInPath().path
        let runtimePath = runtime.resolvingSymlinksInPath().path
        if environment["SCREENPUNK_GUI_TEST_ISOLATED"] == "1",
           homePath.hasPrefix(testPrefix), runtimePath.hasPrefix(testPrefix),
           homePath != runtimePath {
            return signedRequirement(identifier: testIdentifier)
        }
        return executable ? productionRequirement : nil
    }

    static func verifier(executable: Bool, home: URL, runtime: URL,
                         environment: [String: String]) throws -> WorkbenchGUIConsumerVerifier? {
        guard let requirement = requirement(executable: executable, home: home,
                                            runtime: runtime, environment: environment) else {
            return nil
        }
        return try WorkbenchSignedGUIConsumerVerifier(requirementText: requirement)
    }

    private static func signedRequirement(identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }
}
