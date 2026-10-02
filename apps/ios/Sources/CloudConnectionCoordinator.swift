import Combine
import Foundation
import ScreenpunkCore

/// Human identity and workspace discovery only. It never enrolls or manages this installation.
@MainActor
final class CloudConnectionCoordinator: ObservableObject {
    enum Failure: Equatable { case authentication, discovery, signOut, persistence, workspaceSetup, pendingOtherUser, setupNotEligible }
    @Published private(set) var humanIdentity: CloudNativeSignInResponse?
    @Published private(set) var accounts: [CloudNativeAccount] = []
    @Published private(set) var locations: [CloudNativeLocation] = []
    @Published private(set) var selectedAccountID: UUID?
    @Published private(set) var isWorking = false
    @Published private(set) var failure: Failure?

    @Published private(set) var pendingWorkspaceSetup: CloudWorkspaceSetupJournalRecord?
    @Published private(set) var workspaceSetupFailure: CloudNativeFailure?
    @Published private(set) var workspaceSetupReceipt: CloudNativeWorkspaceSetupReceipt?
    private let journal: any CloudWorkspaceSetupJournal
    private var accountsDiscoveryComplete = false
    private var journalReadable = false
    private var journalRecord: CloudWorkspaceSetupJournalRecord?

    private let authenticate: (CloudNativeSignInProvider) async throws -> any CloudNativeTokenProvider
    private let cancelIdentityFlow: () -> Void
    private let signOutIdentity: () throws -> Void
    private let makeClient: (any CloudNativeTokenProvider) throws -> CloudNativeClient
    private var client: CloudNativeClient?
    private var generation = UUID()
    private var operation: Task<Void, Never>?

    /// The explicit provider operation captures its presentation context outside this coordinator.
    init(authenticate: @escaping (CloudNativeSignInProvider) async throws -> any CloudNativeTokenProvider,
         cancelIdentityFlow: @escaping () -> Void, signOutIdentity: @escaping () throws -> Void,
         makeClient: @escaping (any CloudNativeTokenProvider) throws -> CloudNativeClient,
         journal: (any CloudWorkspaceSetupJournal)? = nil) {
        self.journal = journal ?? CloudWorkspaceSetupFileJournal.applicationJournal()
        self.authenticate = authenticate
        self.cancelIdentityFlow = cancelIdentityFlow
        self.signOutIdentity = signOutIdentity
        self.makeClient = makeClient
    }

