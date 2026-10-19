import Foundation
import ScreenpunkCore
#if os(macOS)

enum WorkbenchTransactionKind: String, Codable, Sendable {
    case projectEdit, catalogSettingsCommit, historyPublish, historyPrune, migrationPublish
    case sourceCommit, packageHeadCommit
}

struct WorkbenchTransactionImage: Codable, Equatable, Sendable {
    let state: String
    let sha256: String?
    let bytes: Int?
    static let absent = Self(state: "absent", sha256: nil, bytes: nil)
    static func present(_ data: Data) -> Self {
        Self(state: "present", sha256: WorkbenchTransactionDigest.hex(data), bytes: data.count)
    }
    func validate() throws {
        if state == "absent" {
            guard sha256 == nil, bytes == nil else { throw WorkspaceError.invalidSchema }
        } else if state == "present" {
            guard let sha256, WorkspaceValidation.sha256(sha256), let bytes,
                  bytes >= 0, bytes <= 50 * 1024 * 1024 else { throw WorkspaceError.invalidSchema }
        } else { throw WorkspaceError.invalidSchema }
    }
}

struct WorkbenchTransactionTarget: Codable, Equatable, Sendable {
    let targetClass: String
    let projectId: String?
    let member: String?
    let object: String?
    let objectKind: String?
    let objectId: String?
    let migrationId: String?

    static func project(_ id: String, _ member: String) -> Self {
        .init(targetClass: "projectMember", projectId: id, member: member,
              object: nil, objectKind: nil, objectId: nil, migrationId: nil)
    }
    static func metadata(_ name: String) -> Self {
        .init(targetClass: "portableMetadata", projectId: nil, member: nil,
              object: name, objectKind: nil, objectId: nil, migrationId: nil)
    }
    static func buildHead(_ projectID: String) -> Self {
        .init(targetClass: "buildHead", projectId: projectID, member: nil,
              object: nil, objectKind: nil, objectId: nil, migrationId: nil)
    }
    static func history(_ kind: String, _ id: String, _ member: String) -> Self {
        .init(targetClass: "historyObject", projectId: nil, member: member,
              object: nil, objectKind: kind, objectId: id, migrationId: nil)
    }
    static func migration(_ migration: String, _ kind: String, _ id: String, _ member: String) -> Self {
        .init(targetClass: "migrationStagingObject", projectId: nil, member: member,
              object: nil, objectKind: kind, objectId: id, migrationId: migration)
    }
    func validate(for kind: WorkbenchTransactionKind) throws {
        switch kind {
        case .packageHeadCommit:
            switch targetClass {
            case "buildHead":
                guard let projectId, WorkspaceValidation.id(projectId), member == nil,
                      object == nil, objectKind == nil, objectId == nil, migrationId == nil
                else { throw WorkspaceError.invalidSchema }
            case "historyObject":
                try validate(for: .historyPublish)
                guard objectKind == "package" else { throw WorkspaceError.invalidSchema }
            default: throw WorkspaceError.invalidSchema
            }
        case .sourceCommit:
            switch targetClass {
            case "projectMember": try validate(for: .projectEdit)
            case "portableMetadata":
                if object == "toolchainRequirements" {
                    guard projectId == nil, member == nil, objectKind == nil,
                          objectId == nil, migrationId == nil else { throw WorkspaceError.invalidSchema }
                } else { try validate(for: .catalogSettingsCommit) }
            case "historyObject":
                try validate(for: .historyPublish)
                guard objectKind == "buildSource" else { throw WorkspaceError.invalidSchema }
            default: throw WorkspaceError.invalidSchema
            }
        case .projectEdit:
            guard targetClass == "projectMember", let projectId, WorkspaceValidation.id(projectId),
                  let member, WorkspaceValidation.member(member),
                  !WorkspaceFiles.fixedSourceExcludes(member),
                  projectId != "", object == nil, objectKind == nil, objectId == nil, migrationId == nil
            else { throw WorkspaceError.invalidSchema }
        case .catalogSettingsCommit:
            guard targetClass == "portableMetadata", let object,
                  ["workspaceDescriptor", "libraryCatalog", "workbenchSettings", "logicalConnections"].contains(object),
                  projectId == nil, member == nil, objectKind == nil, objectId == nil, migrationId == nil
            else { throw WorkspaceError.invalidSchema }
        case .historyPublish:
            if targetClass == "portableMetadata" {
                guard let object,
                      ["workspaceDescriptor", "libraryCatalog", "workbenchSettings"].contains(object),
                      projectId == nil, member == nil, objectKind == nil,
                      objectId == nil, migrationId == nil else { throw WorkspaceError.invalidSchema }
            } else { try validate(for: .historyPrune) }
        case .historyPrune:
            guard targetClass == "historyObject", let objectKind,
                  ["buildSource", "package", "preparedPackage", "deploymentHistory", "attachment"].contains(objectKind),
                  let objectId, WorkspaceValidation.id(objectId), let member, WorkspaceValidation.member(member),
                  projectId == nil, object == nil, migrationId == nil else { throw WorkspaceError.invalidSchema }
        case .migrationPublish:
            guard targetClass == "migrationStagingObject", let migrationId, WorkspaceValidation.id(migrationId),
                  let objectKind, ["project", "metadata", "history", "attachment"].contains(objectKind),
                  let objectId, WorkspaceValidation.id(objectId), let member, WorkspaceValidation.member(member),
                  projectId == nil, object == nil else { throw WorkspaceError.invalidSchema }
        }
    }
}

