import Foundation

/// Exact bytes bind retry identity; this schema makes no digest/hash claim.
/// Internal, unmounted persistence values. Caller assertions about resources are not verified durability
/// evidence, management authority, approval, migration policy, or permission to execute a package.
struct DeviceStructuralCommitEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let operationID: UUID
    let expectedGenerationID: UUID?
    let snapshot: DeviceStructuralSnapshot
    let intent: Data
    let outcome: Data
    init(operationID: UUID, expectedGenerationID: UUID?, snapshot: DeviceStructuralSnapshot, intent: Data, outcome: Data) {
        schemaVersion = 1; self.operationID = operationID; self.expectedGenerationID = expectedGenerationID
        self.snapshot = snapshot; self.intent = intent; self.outcome = outcome
    }
}

enum DeviceStructuralStoreError: Error, Equatable {
    case invalidRecord, tooLarge, unsafeBinding, conflict, capacity, outcomeUncertain
    case io(Int32)
}

struct StructuralStoreIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
}

struct DeviceStructuralOperationRecord: Codable, Equatable {
    enum Phase: String, Codable { case unresolved, prepared, terminal }
    let schemaVersion: Int
    let rootID: UUID
    let operationID: UUID
    let expectedOld: Data?
    let candidate: Data
    /// Opaque untrusted caller assertions; no package/Keychain adapter consumes these bytes.
    let resourceAssertions: Data
    let phase: Phase
    let baselineIdentity: StructuralStoreIdentity?
    let candidateIdentity: StructuralStoreIdentity?
    init(rootID: UUID, operationID: UUID, expectedOld: Data?, candidate: Data,
         resourceAssertions: Data, phase: Phase = .unresolved,
         baselineIdentity: StructuralStoreIdentity? = nil, candidateIdentity: StructuralStoreIdentity? = nil) {
        schemaVersion = 1; self.rootID = rootID; self.operationID = operationID
        self.expectedOld = expectedOld; self.candidate = candidate; self.resourceAssertions = resourceAssertions; self.phase = phase
        self.baselineIdentity = baselineIdentity; self.candidateIdentity = candidateIdentity
    }
    var terminal: Self { .init(rootID: rootID, operationID: operationID, expectedOld: expectedOld,
                              candidate: candidate, resourceAssertions: resourceAssertions, phase: .terminal, baselineIdentity: baselineIdentity, candidateIdentity: candidateIdentity)
    }
    func binding(baseline: StructuralStoreIdentity?, candidate: StructuralStoreIdentity? = nil) -> Self {
        .init(rootID: rootID, operationID: operationID, expectedOld: expectedOld, candidate: self.candidate,
              resourceAssertions: resourceAssertions, phase: candidate == nil ? .unresolved : .prepared,
              baselineIdentity: baseline, candidateIdentity: candidate) }
    func sameIntent(as other: Self) -> Bool {
        rootID == other.rootID && operationID == other.operationID && expectedOld == other.expectedOld
            && candidate == other.candidate && resourceAssertions == other.resourceAssertions
    }
}

