import Foundation

/// Unmounted, nonsecret local journal values. Neither phases nor local receipts
/// qualify Keychain inventory, remote authority or paired history/enrollment IO.
enum NativeEnrollmentJournalError: Error, Equatable {
    case invalidRecord, capacity, unsafeRoot, conflict, outcomeUncertain
    case io(Int32)
}
struct NativeJournalIdentity: Codable, Equatable {
    let device: UInt64, inode: UInt64
}
struct NativeJournalNode: Codable, Equatable {
    let identity: NativeJournalIdentity
    let bytes: Data
}
struct NativeJournalBinding: Codable, Equatable {
    let schemaVersion: Int, cloudRootID: UUID, canonicalPath: String
    let directory: NativeJournalIdentity, lock: NativeJournalIdentity
    let attempts: NativeJournalIdentity, frames: NativeJournalIdentity, ownIdentity: NativeJournalIdentity
}
struct NativeJournalFrame: Codable, Equatable {
    let schemaVersion: Int, cloudRootID: UUID, preparationID: UUID, attemptID: UUID, intentAttemptID: UUID
    let index: Int, phase: Int
}
struct NativeJournalAttempt: Codable, Equatable {
    enum Method: String, Codable { case prepareIntent, appendPhaseAssertion }
    let schemaVersion: Int, cloudRootID: UUID, preparationID: UUID, attemptID: UUID
    let index: Int, method: Method, rootBindingIdentity: NativeJournalIdentity, ownIdentity: NativeJournalIdentity
    let predecessor: NativeJournalNode?
    let candidateIdentity: NativeJournalIdentity
    let targetPayload: Data
    /// Strict preparation codec bytes, present only in initial intent attempts.
    let intentPayload: Data?
    let reservation: Int
}