struct WorkbenchTransactionOperation: Codable, Equatable, Sendable {
    let target: WorkbenchTransactionTarget
    let before: WorkbenchTransactionImage
    let after: WorkbenchTransactionImage
    let recoveryBlobHash: String?

    func validate(for kind: WorkbenchTransactionKind) throws {
        try target.validate(for: kind); try before.validate(); try after.validate()
        if after.state == "present" {
            guard let recoveryBlobHash, recoveryBlobHash == after.sha256 else { throw WorkspaceError.invalidSchema }
        } else {
            guard recoveryBlobHash == nil else { throw WorkspaceError.invalidSchema }
        }
        switch kind {
        case .packageHeadCommit:
            guard after.state == "present" else { throw WorkspaceError.invalidSchema }
            if target.targetClass == "historyObject" {
                guard before.state == "absent" || before == after else { throw WorkspaceError.invalidSchema }
            }
        case .sourceCommit:
            if target.targetClass == "historyObject" {
                guard after.state == "present", before.state == "absent" || before == after else {
                    throw WorkspaceError.invalidSchema
                }
            } else if target.targetClass == "portableMetadata" {
                guard after.state == "present" else { throw WorkspaceError.invalidSchema }
            }
        case .projectEdit: break
        case .catalogSettingsCommit:
            guard after.state == "present" else { throw WorkspaceError.invalidSchema }
        case .historyPublish:
            if target.targetClass == "portableMetadata" {
                guard before.state == "present", after.state == "present" else {
                    throw WorkspaceError.invalidSchema
                }
            } else {
                guard after.state == "present", before.state == "absent" || before == after else {
                    throw WorkspaceError.conflict
                }
            }
        case .migrationPublish:
            guard after.state == "present",
                  before.state == "absent" || before == after else { throw WorkspaceError.conflict }
        case .historyPrune:
            guard before.state == "present", after.state == "absent" else { throw WorkspaceError.invalidSchema }
        }
    }
}

