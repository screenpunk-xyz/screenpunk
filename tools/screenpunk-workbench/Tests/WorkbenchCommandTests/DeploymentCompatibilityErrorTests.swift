import XCTest
import Foundation
import ScreenpunkController
@testable import ScreenpunkBrokerMCP

final class DeploymentCompatibilityErrorTests: XCTestCase {
    func testDeterministicPreflightErrorsAreActionableAndNotUncertain() throws {
        for (code, prefix) in [
            (WorkbenchIPCErrorCode.deploymentPackageInvalid, "deployment_package_invalid"),
            (.deploymentTargetMismatch, "deployment_target_mismatch"),
            (.deploymentIdentityInvalid, "deployment_identity_invalid")
        ] {
            let error = WorkbenchIPCError(code)
            let text = LegacyBrokerAdapter.deploymentFailureText(error)
            XCTAssertTrue(text.hasPrefix(prefix + ":"), text)
            XCTAssertTrue(text.contains("before sending"), text)
            XCTAssertNil(LegacyMutationOutcome.uncertain(name: "plan_deployment", arguments: [:],
                error: error, submitted: true))
        }
        XCTAssertTrue(LegacyBrokerAdapter.deploymentFailureText(.init(.deploymentIdentityInvalid)).contains("Keep existing Screen IDs"))
    }
    func testMCPSchemaExplainsLegacyIdentityAndPreparedRevision() throws {
        let bytes = try LegacyBrokerAdapter.deploymentSchema("plan_deployment").data()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("google-tv-test"))
        XCTAssertTrue(text.contains("Preserve this ID"))
        XCTAssertTrue(text.contains("prepared revision returned by prepare_deployment"))
    }

    func testSentUnknownKeepsOriginalPlanInspectionAndNoReplayGuidance() throws {
        let text = try XCTUnwrap(LegacyMutationOutcome.uncertain(name: "apply_deployment",
            arguments: ["planId": "original-plan"], error: WorkbenchIPCError(.remoteOutcomeUnknown), submitted: true))
        XCTAssertTrue(text.contains("original-plan"))
        XCTAssertTrue(text.contains("lookup_deployment"))
        XCTAssertTrue(text.contains("Do not replay it blindly"))
        XCTAssertNil(LegacyMutationOutcome.uncertain(name: "apply_deployment", arguments: [:],
            error: WorkbenchIPCError(.remoteOutcomeUnknown), submitted: false))
    }
}
