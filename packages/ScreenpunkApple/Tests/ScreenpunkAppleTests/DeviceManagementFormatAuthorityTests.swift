import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class DeviceManagementFormatAuthorityTests: XCTestCase {
    func testMigrationRevokesOldLeaseRequiresRefreshAndRetainsFences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DeviceManagementTransitionStore(directory: root), backend = FormatInventoryBackend()
        let intent = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "legacy")
        let h = try intent.fenced()
        try journal.save(intent); try journal.save(h); backend.values["legacy"] = Data(repeating: 7, count: 32)
        let keys = CloudInstallationCredentialStore(backend: backend, random: { fatalError("No insertion") })
        let owner = DeviceManagementAuthority(journal: journal, credentials: keys, reset: ManagementTestResetEvidence())
        let old = try XCTUnwrap(owner.refresh())
        try owner.migrateLegacyHistory(expected: h)
        XCTAssertThrowsError(try owner.withLocalAuthority(old) {})
        let fresh = try XCTUnwrap(owner.refresh())
        try owner.withLocalAuthority(fresh) {}
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: keys), .locallyFenced)
        XCTAssertThrowsError(try CloudInstallationRecovery.stageCredential(h, credentialGenerationID: h.credentials[0].credentialGenerationID, journal: journal, credentials: keys))
        XCTAssertEqual(backend.values["legacy"], Data(repeating: 7, count: 32))
        XCTAssertEqual(backend.inserts, 0)
        // Restored legacy evidence cannot lower the in-process observed schema.
        try JSONEncoder().encode(h).write(to: journal.recordURL)
        XCTAssertNil(try owner.refresh())
    }
    func testOwnerExactRecommitAfterDiskFailureNeverReturnsOldAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let journal = DeviceManagementTransitionStore(directory: root), backend = FormatInventoryBackend()
        let intent = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "legacy")
        try journal.save(intent)
        let h = try intent.fenced(); try journal.save(h)
        backend.values["legacy"] = Data(repeating: 7, count: 32)
        let keys = CloudInstallationCredentialStore(backend: backend, random: { fatalError("No insertion") })
        let owner = DeviceManagementAuthority(journal: journal, credentials: keys, reset: ManagementTestResetEvidence())
        let old = try XCTUnwrap(owner.refresh())
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try owner.migrateLegacyHistory(expected: h))
        XCTAssertNil(try owner.refresh())
        XCTAssertThrowsError(try owner.withLocalAuthority(old) {})
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        XCTAssertThrowsError(try owner.recommitLegacyMigration(expected: intent))
        try owner.recommitLegacyMigration(expected: h)
        XCTAssertThrowsError(try owner.withLocalAuthority(old) {})
        let fresh = try XCTUnwrap(owner.refresh()); try owner.withLocalAuthority(fresh) {}
    }
    func testPreparedRetryAfterLockFailureAndAcknowledgedRetryAfterInventoryFailure() throws {
        for postCommit in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let journal = DeviceManagementTransitionStore(directory: root), backend = FormatInventoryBackend()
            let intent = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "legacy")
            try journal.save(intent)
            let h = try intent.fenced(); try journal.save(h)
            backend.values["legacy"] = Data(repeating: 7, count: 32)
            let keys = CloudInstallationCredentialStore(backend: backend, random: { fatalError("No insertion") })
            let owner = DeviceManagementAuthority(journal: journal, credentials: keys, reset: ManagementTestResetEvidence())
            let old = try XCTUnwrap(owner.refresh())
            let lock = root.appendingPathComponent("management-transition.lock")
            if postCommit {
                backend.referenceCalls = 0; backend.failReferenceCall = 4
            } else {
                backend.referenceCalls = 0
                backend.onReferenceCall = { call in
                    if call == 3 {
                        try FileManager.default.removeItem(at: lock)
                        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: root.appendingPathComponent("missing-lock"))
                    }
                }
            }
            XCTAssertThrowsError(try owner.migrateLegacyHistory(expected: h))
            XCTAssertNil(try owner.refresh())
            XCTAssertThrowsError(try owner.withLocalAuthority(old) {})
            let committedBytes = try Data(contentsOf: journal.recordURL)
            let committedDate = try FileManager.default.attributesOfItem(atPath: journal.recordURL.path)[.modificationDate] as? Date
            if !postCommit { try FileManager.default.removeItem(at: lock) }
            backend.failReferenceCall = nil; backend.onReferenceCall = nil
            try owner.recommitLegacyMigration(expected: h)
            if postCommit {
                XCTAssertEqual(try Data(contentsOf: journal.recordURL), committedBytes)
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.recordURL.path)[.modificationDate] as? Date, committedDate, "Acknowledged retry never rewrites")
            }
            XCTAssertThrowsError(try owner.withLocalAuthority(old) {})
            let fresh = try XCTUnwrap(owner.refresh()); try owner.withLocalAuthority(fresh) {}
        }
    }
    func testFormattedLegacyOrphanRemainsQuarantinedAfterItsRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DeviceManagementTransitionStore(directory: root), backend = FormatInventoryBackend()
        let intent = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "legacy")
        try journal.save(intent)
        let h = try intent.fenced(); try journal.save(h)
        backend.values["legacy"] = Data(repeating: 7, count: 32)
        let keys = CloudInstallationCredentialStore(backend: backend, random: { fatalError("No insertion") })
        let owner = DeviceManagementAuthority(journal: journal, credentials: keys, reset: ManagementTestResetEvidence())
        try owner.migrateLegacyHistory(expected: h)
        let lease = try XCTUnwrap(owner.refresh())
        backend.values["orphan"] = Data(repeating: 1, count: 48)
        XCTAssertThrowsError(try owner.withLocalAuthority(lease) {})
        backend.values.removeValue(forKey: "orphan")
        XCTAssertNil(try owner.refresh(), "Removing observed orphan cannot reopen formatted Local authority")
    }
    func testFinalRawSnapshotAndMigrationOrphanChangesRemainQuarantined() throws {
        for migration in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let journal = DeviceManagementTransitionStore(directory: root), backend = FormatInventoryBackend()
            let intent = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "legacy")
            try journal.save(intent)
            let h = try intent.fenced(); try journal.save(h)
            backend.values["legacy"] = Data(repeating: 7, count: 32)
            let keys = CloudInstallationCredentialStore(backend: backend, random: { fatalError("No insertion") })
            let owner = DeviceManagementAuthority(journal: journal, credentials: keys, reset: ManagementTestResetEvidence())
            let lease = try XCTUnwrap(owner.refresh())
            backend.referenceCalls = 0
            if migration {
                backend.values["orphan"] = Data(repeating: 8, count: 48)
                XCTAssertThrowsError(try owner.migrateLegacyHistory(expected: h))
            } else {
                backend.onReferenceCall = { call in if call == 7 { backend.values["orphan"] = Data(repeating: 8, count: 48) } }
                XCTAssertThrowsError(try owner.withLocalAuthority(lease) {})
            }
            backend.onReferenceCall = nil; backend.values.removeValue(forKey: "orphan")
            XCTAssertNil(try owner.refresh())
            XCTAssertThrowsError(try owner.migrateLegacyHistory(expected: h))
        }
    }
    func testIntentRemainsBlockedAndMissingKeyNeverMigrates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DeviceManagementTransitionStore(directory: root), backend = FormatInventoryBackend()
        let h = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "legacy")
        try journal.save(h)
        let keys = CloudInstallationCredentialStore(backend: backend, random: { fatalError("No insertion") })
        let owner = DeviceManagementAuthority(journal: journal, credentials: keys, reset: ManagementTestResetEvidence())
        XCTAssertThrowsError(try owner.migrateLegacyHistory(expected: h))
        XCTAssertEqual(try journal.load(), h)
        backend.values["legacy"] = Data(repeating: 7, count: 32)
        try owner.migrateLegacyHistory(expected: h)
        XCTAssertNil(try owner.refresh())
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: keys), .blocked(.pendingIntent))
    }
}
