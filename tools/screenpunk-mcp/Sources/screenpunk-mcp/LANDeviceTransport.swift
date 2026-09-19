import Foundation
import ScreenpunkApple
import ScreenpunkController
import ScreenpunkCore
#if canImport(Network)
import Network
#endif

/// Wires the controller's device link to the existing TLS 1.3 LAN stack:
/// `ControllerLANClient` for pairing/deploy and `LANAdvertisementBrowser` for
/// `_screenpunk._tcp` discovery. Devices still fetch their own data; nothing
/// here relays dashboard traffic.
final class LANTransport {
#if canImport(Network) && canImport(Security)
    private var browser: LANAdvertisementBrowser?
#endif

    func attach(to service: ControllerService) -> String {
        service.homeAssistantConfiguration = { try MacHomeAssistantConnection.provisioning(dashboardId: $0, revision: $1, provisioningId: $2) }
        service.connectionDescription = { try MacHomeAssistantConnection.descriptor() }
        service.connectionInspection = { try MacHomeAssistantConnection.inspectBlocking(query: $0) }
#if canImport(Network) && canImport(Security)
        let browser = LANAdvertisementBrowser(hub: service.devices.hub)
        browser.start()
        self.browser = browser
        do {
            let identity = try TLSIdentity.loadOrCreate(role: .controller)
            service.devices.attach(LANDeviceLinkFactory(identity: identity))
            return "lan=tls1.3 controllerPin=\(PeerPin.hex(identity.pin).prefix(8))…"
        } catch {
            return "lan=unavailable tls-identity-failed \(error)"
        }
#else
        return "lan=unavailable network-framework-missing"
#endif
    }
}

#if canImport(Network) && canImport(Security)
/// `DeviceLink` over the pinned TLS 1.3 client from ScreenpunkApple.
final class LANDeviceLink: DeviceLink {
    private let client: ControllerLANClient

    init(identity: TLSIdentityMaterial) {
        client = ControllerLANClient(identity: identity)
    }

    var devicePin: [UInt8]? { client.devicePin }

    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws {
        do {
            try client.connect(host: host, port: port, pinnedDevice: pinnedDevice)
        } catch let error as NWError {
            // A TLS failure is pin verification refusing the peer on one side
            // (second controller, or a device whose identity changed).
            if case .tls = error {
                throw TransferFailure.notPaired
            }
            throw error
        }
    }

    func hello() throws -> LANHello {
        try client.hello()
    }

    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult {
        try client.beginPairing(nonce: nonce)
    }

    func confirmPairing(code: String) throws {
        try client.confirmPairing(code: code)
    }

    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord {
        try client.deploy(body)
    }

    func deployScreenSet(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt {
        try client.deployScreenSet(body)
    }
    func queryActiveState() throws -> LANActiveQuery { try client.queryActiveState() }
    func getSettings() throws -> DeviceSettingsSnapshot { try client.getSettings() }
    func updateSettings(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot { try client.updateSettings(update) }

    func provisionHomeAssistant(_ configuration: HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt {
        try client.provisionHomeAssistant(configuration)
    }
    func revokeHomeAssistant() throws { try client.revokeHomeAssistant() }

    func queryActive() throws -> String? {
        try client.queryActive()
    }

    func cancel() {
        client.cancel()
    }
}

struct LANDeviceLinkFactory: DeviceLinkFactory {
    let identity: TLSIdentityMaterial

    var controllerIdentity: PairingIdentity { identity.pairingIdentity }

    func makeLink() throws -> DeviceLink {
        LANDeviceLink(identity: identity)
    }
}
#endif
