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

    public init(hub: LoopbackDiscovery) {
        self.hub = hub
    }

    public func start() {
        if browser != nil { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: DiscoveryService.type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        for result in results {
            let meta = txtFields(result)
            switch result.endpoint {
            case .hostPort(let host, let port):
                advertise(deviceId: meta.id, host: "\(host)", port: Int(port.rawValue), major: meta.major)
            default:
                resolve(result, meta: meta)
            }
        }
    }

    private func resolve(_ result: NWBrowser.Result, meta: (id: String, major: Int)) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    self?.advertise(
                        deviceId: meta.id,
                        host: "\(host)",
                        port: Int(port.rawValue),
                        major: meta.major
                    )
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

    private func advertise(deviceId: String, host: String, port: Int, major: Int) {
        guard port > 0, deviceId.isEmpty == false else { return }
        hub.advertise(
            AdvertisedDevice(
                deviceId: deviceId,
                protocolMajor: major,
                host: host,
                port: port,
                source: .advertised
            )
        )
    }

    private func txtFields(_ result: NWBrowser.Result) -> (id: String, major: Int) {
        var deviceId = "advertised"
        var major = DiscoveryService.protocolMajor
        if case .bonjour(let txt) = result.metadata {
            let fields = txt.dictionary
            if let id = fields["id"], id.isEmpty == false {
                deviceId = id
            }
            if let version = fields["v"], let parsed = Int(version) {
                major = parsed
            }
        }
        if deviceId == "advertised", case .service(let name, _, _, _) = result.endpoint {
            deviceId = name
        }
        return (deviceId, major)
    }
}
#endif
