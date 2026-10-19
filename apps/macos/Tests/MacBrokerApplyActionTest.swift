import Foundation

@main
struct MacBrokerApplyActionTest {
    enum FakeFailure: Error { case lostResponse }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenpunk-apply-action-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MacBrokerApplyJournal(url: root.appendingPathComponent("attempt.json"))
        let attempt = MacBrokerApplyJournal.Record(workspaceId: "workspace-a",
            selectionGeneration: 2, deviceId: "device-a", planId: "plan-a",
            planHash: "hash-a", idempotencyKey: "stable-key", operationId: nil,
            phase: .submitting)
        var calls = 0
        precondition(!MacBrokerApplyButtonGate.allows(verifiedGUI: false, busy: false,
            selectedDeviceMatches: true, hasExactOfflinePackage: true, prior: nil))
        precondition(MacBrokerApplyButtonGate.allows(verifiedGUI: true, busy: false,
            selectedDeviceMatches: true, hasExactOfflinePackage: true, prior: nil))
        do {
            _ = try MacBrokerApplyAction.submit(journal: journal, attempt: attempt,
                verifiedGUI: false) { _ in
                calls += 1
                return .init(operationId: "must-not-send", phase: .active)
            }
            fatalError("unverified GUI accepted")
        } catch MacBrokerApplyAction.Failure.unverifiedGUI { }
        precondition(calls == 0)
        do {
            _ = try MacBrokerApplyAction.submit(journal: journal, attempt: attempt,
                verifiedGUI: true) { markSubmissionBoundary in
                calls += 1
                let persisted = try journal.load()
                precondition(persisted?.idempotencyKey == "stable-key")
                markSubmissionBoundary()
                throw FakeFailure.lostResponse
            }
            fatalError("lost response accepted")
        } catch FakeFailure.lostResponse { }
        precondition(calls == 1)
        let uncertain = try journal.load()!
        precondition(uncertain.phase == .unknown && uncertain.blocksNewApply)
        precondition(!MacBrokerApplyButtonGate.allows(verifiedGUI: true, busy: false,
            selectedDeviceMatches: true, hasExactOfflinePackage: true, prior: uncertain))
        do {
            _ = try MacBrokerApplyAction.submit(journal: MacBrokerApplyJournal(url: journal.url),
                attempt: attempt, verifiedGUI: true) { _ in
                calls += 1
                return .init(operationId: "must-not-send", phase: .active)
            }
            fatalError("second GUI sent across unresolved Apply")
        } catch MacBrokerApplyJournal.Failure.conflict { }
        precondition(calls == 1)
        // A later known operation is observed via status/reconcile, not resend.
        let active = try MacBrokerApplyAction.observed(journal: journal, record: uncertain,
            outcome: .init(operationId: "operation-a", phase: .active))
        precondition(active.phase == .active && !active.blocksNewApply && calls == 1)
        precondition(MacBrokerApplyButtonGate.allows(verifiedGUI: true, busy: false,
            selectedDeviceMatches: true, hasExactOfflinePackage: true, prior: active))
        let next = try MacBrokerApplyAction.submit(journal: journal, attempt: attempt,
            verifiedGUI: true) { markSubmissionBoundary in
            calls += 1
            markSubmissionBoundary()
            return .init(operationId: "operation-b", phase: .received)
        }
        precondition(next.phase == .received && next.blocksNewApply && calls == 2)

        let preflightJournal = MacBrokerApplyJournal(url: root.appendingPathComponent("preflight.json"))
        do {
            _ = try MacBrokerApplyAction.submit(journal: preflightJournal,
                attempt: attempt, verifiedGUI: true) { _ in
                throw FakeFailure.lostResponse
            }
            fatalError("pre-submission failure accepted")
        } catch FakeFailure.lostResponse { }
        let definiteFailure = try preflightJournal.load()
        precondition(definiteFailure?.phase == .failed && definiteFailure?.blocksNewApply == false)
        let afterPreflight = try MacBrokerApplyAction.submit(journal: preflightJournal,
            attempt: attempt, verifiedGUI: true) { markSubmissionBoundary in
            markSubmissionBoundary()
            return .init(operationId: "operation-after-preflight", phase: .admitted)
        }
        precondition(afterPreflight.phase == .admitted)
        let unmarkedJournal = MacBrokerApplyJournal(url: root.appendingPathComponent("unmarked.json"))
        do {
            _ = try MacBrokerApplyAction.submit(journal: unmarkedJournal,
                attempt: attempt, verifiedGUI: true) { _ in
                return .init(operationId: "returned-without-marker", phase: .active)
            }
            fatalError("unmarked returned operation accepted")
        } catch MacBrokerApplyAction.Failure.missingSubmissionMark { }
        let unmarked = try unmarkedJournal.load()
        precondition(unmarked?.phase == .unknown && unmarked?.blocksNewApply == true)
        print("MacBrokerApplyActionTest passed")
    }
}
