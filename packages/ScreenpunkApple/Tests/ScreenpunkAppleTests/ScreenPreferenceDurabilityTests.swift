import XCTest
import Darwin
@testable import ScreenpunkApple

@MainActor final class ScreenPreferenceDurabilityTests: XCTestCase {
    private enum Injected: Error { case failure }
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func fault(_ root: URL, at point: ScreenPreferenceAtomicWriter.Boundary) -> ScreenPreferenceStore {
        var fired = false
        return .init(root: root, persistenceBoundary: { if $0 == point && !fired { fired = true; throw Injected.failure } })
    }
    func testProtectionObservabilityAccommodationIsSimulatorOnly() {
        XCTAssertFalse(ScreenPreferenceAtomicWriter.protectionReadbackMatches(nil, required: "required", simulator: false))
        XCTAssertTrue(ScreenPreferenceAtomicWriter.protectionReadbackMatches(nil, required: "required", simulator: true))
        for simulator in [false, true] {
            XCTAssertFalse(ScreenPreferenceAtomicWriter.protectionReadbackMatches("different", required: "required", simulator: simulator))
            XCTAssertTrue(ScreenPreferenceAtomicWriter.protectionReadbackMatches("required", required: "required", simulator: simulator))
        }
    }
    func testExistingAncestorsAreNeverSynchronized() throws {
        let root = makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var targets: [String] = []
        let writer = ScreenPreferenceAtomicWriter(root: root, directorySyncObserved: { targets.append($0) })
        try writer.withSession { _ = try $0.read() }
        XCTAssertEqual(targets, [ScreenPreferenceAtomicWriter.canonicalRoot(root).path])
    }
    func testCreatedDirectoryReplayRetainsBindingBeforeInjectedFailure() throws {
        let root = makeRoot().appendingPathComponent("child")
        var targets: [String] = []
        let failing = ScreenPreferenceAtomicWriter(root: root, boundary: { if $0 == .afterRootCreation { throw Injected.failure } })
        XCTAssertThrowsError(try failing.withSession { _ = try $0.read() })
        let retry = ScreenPreferenceAtomicWriter(root: root, directorySyncObserved: { targets.append($0) })
        try retry.withSession { _ = try $0.read() }
        XCTAssertFalse(targets.contains("/"))
        XCTAssertFalse(targets.contains("/private"))
        XCTAssertTrue(targets.contains(ScreenPreferenceAtomicWriter.canonicalRoot(root).path))
    }
    func testCreatedDirectoryReplacementRejectsSetupReplay() throws {
        let root = makeRoot()
        let failing = ScreenPreferenceAtomicWriter(root: root, boundary: { if $0 == .afterRootCreation { throw Injected.failure } })
        XCTAssertThrowsError(try failing.withSession { _ = try $0.read() })
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ScreenPreferenceAtomicWriter(root: root).withSession { _ = try $0.read() })
    }
    func testEveryCommitBoundaryRetainsExactAttemptAcrossStoreInstances() throws {
        let points: [ScreenPreferenceAtomicWriter.Boundary] = [.afterTemporaryCreation, .afterProtection, .afterPartialWrite, .afterTemporaryWrite, .afterFileSync, .beforeReplace, .afterReplace, .afterDirectorySync]
        for point in points {
            let root = makeRoot(), original = ScreenPreferenceStore(root: root), generation = try original.generation()
            let failing = fault(root, at: point)
            XCTAssertThrowsError(try failing.set(dashboard: "screen", key: "key", value: "attempted", generation: generation))
            let recreated = ScreenPreferenceStore(root: root)
            for store in [original, failing, recreated] {
                XCTAssertThrowsError(try store.generation())
                XCTAssertThrowsError(try store.erase())
                XCTAssertThrowsError(try store.set(dashboard: "screen", key: "key", value: "different", generation: generation))
            }
            try recreated.retryPendingWrite()
            XCTAssertEqual(try original.generation(), generation)
            XCTAssertEqual(try original.get(dashboard: "screen", key: "key", generation: generation) as? String, "attempted")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ScreenPreferenceAtomicWriter.pendingName).path))
        }
    }
    func testPartialWriteNeverPromotesScratchAndRetryUsesCompleteOriginalBytes() throws {
        let root = makeRoot(), original = ScreenPreferenceStore(root: root), generation = try original.generation()
        try original.set(dashboard: "screen", key: "first", value: String(repeating: "a", count: 16_000), generation: generation)
        let archive = root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName), before = try Data(contentsOf: archive)
        let failing = fault(root, at: .afterPartialWrite)
        XCTAssertThrowsError(try failing.set(dashboard: "screen", key: "second", value: String(repeating: "b", count: 16_000), generation: generation))
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ScreenPreferenceAtomicWriter.pendingName)).count, 16_384)
        try original.retryPendingWrite()
        XCTAssertEqual((try original.get(dashboard: "screen", key: "second", generation: generation) as? String)?.count, 16_000)
    }
    func testWriteThenThrowPreservesEraseGenerationAndInstalledIdentity() throws {
        let root = makeRoot(), original = ScreenPreferenceStore(root: root)
        let old = try original.generation(), failing = fault(root, at: .afterDirectorySync)
        XCTAssertThrowsError(try failing.erase())
        let file = root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName)
        let exact = try Data(contentsOf: file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: exact) as? [String: Any])
        let attempted = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(json["generation"] as? String)))
        XCTAssertNotEqual(old, attempted)
        try ScreenPreferenceStore(root: root).retryPendingWrite()
        XCTAssertEqual(try original.generation(), attempted)
        XCTAssertEqual(try Data(contentsOf: file), exact)
    }
    func testRetryRejectsExternalReplacementEvenWithIdenticalBytes() throws {
        for point in [ScreenPreferenceAtomicWriter.Boundary.beforeReplace, .afterDirectorySync] {
            let root = makeRoot(), original = ScreenPreferenceStore(root: root), generation = try original.generation()
            let failing = fault(root, at: point)
            XCTAssertThrowsError(try failing.set(dashboard: "screen", key: "key", value: "attempted", generation: generation))
            let file = root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName), bytes = try Data(contentsOf: file)
            try bytes.write(to: file, options: .atomic)
            XCTAssertThrowsError(try original.retryPendingWrite())
            XCTAssertThrowsError(try ScreenPreferenceStore(root: root).generation())
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
    func testRetryRejectsExternalInPlaceContentChangeAndLockReplacement() throws {
        for replaceLock in [false, true] {
            let root = makeRoot(), original = ScreenPreferenceStore(root: root), generation = try original.generation()
            XCTAssertThrowsError(try fault(root, at: .beforeReplace).set(dashboard: "screen", key: "key", value: "attempted", generation: generation))
            if replaceLock {
                let lock = root.appendingPathComponent(ScreenPreferenceAtomicWriter.lockName)
                try FileManager.default.removeItem(at: lock); try Data().write(to: lock)
            } else { try Data("external".utf8).write(to: root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName)) }
            XCTAssertThrowsError(try original.retryPendingWrite())
            XCTAssertThrowsError(try original.generation())
        }
    }
    func testPendingRemovalFailurePreservesOriginalAttempt() throws {
        for point in [ScreenPreferenceAtomicWriter.Boundary.beforePendingRemoval, .afterPendingRemoval] {
            let root = makeRoot(), original = ScreenPreferenceStore(root: root), generation = try original.generation()
            let pending = root.appendingPathComponent(ScreenPreferenceAtomicWriter.pendingName)
            try Data("stale scratch".utf8).write(to: pending)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            XCTAssertThrowsError(try fault(root, at: point).set(dashboard: "screen", key: "key", value: "exact", generation: generation))
            XCTAssertThrowsError(try original.generation())
            try original.retryPendingWrite()
            XCTAssertEqual(try original.get(dashboard: "screen", key: "key", generation: generation) as? String, "exact")
        }
    }
    func testSetupFailuresCannotReportArchiveSuccessAndAreRetryable() throws {
        for point in [ScreenPreferenceAtomicWriter.Boundary.afterRootCreation, .afterLockCreation] {
            let root = makeRoot(), failing = fault(root, at: point)
            XCTAssertThrowsError(try failing.generation())
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName).path))
            XCTAssertNoThrow(try ScreenPreferenceStore(root: root).generation())
        }
    }
    func testStaleReservedScratchIsNeverPromotedAndUnknownTempsRemain() throws {
        let root = makeRoot(), original = ScreenPreferenceStore(root: root), generation = try original.generation()
        let pending = root.appendingPathComponent(ScreenPreferenceAtomicWriter.pendingName), unknown = root.appendingPathComponent("unknown-history.tmp")
        try Data("never authoritative".utf8).write(to: pending)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        try Data("preserved".utf8).write(to: unknown)
        XCTAssertEqual(try ScreenPreferenceStore(root: root).generation(), generation)
        try original.set(dashboard: "screen", key: "key", value: "real", generation: generation)
        XCTAssertEqual(try String(contentsOf: unknown), "preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }
    func testSymlinkRootLockArchiveAndPendingFailClosedPreserveSentinel() throws {
        for name in ["root", ScreenPreferenceAtomicWriter.lockName, ScreenPreferenceAtomicWriter.archiveName, ScreenPreferenceAtomicWriter.pendingName] {
            let root = makeRoot(), sentinel = makeRoot().appendingPathComponent("sentinel")
            try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("protected".utf8).write(to: sentinel)
            if name == "root" {
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: sentinel.deletingLastPathComponent())
                XCTAssertThrowsError(try ScreenPreferenceStore(root: root).generation())
            } else {
                let store = ScreenPreferenceStore(root: root), generation = try store.generation(), path = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
                XCTAssertThrowsError(try store.set(dashboard: "screen", key: "key", value: "overwrite", generation: generation))
            }
            XCTAssertEqual(try String(contentsOf: sentinel), "protected")
        }
    }
    func testRootReplacementCannotReuseAnUncertainAttempt() throws {
        let root = makeRoot(), original = ScreenPreferenceStore(root: root), generation = try original.generation()
        XCTAssertThrowsError(try fault(root, at: .beforeReplace).set(dashboard: "screen", key: "key", value: "attempted", generation: generation))
        let displaced = makeRoot()
        try FileManager.default.moveItem(at: root, to: displaced)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName)
        try Data("external sentinel".utf8).write(to: sentinel)
        XCTAssertThrowsError(try original.retryPendingWrite())
        XCTAssertEqual(try String(contentsOf: sentinel), "external sentinel")
    }
    func testFreshWriterReadsArchiveAndNeverPromotesInterruptedScratch() throws {
        let root = makeRoot()
        let committed = Data("committed archive".utf8)
        let writer = ScreenPreferenceAtomicWriter(root: root)
        try writer.withSession { session in try session.commit(session.attempt(bytes: committed, baseline: session.read())) }
        let interrupted = ScreenPreferenceAtomicWriter(root: root, boundary: { if $0 == .afterPartialWrite { throw Injected.failure } })
        XCTAssertThrowsError(try interrupted.withSession { session in try session.commit(session.attempt(bytes: Data(repeating: 120, count: 40_000), baseline: session.read())) })
        // No retained in-process attempt: model a fresh primitive after process restart.
        let fresh = ScreenPreferenceAtomicWriter(root: root)
        try fresh.withSession { session in
            let baseline = try session.read(); XCTAssertEqual(baseline.data, committed)
            try session.commit(session.attempt(bytes: committed, baseline: baseline))
            XCTAssertEqual(try session.read().data, committed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ScreenPreferenceAtomicWriter.pendingName).path))
    }
    func testShortWritesAndEINTRCompleteExactBytesAndZeroWriteFails() throws {
        let root = makeRoot(), bytes = Data(repeating: 97, count: 500)
        var first = true
        let writer = ScreenPreferenceAtomicWriter(root: root, writeCall: { descriptor, pointer, count in
            if first { first = false; errno = EINTR; return -1 }
            return Darwin.write(descriptor, pointer, min(count, 7))
        })
        try writer.withSession { session in try session.commit(session.attempt(bytes: bytes, baseline: session.read())) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName)), bytes)
        let zero = ScreenPreferenceAtomicWriter(root: root, writeCall: { _, _, _ in 0 })
        XCTAssertThrowsError(try zero.withSession { session in try session.commit(session.attempt(bytes: Data("different".utf8), baseline: session.read())) })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName)), bytes)
    }
    func testEscapedSessionCannotReadOrWriteAfterFlockExit() throws {
        let writer = ScreenPreferenceAtomicWriter(root: makeRoot())
        var escaped: ScreenPreferenceAtomicWriter.Session?
        var attempt: ScreenPreferenceAtomicWriter.Attempt?
        try writer.withSession {
            escaped = $0; attempt = try $0.attempt(bytes: Data("forbidden".utf8), baseline: $0.read())
        }
        XCTAssertThrowsError(try XCTUnwrap(escaped).read())
        XCTAssertThrowsError(try XCTUnwrap(escaped).commit(XCTUnwrap(attempt)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName).path))
    }
    func testSuspensionRejectsPendingRetryAndNewStores() throws {
        let root = makeRoot(), original = ScreenPreferenceStore(root: root), generation = try original.generation()
        XCTAssertThrowsError(try fault(root, at: .afterReplace).set(dashboard: "screen", key: "key", value: "attempted", generation: generation))
        let file = root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName), before = try Data(contentsOf: file)
        original.suspendForReset()
        XCTAssertThrowsError(try original.retryPendingWrite())
        XCTAssertThrowsError(try ScreenPreferenceStore(root: root).retryPendingWrite())
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}
