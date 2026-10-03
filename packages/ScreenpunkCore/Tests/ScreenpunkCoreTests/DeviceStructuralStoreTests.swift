import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DeviceStructuralStoreTests: XCTestCase {
    private let rootID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))! }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("structural-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func record(_ operation: Int, old: Data? = nil, assertions: Data = Data()) throws -> DeviceStructuralOperationRecord {
        let expected = try old.map { try StructuralStoreCodec.envelope($0).snapshot.generationID }
        let snapshot = DeviceStructuralSnapshot(generationID: id(operation + 1000), entries: [], configuredEntryID: nil, contentOwner: nil, grantSet: nil)
        let envelope = DeviceStructuralCommitEnvelope(operationID: id(operation), expectedGenerationID: expected, snapshot: snapshot,
                                                      intent: Data("exact intent".utf8), outcome: Data("local commit outcome".utf8))
        return .init(rootID: rootID, operationID: id(operation), expectedOld: old,
                     candidate: try StructuralStoreCodec.encode(envelope), resourceAssertions: assertions)
    }
    private func current(_ root: URL) throws -> Data { try Data(contentsOf: root.appendingPathComponent("structural-envelope.json")) }
    func testExplicitInitializationAndRetainedOldReplayDoNotReplaceTip() throws {
        let root = try directory(); let store = DeviceStructuralStore(root: root, rootID: rootID)
        XCTAssertThrowsError(try store.prepare(record(1)))
        try store.initializeExplicit()
        let first = try record(1); try store.prepare(first)
        XCTAssertEqual(try store.recover(operationID: first.operationID), .oldObserved(first))
        XCTAssertTrue(try store.attempt(operationID: first.operationID).record.sameIntent(as: first))
        let next = try record(2, old: first.candidate); try store.prepare(next); _ = try store.attempt(operationID: next.operationID)
        let tip = try current(root)
        let replay = DeviceStructuralStore(root: root, rootID: rootID)
        guard case .terminalNeedsDurability(let proof) = try replay.recover(operationID: first.operationID) else { return XCTFail("terminal expected") }; XCTAssertTrue(proof.sameIntent(as: first))
        XCTAssertTrue(try replay.attempt(operationID: first.operationID).record.sameIntent(as: first))
        XCTAssertEqual(try current(root), tip)
        var changed = try record(1, assertions: Data("changed retry".utf8))
        XCTAssertThrowsError(try replay.prepare(changed))
        changed = try record(3, old: first.candidate)
        XCTAssertThrowsError(try replay.prepare(changed))
        try FileManager.default.removeItem(at: root.appendingPathComponent("structural-envelope.json"))
        XCTAssertThrowsError(try replay.attempt(operationID: first.operationID))
    }
    func testFaultBoundariesRequireExactRepairAcrossReconstruction() throws {
        let kinds: [DeviceStructuralStore.Kind] = [.intent, .envelope, .terminal]
        for kind in kinds {
            let points: [DeviceStructuralStore.Boundary] = [.afterWrite(kind), .afterFileSync(kind), .beforeReplace(kind), .afterReplace(kind), .afterDirectorySync(kind)]
            for point in points {
                let root = try directory(); try DeviceStructuralStore(root: root, rootID: rootID).initializeExplicit()
                let first = try record(1)
                var fired = false
                let faulty = DeviceStructuralStore(root: root, rootID: rootID) { boundary in
                    if boundary == point && !fired { fired = true; throw DeviceStructuralStoreError.io(EIO) }
                }
                try faulty.initializeExplicit()
                if kind == .intent { XCTAssertThrowsError(try faulty.prepare(first)) }
                else { try faulty.prepare(first); XCTAssertThrowsError(try faulty.attempt(operationID: first.operationID)) }
                XCTAssertTrue(fired)
                let recovered = DeviceStructuralStore(root: root, rootID: rootID)
                let diagnosis = try recovered.recover(operationID: first.operationID)
                if kind == .terminal && (point == .afterReplace(kind) || point == .afterDirectorySync(kind)) {
                    guard case .terminalNeedsDurability(let proof) = diagnosis else { return XCTFail("terminal expected") }; XCTAssertTrue(proof.sameIntent(as: first))
                }
                if kind == .envelope && (point == .afterWrite(kind) || point == .afterFileSync(kind)) {
                    XCTAssertThrowsError(try recovered.recommitExact(operationID: first.operationID))
                    XCTAssertTrue(try faulty.recommitExact(operationID: first.operationID).record.sameIntent(as: first))
                } else { XCTAssertTrue(try recovered.recommitExact(operationID: first.operationID).record.sameIntent(as: first)) }
                XCTAssertEqual(try current(root), first.candidate)
            }
        }
    }
    func testVisibleCandidateDoesNotAcknowledgeCommit() throws {
        let root = try directory(); try DeviceStructuralStore(root: root, rootID: rootID).initializeExplicit()
        let first = try record(1)
        let interrupted = DeviceStructuralStore(root: root, rootID: rootID) { if $0 == .afterReplace(.envelope) { throw DeviceStructuralStoreError.io(EIO) } }
        try interrupted.initializeExplicit(); try interrupted.prepare(first); XCTAssertThrowsError(try interrupted.attempt(operationID: first.operationID))
        XCTAssertEqual(try current(root), first.candidate)
        let diagnosis = DeviceStructuralStore(root: root, rootID: rootID)
        guard case .candidateNeedsDurability(let prepared) = try diagnosis.recover(operationID: first.operationID) else { return XCTFail("candidate expected") }; XCTAssertTrue(prepared.sameIntent(as: first))
        let repairFault = DeviceStructuralStore(root: root, rootID: rootID) { if $0 == .afterFileSync(.envelope) { throw DeviceStructuralStoreError.io(EIO) } }
        XCTAssertThrowsError(try repairFault.recommitExact(operationID: first.operationID))
        XCTAssertTrue(try diagnosis.recommitExact(operationID: first.operationID).record.sameIntent(as: first))
    }
    func testExternalReplacementSymlinksSpecialNodesAndRootBinding() throws {
        let root = try directory(); let store = DeviceStructuralStore(root: root, rootID: rootID)
        try store.initializeExplicit(); let first = try record(1); try store.prepare(first)
        let replacement = DeviceStructuralStore(root: root, rootID: rootID) { point in
            if point == .beforeReplace(.envelope) { try Data("external".utf8).write(to: root.appendingPathComponent("structural-envelope.json")) }
        }
        XCTAssertThrowsError(try replacement.attempt(operationID: first.operationID))
        XCTAssertThrowsError(try store.recover(operationID: first.operationID))
        XCTAssertThrowsError(try DeviceStructuralStore(root: root, rootID: id(99)).initializeExplicit())
        let root2 = try directory(); let other = DeviceStructuralStore(root: root2, rootID: rootID); try other.initializeExplicit(); try other.prepare(first)
        let lock = root2.appendingPathComponent("structural.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: root.appendingPathComponent("structural.lock"))
        XCTAssertThrowsError(try other.recover(operationID: first.operationID))
        let root3 = try directory(); let special = DeviceStructuralStore(root: root3, rootID: rootID); try special.initializeExplicit(); try special.prepare(first)
        XCTAssertEqual(mkfifo(root3.appendingPathComponent("structural-envelope.json").path, 0o600), 0)
        XCTAssertThrowsError(try special.recover(operationID: first.operationID))
        let root4 = try directory(); let moved = root4.appendingPathExtension("moved")
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
        let swapping = DeviceStructuralStore(root: root4, rootID: rootID) { point in
            if point == .beforeReplace(.envelope) {
                try FileManager.default.moveItem(at: root4, to: moved)
                try FileManager.default.createDirectory(at: root4, withIntermediateDirectories: false)
            }
        }
        try swapping.initializeExplicit(); try swapping.prepare(first)
        XCTAssertThrowsError(try swapping.attempt(operationID: first.operationID))
    }
    func testSameBytesReplacementAndMissingTerminalChainBlockReplay() throws {
        let root = try directory(); let store = DeviceStructuralStore(root: root, rootID: rootID)
        try store.initializeExplicit(); let first = try record(1); try store.prepare(first); _ = try store.attempt(operationID: first.operationID)
        let next = try record(2, old: first.candidate); try store.prepare(next)
        let replacing = DeviceStructuralStore(root: root, rootID: rootID) { point in
            if point == .beforeReplace(.envelope) {
                try first.candidate.write(to: root.appendingPathComponent("structural-envelope.json"), options: .atomic)
            }
        }
        XCTAssertThrowsError(try replacing.attempt(operationID: next.operationID))
        XCTAssertThrowsError(try store.recommitExact(operationID: next.operationID))
        XCTAssertThrowsError(try DeviceStructuralStore(root: root, rootID: rootID).recommitExact(operationID: next.operationID))
        let proof = root.appendingPathComponent("operations/" + first.operationID.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: proof)
        XCTAssertThrowsError(try store.recover(operationID: next.operationID))
        let lock = root.appendingPathComponent("structural.lock")
        try Data().write(to: lock, options: .atomic)
        XCTAssertThrowsError(try DeviceStructuralStore(root: root, rootID: rootID).recover(operationID: next.operationID))
    }
    func testRestartAndSharedUncertaintyQualificationGate() throws {
        let root = try directory(); let a = DeviceStructuralStore(root: root, rootID: rootID)
        try a.initializeExplicit(); let first = try record(1); try a.prepare(first); _ = try a.attempt(operationID: first.operationID)
        let next = try record(2, old: first.candidate)
        let restarted = DeviceStructuralStore(root: root, rootID: rootID)
        XCTAssertThrowsError(try restarted.prepare(next))
        let b = DeviceStructuralStore(root: root, rootID: rootID) { if $0 == .afterReplace(.terminal) { throw DeviceStructuralStoreError.io(EIO) } }
        XCTAssertThrowsError(try b.recommitExact(operationID: first.operationID))
        XCTAssertThrowsError(try a.prepare(next))
        XCTAssertThrowsError(try restarted.prepare(next))
        _ = try a.recommitExact(operationID: first.operationID); try a.prepare(next)
        _ = try a.attempt(operationID: next.operationID)
        _ = try restarted.recommitExact(operationID: first.operationID)
        XCTAssertThrowsError(try restarted.prepare(record(3, old: next.candidate)))
        XCTAssertEqual(try current(root), next.candidate)
    }
    func testVisibleBindingRequiresExplicitInitializationRecovery() throws {
        let root = try directory()
        let interrupted = DeviceStructuralStore(root: root, rootID: rootID) { if $0 == .afterReplace(.binding) { throw DeviceStructuralStoreError.io(EIO) } }
        XCTAssertThrowsError(try interrupted.initializeExplicit())
        let first = try record(1)
        XCTAssertThrowsError(try interrupted.prepare(first))
        let reconstructed = DeviceStructuralStore(root: root, rootID: rootID)
        XCTAssertThrowsError(try reconstructed.prepare(first))
        try reconstructed.initializeExplicit()
        try reconstructed.prepare(first)
        XCTAssertTrue(try reconstructed.attempt(operationID: first.operationID).record.sameIntent(as: first))
    }
    func testVisibleTerminalDoesNotPermitNextPrepareUntilExactRepair() throws {
        let root = try directory(); let first = try record(1)
        let failing = DeviceStructuralStore(root: root, rootID: rootID) { if $0 == .afterReplace(.terminal) { throw DeviceStructuralStoreError.io(EIO) } }
        try failing.initializeExplicit(); try failing.prepare(first)
        XCTAssertThrowsError(try failing.attempt(operationID: first.operationID))
        let restarted = DeviceStructuralStore(root: root, rootID: rootID)
        let next = try record(2, old: first.candidate)
        XCTAssertThrowsError(try restarted.prepare(next))
        _ = try restarted.recommitExact(operationID: first.operationID)
        try restarted.prepare(next)
    }
    func testCommittedAndUncertainCandidateSameByteReplacementBlocksRestart() throws {
        for uncertain in [false, true] {
            let root = try directory(); let first = try record(1)
            let store = DeviceStructuralStore(root: root, rootID: rootID) { if uncertain && $0 == .afterReplace(.envelope) { throw DeviceStructuralStoreError.io(EIO) } }
            try store.initializeExplicit(); try store.prepare(first)
            if uncertain { XCTAssertThrowsError(try store.attempt(operationID: first.operationID)) }
            else { _ = try store.attempt(operationID: first.operationID) }
            try first.candidate.write(to: root.appendingPathComponent("structural-envelope.json"), options: .atomic)
            XCTAssertThrowsError(try store.recommitExact(operationID: first.operationID))
            XCTAssertThrowsError(try DeviceStructuralStore(root: root, rootID: rootID).recommitExact(operationID: first.operationID))
        }
    }
    func testMalformedSurrogatesAndEnvelopePayloadBounds() throws {
        XCTAssertThrowsError(try StructuralStoreCodec.object(Data("{\"x\":\"\\uD800\"}".utf8), limit: 8192))
        XCTAssertThrowsError(try StructuralStoreCodec.object(Data("{\"x\":\"\\uDC00\"}".utf8), limit: 8192))
        XCTAssertNoThrow(try StructuralStoreCodec.object(Data("{\"x\":\"\\uD83D\\uDE00\"}".utf8), limit: 8192))
        let first = try record(1); let original = try StructuralStoreCodec.envelope(first.candidate)
        let oversized = DeviceStructuralCommitEnvelope(operationID: original.operationID, expectedGenerationID: nil,
            snapshot: original.snapshot, intent: Data(repeating: 0, count: 32*1024+1), outcome: Data())
        XCTAssertThrowsError(try StructuralStoreCodec.envelope(StructuralStoreCodec.encode(oversized)))
    }
    func testOneUnresolvedCapacityAndNeverPruneTerminalProof() throws {
        let root = try directory(); let store = DeviceStructuralStore(root: root, rootID: rootID); try store.initializeExplicit()
        var old: Data?
        for operation in 1...128 {
            let item = try record(operation, old: old); try store.prepare(item)
            if operation == 1 { XCTAssertThrowsError(try store.prepare(record(999))) }
            _ = try store.attempt(operationID: item.operationID); old = item.candidate
        }
        XCTAssertThrowsError(try store.prepare(record(129, old: old))) { XCTAssertEqual($0 as? DeviceStructuralStoreError, .capacity) }
        XCTAssertEqual(try store.attempt(operationID: id(1)).record.operationID, id(1))
        XCTAssertEqual(try current(root), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("operations").path).count, 128)
    }
    func testStrictEnvelopeAndRecordBoundsAndUntrustedResources() throws {
        let root = try directory(); let store = DeviceStructuralStore(root: root, rootID: rootID); try store.initializeExplicit()
        let first = try record(1)
        let text = String(decoding: first.candidate, as: UTF8.self)
        for altered in [text + "{}", text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schema\\u0056ersion\":1"), text.replacingOccurrences(of: "exact intent", with: "\\uD800")] {
            // Base64 payload does not contain plaintext intent; duplicate/trailing cases are exercised below.
            if altered == text { continue }
            XCTAssertThrowsError(try StructuralStoreCodec.envelope(Data(altered.utf8)))
        }
        var object = try JSONSerialization.jsonObject(with: first.candidate) as! [String: Any]
        var snapshot = object["snapshot"] as! [String: Any]; snapshot["future"] = true; object["snapshot"] = snapshot
        XCTAssertThrowsError(try StructuralStoreCodec.envelope(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try StructuralStoreCodec.envelope(Data(repeating: 32, count: 128*1024+1)))
        XCTAssertThrowsError(try StructuralStoreCodec.record(Data(repeating: 32, count: 384*1024+1)))
        XCTAssertThrowsError(try store.prepare(record(1, assertions: Data(repeating: 0, count: 8*1024+1))))
        let asserted = try record(1, assertions: Data("not proof of packages or grants".utf8)); try store.prepare(asserted)
        XCTAssertEqual(try store.attempt(operationID: asserted.operationID).record.resourceAssertions, asserted.resourceAssertions)
    }
}
