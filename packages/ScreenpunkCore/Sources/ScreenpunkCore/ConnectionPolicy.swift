import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AddressClass: String, Sendable, Equatable {
    case loopback
    case linkLocal
    case metadata
    case privateLAN
    case publicUnicast
    case invalid
}

public enum ConnectionDecision: String, Sendable, Equatable {
    case allow
    case validationFailed = "validation_failed"
    case permissionRequired = "permission_required"
    case deniedEgress = "denied_egress"
    case sizeLimit = "size_limit"
}

public struct AuthorizedDestination: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var queryParameters: [String: String]
    public var addressClass: AddressClass
    public var usesTLS: Bool
}

public enum ConnectionAuthKeys {
    public static let overrideKeys: Set<String> = [
        "authorization",
        "x-api-key",
        "token",
        "password",
        "access_token",
        "api_key",
        "apikey",
        "secret"
    ]

    public static let destinationKeys: Set<String> = [
        "path",
        "url",
        "host",
        "origin",
        "method",
        "headers",
        "scheme",
        "port"
    ]

    public static func isOverride(_ key: String) -> Bool {
        overrideKeys.contains(key.lowercased())
    }

    public static func isDestination(_ key: String) -> Bool {
        destinationKeys.contains(key.lowercased())
    }
}

public enum AddressClassifier {
    public static func classify(host: String) -> AddressClass {
        let lower = host.lowercased()
        if lower == "metadata.google.internal" || lower.hasSuffix(".metadata.google.internal") {
            return .metadata
        }
        if lower == "localhost" || lower.hasSuffix(".localhost") {
            return .loopback
        }
        if let ip = parseIPv4(lower) {
            return classifyIPv4(ip)
        }
        if lower.contains(":") {
            return classifyIPv6(lower)
        }
        return .publicUnicast
    }

    public static func classifyResolved(_ addresses: [String]) -> AddressClass {
        let classes = addresses.map(classify(host:))
        if classes.contains(.metadata) { return .metadata }
        if classes.contains(.invalid) { return .invalid }
        if classes.contains(.loopback) { return .loopback }
        if classes.contains(.linkLocal) { return .linkLocal }
        if classes.contains(.privateLAN) { return .privateLAN }
        if classes.isEmpty { return .invalid }
        return .publicUnicast
    }

    public static func isLoopbackLiteral(_ host: String) -> Bool {
        if let ip = parseIPv4(host) {
            return (ip >> 24) == 127
        }
        let trimmed = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return trimmed == "::1"
    }

    private static func classifyIPv4(_ ip: UInt32) -> AddressClass {
        if ip == 0xA9FEA9FE || ip == 0xA9FEA9FD || ip == 0xA9FEA97B {
            return .metadata
        }
        if ip == 0x646464C8 {
            return .metadata
        }
        let b1 = ip >> 24
        if b1 == 127 { return .loopback }
        if b1 == 0 || b1 >= 224 { return .invalid }
        if (ip >> 16) == 0xA9FE { return .linkLocal }
        if b1 == 10 { return .privateLAN }
        if b1 == 192 && ((ip >> 16) & 0xFF) == 168 { return .privateLAN }
        if b1 == 172 {
            let b2 = (ip >> 16) & 0xFF
            if (16...31).contains(b2) { return .privateLAN }
        }
        if b1 == 100 {
            let b2 = (ip >> 16) & 0xFF
            if (64...127).contains(b2) { return .privateLAN }
        }
        return .publicUnicast
    }

    private static func classifyIPv6(_ host: String) -> AddressClass {
        let text = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var address = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return .invalid }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return .invalid }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return .loopback }
        if bytes[0] == 0xff { return .invalid }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return .linkLocal }
        if bytes[0] == 0xfd, bytes[1] == 0, bytes[2] == 0x0e, bytes[3] == 0xc2 { return .metadata }
        if bytes[0] & 0xfe == 0xfc { return .privateLAN }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return classifyIPv4(bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        return .publicUnicast
    }

    private static func parseIPv4(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let byte = UInt32(part), byte <= 255 else { return nil }
            result = (result << 8) | byte
        }
        return result
    }
}

