import AuthenticationServices
import Combine
import CryptoKit
import FirebaseCore
import FirebaseAuth
import GoogleSignIn
import ScreenpunkCore
import UIKit

/// App-only adapter; it is not constructed by the current onboarding UI.
/// Firebase configuration and interactive provider flows require an explicit caller.
@MainActor
final class CloudNativeIdentity: ObservableObject {
    enum SignOutState: Equatable { case idle, waiting, failed, succeeded }
    @Published private(set) var signOutState: SignOutState = .idle
    private var signOutIntent: UUID?
    private var signOutWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var auth: Auth?
    private var configuration: CloudNativeConfiguration?
    private var generation = UUID()
    private struct Flow { let provider: CloudNativeSignInProvider; let generation: UUID; let cancellation = CloudFlowCancellation(); var callbackInFlight = false; var callbackAccepted = false }
    private var activeFlow: Flow?
    private var flowInProgress: Bool { activeFlow != nil }
    private(set) var interactiveUserID: String?
    private let drivers: CloudIdentityTestDrivers?

    init() { drivers = nil }
    /// Internal isolated seam: no SDK initialization, UI or network is needed by tests.
    init(testDrivers: CloudIdentityTestDrivers) { drivers = testDrivers }
    private var appleFlow: CloudAppleAuthorization?

    /// Bind an API client to this human context. Discard in-flight responses after revocation.
    func tokenProvider() throws -> any CloudNativeTokenProvider {
        guard let uid = auth?.currentUser?.uid, uid == interactiveUserID else { throw CloudNativeIdentityError.signedOut }
        return CloudSessionTokenProvider(identity: self, uid: uid, generation: generation)
    }

    fileprivate func idToken(uid: String, generation expectedGeneration: UUID) async throws -> String {
        guard !Task.isCancelled, generation == expectedGeneration, let user = auth?.currentUser, user.uid == uid else { throw CloudNativeIdentityError.signedOut }
        let token = try await user.getIDToken(forcingRefresh: false)
        guard !Task.isCancelled, generation == expectedGeneration, auth?.currentUser?.uid == uid else { throw CloudNativeIdentityError.signedOut }
        return token
    }

