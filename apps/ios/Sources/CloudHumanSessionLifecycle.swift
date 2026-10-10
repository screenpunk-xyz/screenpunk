import AuthenticationServices
import Combine
import ScreenpunkApple
import ScreenpunkCore
import UIKit
import SwiftUI

/// One human session; this does not enroll or manage the installation.
@MainActor
final class CloudHumanSession {
    let coordinator: CloudConnectionCoordinator?
    private let callback: (URL) -> Bool
    private let revoke: () -> Void
    private var lease: CloudHumanSessionBroker.Lease?
    private let enrollmentTokens: (() throws -> any CloudNativeTokenProvider)?

    private init(identity: CloudNativeIdentity, coordinator: CloudConnectionCoordinator) {
        self.coordinator = coordinator
        enrollmentTokens = { try identity.tokenProvider() }
        callback = { identity.handleGoogleCallback($0) }
        revoke = { coordinator.cancel() }
    }

    /// Explicit future presentation entry only. Configuration is validated before creating
    /// the journal/coordinator; no SDK initializes until an explicit provider sign-in.
    static func make(lease: CloudHumanSessionBroker.Lease, googlePresentation: @escaping () throws -> UIViewController,
                     applePresentation: @escaping () throws -> ASPresentationAnchor,
                     transport: any HTTPTransport,
                     journal: (any CloudWorkspaceSetupJournal)? = nil) throws -> CloudHumanSession {
        try lease.checkConstruction()
        let configuration = try CloudNativeConfiguration.load()
        let identity = CloudNativeIdentity()
        let coordinator = CloudConnectionCoordinator(authenticate: { provider in
            try lease.checkHumanAction()
            switch provider {
            case .google: try await identity.signInWithGoogle(presenting: googlePresentation())
            case .apple: try await identity.signInWithApple(presentationAnchor: applePresentation())
            }
            try lease.checkHumanAction()
            return try identity.tokenProvider()
        }, cancelIdentityFlow: { if lease.isCurrent { identity.cancelActiveFlow() } },
           signOutIdentity: { try lease.checkSettlement(); try await identity.requestSignOut() },
           retrySignOutIdentity: { try lease.checkSettlement(); try await identity.retrySignOut() },
           makeClient: { try lease.checkHumanAction(); return try CloudNativeClient(baseURL: configuration.apiOrigin, tokenProvider: $0, transport: transport) },
           journal: journal)
        return CloudHumanSession(identity: identity, coordinator: coordinator)
    }

    /// Internal fake seam supplies behavior, never a mismatched production identity/coordinator pair.
    init(testCallback: @escaping (URL) -> Bool, testRevoke: @escaping () -> Void) {
        coordinator = nil; enrollmentTokens = nil; callback = testCallback; revoke = testRevoke
    }
    init(testCoordinator: CloudConnectionCoordinator, testCallback: @escaping (URL) -> Bool,
         testEnrollmentTokens: (() throws -> any CloudNativeTokenProvider)? = nil) {
        enrollmentTokens = testEnrollmentTokens
        coordinator = testCoordinator; callback = testCallback
        revoke = { testCoordinator.cancel() }
    }
    func enrollmentSelection(accountID: UUID, locationID: UUID?) throws -> CloudEnrollmentSelection {
        guard let lease, let coordinator, let identity = coordinator.humanIdentity, let enrollmentTokens else { throw CloudNativeIdentityError.providerFailed }
        func validate() throws {
            try lease.checkHumanAction()
            guard coordinator.humanIdentity == identity, !coordinator.isWorking, coordinator.signOutState == .idle,
                coordinator.selectedAccountID == accountID,
                coordinator.accounts.contains(where: { $0.id == accountID && $0.capabilities.canEnroll && (locationID != nil || $0.capabilities.canEnrollUnassigned) }),
                (locationID == nil || coordinator.locations.contains(where: { $0.id == locationID && $0.capabilities.canEnroll })) else { throw CancellationError() }
        }
        try validate()
        return CloudEnrollmentSelection(accountID: accountID, locationID: locationID,
            tokens: CloudEnrollmentTokenScope(provider: try enrollmentTokens(), validate: validate))
    }
    func bind(_ lease: CloudHumanSessionBroker.Lease) { self.lease = lease }
    func handleCallback(_ url: URL) -> Bool {
        guard (try? lease?.checkHumanAction()) != nil else { return false }; return callback(url)
    }
    func cancel() { if lease?.isCurrent == true { revoke() } }
    func signOut() -> Task<Void, Never>? { coordinator?.signOut() }
    func retrySignOut() -> Task<Void, Never>? { coordinator?.retrySignOut() }
}

