import Foundation
import ScreenpunkCore
#if canImport(Network)
import Network
import dnssd
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
    private var resolutions: [String: BonjourServiceResolver] = [:]
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
        for resolver in resolutions.values { resolver.cancel() }
        resolutions.removeAll()
        for id in activeIDs { hub.withdraw(id) }
        activeIDs.removeAll()
    }

    deinit {
        pathMonitor?.cancel()
        recoveryTimer?.cancel()
        browser?.cancel()
        for resolver in resolutions.values { resolver.cancel() }
        for id in activeIDs { hub.withdraw(id) }
    }

    private struct TXTFields: Sendable {
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
            case .service:
                resolve(result, meta: meta)
            default:
                break
            }
        }
    }

    /// SRV target (`name.local`) and port. A TCP connect here would hit the TLS listener.
    private func resolve(_ result: NWBrowser.Result, meta: TXTFields) {
        guard resolutions[meta.id] == nil else { return }
        guard case .service(let name, let type, let domain, let interface) = result.endpoint,
              name.isEmpty == false, type.isEmpty == false else { return }
        let resolver = BonjourServiceResolver(queue: queue, onResolved: { [weak self] host, port in
            self?.advertise(meta, host: host, port: port)
        }, onDone: { [weak self] resolver in
            guard let self, self.resolutions[meta.id] === resolver else { return }
            self.resolutions[meta.id] = nil
        })
        resolutions[meta.id] = resolver
        resolver.start(
            name: name,
            type: type,
            domain: domain.isEmpty ? "local." : domain,
            interfaceIndex: UInt32(exactly: interface?.index ?? 0) ?? 0
        )
    }

    private func advertise(_ meta: TXTFields, host: String, port: Int) {
        guard port > 0, host.isEmpty == false, meta.id.isEmpty == false, activeIDs.contains(meta.id) else { return }
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

/// One `DNSServiceResolve`. The service ref is deallocated exactly once.
private final class BonjourServiceResolver: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onResolved: @Sendable (String, Int) -> Void
    private let onDone: @Sendable (BonjourServiceResolver) -> Void
    private let lock = NSLock()
    private var service: DNSServiceRef?
    private var finished = false

    init(queue: DispatchQueue, onResolved: @escaping @Sendable (String, Int) -> Void,
         onDone: @escaping @Sendable (BonjourServiceResolver) -> Void) {
        self.queue = queue
        self.onResolved = onResolved
        self.onDone = onDone
    }

    func start(name: String, type: String, domain: String, interfaceIndex: UInt32) {
        var created: DNSServiceRef?
        let flags: DNSServiceFlags = interfaceIndex == 0 ? kDNSServiceFlagsIncludeP2P : 0
        let error = name.withCString { name in
            type.withCString { type in
                domain.withCString { domain in
                    DNSServiceResolve(
                        &created, flags, interfaceIndex, name, type, domain,
                        Self.reply, Unmanaged.passUnretained(self).toOpaque()
                    )
                }
            }
        }
        guard Self.succeeded(error), let created else {
            finish(nil, 0)
            return
        }
        guard Self.succeeded(DNSServiceSetDispatchQueue(created, queue)) else {
            DNSServiceRefDeallocate(created)
            finish(nil, 0)
            return
        }
        lock.lock()
        let stopped = finished
        if stopped == false { service = created }
        lock.unlock()
        if stopped {
            queue.async { DNSServiceRefDeallocate(created) }
            return
        }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(nil, 0) }
    }

    func cancel() {
        var ref: DNSServiceRef?
        guard claim(&ref), let ref else { return }
        let queue = self.queue
        queue.async { DNSServiceRefDeallocate(ref) }
    }

    deinit { cancel() }

    private func finish(_ host: String?, _ port: Int) {
        var ref: DNSServiceRef?
        guard claim(&ref) else { return }
        if let ref { DNSServiceRefDeallocate(ref) }
        if let host = Self.hostname(host), port > 0 { onResolved(host, port) }
        onDone(self)
    }

    private func claim(_ ref: inout DNSServiceRef?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        ref = service
        service = nil
        return true
    }

    // Port is network byte order. `kDNSServiceErr_*` is an untyped C enum (`Int`);
    // the callback's error parameter is `int32_t`.
    private static let reply: DNSServiceResolveReply = { _, _, _, error, _, target, port, _, _, context in
        guard let context else { return }
        let resolver = Unmanaged<BonjourServiceResolver>.fromOpaque(context).takeUnretainedValue()
        let host = BonjourServiceResolver.succeeded(error) ? target.map { String(cString: $0) } : nil
        let resolvedPort = host == nil ? 0 : Int(UInt16(bigEndian: port))
        resolver.queue.async { [weak resolver] in resolver?.finish(host, resolvedPort) }
    }

    private static func succeeded(_ error: DNSServiceErrorType) -> Bool {
        error == DNSServiceErrorType(kDNSServiceErr_NoError)
    }

    private static func hostname(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if host.hasSuffix("."), host.count > 1 { host.removeLast() }
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty || host == "." ? nil : host
    }
}
#endif
