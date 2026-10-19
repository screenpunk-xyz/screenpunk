import Foundation
import ScreenpunkApple
import ScreenpunkController
import ScreenpunkCore

public protocol ControllerLANDiscovery: AnyObject {
    func start()
    func stop()
}

#if canImport(Network)
extension LANAdvertisementBrowser: ControllerLANDiscovery {}
#endif

/// Native connection providers are installed only on explicit attachment.
/// Creating these closures does not access the Keychain or the LAN.
public struct ControllerNativeConnections {
    public var homeAssistant: (@Sendable (String, String, String) throws -> HomeAssistantProvisioning)?
    public var description: (@Sendable () throws -> Data)?
    public var inspection: (@Sendable (String?) throws -> Data)?

    public init(
        homeAssistant: (@Sendable (String, String, String) throws -> HomeAssistantProvisioning)? = nil,
        description: (@Sendable () throws -> Data)? = nil,
        inspection: (@Sendable (String?) throws -> Data)? = nil
    ) {
        self.homeAssistant = homeAssistant
        self.description = description
        self.inspection = inspection
    }

#if os(macOS)
    public static var native: Self {
        Self(
            homeAssistant: { try MacHomeAssistantConnection.provisioning(dashboardId: $0, revision: $1, provisioningId: $2) },
            description: { try MacHomeAssistantConnection.descriptor() },
            inspection: { try MacHomeAssistantConnection.inspectBlocking(query: $0) }
        )
    }
#endif
}

/// One broker-owned native transport. Construction is inert; attachment is the
/// explicit identity/discovery boundary. Callers serialize domain operations.
/// One active domain may be bound at a time. Reattachment after stop reloads
/// identity so a revoked or changed Keychain item is not silently retained.
public final class AppleControllerTransport {
    private let makeLinkFactory: () throws -> any DeviceLinkFactory
    private let makeDiscovery: (LoopbackDiscovery) -> any ControllerLANDiscovery
    private let connections: ControllerNativeConnections
    private let lock = NSLock()
    private var service: ControllerService?
    private var factory: (any DeviceLinkFactory)?
    private var discovery: (any ControllerLANDiscovery)?
    private var ownedGeneration: UInt64?
    private var active = false

    public init(
        linkFactory: @escaping () throws -> any DeviceLinkFactory,
        discoveryFactory: @escaping (LoopbackDiscovery) -> any ControllerLANDiscovery,
        connections: ControllerNativeConnections = .init()
    ) {
        self.makeLinkFactory = linkFactory
        self.makeDiscovery = discoveryFactory
        self.connections = connections
    }

#if os(macOS) && canImport(Network) && canImport(Security)
    public convenience init() {
        self.init(
            linkFactory: { AppleLANDeviceLinkFactory(identity: try TLSIdentity.loadOrCreate(role: .controller)) },
            discoveryFactory: { LANAdvertisementBrowser(hub: $0) },
            connections: .native
        )
    }
#endif

    @discardableResult
    public func attach(to service: ControllerService) throws -> PairingIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let bound = self.service, bound !== service {
            throw ControllerError.validationFailed(detail: "Native transport already belongs to another controller domain")
        }
        if active, let factory {
            guard ownedGeneration == service.devices.currentTransportGeneration else {
                throw ControllerError.validationFailed(detail: "Native transport binding was replaced")
            }
            return factory.controllerIdentity
        }
        guard !service.devices.transportAvailable else {
            throw ControllerError.validationFailed(detail: "Another native transport already owns this controller domain")
        }
        // Failure here leaves the domain without native providers or discovery.
        let factory = try self.factory ?? makeLinkFactory()
        let discovery = self.discovery ?? makeDiscovery(service.devices.hub)
        guard let generation = service.devices.attachIfEmpty(factory) else {
            throw ControllerError.validationFailed(detail: "Another native transport already owns this controller domain")
        }
        ownedGeneration = generation
        self.factory = factory
        self.discovery = discovery
        self.service = service
        service.homeAssistantConfiguration = connections.homeAssistant
        service.connectionDescription = connections.description
        service.connectionInspection = connections.inspection
        discovery.start()
        active = true
        return factory.controllerIdentity
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        discovery?.stop()
        if let service, let ownedGeneration, service.devices.detach(ifGeneration: ownedGeneration) {
            service.homeAssistantConfiguration = nil
            service.connectionDescription = nil
            service.connectionInspection = nil
        }
        ownedGeneration = nil
        factory = nil
        discovery = nil
        service = nil
        active = false
    }

    deinit { stop() }
}
