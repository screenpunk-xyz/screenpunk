import Foundation
import ScreenpunkCore
#if os(macOS)

public protocol WorkbenchSecretProvider {
    /// The host supplies a trusted local Keychain-backed implementation. Never serialize values in workspace or authority state.
    func install(_ secret: Data, for authRef: String) throws
    func load(authRef: String) throws -> Data
    func remove(authRef: String) throws
}

public struct WorkbenchUnavailableSecretProvider: WorkbenchSecretProvider {
    public init() {}
    public func install(_ secret: Data, for authRef: String) throws { throw WorkbenchAuthorityError.unsupportedCapability }
    public func load(authRef: String) throws -> Data { throw WorkbenchAuthorityError.unsupportedCapability }
    public func remove(authRef: String) throws { throw WorkbenchAuthorityError.unsupportedCapability }
}

/// Only broker host code in this module can mint one. A JSON role, client name,
/// TTY claim or MCP field can never construct this capability.
public struct WorkbenchTrustedLocalCapability {
    fileprivate init() {}
    static func hostTerminalOrGUI() -> Self { .init() }
}

public struct WorkbenchConnectionOperationView: Codable, Sendable, Equatable {
    public let name: String
    public let method: String
    public let address: String
    public let writes: Bool
}
public struct WorkbenchConnectionSummary: Codable, Sendable, Equatable {
    public let bindingId: String
    public let deviceId: String
    public let dashboardId: String
    public let revision: String
    public let alias: String
    public let origin: String
    public let transport: String
    public let operations: [WorkbenchConnectionOperationView]
    public let authenticationPlacement: String
    public let authenticationField: String?
    public let redirectPolicy: String
    public let maximumResponseBytes: Int
    public let timeoutSeconds: Int
    public let grantGeneration: Int
    public let localStatus: String
    public let remoteRevocation: String

    init(bindingId: String, deviceId: String, dashboardId: String, revision: String,
         grant: ConnectionGrant, auth: ConnectionAuthBinding, localStatus: String,
         grantGeneration: Int = 0,
         remoteRevocation: String = "not_requested") {
        self.bindingId = bindingId; self.deviceId = deviceId; self.dashboardId = dashboardId; self.revision = revision
        alias = grant.alias; origin = ConnectionRedaction.hostLabel(origin: grant.origin, lan: grant.lan)
        transport = grant.transport.rawValue
        operations = grant.operations.map { operation in
            let address = WorkbenchConnectionReviewScope.address(origin: grant.origin,
                path: operation.path) ?? "unreviewable-query"
            return .init(name: operation.name, method: operation.method.rawValue,
                         address: address, writes: operation.write)
        }
        authenticationPlacement = auth.placement.rawValue; authenticationField = auth.fieldName
        redirectPolicy = "deny_cross_origin_and_downgrade"
        maximumResponseBytes = ConnectionBounds.httpResponseBytes
        timeoutSeconds = ConnectionBounds.httpTimeoutSeconds
        self.grantGeneration = grantGeneration
        self.localStatus = localStatus; self.remoteRevocation = remoteRevocation
    }
}

/// Editable, nonsecret projection of the current machine-local grant. Empty
/// auth references are required by connection.update; the broker restores its
/// private reference only after it verifies the unchanged endpoint and auth mode.
public struct WorkbenchConnectionScopeDraft: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let bindingId: String
    public let deviceId: String
    public let dashboardId: String
    public let revision: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let expectedGrantGeneration: Int
    public let authorizationContextHash: String
    public let grant: ConnectionGrant
    public let auth: ConnectionAuthBinding

    func validate() throws {
        guard schemaVersion == 1, WorkspaceValidation.id(bindingId),
              WorkspaceValidation.id(deviceId), WorkspaceValidation.id(dashboardId),
              WorkspaceValidation.id(revision), WorkspaceValidation.id(workspaceId),
              selectionGeneration > 0, expectedGrantGeneration > 0,
              grant.id.uuidString.lowercased() == bindingId,
              grant.authRef.isEmpty, auth.authRef.isEmpty,
              authorizationContextHash.count == 64,
              authorizationContextHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              WorkbenchConnectionReviewScope.draftCanExpose(grant) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}

private enum WorkbenchConnectionReviewScope {
    /// Only known nonsecret selectors are displayed with values. Credential
    /// fields are redacted; unknown keys make the declaration unreviewable.
    private static let selectors: Set<String> = [
        "target", "view", "scope", "device", "entity", "area", "room", "mode",
        "resource", "filter", "name", "state", "zone", "group"
    ]
    private static let credentials: Set<String> = [
        "access_token", "api_key", "apikey", "token", "password", "auth",
        "authorization", "key", "secret", "client_secret", "access_key",
        "signature", "credential", "session", "private_key"
    ]

    static func address(origin: String, path: String) -> String? {
        guard var components = URLComponents(string: origin + path),
              components.scheme != nil, components.host != nil else { return nil }
        components.user = nil; components.password = nil
        if let items = components.queryItems {
            var rendered: [URLQueryItem] = []
            for item in items {
                let key = item.name.lowercased()
                if credentials.contains(key) {
                    rendered.append(URLQueryItem(name: item.name, value: item.value == nil ? nil : "REDACTED"))
                } else if selectors.contains(key),
                          item.name.utf8.count <= 64,
                          item.value.map({ value in
                              value.utf8.count <= 128 && value.utf8.allSatisfy {
                                  (48...57).contains($0) || (65...90).contains($0) ||
                                  (97...122).contains($0) || [45, 46, 95, 126, 46].contains($0)
                              }
                          }) ?? true {
                    rendered.append(item)
                } else { return nil }
            }
            components.queryItems = rendered
        }
        return components.url?.absoluteString
    }