/// Strict outer wrapper decoding uses the accepted bounded duplicate/UTF8/surrogate
/// preflight. The embedded preparation record is independently replayed through
/// its accepted codec, never through an unchecked Decodable model initializer.
enum NativeJournalCodec {
    static let preparationLimit = 64, phaseCount = 7
    static let attemptLimit = 2_097_152, phaseAttemptLimit = 32768, frameLimit = 8192
    static let totalReservationLimit = 134_217_728
    static let nameLimit = preparationLimit * phaseCount * 2
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func reservation(intentBytes: Int) throws -> Int {
        guard intentBytes >= 0, intentBytes <= NativeEnrollmentPreparationCodec.maximumBytes else { throw NativeEnrollmentJournalError.capacity }
        // Base64 intent expansion, generous fixed wrapper/identity space, every
        // future attempt+frame and binding bookkeeping. No pruning on failure.
        let bytes = ((intentBytes + 2) / 3) * 4 + 32768 + phaseCount * frameLimit + 6 * phaseAttemptLimit + frameLimit
        guard bytes <= attemptLimit else { throw NativeEnrollmentJournalError.capacity }; return bytes
    }
    private static func object(_ data: Data, limit: Int, keys: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard data.count <= limit else { throw NativeEnrollmentJournalError.capacity }
        do {
            let o = try StructuralStoreCodec.object(data, limit: limit)
            try StructuralStoreCodec.keys(o, required: keys, optional: optional)
            return o
        } catch { throw NativeEnrollmentJournalError.invalidRecord }
    }
    private static func identity(_ value: Any?) throws {
        guard let o = value as? [String: Any] else { throw NativeEnrollmentJournalError.invalidRecord }
        do { try StructuralStoreCodec.keys(o, required: ["device", "inode"]) } catch { throw NativeEnrollmentJournalError.invalidRecord }
    }
    private static func uuid(_ value: Any?) throws {
        guard let s = value as? String else { throw NativeEnrollmentJournalError.invalidRecord }
        let bytes = Array(s.utf8.prefix(37))
        guard bytes.count == 36, bytes.enumerated().allSatisfy({ [8,13,18,23].contains($0.offset) ? $0.element == 45 : (48...57).contains($0.element) || (65...70).contains($0.element) || (97...102).contains($0.element) }), UUID(uuidString: s) != nil else { throw NativeEnrollmentJournalError.invalidRecord }
    }
    static func binding(_ data: Data) throws -> NativeJournalBinding {
        let o = try object(data, limit: frameLimit, keys: ["schemaVersion", "cloudRootID", "canonicalPath", "directory", "lock", "attempts", "frames", "ownIdentity"])
        try uuid(o["cloudRootID"])
        for key in ["directory", "lock", "attempts", "frames", "ownIdentity"] { try identity(o[key]) }
        let result = try JSONDecoder().decode(NativeJournalBinding.self, from: data)
        guard result.schemaVersion == 1, result.canonicalPath.utf8.count <= 4096, try encode(result) == data else { throw NativeEnrollmentJournalError.invalidRecord }; return result
    }
    static func frame(_ data: Data) throws -> NativeJournalFrame {
        let o = try object(data, limit: frameLimit, keys: ["schemaVersion", "cloudRootID", "preparationID", "attemptID", "intentAttemptID", "index", "phase"])
        for key in ["cloudRootID", "preparationID", "attemptID", "intentAttemptID"] { try uuid(o[key]) }
        let result = try JSONDecoder().decode(NativeJournalFrame.self, from: data)
        guard result.schemaVersion == 1, (1...448).contains(result.index), (0...6).contains(result.phase), try encode(result) == data else { throw NativeEnrollmentJournalError.invalidRecord }; return result
    }
    static func attempt(_ data: Data) throws -> NativeJournalAttempt {
        let o = try object(data, limit: attemptLimit, keys: ["schemaVersion", "cloudRootID", "preparationID", "attemptID", "index", "method", "rootBindingIdentity", "ownIdentity", "candidateIdentity", "targetPayload", "reservation"], optional: ["predecessor", "intentPayload"])
        for key in ["cloudRootID", "preparationID", "attemptID"] { try uuid(o[key]) }
        for key in ["rootBindingIdentity", "ownIdentity", "candidateIdentity"] { try identity(o[key]) }
        if let predecessor = o["predecessor"] {
            guard let node = predecessor as? [String: Any] else { throw NativeEnrollmentJournalError.invalidRecord }
            do { try StructuralStoreCodec.keys(node, required: ["identity", "bytes"]) } catch { throw NativeEnrollmentJournalError.invalidRecord }
            try identity(node["identity"])
        }
        let a = try JSONDecoder().decode(NativeJournalAttempt.self, from: data)
        guard a.schemaVersion == 1, (1...448).contains(a.index), a.targetPayload.count <= frameLimit, try encode(a) == data,
            (a.predecessor?.bytes.count ?? 0) <= frameLimit else { throw NativeEnrollmentJournalError.invalidRecord }
        if a.method == .prepareIntent {
            guard let intent = a.intentPayload, a.reservation == (try reservation(intentBytes: intent.count)) else { throw NativeEnrollmentJournalError.invalidRecord }
        } else {
            guard a.intentPayload == nil, a.reservation == 0, data.count <= phaseAttemptLimit else { throw NativeEnrollmentJournalError.invalidRecord }
        }
        _ = try frame(a.targetPayload); return a
    }
    static func effectiveIntent(_ intent: Data, phase: Int) throws -> Data {
        guard intent.count <= NativeEnrollmentPreparationCodec.maximumBytes, (0...6).contains(phase) else { throw NativeEnrollmentJournalError.invalidRecord }
        // Caller has already qualified this initial intent through the strict codec.
        guard var o = try JSONSerialization.jsonObject(with: intent) as? [String: Any] else { throw NativeEnrollmentJournalError.invalidRecord }
        o["phase"] = phase
        let data = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= NativeEnrollmentPreparationCodec.maximumBytes else { throw NativeEnrollmentJournalError.capacity }; return data
    }
}
