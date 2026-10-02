import AuthenticationServices
import CryptoKit
import FirebaseCore
import FirebaseAuth
import GoogleSignIn
import ScreenpunkCore
import UIKit

/// App-only adapter; it is not constructed by the current onboarding UI.
/// Firebase configuration and interactive provider flows require an explicit caller.
@MainActor
final class CloudNativeIdentity {
    private var auth: Auth?
    private var configuration: CloudNativeConfiguration?
    private var generation = UUID()
    private var flowInProgress = false
    private var interactiveUserID: String?
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
        guard !flowInProgress else { throw CloudNativeIdentityError.flowInProgress }
        let (configuration, auth) = try configure()
        generation = UUID()
        interactiveUserID = nil
        flowInProgress = true
        let flowGeneration = generation
        defer { flowInProgress = false }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: configuration.googleClientID)
        do {
            // Always interactive. restorePreviousSignIn is not proof of a recent human sign-in.
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller)
            try validateFlow(flowGeneration)
            guard let token = result.user.idToken?.tokenString else { throw CloudNativeIdentityError.invalidCredential }
            let credential = GoogleAuthProvider.credential(withIDToken: token, accessToken: result.user.accessToken.tokenString)
            let firebaseResult = try await auth.signIn(with: credential)
            try validateFlow(flowGeneration)
            interactiveUserID = firebaseResult.user.uid
        } catch {
            if error is CancellationError || (error as? CloudNativeIdentityError) == .cancelled { throw CloudNativeIdentityError.cancelled }
            let error = error as NSError
            if error.domain == kGIDSignInErrorDomain && error.code == GIDSignInError.canceled.rawValue {
                throw CloudNativeIdentityError.cancelled
            }
            throw CloudNativeIdentityError.providerFailed
        }
    }

    func signInWithApple(presentationAnchor: ASPresentationAnchor) async throws {
        guard !flowInProgress else { throw CloudNativeIdentityError.flowInProgress }
        let (_, auth) = try configure()
        generation = UUID()
        interactiveUserID = nil
        flowInProgress = true
        let flowGeneration = generation
        defer { flowInProgress = false; appleFlow = nil }
        let flow = try CloudAppleAuthorization(anchor: presentationAnchor)
        appleFlow = flow
        let result = try await flow.authorize()
        try validateFlow(flowGeneration)
        let credential = OAuthProvider.appleCredential(withIDToken: result.token, rawNonce: flow.rawNonce, fullName: result.fullName)
        do {
            let firebaseResult = try await auth.signIn(with: credential)
            try validateFlow(flowGeneration)
            interactiveUserID = firebaseResult.user.uid
        } catch { throw mappedError(error) }
    }

    /// Revokes this context immediately. SDK presentation may complete later; its result is rejected.
    func cancelActiveFlow() {
        generation = UUID()
        interactiveUserID = nil
        appleFlow?.cancel()
    }

    private func validateFlow(_ expected: UUID) throws {
        guard !Task.isCancelled, generation == expected else { throw CloudNativeIdentityError.cancelled }
    }

    private func mappedError(_ error: Error) -> CloudNativeIdentityError {
        error is CancellationError || (error as? CloudNativeIdentityError) == .cancelled ? .cancelled : .providerFailed
    }

    /// Called by the app only for a whitelisted dedicated Cloud callback.
    func handleGoogleCallback(_ url: URL) -> Bool {
        guard flowInProgress, let configuration, configuration.acceptsGoogleCallback(url) else { return false }
        return GIDSignIn.sharedInstance.handle(url)
    }

    /// Explicit human sign-out affects provider sessions only; installed screens are untouched.
    func signOut() throws {
        guard !flowInProgress else { throw CloudNativeIdentityError.flowInProgress }
        generation = UUID()
        interactiveUserID = nil
        try auth?.signOut()
        GIDSignIn.sharedInstance.signOut()
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
private final class CloudAppleAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Result { let token: String; let fullName: PersonNameComponents? }
    let rawNonce: String
    private let anchor: ASPresentationAnchor
    private var continuation: CheckedContinuation<Result, Error>?
    private var controller: ASAuthorizationController?

    init(anchor: ASPresentationAnchor) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CloudNativeIdentityError.invalidCredential }
        rawNonce = bytes.map { String(format: "%02x", $0) }.joined()
        self.anchor = anchor
    }
    func authorize() async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
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
        controller?.cancel()
        finish(.failure(CloudNativeIdentityError.cancelled))
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
        let continuation = continuation
        self.continuation = nil
        controller = nil
        continuation?.resume(with: result)
    }
}