struct WorkbenchPackagePublicationBinding: Codable, Equatable, Sendable {
    let projectId: String
    let dashboardId: String
    let sourceVersion: String
    let selectedToolchain: WorkspaceToolchainRequirements.Requirement?
    func validate() throws {
        guard WorkspaceValidation.id(projectId), WorkspaceValidation.id(dashboardId),
              WorkspaceValidation.sha256(sourceVersion) else { throw WorkspaceError.invalidSchema }
        if let selectedToolchain {
            guard WorkspaceValidation.id(selectedToolchain.catalogEntryId),
                  WorkspaceValidation.id(selectedToolchain.kitVersion),
                  selectedToolchain.platform == "darwin-arm64",
                  WorkspaceValidation.sha256(selectedToolchain.inventoryHash) else {
                throw WorkspaceError.invalidSchema
            }
        }
    }
}

struct WorkbenchTransactionJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let transactionId: String
    let workspaceId: String
    let kind: WorkbenchTransactionKind
    let expectedGeneration: Int
    let operations: [WorkbenchTransactionOperation]
    var publication: WorkbenchPackagePublicationBinding? = nil

    func validate() throws {
        guard schemaVersion == ([.sourceCommit, .packageHeadCommit].contains(kind) ? 2 :
                kind == .historyPublish ? (operations.contains(where: { $0.target.targetClass == "portableMetadata" }) ? 2 : 1) : 1),
              WorkspaceValidation.id(transactionId), WorkspaceValidation.id(workspaceId),
              expectedGeneration >= 0, expectedGeneration < WorkspaceValidation.maxUInt,
              (1...WorkbenchTransactionAccounting.maximumOperations(for: kind)).contains(operations.count)
        else { throw WorkspaceError.invalidSchema }
        var targets = Set<String>()
        for operation in operations {
            try operation.validate(for: kind)
            let normalized = try JSONEncoder().encode(operation.target)
            guard targets.insert(String(decoding: normalized, as: UTF8.self)).inserted else { throw WorkspaceError.conflict }
        }
        if kind == .projectEdit {
            guard Set(operations.compactMap(\.target.projectId)).count == 1 else { throw WorkspaceError.invalidSchema }
        }
        if kind == .sourceCommit {
            guard publication == nil else { throw WorkspaceError.invalidSchema }
            let project = operations.filter { $0.target.targetClass == "projectMember" }
            let history = operations.filter { $0.target.targetClass == "historyObject" }
            let metadata = operations.filter { $0.target.targetClass == "portableMetadata" }
            guard !project.isEmpty, Set(project.compactMap(\.target.projectId)).count == 1,
                  !history.isEmpty, Set(history.compactMap(\.target.objectId)).count == 1,
                  Set(metadata.compactMap(\.target.object)) == [] ||
                    Set(metadata.compactMap(\.target.object)) ==
                    ["workspaceDescriptor", "libraryCatalog", "workbenchSettings"] ||
                    Set(metadata.compactMap(\.target.object)) ==
                    ["workspaceDescriptor", "libraryCatalog", "workbenchSettings", "toolchainRequirements"],
                  metadata.isEmpty || project.contains(where: { $0.target.member == "screenpunk.project.json" && $0.after.state == "present" })
            else { throw WorkspaceError.invalidSchema }
        }
        if kind == .historyPublish {
            let history = operations.filter { $0.target.targetClass == "historyObject" }
            let metadata = operations.filter { $0.target.targetClass == "portableMetadata" }
            guard !history.isEmpty, metadata.isEmpty ||
                    (metadata.count == 3 && Set(metadata.compactMap(\.target.object)) ==
                     ["workspaceDescriptor", "libraryCatalog", "workbenchSettings"]) else {
                throw WorkspaceError.invalidSchema
            }
        }
        if kind == .packageHeadCommit {
            guard let publication else { throw WorkspaceError.invalidSchema }
            try publication.validate()
            let head = operations.filter { $0.target.targetClass == "buildHead" }
            let history = operations.filter { $0.target.targetClass == "historyObject" }
            guard head.count == 1, head[0].target.projectId == publication.projectId,
                  !history.isEmpty, Set(history.compactMap(\.target.objectId)).count == 1,
                  history.contains(where: { $0.target.member == "manifest.json" }) else {
                throw WorkspaceError.invalidSchema
            }
        } else if publication != nil { throw WorkspaceError.invalidSchema }
        if kind == .catalogSettingsCommit {
            let names = Set(operations.compactMap { $0.target.object })
            guard names.isSuperset(of: ["workspaceDescriptor", "libraryCatalog", "workbenchSettings"]) else {
                throw WorkspaceError.invalidSchema
            }
        }
    }
}