    /// A duplicate request is rejected while the current operation is running.
    @discardableResult
    func signIn(provider: CloudNativeSignInProvider) -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        revoke()
        let generation = self.generation
        isWorking = true
        let operation = Task { [weak self] in
            guard let self else { return }
            var failureKind = Failure.authentication
            defer { finish(generation) }
            do {
                try check(generation)
                let tokens = try await authenticate(provider)
                try check(generation)
                let client = try makeClient(tokens)
                let identity = try await client.signIn()
                try check(generation)
                failureKind = .discovery
                let accounts = try await client.allAccounts()
                try check(generation)
                self.client = client
                humanIdentity = identity
                self.accounts = accounts
                accountsDiscoveryComplete = true
                refreshJournal(userID: identity.user.id)
            } catch {
                guard self.generation == generation else { return }
                clearDiscovery()
                cancelIdentityFlow()
                if !Task.isCancelled && !(error is CancellationError) && (error as? CloudNativeIdentityError) != .cancelled && (error as? CloudNativeFailure) != .cancelled {
                    failure = failureKind
                }
            }
        }
        self.operation = operation
        return operation
    }

    @discardableResult
    func discoverLocations(accountID: UUID) -> Task<Void, Never>? {
        guard !isWorking, let client, accounts.contains(where: { $0.id == accountID }) else { return nil }
        let generation = self.generation
        selectedAccountID = accountID
        workspaceSetupFailure = nil
        locations = []
        failure = nil
        isWorking = true
        let operation = Task { [weak self] in
            guard let self else { return }
            defer { finish(generation) }
            do {
                try check(generation)
                let locations = try await client.allLocations(accountID: accountID)
                try check(generation)
                self.locations = locations
            } catch {
                guard self.generation == generation else { return }
                locations = []
                selectedAccountID = nil
                if !Task.isCancelled && !(error is CancellationError) && (error as? CloudNativeFailure) != .cancelled { failure = .discovery }
            }
        }
        self.operation = operation
        return operation
    }

    /// Available only after complete successful empty discovery and resolved prior operations.
    var canCreateFirstWorkspace: Bool {
        humanIdentity != nil && client != nil && accountsDiscoveryComplete && accounts.isEmpty && !isWorking && journalReadable && (journalRecord == nil || journalRecord?.receipt != nil)
    }

    @discardableResult
    func createFirstWorkspace(workspaceName: String, locationName: String) -> Task<Void, Never>? {
        guard !isWorking, let identity = humanIdentity, let client else { return nil }
        workspaceSetupFailure = nil
        refreshJournal(userID: identity.user.id)
        guard canCreateFirstWorkspace else { failure = failure ?? .setupNotEligible; return nil }
        let record: CloudWorkspaceSetupJournalRecord
        do {
            let request = try CloudNativeWorkspaceSetupRequest(requestId: UUID(), workspaceName: workspaceName, locationName: locationName)
            record = try .init(userID: identity.user.id, request: request)
        } catch { failure = .workspaceSetup; return nil }
        do { try journal.save(record) } catch {
            // A failed filesystem write may be uncertain; reload before allowing another operation.
            refreshJournal(userID: identity.user.id)
            failure = .persistence
            return nil
        }
        journalRecord = record; pendingWorkspaceSetup = record; workspaceSetupReceipt = nil
        return submitWorkspaceSetup(record, client: client, lookup: false)
    }

    /// Explicit same-user reconciliation; GET 404 never clears the saved operation.
    @discardableResult
    func recoverWorkspaceSetup() -> Task<Void, Never>? { resumeWorkspaceSetup(lookup: true) }
    /// Explicit identical POST replay uses the saved UUID and exact names, never new input.
    @discardableResult
    func retryWorkspaceSetup() -> Task<Void, Never>? { resumeWorkspaceSetup(lookup: false) }

    private func resumeWorkspaceSetup(lookup: Bool) -> Task<Void, Never>? {
        guard !isWorking, let identity = humanIdentity, let client else { return nil }
        workspaceSetupFailure = nil
        refreshJournal(userID: identity.user.id)
        guard journalReadable, let record = journalRecord else { return nil }
        guard record.userID == identity.user.id else { failure = .pendingOtherUser; return nil }
        return submitWorkspaceSetup(record, client: client, lookup: lookup)
    }

    private func submitWorkspaceSetup(_ record: CloudWorkspaceSetupJournalRecord, client: CloudNativeClient, lookup: Bool) -> Task<Void, Never> {
        let generation = self.generation
        isWorking = true; failure = nil; workspaceSetupFailure = nil
        let operation = Task { [weak self] in
            guard let self else { return }
            defer { finish(generation) }
            do {
                try check(generation)
                let receipt: CloudNativeWorkspaceSetupReceipt
                if lookup { receipt = try await client.workspaceSetup(requestID: record.request.requestId) }
                else { receipt = try await client.setupWorkspace(request: record.request) }
                try check(generation)
                guard humanIdentity?.user.id == record.userID else { throw CancellationError() }
                accountsDiscoveryComplete = false
                let completed = try CloudWorkspaceSetupJournalRecord(userID: record.userID, request: record.request, receipt: receipt)
                do { try journal.save(completed) } catch { failure = .persistence; return }
                journalRecord = completed; pendingWorkspaceSetup = nil; workspaceSetupReceipt = receipt
                // Receipt supplies discovery IDs, never enrollment or management authority.
            } catch {
                guard self.generation == generation else { return }
                if !Task.isCancelled && !(error is CancellationError) && (error as? CloudNativeFailure) != .cancelled {
                    failure = .workspaceSetup
                    workspaceSetupFailure = error as? CloudNativeFailure
                }
            }
        }
        self.operation = operation
        return operation
    }

    private func refreshJournal(userID: UUID) {
        do {
            journalRecord = try journal.load(); journalReadable = true
            if let record = journalRecord, record.userID == userID {
                pendingWorkspaceSetup = record.receipt == nil ? record : nil
                workspaceSetupReceipt = record.receipt
            } else {
                pendingWorkspaceSetup = nil; workspaceSetupReceipt = nil
                if journalRecord?.receipt == nil && journalRecord != nil { failure = .pendingOtherUser }
            }
        } catch {
            journalReadable = false; pendingWorkspaceSetup = nil; workspaceSetupReceipt = nil; failure = .persistence
        }
    }

    /// Clear all identity-dependent presentation synchronously, before SDK or network completion.
    func cancel() { revoke() }
    func signOut() {
        revoke()
        do { try signOutIdentity() } catch { failure = .signOut }
    }

    private func revoke() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        isWorking = false
        failure = nil
        clearDiscovery()
        cancelIdentityFlow()
    }
    private func clearDiscovery() {
        client = nil
        humanIdentity = nil
        accounts = []
        locations = []
        selectedAccountID = nil
        pendingWorkspaceSetup = nil
        workspaceSetupReceipt = nil
        workspaceSetupFailure = nil
        journalRecord = nil
        journalReadable = false
        accountsDiscoveryComplete = false
    }
    private func check(_ expected: UUID) throws {
        guard !Task.isCancelled, generation == expected else { throw CancellationError() }
    }
    private func finish(_ expected: UUID) {
        guard generation == expected else { return }
        operation = nil
        isWorking = false
    }
}
