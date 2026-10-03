import XCTest
import UIKit
import AuthenticationServices
@testable import Screenpunk

final class CloudNativeIdentityTests: XCTestCase {
    private var configured: [String: Any] {
        ["ScreenpunkCloudFirebaseProjectID": "fixture-cloud-project",
         "ScreenpunkCloudFirebaseAPIKey": "fixture-api-key",
         "ScreenpunkCloudFirebaseAppID": "1:123456:ios:fixture",
         "ScreenpunkCloudFirebaseSenderID": "123456",
         "ScreenpunkCloudGoogleClientID": "fixture-client.apps.googleusercontent.com",
         "ScreenpunkCloudGoogleCallbackScheme": "com.googleusercontent.apps.fixture-client",
         "ScreenpunkCloudBundleID": "test.screenpunk",
         "ScreenpunkCloudAPIOrigin": "https://cloud.example.invalid",
         "CFBundleURLTypes": [["CFBundleURLName": "Screenpunk Cloud OAuth", "CFBundleURLSchemes": ["com.googleusercontent.apps.fixture-client"]]]]
    }
    func testMissingAndUnexpandedConfigurationFailsClosed() {
        XCTAssertThrowsError(try CloudNativeConfiguration.load(info: [:], bundleID: "test.screenpunk"))
        for key in configured.keys.filter({ $0.hasPrefix("ScreenpunkCloud") }) {
            for value in ["", "$(UNSUPPLIED)"] {
                var info = configured; info[key] = value
                XCTAssertThrowsError(try CloudNativeConfiguration.load(info: info, bundleID: "test.screenpunk"), key)
            }
        }
    }
    func testDedicatedCallbackRejectsCalendarAndUnexpectedPaths() throws {
        let configuration = try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk")
        XCTAssertTrue(configuration.acceptsGoogleCallback(URL(string: "com.googleusercontent.apps.fixture-client:/oauth2callback?code=fixture")!))
        for url in ["calendar:/oauth2redirect", "com.googleusercontent.apps.fixture-client:/oauth2redirect", "com.googleusercontent.apps.fixture-client://unexpected/oauth2callback", "https://cloud.example.invalid/oauth2callback"] {
            XCTAssertFalse(configuration.acceptsGoogleCallback(URL(string: url)!))
        }
    }
    func testBundleOriginAndCalendarSchemeCollisionFailClosed() {
        XCTAssertThrowsError(try CloudNativeConfiguration.load(info: configured, bundleID: "other.bundle"))
        for origin in ["http://cloud.example.invalid", "https://user@cloud.example.invalid", "https://cloud.example.invalid/path", "https://cloud.example.invalid?secret=fixture"] {
            var info = configured; info["ScreenpunkCloudAPIOrigin"] = origin
            XCTAssertThrowsError(try CloudNativeConfiguration.load(info: info, bundleID: "test.screenpunk"))
        }
        var info = configured
        var types = info["CFBundleURLTypes"] as! [[String: Any]]
        types.append(["CFBundleURLName": "Google Calendar OAuth", "CFBundleURLSchemes": ["com.googleusercontent.apps.fixture-client"]])
        info["CFBundleURLTypes"] = types
        XCTAssertThrowsError(try CloudNativeConfiguration.load(info: info, bundleID: "test.screenpunk"))
    }
    @MainActor func testUnconfiguredAppleSignInFailsBeforeInteractiveAuthorization() async {
        let identity = CloudNativeIdentity()
        do {
            try await identity.signInWithApple(presentationAnchor: UIWindow())
            XCTFail("Unconfigured Apple sign-in must fail before presenting a provider")
        } catch {
            XCTAssertEqual(error as? CloudNativeIdentityError, .notConfigured)
        }
        XCTAssertThrowsError(try identity.tokenProvider())
    }

