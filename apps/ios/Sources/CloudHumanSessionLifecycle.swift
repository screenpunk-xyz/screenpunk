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

    private init(identity: CloudNativeIdentity, coordinator: CloudConnectionCoordinator) {
        self.coordinator = coordinator
        callback = { identity.handleGoogleCallback($0) }
        revoke = { coordinator.cancel() }
    }

    /// Explicit future presentation entry only. Configuration is validated before creating
    /// the journal/coordinator; no SDK initializes until an explicit provider sign-in.
    static func make(googlePresentation: @escaping () throws -> UIViewController,
                     applePresentation: @escaping () throws -> ASPresentationAnchor,
                     transport: any HTTPTransport,
                     journal: (any CloudWorkspaceSetupJournal)? = nil) throws -> CloudHumanSession {
        let configuration = try CloudNativeConfiguration.load()
        let identity = CloudNativeIdentity()
        let coordinator = CloudConnectionCoordinator(authenticate: { provider in
            switch provider {
            case .google: try await identity.signInWithGoogle(presenting: googlePresentation())
            case .apple: try await identity.signInWithApple(presentationAnchor: applePresentation())
            }
            return try identity.tokenProvider()
        }, cancelIdentityFlow: { identity.cancelActiveFlow() },
           signOutIdentity: { try identity.signOut() },
           makeClient: { try CloudNativeClient(baseURL: configuration.apiOrigin, tokenProvider: $0, transport: transport) },
           journal: journal)
        return CloudHumanSession(identity: identity, coordinator: coordinator)
    }

    /// Internal fake seam supplies behavior, never a mismatched production identity/coordinator pair.
    init(testCallback: @escaping (URL) -> Bool, testRevoke: @escaping () -> Void) {
        coordinator = nil; callback = testCallback; revoke = testRevoke
    }
    init(testCoordinator: CloudConnectionCoordinator, testCallback: @escaping (URL) -> Bool) {
        coordinator = testCoordinator; callback = testCallback
        revoke = { testCoordinator.cancel() }
    }
    fileprivate func handleCallback(_ url: URL) -> Bool { callback(url) }
    fileprivate func cancel() { revoke() }
}

/// Scene-owned, dormant until explicit installation. It retains revoked persistence context.
/// Multiple concurrent Cloud scenes would require separate Google SDK singleton arbitration.
@MainActor
final class CloudHumanSessionLifecycle: ObservableObject {
    enum Failure: Error { case alreadyInstalled, retired }
    @Published private var session: CloudHumanSession?
    @Published private var retired = false
    var coordinator: CloudConnectionCoordinator? { retired ? nil : session?.coordinator }

    func install(_ session: CloudHumanSession) throws {
        guard !retired else { throw Failure.retired }
        guard self.session == nil else { throw Failure.alreadyInstalled }
        self.session = session
    }
    func handleCallback(_ url: URL) -> Bool {
        guard !retired else { return false }
        return session?.handleCallback(url) ?? false
    }
    func cancelPresentation() { if !retired { session?.cancel() } }
    func didEnterBackground() { if !retired { session?.cancel() } }
    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .background { didEnterBackground() }
    }
    func retirePresentationContext() {
        guard !retired else { return }
        retired = true
        session?.cancel()
    }
}
