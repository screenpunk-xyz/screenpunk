import XCTest
@testable import ScreenpunkCore

final class DeviceLocalResetStoreTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("reset-test-\(UUID().uuidString)", isDirectory: true) }
    private func pending(scope: String? = nil) throws -> DeviceLocalResetRecord { try .init(resetID: UUID(), scopeDigest: scope ?? self.scope) }

    func testConfirmedAbsenceDoesNotCreateDirectoryOrDefaultRecord() throws {
        let root = directory(), store = DeviceLocalResetStore(directory: root)
        XCTAssertNil(try store.load())
        XCTAssertNil(try store.diagnosticReadback())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNotEqual(DeviceLocalResetStore.defaultDirectory(), DeviceStateStore.defaultRoot())
        XCTAssertNotEqual(DeviceLocalResetStore.defaultDirectory(), DeviceManagementTransitionStore.defaultDirectory())
    }

    func testPendingCompletionAndExplicitNewResetPersistAcrossStoreReconstruction() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceLocalResetStore(directory: root), first = try pending()
        try store.save(first); try store.save(first)
        XCTAssertEqual(try DeviceLocalResetStore(directory: root).load(), first)
        let completed = try first.completed()
        try store.save(completed); try store.save(completed)
        XCTAssertEqual(try DeviceLocalResetStore(directory: root).load(), completed)
        let next = try pending(scope: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try store.save(next)) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .transitionConflict) }
        XCTAssertEqual(try store.load(), completed, "Ordinary save must retain completion")
        try store.beginNewReset(next); try store.beginNewReset(next)
        XCTAssertEqual(try DeviceLocalResetStore(directory: root).load(), next)
        try store.save(next.completed())
        XCTAssertEqual(try store.load(), try next.completed())
    }

    func testNoInitialCompletionPendingReplacementScopeChangeOrUnfence() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceLocalResetStore(directory: root), first = try pending()
        XCTAssertThrowsError(try store.save(first.completed()))
        XCTAssertThrowsError(try store.beginNewReset(first.completed()))
        XCTAssertNil(try store.load())
        try store.save(first)
        let changedScope = try DeviceLocalResetRecord(resetID: first.resetID, scopeDigest: String(repeating: "c", count: 64))
        for replacement in [try pending(), changedScope, try changedScope.completed()] {
            XCTAssertThrowsError(try store.save(replacement))
            XCTAssertThrowsError(try store.beginNewReset(replacement))
            XCTAssertEqual(try store.load(), first)
        }
        try store.save(first.completed())
        XCTAssertThrowsError(try store.save(first))
        XCTAssertThrowsError(try store.beginNewReset(first), "Explicit request still needs a different ID")
        XCTAssertThrowsError(try store.beginNewReset(changedScope))
        XCTAssertThrowsError(try store.save(changedScope.completed()))
        XCTAssertEqual(try store.load(), try first.completed())
    }

    func testDigestValidationStrictKeysAndNonsecretFormat() throws {
        for digest in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "é", count: 32), "../" + String(repeating: "a", count: 61)] {
            XCTAssertThrowsError(try pending(scope: digest)) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .invalidRecord) }
        }
        let valid = try pending(scope: "0123456789abcdef" + String(repeating: "0", count: 48))
        let encoded = try JSONEncoder().encode(valid)
        XCTAssertEqual(try JSONDecoder().decode(DeviceLocalResetRecord.self, from: encoded), valid)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "resetID", "scopeDigest", "phase"])
        for key in object.keys {
            var missing = object; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(DeviceLocalResetRecord.self, from: JSONSerialization.data(withJSONObject: missing)))
        }
        for key in ["credential", "cleanupPath", "cloudStatus"] {
            var extra = object; extra[key] = "forbidden"
            XCTAssertThrowsError(try JSONDecoder().decode(DeviceLocalResetRecord.self, from: JSONSerialization.data(withJSONObject: extra)))
        }
    }

    func testCorruptionUnsupportedVersionAndOversizeNeverBecomeAbsentOrOverwrite() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DeviceLocalResetStore(directory: root), record = try pending()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        var invalids = [Data(), Data("not-json".utf8), Data("{}".utf8)]
        for key in object.keys { var missing = object; missing.removeValue(forKey: key); invalids.append(try JSONSerialization.data(withJSONObject: missing)) }
        for (key, value) in [("resetID", "invalid"), ("phase", "cleaning"), ("scopeDigest", "wrong")] {
            var invalid = object; invalid[key] = value; invalids.append(try JSONSerialization.data(withJSONObject: invalid))
        }
        object["secret"] = "forbidden"; invalids.append(try JSONSerialization.data(withJSONObject: object))
        for data in invalids {
            try data.write(to: store.recordURL)
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .corrupt) }
            XCTAssertThrowsError(try store.save(record))
            XCTAssertThrowsError(try store.beginNewReset(record))
            XCTAssertEqual(try Data(contentsOf: store.recordURL), data)
        }
        let future = Data(#"{"schemaVersion":2,"futureField":true}"#.utf8)
        try future.write(to: store.recordURL)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .unsupportedVersion(2)) }
        XCTAssertThrowsError(try store.save(record))
        XCTAssertEqual(try Data(contentsOf: store.recordURL), future)
        let oversized = Data(repeating: 32, count: DeviceLocalResetStore.maximumRecordBytes + 1)
        try oversized.write(to: store.recordURL)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .recordTooLarge) }
        XCTAssertThrowsError(try store.beginNewReset(record))
        XCTAssertEqual(try Data(contentsOf: store.recordURL), oversized)
    }

    func testDirectoryRecordAndLockSymlinksAreRejectedWithoutChangingTarget() throws {
        for kind in 0..<3 {
            let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
            let root = base.appendingPathComponent("journal"), target = base.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let marker = target.appendingPathComponent("marker")
            let bytes = Data("preserve".utf8); try bytes.write(to: marker)
            if kind == 0 { try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target) }
            else {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let name = kind == 1 ? "local-reset.json" : "local-reset.lock"
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: marker)
            }
            let store = DeviceLocalResetStore(directory: root)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(pending()))
            XCTAssertEqual(try Data(contentsOf: marker), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("local-reset.json").path))
        }
    }

    func testIOFailureIsNotAbsenceAndWriteUncertaintySurvivesStoreReconstruction() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("not a directory".utf8); try bytes.write(to: root)
        let store = DeviceLocalResetStore(directory: root), record = try pending()
        XCTAssertThrowsError(try store.load()) { error in
            guard case .io = error as? DeviceLocalResetStoreError else { return XCTFail("Expected IO failure") }
        }
        XCTAssertThrowsError(try store.save(record))
        XCTAssertThrowsError(try DeviceLocalResetStore(directory: root).load()) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .writeOutcomeUncertain) }
        XCTAssertEqual(try Data(contentsOf: root), bytes)
    }

    func testEveryWriteBoundaryForInitialPendingCompletionAndExplicitNewResetRequiresExactMethodRecommit() throws {
        for operation in 0..<3 {
            for failure in [DeviceLocalResetCommitBoundary.afterTemporaryWrite, .afterFileSync, .beforeReplace, .afterReplace, .afterDirectorySync] {
                let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
                let initial = try pending()
                let ordinary = DeviceLocalResetStore(directory: root)
                var previous: DeviceLocalResetRecord?
                let attempted: DeviceLocalResetRecord
                if operation == 0 { attempted = initial }
                else {
                    try ordinary.save(initial); previous = initial
                    if operation == 1 { attempted = try initial.completed() }
                    else { previous = try initial.completed(); try ordinary.save(previous!); attempted = try pending() }
                }
                let fault = ResetBoundaryFault(failure)
                let store = DeviceLocalResetStore(directory: root, boundary: { try fault.visit($0) })
                func retry() throws { if operation == 2 { try store.beginNewReset(attempted) } else { try store.save(attempted) } }
                XCTAssertThrowsError(try retry())
                XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .writeOutcomeUncertain) }
                XCTAssertThrowsError(try ordinary.load()) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .writeOutcomeUncertain) }
                let replaced = failure == .afterReplace || failure == .afterDirectorySync
                XCTAssertEqual(try store.diagnosticReadback(), replaced ? attempted : previous)
                XCTAssertThrowsError(try store.save(pending())) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .writeOutcomeUncertain) }
                if operation == 2 { XCTAssertThrowsError(try store.save(attempted)) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .writeOutcomeUncertain) } }
                else if attempted.phase == .pending { XCTAssertThrowsError(try store.beginNewReset(attempted)) { XCTAssertEqual($0 as? DeviceLocalResetStoreError, .writeOutcomeUncertain) } }
                fault.disable(); try retry()
                XCTAssertEqual(try ordinary.load(), attempted)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("local-reset.tmp-") })
            }
        }
    }

    func testCommitOrderPermissionsAndCompletedMarkerRetention() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fault = ResetBoundaryFault(nil), store = DeviceLocalResetStore(directory: root, boundary: { try fault.visit($0) })
        let record = try pending()
        try store.save(record)
        XCTAssertEqual(fault.snapshot(), [.afterTemporaryWrite, .afterFileSync, .beforeReplace, .afterReplace, .afterDirectorySync])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.recordURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.save(record.completed())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.recordURL.path))
        XCTAssertEqual(try store.load(), try record.completed())
    }

    func testIndependentStoresCannotReplacePendingOrUndoCompletion() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let one = DeviceLocalResetStore(directory: root), two = DeviceLocalResetStore(directory: root), record = try pending()
        try one.save(record)
        XCTAssertThrowsError(try two.beginNewReset(pending()))
        try two.save(record.completed())
        XCTAssertThrowsError(try one.save(record))
        XCTAssertEqual(try one.load(), try record.completed())
    }
}

private final class ResetBoundaryFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: DeviceLocalResetCommitBoundary?
    private var observed: [DeviceLocalResetCommitBoundary] = []
    init(_ failure: DeviceLocalResetCommitBoundary?) { self.failure = failure }
    func visit(_ point: DeviceLocalResetCommitBoundary) throws {
        lock.lock(); defer { lock.unlock() }
        observed.append(point)
        if point == failure { throw CocoaError(.fileWriteUnknown) }
    }
    func disable() { lock.lock(); failure = nil; lock.unlock() }
    func snapshot() -> [DeviceLocalResetCommitBoundary] { lock.lock(); defer { lock.unlock() }; return observed }
}