    func signInWithGoogle(presenting controller: UIViewController) async throws {
        try checkEntry()
        let configuration: CloudNativeConfiguration
        let exchange: (CloudProviderCredential) async throws -> String
        if let drivers {
            configuration = try drivers.configure()
            self.configuration = configuration
            exchange = drivers.exchange
        } else {
            let configured = try configure()
            configuration = configured.0
            exchange = { try await configured.1.signIn(with: $0.firebaseCredential()).user.uid }
        }
        let flow = beginFlow(.google)
        defer { finishFlow(flow.generation) }
        do {
            try await withFlowCancellation(flow) {
            try validateFlow(flow.generation)
            let credential: CloudProviderCredential
            if let drivers { credential = try await drivers.google(controller) }
            else {
                GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: configuration.googleClientID)
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller)
                try validateFlow(flow.generation)
                guard let token = result.user.idToken?.tokenString else { throw CloudNativeIdentityError.invalidCredential }
                credential = .google(idToken: token, accessToken: result.user.accessToken.tokenString)
            }
            try validateFlow(flow.generation)
            let uid = try await exchange(credential)
            try validateFlow(flow.generation)
            interactiveUserID = uid
            }
        } catch {
            if (error as NSError).domain == kGIDSignInErrorDomain && (error as NSError).code == GIDSignInError.canceled.rawValue { throw CloudNativeIdentityError.cancelled }
            throw mappedError(error)
        }
    }

    func signInWithApple(presentationAnchor: ASPresentationAnchor) async throws {
        try checkEntry()
        let exchange: (CloudProviderCredential) async throws -> String
        if let drivers { _ = try drivers.configure(); exchange = drivers.exchange }
        else {
            let configured = try configure()
            exchange = { try await configured.1.signIn(with: $0.firebaseCredential()).user.uid }
        }
        let flow = beginFlow(.apple)
        defer { finishFlow(flow.generation) }
        do {
            try await withFlowCancellation(flow) {
            try validateFlow(flow.generation)
            let credential: CloudProviderCredential
            if let drivers { credential = try await drivers.apple(presentationAnchor) }
            else {
                let authorization = try CloudAppleAuthorization(anchor: presentationAnchor)
                appleFlow = authorization
                let result = try await authorization.authorize()
                credential = .apple(idToken: result.token, rawNonce: authorization.rawNonce, fullName: result.fullName)
            }
            try validateFlow(flow.generation)
            let uid = try await exchange(credential)
            try validateFlow(flow.generation)
            interactiveUserID = uid
            }
        } catch { throw mappedError(error) }
    }

    private func checkEntry() throws {
        guard !Task.isCancelled else { throw CloudNativeIdentityError.cancelled }
        guard !flowInProgress, signOutState != .waiting, signOutState != .failed else { throw CloudNativeIdentityError.flowInProgress }
    }
    private func beginFlow(_ provider: CloudNativeSignInProvider) -> Flow {
        signOutIntent = nil; signOutState = .idle
        generation = UUID(); interactiveUserID = nil
        let flow = Flow(provider: provider, generation: generation)
        activeFlow = flow
        return flow
    }

    /// Revokes this context immediately. SDK presentation may complete later; its result is rejected.
    func cancelActiveFlow() {
        activeFlow?.cancellation.revoke()
        generation = UUID()
        interactiveUserID = nil
        appleFlow?.cancel()
        drivers?.cancel()
    }

    private func withFlowCancellation(_ flow: Flow, operation: () async throws -> Void) async throws {
        try await withTaskCancellationHandler(operation: operation, onCancel: {
            // This synchronized bit closes callback admission immediately, even before actor delivery.
            flow.cancellation.revoke()
            Task { @MainActor [weak self] in self?.scheduleCancellation(expected: flow.generation) }
        })
    }

    private func scheduleCancellation(expected: UUID) {
        if let delivery = drivers?.cancellationDelivery {
            delivery { [weak self] in self?.deliverCancellation(expected: expected) }
        } else { deliverCancellation(expected: expected) }
    }

    private func deliverCancellation(expected: UUID) {
        guard activeFlow?.generation == expected, generation == expected else { return }
        cancelActiveFlow()
    }

    private func validateFlow(_ expected: UUID) throws {
        guard !Task.isCancelled, generation == expected, activeFlow?.cancellation.isRevoked == false else { throw CloudNativeIdentityError.cancelled }
    }

    private func mappedError(_ error: Error) -> CloudNativeIdentityError {
        error is CancellationError || (error as? CloudNativeIdentityError) == .cancelled ? .cancelled : .providerFailed
    }

    /// Called by the app only for a whitelisted dedicated Cloud callback.
    func handleGoogleCallback(_ url: URL) -> Bool {
        guard let flow = activeFlow, flow.provider == .google, flow.generation == generation, !flow.cancellation.isRevoked,
              !flow.callbackInFlight, !flow.callbackAccepted,
              let configuration, configuration.acceptsGoogleCallback(url) else { return false }
        activeFlow?.callbackInFlight = true
        defer {
            if activeFlow?.generation == flow.generation { activeFlow?.callbackInFlight = false }
        }
        let accepted = drivers?.callback(url) ?? GIDSignIn.sharedInstance.handle(url)
        guard activeFlow?.generation == flow.generation, generation == flow.generation,
              !flow.cancellation.isRevoked else { return false }
        if accepted { activeFlow?.callbackAccepted = true }
        return accepted
    }

    /// Explicit human intent is retained in this process, independently of waiter cancellation.
    /// No restart durability is implied. A blocked SDK await remains waiting, never timed out as success.
    func requestSignOut() async throws {
        if signOutState == .succeeded { return }
        if signOutState == .failed { throw CloudNativeIdentityError.providerFailed }
        if let intent = signOutIntent { try await waitForSignOut(expected: intent); return }
        let intent = UUID()
        signOutIntent = intent
        signOutState = .waiting
        cancelActiveFlow()
        if !flowInProgress { clearSDKs(expected: intent) }
        try await waitForSignOut(expected: intent)
    }

    func retrySignOut() async throws {
        guard signOutState == .failed, let intent = signOutIntent else {
            try await requestSignOut(); return
        }
        signOutState = .waiting
        if !flowInProgress { clearSDKs(expected: intent) }
        try await waitForSignOut(expected: intent)
    }

    private func waitForSignOut(expected: UUID) async throws {
        guard signOutIntent == expected else { throw CloudNativeIdentityError.cancelled }
        switch signOutState {
        case .succeeded: return
        case .failed: throw CloudNativeIdentityError.providerFailed
        case .waiting:
            try await withCheckedThrowingContinuation { signOutWaiters.append((expected, $0)) }
        case .idle: throw CloudNativeIdentityError.cancelled
        }
    }

    private func finishFlow(_ expected: UUID) {
        guard activeFlow?.generation == expected else { return }
        activeFlow = nil; appleFlow = nil
        if signOutState == .waiting, let intent = signOutIntent { clearSDKs(expected: intent) }
    }

    private func clearSDKs(expected: UUID) {
        guard signOutIntent == expected, signOutState == .waiting, !flowInProgress else { return }
        var failed = false
        do {
            if let drivers { try drivers.firebaseSignOut() }
            else { try auth?.signOut() }
        } catch { failed = true }
        // Always attempt Google clearing even if Firebase clearing failed.
        do {
            if let drivers { try drivers.googleSignOut() }
            else if configuration != nil { GIDSignIn.sharedInstance.signOut() }
        } catch { failed = true }
        guard signOutIntent == expected else { return }
        let waiters = signOutWaiters.filter { $0.0 == expected }
        signOutWaiters.removeAll { $0.0 == expected }
        signOutState = failed ? .failed : .succeeded
        for (_, waiter) in waiters {
            if failed { waiter.resume(throwing: CloudNativeIdentityError.providerFailed) }
            else { waiter.resume() }
        }
    }

    private func configure() throws -> (CloudNativeConfiguration, Auth) {
        if let configuration, let auth { return (configuration, auth) }
        // Validate all supplied configuration before Firebase initialization or interactive auth.
        let configuration = try CloudNativeConfiguration.load()
        let options = FirebaseOptions(googleAppID: configuration.appID, gcmSenderID: configuration.senderID)
        options.apiKey = configuration.apiKey
        options.projectID = configuration.projectID
        options.bundleID = configuration.bundleID
        options.clientID = configuration.googleClientID
        let name = "ScreenpunkNativeCloud"
        if FirebaseApp.app(name: name) == nil { FirebaseApp.configure(name: name, options: options) }
        guard let app = FirebaseApp.app(name: name),
              app.options.googleAppID == configuration.appID,
              app.options.gcmSenderID == configuration.senderID,
              app.options.projectID == configuration.projectID,
              app.options.apiKey == configuration.apiKey,
              app.options.bundleID == configuration.bundleID,
              app.options.clientID == configuration.googleClientID else { throw CloudNativeIdentityError.notConfigured }
        let auth = Auth.auth(app: app)
        self.configuration = configuration
        self.auth = auth
        return (configuration, auth)
    }
}

