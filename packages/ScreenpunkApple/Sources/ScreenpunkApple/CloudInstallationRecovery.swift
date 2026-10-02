import Foundation
import ScreenpunkCore

public protocol CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionRecord?
    func save(_ record: DeviceManagementTransitionRecord) throws
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

    /// Classification never deletes a credential or turns unknown activation into Local authority.
    public static func localEligibility(journal: any CloudInstallationTransitionJournal,
                                        credentials: CloudInstallationCredentialStore) -> LocalEligibility {
        let record: DeviceManagementTransitionRecord?
        do { record = try journal.load() } catch { return .blocked(.journalUnavailable) }
        let references: Set<String>
        do { references = try credentials.references() } catch { return .blocked(.credentialUnavailable) }
        guard let record else { return references.isEmpty ? .legacyLocal : .blocked(.orphanedCredential) }
        guard references.subtracting([record.credentialReference]).isEmpty else { return .blocked(.orphanedCredential) }
        guard references.contains(record.credentialReference) else { return .blocked(.missingCredential) }
        do {
            guard try credentials.secret(for: record.credentialReference) != nil else { return .blocked(.missingCredential) }
        } catch { return .blocked(.credentialUnavailable) }
        switch record.phase {
        case .intent: return .blocked(.pendingIntent)
        case .locallyFenced: return .locallyFenced
        }
    }

    /// Durable intent/reference must precede random generation and Keychain insertion.
    /// Returned bytes have been verified at the same immutable reference; never log them.
    public static func stageIntent(_ record: DeviceManagementTransitionRecord,
                                   journal: any CloudInstallationTransitionJournal,
                                   credentials: CloudInstallationCredentialStore) throws -> Data {
        guard record.phase == .intent else { throw CloudInstallationStagingError.notIntent }
        let existing = try journal.load()
        let references = try credentials.references()
        if let existing {
            guard existing == record else { throw CloudInstallationStagingError.transitionConflict }
            guard references.subtracting([record.credentialReference]).isEmpty else { throw CloudInstallationStagingError.orphanedCredential }
            // Existing intent cannot distinguish a pre-key crash from a lost key after a remote attempt.
            guard references.contains(record.credentialReference),
                  let secret = try credentials.secret(for: record.credentialReference) else { throw CloudInstallationStagingError.missingCredential }
            guard try journal.load() == record else { throw CloudInstallationStagingError.unconfirmedIntent }
            return secret
        }
        guard references.isEmpty else { throw CloudInstallationStagingError.orphanedCredential }
        try journal.save(record)
        guard try journal.load() == record else { throw CloudInstallationStagingError.unconfirmedIntent }
        let secret = try credentials.stage(reference: record.credentialReference)
        guard try journal.load() == record else { throw CloudInstallationStagingError.unconfirmedIntent }
        return secret
    }
}