public protocol DestinationResolver: Sendable {
    func addresses(for host: String) throws -> [String]
}

public struct LiteralOrResolvedDestinationResolver: DestinationResolver {
    public init() {}

    public func addresses(for host: String) throws -> [String] {
        if AddressClassifier.classify(host: host) != .publicUnicast || host.contains(":")
            || AddressClassifier.isLoopbackLiteral(host) || parseLooksLikeIPv4(host) {
            return [host]
        }
        return try SystemNameResolver.addresses(for: host)
    }
}

public enum SystemNameResolver {
    public static func addresses(for host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { hostname in
            getaddrinfo(hostname, nil, &hints, &info)
        }
        guard status == 0, let first = info else {
            throw ConnectionFailure.deniedEgress
        }
        defer { freeaddrinfo(first) }
        var collected: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameStatus == 0 {
                collected.append(String(cString: buffer))
            }
            cursor = current.pointee.ai_next
        }
        if collected.isEmpty {
            throw ConnectionFailure.deniedEgress
        }
        return collected
    }
}

private func parseLooksLikeIPv4(_ host: String) -> Bool {
    host.split(separator: ".").count == 4 && host.unicodeScalars.allSatisfy {
        $0 == "." || CharacterSet.decimalDigits.contains($0)
    }
}

public enum ConnectionPolicy {
    public static func originHost(_ origin: String) throws -> String {
        guard let url = URL(string: origin), let host = url.host, host.isEmpty == false else {
            throw ConnectionFailure.validationFailed
        }
        return host
    }

    public static func decide(
        grant: ConnectionGrant,
        operationName: String,
        parameters: [String: String],
        resolvedAddresses: [String],
        binding: ConnectionAuthBinding
    ) -> ConnectionDecision {
        do {
            _ = try authorize(
                grant: grant,
                operationName: operationName,
                parameters: parameters,
                resolvedAddresses: resolvedAddresses,
                binding: binding
            )
            return .allow
        } catch let failure as ConnectionFailure {
            switch failure {
            case .validationFailed: return .validationFailed
            case .permissionRequired: return .permissionRequired
            case .deniedEgress: return .deniedEgress
            case .sizeLimit: return .sizeLimit
            case .timeout, .deviceOffline: return .deniedEgress
            }
        } catch {
            return .validationFailed
        }
    }

    public static func authorize(
        grant: ConnectionGrant,
        operationName: String,
        parameters: [String: String],
        resolvedAddresses: [String],
        binding: ConnectionAuthBinding
    ) throws -> AuthorizedDestination {
        try ConnectionGrantValidator.validate(grant)
        if binding.authRef != grant.authRef {
            throw ConnectionFailure.validationFailed
        }
        if encodedSize(parameters) > ConnectionBounds.parameterBytes {
            throw ConnectionFailure.sizeLimit
        }
        for key in parameters.keys {
            if ConnectionAuthKeys.isOverride(key) {
                throw ConnectionFailure.permissionRequired
            }
            if ConnectionAuthKeys.isDestination(key) {
                throw ConnectionFailure.deniedEgress
            }
            if let field = binding.fieldName, key.lowercased() == field.lowercased() {
                throw ConnectionFailure.permissionRequired
            }
        }

        guard let operation = grant.operations.first(where: { $0.name == operationName }) else {
            throw ConnectionFailure.permissionRequired
        }
        if operation.kind != grant.transport {
            throw ConnectionFailure.validationFailed
        }

        let parts = try splitOrigin(grant.origin)
        let destinationClass = AddressClassifier.classifyResolved(resolvedAddresses + [parts.host])
        try assertDestinationAllowed(grant: grant, originHost: parts.host, destinationClass: destinationClass)

        let scheme = try transportScheme(grant: grant, originScheme: parts.scheme)
        let url = try composeURL(scheme: scheme, host: parts.host, port: parts.port, path: operation.path)
        try assertSameOrigin(url: url, scheme: scheme, host: parts.host, port: parts.port)

        return AuthorizedDestination(
            url: url,
            method: operation.method.rawValue,
            queryParameters: operation.method == .GET || operation.method == .DELETE ? parameters : [:],
            addressClass: destinationClass,
            usesTLS: scheme == "https" || scheme == "wss"
        )
    }

