import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class ConnectionApprovalTests: XCTestCase {
    func testApprovalRequiresPairingAndValidCredentialsThenChecksReceiptScope() throws {
        let device = FakeLANDevice(deviceId: "approval-device", name: "Phone")
        let state = ApprovalTransportState()
        let coordinator = makeCoordinator(device: device, state: state)
        let configuration = ConnectionProvisioning(dashboardId: "dashboard", revision: "revision", entries: [])
        XCTAssertThrowsError(try coordinator.provisionConnections(deviceId: device.runtime.profile.deviceId, configuration: configuration))
        XCTAssertEqual(state.attempts, 0)
        try pair(coordinator, device: device)

        let receipt = try coordinator.provisionConnections(deviceId: device.runtime.profile.deviceId, configuration: configuration)
        XCTAssertEqual(receipt.provisioningId, configuration.provisioningId)
        XCTAssertEqual(state.attempts, 1)
        state.wrongRevision = true
        XCTAssertThrowsError(try coordinator.provisionConnections(deviceId: device.runtime.profile.deviceId, configuration: configuration))

        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "door", origin: "https://example.com", transport: .http,
                                    authRef: "door-key", lan: false, allowInsecureHTTP: false,
                                    operations: [.init(name: "read", kind: .http, method: .GET, path: "/state", idempotent: true, write: false)])
        let invalid = ConnectionProvisioning(dashboardId: "dashboard", revision: "revision", entries: [
            .init(grant: grant, binding: .init(authRef: "door-key", placement: .bearer), secret: nil)
        ])
        let before = state.attempts
        XCTAssertThrowsError(try coordinator.provisionConnections(deviceId: device.runtime.profile.deviceId, configuration: invalid))
        XCTAssertEqual(state.attempts, before, "Reject invalid credential bindings before transport")
    }

    func testOfflineApprovalDoesNotReplayOnReconnect() throws {
        let device = FakeLANDevice(deviceId: "approval-device", name: "Phone")
        let state = ApprovalTransportState()
        let coordinator = makeCoordinator(device: device, state: state)
        try pair(coordinator, device: device)
        device.online = false
        XCTAssertThrowsError(try coordinator.provisionConnections(deviceId: device.runtime.profile.deviceId,
            configuration: .init(dashboardId: "dashboard", revision: "revision", entries: [])))
        XCTAssertEqual(state.attempts, 0)
        device.online = true
        _ = try coordinator.device(device.runtime.profile.deviceId, probe: true)
        XCTAssertEqual(state.attempts, 0, "A read or reconnect must not replay a failed approval")
    }

    private func makeCoordinator(device: FakeLANDevice, state: ApprovalTransportState) -> DeviceCoordinator {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("connection-approval-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let identity = PairingIdentityFactory.make(role: .controller)
        return DeviceCoordinator(directory: .init(url: root.appendingPathComponent("devices.json")), hub: LoopbackDiscovery(),
                                 linkFactory: ApprovalLinkFactory(device: device, controllerIdentity: identity, state: state))
    }

    private func pair(_ coordinator: DeviceCoordinator, device: FakeLANDevice) throws {
        let request = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()
        _ = try coordinator.confirmPairing(deviceId: request.deviceId)
    }
}

private final class ApprovalTransportState: @unchecked Sendable {
    var attempts = 0
    var wrongRevision = false
}
private struct ApprovalLinkFactory: DeviceLinkFactory {
    let device: FakeLANDevice
    let controllerIdentity: PairingIdentity
    let state: ApprovalTransportState
    func makeLink() throws -> DeviceLink {
        ApprovalLink(device: device, controllerPin: controllerIdentity.publicKey, state: state)
    }
}
private final class ApprovalLink: DeviceLink {
    let wrapped: FakeLANLink
    let device: FakeLANDevice
    let state: ApprovalTransportState
    init(device: FakeLANDevice, controllerPin: [UInt8], state: ApprovalTransportState) {
        wrapped = FakeLANLink(device: device, controllerPin: controllerPin); self.device = device; self.state = state
    }
    var devicePin: [UInt8]? { wrapped.devicePin }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws { try wrapped.connect(host: host, port: port, pinnedDevice: pinnedDevice) }
    func hello() throws -> LANHello { try wrapped.hello() }
    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult { try wrapped.beginPairing(nonce: nonce) }
    func confirmPairing(code: String) throws { try wrapped.confirmPairing(code: code) }
    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord { try wrapped.deploy(body) }
    func queryActive() throws -> String? { try wrapped.queryActive() }
    func cancel() { wrapped.cancel() }
    func provisionConnections(_ configuration: ConnectionProvisioning) throws -> ConnectionProvisioningReceipt {
        guard device.online else { throw TransferFailure.deviceOffline }
        state.attempts += 1
        return .init(deviceId: device.runtime.profile.deviceId, dashboardId: configuration.dashboardId,
                     revision: state.wrongRevision ? "other" : configuration.revision, provisioningId: configuration.provisioningId)
    }
}