    static func validate(_ grant: ConnectionGrant) throws {
        guard grant.operations.allSatisfy({ address(origin: grant.origin, path: $0.path) != nil }) else {
            throw WorkbenchAuthorityError.invalidState
        }
    }

    static func draftCanExpose(_ grant: ConnectionGrant) -> Bool {
        grant.operations.allSatisfy { operation in
            guard let components = URLComponents(string: grant.origin + operation.path) else {
                return false
            }
            guard let items = components.queryItems else { return true }
            return items.allSatisfy { !credentials.contains($0.name.lowercased()) }
        }
    }
}
public struct WorkbenchConnectionIntentView: Codable, Sendable, Equatable {
    public let intentId: String
    public let declarationHash: String
    public let proposalScopeHash: String?
    public let authorizationContextHash: String
    public let expiresAt: Date
    public let state: String
    public let summary: WorkbenchConnectionSummary
}
public struct WorkbenchConnectionApplyResult: Codable, Sendable, Equatable {
    public let summary: WorkbenchConnectionSummary
    public let receipt: ConnectionProvisioningReceipt
    public let authorizationContextHash: String
}

/// Reuses the paired owner channel and core grant validator. It does not issue
/// package/deployment approval, execute screen operations or claim upstream
/// credential revocation. The broker must call this on its serial domain queue.
public final class WorkbenchConnectionDomain {
    private let devices: DeviceCoordinator
    private let workspace: WorkspaceStore
    private let authority: WorkbenchLocalAuthorityStore
    private let secrets: any WorkbenchSecretProvider
    private let now: () -> Date
    let authorityBoundary = WorkbenchAuthorityBoundary()
    private var serial: NSRecursiveLock { authorityBoundary.lock }

    public init(machineAuthorityPath: String, devices: DeviceCoordinator, workspace: WorkspaceStore,
                secrets: any WorkbenchSecretProvider = WorkbenchUnavailableSecretProvider(),
                now: @escaping () -> Date = { Date() }) throws {
        self.devices = devices; self.workspace = workspace; self.secrets = secrets; self.now = now
        authority = try WorkbenchLocalAuthorityStore(path: machineAuthorityPath)
        if let owner = devices.controllerIdentity {
            try authority.update { state in
                try state.synchronizeController(owner)
                for record in devices.listDevices() where record.device.owner == owner {
                    if state.devices[record.id]?.peerPin != record.devicePinHex {
                        try state.paired(deviceId: record.id, peerPin: record.devicePinHex)
                    }
                }
            }
        }
    }
    public func deviceDomain() -> WorkbenchDeviceDomain {
        WorkbenchDeviceDomain(devices: devices, authority: authority,
                              boundary: authorityBoundary, now: now)
    }
    public func capabilities() -> [String: String] {
        ["generic": devices.transportAvailable ? "owner_channel_present_device_support_unverified" : "transport_unavailable",
         "homeAssistant": "requires_trusted_native_validation_adapter",
         "googleTV": "dedicated_setup_unavailable_in_this_domain",
         "genericLiveTest": "unsupported_by_device_protocol",
         "screenshots": "separate_optional_legacy_capability"]
    }
    func homeAssistantAuthority(deviceId: String) throws
        -> (contextHash: String, ownerPin: String, devicePin: String, pairingEpoch: String) {
        serial.lock(); defer { serial.unlock() }
        let state = try authority.read()
        let hash = try WorkbenchAuthorizationContext.hash(state: state,
            workspace: workspace, devices: devices, deviceId: deviceId)
        guard let owner = state.controllerPin, let pairing = state.devices[deviceId] else {
            throw WorkbenchAuthorityError.staleContext
        }
        return (hash, owner, pairing.peerPin, pairing.pairingEpoch)
    }
    public func installSecret(authRef: String, secret: Data, capability: WorkbenchTrustedLocalCapability) throws {
        serial.lock(); defer { serial.unlock() }
        guard (1...8192).contains(secret.count), !authRef.isEmpty, authRef.utf8.count <= 128 else {
            throw ConnectionFailure.validationFailed
        }
        // Invalidate consent before the external secret-store effect. If the
        // install fails, an extra generation is safe; a changed secret with an
        // old generation would not be.
        try authority.update { state in
            let previous = state.credentialGenerations[authRef] ?? 0
            guard previous < WorkspaceValidation.maxUInt else { throw WorkbenchAuthorityError.invalidState }
            state.credentialGenerations[authRef] = previous + 1
            for id in state.connections.keys where state.connections[id]?.grant.authRef == authRef {
                guard state.connections[id]!.revocationGeneration < WorkspaceValidation.maxUInt else {
                    throw WorkbenchAuthorityError.invalidState
                }
                state.connections[id]!.active = false
                state.connections[id]!.revocationGeneration += 1
            }
        }
        try secrets.install(secret, for: authRef)
    }
    public func requestGenericIntent(deviceId: String, dashboardId: String, revision: String,
                                     grant: ConnectionGrant, auth: ConnectionAuthBinding,
                                     expiresIn: TimeInterval = 600) throws -> WorkbenchConnectionIntentView {
        let proposalScopeHash = try WorkbenchConnectionIntentAttestation.proposalScopeHash(
            deviceId: deviceId, dashboardId: dashboardId, revision: revision,
            grant: grant, auth: auth)
        return try requestGenericIntent(deviceId: deviceId, dashboardId: dashboardId, revision: revision,
            grant: grant, auth: auth, expiresIn: expiresIn, hostManagedSecret: false,
            ordinaryProposal: true, proposalScopeHash: proposalScopeHash)
    }

