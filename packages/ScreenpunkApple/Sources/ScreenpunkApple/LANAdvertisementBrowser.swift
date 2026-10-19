import Foundation
import ScreenpunkCore
#if canImport(Network)
import Darwin
import Network
import dnssd
#endif

#if canImport(Network)
/// Browses `_screenpunk._tcp` and publishes host/port records into the discovery hub.
///
/// Host and port come from DNS-SD (SRV, then A/AAAA). The device port is a TLS
/// listener, so discovery must not open a TCP connection to it.
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
            case .service:
                resolve(result, meta: meta)
            default:
                break
            }
        }
    }

    /// DNS-SD resolve of the browsed service. `NWConnection` to the service
    /// endpoint would complete a TCP handshake against the TLS listener and
    /// then cancel, which the device logs as a client hello that never arrives.
    private func resolve(_ result: NWBrowser.Result, meta: TXTFields) {
        guard resolutions[meta.id] == nil else { return }
        guard case .service(let name, let type, let domain, let interface) = result.endpoint,
              name.isEmpty == false, type.isEmpty == false else { return }
        let resolver = BonjourServiceResolver(
            name: name,
            type: type,
            domain: domain.isEmpty ? "local." : domain,
            interfaceIndex: UInt32(exactly: interface?.index ?? 0) ?? 0,
            queue: queue,
            onResolved: { [weak self] host, port in
                self?.advertise(meta, host: host, port: port)
            },
            onDone: { [weak self] resolver in
                guard let self, self.resolutions[meta.id] === resolver else { return }
                self.resolutions[meta.id] = nil
            }
        )
        resolutions[meta.id] = resolver
        resolver.start()
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

/// Host string and port decoded from a DNS-SD SRV/address result, with no socket.
enum BonjourResolvedAddress {
    struct Candidate: Equatable {
        var host: String
        var family: Int
    }

    /// `DNSServiceResolve` returns the SRV port in network byte order.
    static func port(networkOrder: UInt16) -> Int {
        Int(UInt16(bigEndian: networkOrder))
    }

    /// Strip the DNS trailing dot so `NWEndpoint.Host` receives `name.local`.
    static func normalizeHost(_ host: String) -> String? {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix("."), host.count > 1 { host.removeLast() }
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : host
    }

    /// Keep a link-local IPv6 address usable by appending the scope when the
    /// numeric form has none. `fe80::1%en0` is what `NWEndpoint.Host` accepts.
    static func appendingScope(_ host: String, scope: UInt32) -> String {
        guard scope != 0, host.contains("%") == false else { return host }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        if if_indextoname(scope, &name) != nil {
            return host + "%" + String(cString: name)
        }
        return host + "%\(scope)"
    }

    static func copy(_ address: UnsafePointer<sockaddr>?) -> Data? {
        guard let address else { return nil }
        let family = address.pointee.sa_family
        let size: Int
        if family == sa_family_t(AF_INET) {
            size = MemoryLayout<sockaddr_in>.size
        } else if family == sa_family_t(AF_INET6) {
            size = MemoryLayout<sockaddr_in6>.size
        } else {
            return nil
        }
        return Data(bytes: UnsafeRawPointer(address), count: size)
    }

    static func describe(_ address: Data) -> Candidate? {
        guard address.count > 1 else { return nil }
        let family = address[1]
        if family == UInt8(AF_INET) {
            var storage = sockaddr_in()
            guard copyInto(address, &storage) else { return nil }
            guard let host = numericHost(&storage, length: socklen_t(MemoryLayout<sockaddr_in>.size)) else { return nil }
            return Candidate(host: host, family: Int(AF_INET))
        }
        if family == UInt8(AF_INET6) {
            var storage = sockaddr_in6()
            guard copyInto(address, &storage) else { return nil }
            guard let host = numericHost(&storage, length: socklen_t(MemoryLayout<sockaddr_in6>.size)) else { return nil }
            return Candidate(host: appendingScope(host, scope: storage.sin6_scope_id), family: Int(AF_INET6))
        }
        return nil
    }

    /// Routable IPv4, then routable IPv6, then link-local. Arrival order breaks ties.
    static func pick(_ addresses: [Candidate]) -> String? {
        addresses.min(by: { rank($0) < rank($1) })?.host
    }

    private static func rank(_ address: Candidate) -> Int {
        let v4 = address.family == Int(AF_INET)
        let linkLocal = v4
            ? address.host.hasPrefix("169.254.")
            : address.host.lowercased().hasPrefix("fe80:")
        if v4 && !linkLocal { return 0 }
        if !v4 && !linkLocal { return 1 }
        if v4 { return 2 }
        return 3
    }

    private static func copyInto<T>(_ address: Data, _ storage: inout T) -> Bool {
        let size = MemoryLayout<T>.size
        guard address.count >= size else { return false }
        return address.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &storage) { dst in
                guard let src = raw.baseAddress, let dstBase = dst.baseAddress, raw.count >= size, dst.count >= size else {
                    return false
                }
                dstBase.copyMemory(from: src, byteCount: size)
                return true
            }
        }
    }

    private static func numericHost<T>(_ storage: inout T, length: socklen_t) -> String? {
        guard MemoryLayout<T>.size >= Int(length) else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &storage) { pointer -> Int32 in
            let sa = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self)
            return getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
        guard result == 0 else { return nil }
        let text = String(cString: host)
        return text.isEmpty ? nil : text
    }
}

