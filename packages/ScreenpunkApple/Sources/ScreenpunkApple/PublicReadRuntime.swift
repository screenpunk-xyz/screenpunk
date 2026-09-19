import Foundation
import ImageIO
import ScreenpunkCore

public struct PublicReadResult: Sendable {
    public var state: String
    public var body: Data?
    public var mime: String?
    public var fetchedAt: Date?
    public var lastModified: String?
    public var status: Int
    public var retryAfter: Double?
    public var code: String?
}

/// Each instance belongs to one screen and revision. Encoded images are retained only in
/// a bounded memory cache; there is no disk cache, cookie jar, credential lookup or URL cache.
public actor PublicReadRuntime {
    public static let cacheBytes = 24 * 1024 * 1024
    private let provisioning: PublicReadProvisioning
    private let runtime: ConnectionRuntime
    private let isCurrent: @Sendable () -> Bool
    private let clock: any PairingClock
    private var cache: [String: Entry] = [:]
    private var pending: [String: Task<PublicReadResult, Error>] = [:]
    private var waiters: [String: Set<UUID>] = [:]
    private var nextOrigin: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var epoch = 0
    private struct Entry { var result: PublicReadResult; var used: Date }
    public init(provisioning: PublicReadProvisioning, transport: any HTTPTransport = HomeAssistantHTTPTransport(),
                resolver: any DestinationResolver = LiteralOrResolvedDestinationResolver(), clock: any PairingClock = SystemClock(), isCurrent: @escaping @Sendable () -> Bool = { true }) throws {
        try provisioning.validate()
        self.provisioning = provisioning; self.isCurrent = isCurrent; self.clock = clock
        runtime = ConnectionRuntime(dashboardId: provisioning.dashboardId, store: MemoryCredentialStore(), http: transport,
                                    webSocket: PublicReadNoSocket(), resolver: resolver)
    }
    public func cancel() {
        epoch += 1
        for task in pending.values { task.cancel() }
        pending.removeAll(); waiters.removeAll(); cache.removeAll(); nextOrigin.removeAll(); failures.removeAll()
    }
    public func request(alias: String, operation: String, parameters: [String: String]) async throws -> PublicReadResult {
        guard isCurrent(), let declaration = provisioning.connections.first(where: { $0.alias == alias })?.publicHTTP,
              let spec = declaration.operations.first(where: { $0.name == operation }) else { throw ConnectionFailure.permissionRequired }
        let (grant, query) = try declaration.grant(alias: alias, operation: spec, parameters: parameters)
        let key = alias + ":" + operation + ":" + ConnectionPolicy.canonicalParameters(parameters)
        let now = clock.now
        if var existing = cache[key], let fetched = existing.result.fetchedAt,
           now.timeIntervalSince(fetched) <= Double(spec.maxAgeSeconds) {
            existing.used = now; cache[key] = existing; return existing.result
        }
        let started = epoch
        let task: Task<PublicReadResult, Error>
        if let existing = pending[key] { task = existing }
        else {
            if let next = nextOrigin[declaration.origin], next > now {
                return fallback(key: key, spec: spec, status: 429, code: "throttled", retryAfter: next.timeIntervalSince(now))
            }
            guard pending.count < 4 else { return fallback(key: key, spec: spec, status: 0, code: "busy", retryAfter: 0.25) }
            nextOrigin[declaration.origin] = now.addingTimeInterval(0.1)
            task = Task { [runtime, clock] in
                let response = try await runtime.publicRead(grant: grant, parameters: query, userAgent: declaration.userAgent,
                    accept: spec.response == "raster" ? "image/png,image/jpeg" : "application/geo+json,application/json",
                    maxBytes: spec.response == "raster" ? 4 * 1024 * 1024 : 1024 * 1024)
                try Task.checkCancellation()
                let headers = Dictionary(response.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, rhs in rhs })
                let retry = Self.retryAfter(headers["retry-after"], now: clock.now)
                if response.status == 204 || response.status == 404 {
                    return .init(state: "unavailable", fetchedAt: clock.now, status: response.status, code: "no_coverage")
                }
                guard (200...299).contains(response.status) else {
                    return .init(state: "error", status: response.status, retryAfter: retry, code: "http_error")
                }
                let mime = (headers["content-type"] ?? "").split(separator: ";").first.map(String.init)?.lowercased() ?? ""
                if spec.response == "raster" { try PublicRasterValidator.validate(response.body, mime: mime) }
                else {
                    guard mime == "application/json" || mime == "application/geo+json" else { throw ConnectionFailure.validationFailed }
                    _ = try JSONSerialization.jsonObject(with: response.body, options: .fragmentsAllowed)
                }
                return .init(state: "fresh", body: response.body, mime: mime, fetchedAt: clock.now,
                             lastModified: headers["last-modified"], status: response.status)
            }
            pending[key] = task
        }
        let waiter = UUID()
        waiters[key, default: []].insert(waiter)
        defer { waiters[key]?.remove(waiter); if waiters[key]?.isEmpty == true { waiters.removeValue(forKey: key) } }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
                Task { await self.cancelWaiter(key: key, waiter: waiter) }
            })
            guard started == epoch, isCurrent() else { throw ConnectionFailure.permissionRequired }
            try Task.checkCancellation()
            pending.removeValue(forKey: key)
            if result.state == "error" {
                let count = min(10, (failures[declaration.origin] ?? 0) + 1); failures[declaration.origin] = count
                let delay = result.retryAfter ?? min(300, pow(2, Double(count)))
                nextOrigin[declaration.origin] = clock.now.addingTimeInterval(delay)
                return fallback(key: key, spec: spec, status: result.status, code: result.code, retryAfter: delay)
            }
            failures[declaration.origin] = 0
            cache[key] = Entry(result: result, used: clock.now); trim()
            return result
        } catch {
            if started == epoch { pending.removeValue(forKey: key) }
            guard started == epoch, isCurrent() else { throw ConnectionFailure.permissionRequired }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let count = min(10, (failures[declaration.origin] ?? 0) + 1); failures[declaration.origin] = count
            let delay = min(300, pow(2, Double(count)))
            nextOrigin[declaration.origin] = clock.now.addingTimeInterval(delay)
            return fallback(key: key, spec: spec, status: 0, code: (error as? ConnectionFailure)?.rawValue ?? "offline", retryAfter: delay)
        }
    }
    private static func retryAfter(_ value: String?, now: Date) -> Double? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite { return min(3600, max(1, seconds)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { min(3600, max(1, $0.timeIntervalSince(now))) }
    }
    private func cancelWaiter(key: String, waiter: UUID) {
        waiters[key]?.remove(waiter)
        if waiters[key]?.isEmpty == true { pending[key]?.cancel() }
    }
    private func fallback(key: String, spec: PublicReadOperation, status: Int, code: String?, retryAfter: Double?) -> PublicReadResult {
        if let entry = cache[key], let fetched = entry.result.fetchedAt,
           clock.now.timeIntervalSince(fetched) <= Double(spec.maxAgeSeconds + spec.staleSeconds), entry.result.body != nil {
            var result = entry.result; result.state = "stale"; result.status = status; result.code = code; result.retryAfter = retryAfter
            return result
        }
        return .init(state: "error", status: status, retryAfter: retryAfter, code: code)
    }
    private func trim() {
        while cache.count > 96 || cache.values.reduce(0, { $0 + ($1.result.body?.count ?? 0) }) > Self.cacheBytes {
            guard let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key else { break }
            cache.removeValue(forKey: oldest)
        }
    }
}

public enum PublicRasterValidator {
    @discardableResult
    public static func validate(_ data: Data, mime: String) throws -> Int {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw ConnectionFailure.sizeLimit }
        let png = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        let jpeg = data.starts(with: [255, 216, 255])
        guard (mime == "image/png" && png) || (mime == "image/jpeg" && jpeg),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ConnectionFailure.validationFailed }
        guard width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 4_194_304 else { throw ConnectionFailure.sizeLimit }
        guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { throw ConnectionFailure.validationFailed }
        return width * height
    }
}
private struct PublicReadNoSocket: WebSocketTransport {
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession { throw ConnectionFailure.permissionRequired }
}