/// Local bounded strict preflight, not an exported parser. Duplicate decoded keys and invalid UTF-16
/// escapes must be rejected before Foundation can collapse/replace them. All record keys are checked.
enum StructuralStoreCodec {
    static let envelopeLimit = 128 * 1024
    static let operationLimit = 384 * 1024
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static func object(_ bytes: Data, limit: Int) throws -> [String: Any] {
        guard bytes.count <= limit else { throw DeviceStructuralStoreError.tooLarge }
        guard String(data: bytes, encoding: .utf8) != nil else { throw DeviceStructuralStoreError.invalidRecord }
        var scan = Scan(bytes: Array(bytes))
        try scan.value(depth: 0); scan.space()
        guard scan.index == scan.bytes.count,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw DeviceStructuralStoreError.invalidRecord }
        return object
    }
    static func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional)) else { throw DeviceStructuralStoreError.invalidRecord }
    }
    static func envelope(_ bytes: Data) throws -> DeviceStructuralCommitEnvelope {
        let object = try object(bytes, limit: envelopeLimit)
        try keys(object, required: ["schemaVersion", "operationID", "snapshot", "intent", "outcome"], optional: ["expectedGenerationID"])
        let value = try JSONDecoder().decode(DeviceStructuralCommitEnvelope.self, from: bytes)
        guard value.schemaVersion == 1, value.intent.count <= 32 * 1024, value.outcome.count <= 32 * 1024,
              value.expectedGenerationID != value.snapshot.generationID else { throw DeviceStructuralStoreError.invalidRecord }
        // Deriving references checks metadata consistency only, never external resource existence/durability.
        let snapshotBytes = try JSONSerialization.data(withJSONObject: object["snapshot"]!)
        let references = value.snapshot.entries.map { DeviceStructuralPackageEvidence(directory: $0.packageDirectory, revision: $0.revision) }
        guard case .bound = DeviceStructuralStateReader.read(structural: .bytes(snapshotBytes), legacy: .missing,
            expectation: .unbound, packages: references) else { throw DeviceStructuralStoreError.invalidRecord }
        return value
    }
    static func record(_ bytes: Data) throws -> DeviceStructuralOperationRecord {
        let object = try object(bytes, limit: operationLimit)
        try keys(object, required: ["schemaVersion", "rootID", "operationID", "candidate", "resourceAssertions", "phase"], optional: ["expectedOld", "baselineIdentity", "candidateIdentity"])
        for name in ["baselineIdentity", "candidateIdentity"] {
            if let identity = object[name] {
                guard let identity = identity as? [String: Any] else { throw DeviceStructuralStoreError.invalidRecord }
                try keys(identity, required: ["device", "inode"])
            }
        }
        let value = try JSONDecoder().decode(DeviceStructuralOperationRecord.self, from: bytes)
        guard value.schemaVersion == 1, value.resourceAssertions.count <= 8 * 1024 else { throw DeviceStructuralStoreError.invalidRecord }
        guard value.phase == .unresolved ? value.candidateIdentity == nil : value.candidateIdentity != nil else { throw DeviceStructuralStoreError.invalidRecord }
        let next = try envelope(value.candidate)
        guard next.operationID == value.operationID else { throw DeviceStructuralStoreError.invalidRecord }
        if let oldBytes = value.expectedOld {
            let old = try envelope(oldBytes)
            guard old.snapshot.generationID == next.expectedGenerationID, old.operationID != next.operationID else { throw DeviceStructuralStoreError.invalidRecord }
        } else { guard next.expectedGenerationID == nil else { throw DeviceStructuralStoreError.invalidRecord } }
        return value
    }
    private struct Scan {
        let bytes: [UInt8]; var index = 0; var nodes = 8192
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) throws { guard index < bytes.count, bytes[index] == byte else { throw DeviceStructuralStoreError.invalidRecord }; index += 1 }
        mutating func value(depth: Int) throws {
            space(); nodes -= 1
            guard depth <= 32, nodes >= 0, index < bytes.count else { throw DeviceStructuralStoreError.invalidRecord }
            switch bytes[index] {
            case 123:
                index += 1; space(); var seen = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string(); guard seen.insert(key).inserted else { throw DeviceStructuralStoreError.invalidRecord }
                    space(); try take(58); try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 125 { index += 1; return }
                    try take(44); space()
                }
            case 91:
                index += 1; space()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 93 { index += 1; return }
                    try take(44)
                }
            case 34: _ = try string()
            case 116: for byte in "true".utf8 { try take(byte) }
            case 102: for byte in "false".utf8 { try take(byte) }
            case 110: for byte in "null".utf8 { try take(byte) }
            default:
                let start = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                let number = String(decoding: bytes[start..<index], as: UTF8.self)
                guard number.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw DeviceStructuralStoreError.invalidRecord }
            }
        }
        mutating func hex() throws -> UInt16 {
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard index < bytes.count else { throw DeviceStructuralStoreError.invalidRecord }
                let byte = bytes[index]; index += 1; let digit: UInt16
                switch byte { case 48...57: digit = UInt16(byte-48); case 65...70: digit = UInt16(byte-55); case 97...102: digit = UInt16(byte-87); default: throw DeviceStructuralStoreError.invalidRecord }
                value = value * 16 + digit
            }
            return value
        }
        mutating func string() throws -> String {
            let start = index; try take(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                guard byte >= 32 else { throw DeviceStructuralStoreError.invalidRecord }
                if byte == 92 {
                    guard index < bytes.count else { throw DeviceStructuralStoreError.invalidRecord }
                    let escape = bytes[index]; index += 1
                    if escape == 117 {
                        let high = try hex()
                        if (0xD800...0xDBFF).contains(high) {
                            try take(92); try take(117); let low = try hex()
                            guard (0xDC00...0xDFFF).contains(low) else { throw DeviceStructuralStoreError.invalidRecord }
                        } else if (0xDC00...0xDFFF).contains(high) { throw DeviceStructuralStoreError.invalidRecord }
                    } else if ![34,92,47,98,102,110,114,116].contains(escape) { throw DeviceStructuralStoreError.invalidRecord }
                }
            }
            throw DeviceStructuralStoreError.invalidRecord
        }
    }
}
