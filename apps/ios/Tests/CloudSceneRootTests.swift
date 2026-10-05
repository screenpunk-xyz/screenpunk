import XCTest
import SwiftUI
import UIKit
import ScreenpunkCore
@testable import Screenpunk

@MainActor
final class CloudSceneRootTests: XCTestCase {
    func testMissingConfigurationIsUnavailableWithoutSessionFactory() {
        var validations = 0
        let sheet = CloudAccountSheet.requested(configuration: {
            validations += 1; throw CloudNativeIdentityError.notConfigured
        })
        guard case .unavailable(let message) = sheet.availability else { return XCTFail() }
        XCTAssertEqual(validations, 1)
        XCTAssertTrue(message.contains("not configured"))
    }
    func testCompleteConfigurationQualifiesOnlyHumanPresentation() throws {
        let client = "fixture.apps.googleusercontent.com", callback = "com.googleusercontent.apps.fixture"
        let info: [String: Any] = ["ScreenpunkCloudFirebaseProjectID": "fixture",
            "ScreenpunkCloudFirebaseAPIKey": "fixture-key", "ScreenpunkCloudFirebaseAppID": "1:123:ios:fixture",
            "ScreenpunkCloudFirebaseSenderID": "123", "ScreenpunkCloudGoogleClientID": client,
            "ScreenpunkCloudGoogleCallbackScheme": callback, "ScreenpunkCloudBundleID": "xyz.screenpunk.fixture",
            "ScreenpunkCloudAPIOrigin": "https://fixture.invalid", "CFBundleURLTypes": [["CFBundleURLName": "Screenpunk Cloud OAuth", "CFBundleURLSchemes": [callback]]]]
        let sheet = CloudAccountSheet.requested(configuration: { try CloudNativeConfiguration.load(info: info, bundleID: "xyz.screenpunk.fixture") })
        guard case .qualified = sheet.availability else { return XCTFail() }
        // No production session factory, SDK, network or enrollment is invoked.
    }
    private func waitFor(_ event: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard condition() else {
            XCTFail("Timed out waiting for " + event)
            throw NSError(domain: "CloudRouteHostedFixture", code: 1)
        }
    }
    func testHostedProviderCoverPreservesFlowButJourneyDismissalCancels() async throws {
        let fixture = RouteJourneyFixture(); fixture.holdAuthentication = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController(), window = UIWindow(windowScene: scene)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let hosting = UIHostingController(rootView: fixture.view); hosting.modalPresentationStyle = .fullScreen
        var presented = false
        root.present(hosting, animated: false) { presented = true }
        try await waitFor("journey presentation completion") { presented }
        let task = try fixture.actions.signIn(.google)
        // Register cleanup immediately: it covers late authentication entry and
        // every timeout/unwrap/error after task creation, not only a captured hold.
        let cleanup: () async throws -> Void = {
            fixture.holdAuthentication = false // BEFORE cancel or resuming a hold.
            fixture.actions.cancel()
            let continuation = fixture.authenticationContinuation
            fixture.authenticationContinuation = nil; continuation?.resume()
            var settled = false
            let monitor = Task { await task?.value; settled = true }
            do { try await self.waitFor("authentication cleanup settlement") { settled } }
            catch { monitor.cancel(); throw error }
            await monitor.value
        }
        do {
            try await waitFor("held fake authentication") { fixture.authenticationContinuation != nil }
            let before = fixture.cancellations
            let provider = UIViewController(); provider.modalPresentationStyle = .fullScreen
            var covered = false
            hosting.present(provider, animated: false) { covered = true }
            try await waitFor("provider presentation completion") { covered }
            XCTAssertEqual(fixture.cancellations, before)
            XCTAssertTrue(fixture.coordinator.isWorking)
            var uncovered = false
            provider.dismiss(animated: false) { uncovered = true }
            try await waitFor("provider dismissal completion") { uncovered }
            XCTAssertEqual(fixture.cancellations, before)
            var dismissed = false
            hosting.dismiss(animated: false) { dismissed = true }
            try await waitFor("journey dismissal completion") { dismissed }
            XCTAssertEqual(fixture.cancellations, before + 1)
            try await cleanup()
            XCTAssertNil(fixture.coordinator.humanIdentity)
        } catch {
            do { try await cleanup() }
            catch { XCTFail("Authentication cleanup did not settle: fixture remains unqualified") }
            throw error
        }
    }

}

