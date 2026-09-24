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
    private var pathMonitor: NWPathMonitor?
    private var networkPath: String?
    private var recoveryTimer: DispatchSourceTimer?
    private var resolutions: [String: NWConnection] = [:]
    private var activeIDs = Set<String>()

    public init(hub: LoopbackDiscovery) {
        self.hub = hub
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.recoveryTimer == nil else { return }
            self.startBrowser()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self, weak monitor] path in
                guard let self, let monitor, self.pathMonitor === monitor else { return }
                let interfaces = path.availableInterfaces.map {
                    "\($0.name):\($0.index):\(path.usesInterfaceType($0.type))"
                }.sorted().joined(separator: ",")
                let signature = "\(path.status):\(path.supportsIPv4):\(path.supportsIPv6):\(interfaces)"
                let previous = self.networkPath
                self.networkPath = signature
                guard let previous, signature != previous else { return }
                // Service endpoints may carry an interface scope. Discard old
                // resolutions when routing changes, even if Bonjour stayed ready.
                self.clearBrowser()
                self.startBrowser()
            }
            self.pathMonitor = monitor
            monitor.start(queue: self.queue)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let browser = self.browser, case .ready = browser.state {
                    // Retry address resolution even if Bonjour's results haven't changed.
                    self.publish(browser.browseResults)
                } else {
                    self.clearBrowser()
                    self.startBrowser()
                }
            }
            self.recoveryTimer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.networkPath = nil
            self.recoveryTimer?.cancel()
            self.recoveryTimer = nil
            self.clearBrowser()
        }
    }

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: DiscoveryService.type, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            self.publish(results)
        }
        browser.start(queue: queue)
    }

    private func clearBrowser() {
        browser?.cancel()
        browser = nil
        for connection in resolutions.values { connection.cancel() }
        resolutions.removeAll()
        for id in activeIDs { hub.withdraw(id) }
        activeIDs.removeAll()
    }

    deinit {
        pathMonitor?.cancel()
        recoveryTimer?.cancel()
        browser?.cancel()
        for connection in resolutions.values { connection.cancel() }
        for id in activeIDs { hub.withdraw(id) }
    }

    private struct TXTFields {
        var id: String
        var major: Int
        var name: String?
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        let current = Set(results.map { txtFields($0).id })
        for id in activeIDs.subtracting(current) {
            hub.withdraw(id)
            resolutions.removeValue(forKey: id)?.cancel()
        }
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
        guard resolutions[meta.id] == nil else { return }
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        resolutions[meta.id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.resolutions[meta.id] === connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    self.advertise(meta, host: "\(host)", port: Int(port.rawValue))
                }
                self.resolutions[meta.id] = nil
                connection.cancel()
            case .failed, .cancelled:
                self.resolutions[meta.id] = nil
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.resolutions[meta.id] === connection else { return }
            self.resolutions[meta.id] = nil
            connection.cancel()
        }
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