/// Every present target reserves its full published size, including an identical
/// already-present history object. Blob storage is accounted separately by hash.
enum WorkbenchTransactionAccounting {
    static let expandedLimit = 50 * 1024 * 1024
    // A source commit publishes at most 2,000 source members both into the
    // project and immutable history, one history inventory, and up to four metadata
    // members. V2 history publication allows three generation metadata targets.
    static func maximumOperations(for kind: WorkbenchTransactionKind) -> Int {
        kind == .sourceCommit ? 4_005 : kind == .historyPublish ? 2_005 : 2_000
    }
    static func expandedPublicationBytes(_ operations: [WorkbenchTransactionOperation],
                                         measuredBlobs: [String: Int],
                                         kind: WorkbenchTransactionKind = .projectEdit) throws -> Int {
        guard operations.count <= maximumOperations(for: kind) else { throw WorkspaceError.limitExceeded }
        // The project and immutable snapshot can each carry 25 MiB of source.
        // Five bounded documents (history inventory and metadata) have a separate allowance.
        let limit = kind == .sourceCommit ? expandedLimit + 5 * 8 * 1024 * 1024 :
            kind == .historyPublish ? expandedLimit + 3 * 8 * 1024 * 1024 : expandedLimit
        var total = 0
        for operation in operations where operation.after.state == "present" {
            guard let hash = operation.recoveryBlobHash, let measured = measuredBlobs[hash],
                  measured == operation.after.bytes, measured >= 0,
                  measured <= limit - total else { throw WorkspaceError.limitExceeded }
            total += measured
        }
        return total
    }
}

/// A trusted local inspector supplies a fresh, exact plan. Portable journal fields
/// never instantiate this value. A nil plan makes privileged recovery unavailable.
struct WorkbenchInspectedTransactionPlan: Sendable {
    let transactionId: String
    let kind: WorkbenchTransactionKind
    let workspaceId: String
    let bindingId: String
    let selectionGeneration: Int
    let expectedGeneration: Int
    let operations: [WorkbenchTransactionOperation]
    let reviewedExternalProjectIds: Set<String>
    /// Derived from a fresh local reference/active-operation scan, never the journal.
    let prunableHistoryTargets: Set<String>
    /// Derived from a fresh locally approved migration staging inventory.
    let verifiedMigrationTargets: Set<String>
}

protocol WorkbenchTransactionPlanInspector {
    /// Look up a locally held plan by ID. Implementations must not echo portable
    /// journal fields as a plan or retain an earlier reachability verdict.
    func currentPlan(transactionId: String) throws -> WorkbenchInspectedTransactionPlan?
}

enum WorkbenchTransactionDigest {
    static func hex(_ data: Data) -> String { DeploymentDigest.sha256Hex(data) }
}

struct WorkbenchTransactionFailure: LocalizedError {
    let transactionId: String?
    let reason: WorkspaceError
    var errorDescription: String? {
        let reference = transactionId.map { "transaction \($0)" } ?? "a transaction entry"
        switch reason {
        case .newerSchema, .invalidSchema, .invalidPath, .incomplete:
            return "Recovery stopped at \(reference): its journal or staging is unsupported or incomplete. Preserve Workbench/Transactions and inspect this entry before retrying."
        case .conflict, .alreadyExists:
            return "Recovery stopped at \(reference): current bytes, generation, binding or local plan differ. Preserve the journal and inspect the current files before an explicit recovery action."
        case .unsafeFile:
            return "Recovery stopped at \(reference): a linked, replaced or unsafe filesystem node was found. Preserve the journal and inspect the path before retrying."
        case .limitExceeded:
            return "Recovery stopped at \(reference): a processing limit was exceeded. Preserve the journal and use a quiesced folder backup for larger data."
        case .unavailable:
            return "Recovery stopped at \(reference): required files are unavailable. Preserve the journal and retry after restoring access."
        }
    }
}

