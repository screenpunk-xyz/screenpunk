import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
final class WorkbenchM4DeploymentLedgerTests: XCTestCase {
    private let planHash = "b8eb5bdec8ea0d01be8e3e0fb208675e329c2a7e4b0dbd390dab6692eb2e8f9e"
    private let contextHash = "537f52ca0ccc7aab4d8b932a4ab563af530eee944294d77375da80e32d420c20"
    private final class Fixture {
        let root: URL
        let path: String
        var clock = WorkbenchDeploymentClock(wallSeconds: 2_000_000_000,
            monotonicMilliseconds: 100_000, bootId: "test-boot")
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/sp-m4-ledger-" + UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            path = root.appendingPathComponent("authority/deployments.sqlite").path
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private func setup(_ ledger: WorkbenchDeploymentLedger, _ fixture: Fixture,
                       planId: String = "plan-1") throws -> WorkbenchDeploymentApprovalRecord {
        let plan = WorkbenchDeploymentPlanRecord(planId: planId, planHash: planHash,
            workspaceId: "workspace-1", deviceId: "device-1", authorizationContextHash: contextHash,
            immutableBodyHash: planHash, materialJSON: Data("{}".utf8), reviewJSON: Data("{}".utf8),
            expiresWallSeconds: fixture.clock.wallSeconds + 1000,
            deadlineMonotonicMilliseconds: fixture.clock.monotonicMilliseconds + 1_000_000,
            bootId: fixture.clock.bootId)
        try ledger.createPlan(plan, clock: fixture.clock)
        let approval = WorkbenchDeploymentApprovalRecord(approvalId: UUID().uuidString.lowercased(),
            planId: planId, planHash: planHash, authorizationContextHash: contextHash,
            consentSource: "terminal_interactive", expiresWallSeconds: plan.expiresWallSeconds,
            deadlineMonotonicMilliseconds: plan.deadlineMonotonicMilliseconds, bootId: fixture.clock.bootId)
        try ledger.approve(approval, clock: fixture.clock, validateCurrent: {})
        return approval
    }

    func testCanonicalPlanAndBodyVectors() throws {
        let body = WorkbenchDeploymentPlanBody(planVersion: 1, planId: "plan-fixture",
            workspaceId: "8ea237eb-b9d1-4dba-803d-0377be9c871f", deviceId: "device-fixture",
            deviceProfileHash: String(repeating: "a", count: 64),
            expectedInstalledSetHash: String(repeating: "b", count: 64),
            packages: [.init(dashboardId: "screen-fixture", sourceRevision: "source-fixture",
                revision: "prepared-fixture", digest: String(repeating: "c", count: 64),
                declaredCapabilities: [], dataDescription: "Unknown")],
            selectedDashboardId: "screen-fixture", removedDashboardIds: [],
            requiredDeclarationsHash: String(repeating: "d", count: 64),
            approvalPolicy: "exact-package-installation-v1", expiresAt: "2026-09-30T12:00:00Z")
        XCTAssertEqual(try WorkbenchDeploymentHash.plan(body), planHash)
        XCTAssertEqual(try WorkbenchDeploymentHash.operationBody(planHash: planHash, contextHash: contextHash),
                       "63e4466c1c95676fb9dede7d47e78c4752b986e21feeccf6bb7fee989f6cf315")
    }