/// Resolves one Bonjour service to a host and port on `queue`, without connecting.
private final class BonjourServiceResolver {
    private let name: String
    private let type: String
    private let domain: String
    private let interfaceIndex: UInt32
    private let queue: DispatchQueue
    private let onResolved: (String, Int) -> Void
    private var onDone: (BonjourServiceResolver) -> Void
    private let lock = NSLock()
    private var service: DNSServiceRef?
    private var finished = false
    private var hostName: String?
    private var port = 0
    private var addresses: [BonjourResolvedAddress.Candidate] = []

    init(
        name: String,
        type: String,
        domain: String,
        interfaceIndex: UInt32,
        queue: DispatchQueue,
        onResolved: @escaping (String, Int) -> Void,
        onDone: @escaping (BonjourServiceResolver) -> Void
    ) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceIndex = interfaceIndex
        self.queue = queue
        self.onResolved = onResolved
        self.onDone = onDone
    }

    func start() {
        guard open(resolveRef()) else {
            complete()
            return
        }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.timedOut()
        }
    }

    func cancel() {
        let (won, service) = finishAndTakeService()
        guard won, let service else { return }
        queue.async { DNSServiceRefDeallocate(service) }
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func finishAndTakeService() -> (won: Bool, service: DNSServiceRef?) {
        lock.lock()
        defer { lock.unlock() }
        if finished { return (false, nil) }
        finished = true
        let current = service
        service = nil
        return (true, current)
    }

    private func complete() {
        let (won, service) = finishAndTakeService()
        guard won else { return }
        if let service { DNSServiceRefDeallocate(service) }
        let done = onDone
        onDone = { _ in }
        done(self)
    }

    private func deliver(_ host: String) {
        let (won, service) = finishAndTakeService()
        guard won else { return }
        if let service { DNSServiceRefDeallocate(service) }
        if port > 0, host.isEmpty == false { onResolved(host, port) }
        let done = onDone
        onDone = { _ in }
        done(self)
    }

    private func timedOut() {
        guard !isFinished else { return }
        if let host = BonjourResolvedAddress.pick(addresses) ?? hostName, port > 0 {
            deliver(host)
        } else {
            complete()
        }
    }

    private func resolveRef() -> DNSServiceRef? {
        var created: DNSServiceRef?
        let flags: DNSServiceFlags = interfaceIndex == 0 ? kDNSServiceFlagsIncludeP2P : 0
        let error = name.withCString { name in
            type.withCString { type in
                domain.withCString { domain in
                    DNSServiceResolve(
                        &created,
                        flags,
                        interfaceIndex,
                        name,
                        type,
                        domain,
                        Self.resolveReply,
                        Unmanaged.passUnretained(self).toOpaque()
                    )
                }
            }
        }
        guard error == kDNSServiceErr_NoError else { return nil }
        return created
    }

    private func open(_ created: DNSServiceRef?) -> Bool {
        guard let created else { return false }
        guard DNSServiceSetDispatchQueue(created, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(created)
            return false
        }
        lock.lock()
        if finished {
            lock.unlock()
            queue.async { DNSServiceRefDeallocate(created) }
            return false
        }
        service = created
        lock.unlock()
        return true
    }

    private func swapService(to created: DNSServiceRef) -> Bool {
        guard DNSServiceSetDispatchQueue(created, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(created)
            return false
        }
        lock.lock()
        if finished {
            lock.unlock()
            queue.async { DNSServiceRefDeallocate(created) }
            return false
        }
        let previous = service
        service = created
        lock.unlock()
        if let previous { DNSServiceRefDeallocate(previous) }
        return true
    }

    private func handleResolve(error: DNSServiceErrorType, host: String?, port: UInt16, interfaceIndex: UInt32) {
        guard !isFinished else { return }
        guard error == kDNSServiceErr_NoError, let host, let normalized = BonjourResolvedAddress.normalizeHost(host) else {
            complete()
            return
        }
        hostName = normalized
        self.port = BonjourResolvedAddress.port(networkOrder: port)
        guard self.port > 0 else {
            complete()
            return
        }
        let lookupInterface = interfaceIndex != 0 ? interfaceIndex : self.interfaceIndex
        var created: DNSServiceRef?
        // Multicast keeps the lookup on Bonjour. IncludeP2P only applies when
        // the browse result was not already pinned to one interface.
        let flags: DNSServiceFlags = lookupInterface == 0
            ? kDNSServiceFlagsForceMulticast | kDNSServiceFlagsIncludeP2P
            : kDNSServiceFlagsForceMulticast
        let queryError = host.withCString { name in
            DNSServiceGetAddrInfo(
                &created,
                flags,
                lookupInterface,
                kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6,
                name,
                Self.addressReply,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        guard queryError == kDNSServiceErr_NoError, let created else {
            deliver(normalized)
            return
        }
        guard swapService(to: created) else {
            if !isFinished { deliver(normalized) }
            return
        }
    }

    private func handleAddress(error: DNSServiceErrorType, flags: DNSServiceFlags, address: Data?) {
        guard !isFinished else { return }
        let more = error == kDNSServiceErr_NoError && (flags & kDNSServiceFlagsMoreComing) != 0
        if error == kDNSServiceErr_NoError, (flags & kDNSServiceFlagsAdd) != 0,
           let address, let described = BonjourResolvedAddress.describe(address) {
            addresses.append(described)
        }
        guard !more else { return }
        if let host = BonjourResolvedAddress.pick(addresses) ?? hostName {
            deliver(host)
        } else {
            complete()
        }
    }

    private static let resolveReply: DNSServiceResolveReply = { _, _, interfaceIndex, errorCode, _, hosttarget, port, _, _, context in
        guard let context else { return }
        let resolver = Unmanaged<BonjourServiceResolver>.fromOpaque(context).takeUnretainedValue()
        let host: String?
        if errorCode == kDNSServiceErr_NoError, let hosttarget {
            host = String(cString: hosttarget)
        } else {
            host = nil
        }
        let capturedPort = port
        let capturedError = errorCode
        let capturedInterface = interfaceIndex
        resolver.queue.async { [weak resolver] in
            resolver?.handleResolve(error: capturedError, host: host, port: capturedPort, interfaceIndex: capturedInterface)
        }
    }

    private static let addressReply: DNSServiceGetAddrInfoReply = { _, flags, _, errorCode, _, address, _, context in
        guard let context else { return }
        let resolver = Unmanaged<BonjourServiceResolver>.fromOpaque(context).takeUnretainedValue()
        let copied = BonjourResolvedAddress.copy(address)
        let capturedFlags = flags
        let capturedError = errorCode
        resolver.queue.async { [weak resolver] in
            resolver?.handleAddress(error: capturedError, flags: capturedFlags, address: copied)
        }
    }
}
#endif