@MainActor
private final class RouteJourneyFixture {
    let lifecycle: CloudHumanSessionLifecycle
    let journal = RouteJourneyJournal()
    let transport = RouteJourneyTransport()
    let availability: CloudJourneyAvailability
    private(set) var factories = 0, presentations = 0
    private(set) var providers: [CloudNativeSignInProvider] = []
    var holdAuthentication = false
    var authenticationContinuation: CheckedContinuation<Void, Never>?
    var cancellations = 0
    var holdSignOut = false
    var signOutContinuation: CheckedContinuation<Void, Error>?
    lazy var presentation = CloudProviderPresentation(testResolve: { [weak self] in
        guard let self else { throw CloudNativeIdentityError.cancelled }
        self.presentations += 1; return .init(controller: UIViewController(), window: UIWindow())
    })
    lazy var coordinator = CloudConnectionCoordinator(authenticate: { [weak self] provider in
        guard let self else { throw CloudNativeIdentityError.cancelled }
        _ = try self.presentation.resolve(); self.providers.append(provider)
        if self.holdAuthentication { await withCheckedContinuation { self.authenticationContinuation = $0 } }
        return RouteJourneyTokens()
    }, cancelIdentityFlow: { [weak self] in self?.cancellations += 1 }, signOutIdentity: { [weak self] in
        guard let self else { return }
        if self.holdSignOut { try await withCheckedThrowingContinuation { self.signOutContinuation = $0 } }
    }, makeClient: { [weak self] tokens in
        guard let self else { throw CloudNativeIdentityError.cancelled }
        return try CloudNativeClient(baseURL: URL(string: "https://fixture.invalid")!, tokenProvider: tokens, transport: self.transport)
    }, journal: journal)
    init(availability: CloudJourneyAvailability = .qualified, broker: CloudHumanSessionBroker? = nil) { self.availability = availability; lifecycle = CloudHumanSessionLifecycle(broker: broker ?? CloudHumanSessionBroker()) }
    var actions: CloudAccountJourneyActions {
        .init(lifecycle: lifecycle, presentation: presentation, availability: availability, makeSession: { _ in
            self.factories += 1; return CloudHumanSession(testCoordinator: self.coordinator, testCallback: { _ in false })
        })
    }
    var view: CloudAccountJourneyView {
        .init(lifecycle: lifecycle, presentation: presentation, availability: availability, makeSession: { _ in
            self.factories += 1; return CloudHumanSession(testCoordinator: self.coordinator, testCallback: { _ in false })
        })
    }
    func finishSignOut(failed: Bool) {
        let continuation = signOutContinuation; signOutContinuation = nil
        if failed { continuation?.resume(throwing: CloudNativeIdentityError.providerFailed) } else { continuation?.resume() }
    }
}
@MainActor
private final class RouteJourneyJournal: CloudWorkspaceSetupJournal {
    var record: CloudWorkspaceSetupJournalRecord?
    private var attempt: CloudWorkspaceSetupJournalRecord?
    var failSaveNumber = 0
    private var saves = 0
    func load() throws -> CloudWorkspaceSetupJournalRecord? { if attempt != nil { throw CocoaError(.fileWriteUnknown) }; return record }
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws {
        saves += 1; attempt = record
        if saves == failSaveNumber { throw CocoaError(.fileWriteUnknown) }
        self.record = record; attempt = nil
    }
    func beginSuccessor(_ record: CloudWorkspaceSetupJournalRecord) throws { try save(record) }
    func retryPendingWrite(expectedUserID: UUID) throws -> CloudWorkspaceSetupJournalRecord {
        let target = try XCTUnwrap(attempt)
        guard target.userID == expectedUserID else { throw CocoaError(.fileWriteUnknown) }
        record = target; attempt = nil; return target
    }
}
private struct RouteJourneyTokens: CloudNativeTokenProvider { func idToken() async throws -> String { "fixture-token" } }
private actor RouteJourneyTransport: HTTPTransport {
    static let accountID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private var failure: Int?
    private var hasAccounts = false
    private(set) var posts: [CloudNativeWorkspaceSetupRequest] = []
    private(set) var lookups: [UUID] = []
    func setFailure(_ status: Int?) { failure = status }
    func setAccounts(_ value: Bool) { hasAccounts = value }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        let path = request.url.path
        if path == "/v1/native/sign-in" {
            return .init(status: 200, body: Data(#"{"user":{"id":"22222222-2222-4222-8222-222222222222","displayName":"Fixture person","email":null},"signInProvider":"google.com","authTime":"2026-10-02T16:00:00Z","tokenExpiresAt":"2026-10-02T17:00:00Z"}"#.utf8))
        }
        if path == "/v1/native/accounts" {
            return .init(status: 200, body: Data((hasAccounts ? #"{"items":[{"id":"11111111-1111-4111-8111-111111111111","name":"Fixture workspace","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"owner":true,"administrator":true,"canEnroll":true}}],"nextCursor":null}"# : #"{"items":[],"nextCursor":null}"#).utf8))
        }
        if path.hasSuffix("/locations") { return .init(status: 200, body: Data(#"{"items":[{"id":"33333333-3333-4333-8333-333333333333","name":"Fixture location","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"canView":true,"canOperate":false,"canEnroll":false}}],"nextCursor":null}"#.utf8)) }
        let id: UUID
        if request.method == "POST" {
            let setup = try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: XCTUnwrap(request.body)); posts.append(setup); id = setup.requestId
        } else { id = try XCTUnwrap(UUID(uuidString: request.url.lastPathComponent)); lookups.append(id) }
        if let failure { return .init(status: failure, body: Data(#"{"code":"workspace_setup_unavailable","message":"raw-fixture-diagnostic","requestId":"trace-fixture"}"#.utf8)) }
        return .init(status: 200, body: Data("{\"requestId\":\"\(id.uuidString)\",\"accountId\":\"11111111-1111-4111-8111-111111111111\",\"locationId\":\"33333333-3333-4333-8333-333333333333\",\"createdAt\":\"2026-10-02T16:00:00Z\"}".utf8))
    }
}