    /// The socket host supplies the original proposal before it replaces only
    /// the empty authRef with a broker-owned credential slot.
    func hostRequestGenericIntent(deviceId: String, dashboardId: String, revision: String,
                                  grant: ConnectionGrant, auth: ConnectionAuthBinding,
                                  originalGrant: ConnectionGrant,
                                  originalAuth: ConnectionAuthBinding) throws -> WorkbenchConnectionIntentView {
        var normalizedGrant = grant
        var normalizedAuth = auth
        normalizedGrant.authRef = ""; normalizedAuth.authRef = ""
        guard normalizedGrant == originalGrant, normalizedAuth == originalAuth,
              originalGrant.authRef.isEmpty, originalAuth.authRef.isEmpty else {
            throw WorkbenchAuthorityError.invalidState
        }
        let proposalScopeHash = try WorkbenchConnectionIntentAttestation.proposalScopeHash(
            deviceId: deviceId, dashboardId: dashboardId, revision: revision,
            grant: originalGrant, auth: originalAuth)
        return try requestGenericIntent(deviceId: deviceId, dashboardId: dashboardId,
            revision: revision, grant: grant, auth: auth, hostManagedSecret: false,
            ordinaryProposal: true, proposalScopeHash: proposalScopeHash)
    }

    /// Host configuration stages a validated, non-approvable intent before the
    /// first credential effect. Each host request uses a fresh authRef, so a
    /// failed or denied request cannot overwrite a working binding's secret.
    func hostConfigureGenericIntent(deviceId: String, dashboardId: String, revision: String,
                                    grant: ConnectionGrant, auth: ConnectionAuthBinding,
                                    secret: Data?) throws -> WorkbenchConnectionIntentView {
        serial.lock(); defer { serial.unlock() }
        guard (auth.placement == .none) == (secret == nil) else { throw ConnectionFailure.validationFailed }
        let state = try authority.read()
        let bindingId = grant.id.uuidString.lowercased()
        guard state.connections[bindingId] == nil,
              !state.intents.values.contains(where: { $0.grant.id == grant.id &&
                  [.credentialPending, .pending, .sending, .uncertain].contains($0.state) }) else {
            throw WorkbenchAuthorityError.invalidState
        }
        if auth.placement == .none {
            return try requestGenericIntent(deviceId: deviceId, dashboardId: dashboardId,
                revision: revision, grant: grant, auth: auth, ordinaryProposal: false)
        }
        guard let secret, (1...8192).contains(secret.count) else { throw ConnectionFailure.validationFailed }
        guard !state.connections.values.contains(where: { $0.auth.authRef == auth.authRef }),
              !state.intents.values.contains(where: { $0.auth.authRef == auth.authRef }) else {
            throw WorkbenchAuthorityError.invalidState
        }
        let staged = try requestGenericIntent(deviceId: deviceId, dashboardId: dashboardId,
            revision: revision, grant: grant, auth: auth, hostManagedSecret: true,
            ordinaryProposal: false)
        do {
            try installSecret(authRef: auth.authRef, secret: secret, capability: .hostTerminalOrGUI())
            return try authority.update { state in
                guard var intent = state.intents[staged.intentId], intent.state == .credentialPending,
                      now() < intent.expiresAt,
                      try WorkbenchAuthorizationContext.hash(state: state, workspace: workspace,
                          devices: devices, deviceId: deviceId) == intent.authorizationContextHash else {
                    throw WorkbenchAuthorityError.staleContext
                }
                intent.credentialGeneration = state.credentialGenerations[auth.authRef] ?? 0
                intent.state = .pending
                state.intents[staged.intentId] = intent
                return view(intent)
            }
        } catch {
            try? authority.update { state in
                if state.intents[staged.intentId]?.state == .credentialPending {
                    state.intents[staged.intentId]?.state = .rejected
                }
            }
            try cleanupManagedSecret(intentId: staged.intentId)
            throw error
        }
    }

    /// Replaces only the reviewed scope of an existing grant. The endpoint and
    /// credential reference stay fixed, so a failed or uncertain remote send
    /// leaves the working credential and local binding untouched. Credential
    /// rotation requires a separate transaction with durable old-secret cleanup.
    func hostUpdateGenericIntent(bindingId: String, expectedGrantGeneration: Int,
                                 grant proposedGrant: ConnectionGrant,
                                 auth proposedAuth: ConnectionAuthBinding,
                                 ordinaryProposal: Bool = false) throws
        -> WorkbenchConnectionIntentView {
        serial.lock(); defer { serial.unlock() }
        let state = try authority.read()
        guard let previous = state.connections[bindingId], previous.active,
              previous.grantGeneration == expectedGrantGeneration,
              previous.bindingId == proposedGrant.id.uuidString.lowercased(),
              previous.grant.origin == proposedGrant.origin,
              previous.grant.transport == proposedGrant.transport,
              previous.grant.lan == proposedGrant.lan,
              previous.grant.allowInsecureHTTP == proposedGrant.allowInsecureHTTP,
              previous.auth.placement == proposedAuth.placement,
              previous.auth.fieldName == proposedAuth.fieldName,
              (state.credentialGenerations[previous.auth.authRef] ?? 0) == previous.credentialGeneration,
              try WorkbenchAuthorizationContext.declarationHash(grant: previous.grant,
                  auth: previous.auth, dashboardId: previous.dashboardId,
                  revision: previous.revision) == previous.grantScopeHash,
              try WorkbenchAuthorizationContext.endpointHash(grant: previous.grant) == previous.endpointIdentityHash,
              !state.intents.values.contains(where: { $0.grant.id == proposedGrant.id &&
                  [.credentialPending, .pending, .sending, .uncertain].contains($0.state) }) else {
            throw WorkbenchAuthorityError.staleContext
        }
        var grant = proposedGrant
        var auth = proposedAuth
        grant.authRef = previous.auth.authRef
        auth.authRef = previous.auth.authRef
        return try requestGenericIntent(deviceId: previous.deviceId,
            dashboardId: previous.dashboardId, revision: previous.revision,
            grant: grant, auth: auth, ordinaryProposal: ordinaryProposal)
    }

