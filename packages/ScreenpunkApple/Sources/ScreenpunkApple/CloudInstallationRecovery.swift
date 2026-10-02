import Foundation
import ScreenpunkCore

public protocol CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionHistory?
    func save(_ history: DeviceManagementTransitionHistory) throws
}
extension DeviceManagementTransitionStore: CloudInstallationTransitionJournal {}

public enum CloudInstallationStagingError: Error, Equatable { case notIntent, transitionConflict, unconfirmedIntent, missingCredential, orphanedCredential }

/// No claim or activation request is performed by these local primitives.
public enum CloudInstallationRecovery {
    public enum LocalEligibility: Equatable {
        case legacyLocal, locallyFenced
        case blocked(Reason)
    }
    public enum Reason: Equatable { case journalUnavailable, credentialUnavailable, orphanedCredential, missingCredential, pendingIntent }

    /// Snapshot evidence only: future callers must serialize authority changes and startup.
    /// Classification never deletes a credential or infers remote cleanup completion.
    public static func localEligibility(journal: any CloudInstallationTransitionJournal,
                                        credentials: CloudInstallationCredentialStore) -> LocalEligibility {
        let history: DeviceManagementTransitionHistory?
        do { history = try journal.load() } catch { return .blocked(.journalUnavailable) }
        let references: Set<String>
        do { references = try credentials.references() } catch { return .blocked(.credentialUnavailable) }
        guard let history else { return references.isEmpty ? .legacyLocal : .blocked(.orphanedCredential) }
        let recorded = Set(history.credentials.map(\.credentialReference))
        guard references.subtracting(recorded).isEmpty else { return .blocked(.orphanedCredential) }
        guard references == recorded else { return .blocked(.missingCredential) }
        do {
            for reference in recorded {
                guard try credentials.secret(for: reference) != nil else { return .blocked(.missingCredential) }
            }
        } catch { return .blocked(.credentialUnavailable) }
        guard history.transitions.allSatisfy({ $0.phase == .locallyFenced }) else { return .blocked(.pendingIntent) }
        return .locallyFenced
    }

    /// Persist one exact append before creating its new immutable credential generation.
    /// Existing persisted bindings always load existing keys; missing keys never regenerate.
    public static func stageCredential(_ proposed: DeviceManagementTransitionHistory,
                                       credentialGenerationID: UUID,
                                       journal: any CloudInstallationTransitionJournal,
                                       credentials: CloudInstallationCredentialStore) throws -> Data {
        guard let transition = proposed.transitions.last, transition.phase == .intent,
              let binding = proposed.credentials.first(where: { $0.credentialGenerationID == credentialGenerationID }),
              binding.transitionID == transition.transitionID else { throw CloudInstallationStagingError.notIntent }
        let existing = try journal.load()
        let references = try credentials.references()
        let recorded = Set(existing?.credentials.map(\.credentialReference) ?? [])
        guard references.subtracting(recorded).isEmpty else { throw CloudInstallationStagingError.orphanedCredential }
        guard references == recorded else { throw CloudInstallationStagingError.missingCredential }
        // Retained prior generations, including same-intent generations, must remain readable.
        for reference in recorded {
            guard try credentials.secret(for: reference) != nil else { throw CloudInstallationStagingError.missingCredential }
        }
        if let existing, existing.credentials.contains(where: { $0.credentialGenerationID == credentialGenerationID }) {
            guard existing == proposed else { throw CloudInstallationStagingError.transitionConflict }
            guard let secret = try credentials.secret(for: binding.credentialReference) else { throw CloudInstallationStagingError.missingCredential }
            guard try journal.load() == proposed else { throw CloudInstallationStagingError.unconfirmedIntent }
            return secret
        }
        let expected: DeviceManagementTransitionHistory
        do {
            if let existing {
                if existing.transitions.last?.phase == .intent {
                    expected = try existing.appendingCredential(credentialGenerationID: credentialGenerationID, credentialReference: binding.credentialReference)
                } else {
                    expected = try existing.appendingIntent(transitionID: transition.transitionID, credentialGenerationID: credentialGenerationID, credentialReference: binding.credentialReference)
                }
            } else {
                expected = try .intent(transitionID: transition.transitionID, credentialGenerationID: credentialGenerationID, credentialReference: binding.credentialReference)
            }
        } catch { throw CloudInstallationStagingError.transitionConflict }
        guard expected == proposed else { throw CloudInstallationStagingError.transitionConflict }
        try journal.save(proposed)
        guard try journal.load() == proposed else { throw CloudInstallationStagingError.unconfirmedIntent }
        let secret = try credentials.stage(reference: binding.credentialReference)
        guard try journal.load() == proposed else { throw CloudInstallationStagingError.unconfirmedIntent }
        return secret
    }
}
