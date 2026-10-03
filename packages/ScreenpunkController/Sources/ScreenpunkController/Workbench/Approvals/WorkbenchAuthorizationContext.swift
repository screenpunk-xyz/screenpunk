import Foundation
import ScreenpunkCore
#if os(macOS)

/// Local epochs are never read from the portable workspace. They are compared
/// with the current native owner and selected root before a context is issued.
enum WorkbenchAuthorizationContext {
    static func hash(state: WorkbenchLocalAuthorityState, workspace: WorkspaceStore,
                     devices: DeviceCoordinator, deviceId: String,
                     bindingIds: [String]? = nil) throws -> String {
        guard let owner = devices.controllerIdentity, owner.role == .controller,
              state.controllerPin == PeerPin.hex(owner.publicKey),
              let record = devices.directory.get(deviceId), record.device.owner == owner,
              let pairing = state.devices[deviceId], pairing.peerPin == record.devicePinHex,
              let selected = try workspace.selection.current(),
              let overview = try workspace.current(), overview.path == selected.activePath,
              overview.descriptor.workspaceId == selected.workspaceId else {
            throw WorkbenchAuthorityError.staleContext
        }
        let chosen: [WorkbenchConnectionBinding]
        if let bindingIds {
            guard bindingIds.count <= 128, Set(bindingIds).count == bindingIds.count else {
                throw WorkbenchAuthorityError.invalidState
            }
            chosen = try bindingIds.map { id in
                guard let binding = state.connections[id], binding.active, binding.deviceId == deviceId else {
                    throw WorkbenchAuthorityError.missingBinding
                }
                return binding
            }
        } else {
            chosen = state.connections.values.filter { $0.active && $0.deviceId == deviceId }
        }
        let services: [[String: Any]] = chosen.sorted { $0.bindingId.utf8.lexicographicallyPrecedes($1.bindingId.utf8) }
            .map { binding in
                ["bindingId": binding.bindingId,
                 "endpointIdentityHash": binding.endpointIdentityHash,
                 "grantScopeHash": binding.grantScopeHash,
                 "grantGeneration": binding.grantGeneration,
                 "revocationGeneration": binding.revocationGeneration,
                 "credentialGeneration": binding.credentialGeneration]
            }
        return try ToolchainCanonical.hash(domain: "authorization-context", value: [
            "contextVersion": 1,
            "controllerIdentityEpoch": state.controllerIdentityEpoch,
            "target": ["deviceId": deviceId, "peerPin": pairing.peerPin, "pairingEpoch": pairing.pairingEpoch],
            "workspace": ["workspaceId": selected.workspaceId, "localBindingId": selected.bindingId,
                          "selectionGeneration": selected.selectionGeneration],
            "services": services
        ])
    }
    static func declarationHash(grant: ConnectionGrant, auth: ConnectionAuthBinding,
                                dashboardId: String, revision: String) throws -> String {
        let grantObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant))
        let authObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth))
        return try ToolchainCanonical.hash(domain: "grant-scope", value: [
            "dashboardId": dashboardId, "revision": revision,
            "grant": grantObject, "authentication": authObject
        ])
    }
    static func endpointHash(grant: ConnectionGrant) throws -> String {
        try ToolchainCanonical.hash(domain: "endpoint-identity", value: [
            "origin": grant.origin, "transport": grant.transport.rawValue
        ])
    }
}
#endif