    func testTwentyConcurrentRetriesConsumeOnePlanAndReopenCannotReplay() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let ledger = try WorkbenchDeploymentLedger(path: fixture.path)
        let secondLedger = try WorkbenchDeploymentLedger(path: fixture.path)
        let approval = try setup(ledger, fixture)
        let collectionLock = NSLock()
        var ids: [String] = []; var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                let selected = index.isMultiple(of: 2) ? ledger : secondLedger
                let result = try selected.admit(planId: "plan-1", planHash: planHash, contextHash: contextHash,
                    approvalId: approval.approvalId, idempotencyKey: "same-key", approved: true,
                    clock: fixture.clock, validateCurrent: {})
                collectionLock.lock(); ids.append(result.operationId); collectionLock.unlock()
            } catch {
                collectionLock.lock(); failures.append(String(describing: error)); collectionLock.unlock()
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(Set(ids).count, 1)
        let operationId = try XCTUnwrap(ids.first)
        let secondKey = try ledger.admit(planId: "plan-1", planHash: planHash, contextHash: contextHash,
            approvalId: approval.approvalId, idempotencyKey: "new-key", approved: true,
            clock: fixture.clock, validateCurrent: {})
        XCTAssertEqual(secondKey.operationId, operationId)
        XCTAssertThrowsError(try ledger.admit(planId: "other-plan", planHash: planHash,
            contextHash: contextHash, approvalId: approval.approvalId, idempotencyKey: "same-key",
            approved: true, clock: fixture.clock, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .conflict)
        }
        XCTAssertThrowsError(try ledger.admit(planId: "plan-1", planHash: planHash,
            contextHash: String(repeating: "f", count: 64), approvalId: approval.approvalId,
            idempotencyKey: "same-key", approved: true, clock: fixture.clock, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .conflict)
        }
        let reopened = try WorkbenchDeploymentLedger(path: fixture.path)
        XCTAssertEqual(try reopened.status(operationId).state, .admitted)
        XCTAssertEqual(try reopened.operationForPlan("plan-1").operationId, operationId)
        XCTAssertEqual(try reopened.markSending(operationId: operationId, clock: fixture.clock,
            validateCurrent: {}).state, .sending)
        XCTAssertThrowsError(try reopened.markSending(operationId: operationId,
            clock: fixture.clock, validateCurrent: {}))
        _ = try reopened.updateOutcome(operationId: operationId, state: .unknown)
        XCTAssertEqual(try reopened.cancelPlan("plan-1")?.state, .unknown)
        XCTAssertTrue(try reopened.status(operationId).cancelRequested)
        XCTAssertEqual(try reopened.admit(planId: "plan-1", planHash: planHash, contextHash: contextHash,
            approvalId: approval.approvalId, idempotencyKey: "same-key", approved: true,
            clock: fixture.clock, validateCurrent: {}).state, .unknown)
    }

