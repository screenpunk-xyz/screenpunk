import XCTest
import Foundation
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple

@MainActor final class CloudLegacyProviderIsolationTests: XCTestCase {
    private final class Replies { var receive: (([String: Any]) -> Void)? }
    private var replies: [ObjectIdentifier: Replies] = [:]
    func testMountedCloudCannotReuseRemovedLocalProviderApprovalsOrPreferences() async throws {
        let dashboard = UUID(), revision = UUID(), localEntry = UUID()
        let dashboardID = dashboard.uuidString.lowercased()
        var maps = ManifestConnection(alias: "appleMaps", required: false)
        maps.operations = ["snapshot", "present", "update", "close"].map { .init(name: $0, kind: "http") }
        let declarations = [ManifestConnection(alias: "googleCalendar", required: false),
            ManifestConnection(alias: "google-calendar", required: false), ManifestConnection(alias: "googleTV", required: false), maps]
        let fixture = try await GenuineUnifiedInventoryFixture.make { authority, parent in
            let lease = try XCTUnwrap(authority.refresh())
            let ids = try NativeManagedLocalRootIDs(package: UUID(), grant: UUID(), structural: UUID(), provisioning: UUID(), contentGenesis: UUID())
            let roots = try authority.prepareLocalInventoryRoots(lease: lease, ids: ids)
            let local = try DeviceLegacyMigrationSession(packageRoot: roots.packageRoot, packageRootID: ids.package,
                grantRoot: roots.grantRoot, grantRootID: ids.grant, structuralRoot: roots.structuralRoot, structuralRootID: ids.structural,
                provisioningRoot: roots.provisioningRoot, provisioningRootID: ids.provisioning,
                legacyStateRoot: parent.appendingPathComponent("legacy-state"), legacyArchiveRoot: parent.appendingPathComponent("legacy-archive"),
                resetRoot: parent.appendingPathComponent("reset"), cloudRoot: parent.appendingPathComponent("Application Support/xyz.screenpunk.native-managed"),
                managementRoot: parent.appendingPathComponent("management"), preferencesRoot: parent.appendingPathComponent("preferences"),
                otherProtectedRoots: [], credentialTransport: FreshGrantTransport(rootID: ids.grant),
                validateRoots: { try authority.validateLocalInventoryRoots(roots) })
            let html = Data("<html>Local provider fixture</html>".utf8)
            var manifest = DashboardManifest(schemaVersion: 1, dashboardId: dashboardID, name: "Local", revision: revision.uuidString.lowercased(),
                entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "Fixture", width: 390, height: 844, scale: 3, orientation: "portrait"),
                connections: declarations, files: [.init(path: "index.html", bytes: html.count, sha256: AuthorityStaticDeliveryFixture.hash(html))])
            manifest.digest = AuthorityStaticDeliveryFixture.hash(try AuthorityStaticDeliveryFixture.encoded(manifest))
            let stored = StoredRevision(revision: manifest.revision, dashboardId: dashboardID, name: manifest.name,
                digest: try XCTUnwrap(manifest.digest), orientation: .portrait, width: 390, height: 844)
            let screen = DeviceLegacyMigrationScreen(entryID: localEntry, packageOperationID: UUID(), displayName: "Local", revision: stored,
                manifest: try AuthorityStaticDeliveryFixture.encoded(manifest), files: ["index.html": html], homeAssistant: nil, generic: nil, publicReads: nil)
            try local.prepareAndCommit(screens: [screen], selected: localEntry, owner: PairingIdentityFactory.make(role: .controller),
                profile: .init(deviceId: "local-fixture", name: "Local"), profileID: "Fixture", operationID: UUID(), grantOperationID: UUID(),
                generationID: UUID(), grantRevisionID: UUID(), legacyGrantSet: nil, validateOriginal: { try authority.validateLocalInventoryRoots(roots) })
            return local
        }
        defer { fixture.close() }
        let owner = try OutcomeReplayLocalOwner(fixture: fixture)
        let entries = try fixture.common.validatedAssociation().entries
        try fixture.common.selectOrRemove(operationID: UUID(), generationID: UUID(), retainedEntryIDs: entries.map(\.entryID), selected: localEntry, owner: owner)
        let localRuntime = try await runtime(fixture)
        try fixture.common.confirmMountedLocalContent(localRuntime.content)
        try localRuntime.verifyActive()
        XCTAssertTrue(localRuntime.allowsLegacyDeviceLocalAccess)

