import Foundation
import ScreenpunkCore
#if os(macOS)
import Darwin

enum WorkbenchAuthorityError: Error, Equatable {
    case invalidState, staleContext, missingBinding, intentExpired, intentResolved, unsupportedCapability, remoteOutcomeUnknown
    case credentialCleanupRequired
    case intentCapacity
}

struct WorkbenchDeviceEpoch: Codable, Equatable {
    var peerPin: String
    var pairingEpoch: String
}

struct WorkbenchConnectionBinding: Codable, Equatable {
    var bindingId: String
    var deviceId: String
    var dashboardId: String
    var revision: String
    var grant: ConnectionGrant
    var auth: ConnectionAuthBinding
    var endpointIdentityHash: String
    var grantScopeHash: String
    var grantGeneration: Int
    var revocationGeneration: Int
    var credentialGeneration: Int
    var active: Bool
}

struct WorkbenchConnectionIntent: Codable, Equatable {
    enum State: String, Codable { case credentialPending, pending, sending, denied, approved, rejected, uncertain }
    var intentId: String
    var deviceId: String
    var dashboardId: String
    var revision: String
    var grant: ConnectionGrant
    var auth: ConnectionAuthBinding
    var declarationHash: String
    var proposalScopeHash: String? = nil
    var authorizationContextHash: String
    var credentialGeneration: Int
    var expiresAt: Date
    var state: State
    var managedSecret: Bool? = nil
    var ordinaryProposal: Bool? = nil
}

struct WorkbenchLocalAuthorityState: Codable {
    var schemaVersion = 1
    var controllerPin: String?
    var controllerIdentityEpoch = UUID().uuidString.lowercased()
    var devices: [String: WorkbenchDeviceEpoch] = [:]
    var connections: [String: WorkbenchConnectionBinding] = [:]
    var credentialGenerations: [String: Int] = [:]
    var intents: [String: WorkbenchConnectionIntent] = [:]

    mutating func synchronizeController(_ identity: PairingIdentity) throws {
        guard identity.role == .controller, identity.isWellFormed else { throw WorkbenchAuthorityError.invalidState }
        let pin = PeerPin.hex(identity.publicKey)
        if controllerPin != pin {
            controllerPin = pin
            controllerIdentityEpoch = UUID().uuidString.lowercased()
            devices.removeAll(); connections.removeAll(); intents.removeAll()
        }
    }
    mutating func paired(deviceId: String, peerPin: String) throws {
        guard PeerPin.parseHex(peerPin)?.count == PairingLimits.identityByteCount else { throw WorkbenchAuthorityError.invalidState }
        devices[deviceId] = .init(peerPin: peerPin, pairingEpoch: UUID().uuidString.lowercased())
        connections = connections.filter { $0.value.deviceId != deviceId }
        intents = intents.filter { $0.value.deviceId != deviceId }
    }
    mutating func forgot(deviceId: String) {
        devices[deviceId] = nil
        connections = connections.filter { $0.value.deviceId != deviceId }
        intents = intents.filter { $0.value.deviceId != deviceId }
    }
}

/// This is reconstructable machine-local authority bookkeeping, never part of
/// the visible workspace. The closed one-file state uses descriptor-anchored
/// private IO and a retained kernel lock; no secret bytes are serialized.
final class WorkbenchLocalAuthorityStore {
    private let root: WorkspaceFiles
    init(path: String) throws {
        do { root = try WorkspaceFiles(path: path, create: true) }
        catch WorkspaceError.alreadyExists { root = try WorkspaceFiles(path: path) }
    }
    func read() throws -> WorkbenchLocalAuthorityState {
        try root.locked { try load() }
    }
    func update<T>(_ body: (inout WorkbenchLocalAuthorityState) throws -> T) throws -> T {
        try root.locked {
            var state = try load()
            let value = try body(&state)
            guard state.schemaVersion == 1, state.devices.count <= 128,
                  state.connections.count <= 512, state.credentialGenerations.count <= 512,
                  state.intents.count <= 512 else { throw WorkbenchAuthorityError.invalidState }
            let data = try JSONEncoder().encode(state)
            guard data.count <= 2 * 1024 * 1024 else { throw WorkbenchAuthorityError.invalidState }
            let expected = try root.exists(root.fd, "authority.json")
                ? WorkspaceNodeID(root.metadata(root.fd, "authority.json")) : nil
            try root.write(root.fd, "authority.json", data: data, expected: expected)
            return value
        }
    }
    private func load() throws -> WorkbenchLocalAuthorityState {
        guard try root.exists(root.fd, "authority.json") else { return .init() }
        let data = try root.read(root.fd, "authority.json", maxBytes: 2 * 1024 * 1024)
        let state = try JSONDecoder().decode(WorkbenchLocalAuthorityState.self, from: data)
        guard state.schemaVersion == 1, state.devices.count <= 128,
              state.connections.count <= 512, state.credentialGenerations.count <= 512,
              state.intents.count <= 512 else { throw WorkbenchAuthorityError.invalidState }
        return state
    }
}
#endif