private struct CloudSessionTokenProvider: CloudNativeTokenProvider {
    let identity: CloudNativeIdentity
    let uid: String
    let generation: UUID
    func idToken() async throws -> String { try await identity.idToken(uid: uid, generation: generation) }
}

@MainActor
final class CloudAppleAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Result { let token: String; let fullName: PersonNameComponents? }
    let rawNonce: String
    private let anchor: ASPresentationAnchor
    private var continuation: CheckedContinuation<Result, Error>?
    private var controller: ASAuthorizationController?
    private var finished = false
    private var started = false
    private var testPerform: ((CloudAppleAuthorization) -> Void)?
    private var testCancel: (() -> Void)?

    init(testPerform: @escaping (CloudAppleAuthorization) -> Void, testCancel: @escaping () -> Void) {
        rawNonce = "isolated-test-nonce"; anchor = UIWindow()
        self.testPerform = testPerform; self.testCancel = testCancel
    }

    init(anchor: ASPresentationAnchor) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CloudNativeIdentityError.invalidCredential }
        rawNonce = bytes.map { String(format: "%02x", $0) }.joined()
        self.anchor = anchor
    }
    func authorize() async throws -> Result {
        guard !Task.isCancelled, !finished, !started else { throw CloudNativeIdentityError.cancelled }
        started = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled, !finished else { continuation.resume(throwing: CloudNativeIdentityError.cancelled); return }
            self.continuation = continuation
            if let testPerform { testPerform(self); return }
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func cancel() {
        guard !finished else { return }
        // Finish first: controller.cancel may synchronously invoke the delegate.
        let controller = controller
        finish(.failure(CloudNativeIdentityError.cancelled))
        controller?.cancel()
        testCancel?()
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { anchor }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
            finish(.failure(CloudNativeIdentityError.invalidCredential)); return
        }
        finish(.success(.init(token: token, fullName: credential.fullName)))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure((error as? ASAuthorizationError)?.code == .canceled ? CloudNativeIdentityError.cancelled : CloudNativeIdentityError.providerFailed))
    }
    private func finish(_ result: Swift.Result<Result, Error>) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        controller = nil
        continuation?.resume(with: result)
    }
}

/// Internal provider seam; credentials never leave this adapter module.
@MainActor
struct CloudIdentityTestDrivers {
    let configure: () throws -> CloudNativeConfiguration
    let google: (UIViewController) async throws -> CloudProviderCredential
    let apple: (ASPresentationAnchor) async throws -> CloudProviderCredential
    let exchange: (CloudProviderCredential) async throws -> String
    let callback: (URL) -> Bool
    let cancel: () -> Void
    var cancellationDelivery: ((@escaping () -> Void) -> Void)? = nil
    var firebaseSignOut: () throws -> Void = {}
    var googleSignOut: () throws -> Void = {}
}

enum CloudProviderCredential {
    case google(idToken: String, accessToken: String)
    case apple(idToken: String, rawNonce: String, fullName: PersonNameComponents?)
    fileprivate func firebaseCredential() -> AuthCredential {
        switch self {
        case let .google(token, access): return GoogleAuthProvider.credential(withIDToken: token, accessToken: access)
        case let .apple(token, nonce, name): return OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: name)
        }
    }
}

/// Task cancellation can arrive off actor; only this bit crosses that boundary.
private final class CloudFlowCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    var isRevoked: Bool { lock.lock(); defer { lock.unlock() }; return revoked }
    func revoke() { lock.lock(); defer { lock.unlock() }; revoked = true }
}
