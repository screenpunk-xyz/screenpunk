import Foundation
import ScreenpunkApple
import ScreenpunkController
import ScreenpunkCore
#if canImport(Network)
import Network
#endif

#if canImport(Network) && canImport(Security)
/// `DeviceLink` over the pinned TLS 1.3 client from ScreenpunkApple.
public final class AppleLANDeviceLink: DeviceLink {
    private let client: ControllerLANClient

    public init(identity: TLSIdentityMaterial) {
        client = ControllerLANClient(identity: identity)
    }

    public var devicePin: [UInt8]? { client.devicePin }

    public func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws {
        try open(host: host, port: port, pinnedDevice: pinnedDevice, timeout: nil)
    }

    public func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?, timeout: TimeInterval) throws {
        try open(host: host, port: port, pinnedDevice: pinnedDevice, timeout: timeout)
    }

    private func open(host: String, port: UInt16, pinnedDevice: [UInt8]?, timeout: TimeInterval?) throws {
        do {
            try client.connect(host: host, port: port, pinnedDevice: pinnedDevice, timeout: timeout)
        } catch let error as NWError {
            // A TLS failure is pin verification refusing the peer on one side
            // (second controller, or a device whose identity changed).
            if case .tls = error {
                throw TransferFailure.notPaired
            }
            throw error
        }
    }

    public func hello() throws -> LANHello {
        try client.hello()
    }

    public func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult {
        try client.beginPairing(nonce: nonce)
    }

    public func confirmPairing(code: String) throws {
        try client.confirmPairing(code: code)
    }

    public func deploy(_ body: LANDeployBody) throws -> DeploymentRecord {
        try client.deploy(body)
    }

    public func deployScreenSet(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt {
        try client.deployScreenSet(body)
    }
    public func relayCloudArchiveChunk(_ body: LANCloudArchiveChunk) throws -> LANCloudArchiveChunkReceipt { try client.relayCloudArchiveChunk(body) }
    public func relayCloudCommand(_ body: LANCloudRelay) throws -> LANCloudRelayReceipt { try client.relayCloudCommand(body) }
    public func installUnifiedScreens(_ body: LANUnifiedScreenInstall) throws -> LANActiveQuery { try client.installUnifiedScreens(body) }
    public func selectUnifiedScreen(_ body: LANScreenManagementChange) throws -> LANActiveQuery { try client.selectUnifiedScreen(body) }
    public func removeUnifiedScreen(_ body: LANScreenManagementChange) throws -> LANActiveQuery { try client.removeUnifiedScreen(body) }
    public func queryActiveState() throws -> LANActiveQuery { try client.queryActiveState() }
    public func connectionInventory() throws -> DeviceConnectionInventory { try client.connectionInventory() }
    public func updateHomeConnection(_ update: DeviceHomeAssistantUpdate) throws -> DeviceConnectionInventory { try client.updateHomeConnection(update) }
    public func getSettings() throws -> DeviceSettingsSnapshot { try client.getSettings() }
    public func updateSettings(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot { try client.updateSettings(update) }

    public func provisionConnections(_ configuration: ConnectionProvisioning) throws -> ConnectionProvisioningReceipt {
        try client.provisionConnections(configuration)
    }

    public func provisionHomeAssistant(_ configuration: HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt {
        try client.provisionHomeAssistant(configuration)
    }
    public func revokeHomeAssistant() throws { try client.revokeHomeAssistant() }

    public func queryActive() throws -> String? {
        try client.queryActive()
    }

    public func cancel() {
        client.cancel()
    }
}

public struct AppleLANDeviceLinkFactory: DeviceLinkFactory {
    public let identity: TLSIdentityMaterial

    public init(identity: TLSIdentityMaterial) { self.identity = identity }

    public var controllerIdentity: PairingIdentity { identity.pairingIdentity }

    public func makeLink() throws -> DeviceLink {
        AppleLANDeviceLink(identity: identity)
    }
}
#endif
