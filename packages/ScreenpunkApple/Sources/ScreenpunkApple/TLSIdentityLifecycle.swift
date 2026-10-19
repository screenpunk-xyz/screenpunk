import Foundation
import ScreenpunkCore

/// The backend must return nil only for confirmed absence in its identity scope.
/// All inaccessible or malformed material must throw instead.
protocol TLSIdentityStore {
    associatedtype Material
    func load(role: PairingRole, tag: String) throws -> Material?
    func create(role: PairingRole, tag: String) throws -> Material
}

enum TLSIdentityLifecycle {
    static func loadOrCreate<Store: TLSIdentityStore>(
        role: PairingRole, tag: String, store: Store
    ) throws -> Store.Material {
        if let existing = try store.load(role: role, tag: tag) { return existing }
        return try store.create(role: role, tag: tag)
    }
}

public enum TLSIdentityLoadError: Error, Equatable, Sendable {
    case keychain(status: Int32)
    case corruptMaterial
}
