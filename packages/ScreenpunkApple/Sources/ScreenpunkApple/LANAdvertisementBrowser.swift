import Foundation
import ScreenpunkCore
#if canImport(Network)
import Network
#endif

#if canImport(Network)
/// Browses `_screenpunk._tcp` and publishes host/port records into the discovery hub.
public final class LANAdvertisementBrowser: @unchecked Sendable {
    private let hub: LoopbackDiscovery
    private let queue = DispatchQueue(label: "xyz.screenpunk.lan.browse")
    private var browser: NWBrowser?
    private var activeIDs = Set<String>()

    public init(hub: LoopbackDiscovery) {
        self.hub = hub
    }

    public func start() {
        if browser != nil { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: DiscoveryService.type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        queue.async { [weak self] in
            guard let self else { return }
            for id in self.activeIDs { self.hub.withdraw(id) }
            self.activeIDs.removeAll()
        }
    }

    private struct TXTFields {
        var id: String
        var major: Int
        var name: String?
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        let current = Set(results.map { txtFields($0).id })
        for id in activeIDs.subtracting(current) { hub.withdraw(id) }
        activeIDs = current
        for result in results {
            let meta = txtFields(result)
            switch result.endpoint {
            case .hostPort(let host, let port):
                advertise(meta, host: "\(host)", port: Int(port.rawValue))
            default:
                resolve(result, meta: meta)
            }
        }
    }

    private func resolve(_ result: NWBrowser.Result, meta: TXTFields) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    self?.advertise(meta, host: "\(host)", port: Int(port.rawValue))
                }
                connection.cancel()
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func advertise(_ meta: TXTFields, host: String, port: Int) {
        guard port > 0, meta.id.isEmpty == false, activeIDs.contains(meta.id) else { return }
        hub.advertise(
            AdvertisedDevice(
                deviceId: meta.id,
                protocolMajor: meta.major,
                host: host,
                port: port,
                source: .advertised,
                name: meta.name
            )
        )
    }

    private func txtFields(_ result: NWBrowser.Result) -> TXTFields {
        var meta = TXTFields(id: "advertised", major: DiscoveryService.protocolMajor, name: nil)
        if case .bonjour(let txt) = result.metadata {
            let fields = txt.dictionary
            if let version = fields["v"], let parsed = Int(version) {
                meta.major = parsed
            }
            meta.name = DeviceDisplayName.sanitize(fields["n"])
        }
        // Bonjour may suffix duplicate service names. Preserve each endpoint until
        // the controller reconciles it using the identity observed over TLS.
        if case .service(let name, let type, let domain, _) = result.endpoint {
            meta.id = "bonjour:\(name).\(type).\(domain)"
        } else {
            meta.id = "bonjour:\(result.endpoint)"
        }
        return meta
    }
}
#endif
