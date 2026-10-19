import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private final class HomeAttemptMemory: WorkbenchHomeAssistantAttemptStore {
    var records: [String: WorkbenchHomeAssistantAttempt] = [:]
    var failPreparedTransition = false
    func load(intentId: String) throws -> WorkbenchHomeAssistantAttempt? { records[intentId] }
    func begin(_ attempt: WorkbenchHomeAssistantAttempt) throws {
        guard records[attempt.intentId] == nil else { throw WorkbenchHomeAssistantSetupFailure.conflict }
        records[attempt.intentId] = attempt
    }
    func transition(from: WorkbenchHomeAssistantAttempt, to: WorkbenchHomeAssistantAttempt) throws {
        if failPreparedTransition && to.phase == .prepared {
            failPreparedTransition = false
            throw WorkbenchHomeAssistantSetupFailure.conflict
        }
        guard records[from.intentId] == from else { throw WorkbenchHomeAssistantSetupFailure.conflict }
        records[from.intentId] = to
    }
}
private final class HomeSecretsMemory: WorkbenchSecretProvider {
    var values: [String: Data] = [:]
    var removeFailures = 0
    func install(_ secret: Data, for authRef: String) throws { values[authRef] = secret }
    func load(authRef: String) throws -> Data {
        guard let value = values[authRef] else { throw ConnectionFailure.permissionRequired }
        return value
    }
    func remove(authRef: String) throws {
        if removeFailures > 0 {
            removeFailures -= 1
            throw ConnectionFailure.permissionRequired
        }
        values.removeValue(forKey: authRef)
    }
}
private final class HomeHTTPMemory: HTTPTransport, @unchecked Sendable {
    var response = HTTPTransportResponse(status: 200,
        body: Data("{\"message\":\"API running.\"}".utf8))
    var requests: [AuthorizedHTTPRequest] = []
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        return response
    }
}
private struct HomeResolverMemory: DestinationResolver {
    func addresses(for host: String) throws -> [String] { [host] }
}

final class WorkbenchHomeAssistantSetupAdapterTests: XCTestCase {
    func testPrivateAttemptJournalPersistsCASAndUnknownAcrossReopen() throws {
        let (_, review, _) = try fixture()
        let path = "/private/tmp/sp-ha-attempt-" + UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try WorkbenchHomeAssistantAttemptFileStore(path: path)
        let preparing = WorkbenchHomeAssistantAttempt(review: review,
            authRef: "ha-fixture-ref", provisioningId: "provision-fixture")
        try first.begin(preparing)
        XCTAssertThrowsError(try first.begin(preparing))
        var unknown = preparing; unknown.phase = .unknown
        try first.transition(from: preparing, to: unknown)
        let reopened = try WorkbenchHomeAssistantAttemptFileStore(path: path)
        XCTAssertEqual(try reopened.load(intentId: review.intentId), unknown)
        var installed = unknown; installed.phase = .installed
        XCTAssertThrowsError(try reopened.transition(from: preparing, to: installed))
        XCTAssertEqual(try first.load(intentId: review.intentId)?.phase, .unknown)
    }

