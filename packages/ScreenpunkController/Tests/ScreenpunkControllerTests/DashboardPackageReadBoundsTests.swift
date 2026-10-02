import Darwin
import Foundation
import ScreenpunkCore
import XCTest
@testable import ScreenpunkController

final class DashboardPackageReadBoundsTests: XCTestCase {
    func testValidNestedAssetsRoundTripThroughBudgetedRead() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.getRevision(dashboardId: fixture.record.manifest.dashboardId,
            revision: nil, readBudget: budget())
        XCTAssertEqual(record.files, fixture.record.files)
        XCTAssertEqual(try fixture.store.listDashboards(readBudget: budget()).count, 1)
    }

    func testHostileInventoryRejectedBeforePayloadRead() throws {
        for sizes in [[Int.max, 1], [-1, 1], [PackageLimits.expandedBytes, 1]] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            var manifest = fixture.record.manifest
            for index in manifest.files.indices { manifest.files[index].bytes = sizes[index] }
            try fixture.writeManifest(manifest)
            XCTAssertThrowsError(try fixture.read()) {
                XCTAssertTrue(($0 as? PackageValidationError)?.issues.contains(.sizeLimit) == true)
            }
            XCTAssertEqual(try fixture.store.listDashboards().count, 1)
        }
    }

    func testPayloadLengthMustEqualDeclaredLength() throws {
        for bytes in [Data(), Data(repeating: 120, count: 4096)] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try bytes.write(to: fixture.record.packageDirectory.appendingPathComponent("index.html"))
            assertValidationFailure { _ = try fixture.read() }
        }
    }

    func testMetadataHasSeparateHeadAndManifestCaps() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manifestURL = fixture.record.packageDirectory.appendingPathComponent("manifest.json")
        let originalManifest = try Data(contentsOf: manifestURL)
        try Data(repeating: 32, count: 8_388_609).write(to: manifestURL)
        assertValidationFailure { _ = try fixture.read() }
        try originalManifest.write(to: manifestURL)
        let headURL = fixture.root.appendingPathComponent("dashboards/\(fixture.record.manifest.dashboardId)/head.json")
        try Data(repeating: 32, count: 1_048_577).write(to: headURL)
        assertValidationFailure { _ = try fixture.store.listDashboards() }
    }

    func testFinalPayloadSymlinkIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let path = fixture.record.packageDirectory.appendingPathComponent("index.html")
        let sentinel = fixture.root.appendingPathComponent("outside.html")
        let bytes = fixture.record.files["index.html"]!
        try bytes.write(to: sentinel)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
        assertValidationFailure { _ = try fixture.read() }
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    }

    func testIntermediateDirectorySymlinkIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = fixture.record.packageDirectory.appendingPathComponent("assets")
        let outside = fixture.root.appendingPathComponent("outside-assets")
        try FileManager.default.moveItem(at: directory, to: outside)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        assertValidationFailure { _ = try fixture.read() }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("nested.js")), fixture.record.files["assets/nested.js"])
    }

    func testFIFORejectedWithoutWaitingForWriter() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let path = fixture.record.packageDirectory.appendingPathComponent("index.html")
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(mkfifo(path.path, 0o600), 0)
        let begin = ProcessInfo.processInfo.systemUptime
        assertValidationFailure { _ = try fixture.read() }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 2)
    }

    func testExpiredAndCancelledBudgetsLeaveValidStoreReadable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for budget in [DashboardReadBudget(deadline: 0, cancelled: { false }),
                       DashboardReadBudget(deadline: ProcessInfo.processInfo.systemUptime + 10, cancelled: { true })] {
            assertValidationFailure { _ = try fixture.store.listDashboards(readBudget: budget) }
            assertValidationFailure { _ = try fixture.store.getRevision(dashboardId: fixture.record.manifest.dashboardId,
                revision: nil, readBudget: budget) }
        }
        XCTAssertEqual(try fixture.read().files, fixture.record.files)
    }

    func testHeldFileLockRespectsDeadlineAndReleasesLocalLockOnFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let holder = open(fixture.root.appendingPathComponent("lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(holder, 0)
        guard holder >= 0 else { return }
        defer { _ = flock(holder, LOCK_UN); close(holder) }
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        let begin = ProcessInfo.processInfo.systemUptime
        assertValidationFailure {
            _ = try fixture.store.listDashboards(readBudget: DashboardReadBudget(deadline: begin + 0.15, cancelled: { false }))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 2)
        XCTAssertEqual(flock(holder, LOCK_UN), 0)
        XCTAssertEqual(try fixture.store.listDashboards(readBudget: budget()).count, 1)
        XCTAssertEqual(try fixture.read().files, fixture.record.files)
    }

    private func budget() -> DashboardReadBudget {
        DashboardReadBudget(deadline: ProcessInfo.processInfo.systemUptime + 5, cancelled: { false })
    }

    private func assertValidationFailure(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControllerError)?.code, .validationFailed, file: file, line: line)
        }
    }

    private final class Fixture {
        let root: URL
        let store: DashboardPackageStore
        let record: DashboardRevisionRecord

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("sp-package-read-\(UUID().uuidString)", isDirectory: true)
            store = try DashboardPackageStore(root: root)
            record = try store.putDashboard(dashboardId: nil, name: "Bounded fixture", baseRevision: nil,
                target: fixtureTarget(), connections: [], files: [htmlFile("OK"),
                    DashboardFileInput(path: "assets/nested.js", text: "ok", base64: nil)])
        }

        func read() throws -> DashboardRevisionRecord {
            try store.getRevision(dashboardId: record.manifest.dashboardId, revision: nil)
        }

        func writeManifest(_ manifest: DashboardManifest) throws {
            try JSONEncoder().encode(manifest).write(to: record.packageDirectory.appendingPathComponent("manifest.json"))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