    @MainActor func testUnconfiguredServiceCannotIssueSessionProviderOrHandleCallbacks() {
        let identity = CloudNativeIdentity()
        XCTAssertThrowsError(try identity.tokenProvider())
        XCTAssertFalse(identity.handleGoogleCallback(URL(string: "com.googleusercontent.apps.fixture-client:/oauth2callback")!))
        identity.cancelActiveFlow()
        XCTAssertThrowsError(try identity.tokenProvider())
    }
    @MainActor func testCanceledEntryNeverConfiguresOrPresentsEitherProvider() async throws {
        let probe = IdentityProbe(configuration: try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk"))
        let identity = CloudNativeIdentity(testDrivers: probe.drivers)
        for apple in [false, true] {
            let task = Task { @MainActor in
                do {
                    if apple { try await identity.signInWithApple(presentationAnchor: UIWindow()) }
                    else { try await identity.signInWithGoogle(presenting: UIViewController()) }
                    XCTFail("Canceled entry succeeded")
                } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .cancelled) }
            }
            task.cancel(); await task.value
        }
        XCTAssertEqual(probe.configurations, 0); XCTAssertEqual(probe.presentations, 0)
    }

    @MainActor func testProviderScopedCallbackAndRevokedLateGoogleResult() async throws {
        let probe = IdentityProbe(configuration: try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk"))
        let identity = CloudNativeIdentity(testDrivers: probe.drivers)
        let callback = URL(string: "com.googleusercontent.apps.fixture-client:/oauth2callback?code=fixture")!
        let apple = Task { try await identity.signInWithApple(presentationAnchor: UIWindow()) }
        while probe.presentations == 0 { await Task.yield() }
        XCTAssertFalse(identity.handleGoogleCallback(callback)); XCTAssertEqual(probe.callbacks, 0)
        identity.cancelActiveFlow(); probe.resolve(.apple(idToken: "fixture", rawNonce: "fixture", fullName: nil))
        do { try await apple.value; XCTFail("Revoked Apple result accepted") } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .cancelled) }
        let google = Task { try await identity.signInWithGoogle(presenting: UIViewController()) }
        while probe.presentations < 2 { await Task.yield() }
        XCTAssertTrue(identity.handleGoogleCallback(callback)); XCTAssertEqual(probe.callbacks, 1)
        identity.cancelActiveFlow()
        XCTAssertFalse(identity.handleGoogleCallback(callback)); XCTAssertEqual(probe.callbacks, 1)
        do { try await identity.signInWithApple(presentationAnchor: UIWindow()); XCTFail("Overlapping flow") }
        catch { XCTAssertEqual(error as? CloudNativeIdentityError, .flowInProgress) }
        probe.resolve(.google(idToken: "fixture", accessToken: "fixture"))
        do { try await google.value; XCTFail("Revoked Google result accepted") } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .cancelled) }
        XCTAssertEqual(probe.exchanges, 0); XCTAssertNil(identity.interactiveUserID)
    }

    @MainActor func testTaskCancelClosesCallbacksAndDelayedDeliveryCannotRevokeNewFlow() async throws {
        let probe = IdentityProbe(configuration: try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk"))
        probe.delayCancellation = true
        let identity = CloudNativeIdentity(testDrivers: probe.drivers)
        let callback = URL(string: "com.googleusercontent.apps.fixture-client:/oauth2callback")!
        let old = Task { try await identity.signInWithGoogle(presenting: UIViewController()) }
        while probe.presentations == 0 { await Task.yield() }
        old.cancel()
        XCTAssertFalse(identity.handleGoogleCallback(callback)) // No actor delivery or provider reply needed.
        do { try await identity.signInWithGoogle(presenting: UIViewController()); XCTFail("Duplicate flow") }
        catch { XCTAssertEqual(error as? CloudNativeIdentityError, .flowInProgress) }
        while probe.delayedCancellations.isEmpty { await Task.yield() }
        probe.resolve(.google(idToken: "old-fixture", accessToken: "fixture"))
        do { try await old.value; XCTFail("Canceled result") } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .cancelled) }
        XCTAssertEqual(probe.exchanges, 0)
        let fresh = Task { try await identity.signInWithGoogle(presenting: UIViewController()) }
        while probe.presentations < 2 { await Task.yield() }
        probe.delayedCancellations.removeFirst()()
        XCTAssertTrue(identity.handleGoogleCallback(callback))
        probe.resolve(.google(idToken: "new-fixture", accessToken: "fixture"))
        try await fresh.value
        XCTAssertEqual(probe.exchanges, 1); XCTAssertEqual(identity.interactiveUserID, "fixture-uid")
    }

    @MainActor func testTaskCancelDuringExchangeRejectsLateUID() async throws {
        let probe = IdentityProbe(configuration: try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk"))
        probe.holdExchange = true
        let identity = CloudNativeIdentity(testDrivers: probe.drivers)
        let task = Task { try await identity.signInWithGoogle(presenting: UIViewController()) }
        while probe.presentations == 0 { await Task.yield() }
        probe.resolve(.google(idToken: "fixture", accessToken: "fixture"))
        while probe.exchanges == 0 { await Task.yield() }
        task.cancel()
        XCTAssertFalse(identity.handleGoogleCallback(URL(string: "com.googleusercontent.apps.fixture-client:/oauth2callback")!))
        probe.resolveExchange()
        do { try await task.value; XCTFail("Canceled exchange published") } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .cancelled) }
        XCTAssertNil(identity.interactiveUserID)
    }

    @MainActor func testSignOutJoinsWhileIgnoredProviderAwaitSettlesForBothProviders() async throws {
        for apple in [false, true] {
            let probe = IdentityProbe(configuration: try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk"))
            let identity = CloudNativeIdentity(testDrivers: probe.drivers)
            let provider = Task {
                if apple { try await identity.signInWithApple(presentationAnchor: UIWindow()) }
                else { try await identity.signInWithGoogle(presenting: UIViewController()) }
            }
            while probe.presentations == 0 { await Task.yield() }
            let first = Task { try await identity.requestSignOut() }
            while identity.signOutState != .waiting { await Task.yield() }
            let joined = Task { try await identity.requestSignOut() }
            first.cancel() // Losing an awaiter must not abandon the explicit human intent.
            XCTAssertFalse(identity.handleGoogleCallback(URL(string: "com.googleusercontent.apps.fixture-client:/oauth2callback")!))
            XCTAssertEqual(probe.firebaseClears, 0); XCTAssertEqual(probe.googleClears, 0)
            do { try await identity.signInWithGoogle(presenting: UIViewController()); XCTFail("Pending sign-out admitted login") }
            catch { XCTAssertEqual(error as? CloudNativeIdentityError, .flowInProgress) }
            probe.resolve(apple ? .apple(idToken: "fixture", rawNonce: "fixture", fullName: nil) : .google(idToken: "fixture", accessToken: "fixture"))
            do { try await provider.value; XCTFail("Revoked provider succeeded") } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .cancelled) }
            try await first.value; try await joined.value
            XCTAssertEqual(probe.exchanges, 0)
            XCTAssertEqual(probe.firebaseClears, 1); XCTAssertEqual(probe.googleClears, 1)
            XCTAssertEqual(identity.signOutState, .succeeded); XCTAssertNil(identity.interactiveUserID)
        }
    }

    @MainActor func testSignOutWaitsForLateExchangeBeforeClearingSDKs() async throws {
        let probe = IdentityProbe(configuration: try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk"))
        probe.holdExchange = true
        let identity = CloudNativeIdentity(testDrivers: probe.drivers)
        let provider = Task { try await identity.signInWithGoogle(presenting: UIViewController()) }
        while probe.presentations == 0 { await Task.yield() }
        probe.resolve(.google(idToken: "fixture", accessToken: "fixture"))
        while probe.exchanges == 0 { await Task.yield() }
        let signOut = Task { try await identity.requestSignOut() }
        while identity.signOutState != .waiting { await Task.yield() }
        XCTAssertEqual(probe.firebaseClears, 0); XCTAssertEqual(probe.googleClears, 0)
        probe.resolveExchange()
        do { try await provider.value; XCTFail("Late exchange published") } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .cancelled) }
        try await signOut.value
        XCTAssertEqual(probe.events, ["exchange-start", "exchange-finish", "firebase-clear", "google-clear"])
        XCTAssertNil(identity.interactiveUserID); XCTAssertEqual(identity.signOutState, .succeeded)
    }

    @MainActor func testPartialSDKClearFailureBlocksLoginUntilExplicitRetry() async throws {
        let probe = IdentityProbe(configuration: try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk"))
        probe.failFirebaseClear = true
        let identity = CloudNativeIdentity(testDrivers: probe.drivers)
        do { try await identity.requestSignOut(); XCTFail("Partial clearing succeeded") } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .providerFailed) }
        XCTAssertEqual(identity.signOutState, .failed)
        XCTAssertEqual(probe.firebaseClears, 1); XCTAssertEqual(probe.googleClears, 1)
        do { try await identity.requestSignOut(); XCTFail("Failed intent silently retried") } catch {}
        XCTAssertEqual(probe.firebaseClears, 1)
        do { try await identity.signInWithApple(presentationAnchor: UIWindow()); XCTFail("Failed sign-out admitted login") }
        catch { XCTAssertEqual(error as? CloudNativeIdentityError, .flowInProgress) }
        XCTAssertEqual(probe.configurations, 0)
        probe.failFirebaseClear = false
        try await identity.retrySignOut()
        XCTAssertEqual(identity.signOutState, .succeeded)
        XCTAssertEqual(probe.firebaseClears, 2); XCTAssertEqual(probe.googleClears, 2)
        try await identity.requestSignOut()
        XCTAssertEqual(probe.firebaseClears, 2)
    }

    @MainActor func testOldCancellationDeliveryCannotAffectNewFlowAfterSignOut() async throws {
        let probe = IdentityProbe(configuration: try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk"))
        probe.delayCancellation = true
        let identity = CloudNativeIdentity(testDrivers: probe.drivers)
        let old = Task { try await identity.signInWithGoogle(presenting: UIViewController()) }
        while probe.presentations == 0 { await Task.yield() }
        old.cancel()
        while probe.delayedCancellations.isEmpty { await Task.yield() }
        let signOut = Task { try await identity.requestSignOut() }
        while identity.signOutState != .waiting { await Task.yield() }
        probe.resolve(.google(idToken: "old-fixture", accessToken: "fixture"))
        _ = try? await old.value; try await signOut.value
        let fresh = Task { try await identity.signInWithGoogle(presenting: UIViewController()) }
        while probe.presentations < 2 { await Task.yield() }
        probe.delayedCancellations.removeFirst()()
        XCTAssertTrue(identity.handleGoogleCallback(URL(string: "com.googleusercontent.apps.fixture-client:/oauth2callback")!))
        XCTAssertEqual(probe.firebaseClears, 1); XCTAssertEqual(probe.googleClears, 1)
        probe.resolve(.google(idToken: "new-fixture", accessToken: "fixture"))
        try await fresh.value
        XCTAssertEqual(identity.interactiveUserID, "fixture-uid")
    }

    @MainActor func testAcceptedFakeProviderExchangesAndPublishesOnlyCurrentResult() async throws {
        let probe = IdentityProbe(configuration: try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk"))
        let identity = CloudNativeIdentity(testDrivers: probe.drivers)
        let task = Task { try await identity.signInWithGoogle(presenting: UIViewController()) }
        while probe.presentations == 0 { await Task.yield() }
        probe.resolve(.google(idToken: "fixture", accessToken: "fixture"))
        try await task.value
        XCTAssertEqual(probe.exchanges, 1); XCTAssertEqual(identity.interactiveUserID, "fixture-uid")
        identity.cancelActiveFlow(); XCTAssertNil(identity.interactiveUserID)
    }

    @MainActor func testApplePrecancelAndDelegateRaceFinishExactlyOnce() async {
        var presentations = 0, cancellations = 0
        let pre = CloudAppleAuthorization(testPerform: { _ in presentations += 1 }, testCancel: {})
        pre.cancel()
        do { _ = try await pre.authorize(); XCTFail("Precancel presented") } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .cancelled) }
        XCTAssertEqual(presentations, 0)
        var held: CloudAppleAuthorization?
        let flow = CloudAppleAuthorization(testPerform: { held = $0; presentations += 1 }, testCancel: { cancellations += 1 })
        let task = Task { try await flow.authorize() }
        while held == nil { await Task.yield() }
        flow.cancel()
        let controller = ASAuthorizationController(authorizationRequests: [ASAuthorizationAppleIDProvider().createRequest()])
        flow.authorizationController(controller: controller, didCompleteWithError: NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.canceled.rawValue))
        flow.cancel()
        do { _ = try await task.value; XCTFail("Cancellation replaced") } catch { XCTAssertEqual(error as? CloudNativeIdentityError, .cancelled) }
        XCTAssertEqual(cancellations, 1); XCTAssertEqual(presentations, 1)
    }

}


