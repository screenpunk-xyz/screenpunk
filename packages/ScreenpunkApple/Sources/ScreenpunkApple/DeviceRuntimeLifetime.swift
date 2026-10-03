import Foundation
import SwiftUI

/// One terminal host/root generation. Retirement never authorizes a replacement generation.
@MainActor public final class DeviceRuntimeLifetime {
    public nonisolated let generation = UUID()
    public private(set) var isRetired = false
    private var retirements: [UUID: () -> Void] = [:]
    public nonisolated init() {}

    public func retire() {
        guard !isRetired else { return }
        isRetired = true
        let actions = Array(retirements.values); retirements.removeAll()
        for action in actions { action() }
    }
    @discardableResult func register(_ action: @escaping () -> Void) -> UUID? {
        guard !isRetired else { action(); return nil }
        let id = UUID(); retirements[id] = action; return id
    }
    func unregister(_ id: UUID?) { if let id { retirements.removeValue(forKey: id) } }
    func guarded(_ action: @escaping () -> Void) -> () -> Void {
        { [weak self] in guard let self, !self.isRetired else { return }; action() }
    }
    func guarded<T>(_ action: @escaping (T) -> Void) -> (T) -> Void {
        { [weak self] value in guard let self, !self.isRetired else { return }; action(value) }
    }
    /// Captured work may ignore cancellation; only a current generation may publish its result.
    func accept<T>(operation: () async throws -> T, discard: (T) async -> Void) async throws -> T? {
        guard !isRetired, !Task.isCancelled else { return nil }
        let value = try await operation()
        guard !isRetired, !Task.isCancelled else { await discard(value); return nil }
        return value
    }
}

private struct DeviceRuntimeLifetimeKey: EnvironmentKey {
    static let defaultValue: DeviceRuntimeLifetime? = nil
}
extension EnvironmentValues {
    var deviceRuntimeLifetime: DeviceRuntimeLifetime? {
        get { self[DeviceRuntimeLifetimeKey.self] }
        set { self[DeviceRuntimeLifetimeKey.self] = newValue }
    }
}
