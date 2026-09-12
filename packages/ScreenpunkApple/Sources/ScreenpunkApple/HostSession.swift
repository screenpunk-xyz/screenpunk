import Foundation
import ScreenpunkCore

/// In-memory Apple host session. Unlink clears local package state immediately.
public struct HostSession: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case dashboard
        case unpaired
    }

    public var phase: Phase
    public var store: PackageAssetStore?

    public init(phase: Phase, store: PackageAssetStore? = nil) {
        self.phase = phase
        self.store = store
    }

    public static func offlineFixture() throws -> HostSession {
        HostSession(phase: .dashboard, store: try PackageAssetStore.bundledOfflineFixture())
    }

    /// Clears current/staged package bytes. Pairing and Keychain wipe land with M3.
    public mutating func unlink() {
        store = nil
        phase = .unpaired
    }
}