    private func requestGenericIntent(deviceId: String, dashboardId: String, revision: String,
                                      grant: ConnectionGrant, auth: ConnectionAuthBinding,
                                      expiresIn: TimeInterval = 600,
                                      hostManagedSecret: Bool = false,
                                      ordinaryProposal: Bool,
                                      proposalScopeHash: String? = nil) throws -> WorkbenchConnectionIntentView {
        serial.lock(); defer { serial.unlock() }
        try validate(grant: grant, auth: auth, dashboardId: dashboardId, revision: revision)
        guard expiresIn > 0, expiresIn <= 600 else { throw WorkbenchAuthorityError.invalidState }
        let declaration = try WorkbenchAuthorizationContext.declarationHash(
            grant: grant, auth: auth, dashboardId: dashboardId, revision: revision)
        let intent = try authority.update { state -> WorkbenchConnectionIntent in
            // Expired pending proposals have no remaining authority. Keep
            // terminal outcomes for inspection until capacity pressure, and
            // always keep uncertain/sending records and managed secrets.
            state.intents = state.intents.filter { _, value in
                guard value.managedSecret != true else { return true }
                return ![.pending, .credentialPending].contains(value.state) || now() < value.expiresAt
            }
            if ordinaryProposal {
                guard state.intents.values.filter({ $0.ordinaryProposal != false &&
                    [.pending, .credentialPending, .sending, .uncertain].contains($0.state) }).count < 384 else {
                    throw WorkbenchAuthorityError.intentCapacity
                }
            }
            if hostManagedSecret {
                guard state.connections[grant.id.uuidString.lowercased()] == nil,
                      !state.intents.values.contains(where: { $0.auth.authRef == auth.authRef }) else {
                    throw WorkbenchAuthorityError.invalidState
                }
            }
            let context = try WorkbenchAuthorizationContext.hash(
                state: state, workspace: workspace, devices: devices, deviceId: deviceId)
            let value = WorkbenchConnectionIntent(intentId: UUID().uuidString.lowercased(), deviceId: deviceId,
                dashboardId: dashboardId, revision: revision, grant: grant, auth: auth,
                declarationHash: declaration, proposalScopeHash: proposalScopeHash,
                authorizationContextHash: context,
                credentialGeneration: state.credentialGenerations[auth.authRef] ?? 0,
                expiresAt: now().addingTimeInterval(expiresIn),
                state: hostManagedSecret ? .credentialPending : .pending,
                managedSecret: hostManagedSecret ? true : nil,
                ordinaryProposal: ordinaryProposal)
            state.intents[value.intentId] = value
            let byteLimit = ordinaryProposal ? 2 * 1024 * 1024 - 512 * 1024 : 2 * 1024 * 1024
            while true {
                let bytes = try JSONEncoder().encode(state).count
                if state.intents.count <= 512 && bytes <= byteLimit { break }
                let ordered = state.intents.values.sorted { $0.expiresAt == $1.expiresAt
                    ? $0.intentId < $1.intentId : $0.expiresAt < $1.expiresAt }
                // Reclaim terminal audit records only under pressure. Trusted
                // admission may additionally displace an ordinary pending
                // proposal, reserving both row and byte capacity.
                let terminal = ordered.first { $0.managedSecret != true &&
                    [.denied, .approved, .rejected].contains($0.state) }
                let displacedOrdinary = ordinaryProposal ? nil : ordered.first {
                    $0.ordinaryProposal != false && $0.managedSecret != true && $0.state == .pending
                }
                guard let candidate = terminal ?? displacedOrdinary else {
                    throw ordinaryProposal ? WorkbenchAuthorityError.intentCapacity : WorkbenchAuthorityError.invalidState
                }
                state.intents[candidate.intentId] = nil
            }
            return value
        }
        return view(intent)
    }
    public func inspectIntent(_ intentId: String) throws -> WorkbenchConnectionIntentView {
        serial.lock(); defer { serial.unlock() }
        guard var intent = try authority.read().intents[intentId] else { throw WorkbenchAuthorityError.invalidState }
        if intent.managedSecret == true && now() >= intent.expiresAt &&
           (intent.state == .pending || intent.state == .credentialPending) {
            intent = try authority.update { state in
                guard var value = state.intents[intentId] else { throw WorkbenchAuthorityError.invalidState }
                value.state = .rejected; state.intents[intentId] = value
                return value
            }
        }
        if intent.managedSecret == true && [.denied, .rejected].contains(intent.state) {
            try cleanupManagedSecret(intentId: intentId)
            intent = try authority.read().intents[intentId] ?? intent
        }
        return view(intent)
    }