    public static func mergeQueryParameters(url: URL, parameters: [String: String]) throws -> URL {
        if parameters.isEmpty { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ConnectionFailure.validationFailed
        }
        var items = components.queryItems ?? []
        let existing = Set(items.map { $0.name.lowercased() })
        for (key, value) in parameters {
            if existing.contains(key.lowercased()) || ConnectionAuthKeys.isOverride(key) {
                throw ConnectionFailure.permissionRequired
            }
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        guard let merged = components.url else { throw ConnectionFailure.validationFailed }
        return merged
    }

    public static func jsonBody(_ parameters: [String: String]) throws -> Data {
        if parameters.isEmpty { return Data("{}".utf8) }
        return try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
    }

    public static func canonicalParameters(_ parameters: [String: String]) -> String {
        let keys = parameters.keys.sorted()
        let pairs = keys.map { "\(escape($0))=\(escape(parameters[$0] ?? ""))" }
        return pairs.joined(separator: "&")
    }

    public static func shouldRetry(write: Bool, idempotent: Bool) -> Bool {
        if write && !idempotent { return false }
        return true
    }

    public static func backoffSeconds(attempt: Int, jitter: Double) -> Double {
        let exp = min(Double(ConnectionBounds.backoffCapSeconds), pow(2.0, Double(max(attempt, 0))))
        let scaled = exp * (0.5 + min(max(jitter, 0), 1) * 0.5)
        return min(Double(ConnectionBounds.backoffCapSeconds), scaled)
    }

    public static func isStale(lastSuccess: Date?, maxAgeSeconds: Int?, now: Date) -> Bool {
        let maxAge = maxAgeSeconds ?? (RuntimeBounds.minPollSeconds * 2 + RuntimeBounds.httpTimeoutSeconds)
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > Double(maxAge)
    }

    private static func assertDestinationAllowed(
        grant: ConnectionGrant,
        originHost: String,
        destinationClass: AddressClass
    ) throws {
        if destinationClass == .metadata || destinationClass == .invalid {
            throw ConnectionFailure.deniedEgress
        }
        let originClass = AddressClassifier.classify(host: originHost)
        if originClass == .metadata || originClass == .invalid {
            throw ConnectionFailure.deniedEgress
        }
        if destinationClass == .loopback || originClass == .loopback {
            if grant.lan && grant.allowInsecureHTTP && AddressClassifier.isLoopbackLiteral(originHost) {
                return
            }
            throw ConnectionFailure.deniedEgress
        }
        if destinationClass == .linkLocal || originClass == .linkLocal {
            throw ConnectionFailure.deniedEgress
        }
        if destinationClass == .privateLAN || originClass == .privateLAN {
            if grant.lan == false {
                throw ConnectionFailure.deniedEgress
            }
        }
        let insecure = grant.origin.hasPrefix("http://")
        if insecure && grant.allowInsecureHTTP == false {
            throw ConnectionFailure.deniedEgress
        }
    }

    private static func transportScheme(grant: ConnectionGrant, originScheme: String) throws -> String {
        switch grant.transport {
        case .http:
            return originScheme
        case .ws:
            if originScheme == "https" { return "wss" }
            if originScheme == "http" { return "ws" }
            throw ConnectionFailure.deniedEgress
        }
    }

    private static func splitOrigin(_ origin: String) throws -> (scheme: String, host: String, port: Int?) {
        guard let url = URL(string: origin), let scheme = url.scheme, let host = url.host else {
            throw ConnectionFailure.validationFailed
        }
        return (scheme.lowercased(), host, url.port)
    }

    private static func composeURL(scheme: String, host: String, port: Int?, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        let split = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.percentEncodedPath = String(split[0])
        if split.count == 2 {
            components.percentEncodedQuery = String(split[1])
        }
        guard let url = components.url else { throw ConnectionFailure.validationFailed }
        return url
    }

    private static func assertSameOrigin(url: URL, scheme: String, host: String, port: Int?) throws {
        guard url.scheme?.lowercased() == scheme, url.host == host else {
            throw ConnectionFailure.deniedEgress
        }
        if url.port != port {
            throw ConnectionFailure.deniedEgress
        }
        if url.user != nil || url.password != nil {
            throw ConnectionFailure.deniedEgress
        }
    }

    private static func encodedSize(_ parameters: [String: String]) -> Int {
        (try? jsonBody(parameters).count) ?? Int.max
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "%26").replacingOccurrences(of: "=", with: "%3D")
    }
}

