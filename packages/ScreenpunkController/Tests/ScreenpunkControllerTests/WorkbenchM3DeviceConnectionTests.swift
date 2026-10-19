import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private final class M3Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 2_000_000_000)
}
private final class M3Secrets: WorkbenchSecretProvider {
    var values: [String: Data] = [:]
    var loadLocked = false
    var failAfterInstall = false
    var removeLocked = false
    func install(_ secret: Data, for authRef: String) throws {
        values[authRef] = secret
        if failAfterInstall { throw ConnectionFailure.permissionRequired }
    }
    func load(authRef: String) throws -> Data {
        if loadLocked { throw ConnectionFailure.permissionRequired }
        guard let value = values[authRef] else { throw ConnectionFailure.permissionRequired }
        return value
    }
    func remove(authRef: String) throws {
        if removeLocked { throw ConnectionFailure.permissionRequired }
        values[authRef] = nil
    }
}
private final class M3ProvisioningState: @unchecked Sendable {
    enum Failure { case interrupted, unsupported }
    var last: ConnectionProvisioning?
    var calls = 0
    var failure: Failure?
}
private final class M3ProvisioningLink: DeviceLink {
    let inner: FakeLANLink
    let state: M3ProvisioningState
    init(device: FakeLANDevice, controllerPin: [UInt8], state: M3ProvisioningState) {
        inner = FakeLANLink(device: device, controllerPin: controllerPin); self.state = state
    }
    var devicePin: [UInt8]? { inner.devicePin }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws {
        try inner.connect(host: host, port: port, pinnedDevice: pinnedDevice)
    }
    func hello() throws -> LANHello { try inner.hello() }
    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult { try inner.beginPairing(nonce: nonce) }
    func confirmPairing(code: String) throws { try inner.confirmPairing(code: code) }
    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord { try inner.deploy(body) }
    func queryActive() throws -> String? { try inner.queryActive() }
    func getSettings() throws -> DeviceSettingsSnapshot { try inner.getSettings() }
    func updateSettings(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot { try inner.updateSettings(update) }
    func connectionInventory() throws -> DeviceConnectionInventory {
        let entries = state.last?.entries.map { item in
            DeviceConnectionEntry(id: item.grant.id.uuidString,
                screen: .init(dashboardId: state.last!.dashboardId,
                              revision: state.last!.revision, name: "Connected"),
                name: item.grant.alias, kind: "Custom connection", origin: item.grant.origin,
                authentication: item.binding.placement.rawValue,
                operations: item.grant.operations.map {
                    .init(name: $0.name, method: $0.method.rawValue,
                          path: $0.path, write: $0.write)
                })
        } ?? []
        return DeviceConnectionInventory(deviceId: inner.device.runtime.profile.deviceId, entries: entries)
    }
    func provisionConnections(_ configuration: ConnectionProvisioning) throws -> ConnectionProvisioningReceipt {
        try configuration.validate()
        state.calls += 1; state.last = configuration
        switch state.failure {
        case .interrupted: throw TransferFailure.interrupted
        case .unsupported: throw ControllerError(code: .unsupportedVersion, detail: "Generic connections unsupported")
        case nil: break
        }
        return .init(deviceId: inner.device.runtime.profile.deviceId,
                     dashboardId: configuration.dashboardId, revision: configuration.revision,
                     provisioningId: configuration.provisioningId)
    }
    func cancel() { inner.cancel() }
}
private struct M3Factory: DeviceLinkFactory {
    let device: FakeLANDevice
    let controllerIdentity: PairingIdentity
    let state: M3ProvisioningState
    func makeLink() throws -> DeviceLink {
        M3ProvisioningLink(device: device, controllerPin: controllerIdentity.publicKey, state: state)
    }
}
private struct M3Documents: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchM3DeviceConnectionTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let device = FakeLANDevice(deviceId: "m3-device", name: "Kitchen iPad")
        let clock = M3Clock()
        let secrets = M3Secrets()
        let provisioning = M3ProvisioningState()
        let owner = PairingIdentityFactory.make(role: .controller)
        let coordinator: DeviceCoordinator
        let workspace: WorkspaceStore
        let connections: WorkbenchConnectionDomain
        let devices: WorkbenchDeviceDomain
        let visible: URL
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/sp-m3-" + UUID().uuidString.prefix(10))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let documents = root.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
            visible = root.appendingPathComponent("visible")
            workspace = try WorkspaceStore(documents: M3Documents(url: documents),
                                           machineRootPath: root.appendingPathComponent("machine").path)
            _ = try workspace.create(at: visible.path)
            let hub = LoopbackDiscovery(); hub.advertise(device.runtime.advertisement)
            coordinator = DeviceCoordinator(directory: DeviceDirectory(url: root.appendingPathComponent("devices.json")),
                hub: hub, linkFactory: M3Factory(device: device, controllerIdentity: owner, state: provisioning),
                now: { [clock] in clock.date })
            connections = try WorkbenchConnectionDomain(machineAuthorityPath: root.appendingPathComponent("authority").path,
                devices: coordinator, workspace: workspace, secrets: secrets, now: { [clock] in clock.date })
            devices = connections.deviceDomain()
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func pair() throws {
            let pending = try devices.beginPairing(deviceId: device.runtime.profile.deviceId)
            device.confirmLocally()
            _ = try devices.confirmPairing(pendingId: pending.pendingId, matchingCode: pending.matchingCode)
        }
        func grant() -> (ConnectionGrant, ConnectionAuthBinding) {
            let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "kitchen",
                origin: "https://example.local", transport: .http, authRef: "m3-secret",
                lan: true, allowInsecureHTTP: false,
                operations: [.init(name: "lights", kind: .http, method: .GET,
                                   path: "/api/lights?view=hidden", idempotent: true, write: false)])
            return (grant, .init(authRef: "m3-secret", placement: .bearer))
        }
        func retainScreenRevision(dashboardId: String = "dashboard-1",
                                  revision: String = "revision-1") throws {
            let html = Data("<html>connection scope</html>".utf8)
            var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
                dashboardId: dashboardId, name: "Connected", revision: revision,
                entrypoint: "index.html", sdkVersion: "1",
                target: .init(profileId: "m3-device", width: 800, height: 480,
                    scale: 1, orientation: "landscape"), connections: [],
                files: [.init(path: "index.html", bytes: html.count,
                    sha256: DeploymentDigest.sha256Hex(html))])
            manifest.digest = try DeploymentDigest.digest(for: manifest)
            _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
                .init(manifest: manifest, files: ["index.html": html]))
        }
    }

    func testOrdinaryIntentCapacityExpiresAndReservesTrustedSetup() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        func grant() -> ConnectionGrant {
            ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "bounded",
                origin: "https://example.local", transport: .http, authRef: "none-ref", lan: true,
                allowInsecureHTTP: false,
                operations: [.init(name: "read", kind: .http, method: .GET,
                                   path: "/api/read", idempotent: true, write: false)])
        }
        let auth = ConnectionAuthBinding(authRef: "none-ref", placement: .none)
        var first: String?
        for index in 0..<384 {
            let staged = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
                dashboardId: "dashboard-1", revision: "revision-1", grant: grant(),
                auth: auth, expiresIn: 60)
            if index == 0 { first = staged.intentId }
        }
        XCTAssertThrowsError(try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant(), auth: auth)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .intentCapacity)
        }
        let trusted = try fixture.connections.hostConfigureGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant(),
            auth: auth, secret: nil)
        XCTAssertEqual(trusted.state, "pending")
        XCTAssertNil(try fixture.connections.resolveGenericIntent(try XCTUnwrap(first),
            approve: false, capability: .hostTerminalOrGUI()))
        _ = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant(), auth: auth)
        let authority = try WorkbenchLocalAuthorityStore(path: fixture.root.appendingPathComponent("authority").path)
        try authority.update { state in state.intents[trusted.intentId]?.state = .uncertain }
        fixture.clock.date.addTimeInterval(61)
        let afterExpiry = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant(), auth: auth)
        XCTAssertEqual(afterExpiry.state, "pending")
        let state = try authority.read()
        XCTAssertLessThan(state.intents.count, 10)
        XCTAssertEqual(state.intents[first!]?.state, .denied)
        XCTAssertEqual(state.intents[trusted.intentId]?.state, .uncertain)
        XCTAssertEqual(fixture.provisioning.calls, 0)
    }

    func testTrustedSetupRecoversFromLegacyUnlabelledSaturation() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let (initialGrant, initialAuth) = fixture.grant()
        let initial = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1",
            grant: initialGrant, auth: initialAuth)
        let authority = try WorkbenchLocalAuthorityStore(path: fixture.root.appendingPathComponent("authority").path)
        try authority.update { state in
            var template = try XCTUnwrap(state.intents[initial.intentId])
            template.ordinaryProposal = nil
            state.intents[initial.intentId] = template
            for _ in 1..<512 {
                template.intentId = UUID().uuidString.lowercased()
                state.intents[template.intentId] = template
            }
        }
        let trustedGrant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "Trusted",
            origin: "https://example.local", transport: .http, authRef: "trusted-none",
            lan: true, allowInsecureHTTP: false,
            operations: [.init(name: "read", kind: .http, method: .GET,
                               path: "/api/read", idempotent: true, write: false)])
        let staged = try fixture.connections.hostConfigureGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: trustedGrant,
            auth: .init(authRef: "trusted-none", placement: .none), secret: nil)
        XCTAssertEqual(staged.state, "pending")
        let state = try authority.read()
        XCTAssertEqual(state.intents.count, 512)
        XCTAssertEqual(state.intents[staged.intentId]?.ordinaryProposal, false)
        XCTAssertEqual(fixture.provisioning.calls, 0)
    }

    func testDeploymentGrantMatcherRequiresVerifiedDeclarationsAndCurrentCredentialEpoch() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let html = Data("<html>connected</html>".utf8)
        let declaration = ManifestConnection(alias: "weather", required: true,
            operations: [.init(name: "read", kind: "http")])
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "dashboard-1", name: "Connected", revision: "revision-1",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "m3-device", width: 800, height: 480,
                scale: 1, orientation: "landscape"),
            connections: [declaration],
            files: [.init(path: "index.html", bytes: html.count,
                          sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: fixture.workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "weather",
            origin: "https://example.local", transport: .http, authRef: "m3-secret", lan: true,
            allowInsecureHTTP: false,
            operations: [.init(name: "read", kind: .http, method: .GET,
                               path: "/api/weather", idempotent: true, write: false)])
        let auth = ConnectionAuthBinding(authRef: "m3-secret", placement: .bearer)
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        try fixture.connections.installSecret(authRef: auth.authRef,
            secret: Data("fixture-secret".utf8), capability: capability)
        let pending = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: manifest.dashboardId, revision: manifest.revision,
            grant: grant, auth: auth)
        let applied = try XCTUnwrap(fixture.connections.resolveGenericIntent(pending.intentId,
            approve: true, capability: capability))
        let requirement = WorkbenchDeploymentGrantRequirement(dashboardId: manifest.dashboardId,
            revision: manifest.revision, sourceRevision: manifest.revision, manifest: manifest)
        let binding = applied.summary.bindingId
        let ready = try fixture.connections.deploymentGrants(deviceId: "m3-device",
            requirements: [requirement], bindingIds: [binding])
        XCTAssertTrue(ready.ready)
        XCTAssertEqual(ready.scopes.map(\.bindingId), [binding])
        var changed = manifest
        changed.connections = [.init(alias: "weather", required: true,
            operations: [.init(name: "expanded", kind: "http")])]
        changed.digest = try DeploymentDigest.digest(for: changed)
        let mismatch = try fixture.connections.deploymentGrants(deviceId: "m3-device",
            requirements: [.init(dashboardId: changed.dashboardId, revision: changed.revision,
                sourceRevision: manifest.revision, manifest: changed)], bindingIds: [binding])
        XCTAssertFalse(mismatch.ready)
        XCTAssertTrue(mismatch.missing.contains { $0.contains("source/prepared") })
        try fixture.connections.installSecret(authRef: auth.authRef,
            secret: Data("rotated-secret".utf8), capability: capability)
        XCTAssertThrowsError(try fixture.connections.deploymentGrants(deviceId: "m3-device",
            requirements: [requirement], bindingIds: [binding])) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .missingBinding)
        }
    }

    func testUnchangedGenericScopeCarriesToNewSelectedRevisionWithCorrelatedInventory() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let html = Data("<html>connected</html>".utf8)
        let declaration = ManifestConnection(alias: "weather", required: true,
            operations: [.init(name: "read", kind: "http")])
        func manifest(_ revision: String) throws -> DashboardManifest {
            var value = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
                dashboardId: "dashboard-1", name: "Connected", revision: revision,
                entrypoint: "index.html", sdkVersion: "1",
                target: .init(profileId: "m3-device", width: 800, height: 480,
                    scale: 1, orientation: "landscape"),
                connections: [declaration],
                files: [.init(path: "index.html", bytes: html.count,
                              sha256: DeploymentDigest.sha256Hex(html))])
            value.digest = try DeploymentDigest.digest(for: value)
            return value
        }
        let previous = try manifest("revision-1")
        let next = try manifest("revision-2")
        let packages = WorkbenchPortablePackages(workspace: fixture.workspace)
        _ = try packages.importVerified(.init(manifest: previous, files: ["index.html": html]))
        _ = try packages.importVerified(.init(manifest: next, files: ["index.html": html]))
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "weather",
            origin: "https://example.local", transport: .http, authRef: "m3-secret", lan: true,
            allowInsecureHTTP: false,
            operations: [.init(name: "read", kind: .http, method: .GET,
                               path: "/api/weather", idempotent: true, write: false)])
        let auth = ConnectionAuthBinding(authRef: "m3-secret", placement: .bearer)
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        try fixture.connections.installSecret(authRef: auth.authRef,
            secret: Data("fixture-secret".utf8), capability: capability)
        let pending = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: previous.dashboardId, revision: previous.revision,
            grant: grant, auth: auth)
        let applied = try XCTUnwrap(fixture.connections.resolveGenericIntent(pending.intentId,
            approve: true, capability: capability))
        let requirement = WorkbenchDeploymentGrantRequirement(dashboardId: next.dashboardId,
            revision: next.revision, sourceRevision: next.revision, manifest: next)
        let callsBefore = fixture.provisioning.calls
        try fixture.connections.installDeploymentGrants(deviceId: "m3-device", selected: requirement,
            bindingIds: [applied.summary.bindingId])
        XCTAssertEqual(fixture.provisioning.calls, callsBefore + 1)
        XCTAssertEqual(fixture.provisioning.last?.revision, next.revision)
    }

    func testLocalReviewBindsExactIntentContextAndConsumesProvisioningOnce() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let (grant, auth) = fixture.grant()
        try fixture.connections.installSecret(authRef: auth.authRef, secret: Data("canary-secret".utf8),
            capability: .hostTerminalOrGUI())
        let intent = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        let handle = Data(repeating: 7, count: 32).base64EncodedString()
        let review = try fixture.connections.makeLocalReview(intentId: intent.intentId, handle: handle)
        XCTAssertEqual(review.declarationHash, intent.declarationHash)
        XCTAssertEqual(review.authorizationContextHash, intent.authorizationContextHash)
        XCTAssertEqual(review.summary.operations.count, 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(review), as: UTF8.self).contains("canary-secret"))
        let applied = try fixture.connections.confirmLocalReview(review)
        XCTAssertEqual(applied.summary.bindingId, grant.id.uuidString.lowercased())
        XCTAssertEqual(fixture.provisioning.calls, 1)
        XCTAssertThrowsError(try fixture.connections.confirmLocalReview(review))
        XCTAssertEqual(fixture.provisioning.calls, 1)

        let secondGrant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "second",
            origin: "https://example.local", transport: .http, authRef: "second-ref", lan: true,
            allowInsecureHTTP: false, operations: [.init(name: "read", kind: .http, method: .GET,
                path: "/api/read", idempotent: true, write: false)])
        try fixture.connections.installSecret(authRef: "second-ref", secret: Data("second-secret".utf8),
            capability: .hostTerminalOrGUI())
        let next = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: secondGrant,
            auth: .init(authRef: "second-ref", placement: .bearer))
        let stale = try fixture.connections.makeLocalReview(intentId: next.intentId,
            handle: Data(repeating: 8, count: 32).base64EncodedString())
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("replacement-workspace").path)
        XCTAssertThrowsError(try fixture.connections.confirmLocalReview(stale))
        XCTAssertEqual(fixture.provisioning.calls, 1)
    }

    func testPendingPairingCodeCancelExpirySettingsAndMacOnlyForget() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        XCTAssertThrowsError(try fixture.devices.registerEndpoint(host: "bad/path", port: 80))
        XCTAssertEqual(try fixture.devices.registerEndpoint(host: fixture.device.host, port: Int(fixture.device.port)).source, .manual)
        let first = try fixture.devices.beginPairing(deviceId: fixture.device.runtime.profile.deviceId)
        XCTAssertEqual(first.matchingCode, fixture.device.runtime.pairingCode)
        XCTAssertThrowsError(try fixture.devices.confirmPairing(pendingId: first.pendingId, matchingCode: "wrong!")) {
            XCTAssertEqual($0 as? WorkbenchDeviceDomainError, .codeMismatch)
        }
        XCTAssertThrowsError(try fixture.devices.confirmPairing(pendingId: first.pendingId, matchingCode: first.matchingCode))
        let cancelled = try fixture.devices.beginPairing(deviceId: fixture.device.runtime.profile.deviceId)
        try fixture.devices.cancelPairing(pendingId: cancelled.pendingId)
        XCTAssertThrowsError(try fixture.devices.confirmPairing(pendingId: cancelled.pendingId, matchingCode: cancelled.matchingCode))
        let expired = try fixture.devices.beginPairing(deviceId: fixture.device.runtime.profile.deviceId)
        fixture.clock.date.addTimeInterval(PairingLimits.expirySeconds + 1)
        XCTAssertThrowsError(try fixture.devices.confirmPairing(pendingId: expired.pendingId, matchingCode: expired.matchingCode)) {
            XCTAssertEqual($0 as? WorkbenchDeviceDomainError, .expiredPairing)
        }
        let pending = try fixture.devices.beginPairing(deviceId: fixture.device.runtime.profile.deviceId)
        XCTAssertThrowsError(try fixture.devices.confirmPairing(pendingId: pending.pendingId, matchingCode: pending.matchingCode))
        fixture.device.confirmLocally()
        let paired = try fixture.devices.confirmPairing(pendingId: pending.pendingId, matchingCode: pending.matchingCode)
        XCTAssertEqual(paired.id, "m3-device")
        XCTAssertTrue(fixture.device.isPaired)
        let connects = fixture.device.connectAttempts
        fixture.device.runtime.activeRevision = "fresh-revision"
        XCTAssertNil(try fixture.devices.status(deviceId: paired.id).device.activeRevision)
        XCTAssertEqual(fixture.device.connectAttempts, connects, "cached status must not probe")
        XCTAssertEqual(try fixture.devices.status(deviceId: paired.id, refresh: true).device.activeRevision,
                       "fresh-revision")
        let settings = try fixture.devices.settingsGet(deviceId: paired.id)
        var changed = settings.value; changed.displayName = "Kitchen iPad Updated"
        XCTAssertThrowsError(try fixture.devices.settingsUpdate(deviceId: paired.id,
            expectedRevision: "stale", value: changed))
        XCTAssertEqual(try fixture.devices.settingsUpdate(deviceId: paired.id,
            expectedRevision: settings.revision, value: changed).value.displayName, "Kitchen iPad Updated")
        XCTAssertTrue(try fixture.devices.forget(deviceId: paired.id))
        XCTAssertTrue(fixture.device.isPaired, "Mac forget must never erase device state")
        XCTAssertTrue(fixture.devices.cachedDevices().isEmpty)
    }

    func testGenericIntentRequiresFreshLocalContextAndNeverLeaksSecret() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        try fixture.connections.installSecret(authRef: "m3-secret", secret: Data("secret-credential".utf8), capability: capability)
        let (grant, auth) = fixture.grant()
        let first = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        XCTAssertTrue(first.summary.operations[0].address.contains("view=hidden"))
        try fixture.connections.installSecret(authRef: "m3-secret", secret: Data("rotated-credential".utf8), capability: capability)
        XCTAssertThrowsError(try fixture.connections.resolveGenericIntent(first.intentId, approve: true, capability: capability)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .staleContext)
        }
        let denied = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        XCTAssertNil(try fixture.connections.resolveGenericIntent(denied.intentId, approve: false, capability: capability))
        XCTAssertEqual(fixture.provisioning.calls, 0)
        let locked = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        fixture.secrets.loadLocked = true
        XCTAssertThrowsError(try fixture.connections.resolveGenericIntent(locked.intentId, approve: true, capability: capability)) {
            XCTAssertEqual($0 as? ConnectionFailure, .permissionRequired)
        }
        XCTAssertEqual(fixture.provisioning.calls, 0)
        fixture.secrets.loadLocked = false
        let staleSelection = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        _ = try fixture.workspace.open(at: fixture.visible.path)
        XCTAssertThrowsError(try fixture.connections.resolveGenericIntent(staleSelection.intentId, approve: true, capability: capability))
        let fresh = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        let applied = try XCTUnwrap(fixture.connections.resolveGenericIntent(fresh.intentId, approve: true, capability: capability))
        XCTAssertEqual(applied.receipt.provisioningId, fresh.intentId)
        XCTAssertEqual(fixture.provisioning.calls, 1)
        XCTAssertEqual(fixture.provisioning.last?.entries[0].secret, Data("rotated-credential".utf8))
        XCTAssertNotEqual(applied.authorizationContextHash, fresh.authorizationContextHash)
        XCTAssertThrowsError(try fixture.connections.resolveGenericIntent(fresh.intentId, approve: true, capability: capability))
        let inspected = try fixture.connections.inspect(bindingId: applied.summary.bindingId)
        XCTAssertEqual(inspected.localStatus, "locally_authorized")
        XCTAssertEqual(try fixture.connections.test(bindingId: applied.summary.bindingId).localStatus,
                       "owner_channel_reachable_upstream_untested")
        let revoked = try fixture.connections.revoke(bindingId: applied.summary.bindingId, capability: capability)
        XCTAssertEqual(revoked.remoteRevocation, "best_effort_not_supported_for_generic_grants")
        XCTAssertThrowsError(try fixture.connections.authorizationContextHash(deviceId: "m3-device",
            bindingIds: [applied.summary.bindingId])) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .missingBinding)
        }
        let staleGrant = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        // Reinstalling an exact grant increments its local scope epoch.
        let replacement = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        _ = try fixture.connections.resolveGenericIntent(replacement.intentId, approve: true, capability: capability)
        XCTAssertThrowsError(try fixture.connections.resolveGenericIntent(staleGrant.intentId, approve: true, capability: capability)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .staleContext)
        }
        let ownerIntent = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        fixture.coordinator.attach(M3Factory(device: fixture.device,
            controllerIdentity: PairingIdentityFactory.make(role: .controller), state: fixture.provisioning))
        XCTAssertThrowsError(try fixture.connections.resolveGenericIntent(ownerIntent.intentId, approve: true, capability: capability))
        let stored = try Data(contentsOf: fixture.root.appendingPathComponent("authority/authority.json"))
        let rendered = try JSONEncoder().encode(applied)
        XCTAssertFalse(stored.range(of: Data("rotated-credential".utf8)) != nil)
        XCTAssertFalse(rendered.range(of: Data("rotated-credential".utf8)) != nil)
        XCTAssertTrue(rendered.range(of: Data("view=hidden".utf8)) != nil)
        XCTAssertEqual(fixture.connections.capabilities()["googleTV"], "dedicated_setup_unavailable_in_this_domain")
    }

    func testHostConfigurationStagesBeforeCredentialAndCleansDeniedAndExpiredIntents() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        var (grant, auth) = fixture.grant()
        grant.authRef = "host-slot-one"; auth.authRef = grant.authRef
        XCTAssertThrowsError(try fixture.connections.hostConfigureGenericIntent(deviceId: "missing-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant, auth: auth,
            secret: Data("not-installed".utf8)))
        XCTAssertTrue(fixture.secrets.values.isEmpty)

        let pending = try fixture.connections.hostConfigureGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant, auth: auth,
            secret: Data("first-secret".utf8))
        XCTAssertEqual(pending.state, "pending")
        XCTAssertEqual(fixture.secrets.values[grant.authRef], Data("first-secret".utf8))
        _ = try fixture.workspace.open(at: fixture.visible.path)
        XCTAssertNil(try fixture.connections.resolveGenericIntent(pending.intentId, approve: false,
            capability: .hostTerminalOrGUI()))
        XCTAssertNil(fixture.secrets.values[grant.authRef])

        var (expiringGrant, expiringAuth) = fixture.grant()
        expiringGrant.authRef = "host-slot-two"; expiringAuth.authRef = expiringGrant.authRef
        let expiring = try fixture.connections.hostConfigureGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: expiringGrant, auth: expiringAuth,
            secret: Data("second-secret".utf8))
        fixture.clock.date.addTimeInterval(601)
        try fixture.connections.reapExpiredManagedIntents()
        XCTAssertEqual(try fixture.connections.inspectIntent(expiring.intentId).state, "rejected")
        XCTAssertNil(fixture.secrets.values[expiringGrant.authRef])
        XCTAssertEqual(fixture.provisioning.calls, 0)
    }

    func testHostCredentialPartialWriteIsCompensatedOrDurablyRetryable() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        var (grant, auth) = fixture.grant()
        grant.authRef = "host-failure-slot"; auth.authRef = grant.authRef
        fixture.secrets.failAfterInstall = true
        fixture.secrets.removeLocked = true
        XCTAssertThrowsError(try fixture.connections.hostConfigureGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant, auth: auth,
            secret: Data("canary-secret".utf8))) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .credentialCleanupRequired)
        }
        XCTAssertEqual(fixture.secrets.values[grant.authRef], Data("canary-secret".utf8))
        let authority = try WorkbenchLocalAuthorityStore(path: fixture.root.appendingPathComponent("authority").path)
        let persisted = try XCTUnwrap(authority.read().intents.values.first(where: { $0.auth.authRef == grant.authRef }))
        XCTAssertEqual(persisted.state, .rejected)
        XCTAssertEqual(persisted.managedSecret, true)
        fixture.secrets.removeLocked = false
        fixture.secrets.failAfterInstall = false
        XCTAssertEqual(try fixture.connections.inspectIntent(persisted.intentId).state, "rejected")
        XCTAssertNil(fixture.secrets.values[grant.authRef])
        XCTAssertEqual(try authority.read().intents[persisted.intentId]?.managedSecret, false)
    }

    func testHostConfigurationCannotReplaceWorkingGrantBeforeIntent() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        let (grant, auth) = fixture.grant()
        try fixture.connections.installSecret(authRef: auth.authRef, secret: Data("working".utf8), capability: capability)
        let original = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant, auth: auth)
        _ = try fixture.connections.resolveGenericIntent(original.intentId, approve: true, capability: capability)
        var proposed = grant; proposed.authRef = "new-host-slot"
        let proposedAuth = ConnectionAuthBinding(authRef: proposed.authRef, placement: .bearer)
        XCTAssertThrowsError(try fixture.connections.hostConfigureGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: proposed, auth: proposedAuth,
            secret: Data("replacement".utf8))) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .invalidState)
        }
        XCTAssertEqual(try fixture.connections.inspect(bindingId: grant.id.uuidString.lowercased()).localStatus,
            "locally_authorized")
        XCTAssertEqual(fixture.secrets.values[auth.authRef], Data("working".utf8))
        XCTAssertNil(fixture.secrets.values[proposed.authRef])
    }

    func testReviewedScopeUpdateKeepsWorkingCredentialUntilDeviceReceipt() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        let (grant, auth) = fixture.grant()
        try fixture.connections.installSecret(authRef: auth.authRef,
            secret: Data("working".utf8), capability: capability)
        let original = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant, auth: auth)
        _ = try fixture.connections.resolveGenericIntent(original.intentId,
            approve: true, capability: capability)
        let id = grant.id.uuidString.lowercased()
        XCTAssertEqual(try fixture.connections.inspect(bindingId: id).grantGeneration, 1)
        var proposed = grant
        proposed.alias = "kitchen-reviewed"
        proposed.authRef = ""
        let proposedAuth = ConnectionAuthBinding(authRef: "", placement: .bearer)
        let pending = try fixture.connections.hostUpdateGenericIntent(bindingId: id,
            expectedGrantGeneration: 1, grant: proposed, auth: proposedAuth)
        XCTAssertEqual(try fixture.connections.inspect(bindingId: id).alias, "kitchen")
        XCTAssertEqual(fixture.secrets.values[auth.authRef], Data("working".utf8))
        XCTAssertEqual(fixture.provisioning.calls, 1)
        let applied = try XCTUnwrap(fixture.connections.resolveGenericIntent(pending.intentId,
            approve: true, capability: capability))
        XCTAssertEqual(applied.summary.alias, "kitchen-reviewed")
        XCTAssertEqual(applied.summary.grantGeneration, 2)
        XCTAssertEqual(fixture.provisioning.calls, 2)
        XCTAssertEqual(fixture.provisioning.last?.entries.first?.secret, Data("working".utf8))
        XCTAssertEqual(fixture.secrets.values[auth.authRef], Data("working".utf8))
        XCTAssertThrowsError(try fixture.connections.hostUpdateGenericIntent(bindingId: id,
            expectedGrantGeneration: 1, grant: proposed, auth: proposedAuth)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .staleContext)
        }
        proposed.origin = "https://other.example.local"
        XCTAssertThrowsError(try fixture.connections.hostUpdateGenericIntent(bindingId: id,
            expectedGrantGeneration: 2, grant: proposed, auth: proposedAuth)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .staleContext)
        }
        XCTAssertEqual(try fixture.connections.inspect(bindingId: id).grantGeneration, 2)
    }

    func testPublicSocketScopeUpdateRequiresReviewAndPreservesOldBinding() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        try fixture.retainScreenRevision()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        let (grant, auth) = fixture.grant()
        try fixture.connections.installSecret(authRef: auth.authRef,
            secret: Data("working".utf8), capability: capability)
        let original = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant, auth: auth)
        _ = try fixture.connections.resolveGenericIntent(original.intentId,
            approve: true, capability: capability)
        let controller = ControllerService(store: try DashboardPackageStore(
            root: fixture.root.appendingPathComponent("legacy")),
            devices: fixture.coordinator, rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:
            fixture.root.appendingPathComponent("runtime"))
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: fixture.workspace,
            native: nil, machineAuthorityPath: fixture.root.appendingPathComponent("authority").path,
            secrets: fixture.secrets, mutationGate: {},
            connectionNow: { fixture.clock.date })
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment,
            credentialScope: .localReview)
        try client.connect(); defer { client.close() }
        let ordinary = WorkbenchBrokerClient(environment: environment)
        try ordinary.connect(); defer { ordinary.close() }
        let id = grant.id.uuidString.lowercased()
        let selection = try XCTUnwrap(fixture.workspace.selection.current())
        XCTAssertThrowsError(try ordinary.connectionScopeDraft(bindingId: id,
            workspaceId: selection.workspaceId,
            selectionGeneration: selection.selectionGeneration)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        _ = try ordinary.reconnectIfPeerClosed()
        XCTAssertThrowsError(try client.connectionScopeDraft(bindingId: id,
            workspaceId: selection.workspaceId,
            selectionGeneration: selection.selectionGeneration + 1)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        _ = try client.reconnectIfPeerClosed()
        let draft = try client.connectionScopeDraft(bindingId: id,
            workspaceId: selection.workspaceId,
            selectionGeneration: selection.selectionGeneration)
        XCTAssertEqual(draft.bindingId, id)
        XCTAssertEqual(draft.deviceId, "m3-device")
        XCTAssertEqual(draft.dashboardId, "dashboard-1")
        XCTAssertEqual(draft.revision, "revision-1")
        XCTAssertEqual(draft.expectedGrantGeneration, 1)
        XCTAssertEqual(draft.grant.operations, grant.operations)
        XCTAssertEqual(draft.auth.placement, .bearer)
        XCTAssertEqual(draft.grant.authRef, "")
        XCTAssertEqual(draft.auth.authRef, "")
        let encodedDraft = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        XCTAssertFalse(encodedDraft.contains("m3-secret"))
        XCTAssertFalse(encodedDraft.contains("working"))
        var proposed = grant
        proposed.alias = "kitchen-reviewed"
        proposed.authRef = ""
        let proposedAuth = ConnectionAuthBinding(authRef: "", placement: .bearer)
        XCTAssertThrowsError(try ordinary.updateConnection(bindingId: id,
            expectedGrantGeneration: 2, grant: proposed, auth: proposedAuth)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        _ = try ordinary.reconnectIfPeerClosed()
        let pending = try ordinary.updateConnection(bindingId: id,
            expectedGrantGeneration: 1, grant: proposed, auth: proposedAuth)
        XCTAssertThrowsError(try ordinary.beginConnectionReview(intentId: pending.intentId)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        _ = try ordinary.reconnectIfPeerClosed()
        XCTAssertThrowsError(try ordinary.resolveConnectionIntent(pending.intentId,
            approve: true)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        XCTAssertEqual(try client.inspectConnection(id).alias, "kitchen")
        XCTAssertEqual(fixture.secrets.values[auth.authRef], Data("working".utf8))
        XCTAssertEqual(fixture.provisioning.calls, 1)
        let review = try client.beginConnectionReview(intentId: pending.intentId)
        let applied = try client.confirmConnectionReview(review)
        XCTAssertEqual(applied.summary.alias, "kitchen-reviewed")
        XCTAssertEqual(applied.summary.grantGeneration, 2)
        XCTAssertEqual(fixture.provisioning.last?.entries.first?.secret, Data("working".utf8))
        XCTAssertEqual(fixture.secrets.values[auth.authRef], Data("working".utf8))
        XCTAssertEqual(try client.inspectConnection(id).grantGeneration, 2)
        XCTAssertThrowsError(try client.connectionScopeDraft(bindingId: id,
            workspaceId: selection.workspaceId,
            selectionGeneration: selection.selectionGeneration + 1)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
    }

    func testScopeDraftRefusesCredentialBearingPathAndRevokedGrant() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        try fixture.retainScreenRevision()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        var (grant, auth) = fixture.grant()
        grant.operations[0].path = "/api/lights?api_key=opaque"
        try fixture.connections.installSecret(authRef: auth.authRef,
            secret: Data("working".utf8), capability: capability)
        let original = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant, auth: auth)
        _ = try fixture.connections.resolveGenericIntent(original.intentId,
            approve: true, capability: capability)
        let selection = try XCTUnwrap(fixture.workspace.selection.current())
        let id = grant.id.uuidString.lowercased()
        XCTAssertThrowsError(try fixture.connections.scopeDraft(bindingId: id,
            workspaceId: selection.workspaceId,
            selectionGeneration: selection.selectionGeneration)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .staleContext)
        }
        _ = try fixture.connections.revoke(bindingId: id, capability: capability)
        XCTAssertThrowsError(try fixture.connections.scopeDraft(bindingId: id,
            workspaceId: selection.workspaceId,
            selectionGeneration: selection.selectionGeneration)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .staleContext)
        }
    }

    func testScopeDraftRefusesBindingWithoutSelectedWorkspacePackage() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        let (grant, auth) = fixture.grant()
        try fixture.connections.installSecret(authRef: auth.authRef,
            secret: Data("working".utf8), capability: capability)
        let pending = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant, auth: auth)
        _ = try fixture.connections.resolveGenericIntent(pending.intentId,
            approve: true, capability: capability)
        let selected = try XCTUnwrap(fixture.workspace.selection.current())
        XCTAssertThrowsError(try fixture.connections.scopeDraft(
            bindingId: grant.id.uuidString.lowercased(), workspaceId: selected.workspaceId,
            selectionGeneration: selected.selectionGeneration)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .staleContext)
        }
        try fixture.retainScreenRevision(dashboardId: "other-dashboard")
        XCTAssertThrowsError(try fixture.connections.scopeDraft(
            bindingId: grant.id.uuidString.lowercased(), workspaceId: selected.workspaceId,
            selectionGeneration: selected.selectionGeneration)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .staleContext)
        }
    }

    func testOrdinaryScopeUpdateHonorsReservedIntentCapacity() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        let (grant, auth) = fixture.grant()
        try fixture.connections.installSecret(authRef: auth.authRef,
            secret: Data("working".utf8), capability: capability)
        let original = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant, auth: auth)
        _ = try fixture.connections.resolveGenericIntent(original.intentId,
            approve: true, capability: capability)
        var firstPending: String?
        for index in 0..<384 {
            var proposal = fixture.grant().0
            proposal.authRef = "none-ref"
            let pending = try fixture.connections.requestGenericIntent(deviceId: "m3-device",
                dashboardId: "dashboard-1", revision: "revision-1", grant: proposal,
                auth: .init(authRef: "none-ref", placement: .none))
            if index == 0 { firstPending = pending.intentId }
        }
        var proposed = grant
        proposed.alias = "capacity-update"
        proposed.authRef = ""
        XCTAssertThrowsError(try fixture.connections.hostUpdateGenericIntent(
            bindingId: grant.id.uuidString.lowercased(), expectedGrantGeneration: 1,
            grant: proposed, auth: .init(authRef: "", placement: .bearer),
            ordinaryProposal: true)) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .intentCapacity)
        }
        XCTAssertEqual(try fixture.connections.inspectIntent(try XCTUnwrap(firstPending)).state,
            "pending")
        XCTAssertEqual(try fixture.connections.inspect(
            bindingId: grant.id.uuidString.lowercased()).alias, "kitchen")
        let controller = ControllerService(store: try DashboardPackageStore(
            root: fixture.root.appendingPathComponent("legacy")),
            devices: fixture.coordinator, rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:
            fixture.root.appendingPathComponent("runtime"))
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: fixture.workspace,
            native: nil, machineAuthorityPath: fixture.root.appendingPathComponent("authority").path,
            secrets: fixture.secrets, mutationGate: {},
            connectionNow: { fixture.clock.date })
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }
        let ordinary = WorkbenchBrokerClient(environment: environment)
        try ordinary.connect(); defer { ordinary.close() }
        XCTAssertThrowsError(try ordinary.updateConnection(
            bindingId: grant.id.uuidString.lowercased(), expectedGrantGeneration: 1,
            grant: proposed, auth: .init(authRef: "", placement: .bearer))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .resourceLimit)
        }
        XCTAssertEqual(try fixture.connections.inspectIntent(try XCTUnwrap(firstPending)).state,
            "pending")
    }

    func testPublicOperationInventoryReadsAndCancelsDurableDeploymentWithoutDeviceOwner() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let clock = WorkbenchDeploymentClock(wallSeconds: 2_000_000_000,
            monotonicMilliseconds: 100_000, bootId: "operation-test")
        let ledger = try WorkbenchDeploymentLedger(path:
            fixture.root.appendingPathComponent("deployment-ledger.sqlite").path)
        let hash = String(repeating: "a", count: 64)
        let context = String(repeating: "b", count: 64)
        let workspaceId = try XCTUnwrap(fixture.workspace.current()?.descriptor.workspaceId)
        let plan = WorkbenchDeploymentPlanRecord(planId: UUID().uuidString.lowercased(),
            planHash: hash, workspaceId: workspaceId, deviceId: "m3-device",
            authorizationContextHash: context, immutableBodyHash: hash,
            materialJSON: Data("{}".utf8), reviewJSON: Data("{}".utf8),
            expiresWallSeconds: clock.wallSeconds + 1000,
            deadlineMonotonicMilliseconds: clock.monotonicMilliseconds + 1_000_000,
            bootId: clock.bootId)
        try ledger.createPlan(plan, clock: clock)
        let approval = WorkbenchDeploymentApprovalRecord(
            approvalId: UUID().uuidString.lowercased(), planId: plan.planId,
            planHash: hash, authorizationContextHash: context,
            consentSource: "terminal_interactive",
            expiresWallSeconds: plan.expiresWallSeconds,
            deadlineMonotonicMilliseconds: plan.deadlineMonotonicMilliseconds,
            bootId: clock.bootId)
        try ledger.approve(approval, clock: clock, validateCurrent: {})
        let admitted = try ledger.admit(planId: plan.planId, planHash: hash,
            contextHash: context, approvalId: approval.approvalId,
            idempotencyKey: "operation-test", approved: true,
            clock: clock, validateCurrent: {})
        let controller = ControllerService(store: try DashboardPackageStore(
            root: fixture.root.appendingPathComponent("legacy")),
            devices: fixture.coordinator, rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:
            fixture.root.appendingPathComponent("runtime"))
        let domain = WorkbenchBrokerDomain(controller: controller,
            workspace: fixture.workspace, native: nil,
            machineAuthorityPath: fixture.root.appendingPathComponent("authority").path)
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect(); defer { client.close() }
        let inventory = try client.operationInventory()
        XCTAssertEqual(inventory.entries.map(\.operationId), [admitted.operationId])
        XCTAssertEqual(inventory.entries.first?.durability, "durable-local-ledger")
        let selection = try XCTUnwrap(fixture.workspace.current()?.selectionGeneration)
        let retained = try client.retainedDeploymentEvidence(workspaceId: workspaceId,
            selectionGeneration: selection, deviceId: "m3-device")
        XCTAssertTrue(retained.complete)
        XCTAssertTrue(retained.packages.isEmpty,
            "An admitted operation cannot be rollback provenance")
        XCTAssertEqual(try client.operationEntry(operationId: admitted.operationId).state, "admitted")
        let cancelled = try client.operationEntry(operationId: admitted.operationId,
            requestCancel: true)
        XCTAssertEqual(cancelled.state, "cancelled")
        XCTAssertTrue(cancelled.cancellationRequested)
        XCTAssertEqual(try ledger.status(admitted.operationId).state, .cancelled)

        let secondPlanId = UUID().uuidString.lowercased()
        let package = WorkbenchDeploymentPackage(dashboardId: "screen-a",
            sourceRevision: "source-a", revision: "prepared-a",
            digest: String(repeating: "c", count: 64), declaredCapabilities: [],
            dataDescription: "fixture")
        let body = WorkbenchDeploymentPlanBody(planVersion: 1, planId: secondPlanId,
            workspaceId: workspaceId, deviceId: "m3-device",
            deviceProfileHash: String(repeating: "d", count: 64),
            expectedInstalledSetHash: String(repeating: "e", count: 64),
            packages: [package], selectedDashboardId: "screen-a",
            removedDashboardIds: [], requiredDeclarationsHash: String(repeating: "f", count: 64),
            approvalPolicy: "exact-package-installation-v1",
            expiresAt: "2033-05-18T03:50:00Z")
        let secondHash = try WorkbenchDeploymentHash.plan(body)
        let review = WorkbenchDeploymentReview(plan: body, planHash: secondHash,
            authorizationContextHash: context, deviceName: "Fixture", observedAt: Date(),
            previouslyInstalled: [], previouslySelectedDashboardId: nil,
            result: [.init(dashboardId: "screen-a", revision: "prepared-a", name: "Fixture")],
            packageBytes: 1, note: "fixture", nativeRenderVerification: "not_performed")
        let secondPlan = WorkbenchDeploymentPlanRecord(planId: secondPlanId,
            planHash: secondHash, workspaceId: workspaceId, deviceId: "m3-device",
            authorizationContextHash: context, immutableBodyHash: hash,
            materialJSON: Data("{}".utf8), reviewJSON: try JSONEncoder().encode(review),
            expiresWallSeconds: clock.wallSeconds + 1000,
            deadlineMonotonicMilliseconds: clock.monotonicMilliseconds + 1_000_000,
            bootId: clock.bootId)
        try ledger.createPlan(secondPlan, clock: clock)
        let secondApproval = WorkbenchDeploymentApprovalRecord(
            approvalId: UUID().uuidString.lowercased(), planId: secondPlanId,
            planHash: secondHash, authorizationContextHash: context,
            consentSource: "terminal_interactive",
            expiresWallSeconds: secondPlan.expiresWallSeconds,
            deadlineMonotonicMilliseconds: secondPlan.deadlineMonotonicMilliseconds,
            bootId: clock.bootId)
        try ledger.approve(secondApproval, clock: clock, validateCurrent: {})
        let second = try ledger.admit(planId: secondPlanId, planHash: secondHash,
            contextHash: context, approvalId: secondApproval.approvalId,
            idempotencyKey: "active-operation-test", approved: true,
            clock: clock, validateCurrent: {})
        _ = try ledger.markSending(operationId: second.operationId,
            clock: clock, validateCurrent: {})
        _ = try ledger.updateOutcome(operationId: second.operationId,
            state: .received, receiptJSON: Data("{}".utf8))
        _ = try ledger.updateOutcome(operationId: second.operationId, state: .active)
        let activeEvidence = try client.retainedDeploymentEvidence(workspaceId: workspaceId,
            selectionGeneration: selection, deviceId: "m3-device")
        XCTAssertEqual(activeEvidence.packages.count, 1)
        XCTAssertEqual(activeEvidence.packages.first?.planId, secondPlanId)
        XCTAssertEqual(activeEvidence.packages.first?.sourceRevision, "source-a")
        XCTAssertEqual(activeEvidence.packages.first?.preparedRevision, "prepared-a")
    }

    func testRejectedSecondBrokerCannotReconcileLiveCopyJournal() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let controller = ControllerService(store: try DashboardPackageStore(
            root: fixture.root.appendingPathComponent("legacy")),
            devices: fixture.coordinator, rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:
            fixture.root.appendingPathComponent("runtime"))
        let domain = WorkbenchBrokerDomain(controller: controller,
            workspace: fixture.workspace, native: nil,
            machineAuthorityPath: fixture.root.appendingPathComponent("authority").path)
        let journal = try WorkbenchWorkspaceOperationJournal(path:
            fixture.root.appendingPathComponent("workspace-operation-journal.sqlite").path)
        let first = WorkbenchBrokerServer(environment: environment, domain: domain)
        try first.start(); defer { first.stop() }
        let running = WorkbenchWorkspaceOperationStatus(
            operationId: UUID().uuidString.lowercased(),
            instanceId: UUID().uuidString.lowercased(),
            method: WorkbenchAuthoringRecoveryMethod.snapshotCreate.rawValue,
            destination: fixture.root.appendingPathComponent("snapshot").path)
        try journal.reserve(running)
        let second = WorkbenchBrokerServer(environment: environment, domain: domain)
        XCTAssertThrowsError(try second.start()) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .alreadyRunning)
        }
        XCTAssertEqual(try journal.get(running.operationId)?.state, "running")
    }

    func testAmbiguousProvisioningIsNotReplayedOrLocallyAuthorized() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        try fixture.connections.installSecret(authRef: "m3-secret", secret: Data("secret".utf8), capability: capability)
        let (grant, auth) = fixture.grant()
        let intent = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        fixture.provisioning.failure = .interrupted
        XCTAssertThrowsError(try fixture.connections.resolveGenericIntent(intent.intentId, approve: true,
            capability: capability)) { XCTAssertEqual($0 as? WorkbenchAuthorityError, .remoteOutcomeUnknown) }
        XCTAssertEqual(fixture.provisioning.calls, 1, "a cached owner link must not replay an uncertain send")
        XCTAssertEqual(try fixture.connections.inspectIntent(intent.intentId).state, "uncertain")
        XCTAssertThrowsError(try fixture.connections.resolveGenericIntent(intent.intentId, approve: true,
            capability: capability)) { XCTAssertEqual($0 as? WorkbenchAuthorityError, .intentResolved) }
        XCTAssertThrowsError(try fixture.connections.inspect(bindingId: grant.id.uuidString.lowercased())) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .missingBinding)
        }
        fixture.provisioning.failure = .unsupported
        let unsupported = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        XCTAssertThrowsError(try fixture.connections.resolveGenericIntent(unsupported.intentId, approve: true,
            capability: capability)) { XCTAssertEqual(($0 as? ControllerError)?.code, .unsupportedVersion) }
        XCTAssertEqual(fixture.provisioning.calls, 2)
        XCTAssertEqual(try fixture.connections.inspectIntent(unsupported.intentId).state, "rejected")
    }

    func testMachineLocalAuthorityPersistsButSecretStoreRemainsSeparate() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        try fixture.connections.installSecret(authRef: "m3-secret", secret: Data("persist-secret".utf8), capability: capability)
        let (grant, auth) = fixture.grant()
        let intent = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        let applied = try XCTUnwrap(fixture.connections.resolveGenericIntent(intent.intentId, approve: true,
            capability: capability))
        let reopened = try WorkbenchConnectionDomain(machineAuthorityPath: fixture.root.appendingPathComponent("authority").path,
            devices: fixture.coordinator, workspace: fixture.workspace, secrets: fixture.secrets,
            now: { [clock = fixture.clock] in clock.date })
        XCTAssertEqual(try reopened.inspect(bindingId: applied.summary.bindingId).localStatus, "locally_authorized")
        XCTAssertEqual(try reopened.authorizationContextHash(deviceId: "m3-device",
            bindingIds: [applied.summary.bindingId]), applied.authorizationContextHash)
        let bytes = try Data(contentsOf: fixture.root.appendingPathComponent("authority/authority.json"))
        XCTAssertNil(bytes.range(of: Data("persist-secret".utf8)))
        try reopened.installSecret(authRef: "m3-secret", secret: Data("new-secret".utf8), capability: capability)
        XCTAssertEqual(try reopened.inspect(bindingId: applied.summary.bindingId).localStatus, "locally_revoked")
        XCTAssertThrowsError(try reopened.authorizationContextHash(deviceId: "m3-device",
            bindingIds: [applied.summary.bindingId])) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .missingBinding)
        }
    }

    func testRePairingSamePeerRetiresPriorGrantBeforeConfirmation() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        try fixture.connections.installSecret(authRef: "m3-secret", secret: Data("secret".utf8), capability: capability)
        let (grant, auth) = fixture.grant()
        let intent = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        let applied = try XCTUnwrap(fixture.connections.resolveGenericIntent(intent.intentId, approve: true,
            capability: capability))
        let pending = try fixture.devices.beginPairing(deviceId: "m3-device")
        fixture.device.confirmLocally()
        _ = try fixture.devices.confirmPairing(pendingId: pending.pendingId, matchingCode: pending.matchingCode)
        XCTAssertThrowsError(try fixture.connections.authorizationContextHash(deviceId: "m3-device",
            bindingIds: [applied.summary.bindingId])) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .missingBinding)
        }
    }

    func testStalePendingIDCannotConfirmOrCancelReplacementNativeSession() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let stale = try fixture.devices.beginPairing(deviceId: "m3-device")
        let replacement = try fixture.coordinator.requestPairing(deviceId: "m3-device", host: nil, port: nil)
        XCTAssertFalse(fixture.devices.pendingPairings().contains(where: { $0.pendingId == stale.pendingId }))
        fixture.device.confirmLocally()
        XCTAssertThrowsError(try fixture.devices.confirmPairing(pendingId: stale.pendingId,
            matchingCode: stale.matchingCode)) {
            XCTAssertEqual($0 as? WorkbenchDeviceDomainError, .stalePairing)
        }
        try fixture.devices.cancelPairing(pendingId: stale.pendingId)
        XCTAssertEqual(fixture.coordinator.pendingPairings().first?.sessionID, replacement.sessionID)
        XCTAssertEqual(try fixture.coordinator.confirmPairing(deviceId: "m3-device").id, "m3-device")
    }

    func testForgetRetiresGrantsBeforeNativeDeletionAndFailedAuthorityWriteKeepsPairing() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.pair()
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        try fixture.connections.installSecret(authRef: "m3-secret", secret: Data("secret".utf8), capability: capability)
        let (grant, auth) = fixture.grant()
        let intent = try fixture.connections.requestGenericIntent(deviceId: "m3-device", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        let applied = try XCTUnwrap(fixture.connections.resolveGenericIntent(intent.intentId, approve: true,
            capability: capability))
        let authorityFile = fixture.root.appendingPathComponent("authority/authority.json")
        let backup = try Data(contentsOf: authorityFile)
        try FileManager.default.removeItem(at: authorityFile)
        try FileManager.default.createDirectory(at: authorityFile, withIntermediateDirectories: false)
        XCTAssertThrowsError(try fixture.devices.forget(deviceId: "m3-device"))
        XCTAssertEqual(fixture.devices.cachedDevices().count, 1)
        try FileManager.default.removeItem(at: authorityFile)
        try backup.write(to: authorityFile)
        XCTAssertTrue(try fixture.devices.forget(deviceId: "m3-device"))
        XCTAssertTrue(fixture.devices.cachedDevices().isEmpty)
        let native = try fixture.coordinator.requestPairing(deviceId: "m3-device", host: nil, port: nil)
        fixture.device.confirmLocally()
        _ = try fixture.coordinator.confirmPairing(deviceId: native.deviceId)
        let reopened = try WorkbenchConnectionDomain(machineAuthorityPath: fixture.root.appendingPathComponent("authority").path,
            devices: fixture.coordinator, workspace: fixture.workspace, secrets: fixture.secrets,
            now: { [clock = fixture.clock] in clock.date })
        XCTAssertThrowsError(try reopened.authorizationContextHash(deviceId: "m3-device",
            bindingIds: [applied.summary.bindingId])) {
            XCTAssertEqual($0 as? WorkbenchAuthorityError, .missingBinding)
        }
    }
}
#endif