    func makeLocalReview(intentId: String, handle: String) throws -> WorkbenchConnectionReview {
        serial.lock(); defer { serial.unlock() }
        let state = try authority.read()
        guard let intent = state.intents[intentId], intent.state == .pending,
              now() < intent.expiresAt,
              state.credentialGenerations[intent.auth.authRef] ?? 0 == intent.credentialGeneration,
              try WorkbenchAuthorizationContext.hash(state: state, workspace: workspace,
                  devices: devices, deviceId: intent.deviceId) == intent.authorizationContextHash,
              try WorkbenchAuthorizationContext.declarationHash(grant: intent.grant, auth: intent.auth,
                  dashboardId: intent.dashboardId, revision: intent.revision) == intent.declarationHash else {
            throw WorkbenchAuthorityError.staleContext
        }
        try WorkbenchConnectionReviewScope.validate(intent.grant)
        guard let url = URLComponents(string: intent.grant.origin),
              let scheme = url.scheme, let host = url.host else { throw WorkbenchAuthorityError.invalidState }
        let endpoint = scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
        let review = try WorkbenchConnectionReview(handle: handle, intent: intent, state: state,
            summary: view(intent).summary, endpoint: endpoint, reviewedAt: now())
        try review.validate()
        return review
    }

    func confirmLocalReview(_ review: WorkbenchConnectionReview) throws -> WorkbenchConnectionApplyResult {
        serial.lock(); defer { serial.unlock() }
        try review.validate()
        let state = try authority.read()
        guard now() < review.reviewExpiresAt,
              let intent = state.intents[review.intentId], intent.state == .pending,
              intent.expiresAt == review.intentExpiresAt,
              intent.declarationHash == review.declarationHash,
              intent.authorizationContextHash == review.authorizationContextHash,
              intent.credentialGeneration == review.credentialGeneration,
              state.controllerPin == review.ownerPin,
              state.controllerIdentityEpoch == review.ownerEpoch,
              state.devices[intent.deviceId]?.peerPin == review.devicePin,
              state.devices[intent.deviceId]?.pairingEpoch == review.pairingEpoch,
              state.connections[intent.grant.id.uuidString.lowercased()]?.grantGeneration ?? 0 == review.grantGeneration,
              view(intent).summary == review.summary,
              state.credentialGenerations[intent.auth.authRef] ?? 0 == review.credentialGeneration,
              try WorkbenchAuthorizationContext.hash(state: state, workspace: workspace,
                  devices: devices, deviceId: intent.deviceId) == review.authorizationContextHash else {
            throw WorkbenchAuthorityError.staleContext
        }
        guard let applied = try resolveGenericIntent(review.intentId, approve: true,
            capability: .hostTerminalOrGUI()) else { throw WorkbenchAuthorityError.intentResolved }
        return applied
    }
    func reapExpiredManagedIntents() throws {
        serial.lock(); defer { serial.unlock() }
        let candidates = try authority.read().intents.values.filter { intent in
            intent.managedSecret == true &&
                ([.denied, .rejected].contains(intent.state) ||
                 (now() >= intent.expiresAt && [.credentialPending, .pending].contains(intent.state)))
        }
        for intent in candidates {
            if [.credentialPending, .pending].contains(intent.state) {
                try authority.update { state in
                    guard state.intents[intent.intentId]?.managedSecret == true else { return }
                    state.intents[intent.intentId]?.state = .rejected
                }
            }
            try cleanupManagedSecret(intentId: intent.intentId)
        }
    }
    public func resolveGenericIntent(_ intentId: String, approve: Bool,
                                     capability: WorkbenchTrustedLocalCapability) throws -> WorkbenchConnectionApplyResult? {
        serial.lock(); defer { serial.unlock() }
        guard let intent = try authority.read().intents[intentId],
              intent.state == .pending || (!approve && intent.state == .credentialPending) else {
            throw WorkbenchAuthorityError.intentResolved
        }
        if !approve {
            try authority.update { state in
                guard [.pending, .credentialPending].contains(state.intents[intentId]?.state) else {
                    throw WorkbenchAuthorityError.intentResolved
                }
                state.intents[intentId]!.state = .denied
            }
            if intent.managedSecret == true { try cleanupManagedSecret(intentId: intentId) }
            return nil
        }
        guard now() < intent.expiresAt else {
            if intent.managedSecret == true {
                try authority.update { state in state.intents[intentId]?.state = .rejected }
                try cleanupManagedSecret(intentId: intentId)
            }
            throw WorkbenchAuthorityError.intentExpired
        }
        let current = try WorkbenchAuthorizationContext.hash(state: authority.read(), workspace: workspace,
                                                             devices: devices, deviceId: intent.deviceId)
        guard current == intent.authorizationContextHash,
              (try authority.read().credentialGenerations[intent.auth.authRef] ?? 0) == intent.credentialGeneration,
              try WorkbenchAuthorizationContext.declarationHash(grant: intent.grant, auth: intent.auth,
                  dashboardId: intent.dashboardId, revision: intent.revision) == intent.declarationHash else {
            throw WorkbenchAuthorityError.staleContext
        }
        let secret = intent.auth.placement == .none ? nil : try secrets.load(authRef: intent.auth.authRef)
        let provisioning = ConnectionProvisioning(dashboardId: intent.dashboardId, revision: intent.revision,
            provisioningId: intentId, entries: [.init(grant: intent.grant, binding: intent.auth, secret: secret)])
        try provisioning.validate()
        // A durable nonretryable state precedes the potentially accepted device call.
        try authority.update { state in
            guard state.intents[intentId]?.state == .pending else { throw WorkbenchAuthorityError.intentResolved }
            guard now() < intent.expiresAt,
                  state.credentialGenerations[intent.auth.authRef] ?? 0 == intent.credentialGeneration,
                  try WorkbenchAuthorizationContext.hash(state: state, workspace: workspace,
                      devices: devices, deviceId: intent.deviceId) == intent.authorizationContextHash else {
                throw WorkbenchAuthorityError.staleContext
            }
            state.intents[intentId]!.state = .sending
        }
        let receipt: ConnectionProvisioningReceipt
        do { receipt = try devices.provisionConnections(deviceId: intent.deviceId, configuration: provisioning) }
        catch {
            if let failure = error as? ControllerError, failure.code == .unsupportedVersion {
                try? authority.update { state in state.intents[intentId]?.state = .rejected }
                if intent.managedSecret == true { try cleanupManagedSecret(intentId: intentId) }
                throw error
            }
            try? authority.update { state in state.intents[intentId]?.state = .uncertain }
            throw WorkbenchAuthorityError.remoteOutcomeUnknown
        }
        let binding: WorkbenchConnectionBinding
        do { binding = try authority.update { state -> WorkbenchConnectionBinding in
            guard state.intents[intentId]?.state == .sending else { throw WorkbenchAuthorityError.staleContext }
            guard state.credentialGenerations[intent.auth.authRef] ?? 0 == intent.credentialGeneration,
                  try WorkbenchAuthorizationContext.hash(state: state, workspace: workspace,
                      devices: devices, deviceId: intent.deviceId) == intent.authorizationContextHash else {
                throw WorkbenchAuthorityError.staleContext
            }
            let id = intent.grant.id.uuidString.lowercased()
            let previous = state.connections[id]
            guard (previous?.grantGeneration ?? 0) < WorkspaceValidation.maxUInt else { throw WorkbenchAuthorityError.invalidState }
            let value = WorkbenchConnectionBinding(bindingId: id, deviceId: intent.deviceId,
                dashboardId: intent.dashboardId, revision: intent.revision, grant: intent.grant, auth: intent.auth,
                endpointIdentityHash: try WorkbenchAuthorizationContext.endpointHash(grant: intent.grant),
                grantScopeHash: intent.declarationHash,
                grantGeneration: (previous?.grantGeneration ?? 0) + 1,
                revocationGeneration: previous?.revocationGeneration ?? 0,
                credentialGeneration: state.credentialGenerations[intent.auth.authRef] ?? 0,
                active: true)
            state.connections[id] = value; state.intents[intentId]!.state = .approved
            state.intents[intentId]!.managedSecret = false
            return value
        } } catch {
            try? authority.update { state in state.intents[intentId]?.state = .uncertain }
            throw WorkbenchAuthorityError.remoteOutcomeUnknown
        }
        let updated = try WorkbenchAuthorizationContext.hash(state: authority.read(), workspace: workspace,
                                                             devices: devices, deviceId: intent.deviceId)
        return .init(summary: summary(binding, status: "provisioned"), receipt: receipt,
                     authorizationContextHash: updated)
    }
    public func inspect(bindingId: String) throws -> WorkbenchConnectionSummary {
        serial.lock(); defer { serial.unlock() }
        guard let value = try authority.read().connections[bindingId] else { throw WorkbenchAuthorityError.missingBinding }
        return summary(value, status: value.active ? "locally_authorized" : "locally_revoked")
    }
    func scopeDraft(bindingId: String, workspaceId: String,
                    selectionGeneration: Int) throws -> WorkbenchConnectionScopeDraft {
        serial.lock(); defer { serial.unlock() }
        let state = try authority.read()
        guard let binding = state.connections[bindingId], binding.active,
              binding.grantGeneration > 0,
              (state.credentialGenerations[binding.auth.authRef] ?? 0) == binding.credentialGeneration,
              let selected = try workspace.selection.current(),
              selected.workspaceId == workspaceId,
              selected.selectionGeneration == selectionGeneration,
              let overview = try workspace.current(),
              overview.path == selected.activePath,
              overview.descriptor.workspaceId == selected.workspaceId,
              try WorkbenchAuthorizationContext.declarationHash(grant: binding.grant,
                  auth: binding.auth, dashboardId: binding.dashboardId,
                  revision: binding.revision) == binding.grantScopeHash,
              try WorkbenchAuthorizationContext.endpointHash(grant: binding.grant) == binding.endpointIdentityHash,
              WorkbenchConnectionReviewScope.draftCanExpose(binding.grant) else {
            throw WorkbenchAuthorityError.staleContext
        }
        // A machine-local binding may outlive a workspace selection change.
        // The editable grant belongs only to its exact verified screen revision.
        guard (try? WorkbenchPortablePackages(workspace: workspace).get(
            dashboardId: binding.dashboardId, revision: binding.revision)) != nil else {
            throw WorkbenchAuthorityError.staleContext
        }
        let context = try WorkbenchAuthorizationContext.hash(state: state, workspace: workspace,
            devices: devices, deviceId: binding.deviceId)
        var grant = binding.grant
        var auth = binding.auth
        grant.authRef = ""
        auth.authRef = ""
        let draft = WorkbenchConnectionScopeDraft(schemaVersion: 1, bindingId: binding.bindingId,
            deviceId: binding.deviceId, dashboardId: binding.dashboardId,
            revision: binding.revision, workspaceId: workspaceId,
            selectionGeneration: selectionGeneration,
            expectedGrantGeneration: binding.grantGeneration,
            authorizationContextHash: context, grant: grant, auth: auth)
        try draft.validate()
        return draft
    }
    public func list(deviceId: String) throws -> [WorkbenchConnectionSummary] {
        serial.lock(); defer { serial.unlock() }
        return try authority.read().connections.values.filter { $0.deviceId == deviceId }
            .sorted { $0.bindingId < $1.bindingId }
            .map { summary($0, status: $0.active ? "locally_authorized" : "locally_revoked") }
    }
    public func inspectDeviceInventory(deviceId: String) throws -> DeviceConnectionInventory {
        serial.lock(); defer { serial.unlock() }
        return try devices.connectionInventory(deviceId: deviceId)
    }
    public func test(bindingId: String) throws -> WorkbenchConnectionSummary {
        serial.lock(); defer { serial.unlock() }
        // The existing owner protocol inventories configured connections; it
        // has no generic upstream probe, so this never claims endpoint health.
        let value = try inspect(bindingId: bindingId)
        _ = try devices.connectionInventory(deviceId: value.deviceId)
        guard let binding = try authority.read().connections[bindingId] else { throw WorkbenchAuthorityError.missingBinding }
        return summary(binding, status: "owner_channel_reachable_upstream_untested")
    }
    public func revoke(bindingId: String, capability: WorkbenchTrustedLocalCapability) throws -> WorkbenchConnectionSummary {
        serial.lock(); defer { serial.unlock() }
        let value = try authority.update { state -> WorkbenchConnectionBinding in
            guard var value = state.connections[bindingId], value.active else { throw WorkbenchAuthorityError.missingBinding }
            guard value.revocationGeneration < WorkspaceValidation.maxUInt else { throw WorkbenchAuthorityError.invalidState }
            value.active = false; value.revocationGeneration += 1
            state.connections[bindingId] = value
            return value
        }
        return summary(value, status: "locally_revoked", remoteRevocation: "best_effort_not_supported_for_generic_grants")
    }
    func removeLocal(bindingId: String, capability: WorkbenchTrustedLocalCapability) throws -> WorkbenchConnectionSummary {
        serial.lock(); defer { serial.unlock() }
        guard let current = try authority.read().connections[bindingId] else {
            throw WorkbenchAuthorityError.missingBinding
        }
        let result = current.active ? try revoke(bindingId: bindingId, capability: capability) :
            summary(current, status: "locally_revoked", remoteRevocation: "best_effort_not_supported_for_generic_grants")
        if current.auth.placement != .none {
            do { try secrets.remove(authRef: current.auth.authRef) }
            catch { throw WorkbenchAuthorityError.credentialCleanupRequired }
        }
        return result
    }
    public func authorizationContextHash(deviceId: String, bindingIds: [String]) throws -> String {
        serial.lock(); defer { serial.unlock() }
        return try WorkbenchAuthorizationContext.hash(state: authority.read(), workspace: workspace,
                                               devices: devices, deviceId: deviceId, bindingIds: bindingIds)
    }