        let credentials = IsolationCredentialStore(), transport = IsolationCalendarTransport()
        let account = GoogleCalendarAccount(id: "account", email: "fixture@example.test", clientID: "fixture.apps.googleusercontent.com",
            accessToken: "synthetic", refreshToken: "synthetic", expiresAt: .distantFuture, calendars: [.init(id: "calendar", summary: "Local calendar")])
        try credentials.put(JSONEncoder().encode(GoogleCalendarState(accounts: [account], selections: [dashboardID: [.init(accountID: "account", calendarID: "calendar")]])), for: GoogleCalendarDeviceService.storageKey)
        let calendar = GoogleCalendarDeviceService(store: credentials, transport: transport, suspension: GoogleCalendarSuspensionDomain())
        let preferences = ScreenPreferenceStore(root: fixture.parent.appendingPathComponent("isolated-preferences"))
        let generation = try preferences.generation()
        try preferences.set(dashboard: dashboardID, key: "secret", value: "Local private value", generation: generation)
        let suite = "screenpunk.isolation." + UUID().uuidString
        let defaults = try XCTUnwrap(IsolationMapDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let approvalKey = "appleMaps.approved." + PeerPin.hex(PeerPin.sha256(Data((dashboardID + "\n" + revision.uuidString.lowercased()).utf8)))
        defaults.set(true, forKey: approvalKey)
        let approval = MapPreviewApproval(defaults: defaults)
        var tvLookups = 0, cloudPhase = false
        var savedTV = GoogleTVConfiguration(host: "invalid.example", pin: Data(repeating: 1, count: 32), dashboardIDs: [dashboardID])
        savedTV.automaticScreenAccess = true
        let tv = GoogleTVScreenConnection(loadConfiguration: {
            tvLookups += 1
            // Even a failing regression must not connect to a real provider.
            return cloudPhase ? GoogleTVConfiguration() : savedTV
        })
        let parameters = ["timeMin": "2026-10-19T00:00:00Z", "timeMax": "2026-10-20T00:00:00Z"]
        let localBridge = try bridge(localRuntime, preferences, calendar, tv, approval)
        defer { localBridge.suspendForReset() }
        let reply1 = try await send(localBridge, method: "state.get", key: "secret")
        XCTAssertEqual(reply1["value"] as? String, "Local private value")
        let reply2 = try await send(localBridge, method: "state.set", key: "temporary", value: "Local write")
        XCTAssertEqual(reply2["ok"] as? Bool, true)
        let reply3 = try await send(localBridge, method: "state.remove", key: "temporary")
        XCTAssertEqual(reply3["ok"] as? Bool, true)
        for alias in ["googleCalendar", "google-calendar"] {
            let result = try await send(localBridge, alias: alias, operation: "events", parameters: parameters)
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertTrue(String(describing: result["value"]).contains("Local calendar"))
        }
        XCTAssertGreaterThan(transport.requests, 0)
        _ = try await send(localBridge, alias: "googleTV", operation: "invalid-no-network")
        XCTAssertEqual(tvLookups, 1, "Local dispatch still consults the existing approved TV configuration")
        let rect = #"{"x":0,"y":0,"width":320,"height":240,"viewportWidth":390,"radius":0,"visible":1}"#
        _ = try await send(localBridge, alias: "appleMaps", operation: "present", parameters: ["id": "map", "address": "Fixture", "rect": rect])
        XCTAssertGreaterThan(defaults.reads, 0, "Local presentation consults the existing revision approval; no WebView means no Maps IO")
        let reply4 = try await send(localBridge, alias: "appleMaps", operation: "close", parameters: ["id": "map"])
        XCTAssertEqual(reply4["ok"] as? Bool, true)
        localBridge.suspendForReset(); await localRuntime.cancel()

        // Remove the Local inventory entry, deliberately retaining its provider approvals and state.
        let retained = entries.filter { $0.entryID != localEntry }.map(\.entryID)
        try fixture.common.selectOrRemove(operationID: UUID(), generationID: UUID(), retainedEntryIDs: retained, selected: retained.first,
            owner: OutcomeReplayLocalOwner(fixture: fixture))
        let delivery = try UnifiedArchiveComposition.make(fixture: fixture, changedPublication: false, connections: declarations, dashboard: dashboard, revision: revision)
        fixture.http.delivery = delivery.value
        let current = try fixture.authority.prepareCurrentInstallationDispatch(fixture.context)
        let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: fixture.installation, current: current, origin: fixture.http.origin, configuration: fixture.http.configuration)
        let plan = try await command.fetchPlan(current: current, origin: fixture.http.origin, nativeOperationID: UUID(), configuration: fixture.http.configuration)
        _ = try plan.acceptUnified(session: fixture.common, current: current)
        let archives = try await plan.fetchArchives(current: current, origin: fixture.http.origin, target: delivery.value.archive.target, profileID: "Fixture", revisionName: "Fixture", configuration: fixture.http.configuration)
        try archives.prepareUnified(session: fixture.common, current: current, packageRootID: UUID(), grantOperationID: UUID(), grantRevisionID: UUID())
        let activation = try fixture.common.retainCloudActivationRequest(requestID: UUID(), current: current)
        let authorization = try await NativeDeliveryActivationHTTPObservation.collect(body: activation, installation: fixture.installation, current: current, origin: fixture.http.origin, configuration: fixture.http.configuration)
        try fixture.common.retainCloudAuthorization(requestBody: activation, observation: authorization)
        _ = try fixture.common.dispatchCloudAndRetainActivatedOutcome(current: current)
        let cloud = try await runtime(fixture)
        try fixture.common.confirmMountedLocalContent(cloud.content)
        try cloud.verifyActive()
        XCTAssertFalse(cloud.allowsLegacyDeviceLocalAccess)
        XCTAssertEqual(cloud.manifest.dashboardId, localRuntime.manifest.dashboardId)
        XCTAssertEqual(cloud.manifest.revision, localRuntime.manifest.revision)
        XCTAssertNotEqual(cloud.content.entryID, localEntry)
        XCTAssertNotEqual(cloud.manifest.digest, localRuntime.manifest.digest)
        cloudPhase = true; defaults.denyExternal = true
        let credentialReads = credentials.reads, calendarRequests = transport.requests, mapReads = defaults.reads
        let cloudBridge = try bridge(cloud, preferences, calendar, tv, approval)
        defer { cloudBridge.suspendForReset() }
        for method in ["state.get", "state.set", "state.remove"] {
            let result = try await send(cloudBridge, method: method, key: "secret", value: method == "state.set" ? "Cloud overwrite" : nil)
            XCTAssertEqual(result["code"] as? String, "permission_required", method)
            XCTAssertNil(result["value"])
        }
        for method in ["connections.request", "connections.subscribe"] {
            for alias in ["googleCalendar", "google-calendar"] {
                let reply5 = try await send(cloudBridge, method: method, alias: alias, operation: "events", parameters: parameters)
                XCTAssertEqual(reply5["code"] as? String, "permission_required")
            }
            for operation in ["status", "key", "launchLink", "voice", "launchChannel", "togglePower"] {
                let reply6 = try await send(cloudBridge, method: method, alias: "googleTV", operation: operation)
                XCTAssertEqual(reply6["code"] as? String, "permission_required")
            }
            for operation in ["snapshot", "present", "update", "close"] {
                let reply7 = try await send(cloudBridge, method: method, alias: "appleMaps", operation: operation, parameters: ["id": "map", "address": "Fixture", "rect": rect])
                XCTAssertEqual(reply7["code"] as? String, "permission_required")
            }
        }
        XCTAssertEqual(credentials.reads, credentialReads, "No Calendar credential/approval lookup, including cached events")
        XCTAssertEqual(transport.requests, calendarRequests)
        XCTAssertEqual(tvLookups, 1, "No TV configuration/provider lookup")
        XCTAssertEqual(defaults.reads, mapReads, "No Maps approval lookup")
        XCTAssertEqual(try preferences.get(dashboard: dashboardID, key: "secret", generation: generation) as? String, "Local private value")
        let reply8 = try await send(cloudBridge, method: "navigation.get")
        XCTAssertEqual(reply8["ok"] as? Bool, true)
        let reply9 = try await send(cloudBridge, method: "runtime.ready")
        XCTAssertEqual(reply9["ok"] as? Bool, true)
        let capabilities = try await send(cloudBridge, method: "runtime.onStatus")
        let flags = try XCTUnwrap(capabilities["value"] as? [String: Any])
        for key in ["persistentState", "persistentStateWritable", "appleMaps", "appleMapsInteractive"] {
            XCTAssertEqual(flags[key] as? Int, 0)
        }
        // A historical presentation exists only after configuration advances beyond
        // the mounted generation. Keep the mounted package while selecting another.
        let cloudEntries = try fixture.common.validatedAssociation().entries
        try fixture.common.selectOrRemove(operationID: UUID(), generationID: UUID(), retainedEntryIDs: cloudEntries.map(\.entryID),
            selected: delivery.retainedEntryID, owner: OutcomeReplayLocalOwner(fixture: fixture))
        let historical = try await fixture.common.lastSuccessfulManagedRuntime(operationID: UUID(), http: IsolationCalendarTransport(),
            webSocket: URLSessionWebSocketTransport(), resolver: LiteralOrResolvedDestinationResolver(), clock: SystemClock())
        XCTAssertFalse(historical.allowsLegacyDeviceLocalAccess, "Historical/restored Cloud issuance must retain the same restriction")
        try fixture.common.confirmMountedLocalContent(historical.content)
        try historical.verifyActive()
        await historical.cancel(); await cloud.cancel()
    }

    private func runtime(_ fixture: GenuineUnifiedInventoryFixture) async throws -> DeviceUnifiedManagedRuntime {
        try await fixture.common.makeManagedRuntime(operationID: UUID(), http: IsolationCalendarTransport(), webSocket: URLSessionWebSocketTransport(), resolver: LiteralOrResolvedDestinationResolver(), clock: SystemClock())
    }
    private func bridge(_ runtime: DeviceUnifiedManagedRuntime, _ preferences: ScreenPreferenceStore, _ calendar: GoogleCalendarDeviceService,
        _ tv: GoogleTVScreenConnection, _ maps: MapPreviewApproval) throws -> HomeAssistantWebBridge {
        let navigation = try DashboardEventRuntime(manifest: runtime.manifest, revision: runtime.manifest.revision, settings: .init(), homeAssistant: nil, connections: nil)
        let relay = Replies()
        let bridge = HomeAssistantWebBridge(runtime: nil, managedRuntime: runtime, navigation: navigation, revision: runtime.manifest.revision,
            preferenceStore: preferences, calendarService: calendar, resources: PublicRasterResources(), googleTV: tv, mapApproval: maps, observeReply: { relay.receive?($0) }, onHealth: { _ in })
        replies[ObjectIdentifier(bridge)] = relay
        return bridge
    }
    private func send(_ bridge: HomeAssistantWebBridge, method: String = "connections.request", alias: String = "", operation: String = "",
        parameters: [String: String] = [:], key: String? = nil, value: String? = nil) async throws -> [String: Any] {
        let id = UUID().uuidString
        var body: [String: Any] = ["protocolVersion": 1, "kind": "request", "id": id, "method": method]
        if method.hasPrefix("connections.") { body["alias"] = alias; body["operation"] = operation; body["parameters"] = parameters }
        body["key"] = key; body["value"] = value
        let done = expectation(description: method + " " + alias + " " + operation)
        var result: [String: Any]?
        try XCTUnwrap(replies[ObjectIdentifier(bridge)]).receive = { response in if response["id"] as? String == id { result = response; done.fulfill() } }
        bridge.handleValidatedBody(body, id: id)
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
}

private final class IsolationCredentialStore: CredentialStore, @unchecked Sendable {
    let memory = MemoryCredentialStore()
    private(set) var reads = 0
    func secret(for key: String) throws -> Data? { reads += 1; return try memory.secret(for: key) }
    func put(_ secret: Data, for key: String) throws { try memory.put(secret, for: key) }
    func delete(_ key: String) throws { try memory.delete(key) }
    func deleteAll() throws { try memory.deleteAll() }
}
private final class IsolationCalendarTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        record()
        return .init(status: 200, body: Data(#"{"items":[{"id":"fixture","summary":"Private Local event"}]}"#.utf8), headers: [:])
    }
}
private final class IsolationMapDefaults: UserDefaults {
    private(set) var reads = 0
    var denyExternal = false
    override func bool(forKey key: String) -> Bool { reads += 1; return denyExternal ? false : super.bool(forKey: key) }
}
