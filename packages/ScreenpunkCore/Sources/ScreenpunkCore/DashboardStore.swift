import Foundation

public struct CacheRecord: Sendable, Equatable {
    public var valueJSON: String
    public var fetchedAt: Date
    public var stale: Bool
    public var write: Bool
}

public struct DashboardStore: Sendable {
    public let dashboardId: String
    private var state: [String: String] = [:]
    private var cache: [String: CacheRecord] = [:]
    private var bytes = 0

    public init(dashboardId: String) {
        self.dashboardId = dashboardId
    }

    public mutating func set(key: String, json: String) throws {
        try assertKey(key)
        let next = key.utf8.count + json.utf8.count
        let previous = state[key].map { key.utf8.count + $0.utf8.count } ?? 0
        try ensure(next - previous)
        state[key] = json
        bytes += next - previous
    }

    public func get(key: String) throws -> String? {
        try assertKey(key)
        return state[key]
    }

    public mutating func remove(key: String) throws {
        try assertKey(key)
        if let value = state.removeValue(forKey: key) {
            bytes -= key.utf8.count + value.utf8.count
        }
    }

    public mutating func rememberRead(cacheKey: String, json: String, fetchedAt: Date) throws {
        if cache[cacheKey]?.write == true {
            throw PackageValidationError(issues: [.validationFailed])
        }
        let next = cacheKey.utf8.count + json.utf8.count
        let previous = cache[cacheKey].map { cacheKey.utf8.count + $0.valueJSON.utf8.count } ?? 0
        try ensure(next - previous)
        cache[cacheKey] = CacheRecord(valueJSON: json, fetchedAt: fetchedAt, stale: false, write: false)
        bytes += next - previous
    }

    public var usedBytes: Int { bytes }

    public static func cacheKey(alias: String, operation: String, parametersJSON: String) -> String {
        "\(alias)\u{001f}\(operation)\u{001f}\(parametersJSON)"
    }

    private func assertKey(_ key: String) throws {
        if key.isEmpty || key.utf8.count > 256 {
            throw PackageValidationError(issues: [.validationFailed])
        }
    }

    private func ensure(_ delta: Int) throws {
        if bytes + delta > RuntimeBounds.stateCacheBytes {
            throw PackageValidationError(issues: [.sizeLimit])
        }
    }
}
