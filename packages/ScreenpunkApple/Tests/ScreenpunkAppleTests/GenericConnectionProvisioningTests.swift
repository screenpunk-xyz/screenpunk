import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class GenericConnectionProvisioningTests: XCTestCase {
    private func configuration(revision: String = "r1", id: String = "install-1", method: ConnectionMethod = .GET, write: Bool = false) -> ConnectionProvisioning {
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "sensor", origin: "https://example.com", transport: .http,
            authRef: "sensor-native", lan: false, allowInsecureHTTP: false,
            operations: [.init(name: "read", kind: .http, method: method, path: "/status", idempotent: !write, write: write)])
        return .init(dashboardId: "dash", revision: revision, provisioningId: id,
                     entries: [.init(grant: grant, binding: .init(authRef: grant.authRef, placement: .bearer), secret: Data("native-secret".utf8))])
    }
    func testPairedTLSInstallRequiresOwnerAndActiveRevision() async throws {
        let deviceIdentity = try TLSIdentity.make(role: .device, commonName: "generic-device")
        let ownerIdentity = try TLSIdentity.make(role: .controller, commonName: "generic-owner")
        let vault = GenericConnectionDeviceVault(store: MemoryCredentialStore())
        let device = DeviceRuntime(identity: deviceIdentity.pairingIdentity,
            profile: DeviceProfile(deviceId: "generic-phone", name: "Phone"),
            advertisement: .init(deviceId: "generic-phone", host: "127.0.0.1", port: 0, source: .advertised))
        let server = DeviceLANServer(runtime: device, identity: deviceIdentity,
            homeAssistantVault: HomeAssistantDeviceVault(store: MemoryCredentialStore()), genericConnectionVault: vault)
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: ownerIdentity); defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(try client.hello().capabilities?.contains("generic-connections-v1") == true)
        var config = configuration()
        config.dashboardId = StoredRevision.offlineFixture.dashboardId
        config.revision = StoredRevision.offlineFixture.revision
        XCTAssertThrowsError(try client.provisionConnections(config))
        let begin = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
        try server.confirmLocally(); try client.confirmPairing(code: begin.code)
        XCTAssertThrowsError(try client.provisionConnections(config))
        let deploy = DeploymentRecord(deploymentId: "generic-deploy", revision: config.revision,
                                      dashboardId: config.dashboardId, deviceId: "generic-phone", phase: .queued)
        XCTAssertEqual(try client.deploy(.init(deployment: deploy, revision: .offlineFixture, files: LANPackageFiles.offlineFixture())).phase, .active)
        let receipt = try client.provisionConnections(config)
        XCTAssertTrue(receipt.installed); XCTAssertEqual(receipt.reachability, "not_checked")
        XCTAssertFalse(try LANCodec.encodePayload(receipt).contains("native-secret"))
        XCTAssertEqual(try client.provisionConnections(config), receipt)
        _ = try await server.makeGenericConnectionRuntime()
        config.revision = "wrong"
        XCTAssertThrowsError(try client.provisionConnections(config))
        try client.revokeConnections()
        do { _ = try await server.makeGenericConnectionRuntime(); XCTFail("revoke must erase grants") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }

    func testAtomicPersistenceOwnerRevisionAndRevocation() async throws {
        let store = MemoryCredentialStore()
        let vault = GenericConnectionDeviceVault(store: store)
        let config = configuration()
        try vault.provision(config, owner: "owner")
        try vault.provision(config, owner: "owner") // same id/payload is idempotent
        var changed = config; changed.entries[0].secret = Data("changed".utf8)
        XCTAssertThrowsError(try vault.provision(changed, owner: "owner"))
        let reloaded = GenericConnectionDeviceVault(store: store)
        let scope = GenericConnectionDeviceVault.Scope(owner: "owner", dashboardId: "dash", revision: "r1")
        let transport = ProvisionHTTP()
        let runtime = try await reloaded.makeRuntime(scope: scope, currentScope: { scope }, http: transport, resolver: FixedResolver(["93.184.216.34"]))
        let result = try await runtime.requestRead(alias: "sensor", operation: "read", parameters: [:])
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(transport.authorization, "Bearer native-secret")
        let wrong = GenericConnectionDeviceVault.Scope(owner: "other-owner", dashboardId: "dash", revision: "r1")
        do { _ = try await reloaded.makeRuntime(scope: wrong, currentScope: { wrong }); XCTFail("must reject owner") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        try vault.revoke()
        do { _ = try await runtime.requestRead(alias: "sensor", operation: "read", parameters: [:]); XCTFail("old actor must reject revoked grant") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }
    func testRevisionChangeAndReprovisionInvalidateOldActors() async throws {
        let vault = GenericConnectionDeviceVault(store: MemoryCredentialStore())
        try vault.provision(configuration(), owner: "owner")
        let scope = GenericConnectionDeviceVault.Scope(owner: "owner", dashboardId: "dash", revision: "r1")
        let runtime = try await vault.makeRuntime(scope: scope, currentScope: { scope }, http: ProvisionHTTP())
        try vault.provision(configuration(revision: "r2", id: "install-2"), owner: "owner")
        do { _ = try await runtime.requestRead(alias: "sensor", operation: "read", parameters: [:]); XCTFail("old revision must reject") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }
    func testRevokedWhileRequestInFlightNeverReturnsResponseOrStaleCache() async throws {
        let vault = GenericConnectionDeviceVault(store: MemoryCredentialStore())
        try vault.provision(configuration(), owner: "owner")
        let scope = GenericConnectionDeviceVault.Scope(owner: "owner", dashboardId: "dash", revision: "r1")
        let runtime = try await vault.makeRuntime(scope: scope, currentScope: { scope },
            http: RevokingHTTP { try vault.revoke() }, resolver: FixedResolver(["93.184.216.34"]))
        do { _ = try await runtime.requestRead(alias: "sensor", operation: "read", parameters: [:]); XCTFail("revoked response must not escape") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }

    func testPollingRejectsWriteOperation() async throws {
        let vault = GenericConnectionDeviceVault(store: MemoryCredentialStore())
        try vault.provision(configuration(method: .POST, write: true), owner: "owner")
        let scope = GenericConnectionDeviceVault.Scope(owner: "owner", dashboardId: "dash", revision: "r1")
        let runtime = try await vault.makeRuntime(scope: scope, currentScope: { scope }, http: ProvisionHTTP())
        do { _ = try await runtime.requestRead(alias: "sensor", operation: "read", parameters: [:]); XCTFail("poll must not write") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        do { _ = try await runtime.subscribe(alias: "sensor", operation: "read", parameters: [:]); XCTFail("HTTP grant cannot become WS grant") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }
    func testRejectsCredentialInjectionAndDuplicateAliases() throws {
        var config = configuration()
        config.entries[0].secret = Data("token\r\nX-Evil: injected".utf8)
        XCTAssertThrowsError(try config.validate())
        config = configuration(); config.entries.append(config.entries[0])
        XCTAssertThrowsError(try config.validate())
        config = configuration(); config.entries[0].binding = .init(authRef: "sensor-native", placement: .header, fieldName: "Host")
        XCTAssertThrowsError(try config.validate())
    }
}

private final class ProvisionHTTP: HTTPTransport, @unchecked Sendable {
    var authorization: String?
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        authorization = request.headers["Authorization"]
        return .init(status: 200, body: Data("{\"active\":true}".utf8))
    }
}

private struct RevokingHTTP: HTTPTransport {
    let revoke: @Sendable () throws -> Void
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        try revoke()
        return .init(status: 200, body: Data("{\"active\":true}".utf8))
    }
}
