import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
final class BuildHostSessionDeadlineTests: XCTestCase {
    func testStalledInputPipeObeysDeadlineAndCancellation() throws {
        let base = URL(fileURLWithPath: "/private/tmp/sp-stalled-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("stalled")
        try Data("#!/usr/bin/python3\nimport time\ntime.sleep(10)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = try BuildHostSession(executable: executable.path, cancelled: { false })
        defer { session.close() }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try session.call(BuildHostWireRequest(action: "upload", jobID: "stall",
            bytes: Data(repeating: 65, count: 256 * 1024)), seconds: 0.25))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)

        let cancelledSession = try BuildHostSession(executable: executable.path, cancelled: { true })
        defer { cancelledSession.close() }
        let cancelStarted = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try cancelledSession.call(BuildHostWireRequest(action: "upload", jobID: "stall",
            bytes: Data(repeating: 65, count: 256 * 1024)), seconds: 5))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelStarted, 2)
    }
}
#endif