    func testReadOnlyRecentOperationInventorySurvivesReopenWithoutCreatingLedger() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        XCTAssertThrowsError(try WorkbenchDeploymentLedger(readOnlyPath: fixture.path)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .missing)
        }
        let ledger = try WorkbenchDeploymentLedger(path: fixture.path)
        let approval = try setup(ledger, fixture)
        let admitted = try ledger.admit(planId: "plan-1", planHash: planHash,
            contextHash: contextHash, approvalId: approval.approvalId,
            idempotencyKey: "inventory-key", approved: true,
            clock: fixture.clock, validateCurrent: {})
        let readOnly = try WorkbenchDeploymentLedger(readOnlyPath: fixture.path)
        XCTAssertEqual(try readOnly.recentOperations(limit: 1).map(\.operationId),
            [admitted.operationId])
        XCTAssertEqual(try readOnly.plan(admitted.planId).deviceId, "device-1")
        XCTAssertThrowsError(try readOnly.recentOperations(limit: 130)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .storage)
        }
    }

    func testCancelExpiryAndClockDiscontinuityPreventFirstSend() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let ledger = try WorkbenchDeploymentLedger(path: fixture.path)
        let approval = try setup(ledger, fixture)
        let admitted = try ledger.admit(planId: "plan-1", planHash: planHash, contextHash: contextHash,
            approvalId: approval.approvalId, idempotencyKey: "key", approved: true,
            clock: fixture.clock, validateCurrent: {})
        let cancelled = try ledger.cancelPlan("plan-1")
        XCTAssertEqual(cancelled?.state, .cancelled)
        XCTAssertFalse(cancelled?.sendAttempted ?? true)
        XCTAssertThrowsError(try ledger.markSending(operationId: admitted.operationId,
            clock: fixture.clock, validateCurrent: {}))

        let secondApproval = try setup(ledger, fixture, planId: "plan-2")
        let second = try ledger.admit(planId: "plan-2", planHash: planHash, contextHash: contextHash,
            approvalId: secondApproval.approvalId, idempotencyKey: "key-2", approved: true,
            clock: fixture.clock, validateCurrent: {})
        fixture.clock = .init(wallSeconds: fixture.clock.wallSeconds + 1000,
            monotonicMilliseconds: fixture.clock.monotonicMilliseconds + 1_000_000, bootId: "test-boot")
        XCTAssertEqual(try ledger.markSending(operationId: second.operationId,
            clock: fixture.clock, validateCurrent: {}).state, .cancelled)
        XCTAssertFalse(try ledger.status(second.operationId).sendAttempted)

        let thirdApproval = try setup(ledger, fixture, planId: "plan-3")
        let third = try ledger.admit(planId: "plan-3", planHash: planHash, contextHash: contextHash,
            approvalId: thirdApproval.approvalId, idempotencyKey: "key-3", approved: true,
            clock: fixture.clock, validateCurrent: {})
        let changedBoot = WorkbenchDeploymentClock(wallSeconds: fixture.clock.wallSeconds + 1,
            monotonicMilliseconds: 1, bootId: "new-boot")
        XCTAssertEqual(try ledger.markSending(operationId: third.operationId,
            clock: changedBoot, validateCurrent: {}).state, .cancelled)
        XCTAssertFalse(try ledger.status(third.operationId).sendAttempted)
    }

    func testExpiryAndWallRollbackRejectNewAdmission() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let ledger = try WorkbenchDeploymentLedger(path: fixture.path)
        let approval = try setup(ledger, fixture)
        let before = fixture.clock
        fixture.clock = .init(wallSeconds: before.wallSeconds - 1,
            monotonicMilliseconds: before.monotonicMilliseconds + 1, bootId: before.bootId)
        XCTAssertThrowsError(try ledger.admit(planId: "plan-1", planHash: planHash,
            contextHash: contextHash, approvalId: approval.approvalId, idempotencyKey: "rollback",
            approved: true, clock: fixture.clock, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .clockUncertain)
        }
        fixture.clock = .init(wallSeconds: before.wallSeconds + 1000,
            monotonicMilliseconds: before.monotonicMilliseconds + 1_000_000, bootId: before.bootId)
        XCTAssertThrowsError(try ledger.admit(planId: "plan-1", planHash: planHash,
            contextHash: contextHash, approvalId: approval.approvalId, idempotencyKey: "expired",
            approved: true, clock: fixture.clock, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .invalidApproval)
        }
        XCTAssertThrowsError(try ledger.status("nonexistent")) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .missing)
        }
    }

    func testRejectedClockObservationInvalidatesOnlyTargetConsentAcrossReopen() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let ledger = try WorkbenchDeploymentLedger(path: fixture.path)
        let first = try setup(ledger, fixture)
        let second = try setup(ledger, fixture, planId: "plan-2")
        let base = fixture.clock
        fixture.clock = .init(wallSeconds: base.wallSeconds - 1,
                              monotonicMilliseconds: base.monotonicMilliseconds + 1,
                              bootId: base.bootId)
        XCTAssertThrowsError(try ledger.admit(planId: "plan-1", planHash: planHash,
            contextHash: contextHash, approvalId: first.approvalId, idempotencyKey: "rejected",
            approved: true, clockProvider: { fixture.clock }, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .clockUncertain)
        }
        let reopened = try WorkbenchDeploymentLedger(path: fixture.path)
        fixture.clock = .init(wallSeconds: base.wallSeconds + 1,
                              monotonicMilliseconds: base.monotonicMilliseconds + 1000,
                              bootId: base.bootId)
        XCTAssertThrowsError(try reopened.admit(planId: "plan-1", planHash: planHash,
            contextHash: contextHash, approvalId: first.approvalId, idempotencyKey: "retry",
            approved: true, clockProvider: { fixture.clock }, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .invalidApproval)
        }
        XCTAssertThrowsError(try reopened.admit(planId: "plan-2", planHash: planHash,
            contextHash: contextHash, approvalId: second.approvalId, idempotencyKey: "other",
            approved: true, clockProvider: { fixture.clock }, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .clockUncertain)
        }
    }

    func testFinalClockSampleAfterValidationPreventsFirstSend() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let ledger = try WorkbenchDeploymentLedger(path: fixture.path)
        let approval = try setup(ledger, fixture)
        let admitted = try ledger.admit(planId: "plan-1", planHash: planHash,
            contextHash: contextHash, approvalId: approval.approvalId, idempotencyKey: "one",
            approved: true, clockProvider: { fixture.clock }, validateCurrent: {})
        let base = fixture.clock
        let state = try ledger.markSending(operationId: admitted.operationId,
            clockProvider: { fixture.clock }) {
            fixture.clock = .init(wallSeconds: base.wallSeconds + 1000,
                monotonicMilliseconds: base.monotonicMilliseconds + 1_000_000,
                bootId: base.bootId)
        }
        XCTAssertEqual(state.state, .cancelled)
        XCTAssertFalse(state.sendAttempted)
        XCTAssertEqual(try WorkbenchDeploymentLedger(path: fixture.path).status(admitted.operationId).state, .cancelled)
    }

    func testExpiredAdmissionObservationCannotBeRewoundToReuseApproval() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let ledger = try WorkbenchDeploymentLedger(path: fixture.path)
        let approval = try setup(ledger, fixture)
        let base = fixture.clock
        fixture.clock = .init(wallSeconds: base.wallSeconds + 1000,
                              monotonicMilliseconds: base.monotonicMilliseconds + 1_000_000,
                              bootId: base.bootId)
        XCTAssertThrowsError(try ledger.admit(planId: "plan-1", planHash: planHash,
            contextHash: contextHash, approvalId: approval.approvalId, idempotencyKey: "expired",
            approved: true, clockProvider: { fixture.clock }, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .expired)
        }
        fixture.clock = .init(wallSeconds: base.wallSeconds + 999,
                              monotonicMilliseconds: base.monotonicMilliseconds + 999_000,
                              bootId: base.bootId)
        XCTAssertThrowsError(try WorkbenchDeploymentLedger(path: fixture.path).admit(
            planId: "plan-1", planHash: planHash, contextHash: contextHash,
            approvalId: approval.approvalId, idempotencyKey: "rewind", approved: true,
            clockProvider: { fixture.clock }, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .invalidApproval)
        }
    }

    func testRejectedPlanCreationAndInvalidBusinessPlanPreserveClockMemory() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let ledger = try WorkbenchDeploymentLedger(path: fixture.path)
        let approval = try setup(ledger, fixture)
        let base = fixture.clock
        fixture.clock = .init(wallSeconds: base.wallSeconds + 1,
                              monotonicMilliseconds: base.monotonicMilliseconds + 1,
                              bootId: base.bootId)
        let duplicate = try ledger.plan("plan-1")
        XCTAssertThrowsError(try ledger.createPlan(duplicate, clock: fixture.clock)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .invalidPlan)
        }
        let reopened = try WorkbenchDeploymentLedger(path: fixture.path)
        fixture.clock = .init(wallSeconds: base.wallSeconds,
                              monotonicMilliseconds: base.monotonicMilliseconds + 2,
                              bootId: base.bootId)
        let rejected = WorkbenchDeploymentPlanRecord(planId: "plan-new", planHash: planHash,
            workspaceId: "workspace-1", deviceId: "device-1", authorizationContextHash: contextHash,
            immutableBodyHash: planHash, materialJSON: Data("{}".utf8), reviewJSON: Data("{}".utf8),
            expiresWallSeconds: base.wallSeconds + 60,
            deadlineMonotonicMilliseconds: base.monotonicMilliseconds + 60_000,
            bootId: base.bootId)
        XCTAssertThrowsError(try reopened.createPlan(rejected, clock: fixture.clock)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .clockUncertain)
        }
        XCTAssertThrowsError(try WorkbenchDeploymentLedger(path: fixture.path).plan("plan-new")) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .missing)
        }
        fixture.clock = .init(wallSeconds: base.wallSeconds + 2,
                              monotonicMilliseconds: base.monotonicMilliseconds + 3,
                              bootId: base.bootId)
        XCTAssertThrowsError(try WorkbenchDeploymentLedger(path: fixture.path).admit(
            planId: "plan-1", planHash: planHash, contextHash: contextHash,
            approvalId: approval.approvalId, idempotencyKey: "old-consent", approved: true,
            clock: fixture.clock, validateCurrent: {})) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .clockUncertain)
        }
    }
}
#endif