    /// The package declaration is logical; only these current machine-local
    /// bindings can satisfy it. A prior revision can carry a grant forward
    /// only when its retained, verified declaration is exactly unchanged.
    func deploymentGrants(deviceId: String, requirements: [WorkbenchDeploymentGrantRequirement],
                          bindingIds: [String]) throws -> WorkbenchDeploymentGrantAssessment {
        serial.lock(); defer { serial.unlock() }
        guard bindingIds.count <= 32, Set(bindingIds).count == bindingIds.count else {
            throw WorkbenchAuthorityError.invalidState
        }
        let state = try authority.read()
        let bindings = try bindingIds.map { id -> WorkbenchConnectionBinding in
            guard let binding = state.connections[id], binding.active,
                  binding.deviceId == deviceId,
                  state.credentialGenerations[binding.auth.authRef] ?? 0 == binding.credentialGeneration,
                  try WorkbenchAuthorizationContext.declarationHash(grant: binding.grant,
                      auth: binding.auth, dashboardId: binding.dashboardId,
                      revision: binding.revision) == binding.grantScopeHash else {
                throw WorkbenchAuthorityError.missingBinding
            }
            return binding
        }
        var missing: [String] = []
        for requirement in requirements {
            if !requirement.manifest.connections.isEmpty {
                let source = try? WorkbenchPortablePackages(workspace: workspace).get(
                    dashboardId: requirement.dashboardId,
                    revision: requirement.sourceRevision)
                guard source?.manifest.connections == requirement.manifest.connections else {
                    missing.append(requirement.dashboardId + " (source/prepared declarations differ)")
                    continue
                }
            }
            for declaration in requirement.manifest.connections {
                let label = requirement.dashboardId + "/" + declaration.alias
                guard let operations = declaration.operations,
                      !operations.isEmpty, declaration.serviceCalls == nil,
                      declaration.cameraEntities == nil, declaration.publicHTTP == nil else {
                    if declaration.required { missing.append(label + " (dedicated grant)") }
                    continue
                }
                let candidates = bindings.filter {
                    $0.dashboardId == requirement.dashboardId && $0.grant.alias == declaration.alias
                }
                guard candidates.count == 1, let binding = candidates.first else {
                    if declaration.required { missing.append(label) }
                    continue
                }
                let granted = binding.grant.operations
                let scopesMatch = operations.allSatisfy { declared in
                    granted.contains { operation in
                        operation.name == declared.name &&
                        operation.kind.rawValue == declared.kind &&
                        operation.maxAgeSeconds == declared.maxAgeSeconds
                    }
                }
                guard scopesMatch else { missing.append(label + " (scope changed)"); continue }
                if binding.revision != requirement.revision {
                    let previous = try? WorkbenchPortablePackages(workspace: workspace).get(
                        dashboardId: binding.dashboardId, revision: binding.revision)
                    guard previous?.manifest.connections == requirement.manifest.connections else {
                        missing.append(label + " (revision changed)")
                        continue
                    }
                }
            }
        }
        let scopes = bindings.sorted { $0.bindingId < $1.bindingId }.map {
            WorkbenchConnectionSummary(bindingId: $0.bindingId, deviceId: $0.deviceId,
                dashboardId: $0.dashboardId, revision: $0.revision,
                grant: $0.grant, auth: $0.auth, localStatus: "locally_authorized")
        }
        return .init(scopes: scopes, missing: missing.sorted(by: ToolchainCanonical.utf8Less))
    }

