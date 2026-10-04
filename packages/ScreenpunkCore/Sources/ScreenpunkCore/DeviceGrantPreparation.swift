import Foundation

struct DeviceGrantPreparationRequest: GrantSecretRedacted {
    let operationID: UUID
    let input: DeviceGrantRevisionInput
    let qualified: QualifiedDeviceGrantRevision
    let expectedEntries: [DeviceGrantEntryExpectation]
}
/// Backend observations are untrusted input. Implementations must guarantee add-only immutable bytes
/// and stable replacement identity. No update/delete operation or actual Keychain implementation here.
/// Inventory visits are bounded and must propagate visitor failure; no aggregate private data inventory.
protocol DeviceGrantCredentialBackend: Sendable {
    func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws
    func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue?
    func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem
}
struct DeviceGrantCredentialItem: Codable, Equatable, Sendable {
    let account: String
    let persistentReference: Data
    let byteCount: Int
}
struct DeviceGrantCredentialValue: GrantSecretRedacted, Sendable {
    let item: DeviceGrantCredentialItem
    let bytes: Data
}
enum DeviceGrantPreparationError: Error, Equatable {
    case invalidRecord, sizeLimit, unsafeBinding, scopeOverlap, conflict, capacity, repairRequired, outcomeUncertain
    case io(Int32)
}
struct GrantDiskIdentity: Codable, Equatable { let device: UInt64; let inode: UInt64 }
struct GrantCredentialBinding: Codable, Equatable {
    let revisionID: UUID
    let byteCount: Int
    var item: DeviceGrantCredentialItem?
    var account: String { GrantPreparationCodec.credentialAccount(revisionID) }
}
struct GrantPreparationRecord: Codable, Equatable {
    let schemaVersion: Int
    let rootID: UUID
    let operationID: UUID
    let revisionID: UUID
    let ordinal: Int
    let publicMetadata: Data
    let privateAttemptBytes: Int
    let previousHead: GrantHeadEvidence?
    var privateAttempt: DeviceGrantCredentialItem?
    var credentials: [GrantCredentialBinding]
    init(rootID: UUID, operationID: UUID, revisionID: UUID, ordinal: Int, publicMetadata: Data, privateAttemptBytes: Int, previousHead: GrantHeadEvidence?, credentials: [GrantCredentialBinding]) {
        schemaVersion = 1; self.rootID = rootID; self.operationID = operationID; self.revisionID = revisionID
        self.ordinal = ordinal; self.publicMetadata = publicMetadata; self.privateAttemptBytes = privateAttemptBytes; self.previousHead = previousHead; self.credentials = credentials
    }
    func progresses(_ old: Self) -> Bool {
        var current = self, prior = old
        current.privateAttempt = nil; prior.privateAttempt = nil
        current.credentials = current.credentials.map { .init(revisionID: $0.revisionID, byteCount: $0.byteCount, item: nil) }
        prior.credentials = prior.credentials.map { .init(revisionID: $0.revisionID, byteCount: $0.byteCount, item: nil) }
        guard current == prior, old.privateAttempt == nil || privateAttempt == old.privateAttempt,
              credentials.count == old.credentials.count else { return false }
        return zip(credentials, old.credentials).allSatisfy { $1.item == nil || $0.item == $1.item }
    }
}
struct GrantTerminalBinding: Codable {
    let schemaVersion: Int
    let operationID: UUID
    let terminalIdentity: GrantDiskIdentity
}
struct GrantHeadEvidence: Codable, Equatable { let bytes: Data; let identity: GrantDiskIdentity }
struct GrantHead: Codable { let schemaVersion: Int; let rootID: UUID; let operationID: UUID; let ordinal: Int; let terminalIdentity: GrantDiskIdentity }
struct GrantHeadBinding: Codable { let schemaVersion: Int; let operationID: UUID; let candidate: GrantHeadEvidence }
struct GrantHeadConfirmation: Codable { let schemaVersion: Int; let operationID: UUID; let headIdentity: GrantDiskIdentity }
struct GrantPrivateAttempt: Codable, GrantSecretRedacted {
    let schemaVersion: Int
    let rootID: UUID
    let operationID: UUID
    let input: DeviceGrantRevisionInput
}
/// Schema-local codecs. Files contain only public metadata, sizes, opaque identities and references.
/// Private intent <=4MiB; credential <=8KiB. Retention:128 terminal/one unresolved,4096 credential IDs,
///128MiB private intents +32MiB credential bytes; reservation checks precede initial intent/effects.
enum GrantPreparationCodec {
    static let recordLimit = 4 * 1024 * 1024
    static let intentLimit = 4 * 1024 * 1024
    static let credentialLimit = 8192
    static let intentTotalLimit = 128 * 1024 * 1024
    static let credentialTotalLimit = 32 * 1024 * 1024
    static let itemLimit = 4096 + 129
    static func service(_ rootID: UUID) -> String { "xyz.screenpunk.device.grant-revisions.v1." + rootID.uuidString.lowercased() }
    static func attemptAccount(_ id: UUID) -> String { "attempt." + id.uuidString.lowercased() }
    static func credentialAccount(_ id: UUID) -> String { "credential." + id.uuidString.lowercased() }
    static func encode<T: Encodable>(_ value: T, limit: Int = recordLimit) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let bytes = try encoder.encode(value); guard bytes.count <= limit else { throw DeviceGrantPreparationError.sizeLimit }; return bytes
    }
    static func attempt(_ request: DeviceGrantPreparationRequest, rootID: UUID) throws -> Data {
        guard request.input.identity.rootID == rootID else { throw DeviceGrantPreparationError.conflict }
        let fresh = try DeviceGrantRevisionQualifier.qualify(request.input, expectedEntries: request.expectedEntries)
        guard fresh.exactlyMatches(request.qualified) else { throw DeviceGrantPreparationError.conflict }
        let input = DeviceGrantRevisionInput(schemaVersion: request.input.schemaVersion, identity: request.input.identity, owner: request.input.owner,
            entries: request.input.entries.sorted { $0.entryID.uuidString < $1.entryID.uuidString },
            credentials: request.input.credentials.sorted { $0.revisionID.uuidString < $1.revisionID.uuidString },
            retainedRevisions: request.input.retainedRevisions.sorted { $0.revisionID.uuidString < $1.revisionID.uuidString })
        return try encode(GrantPrivateAttempt(schemaVersion: 1, rootID: rootID, operationID: request.operationID, input: input), limit: intentLimit)
    }
    static func decodeAttempt(_ bytes: Data) throws -> GrantPrivateAttempt {
        let object = try object(bytes, limit: intentLimit)
        try keys(object, ["schemaVersion","rootID","operationID","input"])
        guard let input = object["input"] else { throw DeviceGrantPreparationError.invalidRecord }
        let inputBytes = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys,.withoutEscapingSlashes])
        _ = try DeviceGrantRevisionPreflight.decode(inputBytes)
        let result = try JSONDecoder().decode(GrantPrivateAttempt.self, from: bytes)
        guard result.schemaVersion == 1, result.rootID == result.input.identity.rootID else { throw DeviceGrantPreparationError.invalidRecord }
        return result
    }
    /// Strict retained union. V1 encoding/decoder remain unchanged; v2 can never be completed by v1 APIs.
    struct StoredAttempt: GrantSecretRedacted {
        let version:Int,rootID:UUID,operationID:UUID,input:DeviceGrantRevisionInput
        let completeSetIntent:Data?
    }
    private struct V2:Codable,GrantSecretRedacted {
        let schemaVersion:Int,rootID:UUID,operationID:UUID,input:DeviceGrantRevisionInput,completeSetIntent:Data
    }
    static func decodeStoredAttempt(_ bytes:Data)throws->StoredAttempt {
        let raw=try object(bytes,limit:intentLimit)
        if (raw["schemaVersion"] as? NSNumber)?.intValue == 1 {
            let v=try decodeAttempt(bytes)
            return .init(version:1,rootID:v.rootID,operationID:v.operationID,input:v.input,completeSetIntent:nil)
        }
        try keys(raw,["schemaVersion","rootID","operationID","input","completeSetIntent"])
        guard let input=raw["input"],let encoded=raw["completeSetIntent"] as? String,
              encoded.utf8.count <= ((ProvisioningIntentCodec.limit+2)/3)*4 else{throw DeviceGrantPreparationError.invalidRecord}
        _ = try DeviceGrantRevisionPreflight.decode(JSONSerialization.data(withJSONObject:input,options:[.sortedKeys,.withoutEscapingSlashes]))
        let v=try JSONDecoder().decode(V2.self,from:bytes)
        guard v.schemaVersion == 2,v.rootID == v.input.identity.rootID else{throw DeviceGrantPreparationError.invalidRecord}
        let intent=try ProvisioningIntentCodec.decode(v.completeSetIntent)
        guard intent.roots.grantID == v.rootID,intent.grantOperationID == v.operationID,
              intent.grantIdentity == v.input.identity,intent.privateAttemptByteCount == bytes.count,
              intent.grantPublicMetadata == (try projection(v.input)),try encode(v,limit:intentLimit) == bytes else{throw DeviceGrantPreparationError.conflict}
        // The frozen v2 encoder sorts opaque IDs; canonical equivalents are not accepted aliases.
        guard v.input.entries.map(\.entryID.uuidString) == v.input.entries.map(\.entryID.uuidString).sorted(),
              v.input.credentials.map(\.revisionID.uuidString) == v.input.credentials.map(\.revisionID.uuidString).sorted(),
              v.input.retainedRevisions.map(\.revisionID.uuidString) == v.input.retainedRevisions.map(\.revisionID.uuidString).sorted() else{throw DeviceGrantPreparationError.invalidRecord}
        return .init(version:2,rootID:v.rootID,operationID:v.operationID,input:v.input,completeSetIntent:v.completeSetIntent)
    }
    static func decodeRecord(_ bytes: Data) throws -> GrantPreparationRecord {
        let object = try object(bytes, limit: recordLimit)
        try keys(object, ["schemaVersion","rootID","operationID","revisionID","ordinal","publicMetadata","privateAttemptBytes","credentials"], optional: ["privateAttempt","previousHead"])
        if let head = object["previousHead"] { try evidenceShape(head) }
        if let item = object["privateAttempt"] { try itemShape(item) }
        guard let credentials = object["credentials"] as? [[String: Any]], credentials.count <= 396 else { throw DeviceGrantPreparationError.invalidRecord }
        for credential in credentials {
            try keys(credential,["revisionID","byteCount"],optional:["item"])
            if let item = credential["item"] { try itemShape(item) }
        }
        let result = try JSONDecoder().decode(GrantPreparationRecord.self, from: bytes)
        guard result.schemaVersion == 1, (1...129).contains(result.ordinal), result.publicMetadata.count <= DeviceGrantRevisionQualifier.publicLimit,
              (1...intentLimit).contains(result.privateAttemptBytes), Set(result.credentials.map(\.revisionID)).count == result.credentials.count,
              result.credentials.map(\.revisionID.uuidString) == result.credentials.map(\.revisionID.uuidString).sorted() else { throw DeviceGrantPreparationError.invalidRecord }
        if let head = result.previousHead { guard head.bytes.count <= 4096 else { throw DeviceGrantPreparationError.sizeLimit }; _ = try decodeHead(head.bytes) }
        if let item = result.privateAttempt { try validate(item, account: attemptAccount(result.operationID), count: result.privateAttemptBytes) }
        for binding in result.credentials {
            guard (1...credentialLimit).contains(binding.byteCount) else { throw DeviceGrantPreparationError.invalidRecord }
            if let item = binding.item { try validate(item, account: binding.account, count: binding.byteCount) }
        }
        return result
    }
    static func decodeTerminal(_ bytes: Data) throws -> GrantTerminalBinding {
        let object = try object(bytes, limit: 4096); try keys(object,["schemaVersion","operationID","terminalIdentity"])
        guard let identity = object["terminalIdentity"] as? [String: Any] else { throw DeviceGrantPreparationError.invalidRecord }
        try keys(identity,["device","inode"])
        let value = try JSONDecoder().decode(GrantTerminalBinding.self, from: bytes)
        guard value.schemaVersion == 1 else { throw DeviceGrantPreparationError.invalidRecord }; return value
    }
    static func decodeHead(_ bytes: Data) throws -> GrantHead {
        let object = try object(bytes,limit:4096); try keys(object,["schemaVersion","rootID","operationID","ordinal","terminalIdentity"])
        try identityShape(object["terminalIdentity"] as Any)
        let value = try JSONDecoder().decode(GrantHead.self,from:bytes)
        guard value.schemaVersion == 1, (1...129).contains(value.ordinal) else { throw DeviceGrantPreparationError.invalidRecord }; return value
    }
    static func decodeHeadBinding(_ bytes: Data) throws -> GrantHeadBinding {
        let object = try object(bytes,limit:8192); try keys(object,["schemaVersion","operationID","candidate"])
        try evidenceShape(object["candidate"] as Any)
        let value = try JSONDecoder().decode(GrantHeadBinding.self,from:bytes)
        guard value.schemaVersion == 1, value.candidate.bytes.count <= 4096 else { throw DeviceGrantPreparationError.invalidRecord }; return value
    }
    static func decodeConfirmation(_ bytes: Data) throws -> GrantHeadConfirmation {
        let object = try object(bytes,limit:4096); try keys(object,["schemaVersion","operationID","headIdentity"])
        try identityShape(object["headIdentity"] as Any)
        let value = try JSONDecoder().decode(GrantHeadConfirmation.self,from:bytes)
        guard value.schemaVersion == 1 else { throw DeviceGrantPreparationError.invalidRecord }; return value
    }
    private static func identityShape(_ raw: Any) throws {
        guard let object = raw as? [String:Any] else { throw DeviceGrantPreparationError.invalidRecord }; try keys(object,["device","inode"])
    }
    private static func evidenceShape(_ raw: Any) throws {
        guard let object = raw as? [String:Any] else { throw DeviceGrantPreparationError.invalidRecord }; try keys(object,["bytes","identity"]); try identityShape(object["identity"] as Any)
    }
    static func projection(_ input: DeviceGrantRevisionInput) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: encode(input, limit: intentLimit)) as! [String: Any]
        object.removeValue(forKey: "credentials")
        var entries = object["entries"] as! [[String: Any]]
        for index in entries.indices {
            if var generic = entries[index]["generic"] as? [String: Any], var grants = generic["entries"] as? [[String: Any]] {
                for i in grants.indices { grants[i].removeValue(forKey: "secret") }; generic["entries"] = grants; entries[index]["generic"] = generic
            }
            if var home = entries[index]["homeAssistant"] as? [String: Any] { home.removeValue(forKey: "token"); entries[index]["homeAssistant"] = home }
        }
        object["entries"] = entries
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys,.withoutEscapingSlashes])
        guard bytes.count <= DeviceGrantRevisionQualifier.publicLimit else { throw DeviceGrantPreparationError.sizeLimit }; return bytes
    }
    static func validate(_ item: DeviceGrantCredentialItem, account: String, count: Int) throws {
        guard item.account.utf8.elementsEqual(account.utf8), item.byteCount == count,
              !item.persistentReference.isEmpty, item.persistentReference.count <= 4096 else { throw DeviceGrantPreparationError.conflict }
    }
    private static func itemShape(_ raw: Any) throws {
        guard let object = raw as? [String: Any] else { throw DeviceGrantPreparationError.invalidRecord }
        try keys(object,["account","persistentReference","byteCount"])
    }
    private static func object(_ bytes: Data, limit: Int) throws -> [String: Any] {
        guard bytes.count <= limit else { throw DeviceGrantPreparationError.sizeLimit }
        try DeviceGrantRevisionPreflight.validate(bytes)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw DeviceGrantPreparationError.invalidRecord }; return object
    }
    private static func keys(_ object: [String: Any], _ required: Set<String>, optional: Set<String> = []) throws {
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional)) else { throw DeviceGrantPreparationError.invalidRecord }
    }
}
