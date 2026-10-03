import XCTest
import Foundation
import Darwin
import ScreenpunkDistribution
@testable import WorkbenchCommand

final class WorkbenchGUIAbsenceProbeTests: XCTestCase {
    private let uid: uid_t = 503
    private func process(_ pid: Int32 = 20, path: String = "/fixture/cli",
                         started: UInt64 = 100, image: UInt8 = 1) -> WorkbenchGUIAbsenceProbe.ProcessIdentity {
        .init(pid: pid, uid: uid, path: path, started: started, image: Data(repeating: image, count: 16))
    }

    func testStableCompleteInventoryOfOtherProcessesEstablishesAbsence() throws {
        let values = [process(), process(21)]
        var snapshots = 0
        var checks: [Int32] = []
        let probe = WorkbenchGUIAbsenceProbe(uid: uid, snapshot: {
            snapshots += 1
            return snapshots == 1 ? values : values.reversed()
        }, codeIdentity: { checks.append($0.pid); return .other }, applicationPresent: { false })
        try probe.assertAbsent()
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(checks, [20, 21])
    }

    func testEmptyDuplicateForeignOrIncompleteInventoriesDoNotEstablishAbsence() {
        let invalid = WorkbenchGUIAbsenceProbe.ProcessIdentity(pid: 20, uid: 504,
            path: "/fixture/other-user", started: 100, image: Data(repeating: 1, count: 16))
        for values in [[], [process(), process()], [invalid], [process(0)],
                       [process(path: "relative")], [process(started: 0)]] {
            let probe = WorkbenchGUIAbsenceProbe(uid: uid, snapshot: { values },
                codeIdentity: { _ in XCTFail("Invalid inventory must fail before classification"); return .other },
                applicationPresent: { false })
            XCTAssertThrowsError(try probe.assertAbsent())
        }
        let unavailable = WorkbenchGUIAbsenceProbe(uid: uid, snapshot: { throw DistributionError.unavailable },
            codeIdentity: { _ in .other }, applicationPresent: { false })
        XCTAssertThrowsError(try unavailable.assertAbsent())
    }

    func testPresentApprovedUnknownOrLegacyGUIAlwaysBlocks() {
        for verdict in [WorkbenchGUIAbsenceProbe.CodeIdentity.approvedGUI, .unknown] {
            let probe = WorkbenchGUIAbsenceProbe(uid: uid, snapshot: { [self.process()] },
                codeIdentity: { _ in verdict }, applicationPresent: { false })
            XCTAssertThrowsError(try probe.assertAbsent())
        }
        let legacy = WorkbenchGUIAbsenceProbe(uid: uid,
            snapshot: { [self.process(path: "/Applications/Screenpunk.app/Contents/MacOS/Screenpunk")] },
            codeIdentity: { _ in .other }, applicationPresent: { false })
        XCTAssertThrowsError(try legacy.assertAbsent())
        let application = WorkbenchGUIAbsenceProbe(uid: uid, snapshot: {
            XCTFail("Known running application must fail before enumeration"); return []
        }, codeIdentity: { _ in .other }, applicationPresent: { true })
        XCTAssertThrowsError(try application.assertAbsent())
    }

    func testProcessBirthExitPIDReuseOrExecImageChangeInvalidatesEvidence() {
        for replacement in [[process(), process(21)], [], [process(started: 101)],
                            [process(image: 2)], [process(path: "/fixture/new-image")]] {
            var snapshots = 0
            let probe = WorkbenchGUIAbsenceProbe(uid: uid, snapshot: {
                snapshots += 1; return snapshots == 1 ? [self.process()] : replacement
            }, codeIdentity: { _ in .other }, applicationPresent: { false })
            XCTAssertThrowsError(try probe.assertAbsent())
        }
    }

    func testApplicationAppearingDuringCheckAndExpiredEvidenceFailClosed() {
        var appChecks = 0
        let appearing = WorkbenchGUIAbsenceProbe(uid: uid, snapshot: { [self.process()] },
            codeIdentity: { _ in .other }, applicationPresent: {
                appChecks += 1; return appChecks > 1
            })
        XCTAssertThrowsError(try appearing.assertAbsent())
        var time: TimeInterval = 100
        let expired = WorkbenchGUIAbsenceProbe(uid: uid, snapshot: { [self.process()] },
            codeIdentity: { _ in time = 103; return .other }, applicationPresent: { false },
            uptime: { time })
        XCTAssertThrowsError(try expired.assertAbsent())
    }
}
