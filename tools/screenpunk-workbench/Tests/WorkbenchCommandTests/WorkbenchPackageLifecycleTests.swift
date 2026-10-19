import XCTest
import Foundation
import ScreenpunkDistribution
@testable import ScreenpunkController
@testable import WorkbenchCommand

final class WorkbenchPackageLifecycleTests: XCTestCase {
    func testInterruptedLifecycleRefusalPointsToOwnedJobAndSupportedBrewRecovery() {
        XCTAssertThrowsError(try WorkbenchPackageLifecycle.checked {
            throw DistributionError.conflict
        }) { error in
            let failure = error as? CommandFailure
            XCTAssertEqual(failure?.code, "installation_conflict")
            XCTAssertEqual(failure?.details["lifecycleError"], "conflict")
            XCTAssertTrue(failure?.nextActions.joined().contains("launchctl print") == true)
            XCTAssertTrue(failure?.nextActions.joined().contains("brew reinstall") == true)
        }
    }

    func testRemovalRefusalProvidesRetryInstructionsWithoutDestructiveRecovery() {
        let busy = WorkbenchPackageLifecycle.failure(WorkbenchPackageRemovalRefusal.busy)
        XCTAssertEqual(busy.code, "homebrew_service_busy")
        XCTAssertTrue(busy.message.contains("without interrupting jobs"))
        XCTAssertTrue(busy.nextActions.joined().contains("finish"))
        let gui = WorkbenchPackageLifecycle.failure(WorkbenchPackageRemovalRefusal.guiActive)
        XCTAssertEqual(gui.code, "homebrew_gui_active")
        let unknown = WorkbenchPackageLifecycle.failure(WorkbenchPackageRemovalRefusal.guiEvidenceUnavailable)
        XCTAssertEqual(unknown.code, "homebrew_gui_absence_unverified")
        XCTAssertFalse(unknown.nextActions.joined().contains("kill"))
        XCTAssertFalse(unknown.nextActions.joined().contains("purge"))
    }

    func testProductionPackageClassificationRequiresExactSupportedRootAndExecutable() {
        let prefix = "/opt/homebrew/Caskroom/screenpunk-cli/1.0.1/Screenpunk CLI 1.0.1"
        for member in ["bin/screenpunk", "bin/screenpunk-mcp", "libexec/screenpunk-service"] {
            XCTAssertEqual(WorkbenchProductionTrust.homebrewRoot(executable: URL(fileURLWithPath: prefix + "/" + member))?.path, prefix)
        }
        for path in ["/private/tmp/Caskroom/screenpunk-cli/1.0.1/Screenpunk CLI 1.0.1/bin/screenpunk",
                     "/usr/local/Caskroom/screenpunk-cli/1.0.1/Screenpunk CLI 1.0.1/bin/screenpunk",
                     "/opt/homebrew/Caskroom/screenpunk-cli/1.0.1/Screenpunk CLI 1.0.0/bin/screenpunk",
                     prefix + "/other/screenpunk", prefix + "/bin/other"] {
            XCTAssertNil(WorkbenchProductionTrust.homebrewRoot(executable: URL(fileURLWithPath: path)))
        }
    }

    func testStartupErrorRetainsBothCausesAndActionableRecovery() {
        let failure = WorkbenchPackageLifecycle.failure(PackageActivationFailure(
            activation: DistributionError.untrustedRelease, cleanup: DistributionError.unavailable))
        XCTAssertEqual(failure.code, "service_activation_recovery_required")
        XCTAssertEqual(failure.details["activationError"], "untrustedRelease")
        XCTAssertEqual(failure.details["cleanupError"], "unavailable")
        XCTAssertTrue(failure.nextActions.joined().contains("service logs"))
        let recovered = WorkbenchPackageLifecycle.failure(PackageActivationFailure(
            activation: DistributionError.unavailable, cleanup: nil))
        XCTAssertEqual(recovered.code, "service_activation_failed")
        XCTAssertEqual(recovered.details["cleanupError"], "none")
    }

    func testPreActivationJournalFailureIsActionableAndUnknownErrorsAreRedacted() {
        let missing = WorkbenchPackageLifecycle.failure(PackagePreparationFailure(
            underlying: ToolchainTrustError.catalogStateMissing))
        XCTAssertEqual(missing.code, "offline_kit_preparation_failed")
        XCTAssertEqual(missing.details["preparationError"], "catalogStateMissing")
        XCTAssertTrue(missing.nextActions.joined().contains("exact matching catalog journal"))
        XCTAssertFalse(missing.nextActions.joined().contains("reinstall"))
        let opaque = NSError(domain: "private.local.path", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "private credential/path must not be emitted"])
        let redacted = WorkbenchPackageLifecycle.failure(PackagePreparationFailure(underlying: opaque))
        XCTAssertEqual(redacted.details["preparationError"], "unavailable")
        XCTAssertFalse(redacted.message.contains("private"))
        XCTAssertFalse(redacted.details.values.joined().contains("private"))
    }
}
