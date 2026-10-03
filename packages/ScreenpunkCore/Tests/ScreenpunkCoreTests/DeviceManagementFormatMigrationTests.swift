import XCTest
@_spi(ManagementMigration) @testable import ScreenpunkCore

final class DeviceManagementFormatMigrationTests: XCTestCase {
    func testMigrationRejectsAbsentFabricatedSourceAndDowngrade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceManagementTransitionStore(directory: root)
        let h = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "old")
        XCTAssertThrowsError(try store.migrateLegacyHistory(expected: h))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try store.save(h)
        XCTAssertThrowsError(try store.migrateLegacyHistory(expected: h.fenced()))
        let target = try store.migrateLegacyHistory(expected: h)
        XCTAssertEqual(try store.loadEvidence(), .formatted(target))
        XCTAssertEqual(try store.migrateLegacyHistory(expected: h), target)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(h))
        XCTAssertThrowsError(try store.recommitLegacyMigration(expected: h))
        XCTAssertEqual(try store.loadEvidence(), .formatted(target))
    }
    func testVersionOneMigrationPreservesExistingDeterministicBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = try DeviceManagementTransitionRecord(transitionID: UUID(), credentialReference: "old", phase: .locallyFenced)
        let store = DeviceManagementTransitionStore(directory: root)
        try JSONEncoder().encode(old).write(to: store.recordURL)
        let interpreted = try XCTUnwrap(store.load())
        let target = try store.migrateLegacyHistory(expected: interpreted)
        XCTAssertEqual(target.transitions, interpreted.transitions)
        XCTAssertEqual(target.credentials[0].credentialGenerationID, interpreted.credentials[0].credentialGenerationID)
        XCTAssertEqual(target.credentials[0].credentialReference, old.credentialReference)
        XCTAssertEqual(target.credentials[0].format, .legacyLocal32)
    }
    func testEveryMigrationFaultRequiresExactRecommitAcrossStoreInstances() throws {
        for point in [DeviceManagementCommitBoundary.afterTemporaryWrite, .afterFileSync, .beforeReplace, .afterReplace, .afterDirectorySync] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let h = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "old")
            let stable = DeviceManagementTransitionStore(directory: root)
            try stable.save(h)
            let failing = DeviceManagementTransitionStore(directory: root, boundary: { if $0 == point { throw DeviceManagementTransitionStoreError.corrupt } })
            XCTAssertThrowsError(try failing.migrateLegacyHistory(expected: h))
            XCTAssertTrue(try stable.hasUncertainLegacyMigration(expected: h))
            XCTAssertThrowsError(try stable.hasUncertainLegacyMigration(expected: h.fenced()))
            XCTAssertThrowsError(try stable.loadEvidence())
            _ = try? stable.diagnosticReadback()
            XCTAssertThrowsError(try stable.loadEvidence())
            XCTAssertThrowsError(try stable.save(h))
            XCTAssertThrowsError(try stable.migrateLegacyHistory(expected: h))
            XCTAssertThrowsError(try stable.recommitLegacyMigration(expected: h.fenced()))
            let target = try stable.recommitLegacyMigration(expected: h)
            XCTAssertEqual(try stable.loadEvidence(), .formatted(target))
            XCTAssertFalse(try stable.hasUncertainLegacyMigration(expected: h))
        }
    }
}