    /// Called only after the exact new selected screen was accepted. The
    /// device currently permits generic provisioning for its active revision;
    /// a failed call therefore leaves a partial installation to reconcile.
    func installDeploymentGrants(deviceId: String,
                                 selected: WorkbenchDeploymentGrantRequirement,
                                 bindingIds: [String]) throws {
        serial.lock(); defer { serial.unlock() }
        let assessment = try deploymentGrants(deviceId: deviceId,
            requirements: [selected], bindingIds: bindingIds)
        guard assessment.ready else { throw WorkbenchAuthorityError.missingBinding }
        let state = try authority.read()
        let selectedAliases = Set(selected.manifest.connections.filter { $0.operations?.isEmpty == false }
            .map(\.alias))
        let carry = bindingIds.compactMap { state.connections[$0] }.filter {
            $0.dashboardId == selected.dashboardId && selectedAliases.contains($0.grant.alias) &&
            $0.revision != selected.revision
        }
        guard !carry.isEmpty else { return }
        let entries = try carry.map { binding -> ConnectionProvisioning.Entry in
            let secret = binding.auth.placement == .none ? nil : try secrets.load(authRef: binding.auth.authRef)
            return .init(grant: binding.grant, binding: binding.auth, secret: secret)
        }
        let request = ConnectionProvisioning(dashboardId: selected.dashboardId,
            revision: selected.revision, entries: entries)
        try request.validate()
        let receipt = try devices.provisionConnections(deviceId: deviceId, configuration: request)
        guard receipt.installed, receipt.deviceId == deviceId,
              receipt.dashboardId == selected.dashboardId,
              receipt.revision == selected.revision,
              receipt.provisioningId == request.provisioningId else {
            throw WorkbenchAuthorityError.remoteOutcomeUnknown
        }
        let inventory = try devices.connectionInventory(deviceId: deviceId)
        guard inventory.deviceId == deviceId,
              carry.allSatisfy({ binding in inventory.entries.contains { entry in
                  entry.id.lowercased() == binding.bindingId &&
                  entry.screen.dashboardId == selected.dashboardId &&
                  entry.screen.revision == selected.revision &&
                  entry.name == binding.grant.alias &&
                  entry.kind == "Custom connection" &&
                  entry.origin == binding.grant.origin &&
                  entry.authentication == binding.auth.placement.rawValue &&
                  entry.operations == binding.grant.operations.map {
                      .init(name: $0.name, method: $0.method.rawValue,
                            path: $0.path, write: $0.write)
                  }
              } }) else { throw WorkbenchAuthorityError.remoteOutcomeUnknown }
    }
    private func validate(grant: ConnectionGrant, auth: ConnectionAuthBinding,
                          dashboardId: String, revision: String) throws {
        try WorkbenchConnectionReviewScope.validate(grant)
        guard WorkspaceValidation.id(dashboardId), WorkspaceValidation.id(revision),
              auth.authRef == grant.authRef else { throw ConnectionFailure.validationFailed }
        let placeholder = auth.placement == .none ? nil : Data("validation-only".utf8)
        try ConnectionProvisioning(dashboardId: dashboardId, revision: revision,
            entries: [.init(grant: grant, binding: auth, secret: placeholder)]).validate()
    }
    private func cleanupManagedSecret(intentId: String) throws {
        serial.lock(); defer { serial.unlock() }
        let state = try authority.read()
        guard let intent = state.intents[intentId], intent.managedSecret == true else { return }
        guard !state.connections.values.contains(where: { $0.auth.authRef == intent.auth.authRef }) else {
            throw WorkbenchAuthorityError.invalidState
        }
        do { try secrets.remove(authRef: intent.auth.authRef) }
        catch { throw WorkbenchAuthorityError.credentialCleanupRequired }
        do {
            try authority.update { state in
                guard state.intents[intentId]?.managedSecret == true else { return }
                state.intents[intentId]?.managedSecret = false
            }
        } catch { throw WorkbenchAuthorityError.credentialCleanupRequired }
    }
    private func view(_ intent: WorkbenchConnectionIntent) -> WorkbenchConnectionIntentView {
        .init(intentId: intent.intentId, declarationHash: intent.declarationHash,
              proposalScopeHash: intent.proposalScopeHash,
              authorizationContextHash: intent.authorizationContextHash,
              expiresAt: intent.expiresAt, state: intent.state.rawValue,
              summary: .init(bindingId: intent.grant.id.uuidString.lowercased(), deviceId: intent.deviceId,
                             dashboardId: intent.dashboardId, revision: intent.revision, grant: intent.grant,
                             auth: intent.auth, localStatus: intent.state.rawValue))
    }
    private func summary(_ binding: WorkbenchConnectionBinding, status: String,
                         remoteRevocation: String = "not_requested") -> WorkbenchConnectionSummary {
        .init(bindingId: binding.bindingId, deviceId: binding.deviceId,
              dashboardId: binding.dashboardId, revision: binding.revision,
              grant: binding.grant, auth: binding.auth, localStatus: status,
              grantGeneration: binding.grantGeneration,
              remoteRevocation: remoteRevocation)
    }
}
#endif
