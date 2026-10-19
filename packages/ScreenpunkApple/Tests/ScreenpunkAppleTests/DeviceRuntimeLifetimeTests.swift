import XCTest
@testable import ScreenpunkApple

final class DeviceRuntimeLifetimeTests: XCTestCase {
    @MainActor func testRetirementIsTerminalReentrantAndRegistrationAfterwardsRunsImmediately() {
        let lifetime = DeviceRuntimeLifetime(); var calls = 0
        lifetime.register { calls += 1; lifetime.retire() }
        let removed = lifetime.register { XCTFail("removed callback") }; lifetime.unregister(removed)
        let late = lifetime.guarded { XCTFail("stale callback") }
        lifetime.retire(); lifetime.retire(); late()
        XCTAssertNil(lifetime.register { calls += 1 }); XCTAssertEqual(calls, 2)
        XCTAssertTrue(lifetime.isRetired); XCTAssertFalse(DeviceRuntimeLifetime().isRetired)
    }
    @MainActor func testCancellationIgnoringResultIsDiscardedAfterRetirement() async throws {
        let lifetime = DeviceRuntimeLifetime(); var continuation: CheckedContinuation<Int, Never>?
        var discarded: Int?
        let task = Task { try await lifetime.accept(operation: { await withCheckedContinuation { continuation = $0 } }, discard: { discarded = $0 }) }
        for _ in 0..<100 { if continuation != nil { break }; await Task.yield() }
        XCTAssertNotNil(continuation)
        lifetime.retire(); continuation?.resume(returning: 42)
        let result = try await task.value; XCTAssertNil(result); XCTAssertEqual(discarded, 42)
    }
    @MainActor func testRetiredLifetimeCannotStartAsyncWorkAndCancellationCannotPublish() async throws {
        let lifetime = DeviceRuntimeLifetime(); lifetime.retire()
        let result: Int? = try await lifetime.accept(operation: { XCTFail("late entry"); return 1 }, discard: { _ in })
        XCTAssertNil(result)
        let active = DeviceRuntimeLifetime(); var continuation: CheckedContinuation<Int, Never>?
        var discarded = false
        let task = Task { try await active.accept(operation: { await withCheckedContinuation { continuation = $0 } }, discard: { _ in discarded = true }) }
        for _ in 0..<100 { if continuation != nil { break }; await Task.yield() }
        task.cancel(); continuation?.resume(returning: 1)
        let cancelled = try await task.value; XCTAssertNil(cancelled); XCTAssertTrue(discarded); XCTAssertFalse(active.isRetired)
    }
}