public enum ConnectionAuth {
    public static func apply(
        binding: ConnectionAuthBinding,
        secret: Data?,
        headers: inout [String: String],
        url: inout URL
    ) throws {
        switch binding.placement {
        case .none:
            return
        case .bearer:
            guard let secret, let token = String(data: secret, encoding: .utf8), token.isEmpty == false else {
                throw ConnectionFailure.permissionRequired
            }
            if headers.keys.contains(where: { $0.lowercased() == "authorization" }) {
                throw ConnectionFailure.permissionRequired
            }
            headers["Authorization"] = "Bearer \(token)"
        case .header:
            guard let name = binding.fieldName, name.isEmpty == false else {
                throw ConnectionFailure.validationFailed
            }
            if ConnectionAuthKeys.isDestination(name) {
                throw ConnectionFailure.validationFailed
            }
            guard let secret, let value = String(data: secret, encoding: .utf8), value.isEmpty == false else {
                throw ConnectionFailure.permissionRequired
            }
            if headers.keys.contains(where: { $0.lowercased() == name.lowercased() }) {
                throw ConnectionFailure.permissionRequired
            }
            headers[name] = value
        case .query:
            guard let name = binding.fieldName, name.isEmpty == false else {
                throw ConnectionFailure.validationFailed
            }
            guard let secret, let value = String(data: secret, encoding: .utf8), value.isEmpty == false else {
                throw ConnectionFailure.permissionRequired
            }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw ConnectionFailure.validationFailed
            }
            var items = components.queryItems ?? []
            if items.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                throw ConnectionFailure.permissionRequired
            }
            items.append(URLQueryItem(name: name, value: value))
            components.queryItems = items
            guard let next = components.url else { throw ConnectionFailure.validationFailed }
            url = next
        }
    }
}

public enum ConnectionRedaction {
    private static let secretQueryKeys: Set<String> = [
        "access_token", "api_key", "apikey", "token", "password", "auth", "authorization", "key", "secret"
    ]

    public static func hostLabel(origin: String, lan: Bool) -> String {
        let host = (try? ConnectionPolicy.originHost(origin)) ?? "unknown"
        let prefix = lan ? "lan" : "public"
        return "\(prefix):\(host)"
    }

    public static func redact(url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "redacted"
        }
        components.user = nil
        components.password = nil
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                if secretQueryKeys.contains(item.name.lowercased()) {
                    return URLQueryItem(name: item.name, value: "redacted")
                }
                return item
            }
        }
        return components.string ?? "redacted"
    }

    public static func diagnostic(
        operation: String,
        status: Int,
        origin: String,
        lan: Bool,
        at: Date
    ) -> String {
        "op=\(operation) status=\(status) host=\(hostLabel(origin: origin, lan: lan)) ts=\(Int(at.timeIntervalSince1970))"
    }
}

public enum TransportExceptions: Sendable {
    public static let globalArbitraryLoads = false
    public static let selfSignedHTTPSTrustedSilently = false
    public static let followsRedirects = false
    public static let macIsRuntimeProxy = false
    public static let requiresLocalNetworkingOrPerHostException = true
}
