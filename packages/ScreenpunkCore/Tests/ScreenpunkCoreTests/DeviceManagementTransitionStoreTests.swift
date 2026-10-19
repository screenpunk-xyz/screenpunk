import XCTest
@testable import ScreenpunkCore

final class DeviceManagementTransitionStoreTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("management-test-\(UUID().uuidString)", isDirectory: true) }
    private func intent() throws -> DeviceManagementTransitionHistory {
        try .intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "cloud-installation-\(UUID().uuidString)")
    }

    func testConfirmedAbsenceRequiresExternalEmptyKeychainForLegacyLocal() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceManagementTransitionStore(directory: root)
        XCTAssertNil(try store.load())
        XCTAssertEqual(try store.localState(cloudCredentialsConfirmedEmpty: false), .blocked)
        XCTAssertEqual(try store.localState(cloudCredentialsConfirmedEmpty: true), .legacyLocal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Absent load never creates an intent or defaults")
    }

    func testIntentBlocksAndFenceSurvivesRestartWithoutDeletingCredentialReference() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceManagementTransitionStore(directory: root)
        let pending = try intent()
        try store.save(pending)
        XCTAssertEqual(try store.load(), pending)
        XCTAssertEqual(try store.localState(cloudCredentialsConfirmedEmpty: true), .blocked, "A missing staged key never resolves pending intent")
        let fenced = try pending.fenced()
        try store.save(fenced)
        let restarted = DeviceManagementTransitionStore(directory: root)
        XCTAssertEqual(try restarted.load(), fenced)
        XCTAssertEqual(try restarted.localState(cloudCredentialsConfirmedEmpty: false), .fenced(credentialReferences: pending.credentials.map(\.credentialReference)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.recordURL)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "transitions", "credentials"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        let mode = try FileManager.default.attributesOfItem(atPath: store.recordURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testImmutableBindingAndNoUnfenceOrFreshFenceWithoutIntent() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceManagementTransitionStore(directory: root)
        let pending = try intent()
        XCTAssertThrowsError(try store.save(pending.fenced())) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .transitionConflict) }
        XCTAssertNil(try store.load())
        try store.save(pending)
        XCTAssertThrowsError(try store.save(intent())) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .transitionConflict) }
        let otherRef = try DeviceManagementTransitionHistory.intent(transitionID: pending.transitions[0].transitionID, credentialGenerationID: pending.credentials[0].credentialGenerationID, credentialReference: "other")
        XCTAssertThrowsError(try store.save(otherRef)) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .transitionConflict) }
        XCTAssertEqual(try store.load(), pending)
        try store.save(pending.fenced())
        XCTAssertThrowsError(try store.save(pending)) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .transitionConflict) }
        XCTAssertThrowsError(try store.save(intent())) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .transitionConflict) }
        XCTAssertEqual(try store.load(), try pending.fenced())
    }

    func testCorruptMissingUnsupportedAndOversizedRecordsNeverBecomeAbsent() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DeviceManagementTransitionStore(directory: root)
        for data in [Data(), Data("not-json".utf8), Data("{}".utf8), Data(#"{"schemaVersion":1,"transitionID":"bad","credentialReference":"ref","phase":"intent"}"#.utf8),
                     Data(#"{"schemaVersion":1,"transitionID":"11111111-1111-4111-8111-111111111111","credentialReference":"ref","phase":"active"}"#.utf8)] {
            try data.write(to: store.recordURL)
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .corrupt) }
            XCTAssertThrowsError(try store.localState(cloudCredentialsConfirmedEmpty: true))
            XCTAssertEqual(try Data(contentsOf: store.recordURL), data)
        }
        let unsupported = Data(#"{"schemaVersion":3,"futureField":true}"#.utf8)
        try unsupported.write(to: store.recordURL)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .unsupportedVersion(3)) }
        XCTAssertThrowsError(try store.save(intent()))
        XCTAssertEqual(try Data(contentsOf: store.recordURL), unsupported, "A future record must never be overwritten by a fallback")
        let large = Data(repeating: 32, count: DeviceManagementTransitionStore.maximumRecordBytes + 1)
        try large.write(to: store.recordURL)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .recordTooLarge) }
        XCTAssertEqual(try Data(contentsOf: store.recordURL), large)
    }

    func testReferenceAndUnknownFieldValidationKeepsFormatNonsecretAndBounded() throws {
        for reference in ["", "ref with space", "ref\n", "../path/token", "https://example", "日本語", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try DeviceManagementTransitionRecord(transitionID: UUID(), credentialReference: reference))
        }
        XCTAssertNoThrow(try DeviceManagementTransitionRecord(transitionID: UUID(), credentialReference: String(repeating: "a", count: 128)))
        let value = try intent()
        XCTAssertEqual(try JSONDecoder().decode(DeviceManagementTransitionHistory.self, from: JSONEncoder().encode(value)), value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object["token"] = "must-not-be-journal-content"
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceManagementTransitionHistory.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testIOFailureAndSymlinkNeverFallBackToAbsentOrDeleteExistingData() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DeviceManagementTransitionStore(directory: root)
        try FileManager.default.createDirectory(at: store.recordURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.load()) { error in
            guard case .io = error as? DeviceManagementTransitionStoreError else { XCTFail("Expected IO error"); return }
        }
        XCTAssertThrowsError(try store.save(intent()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.recordURL.path))
        try FileManager.default.removeItem(at: store.recordURL)
        let target = root.appendingPathComponent("elsewhere.json")
        try JSONEncoder().encode(intent()).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.recordURL, withDestinationURL: target)
        let fresh = DeviceManagementTransitionStore(directory: root)
        XCTAssertThrowsError(try fresh.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testCommitOrderingAndEveryInjectedFailureStayBlockedUntilExactDurableRecommit() throws {
        for failure in [DeviceManagementCommitBoundary.afterTemporaryWrite, .afterFileSync, .beforeReplace, .afterReplace, .afterDirectorySync] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let pending = try intent()
            try DeviceManagementTransitionStore(directory: root).save(pending)
            let boundary = ManagementBoundaryFault(failure)
            let store = DeviceManagementTransitionStore(directory: root, boundary: { try boundary.visit($0) })
            let fenced = try pending.fenced()
            XCTAssertThrowsError(try store.save(fenced))
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .writeOutcomeUncertain) }
            let reconstructed = DeviceManagementTransitionStore(directory: root)
            XCTAssertThrowsError(try reconstructed.load()) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .writeOutcomeUncertain) }
            XCTAssertThrowsError(try store.localState(cloudCredentialsConfirmedEmpty: true))
            let observed = try store.diagnosticReadback()
            XCTAssertEqual(observed, failure == .afterReplace || failure == .afterDirectorySync ? fenced : pending)
            XCTAssertThrowsError(try store.save(pending)) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .writeOutcomeUncertain) }
            boundary.disable()
            try store.save(fenced)
            XCTAssertEqual(try store.load(), fenced)
            XCTAssertEqual(try DeviceManagementTransitionStore(directory: root).load(), fenced)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(files.contains { $0.hasPrefix("management-transition.tmp-") })
        }
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let boundary = ManagementBoundaryFault(nil)
        try DeviceManagementTransitionStore(directory: root, boundary: { try boundary.visit($0) }).save(intent())
        XCTAssertEqual(boundary.snapshot(), [.afterTemporaryWrite, .afterFileSync, .beforeReplace, .afterReplace, .afterDirectorySync])
    }

    func testInitialIntentWriteThenThrowCannotDefaultOrAdvanceToFence() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let boundary = ManagementBoundaryFault(.afterReplace)
        let store = DeviceManagementTransitionStore(directory: root, boundary: { try boundary.visit($0) })
        let pending = try intent()
        XCTAssertThrowsError(try store.save(pending))
        XCTAssertEqual(try store.diagnosticReadback(), pending)
        XCTAssertThrowsError(try store.localState(cloudCredentialsConfirmedEmpty: true))
        XCTAssertThrowsError(try store.save(pending.fenced())) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .writeOutcomeUncertain) }
        boundary.disable()
        try store.save(pending)
        XCTAssertEqual(try store.localState(cloudCredentialsConfirmedEmpty: true), .blocked)
    }

    func testIndependentStoreInstancesCannotUnfenceOrReplaceAnIntent() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = DeviceManagementTransitionStore(directory: root)
        let second = DeviceManagementTransitionStore(directory: root)
        let pending = try intent()
        try first.save(pending)
        XCTAssertEqual(try second.load(), pending)
        try second.save(pending.fenced())
        XCTAssertThrowsError(try first.save(pending)) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .transitionConflict) }
        XCTAssertEqual(try first.load(), try pending.fenced())
    }


    func testRepeatedCyclesAndMultipleCredentialGenerationsRetainAllBindings() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceManagementTransitionStore(directory: root)
        var history = try intent(); try store.save(history)
        history = try history.appendingCredential(credentialGenerationID: UUID(), credentialReference: "second-generation")
        try store.save(history)
        history = try history.fenced(); try store.save(history)
        let firstBindings = history.credentials
        history = try history.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "next-transition")
        try store.save(history)
        XCTAssertEqual(try store.localState(cloudCredentialsConfirmedEmpty: false), .blocked)
        history = try history.fenced(); try store.save(history)
        XCTAssertEqual(try DeviceManagementTransitionStore(directory: root).load(), history)
        XCTAssertEqual(Array(history.credentials.prefix(2)), firstBindings)
        XCTAssertEqual(try store.localState(cloudCredentialsConfirmedEmpty: false), .fenced(credentialReferences: history.credentials.map(\.credentialReference)))
        let dropped = try DeviceManagementTransitionHistory(transitions: [history.transitions[1]], credentials: [history.credentials[2]])
        XCTAssertThrowsError(try store.save(dropped))
        XCTAssertThrowsError(try history.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "second-generation"))
        XCTAssertThrowsError(try history.appendingCredential(credentialGenerationID: UUID(), credentialReference: "late-generation"))
    }

    func testWholeHistoryUncertainAppendRequiresExactRecommitAndRejectsNestedTampering() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try intent()
        let ordinary = DeviceManagementTransitionStore(directory: root)
        try ordinary.save(initial); let fenced = try initial.fenced(); try ordinary.save(fenced)
        let appended = try fenced.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "next")
        let fault = ManagementBoundaryFault(.afterReplace)
        let store = DeviceManagementTransitionStore(directory: root, boundary: { try fault.visit($0) })
        XCTAssertThrowsError(try store.save(appended))
        XCTAssertEqual(try store.diagnosticReadback(), appended)
        XCTAssertThrowsError(try ordinary.load())
        XCTAssertThrowsError(try store.save(appended.fenced()))
        XCTAssertThrowsError(try store.save(fenced))
        fault.disable(); try store.save(appended)
        XCTAssertEqual(try store.load(), appended)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(appended)) as? [String: Any])
        var bindings = try XCTUnwrap(object["credentials"] as? [[String: Any]])
        bindings[0]["secret"] = "forbidden"; object["credentials"] = bindings
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceManagementTransitionHistory.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try DeviceManagementTransitionHistory.intent(transitionID: initial.transitions[0].transitionID, credentialGenerationID: initial.transitions[0].transitionID, credentialReference: "same-id"))
    }

    func testVersionOneMigrationPreservesIntentAndFenceAndUpgradesOnSave() throws {
        for phase in [DeviceManagementTransitionPhase.intent, .locallyFenced] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = DeviceManagementTransitionStore(directory: root)
            let old = try DeviceManagementTransitionRecord(transitionID: UUID(), credentialReference: "legacy-ref", phase: phase)
            try JSONEncoder().encode(old).write(to: store.recordURL)
            let migrated = try XCTUnwrap(store.load())
            XCTAssertEqual(migrated.transitions, [.init(transitionID: old.transitionID, phase: phase)])
            XCTAssertEqual(migrated.credentials[0].credentialReference, old.credentialReference)
            XCTAssertNotEqual(migrated.credentials[0].credentialGenerationID, old.transitionID)
            XCTAssertEqual(try store.load(), migrated)
            try store.save(migrated)
            let data = try Data(contentsOf: store.recordURL)
            XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int, 2)
            XCTAssertEqual(try store.load(), migrated)
        }
    }

    func testCapacityFailsClosedWithoutPruningAndRejectsReorder() throws {
        var history = try intent()
        for i in 1..<DeviceManagementTransitionHistory.maximumTransitions {
            history = try history.fenced().appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "ref-\(i)")
        }
        history = try history.fenced()
        XCTAssertThrowsError(try history.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "overflow")) { XCTAssertEqual($0 as? DeviceManagementTransitionStoreError, .capacityExceeded) }
        var generations = try intent()
        for i in 1..<DeviceManagementTransitionHistory.maximumCredentials { generations = try generations.appendingCredential(credentialGenerationID: UUID(), credentialReference: "generation-\(i)") }
        XCTAssertThrowsError(try generations.appendingCredential(credentialGenerationID: UUID(), credentialReference: "overflow"))
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceManagementTransitionStore(directory: root)
        var value = try intent(); try store.save(value)
        value = try value.fenced(); try store.save(value)
        value = try value.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "new"); try store.save(value)
        value = try value.fenced(); try store.save(value)
        let reordered = try DeviceManagementTransitionHistory(transitions: value.transitions.reversed(), credentials: value.credentials.reversed())
        XCTAssertThrowsError(try store.save(reordered))
        XCTAssertEqual(try store.load(), value)
    }

    func testSiblingJournalSurvivesLegacyDeviceStateErase() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let device = DeviceStateStore(root: root.appendingPathComponent("xyz.screenpunk.device"))
        let management = DeviceManagementTransitionStore(directory: root.appendingPathComponent("xyz.screenpunk.management"))
        let pending = try intent()
        try management.save(pending)
        try device.save(.init(owner: nil, activeRevision: nil, activeStoredRevision: nil, lastDeployment: nil))
        try device.erase()
        XCTAssertEqual(try management.load(), pending)
        XCTAssertNotEqual(DeviceManagementTransitionStore.defaultDirectory().lastPathComponent, DeviceStateStore.defaultRoot().lastPathComponent)
    }
}

private final class ManagementBoundaryFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: DeviceManagementCommitBoundary?
    private var visited: [DeviceManagementCommitBoundary] = []
    init(_ failure: DeviceManagementCommitBoundary?) { self.failure = failure }
    func visit(_ boundary: DeviceManagementCommitBoundary) throws {
        lock.lock(); defer { lock.unlock() }
        visited.append(boundary)
        if boundary == failure { throw CocoaError(.fileWriteUnknown) }
    }
    func disable() { lock.lock(); defer { lock.unlock() }; failure = nil }
    func snapshot() -> [DeviceManagementCommitBoundary] { lock.lock(); defer { lock.unlock() }; return visited }
}