/// Scene attachment to one process-owned pair. Presentation revocation preserves
/// unresolved workspace persistence; retirement cleanup outlives the scene.
@MainActor
final class CloudHumanSessionLifecycle: ObservableObject {
    enum Failure: Error { case alreadyInstalled, retired }
    enum AccountEntryState: Equatable { case available, ownedHere, occupiedElsewhere, retired }
    /// Presentation only. The broker still authorizes every acquisition and action.
    var accountEntryState: AccountEntryState {
        if retired { return .retired }
        if lease?.isCurrent == true { return .ownedHere }
        return broker.state == .vacant ? .available : .occupiedElsewhere
    }
    private let broker: CloudHumanSessionBroker
    private let owner = UUID()
    private var originalRevocationObservers: [UUID: () -> Void] = [:]
    @discardableResult func observeOriginalRevocation(_ action: @escaping () -> Void) -> UUID {
        let id = UUID(); originalRevocationObservers[id] = action; return id
    }
    func removeOriginalRevocationObserver(_ id: UUID) { originalRevocationObservers.removeValue(forKey: id) }
    private func revokeOriginalPresentations() {
        // Synchronous notifications before human/session mutation. They grant no authority.
        for action in Array(originalRevocationObservers.values) { action() }
    }
    @Published private var lease: CloudHumanSessionBroker.Lease?
    @Published private var retired = false
    private var observation: AnyCancellable?
    private var retirement: CloudSceneRetirement?
    var coordinator: CloudConnectionCoordinator? { retired ? nil : lease.flatMap { broker.session(for: $0)?.coordinator } }
    init(broker: CloudHumanSessionBroker? = nil) {
        let resolved = broker ?? .shared
        self.broker = resolved
        observation = resolved.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    /// Internal fake-only seam. Production installation reserves before invoking its factory.
    func install(_ session: CloudHumanSession) throws { try install(factory: { _ in session }) }
    func install(factory: (CloudHumanSessionBroker.Lease) throws -> CloudHumanSession) throws {
        guard !retired else { throw Failure.retired }
        guard lease?.isCurrent != true else { throw Failure.alreadyInstalled }
        let acquired = try broker.acquire(owner: owner, factory: factory)
        lease = acquired
        retirement = CloudSceneRetirement(broker: broker, lease: acquired)
    }
    func installExplicit(presentation: CloudProviderPresentation, testFactory: ((CloudProviderPresentation) throws -> CloudHumanSession)? = nil) throws {
        try install { lease in
            if let testFactory { return try testFactory(presentation) }
            return try CloudHumanSession.make(lease: lease,
                googlePresentation: { try presentation.resolve().controller },
                applePresentation: { try presentation.resolve().window }, transport: CloudNativeURLSessionTransport())
        }
    }
    func enrollmentSelection(accountID: UUID, locationID: UUID?) throws -> CloudEnrollmentSelection {
        guard !retired, let lease, let session = broker.session(for: lease) else { throw Failure.retired }
        return try session.enrollmentSelection(accountID: accountID, locationID: locationID)
    }
    /// A live scene may transport a callback to the process owner, without acquiring
    /// cancellation or session rights. Retired scenes do not transport callbacks.
    func dispatchGoogleCallback(_ url: URL) -> Bool {
        guard !retired else { return false }
        return broker.dispatchGoogleCallback(url)
    }
    func handleCallback(_ url: URL) -> Bool {
        guard !retired, let lease else { return false }; return broker.session(for: lease)?.handleCallback(url) ?? false
    }
    @discardableResult func signOut() -> Task<Void, Never>? {
        guard !retired, let lease else { return nil }; revokeOriginalPresentations(); return broker.signOut(lease)
    }
    @discardableResult func retrySignOut() -> Task<Void, Never>? {
        guard !retired, let lease else { return nil }; return broker.retrySignOut(lease)
    }
    var retiredCleanupState: CloudHumanSessionBroker.RetiredCleanupState {
        retired ? .none : broker.retiredCleanupState
    }
    /// A later live scene can request exact retired cleanup, without installing a pair.
    @discardableResult func retryRetiredCleanup(_ handle: CloudHumanSessionBroker.RetiredCleanupHandle) -> Task<Void, Never>? {
        guard !retired else { return nil }
        return broker.retryRetiredCleanup(handle)
    }
    func cancelPresentation() { if !retired, let lease { revokeOriginalPresentations(); broker.cancel(lease) } }
    func didEnterBackground() { cancelPresentation() }
    func scenePhaseChanged(_ phase: ScenePhase) { if phase == .background { didEnterBackground() } }
    func retirePresentationContext() {
        guard !retired else { return }
        revokeOriginalPresentations()
        retired = true
        if let lease { broker.retire(lease) }
    }
}

/// Last-resort actual attachment retirement, independent of SwiftUI cover disappearances.
/// Its actor task retains cleanup ownership if the scene drops without an explicit callback.
private final class CloudSceneRetirement: Sendable {
    let broker: CloudHumanSessionBroker
    let lease: CloudHumanSessionBroker.Lease
    init(broker: CloudHumanSessionBroker, lease: CloudHumanSessionBroker.Lease) { self.broker = broker; self.lease = lease }
    deinit { Task { @MainActor [broker, lease] in _ = broker.retire(lease) } }
}

/// Genuine selected response IDs, never caller-created identity or admission evidence.
@MainActor struct CloudEnrollmentSelection {
    let accountID: UUID
    let locationID: UUID?
    let tokens: CloudEnrollmentTokenScope
    func validate() throws { try tokens.validateCurrent() }
}
@MainActor final class CloudEnrollmentTokenScope: CloudNativeTokenProvider {
    private let provider: any CloudNativeTokenProvider
    private let validate: () throws -> Void
    init(provider: any CloudNativeTokenProvider, validate: @escaping () throws -> Void) {
        self.provider = provider; self.validate = validate
    }
    func validateCurrent() throws { try validate() }
    func idToken() async throws -> String {
        try Task.checkCancellation(); try validate()
        let token = try await provider.idToken()
        try Task.checkCancellation(); try validate(); return token
    }
}
