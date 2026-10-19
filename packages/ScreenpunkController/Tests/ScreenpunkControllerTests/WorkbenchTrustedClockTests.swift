import XCTest
@testable import ScreenpunkController

#if os(macOS)
final class WorkbenchTrustedClockTests: XCTestCase {
    private let boot = "5A9D53CF-34FA-42C8-9BCA-23FFD9C46FF8"

    func testCoherentBootWallAndSleepInclusiveMonotonicUnits() {
        let clock = WorkbenchTrustedClock(source: .init(
            bootSessionID: { self.boot }, wallTime: { 2_000_000_000.75 },
            monotonicNanoseconds: { 100_123_456_789 })).sample()
        XCTAssertEqual(clock.wallSeconds, 2_000_000_000)
        XCTAssertEqual(clock.monotonicMilliseconds, 100_123)
        XCTAssertEqual(clock.bootId, boot.lowercased())
    }

    func testUnavailableOrChangingSystemObservationsFailClosed() {
        var bootReads = [boot, UUID().uuidString]
        let changed = WorkbenchTrustedClock(source: .init(
            bootSessionID: { bootReads.removeFirst() }, wallTime: { 2_000_000_000 },
            monotonicNanoseconds: { 100_000_000_000 })).sample()
        XCTAssertEqual(changed.bootId, "")
        XCTAssertEqual(changed.monotonicMilliseconds, -1)
        for source in [
            WorkbenchTrustedClock.Source(bootSessionID: { nil }, wallTime: { 2_000_000_000 },
                monotonicNanoseconds: { 100_000_000_000 }),
            .init(bootSessionID: { self.boot }, wallTime: { .nan },
                monotonicNanoseconds: { 100_000_000_000 }),
            .init(bootSessionID: { self.boot }, wallTime: { 2_000_000_000 },
                monotonicNanoseconds: { nil })
        ] {
            let sample = WorkbenchTrustedClock(source: source).sample()
            XCTAssertEqual(sample.wallSeconds, 0)
            XCTAssertEqual(sample.monotonicMilliseconds, -1)
            XCTAssertEqual(sample.bootId, "")
        }
    }
}
#endif
