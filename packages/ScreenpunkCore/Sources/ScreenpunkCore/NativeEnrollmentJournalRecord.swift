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
    let stageOwnership: NativeJournalStageOwnership?
    init(schemaVersion: Int, cloudRootID: UUID, preparationID: UUID, attemptID: UUID, intentAttemptID: UUID,
        index: Int, phase: Int, stageOwnership: NativeJournalStageOwnership? = nil) {
        self.schemaVersion = schemaVersion; self.cloudRootID = cloudRootID; self.preparationID = preparationID; self.attemptID = attemptID
        self.intentAttemptID = intentAttemptID; self.index = index; self.phase = phase; self.stageOwnership = stageOwnership
    }
}
/// Nonsecret persistent-reference ownership only; no payload/digest or remote proof.
struct NativeJournalStageOwnership: Codable, Equatable {
    let cloudRootID: UUID, preparationID: UUID, enrollmentID: UUID, localBindingID: UUID, transitionID: UUID, claimRequestID: UUID, stageAttemptID: UUID
    let stageService: String, stageAccount: String
    let persistentReference: Data
    init(_ binding: NativeEnrollmentStageBinding, persistentReference: Data, stageAttemptID: UUID) {
        cloudRootID = binding.cloudRootID; preparationID = binding.preparationID; enrollmentID = binding.enrollmentID
        localBindingID = binding.binding.credentialGenerationID; transitionID = binding.binding.transitionID; claimRequestID = binding.input.requestId
        self.stageAttemptID = stageAttemptID; stageService = NativeEnrollmentStageEnvelope.service
        stageAccount = String(decoding: binding.stage, as: UTF8.self); self.persistentReference = persistentReference
    }
    func matches(_ b: NativeEnrollmentStageBinding) -> Bool {
        cloudRootID == b.cloudRootID && preparationID == b.preparationID && enrollmentID == b.enrollmentID && localBindingID == b.binding.credentialGenerationID
            && transitionID == b.binding.transitionID && claimRequestID == b.input.requestId && Data(stageService.utf8) == Data(NativeEnrollmentStageEnvelope.service.utf8)
            && Data(stageAccount.utf8) == b.stage && (1...1024).contains(persistentReference.count)
    }
}
struct NativeJournalAttempt: Codable, Equatable {
    enum Method: String, Codable { case prepareIntent, appendPhaseAssertion, bindStageOwnership }
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
    static func stageOwnershipReservationProof(_ binding: NativeEnrollmentStageBinding) throws {
        // Pure maximum-size layout proof BEFORE backend or journal write effects.
        let owned = NativeJournalStageOwnership(binding, persistentReference: Data(repeating: 0, count: 1024), stageAttemptID: UUID())
        let f = NativeJournalFrame(schemaVersion: 2, cloudRootID: binding.cloudRootID, preparationID: binding.preparationID,
            attemptID: UUID(), intentAttemptID: UUID(), index: 448, phase: 2, stageOwnership: owned)
        let target = try encode(f)
        let identity = NativeJournalIdentity(device: UInt64.max, inode: UInt64.max)
        let a = NativeJournalAttempt(schemaVersion: 1, cloudRootID: binding.cloudRootID, preparationID: binding.preparationID,
            attemptID: f.attemptID, index: 448, method: .bindStageOwnership, rootBindingIdentity: identity, ownIdentity: identity,
            predecessor: .init(identity: identity, bytes: Data(repeating: 0, count: frameLimit)), candidateIdentity: identity,
            targetPayload: target, intentPayload: nil, reservation: 0)
        guard target.count <= frameLimit, try encode(a).count <= phaseAttemptLimit else { throw NativeEnrollmentJournalError.capacity }
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
        let o = try object(data, limit: frameLimit, keys: ["schemaVersion", "cloudRootID", "preparationID", "attemptID", "intentAttemptID", "index", "phase"], optional: ["stageOwnership"])
        for key in ["cloudRootID", "preparationID", "attemptID", "intentAttemptID"] { try uuid(o[key]) }
        if let raw = o["stageOwnership"] {
            guard let ownership = raw as? [String: Any] else { throw NativeEnrollmentJournalError.invalidRecord }
            do { try StructuralStoreCodec.keys(ownership, required: ["cloudRootID", "preparationID", "enrollmentID", "localBindingID", "transitionID", "claimRequestID", "stageAttemptID", "stageService", "stageAccount", "persistentReference"]) } catch { throw NativeEnrollmentJournalError.invalidRecord }
            for key in ["cloudRootID", "preparationID", "enrollmentID", "localBindingID", "transitionID", "claimRequestID", "stageAttemptID"] { try uuid(ownership[key]) }
            guard let ref = ownership["persistentReference"] as? String, ref.utf8.prefix(1369).count <= 1368,
                let decoded = Data(base64Encoded: ref), (1...1024).contains(decoded.count), decoded.base64EncodedString().utf8.elementsEqual(ref.utf8),
                let service = ownership["stageService"] as? String, service.utf8.elementsEqual(NativeEnrollmentStageEnvelope.service.utf8),
                let account = ownership["stageAccount"] as? String else { throw NativeEnrollmentJournalError.invalidRecord }
            _ = try NativeEnrollmentStageBinding.reference(Data(account.utf8))
        }
        let result = try JSONDecoder().decode(NativeJournalFrame.self, from: data)
        guard (result.schemaVersion == 1 && result.stageOwnership == nil) || (result.schemaVersion == 2 && result.phase == 2 && result.stageOwnership != nil) else { throw NativeEnrollmentJournalError.invalidRecord }
        guard (1...448).contains(result.index), (0...6).contains(result.phase), try encode(result) == data else { throw NativeEnrollmentJournalError.invalidRecord }; return result
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
        let f = try frame(a.targetPayload)
        guard (a.method == .bindStageOwnership) == (f.schemaVersion == 2), a.method != .prepareIntent || f.phase == 0 else { throw NativeEnrollmentJournalError.invalidRecord }
        return a
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
