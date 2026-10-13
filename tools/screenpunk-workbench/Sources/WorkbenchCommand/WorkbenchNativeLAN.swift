import Foundation
import ScreenpunkApple
import ScreenpunkController
import ScreenpunkCore
import Network

/// The service owns this adapter. Construction has no Keychain or network effect.
/// Only an explicit device operation calls activate; a failed identity lookup is
/// propagated and never replaced with a second controller identity.
final class WorkbenchNativeLAN {
    private var browser: LANAdvertisementBrowser?
    private var generation: UInt64?

    func activate(_ service: ControllerService) throws {
        guard generation == nil else { return }
        let identity = try TLSIdentity.loadOrCreate(role: .controller)
        guard let attached = service.devices.attachIfEmpty(WorkbenchLANFactory(identity: identity)) else {
            throw WorkbenchIPCError(.alreadyRunning)
        }
        generation = attached
        let browser = LANAdvertisementBrowser(hub: service.devices.hub)
        browser.start()
        self.browser = browser
    }

    func deactivate(_ service: ControllerService) {
        browser?.stop()
        browser = nil
        if let generation { _ = service.devices.detach(ifGeneration: generation) }
        generation = nil
    }
}

private struct WorkbenchLANFactory: DeviceLinkFactory {
    let identity: TLSIdentityMaterial
    var controllerIdentity: PairingIdentity { identity.pairingIdentity }
    func makeLink() throws -> DeviceLink { WorkbenchLANLink(identity: identity) }
}

private final class WorkbenchLANLink: DeviceLink {
    private let client: ControllerLANClient
    init(identity: TLSIdentityMaterial) { client = ControllerLANClient(identity: identity) }
    var devicePin: [UInt8]? { client.devicePin }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws {
        try open(host: host, port: port, pinnedDevice: pinnedDevice, timeout: nil)
    }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?, timeout: TimeInterval) throws {
        try open(host: host, port: port, pinnedDevice: pinnedDevice, timeout: timeout)
    }
    private func open(host: String, port: UInt16, pinnedDevice: [UInt8]?, timeout: TimeInterval?) throws {
        do { try client.connect(host: host, port: port, pinnedDevice: pinnedDevice, timeout: timeout) }
        catch let error as NWError {
            if case .tls = error { throw TransferFailure.notPaired }
            throw error
        }
    }
    func hello() throws -> LANHello { try client.hello() }
    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult { try client.beginPairing(nonce: nonce) }
    func confirmPairing(code: String) throws { try client.confirmPairing(code: code) }
    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord { try client.deploy(body) }
    func deployScreenSet(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt { try client.deployScreenSet(body) }
    func relayCloudArchiveChunk(_ body: LANCloudArchiveChunk) throws -> LANCloudArchiveChunkReceipt { try client.relayCloudArchiveChunk(body) }
    func relayCloudCommand(_ body: LANCloudRelay) throws -> LANCloudRelayReceipt { try client.relayCloudCommand(body) }
    func installUnifiedScreens(_ body: LANUnifiedScreenInstall) throws -> LANActiveQuery { try client.installUnifiedScreens(body) }
    func selectUnifiedScreen(_ body: LANScreenManagementChange) throws -> LANActiveQuery { try client.selectUnifiedScreen(body) }
    func removeUnifiedScreen(_ body: LANScreenManagementChange) throws -> LANActiveQuery { try client.removeUnifiedScreen(body) }
    func queryActiveState() throws -> LANActiveQuery { try client.queryActiveState() }
    func connectionInventory() throws -> DeviceConnectionInventory { try client.connectionInventory() }
    func updateHomeConnection(_ update: DeviceHomeAssistantUpdate) throws -> DeviceConnectionInventory { try client.updateHomeConnection(update) }
    func getSettings() throws -> DeviceSettingsSnapshot { try client.getSettings() }
    func updateSettings(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot { try client.updateSettings(update) }
    func provisionConnections(_ configuration: ConnectionProvisioning) throws -> ConnectionProvisioningReceipt {
        try client.provisionConnections(configuration)
    }
    func provisionHomeAssistant(_ configuration: HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt {
        try client.provisionHomeAssistant(configuration)
    }
    func revokeHomeAssistant() throws { try client.revokeHomeAssistant() }
    func queryActive() throws -> String? { try client.queryActive() }
    func cancel() { client.cancel() }
}
