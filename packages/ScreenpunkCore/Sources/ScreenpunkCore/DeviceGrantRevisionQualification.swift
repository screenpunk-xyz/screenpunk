import Foundation

/// New, unmounted supplied-data schema. No legacy conversion, ownership, approval, storage or durability claim.
struct DeviceGrantRevisionIdentity: Codable, Equatable, Sendable { let rootID: UUID; let revisionID: UUID }
struct DeviceGrantEntryExpectation: Sendable { let entryID: UUID; let package: QualifiedDevicePackage }
enum DeviceGrantCredentialKind: String, Codable, Sendable { case generic, homeAssistant }
struct DeviceGrantCredentialReference: Codable, Sendable {
    let credentialRevisionID: UUID
    let kind: DeviceGrantCredentialKind
    /// Existing logical authRef for Generic, connectionId for HA; never a storage account.
    let key: String
}
protocol GrantSecretRedacted: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}
extension GrantSecretRedacted {
    var description: String { "Grant revision supplied data (redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
struct DeviceGrantCredentialInput: Codable, Sendable, GrantSecretRedacted { let revisionID: UUID; let bytes: Data }
struct DeviceGrantEntryInput: Codable, Sendable, GrantSecretRedacted {
    let entryID: UUID
    let revision: StoredRevision
    let generic: ConnectionProvisioning?
    let homeAssistant: HomeAssistantProvisioning?
    let publicReads: PublicReadProvisioning?
    let credentialReferences: [DeviceGrantCredentialReference]
}
struct DeviceGrantRevisionInput: Codable, Sendable, GrantSecretRedacted {
    let schemaVersion: Int
    let identity: DeviceGrantRevisionIdentity
    let owner: PairingIdentity
    let entries: [DeviceGrantEntryInput]
    let credentials: [DeviceGrantCredentialInput]
    /// Caller-supplied reference inventory only, not observed persistence. Nothing is pruned or promoted.
    let retainedRevisions: [DeviceGrantRevisionIdentity]
}
enum DeviceGrantRevisionQualificationError: Error, Equatable {
    case sizeLimit, invalidInput, identityMismatch, incompleteInventory, credentialMismatch, undeclaredCapability
}
/// Only this file can create qualification. Public metadata excludes credential bytes and token fields.
/// Private canonical bytes are inaccessible to callers, reflection and descriptions, and never hashed.
/// A future storage adapter needs a separately reviewed boundary; this value supplies no secret proof.
final class QualifiedDeviceGrantRevision: GrantSecretRedacted, @unchecked Sendable {
    let identity: DeviceGrantRevisionIdentity
    let owner: PairingIdentity
    let publicMetadataBytes: Data
    let retainedRevisions: [DeviceGrantRevisionIdentity]
    private let privateCanonicalBytes: Data
    fileprivate init(input: DeviceGrantRevisionInput, publicMetadataBytes: Data, privateCanonicalBytes: Data) {
        identity = input.identity; owner = input.owner; retainedRevisions = input.retainedRevisions
        self.publicMetadataBytes = publicMetadataBytes; self.privateCanonicalBytes = privateCanonicalBytes
    }
    /// Exact private-byte equality only; no returned bytes, digest, credential or execution access.
    func exactlyMatches(_ other: QualifiedDeviceGrantRevision) -> Bool { privateCanonicalBytes == other.privateCanonicalBytes }
}

/// Bounds checked before canonical encoding: 12 entries, 32 Generic connections each, existing HA/public
/// limits, 8KiB per secret, 1MiB aggregate unique credentials AND 1MiB aggregate inline Generic/HA
/// binding bytes (shared credentials count once per binding), 256KiB public / 4MiB private representation.
/// Raw decoding also enforces depth32/nodes65536 before Foundation object materialization. Fail closed,
/// no truncation. Canonical representation pins native sorted JSON; no Unicode normalization or wire DTO.
enum DeviceGrantRevisionQualifier {
    static let privateLimit = 4 * 1024 * 1024
    static let publicLimit = 256 * 1024
    static let secretLimit = 8192
    static let aggregateSecretLimit = 1024 * 1024
    static func qualify(_ bytes: Data, expectedEntries: [DeviceGrantEntryExpectation]) throws -> QualifiedDeviceGrantRevision {
        try qualify(DeviceGrantRevisionPreflight.decode(bytes), expectedEntries: expectedEntries)
    }
    static func qualify(_ input: DeviceGrantRevisionInput, expectedEntries: [DeviceGrantEntryExpectation]) throws -> QualifiedDeviceGrantRevision {
        try bounds(input)
        guard input.schemaVersion == 1, input.owner.isWellFormed, input.owner.role == .controller else { throw DeviceGrantRevisionQualificationError.invalidInput }
        guard expectedEntries.count <= 12, expectedEntries.count == input.entries.count,
              Set(expectedEntries.map(\.entryID)).count == expectedEntries.count,
              Set(input.entries.map(\.entryID)).count == input.entries.count else { throw DeviceGrantRevisionQualificationError.incompleteInventory }
        let expected = Dictionary(uniqueKeysWithValues: expectedEntries.map { ($0.entryID, $0.package) })
        var dashboardIDs = Set<Data>(), credentialIDs = Set<UUID>(), used = Set<UUID>()
        for item in input.credentials { guard credentialIDs.insert(item.revisionID).inserted else { throw DeviceGrantRevisionQualificationError.credentialMismatch } }
        let credentials = Dictionary(uniqueKeysWithValues: input.credentials.map { ($0.revisionID, $0.bytes) })
        for entry in input.entries {
            guard let package = expected[entry.entryID], try canonical(entry.revision) == canonical(package.revision),
                  dashboardIDs.insert(Data(entry.revision.dashboardId.utf8)).inserted else { throw DeviceGrantRevisionQualificationError.identityMismatch }
            var references = Set<Data>()
            for ref in entry.credentialReferences {
                guard references.insert(Data((ref.kind.rawValue + "\0" + ref.key).utf8)).inserted,
                      credentials[ref.credentialRevisionID] != nil else { throw DeviceGrantRevisionQualificationError.credentialMismatch }
                used.insert(ref.credentialRevisionID)
            }
            var consumed = Set<Data>()
            func secret(_ kind: DeviceGrantCredentialKind, _ key: String, _ value: Data) throws {
                guard let ref = entry.credentialReferences.first(where: { $0.kind == kind && exact($0.key, key) }),
                      credentials[ref.credentialRevisionID] == value, consumed.insert(Data((kind.rawValue + "\0" + key).utf8)).inserted else { throw DeviceGrantRevisionQualificationError.credentialMismatch }
            }
            if let config = entry.generic {
                try config.validate(); try scope(config.dashboardId, config.revision, entry.revision)
                guard Set(config.entries.map { $0.grant.id }).count == config.entries.count else { throw DeviceGrantRevisionQualificationError.invalidInput }
                for item in config.entries {
                    guard exact(item.binding.authRef, item.grant.authRef) else { throw DeviceGrantRevisionQualificationError.identityMismatch }
                    guard let declaration = package.manifest.connections.first(where: { exact($0.alias, item.grant.alias) }),
                          declaration.publicHTTP == nil, declaration.alias != "home" else { throw DeviceGrantRevisionQualificationError.undeclaredCapability }
                    for operation in item.grant.operations {
                        guard declaration.operations?.contains(where: { exact($0.name, operation.name) && exact($0.kind, operation.kind.rawValue) && $0.maxAgeSeconds == operation.maxAgeSeconds }) == true else { throw DeviceGrantRevisionQualificationError.undeclaredCapability }
                    }
                    if let bytes = item.secret { try secret(.generic, item.grant.authRef, bytes) }
                }
            }
            if let config = entry.homeAssistant {
                try config.validate(); try scope(config.dashboardId, config.revision, entry.revision)
                guard let declaration = package.manifest.connections.first(where: { exact($0.alias, "home") && $0.publicHTTP == nil }) else { throw DeviceGrantRevisionQualificationError.undeclaredCapability }
                // Legacy schema1 retains its broad existing semantics; this is never approval or an upgrade.
                if config.schemaVersion >= 2 {
                    for grant in config.serviceCalls ?? [] {
                        guard try (declaration.serviceCalls ?? []).contains(where: { try canonical($0) == canonical(grant) }) else { throw DeviceGrantRevisionQualificationError.undeclaredCapability }
                    }
                }
                guard (config.cameraEntities ?? []).allSatisfy({ camera in (declaration.cameraEntities ?? []).contains(where: { exact($0, camera) }) }) else { throw DeviceGrantRevisionQualificationError.undeclaredCapability }
                try secret(.homeAssistant, config.connectionId, Data(config.token.utf8))
            }
            if let config = entry.publicReads {
                try config.validate(); try scope(config.dashboardId, config.revision, entry.revision)
                let declared = package.manifest.connections.filter { $0.publicHTTP != nil }
                for connection in config.connections {
                    guard try declared.contains(where: { try canonical($0) == canonical(connection) }) else { throw DeviceGrantRevisionQualificationError.undeclaredCapability }
                }
            }
            guard consumed == references else { throw DeviceGrantRevisionQualificationError.credentialMismatch }
        }
        guard used == credentialIDs else { throw DeviceGrantRevisionQualificationError.credentialMismatch }
        guard input.retainedRevisions.count <= 128, Set(input.retainedRevisions.map(\.revisionID)).count == input.retainedRevisions.count,
              input.retainedRevisions.allSatisfy({ $0.rootID == input.identity.rootID && $0.revisionID != input.identity.revisionID }) else { throw DeviceGrantRevisionQualificationError.invalidInput }
        // Sort inventories by opaque UUID, never select/configure entries or infer migration policy.
        let normalized = DeviceGrantRevisionInput(schemaVersion: 1, identity: input.identity, owner: input.owner,
            entries: input.entries.sorted { $0.entryID.uuidString < $1.entryID.uuidString },
            credentials: input.credentials.sorted { $0.revisionID.uuidString < $1.revisionID.uuidString },
            retainedRevisions: input.retainedRevisions.sorted { $0.revisionID.uuidString < $1.revisionID.uuidString })
        let privateBytes = try canonical(normalized)
        guard privateBytes.count <= privateLimit else { throw DeviceGrantRevisionQualificationError.sizeLimit }
        try DeviceGrantRevisionPreflight.validate(privateBytes)
        var publicObject = try JSONSerialization.jsonObject(with: privateBytes) as! [String: Any]
        publicObject.removeValue(forKey: "credentials")
        var publicEntries = publicObject["entries"] as! [[String: Any]]
        for index in publicEntries.indices {
            if var generic = publicEntries[index]["generic"] as? [String: Any], var entries = generic["entries"] as? [[String: Any]] {
                for entry in entries.indices { entries[entry].removeValue(forKey: "secret") }
                generic["entries"] = entries; publicEntries[index]["generic"] = generic
            }
            if var home = publicEntries[index]["homeAssistant"] as? [String: Any] { home.removeValue(forKey: "token"); publicEntries[index]["homeAssistant"] = home }
        }
        publicObject["entries"] = publicEntries
        let publicBytes = try JSONSerialization.data(withJSONObject: publicObject, options: [.sortedKeys, .withoutEscapingSlashes])
        guard publicBytes.count <= publicLimit else { throw DeviceGrantRevisionQualificationError.sizeLimit }
        // Schema projection excludes credential storage, Generic secret and HA token fields.
        // Metadata strings may coincide with secret content; no token-content policy is inferred.
        return .init(input: normalized, publicMetadataBytes: publicBytes, privateCanonicalBytes: privateBytes)
    }
    private static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    private static func scope(_ dashboard: String, _ revision: String, _ expected: StoredRevision) throws {
        guard exact(dashboard, expected.dashboardId), exact(revision, expected.revision) else { throw DeviceGrantRevisionQualificationError.identityMismatch }
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    private static func bounds(_ input: DeviceGrantRevisionInput) throws {
        guard input.entries.count <= 12, input.credentials.count <= 396, input.retainedRevisions.count <= 128,
              input.owner.publicKey.count <= PairingLimits.identityByteCount else { throw DeviceGrantRevisionQualificationError.sizeLimit }
        var total = 0
        for item in input.credentials {
            guard !item.bytes.isEmpty, item.bytes.count <= secretLimit, item.bytes.count <= aggregateSecretLimit - total else { throw DeviceGrantRevisionQualificationError.sizeLimit }; total += item.bytes.count
        }
        // Existing validators do not bound every string. Charge UTF8 and collections before encoding.
        var budget = privateLimit, inlineBytes = 0
        func inlineSecret(_ count: Int) throws {
            guard count <= secretLimit, count <= aggregateSecretLimit - inlineBytes else { throw DeviceGrantRevisionQualificationError.sizeLimit }
            inlineBytes += count
        }
        func text(_ value: String) throws { guard value.utf8.count <= budget else { throw DeviceGrantRevisionQualificationError.sizeLimit }; budget -= value.utf8.count }
        for entry in input.entries {
            try text(entry.revision.dashboardId); try text(entry.revision.revision); try text(entry.revision.name); try text(entry.revision.digest)
            guard entry.credentialReferences.count <= 33 else { throw DeviceGrantRevisionQualificationError.sizeLimit }
            for ref in entry.credentialReferences { try text(ref.key) }
            if let config = entry.generic {
                guard config.entries.count <= 32 else { throw DeviceGrantRevisionQualificationError.sizeLimit }
                try text(config.dashboardId); try text(config.revision); try text(config.provisioningId)
                for item in config.entries {
                    guard item.grant.operations.count <= 32 else { throw DeviceGrantRevisionQualificationError.sizeLimit }
                    try inlineSecret(item.secret?.count ?? 0)
                    for string in [item.grant.alias,item.grant.origin,item.grant.authRef,item.binding.authRef,item.binding.fieldName ?? ""] { try text(string) }
                    for operation in item.grant.operations { try text(operation.name); try text(operation.path) }
                }
            }
            if let config = entry.homeAssistant {
                guard (config.serviceCalls?.count ?? 0) <= 128, (config.cameraEntities?.count ?? 0) <= 16 else { throw DeviceGrantRevisionQualificationError.sizeLimit }
                try inlineSecret(config.token.utf8.count)
                for string in [config.dashboardId,config.revision,config.provisioningId,config.connectionId,config.origin,config.permissionMode,config.token] { try text(string) }
                for call in config.serviceCalls ?? [] {
                    guard call.entityIds.count <= 128 else { throw DeviceGrantRevisionQualificationError.sizeLimit }
                    try text(call.domain); try text(call.service); for id in call.entityIds { try text(id) }
                }
                for camera in config.cameraEntities ?? [] { try text(camera) }
            }
            if let reads = entry.publicReads {
                guard reads.connections.count <= 8 else { throw DeviceGrantRevisionQualificationError.sizeLimit }
                try text(reads.dashboardId); try text(reads.revision)
                for connection in reads.connections {
                    try text(connection.alias)
                    guard let declaration = connection.publicHTTP, declaration.operations.count <= 16,
                          connection.operations == nil, connection.serviceCalls == nil, connection.cameraEntities == nil else { throw DeviceGrantRevisionQualificationError.sizeLimit }
                    try text(declaration.origin); try text(declaration.userAgent)
                    for operation in declaration.operations {
                        guard operation.parameters.count <= 12 else { throw DeviceGrantRevisionQualificationError.sizeLimit }
                        try text(operation.name); try text(operation.path); try text(operation.response)
                        for (key, parameter) in operation.parameters {
                            try text(key); try text(parameter.location)
                            guard (parameter.values?.count ?? 0) <= 64 else { throw DeviceGrantRevisionQualificationError.sizeLimit }
                            for value in parameter.values ?? [] { try text(value) }
                        }
                    }
                }
                try reads.validate()
                let bytes = try canonical(reads); guard bytes.count <= publicLimit, bytes.count <= budget else { throw DeviceGrantRevisionQualificationError.sizeLimit }; budget -= bytes.count
            }
        }
    }
}
