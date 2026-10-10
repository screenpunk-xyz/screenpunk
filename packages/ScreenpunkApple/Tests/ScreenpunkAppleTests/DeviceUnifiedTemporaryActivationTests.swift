import XCTest
import Foundation
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple
#if canImport(Network) && canImport(Security)
import Security

final class DeviceUnifiedTemporaryActivationTests: XCTestCase {
    func testGenuineRecipeActivatesAndExpiresWithoutNetworkAndRestartsWithTombstone() async throws {
        let fixture = try await AutomationFixture.make(targets: 1)
        defer { fixture.close() }
        let clock = AutomationClock()
        let http = AutomationHTTP(started: clock.now)
        let driver = fixture.genuine.common.makeTemporaryActivationDriver(http: http, resolver: FixedResolver(["93.184.216.34"]), clock: clock)
        let applied = try await driver.poll()
        XCTAssertTrue(applied)
        XCTAssertEqual(try fixture.genuine.common.validatedAssociation().configuredEntryID, fixture.targets[0])
        await driver.cancel()
        let reopened = fixture.genuine.common.makeTemporaryActivationDriver(http: http, resolver: FixedResolver(["93.184.216.34"]), clock: clock)
        clock.advance(3601)
        let restored = try await reopened.expire()
        XCTAssertTrue(restored)
        XCTAssertEqual(try fixture.genuine.common.validatedAssociation().configuredEntryID, fixture.baseEntry)
        let repeated = try await reopened.poll()
        XCTAssertFalse(repeated, "Expired repeated alert cannot replay after restart")
    }
    func testExplicitLocalChangeCancelsAutomaticExpiryAndAmbiguousRecipesAreRejected() async throws {
        let fixture = try await AutomationFixture.make(targets: 1)
        defer { fixture.close() }
        let clock = AutomationClock()
        let driver = fixture.genuine.common.makeTemporaryActivationDriver(http: AutomationHTTP(started: clock.now), resolver: FixedResolver(["93.184.216.34"]), clock: clock)
        let activated = try await driver.poll(); XCTAssertTrue(activated)
        let state = try fixture.client.queryActiveState()
        let beforePending = try fixture.genuine.common.validatedAssociation()
        let accepted = expectation(description: "Genuine paired explicit install accepted before CAS")
        let releasePreparation = DispatchSemaphore(value: 0)
        defer { releasePreparation.signal() }
        let originalPreparation = try XCTUnwrap(fixture.server.prepareIncomingLocalScreens)
        fixture.server.prepareIncomingLocalScreens = { operation, peer, screens, selected, validate in
            accepted.fulfill()
            guard releasePreparation.wait(timeout: .now() + 90) == .success else { throw TransferFailure.validationFailed }
            return try originalPreparation(operation, peer, screens, selected, validate)
        }
        let pendingPlan = LANUnifiedScreenInstall(operationId: UUID().uuidString.lowercased(),
            expectedGenerationId: try XCTUnwrap(state.stateGenerationId),
            retainedEntryIds: try XCTUnwrap(state.commonEntries).map(\.entryId),
            selectedEntryId: fixture.baseEntry.uuidString.lowercased(), incoming: fixture.incoming)
        let pending = Task.detached { try fixture.client.installUnifiedScreens(pendingPlan) }
        await fulfillment(of: [accepted], timeout: 30)
        do { _ = try await driver.poll(); XCTFail("Accepted explicit intent must prevent a new automatic activation before CAS") }
        catch { /* No fresh automatic owner can be issued for the superseded explicit base. */ }
        clock.advance(3601)
        do { let restored = try await driver.expire(); XCTAssertFalse(restored, "Accepted explicit intent must invalidate automatic restoration before CAS") }
        catch { /* Genuine coordinator rejects the captured automatic owner. */ }
        XCTAssertEqual(try fixture.genuine.common.validatedAssociation().generationID, beforePending.generationID,
            "Pending explicit acceptance cancels restoration before changing the inventory")
        releasePreparation.signal()
        _ = try await pending.value
        let explicit = try fixture.genuine.common.validatedAssociation()
        let expired = try await driver.expire(); XCTAssertFalse(expired)
        XCTAssertEqual(try fixture.genuine.common.validatedAssociation().generationID, explicit.generationID)
        let ambiguous = try await AutomationFixture.make(targets: 2)
        defer { ambiguous.close() }
        let rejected = ambiguous.genuine.common.makeTemporaryActivationDriver(http: AutomationHTTP(), resolver: FixedResolver(["93.184.216.34"]), clock: clock)
        do { _ = try await rejected.poll(); XCTFail("Multiple recipe targets must require review") }
        catch { XCTAssertTrue(error is ConnectionFailure) }
    }
}
private final class AutomationClock: PairingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(seconds) }
}
private final class AutomationHTTP: HTTPTransport, @unchecked Sendable {
    private let started: Date
    init(started: Date = Date()) { self.started = started }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        XCTAssertEqual(request.url.path, "/api/states/sensor.alert")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["Authorization"], "Bearer fixture-approved-private-token")
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["entity_id":"sensor.alert","state":"active","attributes":["id":"fixture-alert","started":formatter.string(from:started),"expires":formatter.string(from:started.addingTimeInterval(3600))]]))
    }
}
private struct AutomationFixture {
    let genuine: GenuineUnifiedInventoryFixture
    let server: DeviceLANServer
    let client: ControllerLANClient
    let targets: [UUID]
    let baseEntry: UUID
    let baseDashboard: String
    let incoming: [LANUnifiedScreenInstallEntry]
    func close() { client.cancel(); server.stop(); genuine.close() }
    static func make(targets count: Int) async throws -> Self {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        var completed = false
        defer { if !completed { fixture.close() } }
        let identity = try TLSIdentity.make(role: .device, commonName: "common-device")
        try recordOwnedTLSIdentity(identity)
        let first = try TLSIdentity.make(role: .controller, commonName: "automation-owner")
        try recordOwnedTLSIdentity(first)
        let context = try fixture.authority.makeConcurrentLocalContext(context: fixture.context, session: fixture.common)
        let profile = DeviceProfile(deviceId: "common-test", name: "Common")
        let server = try DeviceLANServer(management: context, runtime: .init(identity: identity.pairingIdentity,
            profile: profile, advertisement: .init(deviceId: profile.deviceId, host: "127.0.0.1", port: 0, source: .advertised)),
            identity: identity, homeAssistantVault: .init(store: MemoryCredentialStore()))
        defer { if !completed { server.stop() } }
        server.prepareIncomingLocalScreens = { operation, peer, screens, selected, validate in
            let ids = try NativeManagedLocalRootIDs(package: UUID(), grant: UUID(), structural: UUID(), provisioning: UUID(), contentGenesis: UUID())
            let roots = try fixture.authority.prepareIncomingLocalInventoryRoots(context: context, operationID: operation, ids: ids)
            XCTAssertTrue(roots.namespace.path.hasPrefix("/private/"), "Incoming fixture roots must use the physical parent")
            let local = try DeviceLegacyMigrationSession(packageRoot: roots.packageRoot, packageRootID: ids.package,
                grantRoot: roots.grantRoot, grantRootID: ids.grant, structuralRoot: roots.structuralRoot, structuralRootID: ids.structural,
                provisioningRoot: roots.provisioningRoot, provisioningRootID: ids.provisioning,
                legacyStateRoot: fixture.parent.appendingPathComponent("legacy-state"), legacyArchiveRoot: fixture.parent.appendingPathComponent("legacy-archive"),
                resetRoot: fixture.parent.appendingPathComponent("reset"), cloudRoot: fixture.parent.appendingPathComponent("cloud"),
                managementRoot: fixture.parent.appendingPathComponent("management"), preferencesRoot: fixture.parent.appendingPathComponent("preferences"),
                otherProtectedRoots: [], credentialTransport: FreshGrantTransport(rootID: ids.grant),
                validateRoots: { try fixture.authority.validateLocalInventoryRoots(roots) })
            let preparationSelection = selected.flatMap { candidate in screens.contains { $0.entryIdentity == candidate } ? candidate : nil } ?? screens.first?.entryIdentity
            do { try local.prepareAndCommit(screens: screens, selected: preparationSelection, owner: peer, profile: profile, profileID: "fixture-phone",
                operationID: operation, grantOperationID: UUID(), generationID: UUID(), grantRevisionID: UUID(),
                legacyGrantSet: nil, validateOriginal: validate) }
            catch { XCTFail("Local qualification failed: \(type(of: error)) \(error)"); throw error }
            return try DeviceIncomingLocalPreparation(completed: local, operationID: operation)
        }
        try server.attachUnifiedLocalSession(fixture.common)
        try server.start()
        let client = ControllerLANClient(identity: first)
        defer { if !completed { client.cancel() } }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: identity.pin)
        XCTAssertTrue(try client.hello().capabilities?.contains("unified-local-screen-install-v1") == true)
        let pairing = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
        try server.confirmLocally(); try client.confirmPairing(code: pairing.code)
        let baseline = try client.queryActiveState()
        let base = try XCTUnwrap(fixture.common.validatedAssociation().configuredEntryID)
        let baseDashboard = try XCTUnwrap(baseline.screens?.first?.dashboardId)
        let operation = UUID().uuidString.lowercased()
        var incoming: [LANUnifiedScreenInstallEntry] = []
        var ids: [UUID] = []
        for _ in 0..<count {
            let id = UUID(); ids.append(id)
            let html = Data("<html><body>Approved temporary screen</body></html>".utf8)
            var manifest = DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString.lowercased(), name: "Alert", revision: UUID().uuidString.lowercased(),
                entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "fixture-phone", width:390,height:844,scale:3,orientation:"portrait"),
                connections: [.init(alias:"home",required:true)], files:[.init(path:"index.html",bytes:html.count,sha256:PeerPin.hex(PeerPin.sha256(html)))])
            manifest.deviceBehavior = .init(temporaryActivation: .init(entityId:"sensor.alert",activeState:"active",inactiveState:"inactive",idAttribute:"id",startedAtAttribute:"started",expiresAtAttribute:"expires",maxDurationSeconds:3600))
            let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            manifest.digest=PeerPin.hex(PeerPin.sha256(try encoder.encode(manifest)))
            let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
            let deployment=DeploymentRecord(deploymentId:operation,revision:revision.revision,dashboardId:revision.dashboardId,deviceId:profile.deviceId,phase:.queued)
            let files=try [("manifest.json",encoder.encode(manifest)),("index.html",html)].map { path,bytes in LANFileBlob(path:path,sha256:PeerPin.hex(PeerPin.sha256(bytes)),dataBase64:bytes.base64EncodedString()) }
            let home=HomeAssistantProvisioning(dashboardId:revision.dashboardId,connectionId:"home",provisioningId:UUID().uuidString,revision:revision.revision,origin:"https://ha.example",token:"fixture-approved-private-token")
            incoming.append(.init(entryId:id.uuidString.lowercased(),screen:.init(name:"Alert",deployment:.init(deployment:deployment,revision:revision,files:files),homeAssistant:home)))
        }
        _ = try client.installUnifiedScreens(.init(operationId:operation,expectedGenerationId:try XCTUnwrap(baseline.stateGenerationId),
            retainedEntryIds:try XCTUnwrap(baseline.commonEntries).map(\.entryId),selectedEntryId:base.uuidString.lowercased(),incoming:incoming))
        let installed = try fixture.common.validatedAssociation()
        XCTAssertEqual(installed.configuredEntryID, base, "Installing an approved local package does not activate it or replace the displayed cloud screen")
        XCTAssertEqual(installed.entries.count, count + 1)
        completed = true
        return .init(genuine:fixture,server:server,client:client,targets:ids,baseEntry:base,baseDashboard:baseDashboard,incoming:incoming)
    }
}
private func recordOwnedTLSIdentity(_ material: TLSIdentityMaterial) throws {
    guard let evidenceRoot = ProcessInfo.processInfo.environment["SCREENPUNK_TEST_EVIDENCE_ROOT"] else { return }
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(material.identity, &certificate) == errSecSuccess,
        let certificate, let label = SecCertificateCopySubjectSummary(certificate) as String? else { throw TransferFailure.validationFailed }
    let directory = URL(fileURLWithPath: evidenceRoot, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("native-temporary-tls-identities.json")
    var entries = (try? JSONSerialization.jsonObject(with: Data(contentsOf: path))) as? [[String: String]] ?? []
    entries.append(["owner": "/root/paid_services", "label": label, "publicPin": PeerPin.hex(material.pin),
        "retentionReason": "Task-created genuine TLS test identity; Keychain preserved per AGENTS.md."])
    try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted,.sortedKeys]).write(to: path, options: .atomic)
}
#endif
