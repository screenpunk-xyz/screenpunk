import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple
final class CloudWorkspaceSetupOperationStoreTests: XCTestCase {
    private enum Injected: Error { case failure }
    private func fixture() throws -> (URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (base, base.appendingPathComponent("xyz.screenpunk.cloud-operations"), base.appendingPathComponent("xyz.screenpunk.device/native-workspace-setup.json"))
    }
    private func pending() throws -> CloudWorkspaceSetupOperationRecord { try .init(userID: UUID(), request: .init(requestId: UUID(), workspaceName: "Exact é", locationName: "Location")) }
    private func complete(_ value: CloudWorkspaceSetupOperationRecord) throws -> CloudWorkspaceSetupOperationRecord {
        let receipt = try JSONDecoder().decode(CloudNativeWorkspaceSetupReceipt.self, from: Data("{\"requestId\":\"\(value.request.requestId)\",\"accountId\":\"\(UUID())\",\"locationId\":\"\(UUID())\",\"createdAt\":\"2026-10-03T12:00:00Z\"}".utf8))
        return try .init(userID: value.userID, request: value.request, receipt: receipt)
    }
    private func store(_ f: (URL,URL,URL), point: CloudWorkspaceSetupOperationStore.Boundary? = nil, process: UUID? = nil) throws -> CloudWorkspaceSetupOperationStore {
        var fired = false
        return try .init(directory: f.1, legacyJournal: f.2, boundary: { if $0 == point && !fired { fired = true; throw Injected.failure } }, testOnlyProcessID: process)
    }
    func testLegacyReadOnlyLookupAcceptsOrdinary0755Directory() throws {
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.2.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.2.deletingLastPathComponent().path)
        let value = try pending(), journal = try store(f)
        XCTAssertNil(try journal.load()); try journal.save(value); XCTAssertEqual(try journal.load(), value)
    }
    func testCreatedSetupRetrySynchronizesOnlyBoundCreatedEntriesAndRejectsReplacement() throws {
        let f = try fixture(), value = try pending()
        let failing = try store(f, point: .afterDirectoryCreation)
        XCTAssertThrowsError(try failing.save(value))
        var targets: [String] = []
        let retry = try CloudWorkspaceSetupOperationStore(directory: f.1, legacyJournal: f.2, boundary: { _ in }, directorySyncObserved: { targets.append($0) })
        XCTAssertEqual(try retry.retryPendingWrite(), value)
        XCTAssertEqual(targets, [ScreenPreferenceAtomicWriter.canonicalRoot(f.1).path, ScreenPreferenceAtomicWriter.canonicalRoot(f.0).path])
        targets = []; XCTAssertEqual(try retry.load(), value); XCTAssertTrue(targets.isEmpty)
        let other = try fixture(); XCTAssertThrowsError(try store(other, point: .afterDirectoryCreation).save(pending()))
        try FileManager.default.removeItem(at: other.1)
        try FileManager.default.createDirectory(at: other.1, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try store(other).retryPendingWrite())
    }
    func testMetadataRootAttemptAckFaultMatrixAndRestartOrphans() throws {
        let points: [CloudWorkspaceSetupOperationStore.Boundary] = [.afterMetadataWrite, .beforeMetadataSync, .afterMetadataSync, .beforeMetadataRename, .afterMetadataRename, .beforeMetadataDirectorySync, .afterMetadataDirectorySync]
        for name in ["workspace-root.json", "workspace-attempt.json", "workspace-ack.json"] {
            for point in points {
                let f = try fixture(), value = try pending(); var fired = false
                let failing = try CloudWorkspaceSetupOperationStore(directory: f.1, legacyJournal: f.2, boundary: { _ in }, metadataBoundary: {
                    if $0 == name && $1 == point && !fired { fired = true; throw Injected.failure }
                })
                XCTAssertThrowsError(try failing.save(value), "\(name) \(point)")
                XCTAssertTrue(fired); XCTAssertThrowsError(try failing.load())
                XCTAssertEqual(try store(f).retryPendingWrite(), value, "\(name) \(point)")
            }
        }
        for name in ["workspace-root.json", "workspace-attempt.json", "workspace-ack.json"] {
            let f = try fixture(); var fired = false
            let failing = try CloudWorkspaceSetupOperationStore(directory: f.1, legacyJournal: f.2, boundary: { _ in }, testOnlyProcessID: UUID(), metadataBoundary: {
                if $0 == name && $1 == .beforeMetadataRename && !fired { fired = true; throw Injected.failure }
            })
            XCTAssertThrowsError(try failing.save(pending()))
            let restarted = try store(f, process: UUID()); XCTAssertThrowsError(try restarted.load()); XCTAssertThrowsError(try restarted.retryPendingWrite())
        }
    }
    func testConcurrentInstancesSerializeAndRetainUncertainAttempt() throws {
        let f = try fixture(), value = try pending(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let firstDone = expectation(description: "first writer returned"), secondDone = expectation(description: "second reader returned")
        let first = try CloudWorkspaceSetupOperationStore(directory: f.1, legacyJournal: f.2, boundary: {
            if $0 == .afterAttempt { entered.signal(); _ = release.wait(timeout: .now() + 5); throw Injected.failure }
        })
        let second = try store(f)
        DispatchQueue.global().async { do { try first.save(value); XCTFail("Expected injected uncertainty") } catch {} ; firstDone.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async { do { _ = try second.load(); XCTFail("Uncertain writer must block reader") } catch {} ; secondDone.fulfill() }
        release.signal(); wait(for: [firstDone, secondDone], timeout: 5)
        XCTAssertEqual(try second.retryPendingWrite(), value)
    }
    func testMetadataSameBytesScratchReplacementIsRejected() throws {
        let f = try fixture(), value = try pending(); var replaced = false
        let store = try CloudWorkspaceSetupOperationStore(directory: f.1, legacyJournal: f.2, boundary: { _ in }, metadataBoundary: { name, point in
            if name == "workspace-attempt.json", point == .beforeMetadataRename, !replaced {
                replaced = true
                let scratch = f.1.appendingPathComponent(name + ".pending"), bytes = try Data(contentsOf: scratch)
                try FileManager.default.removeItem(at: scratch); try bytes.write(to: scratch)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.path)
            }
        })
        XCTAssertThrowsError(try store.save(value)); XCTAssertTrue(replaced)
        XCTAssertThrowsError(try store.retryPendingWrite())
        XCTAssertNil(try store.diagnosticReadback())
    }
    func testSuccessorBeforeIntentReplacementPreservesOriginalContext() throws {
        for point: CloudWorkspaceSetupOperationStore.Boundary in [.beforeAttempt, .afterAttemptScratchCreation] {
            let f = try fixture(), initial = try pending(), normal = try store(f), completed = try complete(initial)
            try normal.save(initial); try normal.save(completed)
            let successor = try pending(), failing = try store(f, point: point)
            XCTAssertThrowsError(try failing.beginSuccessor(successor))
            XCTAssertEqual(try failing.diagnosticReadback(), completed)
            XCTAssertThrowsError(try normal.save(successor))
            XCTAssertEqual(try normal.retryPendingWrite(), successor)
        }
    }
    func testCorruptPredecessorOrAckCannotBeOverwrittenByRetainedSuccessor() throws {
        for name in ["workspace-attempt.json", "workspace-ack.json"] {
            let f = try fixture(), initial = try pending(), normal = try store(f), completed = try complete(initial)
            try normal.save(initial); try normal.save(completed)
            let next = try pending(), failing = try store(f, point: .beforeAttempt)
            XCTAssertThrowsError(try failing.beginSuccessor(next))
            let path = f.1.appendingPathComponent(name)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            if name == "workspace-attempt.json" {
                var root = try XCTUnwrap(object["root"] as? [String: Any])
                var lock = try XCTUnwrap(root["lock"] as? [String: Any])
                lock["inode"] = (try XCTUnwrap(lock["inode"] as? NSNumber)).uint64Value + 1
                root["lock"] = lock; object["root"] = root
            } else { object["attemptDigest"] = String(repeating: "0", count: 64) }
            let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try corrupt.write(to: path)
            XCTAssertThrowsError(try normal.retryPendingWrite())
            XCTAssertEqual(try Data(contentsOf: path), corrupt)
            XCTAssertEqual(try normal.diagnosticReadback(), completed)
        }
    }
    func testDurableIntentCannotOverwriteMissingCorruptOrReplacedBaselineAck() throws {
        for mutation in ["missing", "corrupt", "replaced"] {
            let f = try fixture(), initial = try pending(), normal = try store(f), completed = try complete(initial)
            try normal.save(initial); try normal.save(completed)
            let next = try pending(), failing = try store(f, point: .afterAttempt)
            XCTAssertThrowsError(try failing.beginSuccessor(next))
            let path = f.1.appendingPathComponent("workspace-ack.json"), original = try Data(contentsOf: path)
            if mutation == "missing" { try FileManager.default.removeItem(at: path) }
            else if mutation == "corrupt" { try Data("{}".utf8).write(to: path) }
            else { try FileManager.default.removeItem(at: path); try original.write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
            let evidence = try? Data(contentsOf: path)
            XCTAssertThrowsError(try normal.retryPendingWrite(), mutation)
            XCTAssertEqual(try? Data(contentsOf: path), evidence)
            XCTAssertEqual(try normal.diagnosticReadback(), completed)
            XCTAssertThrowsError(try store(f, process: UUID()).retryPendingWrite(), mutation)
        }
    }
    func testPendingCompletionAndExplicitSuccessor() throws {
        let f = try fixture(), store = try store(f), value = try pending()
        XCTAssertNil(try store.load()); try store.save(value); XCTAssertEqual(try store.load(), value)
        XCTAssertThrowsError(try store.save(pending())); let completed = try complete(value)
        // A rejected validation must not retain an unattempted operation.
        try store.save(completed); let successor = try pending()
        XCTAssertThrowsError(try store.save(successor)); try store.beginSuccessor(successor)
        XCTAssertEqual(try store.load(), successor)
    }
    func testEveryBoundaryExactReplayAcrossInstances() throws {
        for point in CloudWorkspaceSetupOperationStore.Boundary.allCases {
            let f = try fixture(), value = try pending(), failing = try store(f, point: point)
            XCTAssertThrowsError(try failing.save(value), "\(point)")
            let recreated = try store(f)
            XCTAssertThrowsError(try recreated.load()); XCTAssertThrowsError(try recreated.beginSuccessor(value))
            XCTAssertEqual(try recreated.retryPendingWrite(), value, "\(point)")
            XCTAssertEqual(try recreated.load(), value)
        }
    }
    func testRestartPreparedAndInstalledCandidateNeedsExactRecovery() throws {
        for point: CloudWorkspaceSetupOperationStore.Boundary in [.afterPreparedAttempt, .afterCandidateReplace, .afterCandidateDirectorySync, .afterAck, .afterFinalSync] {
            let f = try fixture(), value = try pending(); let failing = try store(f, point: point, process: UUID())
            XCTAssertThrowsError(try failing.save(value))
            let restarted = try store(f, process: UUID())
            if point == .afterAck || point == .afterFinalSync { XCTAssertEqual(try restarted.load(), value) }
            else { XCTAssertThrowsError(try restarted.load()); XCTAssertEqual(try restarted.retryPendingWrite(), value) }
        }
    }
    func testRestartUnrecordedScratchAndMalformedEvidenceBlock() throws {
        let f = try fixture(), value = try pending(); XCTAssertThrowsError(try store(f, point: .afterCandidateCreation, process: UUID()).save(value))
        let restarted = try store(f, process: UUID()); XCTAssertThrowsError(try restarted.load()); XCTAssertThrowsError(try restarted.retryPendingWrite())
        try Data("{}".utf8).write(to: f.1.appendingPathComponent("workspace-attempt.json")); XCTAssertThrowsError(try restarted.retryPendingWrite())
    }
    func testSuccessorIntentFailureRetainsExactMethodAndPredecessor() throws {
        let f = try fixture(), original = try pending(), normal = try store(f), completed = try complete(original); try normal.save(original); try normal.save(completed)
        let next = try pending(), failing = try store(f, point: .afterAttempt)
        XCTAssertThrowsError(try failing.beginSuccessor(next)); XCTAssertThrowsError(try normal.save(next))
        XCTAssertEqual(try normal.diagnosticReadback(), completed)
        XCTAssertEqual(try normal.retryPendingWrite(), next)
    }
    func testLegacyPresenceIncludingSymlinkBlocksWithoutWrites() throws {
        let f = try fixture(); try FileManager.default.createDirectory(at: f.2.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: f.2, withDestinationURL: f.0.appendingPathComponent("missing"))
        let value = try store(f); XCTAssertThrowsError(try value.load()); XCTAssertThrowsError(try value.save(pending()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.1.path))
    }
    func testSameBytesReplacementAndDisappearanceCannotAcknowledge() throws {
        let f = try fixture(), value = try pending(), failing = try store(f, point: .afterFinalSync)
        XCTAssertThrowsError(try failing.save(value))
        let file = f.1.appendingPathComponent("workspace-operation.json"), bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try failing.retryPendingWrite()); XCTAssertThrowsError(try store(f, process: UUID()).load())
        try FileManager.default.removeItem(at: f.1); XCTAssertThrowsError(try failing.load())
    }
    func testIncorrectRootAndSymlinkRejected() throws {
        let f = try fixture(); XCTAssertThrowsError(try CloudWorkspaceSetupOperationStore(directory: f.0, legacyJournal: f.2))
        let elsewhere = f.0.appendingPathComponent("elsewhere"); try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: f.1, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try store(f).save(pending())); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }
}
