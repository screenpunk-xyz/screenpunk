/// The existing Mac Apply action persists its exact plan/key before crossing
/// the broker mutation boundary. A failed response becomes unknown and the
/// action never invokes the sender a second time.
enum MacBrokerApplyAction {
    enum Failure: Error { case unverifiedGUI, missingSubmissionMark }
    struct Outcome {
        let operationId: String
        let phase: MacBrokerApplyJournal.Record.Phase
    }

    static func submit(journal: MacBrokerApplyJournal,
                       attempt: MacBrokerApplyJournal.Record,
                       verifiedGUI: Bool,
                       send: (_ markSubmissionBoundary: () -> Void) throws -> Outcome) throws -> MacBrokerApplyJournal.Record {
        guard verifiedGUI else { throw Failure.unverifiedGUI }
        var record = attempt
        record.phase = .submitting
        record.operationId = nil
        try journal.begin(record)
        var mayHaveSubmitted = false
        do {
            let outcome = try send { mayHaveSubmitted = true }
            guard mayHaveSubmitted else {
                // A returned operation is evidence of possible submission even
                // if a caller violated the boundary-marker contract.
                mayHaveSubmitted = true
                throw Failure.missingSubmissionMark
            }
            var observed = record
            observed.operationId = outcome.operationId
            observed.phase = outcome.phase
            try journal.transition(from: record, to: observed)
            return observed
        } catch {
            var persisted = record
            persisted.phase = mayHaveSubmitted ? .unknown : .failed
            try? journal.transition(from: record, to: persisted)
            throw error
        }
    }

    static func observed(journal: MacBrokerApplyJournal,
                         record: MacBrokerApplyJournal.Record,
                         outcome: Outcome) throws -> MacBrokerApplyJournal.Record {
        var updated = record
        updated.operationId = outcome.operationId
        updated.phase = outcome.phase
        try journal.transition(from: record, to: updated)
        return updated
    }
}
