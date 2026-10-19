#if os(macOS)
import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

private final class ReviewProvisioning: @unchecked Sendable {
    var calls = 0
}
private final class ReviewClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 2_000_000_000)
}
private final class ReviewLink: DeviceLink {
    let inner: FakeLANLink
    let provisioning: ReviewProvisioning
    init(device: FakeLANDevice, owner: PairingIdentity, provisioning: ReviewProvisioning) {
        inner = FakeLANLink(device: device, controllerPin: owner.publicKey)
        self.provisioning = provisioning
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
    func updateSettings(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot {
        try inner.updateSettings(update)
    }
    func provisionConnections(_ configuration: ConnectionProvisioning) throws -> ConnectionProvisioningReceipt {
        try configuration.validate()
        provisioning.calls += 1
        return .init(deviceId: inner.device.runtime.profile.deviceId,
                     dashboardId: configuration.dashboardId, revision: configuration.revision,
                     provisioningId: configuration.provisioningId)
    }
    func cancel() { inner.cancel() }
}
private struct ReviewFactory: DeviceLinkFactory {
    let device: FakeLANDevice
    let controllerIdentity: PairingIdentity
    let provisioning: ReviewProvisioning
    func makeLink() throws -> DeviceLink {
        ReviewLink(device: device, owner: controllerIdentity, provisioning: provisioning)
    }
}
private struct ReviewDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

final class WorkbenchLocalReviewBrokerTests: XCTestCase {
    func testScopedSessionCrossSessionReplayAndStaleContext() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-local-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"),
                                                withIntermediateDirectories: false)
        let device = FakeLANDevice(deviceId: "review-device", name: "Fixture iPad")
        let hub = LoopbackDiscovery(); hub.advertise(device.runtime.advertisement)
        let owner = PairingIdentityFactory.make(role: .controller)
        let provisioning = ReviewProvisioning()
        let clock = ReviewClock()
        let workspace = try WorkspaceStore(documents: ReviewDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("home"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"), hub: hub,
            rendererFactory: { nil })
        let paired = PairedDevice(profile: device.runtime.profile, owner: owner, reachable: false)
        try controller.devices.directory.upsert(PairedDeviceRecord(device: paired,
            host: device.host, port: Int(device.port), devicePinHex: PeerPin.hex(device.identityPin),
            pairedAt: Date()))
        let factory = ReviewFactory(device: device, controllerIdentity: owner,
            provisioning: provisioning)
        let native = WorkbenchNativeComposition(activateOnStart: false,
            activate: { $0.devices.attach(factory) }, deactivate: { controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native, machineAuthorityPath: root.appendingPathComponent("machine/authority").path,
            mutationGate: {}, connectionNow: { clock.date })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"),
            limits: .init(timeout: 1))
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }
        let ordinary = WorkbenchBrokerClient(environment: environment)
        try ordinary.connect(); defer { ordinary.close() }
        let local = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview)
        try local.connect(); defer { local.close() }
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "Kitchen",
            origin: "https://example.local", transport: .http, authRef: "", lan: true,
            allowInsecureHTTP: false, operations: [.init(name: "lights", kind: .http,
                method: .GET, path: "/api/lights?view=hidden", idempotent: true, write: false)])
        XCTAssertThrowsError(try ordinary.configureConnection(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant,
            auth: .init(authRef: "", placement: .none), secret: nil)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        try ordinary.connect()
        var requestedGrant = grant; requestedGrant.id = UUID(); requestedGrant.alias = "ordinary-proposal"
        let requested = try ordinary.requestConnectionIntent(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: requestedGrant,
            auth: .init(authRef: "", placement: .none))
        XCTAssertEqual(requested.state, "pending")
        XCTAssertNotNil(requested.proposalScopeHash)
        XCTAssertTrue(WorkbenchConnectionIntentAttestation.matchesRequest(requested,
            deviceId: "review-device", dashboardId: "dashboard-1", revision: "revision-1",
            grant: requestedGrant, auth: .init(authRef: "", placement: .none)))
        var alteredGrant = requestedGrant
        alteredGrant.operations[0].idempotent = false
        XCTAssertFalse(WorkbenchConnectionIntentAttestation.matchesRequest(requested,
            deviceId: "review-device", dashboardId: "dashboard-1", revision: "revision-1",
            grant: alteredGrant, auth: .init(authRef: "", placement: .none)))
        alteredGrant = requestedGrant
        alteredGrant.operations[0].maxAgeSeconds = 30
        XCTAssertFalse(WorkbenchConnectionIntentAttestation.matchesRequest(requested,
            deviceId: "review-device", dashboardId: "dashboard-1", revision: "revision-1",
            grant: alteredGrant, auth: .init(authRef: "", placement: .none)))
        alteredGrant = requestedGrant
        alteredGrant.origin = "https://other.local"
        XCTAssertFalse(WorkbenchConnectionIntentAttestation.matchesRequest(requested,
            deviceId: "review-device", dashboardId: "dashboard-1", revision: "revision-1",
            grant: alteredGrant, auth: .init(authRef: "", placement: .none)))
        alteredGrant = requestedGrant
        alteredGrant.operations[0].path = "/api/other"
        XCTAssertFalse(WorkbenchConnectionIntentAttestation.matchesRequest(requested,
            deviceId: "review-device", dashboardId: "dashboard-1", revision: "revision-1",
            grant: alteredGrant, auth: .init(authRef: "", placement: .none)))
        XCTAssertFalse(WorkbenchConnectionIntentAttestation.matchesRequest(requested,
            deviceId: "review-device", dashboardId: "dashboard-1", revision: "revision-2",
            grant: requestedGrant, auth: .init(authRef: "", placement: .none)))
        XCTAssertEqual(try ordinary.connectionIntent(requested.intentId), requested)
        XCTAssertEqual(provisioning.calls, 0, "ordinary proposal must not provision")
        XCTAssertThrowsError(try ordinary.requestConnectionIntent(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: requestedGrant,
            auth: .init(authRef: "", placement: .bearer))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .invalidRequest)
        }
        try ordinary.connect()
        XCTAssertThrowsError(try ordinary.beginConnectionReview(intentId: requested.intentId)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        try ordinary.connect()
        let intent = try local.configureConnection(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: grant,
            auth: .init(authRef: "", placement: .none), secret: nil)
        for _ in 0..<383 {
            requestedGrant.id = UUID()
            _ = try ordinary.requestConnectionIntent(deviceId: "review-device",
                dashboardId: "dashboard-1", revision: "revision-1", grant: requestedGrant,
                auth: .init(authRef: "", placement: .none))
        }
        requestedGrant.id = UUID()
        XCTAssertThrowsError(try ordinary.requestConnectionIntent(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: requestedGrant,
            auth: .init(authRef: "", placement: .none))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .resourceLimit)
        }
        let authority = try WorkbenchLocalAuthorityStore(path: root.appendingPathComponent("machine/authority").path)
        XCTAssertEqual(try authority.read().intents.values.filter { $0.ordinaryProposal == true }.count, 384)
        try ordinary.connect()
        local.close()
        try local.connect()
        var broad = grant; broad.id = UUID()
        broad.operations = [.init(name: "lights", kind: .http, method: .GET,
            path: "/api/lights?target=all&api_key=secret-query-value", idempotent: true, write: false)]
        let broadIntent = try local.configureConnection(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: broad,
            auth: .init(authRef: "", placement: .none), secret: nil)
        let broadReview = try local.beginConnectionReview(intentId: broadIntent.intentId)
        XCTAssertTrue(broadReview.summary.operations[0].address.contains("target=all"))
        XCTAssertFalse(broadReview.summary.operations[0].address.contains("secret-query-value"))
        XCTAssertTrue(broadReview.summary.operations[0].address.contains("api_key=REDACTED"))
        var unknown = grant; unknown.id = UUID()
        unknown.operations = [.init(name: "lights", kind: .http, method: .GET,
            path: "/api/lights?ambiguous=all", idempotent: true, write: false)]
        let invalidLocal = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview)
        try invalidLocal.connect(); defer { invalidLocal.close() }
        XCTAssertThrowsError(try invalidLocal.configureConnection(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: unknown,
            auth: .init(authRef: "", placement: .none), secret: nil))
        let ordinaryReview = WorkbenchBrokerClient(environment: environment)
        try ordinaryReview.connect(); defer { ordinaryReview.close() }
        XCTAssertThrowsError(try ordinaryReview.beginConnectionReview(intentId: intent.intentId)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        let oldLocal = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview)
        try oldLocal.connect(); defer { oldLocal.close() }
        XCTAssertThrowsError(try oldLocal.resolveConnectionIntent(intent.intentId, approve: true)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .confirmationRequired)
        }
        let review = try local.beginConnectionReview(intentId: intent.intentId)
        XCTAssertEqual(review.declarationHash, intent.declarationHash)
        XCTAssertEqual(review.summary.operations.count, 1)
        XCTAssertTrue(review.summary.operations[0].address.contains("view=hidden"))
        XCTAssertTrue(review.summary.origin.hasPrefix("lan:"))
        let otherLocal = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview)
        try otherLocal.connect(); defer { otherLocal.close() }
        XCTAssertThrowsError(try otherLocal.confirmConnectionReview(review)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .confirmationRequired)
        }
        let expiredTicket = WorkbenchLocalReviewTicket(review: review,
            deadlineUptime: ProcessInfo.processInfo.systemUptime - 1)
        XCTAssertThrowsError(try domain.confirmConnectionReview(expiredTicket)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .confirmationRequired)
        }
        // The socket idle timeout is one second, but a valid local review
        // may wait until its bounded five-minute ticket deadline.
        Thread.sleep(forTimeInterval: 1.4)
        let applied = try local.confirmConnectionReview(review)
        XCTAssertEqual(applied.summary.bindingId, grant.id.uuidString.lowercased())
        XCTAssertEqual(provisioning.calls, 1)
        XCTAssertThrowsError(try local.confirmConnectionReview(review)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .confirmationRequired)
        }
        XCTAssertEqual(provisioning.calls, 1)

        var second = grant; second.id = UUID(); second.alias = "second"
        let laterLocal = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview)
        try laterLocal.connect(); defer { laterLocal.close() }
        let next = try laterLocal.configureConnection(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: second,
            auth: .init(authRef: "", placement: .none), secret: nil)
        let stale = try laterLocal.beginConnectionReview(intentId: next.intentId)
        _ = try laterLocal.initializeWorkspace(path: root.appendingPathComponent("replacement").path)
        XCTAssertThrowsError(try laterLocal.confirmConnectionReview(stale)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .confirmationRequired)
        }
        XCTAssertEqual(provisioning.calls, 1)
        clock.date.addTimeInterval(601)
        ordinary.close()
        try ordinary.connect()
        requestedGrant.id = UUID()
        let afterExpiry = try ordinary.requestConnectionIntent(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: requestedGrant,
            auth: .init(authRef: "", placement: .none))
        XCTAssertEqual(afterExpiry.state, "pending")
        XCTAssertLessThan(try authority.read().intents.count, 10)
        var largeGrant = requestedGrant
        largeGrant.alias = "large"
        largeGrant.operations = (0..<32).map { index in
            .init(name: "read\(index)", kind: .http, method: .GET,
                  path: "/api/" + String(repeating: "x", count: 3_800),
                  idempotent: true, write: false)
        }
        var largeAccepted = 0
        for _ in 0..<40 {
            largeGrant.id = UUID()
            do {
                _ = try ordinary.requestConnectionIntent(deviceId: "review-device",
                    dashboardId: "dashboard-1", revision: "revision-1", grant: largeGrant,
                    auth: .init(authRef: "", placement: .none))
                largeAccepted += 1
            } catch let error as WorkbenchIPCError where error.code == .resourceLimit {
                break
            }
        }
        XCTAssertGreaterThan(largeAccepted, 1)
        XCTAssertLessThan(largeAccepted, 40)
        local.close(); try local.connect()
        var trustedGrant = grant; trustedGrant.id = UUID()
        let trustedAfterBytePressure = try local.configureConnection(deviceId: "review-device",
            dashboardId: "dashboard-1", revision: "revision-1", grant: trustedGrant,
            auth: .init(authRef: "", placement: .none), secret: nil)
        XCTAssertEqual(trustedAfterBytePressure.state, "pending")
        XCTAssertEqual(provisioning.calls, 1)
    }
}
#endif