@MainActor
private final class IdentityProbe {
    let configuration: CloudNativeConfiguration
    var configurations = 0, presentations = 0, exchanges = 0, callbacks = 0
    var firebaseClears = 0, googleClears = 0
    var failFirebaseClear = false
    var events: [String] = []
    var delayCancellation = false, holdExchange = false
    var delayedCancellations: [() -> Void] = []
    private var pendingExchange: CheckedContinuation<String, Never>?
    private var pending: CheckedContinuation<CloudProviderCredential, Error>?
    init(configuration: CloudNativeConfiguration) { self.configuration = configuration }
    var drivers: CloudIdentityTestDrivers {
        .init(configure: { self.configurations += 1; return self.configuration },
              google: { _ in try await self.present() }, apple: { _ in try await self.present() },
              exchange: { _ in
                  self.exchanges += 1
                  self.events.append("exchange-start")
                  if self.holdExchange { return await withCheckedContinuation { self.pendingExchange = $0 } }
                  self.events.append("exchange-finish")
                  return "fixture-uid"
              },
              callback: { _ in self.callbacks += 1; return true }, cancel: {},
              cancellationDelivery: { delivery in
                  if self.delayCancellation { self.delayedCancellations.append(delivery) } else { delivery() }
              }, firebaseSignOut: {
                  self.firebaseClears += 1; self.events.append("firebase-clear")
                  if self.failFirebaseClear { throw CloudNativeIdentityError.providerFailed }
              }, googleSignOut: { self.googleClears += 1; self.events.append("google-clear") })
    }
    func present() async throws -> CloudProviderCredential {
        presentations += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func resolveExchange() { events.append("exchange-finish"); let saved = pendingExchange; pendingExchange = nil; saved?.resume(returning: "late-fixture-uid") }
    func resolve(_ credential: CloudProviderCredential) { let saved = pending; pending = nil; saved?.resume(returning: credential) }
}