    private func fixture() throws -> (DashboardManifest, WorkbenchHomeAssistantReviewedSetup,
                                     WorkbenchHomeAssistantContext) {
        let file = Data("<html>home</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "dashboard-1", name: "Home", revision: "revision-1",
            entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"),
            connections: [.init(alias: "home", required: true)],
            files: [.init(path: "index.html", bytes: file.count,
                sha256: DeploymentDigest.sha256Hex(file))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let context = WorkbenchHomeAssistantContext(workspaceId: "workspace-1",
            selectionGeneration: 2, deviceId: "device-1", dashboardId: manifest.dashboardId,
            revision: manifest.revision, packageDigest: try XCTUnwrap(manifest.digest),
            authorizationContextHash: String(repeating: "a", count: 64))
        let review = WorkbenchHomeAssistantReviewedSetup(intentId: "intent-1",
            context: context, origin: "https://home.example.test:8123",
            connectionId: "home-assistant", expiresAt: Date().addingTimeInterval(300))
        return (manifest, review, context)
    }

    func testVerifiedSetupBindsExactTargetAndNeverReplaysUnknownProvision() async throws {
        let (manifest, review, expected) = try fixture()
        let store = HomeAttemptMemory(), secrets = HomeSecretsMemory(), http = HomeHTTPMemory()
        var current = expected
        var sends = 0
        let adapter = WorkbenchHomeAssistantSetupAdapter(secrets: secrets, attempts: store,
            transport: http, resolver: HomeResolverMemory(), context: { current },
            provision: { device, configuration in
                sends += 1
                XCTAssertEqual(device, expected.deviceId)
                XCTAssertEqual(configuration.dashboardId, expected.dashboardId)
                XCTAssertEqual(configuration.revision, expected.revision)
                XCTAssertEqual(configuration.token, "private-token")
                throw ConnectionFailure.deviceOffline
            })
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        let prepared = try await adapter.prepare(review: review, manifest: manifest,
            secret: Data("private-token".utf8), capability: capability)
        XCTAssertEqual(prepared.phase, .prepared)
        XCTAssertEqual(secrets.values[prepared.authRef], Data("private-token".utf8))
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests[0].url.absoluteString, "https://home.example.test:8123/api/")
        XCTAssertEqual(http.requests[0].maxBytes, 16_384)
        XCTAssertEqual(store.records[review.intentId]?.phase, .prepared)
        current = .init(workspaceId: expected.workspaceId, selectionGeneration: 3,
            deviceId: expected.deviceId, dashboardId: expected.dashboardId,
            revision: expected.revision, packageDigest: expected.packageDigest,
            authorizationContextHash: expected.authorizationContextHash)
        do {
            _ = try await adapter.submit(intentId: review.intentId, manifest: manifest,
                capability: capability)
            XCTFail("stale selection sent to device")
        } catch WorkbenchHomeAssistantSetupFailure.staleContext { }
        XCTAssertEqual(sends, 0)
        current = expected
        do {
            _ = try await adapter.submit(intentId: review.intentId, manifest: manifest,
                capability: capability)
            XCTFail("lost device response was treated as success")
        } catch WorkbenchHomeAssistantSetupFailure.unknownRemoteOutcome { }
        XCTAssertEqual(store.records[review.intentId]?.phase, .unknown)
        XCTAssertEqual(sends, 1)
        do {
            _ = try await adapter.submit(intentId: review.intentId, manifest: manifest,
                capability: capability)
            XCTFail("unknown provision was resent")
        } catch WorkbenchHomeAssistantSetupFailure.conflict { }
        XCTAssertEqual(sends, 1)
    }

    func testInvalidAPIDoesNotSaveSecretAndPreparedCancellationRemovesIt() async throws {
        let (manifest, review, expected) = try fixture()
        let store = HomeAttemptMemory(), secrets = HomeSecretsMemory(), http = HomeHTTPMemory()
        http.response = .init(status: 302, body: Data())
        let adapter = WorkbenchHomeAssistantSetupAdapter(secrets: secrets, attempts: store,
            transport: http, resolver: HomeResolverMemory(), context: { expected },
            provision: { _, _ in XCTFail("preflight called device"); throw ConnectionFailure.deviceOffline })
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        do {
            _ = try await adapter.prepare(review: review, manifest: manifest,
                secret: Data("private-token".utf8), capability: capability)
            XCTFail("redirecting API was accepted")
        } catch WorkbenchHomeAssistantSetupFailure.invalidAPI { }
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        http.response = .init(status: 200, body: Data("{\"message\":\"API running.\"}".utf8))
        let prepared = try await adapter.prepare(review: review, manifest: manifest,
            secret: Data("private-token".utf8), capability: capability)
        try adapter.cancelPrepared(intentId: review.intentId, capability: capability)
        XCTAssertEqual(store.records[review.intentId]?.phase, .cancelled)
        XCTAssertNil(secrets.values[prepared.authRef])
    }

    func testMatchingReceiptInstallsAndMismatchedReceiptStaysUnknown() async throws {
        let (manifest, review, expected) = try fixture()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        let goodStore = HomeAttemptMemory()
        let good = WorkbenchHomeAssistantSetupAdapter(secrets: HomeSecretsMemory(),
            attempts: goodStore, transport: HomeHTTPMemory(),
            resolver: HomeResolverMemory(), context: { expected },
            provision: { device, configuration in
                HomeAssistantProvisioningReceipt(deviceId: device,
                    dashboardId: configuration.dashboardId, revision: configuration.revision,
                    connectionId: configuration.connectionId,
                    provisioningId: configuration.provisioningId)
            })
        _ = try await good.prepare(review: review, manifest: manifest,
            secret: Data("private-token".utf8), capability: capability)
        let installed = try await good.submit(intentId: review.intentId,
            manifest: manifest, capability: capability)
        XCTAssertEqual(installed.phase, .installed)
        XCTAssertEqual(goodStore.records[review.intentId]?.phase, .installed)

        let badStore = HomeAttemptMemory()
        let bad = WorkbenchHomeAssistantSetupAdapter(secrets: HomeSecretsMemory(),
            attempts: badStore, transport: HomeHTTPMemory(),
            resolver: HomeResolverMemory(), context: { expected },
            provision: { device, configuration in
                HomeAssistantProvisioningReceipt(deviceId: device,
                    dashboardId: configuration.dashboardId, revision: "wrong-revision",
                    connectionId: configuration.connectionId,
                    provisioningId: configuration.provisioningId)
            })
        _ = try await bad.prepare(review: review, manifest: manifest,
            secret: Data("private-token".utf8), capability: capability)
        do {
            _ = try await bad.submit(intentId: review.intentId,
                manifest: manifest, capability: capability)
            XCTFail("mismatched device receipt was accepted")
        } catch WorkbenchHomeAssistantSetupFailure.unknownRemoteOutcome { }
        XCTAssertEqual(badStore.records[review.intentId]?.phase, .unknown)
    }

    func testFailedCancellationKeepsSecretCleanupRetryableAndNeverSubmits() async throws {
        let (manifest, review, expected) = try fixture()
        let store = HomeAttemptMemory(), secrets = HomeSecretsMemory()
        var sends = 0
        let adapter = WorkbenchHomeAssistantSetupAdapter(secrets: secrets, attempts: store,
            transport: HomeHTTPMemory(), resolver: HomeResolverMemory(), context: { expected },
            provision: { _, _ in sends += 1; throw ConnectionFailure.deviceOffline })
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        let prepared = try await adapter.prepare(review: review, manifest: manifest,
            secret: Data("private-token".utf8), capability: capability)
        secrets.removeFailures = 1
        XCTAssertThrowsError(try adapter.cancelPrepared(intentId: review.intentId, capability: capability))
        XCTAssertEqual(store.records[review.intentId]?.phase, .cleanupPending)
        XCTAssertEqual(secrets.values[prepared.authRef], Data("private-token".utf8))
        do {
            _ = try await adapter.submit(intentId: review.intentId, manifest: manifest,
                capability: capability)
            XCTFail("cleanup-pending attempt submitted")
        } catch WorkbenchHomeAssistantSetupFailure.conflict { }
        XCTAssertEqual(sends, 0)
        try adapter.cancelPrepared(intentId: review.intentId, capability: capability)
        XCTAssertEqual(store.records[review.intentId]?.phase, .cancelled)
        XCTAssertNil(secrets.values[prepared.authRef])
    }

    func testFailedPrepareRetainsDurableSecretCleanupHandle() async throws {
        let (manifest, review, expected) = try fixture()
        let store = HomeAttemptMemory(), secrets = HomeSecretsMemory()
        store.failPreparedTransition = true
        secrets.removeFailures = 1
        let adapter = WorkbenchHomeAssistantSetupAdapter(secrets: secrets, attempts: store,
            transport: HomeHTTPMemory(), resolver: HomeResolverMemory(), context: { expected },
            provision: { _, _ in XCTFail("failed prepare submitted"); throw ConnectionFailure.deviceOffline })
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        do {
            _ = try await adapter.prepare(review: review, manifest: manifest,
                secret: Data("private-token".utf8), capability: capability)
            XCTFail("failed store transition was accepted")
        } catch WorkbenchHomeAssistantSetupFailure.cleanupPending { }
        let pending = try XCTUnwrap(store.records[review.intentId])
        XCTAssertEqual(pending.phase, .cleanupPending)
        XCTAssertEqual(secrets.values[pending.authRef], Data("private-token".utf8))
        try adapter.cancelPrepared(intentId: review.intentId, capability: capability)
        XCTAssertEqual(store.records[review.intentId]?.phase, .cancelled)
        XCTAssertNil(secrets.values[pending.authRef])
    }
}
#endif
