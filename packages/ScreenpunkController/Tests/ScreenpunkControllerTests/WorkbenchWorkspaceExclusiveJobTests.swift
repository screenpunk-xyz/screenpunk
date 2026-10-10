#if os(macOS)
import XCTest
@testable import ScreenpunkController

final class WorkbenchWorkspaceExclusiveJobTests: XCTestCase {
    func testCopyStatusRecordsMeasuredProgressAndUncertainOutcome() throws {
        let registry = try WorkbenchWorkspaceOperationRegistry()
        let id = UUID().uuidString.lowercased()
        let instance = UUID().uuidString.lowercased()
        try registry.begin(id: id, instanceId: instance,
            method: WorkbenchAuthoringRecoveryMethod.snapshotCreate.rawValue,
            destination: "/private/tmp/screenpunk-copy-status-test",
            workspaceId: UUID().uuidString.lowercased(), selectionGeneration: 1)
        XCTAssertEqual(registry.get(id: id)?.state, "running")
        XCTAssertEqual(try registry.requestCancel(id: id)?.cancellationRequested, true)
        XCTAssertTrue(registry.isCancelRequested(id: id))
        registry.progress(id: id, value: .init(phase: .verifying,
            copiedFiles: 3, totalFiles: 3, copiedBytes: 512, totalBytes: 512))
        try registry.finish(id: id, state: "outcomeUnknown")
        let status = try XCTUnwrap(registry.get(id: id))
        let listed = registry.list(instanceId: instance)
        try listed.validate()
        XCTAssertEqual(listed.operations, [status])
        XCTAssertFalse(listed.complete)
        try status.validate()
        XCTAssertEqual(status.phase, "verifying")
        XCTAssertEqual(status.copiedFiles, 3)
        XCTAssertEqual(status.copiedBytes, 512)
        XCTAssertEqual(status.state, "outcomeUnknown")
        XCTAssertTrue(status.cancellationRequested)
        registry.progress(id: id, value: .init(phase: .complete,
            copiedFiles: 3, totalFiles: 3, copiedBytes: 512, totalBytes: 512))
        XCTAssertEqual(registry.get(id: id), status)
    }

    func testDurableCopyJournalReconcilesInterruptedWriterWithoutReplay() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-copy-journal-" +
            UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("workspace-operation-journal.sqlite").path
        let first = try WorkbenchWorkspaceOperationRegistry(journalPath: path)
        let operationId = UUID().uuidString.lowercased()
        try first.begin(id: operationId, instanceId: UUID().uuidString.lowercased(),
            method: WorkbenchAuthoringRecoveryMethod.snapshotCreate.rawValue,
            destination: root.appendingPathComponent("snapshot").path,
            workspaceId: UUID().uuidString.lowercased(), selectionGeneration: 1)
        first.progress(id: operationId, value: .init(phase: .copying,
            copiedFiles: 1, totalFiles: 2, copiedBytes: 128, totalBytes: 256))
        let restarted = try WorkbenchWorkspaceOperationRegistry(journalPath: path)
        let recovered = try XCTUnwrap(restarted.historical(operationId))
        XCTAssertEqual(recovered.state, "outcomeUnknown")
        XCTAssertEqual(recovered.copiedFiles, 1)
        XCTAssertEqual(recovered.copiedBytes, 128)
        XCTAssertFalse(restarted.isCancelRequested(id: operationId))
        let history = try restarted.history()
        XCTAssertFalse(history.truncated)
        XCTAssertEqual(history.operations.map(\.operationId), [operationId])
        let third = try WorkbenchWorkspaceOperationRegistry(journalPath: path)
        XCTAssertEqual(try third.historical(operationId)?.state, "outcomeUnknown")
    }

    func testCopyOperationIDsStayReservedAndBoundedAcrossReopen() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-copy-id-journal-" +
            UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("workspace-operation-journal.sqlite").path
        let journal = try WorkbenchWorkspaceOperationJournal(path: path,
            reservationLimit: 2)
        func status(_ id: String) -> WorkbenchWorkspaceOperationStatus {
            .init(operationId: id, instanceId: UUID().uuidString.lowercased(),
                method: WorkbenchAuthoringRecoveryMethod.snapshotCreate.rawValue,
                destination: root.appendingPathComponent("snapshot").path)
        }
        let first = status(UUID().uuidString.lowercased())
        try journal.reserve(first)
        try journal.upsert(first.completed("applied"))
        XCTAssertThrowsError(try journal.reserve(first)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        XCTAssertEqual(try journal.get(first.operationId)?.state, "applied")
        let second = status(UUID().uuidString.lowercased())
        try journal.reserve(second)
        try journal.upsert(second.completed("applied"))
        let third = status(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try journal.reserve(third)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .resourceLimit)
        }
        let reopened = try WorkbenchWorkspaceOperationJournal(path: path,
            reservationLimit: 2)
        XCTAssertThrowsError(try reopened.reserve(first)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        XCTAssertThrowsError(try reopened.reserve(third)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .resourceLimit)
        }
        XCTAssertEqual(try reopened.get(first.operationId)?.state, "applied")
    }

    func testExclusiveCopyWaitsForEarlierJobsAndBlocksNewAdmission() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        let earlier = try lifecycle.beginJob(id: "earlier", cancel: {})
        let copy = try lifecycle.beginJob(id: "copy", cancel: {})
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                try lifecycle.beginExclusiveWorkspaceJob(id: "copy", token: copy,
                    timeout: 2)
                entered.signal()
            } catch { }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 0.1), .timedOut)
        lifecycle.finishJob(id: "earlier", token: earlier)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try lifecycle.beginJob(id: "new-writer", cancel: {}))
        lifecycle.endExclusiveWorkspaceJob(id: "copy", token: copy)
        let next = try lifecycle.beginJob(id: "new-writer", cancel: {})
        lifecycle.finishJob(id: "new-writer", token: next)
        lifecycle.finishJob(id: "copy", token: copy)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
    }

    func testDrainCancelsExclusiveJobAndNeverReportsFalseCompletion() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        let cancelled = DispatchSemaphore(value: 0)
        let token = try lifecycle.beginJob(id: "copy", cancel: { cancelled.signal() })
        try lifecycle.beginExclusiveWorkspaceJob(id: "copy", token: token)
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? lifecycle.drain(timeout: 2)
            drained.signal()
        }
        XCTAssertEqual(cancelled.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(drained.wait(timeout: .now() + 0.1), .timedOut)
        lifecycle.finishJob(id: "copy", token: token, completion: .interrupted)
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try lifecycle.beginJob(id: "later", cancel: {}))
    }
}
#endif
