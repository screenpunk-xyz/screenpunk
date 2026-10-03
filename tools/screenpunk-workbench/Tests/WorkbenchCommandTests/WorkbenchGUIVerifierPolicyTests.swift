import XCTest
@testable import WorkbenchCommand

final class WorkbenchGUIVerifierPolicyTests: XCTestCase {
    private let productionHome = URL(fileURLWithPath: "/private/tmp/unrelated-controller")
    private let productionRuntime = URL(fileURLWithPath: "/private/tmp/unrelated-runtime")
    private let testHome = URL(fileURLWithPath: "/private/tmp/screenpunk-gui-test-policy/controller-home")
    private let testRuntime = URL(fileURLWithPath: "/private/tmp/screenpunk-gui-test-policy/runtime")

    func testInstalledServiceAdmitsOnlyFixedProductionIdentity() throws {
        let requirement = WorkbenchGUIVerifierPolicy.requirement(executable: true,
            home: productionHome, runtime: productionRuntime, environment: [:])
        XCTAssertEqual(requirement,
            "anchor apple generic and certificate leaf[subject.OU] = \"77KASWDGM6\" and identifier \"xyz.screenpunk.macos\"")
        XCTAssertNotNil(try WorkbenchGUIVerifierPolicy.verifier(executable: true,
            home: productionHome, runtime: productionRuntime, environment: [:]))
        XCTAssertNil(WorkbenchGUIVerifierPolicy.requirement(executable: false,
            home: productionHome, runtime: productionRuntime, environment: [:]))
    }

    func testTestIdentityRequiresExplicitSeparatedDisposablePaths() throws {
        let environment = ["SCREENPUNK_GUI_TEST_ISOLATED": "1"]
        let requirement = WorkbenchGUIVerifierPolicy.requirement(executable: false,
            home: testHome, runtime: testRuntime, environment: environment)
        XCTAssertEqual(requirement,
            "anchor apple generic and certificate leaf[subject.OU] = \"77KASWDGM6\" and identifier \"xyz.screenpunk.macos.gui-test\"")
        XCTAssertNotNil(try WorkbenchGUIVerifierPolicy.verifier(executable: false,
            home: testHome, runtime: testRuntime, environment: environment))
        XCTAssertNil(WorkbenchGUIVerifierPolicy.requirement(executable: false,
            home: testHome, runtime: testRuntime, environment: [:]))
        XCTAssertNil(WorkbenchGUIVerifierPolicy.requirement(executable: false,
            home: productionHome, runtime: testRuntime, environment: environment))
        XCTAssertNil(WorkbenchGUIVerifierPolicy.requirement(executable: false,
            home: testHome, runtime: testHome, environment: environment))
        XCTAssertEqual(WorkbenchGUIVerifierPolicy.requirement(executable: true,
            home: productionHome, runtime: testRuntime, environment: environment),
            WorkbenchGUIVerifierPolicy.requirement(executable: true,
                home: productionHome, runtime: productionRuntime, environment: [:]))
    }
}
