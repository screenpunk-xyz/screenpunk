#if os(macOS)
import XCTest
@testable import ScreenpunkController

final class WorkbenchServiceLifecycleTests: XCTestCase {
    func testRemovalRefusesActiveJobWithoutCancellingOrClosingAdmission() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        var cancellations = 0
        let job = try lifecycle.beginJob(id: "build-1", cancel: { cancellations += 1 })
        XCTAssertThrowsError(try lifecycle.prepareRemoval(owner: UUID()))
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(lifecycle.snapshot().state, .busy)
        let other = try lifecycle.beginJob(id: "read-2", cancel: {})
        lifecycle.finishJob(id: "read-2", token: other)
        lifecycle.finishJob(id: "build-1", token: job)
        XCTAssertEqual(lifecycle.snapshot().state, .healthy)
    }

    func testRemovalRefusesRegisteredGUIAndThenSucceedsAfterRelease() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        let gui = UUID().uuidString
        try lifecycle.registerVerifiedGUIConsumer(gui)
        XCTAssertThrowsError(try lifecycle.prepareRemoval(owner: UUID()))
        XCTAssertEqual(lifecycle.snapshot().state, .busy)
        lifecycle.releaseVerifiedGUIConsumer(gui)
        try lifecycle.prepareRemoval(owner: UUID())
        XCTAssertEqual(lifecycle.snapshot().state, .draining)
    }

    func testOnlyReservationOwnerCanCommitOrReleaseAndDrainCannotStealIt() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        let owner = UUID(), other = UUID()
        try lifecycle.prepareRemoval(owner: owner)
        XCTAssertThrowsError(try lifecycle.beginJob(id: "new-job", cancel: {}))
        XCTAssertThrowsError(try lifecycle.registerVerifiedGUIConsumer(UUID().uuidString))
        XCTAssertThrowsError(try lifecycle.prepareRemoval(owner: other))
        XCTAssertThrowsError(try lifecycle.drain(timeout: 1))
        XCTAssertThrowsError(try lifecycle.commitRemoval(owner: other))
        lifecycle.cancelPreparedRemoval(owner: other)
        XCTAssertEqual(lifecycle.snapshot().state, .draining)
        lifecycle.cancelPreparedRemoval(owner: owner)
        XCTAssertEqual(lifecycle.snapshot().state, .healthy)
        let job = try lifecycle.beginJob(id: "new-job", cancel: {})
        lifecycle.finishJob(id: "new-job", token: job)
    }

    func testHungRemovalExpiresAndOldOwnerCannotCommitOrCancelReplacement() throws {
        var time: TimeInterval = 100
        let lifecycle = WorkbenchServiceLifecycle(uptime: { time })
        let owner = UUID(), replacement = UUID()
        try lifecycle.prepareRemoval(owner: owner)
        time = 110
        XCTAssertThrowsError(try lifecycle.commitRemoval(owner: owner))
        XCTAssertEqual(lifecycle.snapshot().state, .healthy)
        try lifecycle.prepareRemoval(owner: replacement)
        lifecycle.cancelPreparedRemoval(owner: owner)
        XCTAssertEqual(lifecycle.snapshot().state, .draining)
        try lifecycle.commitRemoval(owner: replacement)
        time = 200
        XCTAssertEqual(lifecycle.snapshot().state, .draining, "Committed shutdown must remain closed")
    }

    func testFailedStopResponseCanAbortCommitBeforeShutdown() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        let owner = UUID()
        try lifecycle.prepareRemoval(owner: owner)
        try lifecycle.commitRemoval(owner: owner)
        lifecycle.cancelPreparedRemoval(owner: owner)
        XCTAssertEqual(lifecycle.snapshot().state, .healthy)
        try lifecycle.prepareRemoval(owner: UUID())
    }

    func testRemovalNeverResumesAnEarlierExplicitDrain() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        XCTAssertEqual(try lifecycle.drain(timeout: 1), [])
        let owner = UUID()
        XCTAssertThrowsError(try lifecycle.prepareRemoval(owner: owner))
        lifecycle.cancelPreparedRemoval(owner: owner)
        XCTAssertEqual(lifecycle.snapshot().state, .draining)
    }

    func testRemovalAdmissionAndJobAdmissionArbitrateOnSameLock() throws {
        for _ in 0..<100 {
            let lifecycle = WorkbenchServiceLifecycle()
            let owner = UUID(), group = DispatchGroup(), resultLock = NSLock()
            var token: UUID?, prepared = false
            group.enter()
            DispatchQueue.global().async {
                let result = try? lifecycle.beginJob(id: "racing-job", cancel: { XCTFail("Must never cancel") })
                resultLock.lock(); token = result; resultLock.unlock(); group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                let result = (try? lifecycle.prepareRemoval(owner: owner)) != nil
                resultLock.lock(); prepared = result; resultLock.unlock(); group.leave()
            }
            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
            XCTAssertNotEqual(token != nil, prepared, "Exactly one admission must succeed")
            if let token { lifecycle.finishJob(id: "racing-job", token: token) }
            lifecycle.cancelPreparedRemoval(owner: owner)
            XCTAssertEqual(lifecycle.snapshot().state, .healthy)
        }
    }

    func testVerifiedGUILeaseExpiresAndDrainWaitsForRelease() throws {
        var time: TimeInterval = 100
        let lifecycle = WorkbenchServiceLifecycle(uptime: { time })
        XCTAssertEqual(lifecycle.snapshot().guiConsumers, .unknown)
        let id = UUID().uuidString.lowercased()
        try lifecycle.registerVerifiedGUIConsumer(id)
        XCTAssertEqual(lifecycle.snapshot().guiConsumers, .verified([id]))
        time = 120
        try lifecycle.renewVerifiedGUIConsumer(id)
        time = 149
        XCTAssertEqual(lifecycle.snapshot().guiConsumers, .verified([id]))
        time = 151
        XCTAssertEqual(lifecycle.snapshot().guiConsumers, .verified([]))
        XCTAssertThrowsError(try lifecycle.renewVerifiedGUIConsumer(id))
        try lifecycle.registerVerifiedGUIConsumer(id)
        let drained = DispatchSemaphore(value: 0)
        var drainResult: Swift.Result<[String], Error>?
        DispatchQueue.global().async {
            drainResult = Swift.Result { try lifecycle.drain(timeout: 1) }
            drained.signal()
        }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, lifecycle.snapshot().state != .draining {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(lifecycle.snapshot().state, .draining)
        XCTAssertEqual(drained.wait(timeout: .now() + 0.02), .timedOut)
        lifecycle.releaseVerifiedGUIConsumer(id)
        XCTAssertEqual(drained.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(try drainResult?.get(), [])
        XCTAssertEqual(lifecycle.snapshot().guiConsumers, .verified([]))
        XCTAssertThrowsError(try lifecycle.registerVerifiedGUIConsumer(UUID().uuidString))
    }

    func testDrainCancelsAndWaitsForExactActiveJob() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        let cancelled = expectation(description: "job cancelled")
        var token: UUID?
        token = try lifecycle.beginJob(id: "build-1", cancel: {
            cancelled.fulfill()
            lifecycle.finishJob(id: "build-1", token: token!, completion: .interrupted)
        })
        XCTAssertEqual(lifecycle.snapshot().state, .busy)
        XCTAssertEqual(try lifecycle.drain(timeout: 2), ["build-1"])
        wait(for: [cancelled], timeout: 2)
        XCTAssertEqual(lifecycle.snapshot().state, .draining)
        XCTAssertThrowsError(try lifecycle.beginJob(id: "build-2", cancel: {})) {
            XCTAssertEqual($0 as? WorkbenchServiceLifecycleError, .draining)
        }
    }

    func testTimedOutDrainRemainsClosedAndDoesNotClaimCompletion() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        let token = try lifecycle.beginJob(id: "deploy-1", cancel: {})
        XCTAssertThrowsError(try lifecycle.drain(timeout: 0.02)) {
            XCTAssertEqual($0 as? WorkbenchServiceLifecycleError, .busy)
        }
        XCTAssertEqual(lifecycle.snapshot().activeJobIDs, ["deploy-1"])
        XCTAssertThrowsError(try lifecycle.beginJob(id: "build-2", cancel: {}))
        lifecycle.finishJob(id: "deploy-1", token: token)
        XCTAssertEqual(try lifecycle.drain(timeout: 1), [])
    }

    func testCompletedJobDuringDrainIsNotReportedInterrupted() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        var token: UUID?
        token = try lifecycle.beginJob(id: "read-1", cancel: {
            lifecycle.finishJob(id: "read-1", token: token!, completion: .completed)
        })
        XCTAssertEqual(try lifecycle.drain(timeout: 1), [])
    }

    func testIdleRequiresVerifiedEmptyConsumersAndNoClientsOrJobs() throws {
        var time: TimeInterval = 100
        let lifecycle = WorkbenchServiceLifecycle(uptime: { time })
        time = 200
        XCTAssertFalse(lifecycle.mayExitIdle(after: 30), "unknown GUI ownership blocks idle exit")
        lifecycle.setGUIConsumerEvidence(.verified(["trusted-gui"]))
        time = 240
        XCTAssertFalse(lifecycle.mayExitIdle(after: 30))
        lifecycle.setGUIConsumerEvidence(.verified([]))
        lifecycle.authenticatedConnectionOpened()
        time = 300
        XCTAssertFalse(lifecycle.mayExitIdle(after: 30))
        lifecycle.authenticatedConnectionClosed()
        let token = try lifecycle.beginJob(id: "build-1", cancel: {})
        time = 340
        XCTAssertFalse(lifecycle.mayExitIdle(after: 30))
        lifecycle.finishJob(id: "build-1", token: token)
        time = 369
        XCTAssertFalse(lifecycle.mayExitIdle(after: 30))
        time = 370
        XCTAssertTrue(lifecycle.mayExitIdle(after: 30))
    }

    func testJobTokensCannotFinishReplacement() throws {
        let lifecycle = WorkbenchServiceLifecycle()
        let first = try lifecycle.beginJob(id: "same", cancel: {})
        XCTAssertThrowsError(try lifecycle.beginJob(id: "same", cancel: {}))
        lifecycle.finishJob(id: "same", token: first)
        let second = try lifecycle.beginJob(id: "same", cancel: {})
        lifecycle.finishJob(id: "same", token: first)
        XCTAssertEqual(lifecycle.snapshot().activeJobIDs, ["same"])
        lifecycle.finishJob(id: "same", token: second)
        XCTAssertTrue(lifecycle.snapshot().activeJobIDs.isEmpty)
    }
}
#endif
