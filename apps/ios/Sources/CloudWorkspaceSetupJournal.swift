import Foundation
import ScreenpunkCore
import ScreenpunkApple

/// Local operation evidence only; Core validates exact inputs and matching receipts.
typealias CloudWorkspaceSetupJournalRecord = CloudWorkspaceSetupOperationRecord

@MainActor
protocol CloudWorkspaceSetupJournal {
    func load() throws -> CloudWorkspaceSetupJournalRecord?
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws
    func beginSuccessor(_ record: CloudWorkspaceSetupJournalRecord) throws
    func retryPendingWrite(expectedUserID: UUID) throws -> CloudWorkspaceSetupJournalRecord
}

/// Protected sibling storage, never a fallback to or migration of the old plaintext file.
@MainActor
final class CloudWorkspaceSetupFileJournal: CloudWorkspaceSetupJournal {
    private let store: Result<CloudWorkspaceSetupOperationStore, Error>
    init(directory: URL, legacyJournal: URL) {
        store = Result { try .init(directory: directory, legacyJournal: legacyJournal) }
    }
    init(store: CloudWorkspaceSetupOperationStore) { self.store = .success(store) }
    static func applicationJournal() -> CloudWorkspaceSetupFileJournal {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return .init(directory: base.appendingPathComponent("xyz.screenpunk.cloud-operations", isDirectory: true),
                     legacyJournal: base.appendingPathComponent("xyz.screenpunk.device/native-workspace-setup.json"))
    }
    func load() throws -> CloudWorkspaceSetupJournalRecord? { try store.get().load() }
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws { try store.get().save(record) }
    func beginSuccessor(_ record: CloudWorkspaceSetupJournalRecord) throws { try store.get().beginSuccessor(record) }
    func retryPendingWrite(expectedUserID: UUID) throws -> CloudWorkspaceSetupJournalRecord {
        try store.get().retryPendingWrite(expectedUserID: expectedUserID)
    }
}