/// Reject unknown/duplicate fields and unsafe number grammar before Codable decoding.
enum WorkbenchTransactionJSON {
    static func decode(_ data: Data) throws -> WorkbenchTransactionJournal {
        guard data.count <= 8 * 1024 * 1024, String(data: data, encoding: .utf8) != nil else { throw WorkspaceError.limitExceeded }
        var scanner = Scanner(bytes: Array(data)); try scanner.value(depth: 0); scanner.space()
        guard scanner.position == scanner.bytes.count,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkspaceError.invalidSchema }
        let kind = raw["kind"] as? String
        try keys(raw, kind == "packageHeadCommit"
            ? ["schemaVersion", "transactionId", "workspaceId", "kind", "expectedGeneration", "operations", "publication"]
            : ["schemaVersion", "transactionId", "workspaceId", "kind", "expectedGeneration", "operations"])
        if kind == "packageHeadCommit" {
            let publication = try object(raw["publication"])
            try keys(publication, publication.keys.contains("selectedToolchain")
                ? ["projectId", "dashboardId", "sourceVersion", "selectedToolchain"]
                : ["projectId", "dashboardId", "sourceVersion"])
            if let toolchain = publication["selectedToolchain"] as? [String: Any] {
                try keys(toolchain, ["catalogEntryId", "kitVersion", "platform", "inventoryHash"])
            }
        }
        guard let operations = raw["operations"] as? [[String: Any]],
              let kindValue = raw["kind"] as? String,
              let transactionKind = WorkbenchTransactionKind(rawValue: kindValue),
              (1...WorkbenchTransactionAccounting.maximumOperations(for: transactionKind)).contains(operations.count) else {
            throw WorkspaceError.invalidSchema
        }
        for operation in operations {
            let after = try object(operation["after"])
            let hasBlob = operation.keys.contains("recoveryBlobHash")
            try keys(operation, hasBlob ? ["target", "before", "after", "recoveryBlobHash"] : ["target", "before", "after"])
            let target = try object(operation["target"])
            let kind = raw["kind"] as? String
            let targetFields: Set<String>
            switch kind {
            case "packageHeadCommit":
                switch target["targetClass"] as? String {
                case "buildHead": targetFields = ["targetClass", "projectId"]
                case "historyObject": targetFields = ["targetClass", "objectKind", "objectId", "member"]
                default: throw WorkspaceError.invalidSchema
                }
            case "sourceCommit":
                switch target["targetClass"] as? String {
                case "projectMember": targetFields = ["targetClass", "projectId", "member"]
                case "portableMetadata": targetFields = ["targetClass", "object"]
                case "historyObject": targetFields = ["targetClass", "objectKind", "objectId", "member"]
                default: throw WorkspaceError.invalidSchema
                }
            case "projectEdit": targetFields = ["targetClass", "projectId", "member"]
            case "catalogSettingsCommit": targetFields = ["targetClass", "object"]
            case "historyPublish":
                switch target["targetClass"] as? String {
                case "historyObject": targetFields = ["targetClass", "objectKind", "objectId", "member"]
                case "portableMetadata": targetFields = ["targetClass", "object"]
                default: throw WorkspaceError.invalidSchema
                }
            case "historyPrune": targetFields = ["targetClass", "objectKind", "objectId", "member"]
            case "migrationPublish": targetFields = ["targetClass", "migrationId", "objectKind", "objectId", "member"]
            default: throw WorkspaceError.newerSchema
            }
            try keys(target, targetFields)
            for image in [try object(operation["before"]), after] {
                let state = image["state"] as? String
                if state == "present" { try keys(image, ["state", "sha256", "bytes"]) }
                else if state == "absent" { try keys(image, ["state"]) }
                else { throw WorkspaceError.invalidSchema }
            }
            guard hasBlob == (after["state"] as? String == "present") else { throw WorkspaceError.invalidSchema }
        }
        let journal: WorkbenchTransactionJournal
        do { journal = try JSONDecoder().decode(WorkbenchTransactionJournal.self, from: data) }
        catch { throw WorkspaceError.invalidSchema }
        try journal.validate()
        return journal
    }
    static func encode(_ journal: WorkbenchTransactionJournal) throws -> Data {
        try journal.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= 8 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
        _ = try decode(data)
        return data
    }
    private static func keys(_ value: [String: Any], _ fields: Set<String>) throws {
        guard Set(value.keys) == fields else { throw WorkspaceError.invalidSchema }
    }
    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw WorkspaceError.invalidSchema }
        return result
    }
    private struct Scanner {
        let bytes: [UInt8]
        var position = 0
        mutating func space() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        mutating func eat(_ byte: UInt8) throws { space(); guard position < bytes.count && bytes[position] == byte else { throw WorkspaceError.invalidSchema }; position += 1 }
        mutating func string() throws -> String {
            space(); let start = position; try eat(34)
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                if byte == 34 {
                    guard position - start <= 16_386 else { throw WorkspaceError.limitExceeded }
                    guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) else {
                        throw WorkspaceError.invalidSchema
                    }
                    return value
                }
                guard byte >= 32 else { throw WorkspaceError.invalidSchema }
                if byte == 92 { guard position < bytes.count else { throw WorkspaceError.invalidSchema }; position += 1 }
            }
            throw WorkspaceError.invalidSchema
        }
        mutating func literal(_ value: String) throws {
            let expected = Array(value.utf8)
            guard position + expected.count <= bytes.count,
                  Array(bytes[position..<position + expected.count]) == expected else { throw WorkspaceError.invalidSchema }
            position += expected.count
        }
        mutating func number() throws {
            let start = position
            if bytes[position] == 48 { position += 1 }
            else { while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 } }
            guard position > start, position - start <= 16,
                  Int(String(decoding: bytes[start..<position], as: UTF8.self)) != nil else { throw WorkspaceError.invalidSchema }
            if position < bytes.count && [46, 69, 101].contains(bytes[position]) { throw WorkspaceError.invalidSchema }
        }
        mutating func value(depth: Int) throws {
            guard depth <= 32 else { throw WorkspaceError.limitExceeded }; space()
            guard position < bytes.count else { throw WorkspaceError.invalidSchema }
            switch bytes[position] {
            case 34: _ = try string()
            case 48...57: try number()
            case 110: try literal("null")
            case 116: try literal("true")
            case 102: try literal("false")
            case 123:
                position += 1; space(); var keys = Set<String>()
                if position < bytes.count && bytes[position] == 125 { position += 1; return }
                while true {
                    let key = try string()
                    guard keys.insert(key).inserted, keys.count <= 64 else { throw WorkspaceError.invalidSchema }
                    try eat(58); try value(depth: depth + 1); space()
                    if position < bytes.count && bytes[position] == 125 { position += 1; return }
                    try eat(44)
                }
            case 91:
                position += 1; space(); var count = 0
                if position < bytes.count && bytes[position] == 93 { position += 1; return }
                while true {
                    count += 1; guard count <= 4_004 else { throw WorkspaceError.limitExceeded }
                    try value(depth: depth + 1); space()
                    if position < bytes.count && bytes[position] == 93 { position += 1; return }
                    try eat(44)
                }
            default: throw WorkspaceError.invalidSchema
            }
        }
    }
}
#endif
