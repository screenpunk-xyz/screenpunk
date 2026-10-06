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
    let pairedEvidence: NativeJournalPairAssertion?
    let promotionProtocolVersion: Int?
    let finalOwnership: NativeJournalFinalOwnership?
    let activationProposal: NativeJournalActivationProposal?
    let activationAssociation: NativeJournalActivationAssociation?
    init(schemaVersion: Int, cloudRootID: UUID, preparationID: UUID, attemptID: UUID, intentAttemptID: UUID,
        index: Int, phase: Int, stageOwnership: NativeJournalStageOwnership? = nil, pairedEvidence: NativeJournalPairAssertion? = nil, promotionProtocolVersion: Int? = nil, finalOwnership: NativeJournalFinalOwnership? = nil, activationProposal: NativeJournalActivationProposal? = nil, activationAssociation: NativeJournalActivationAssociation? = nil) {
        self.schemaVersion = schemaVersion; self.cloudRootID = cloudRootID; self.preparationID = preparationID; self.attemptID = attemptID
        self.intentAttemptID = intentAttemptID; self.index = index; self.phase = phase; self.stageOwnership = stageOwnership; self.pairedEvidence = pairedEvidence
        self.promotionProtocolVersion = promotionProtocolVersion; self.finalOwnership = finalOwnership
        self.activationProposal = activationProposal; self.activationAssociation = activationAssociation
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
/// Original stage and final persistent-reference binding; never credential bytes or remote authority.
struct NativeJournalFinalOwnership: Codable, Equatable {
    let cloudRootID: UUID, preparationID: UUID, enrollmentID: UUID, localBindingID: UUID, transitionID: UUID, claimRequestID: UUID
    let originalIntentAttemptID: UUID, promotionAttemptID: UUID, stageOwnershipAttemptID: UUID, pairedCompletionAttemptID: UUID
    let stageService: String, stageAccount: String, stagePersistentReference: Data
    let finalService: String, finalAccount: String, finalPersistentReference: Data
    func validate() throws {
        guard stageService.utf8.elementsEqual(NativeEnrollmentStageEnvelope.service.utf8),
            finalService.utf8.elementsEqual(NativeEnrollmentStageEnvelope.finalService.utf8),
            (1...1024).contains(stagePersistentReference.count), (1...1024).contains(finalPersistentReference.count),
            stagePersistentReference != finalPersistentReference else { throw NativeEnrollmentJournalError.invalidRecord }
        _ = try NativeEnrollmentStageBinding.reference(Data(stageAccount.utf8))
        _ = try NativeEnrollmentStageBinding.reference(Data(finalAccount.utf8))
    }
}
/// Closed nonsecret persistence projection. Values alone never prove HTTP provenance.
struct NativeJournalActivationProposal: Codable, Equatable {
    struct Claim: Codable, Equatable {
        let installationId: UUID, requestId: UUID, transitionId: UUID, challengeId: UUID, accountId: UUID, locationId: UUID
        let createdAt: String, expiresAt: String, outcome: String
        init(_ c: NativeClaimReceipt) {
            installationId = c.installationId; requestId = c.requestId; transitionId = c.transitionId; challengeId = c.challengeId
            accountId = c.accountId; locationId = c.locationId; createdAt = c.createdAt; expiresAt = c.expiresAt; outcome = c.outcome.rawValue
        }
        func receipt() throws -> NativeClaimReceipt {
            guard outcome == "pending" else { throw NativeEnrollmentJournalError.invalidRecord }
            return try .init(installationId: installationId, requestId: requestId, transitionId: transitionId, challengeId: challengeId,
                accountId: accountId, locationId: locationId, createdAt: createdAt, expiresAt: expiresAt, outcome: .pending)
        }
    }
    struct Input: Codable, Equatable {
        let installationId: UUID, requestId: UUID, challengeId: UUID, transitionId: UUID
        init(_ i: NativeActivationInput) { installationId = i.installationId; requestId = i.requestId; challengeId = i.challengeId; transitionId = i.transitionId }
        var value: NativeActivationInput { .init(installationId: installationId, requestId: requestId, challengeId: challengeId, transitionId: transitionId) }
    }
    let pendingClaim: Claim, activationInput: Input
    init(claim: NativeClaimReceipt, input: NativeActivationInput) throws {
        pendingClaim = Claim(claim); activationInput = Input(input); try validate()
    }
    func validate() throws {
        _ = try pendingClaim.receipt()
        guard activationInput.installationId == pendingClaim.installationId, activationInput.challengeId == pendingClaim.challengeId,
            activationInput.transitionId == pendingClaim.transitionId, activationInput.requestId != pendingClaim.requestId else { throw NativeEnrollmentJournalError.invalidRecord }
    }
    func matches(_ binding: NativeEnrollmentStageBinding) -> Bool {
        pendingClaim.requestId == binding.input.requestId && pendingClaim.transitionId == binding.binding.transitionID
            && pendingClaim.accountId == binding.input.accountId && pendingClaim.locationId == binding.input.locationId
    }
}
struct NativeJournalActivationAssociation: Codable, Equatable {
    struct Activation: Codable, Equatable {
        struct Generation: Codable, Equatable {
            let generationId: UUID
            let createdAt: String, renewAfter: String, expiresAt: String
        }
        let installationId: UUID, deviceId: UUID, requestId: UUID, accountId: UUID, locationId: UUID, transitionId: UUID
        let activatedAt: String
        let initialGeneration: Generation
        init(_ a: NativeActivationReceipt) {
            installationId = a.installationId; deviceId = a.deviceId; requestId = a.requestId; accountId = a.accountId; locationId = a.locationId; transitionId = a.transitionId; activatedAt = a.activatedAt
            initialGeneration = .init(generationId: a.initialGeneration.generationId, createdAt: a.initialGeneration.createdAt,
                renewAfter: a.initialGeneration.renewAfter, expiresAt: a.initialGeneration.expiresAt)
        }
        func receipt() throws -> NativeActivationReceipt {
            try .init(installationId: installationId, deviceId: deviceId, requestId: requestId, accountId: accountId, locationId: locationId,
                transitionId: transitionId, activatedAt: activatedAt, initialGeneration: .init(generationId: initialGeneration.generationId,
                    createdAt: initialGeneration.createdAt, renewAfter: initialGeneration.renewAfter, expiresAt: initialGeneration.expiresAt))
        }
    }
    let activationInput: NativeJournalActivationProposal.Input, activation: Activation, finalOwnershipAttemptID: UUID
    init(proposal: NativeJournalActivationProposal, receipt: NativeActivationReceipt, finalOwnershipAttemptID: UUID) throws {
        activationInput = proposal.activationInput; activation = Activation(receipt); self.finalOwnershipAttemptID = finalOwnershipAttemptID
        try validate(proposal: proposal)
    }
    func validate(proposal: NativeJournalActivationProposal) throws {
        _ = try activation.receipt(); try proposal.validate()
        guard activationInput == proposal.activationInput, activation.installationId == activationInput.installationId,
            activation.requestId == activationInput.requestId, activation.transitionId == activationInput.transitionId,
            activation.accountId == proposal.pendingClaim.accountId, activation.locationId == proposal.pendingClaim.locationId else { throw NativeEnrollmentJournalError.invalidRecord }
    }
}
struct NativeJournalAttempt: Codable, Equatable {
    enum Method: String, Codable { case prepareIntent, appendPhaseAssertion, bindStageOwnership, pairedEvidence, bindFinalOwnership, bindActivationAssociation }
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
/// Physical record projection only. No decoded intent, persistence acknowledgment,
/// authority, or factory for an operational preparation is carried here.
struct NativeJournalAttemptWitness {
    private let small: NativeJournalAttempt
    let decodedIntentBytes: Int?
    fileprivate init(_ small: NativeJournalAttempt, decodedIntentBytes: Int?) {
        self.small = small; self.decodedIntentBytes = decodedIntentBytes
    }
    var schemaVersion: Int { small.schemaVersion }
    var cloudRootID: UUID { small.cloudRootID }
    var preparationID: UUID { small.preparationID }
    var attemptID: UUID { small.attemptID }
    var index: Int { small.index }
    var method: NativeJournalAttempt.Method { small.method }
    var rootBindingIdentity: NativeJournalIdentity { small.rootBindingIdentity }
    var ownIdentity: NativeJournalIdentity { small.ownIdentity }
    var predecessor: NativeJournalNode? { small.predecessor }
    var candidateIdentity: NativeJournalIdentity { small.candidateIdentity }
    var targetPayload: Data { small.targetPayload }
    var reservation: Int { small.reservation }
}

/// Scans borrowed raw bytes; only the canonical top-level intent string body is
/// omitted from the small wrapper. Every other byte remains for strict decoding
/// and exact canonical reencoding. Large intent base64 is never materialized.
private struct NativeJournalWitnessSpanScanner {
    let bytes: UnsafeRawBufferPointer
    var offset = 0, nodes = 0
    var intentBody: Range<Int>?
    var intentDecodedBytes: Int?
    mutating func scan() throws -> Range<Int>? {
        try value(depth: 0, top: true)
        guard offset == bytes.count else { throw NativeEnrollmentJournalError.invalidRecord }
        return intentBody
    }
    mutating func take(_ byte: UInt8) throws {
        guard offset < bytes.count, bytes[offset] == byte else { throw NativeEnrollmentJournalError.invalidRecord }
        offset += 1
    }
    mutating func string() throws -> Range<Int> {
        try take(34); let start = offset
        while offset < bytes.count {
            let b = bytes[offset]
            if b == 34 { let result = start..<offset; offset += 1; return result }
            guard b >= 32 else { throw NativeEnrollmentJournalError.invalidRecord }
            if b == 92 {
                offset += 1
                guard offset < bytes.count else { throw NativeEnrollmentJournalError.invalidRecord }
                let escaped = bytes[offset]
                if escaped == 117 {
                    guard offset + 4 < bytes.count else { throw NativeEnrollmentJournalError.invalidRecord }
                    for i in (offset + 1)...(offset + 4) {
                        let x = bytes[i]
                        guard (48...57).contains(x) || (65...70).contains(x) || (97...102).contains(x) else { throw NativeEnrollmentJournalError.invalidRecord }
                    }
                    offset += 4
                } else {
                    guard [34,92,47,98,102,110,114,116].contains(escaped) else { throw NativeEnrollmentJournalError.invalidRecord }
                }
            }
            offset += 1
        }
        throw NativeEnrollmentJournalError.invalidRecord
    }
    func isIntent(_ key: Range<Int>) -> Bool {
        let expected: [UInt8] = [105,110,116,101,110,116,80,97,121,108,111,97,100]
        return key.count == expected.count && zip(key, expected).allSatisfy { bytes[$0.0] == $0.1 }
    }
    mutating func value(depth: Int, top: Bool = false) throws {
        nodes += 1
        guard depth <= 16, nodes <= 65536, offset < bytes.count else { throw NativeEnrollmentJournalError.invalidRecord }
        switch bytes[offset] {
        case 123:
            offset += 1
            if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
            while true {
                let key = try string(); try take(58)
                if top && isIntent(key) {
                    guard intentBody == nil else { throw NativeEnrollmentJournalError.invalidRecord }
                    intentBody = try intentString()
                } else { try value(depth: depth + 1) }
                guard offset < bytes.count else { throw NativeEnrollmentJournalError.invalidRecord }
                if bytes[offset] == 125 { offset += 1; return }
                try take(44)
            }
        case 91:
            offset += 1
            if offset < bytes.count, bytes[offset] == 93 { offset += 1; return }
            while true {
                try value(depth: depth + 1)
                guard offset < bytes.count else { throw NativeEnrollmentJournalError.invalidRecord }
                if bytes[offset] == 93 { offset += 1; return }
                try take(44)
            }
        case 34: _ = try string()
        default:
            let start = offset
            while offset < bytes.count, ![44,93,125].contains(bytes[offset]) { offset += 1 }
            guard offset > start else { throw NativeEnrollmentJournalError.invalidRecord }
            // Exact JSON token grammar/canonical spelling is checked by the
            // bounded small wrapper decoder; no primitive token is omitted.
        }
    }
    mutating func intentString() throws -> Range<Int> {
        try take(34); let start = offset
        var padding = 0, lastDigit: UInt8 = 0
        while offset < bytes.count, bytes[offset] != 34 {
            let b = bytes[offset]
            if b == 61 {
                padding += 1
                guard padding <= 2 else { throw NativeEnrollmentJournalError.invalidRecord }
            } else {
                guard padding == 0 else { throw NativeEnrollmentJournalError.invalidRecord }
                if b >= 65 && b <= 90 { lastDigit = b - 65 }
                else if b >= 97 && b <= 122 { lastDigit = b - 97 + 26 }
                else if b >= 48 && b <= 57 { lastDigit = b - 48 + 52 }
                else if b == 43 { lastDigit = 62 }
                else if b == 47 { lastDigit = 63 }
                else { throw NativeEnrollmentJournalError.invalidRecord }
            }
            offset += 1
        }
        let count = offset - start
        guard count % 4 == 0, (padding == 0 || count >= 4),
            padding != 2 || lastDigit & 15 == 0,
            padding != 1 || lastDigit & 3 == 0 else { throw NativeEnrollmentJournalError.invalidRecord }
        let decoded = (count / 4) * 3 - padding
        guard decoded <= NativeEnrollmentPreparationCodec.maximumBytes else { throw NativeEnrollmentJournalError.capacity }
        let result = start..<offset; try take(34)
        intentDecodedBytes = decoded; return result
    }
}

enum NativeJournalCodec {
    static let preparationLimit = 64, phaseCount = 7
    static let attemptLimit = 2_097_152, phaseAttemptLimit = 32768, frameLimit = 8192
    static let totalReservationLimit = 134_217_728
    // The legacy reservation is unchanged. The separately admitted workspace
    // reserves all 323 auxiliary nodes before the first workspace effect.
    static let legacyNodeLimit = 448, nodeLimit = 771, compactDeclarationLimit = 394_752
    static let pairedReservationLimit = 33_554_432, combinedReservationLimit = 167_772_160
    static let nameLimit = nodeLimit * 2
    static let pairedCompletionReservation = 323 * (phaseAttemptLimit + frameLimit) + 3 * (65536 + 1048576) + 2 * frameLimit + phaseAttemptLimit + frameLimit
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
        for (frameVersion, attemptVersion, maximumIndex) in [(2, 1, legacyNodeLimit), (3, 2, nodeLimit), (4, 3, nodeLimit)] {
            let f = NativeJournalFrame(schemaVersion: frameVersion, cloudRootID: binding.cloudRootID, preparationID: binding.preparationID,
                attemptID: UUID(), intentAttemptID: UUID(), index: maximumIndex, phase: 2, stageOwnership: owned, promotionProtocolVersion: frameVersion == 4 ? 1 : nil)
            let target = try encode(f)
            let identity = NativeJournalIdentity(device: UInt64.max, inode: UInt64.max)
            let a = NativeJournalAttempt(schemaVersion: attemptVersion, cloudRootID: binding.cloudRootID, preparationID: binding.preparationID,
                attemptID: f.attemptID, index: maximumIndex, method: .bindStageOwnership, rootBindingIdentity: identity, ownIdentity: identity,
                predecessor: .init(identity: identity, bytes: Data(repeating: 0, count: frameLimit)), candidateIdentity: identity,
                targetPayload: target, intentPayload: nil, reservation: 0)
            guard target.count <= frameLimit, try encode(a).count <= phaseAttemptLimit else { throw NativeEnrollmentJournalError.capacity }
        }
    }
    static func firstNativeLayoutReservationProof() throws -> (intentBytes: Int, frameBytes: Int, attemptBytes: Int) {
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: String(repeating: "F", count: 128), format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(),
            name: String(repeating: "😀", count: 128), profile: String(repeating: "😀", count: 128))
        let first = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: String(repeating: "S", count: 128), binding: binding, claimInput: input)
        let intent = try NativeEnrollmentPreparationCodec.encodeFirstNativeProposal(first)
        let decoded = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(intent)
        guard decoded.source.isFirstNative, decoded.sourceEnrollment.enrollments.isEmpty,
            intent.count <= NativeEnrollmentPreparationCodec.maximumBytes,
            try reservation(intentBytes: intent.count) <= NativeEnrollmentPreparation.maximumReservedBytes else { throw NativeEnrollmentJournalError.capacity }
        let maximum = try promotionLayoutReservationProof()
        return (intent.count, maximum.frameBytes, maximum.attemptBytes)
    }
    static func promotionLayoutReservationProof() throws -> (frameBytes: Int, attemptBytes: Int) {
        let id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let ref = Data(repeating: 255, count: 1024), account = String(repeating: "A", count: 128)
        let owned = NativeJournalFinalOwnership(cloudRootID: id, preparationID: id, enrollmentID: id, localBindingID: id, transitionID: id, claimRequestID: id,
            originalIntentAttemptID: id, promotionAttemptID: id, stageOwnershipAttemptID: id, pairedCompletionAttemptID: id,
            stageService: NativeEnrollmentStageEnvelope.service, stageAccount: account, stagePersistentReference: ref,
            finalService: NativeEnrollmentStageEnvelope.finalService, finalAccount: String(repeating: "B", count: 128), finalPersistentReference: Data(repeating: 254, count: 1024))
        let fraction = String(repeating: "0", count: 235)
        func timestamp(_ day: String, minute: String = "00") -> String { day + "T00:" + minute + ":00." + fraction + "Z" }
        let claim = try NativeClaimReceipt(installationId: id, requestId: id, transitionId: id, challengeId: id,
            accountId: id, locationId: id, createdAt: timestamp("2026-10-05"), expiresAt: timestamp("2026-10-05", minute: "10"), outcome: .pending)
        let remoteID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let proposal = try NativeJournalActivationProposal(claim: claim, input: .init(installationId: id, requestId: remoteID, challengeId: id, transitionId: id))
        let receipt = try NativeActivationReceipt(installationId: id, deviceId: id, requestId: remoteID, accountId: id, locationId: id,
            transitionId: id, activatedAt: timestamp("2026-10-05"), initialGeneration: .init(generationId: id,
                createdAt: timestamp("2026-10-05"), renewAfter: timestamp("2026-11-04"), expiresAt: timestamp("2027-01-03")))
        let association = try NativeJournalActivationAssociation(proposal: proposal, receipt: receipt, finalOwnershipAttemptID: id)
        let frames = [
            NativeJournalFrame(schemaVersion: 4, cloudRootID: id, preparationID: id, attemptID: id, intentAttemptID: id,
                index: nodeLimit, phase: 4, promotionProtocolVersion: 1, activationProposal: proposal),
            NativeJournalFrame(schemaVersion: 4, cloudRootID: id, preparationID: id, attemptID: id, intentAttemptID: id,
                index: nodeLimit, phase: 5, promotionProtocolVersion: 1, finalOwnership: owned),
            NativeJournalFrame(schemaVersion: 4, cloudRootID: id, preparationID: id, attemptID: id, intentAttemptID: id,
                index: nodeLimit, phase: 6, promotionProtocolVersion: 1, activationAssociation: association)]
        let identity = NativeJournalIdentity(device: .max, inode: .max)
        var payload = Data(), bytes = Data()
        for frame in frames {
            let encoded = try encode(frame)
            let attempt = NativeJournalAttempt(schemaVersion: 3, cloudRootID: id, preparationID: id, attemptID: id, index: nodeLimit,
                method: frame.phase == 6 ? .bindActivationAssociation : (frame.phase == 5 ? .bindFinalOwnership : .appendPhaseAssertion),
                rootBindingIdentity: identity, ownIdentity: identity,
                predecessor: .init(identity: identity, bytes: Data(repeating: 255, count: frameLimit)), candidateIdentity: identity,
                targetPayload: encoded, intentPayload: nil, reservation: 0)
            let encodedAttempt = try encode(attempt)
            guard encoded.count <= frameLimit, encodedAttempt.count <= phaseAttemptLimit else { throw NativeEnrollmentJournalError.capacity }
            if encoded.count > payload.count { payload = encoded }
            if encodedAttempt.count > bytes.count { bytes = encodedAttempt }
        }
        guard payload.count <= frameLimit, bytes.count <= phaseAttemptLimit,
            preparationLimit * phaseCount == legacyNodeLimit, nodeLimit == legacyNodeLimit + 323,
            pairedCompletionReservation <= pairedReservationLimit,
            totalReservationLimit + pairedReservationLimit == combinedReservationLimit else { throw NativeEnrollmentJournalError.capacity }
        return (payload.count, bytes.count)
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
        let o = try object(data, limit: frameLimit, keys: ["schemaVersion", "cloudRootID", "preparationID", "attemptID", "intentAttemptID", "index", "phase"], optional: ["stageOwnership", "pairedEvidence", "promotionProtocolVersion", "finalOwnership", "activationProposal", "activationAssociation"])
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
        if let raw = o["finalOwnership"] {
            guard let owned = raw as? [String: Any] else { throw NativeEnrollmentJournalError.invalidRecord }
            let ids: Set<String> = ["cloudRootID", "preparationID", "enrollmentID", "localBindingID", "transitionID", "claimRequestID", "originalIntentAttemptID", "promotionAttemptID", "stageOwnershipAttemptID", "pairedCompletionAttemptID"]
            try StructuralStoreCodec.keys(owned, required: ids.union(["stageService", "stageAccount", "stagePersistentReference", "finalService", "finalAccount", "finalPersistentReference"]))
            for key in ids { try uuid(owned[key]) }
            for key in ["stagePersistentReference", "finalPersistentReference"] {
                guard let text = owned[key] as? String, text.utf8.prefix(1369).count <= 1368,
                    let decoded = Data(base64Encoded: text), (1...1024).contains(decoded.count),
                    decoded.base64EncodedString().utf8.elementsEqual(text.utf8) else { throw NativeEnrollmentJournalError.invalidRecord }
            }
        }
        func closed(_ value: Any?, _ keys: Set<String>, ids: Set<String> = []) throws -> [String: Any] {
            guard let value = value as? [String: Any] else { throw NativeEnrollmentJournalError.invalidRecord }
            try StructuralStoreCodec.keys(value, required: keys)
            for key in ids { try uuid(value[key]) }
            return value
        }
        let inputKeys: Set<String> = ["installationId", "requestId", "challengeId", "transitionId"]
        if let raw = o["activationProposal"] {
            let value = try closed(raw, ["pendingClaim", "activationInput"])
            _ = try closed(value["activationInput"], inputKeys, ids: inputKeys)
            let claimIDs: Set<String> = ["installationId", "requestId", "transitionId", "challengeId", "accountId", "locationId"]
            _ = try closed(value["pendingClaim"], claimIDs.union(["createdAt", "expiresAt", "outcome"]), ids: claimIDs)
        }
        if let raw = o["activationAssociation"] {
            let value = try closed(raw, ["activationInput", "activation", "finalOwnershipAttemptID"], ids: ["finalOwnershipAttemptID"])
            _ = try closed(value["activationInput"], inputKeys, ids: inputKeys)
            let activationIDs: Set<String> = ["installationId", "deviceId", "requestId", "accountId", "locationId", "transitionId"]
            let activation = try closed(value["activation"], activationIDs.union(["activatedAt", "initialGeneration"]), ids: activationIDs)
            _ = try closed(activation["initialGeneration"], ["generationId", "createdAt", "renewAfter", "expiresAt"], ids: ["generationId"])
        }
        let result = try JSONDecoder().decode(NativeJournalFrame.self, from: data)
        guard (result.schemaVersion == 1 && result.stageOwnership == nil && result.pairedEvidence == nil)
            || (result.schemaVersion == 2 && result.phase == 2 && result.stageOwnership != nil && result.pairedEvidence == nil)
            || (result.schemaVersion == 3 && (result.stageOwnership == nil || result.phase == 2))
            || (result.schemaVersion == 4 && result.promotionProtocolVersion == 1 && (result.stageOwnership == nil || result.phase == 2)) else { throw NativeEnrollmentJournalError.invalidRecord }
        guard result.schemaVersion == 4 || (result.promotionProtocolVersion == nil && result.finalOwnership == nil && result.activationProposal == nil && result.activationAssociation == nil) else { throw NativeEnrollmentJournalError.invalidRecord }
        if let owned = result.finalOwnership {
            guard result.schemaVersion == 4, result.phase == 5, result.stageOwnership == nil, result.pairedEvidence == nil,
                owned.cloudRootID == result.cloudRootID, owned.preparationID == result.preparationID,
                owned.originalIntentAttemptID == result.intentAttemptID else { throw NativeEnrollmentJournalError.invalidRecord }
            try owned.validate()
        }
        guard result.schemaVersion != 4 || result.phase != 5 || result.finalOwnership != nil else { throw NativeEnrollmentJournalError.invalidRecord }
        if let proposal = result.activationProposal {
            guard result.schemaVersion == 4, result.phase == 4, result.finalOwnership == nil, result.pairedEvidence == nil, result.stageOwnership == nil else { throw NativeEnrollmentJournalError.invalidRecord }
            try proposal.validate()
        }
        if let association = result.activationAssociation {
            guard result.schemaVersion == 4, result.phase == 6, result.finalOwnership == nil, result.pairedEvidence == nil, result.stageOwnership == nil else { throw NativeEnrollmentJournalError.invalidRecord }
            _ = try association.activation.receipt()
        }
        guard result.schemaVersion != 4 || result.phase != 4 || result.activationProposal != nil,
            result.schemaVersion != 4 || result.phase != 6 || result.activationAssociation != nil else { throw NativeEnrollmentJournalError.invalidRecord }
        if let pair = result.pairedEvidence {
            guard [3, 4].contains(result.schemaVersion), result.stageOwnership == nil,
                result.phase == (pair.role == .targetComplete ? 3 : 2) else { throw NativeEnrollmentJournalError.invalidRecord }
            try pair.validate()
        }
        guard (1...(result.schemaVersion >= 3 ? nodeLimit : legacyNodeLimit)).contains(result.index), (0...6).contains(result.phase), try encode(result) == data else { throw NativeEnrollmentJournalError.invalidRecord }; return result
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
        guard (1...3).contains(a.schemaVersion), (1...(a.schemaVersion == 1 ? legacyNodeLimit : nodeLimit)).contains(a.index), a.targetPayload.count <= frameLimit, try encode(a) == data,
            (a.predecessor?.bytes.count ?? 0) <= frameLimit else { throw NativeEnrollmentJournalError.invalidRecord }
        if a.method == .prepareIntent {
            guard let intent = a.intentPayload, a.reservation == (try reservation(intentBytes: intent.count)) else { throw NativeEnrollmentJournalError.invalidRecord }
        } else {
            guard a.intentPayload == nil, a.reservation == 0, data.count <= phaseAttemptLimit else { throw NativeEnrollmentJournalError.invalidRecord }
        }
        let f = try frame(a.targetPayload)
        guard ((a.schemaVersion == 1 && f.schemaVersion <= 2) || (a.schemaVersion == 2 && f.schemaVersion == 3) || (a.schemaVersion == 3 && f.schemaVersion == 4)),
            (a.method == .bindStageOwnership) == (f.stageOwnership != nil),
            (a.method == .pairedEvidence) == (f.pairedEvidence != nil),
            (a.method == .bindFinalOwnership) == (f.finalOwnership != nil),
            (a.method == .bindActivationAssociation) == (f.activationAssociation != nil), a.method != .prepareIntent || f.phase == 0 else { throw NativeEnrollmentJournalError.invalidRecord }
        return a
    }
    /// Fresh physical witness validation. Full semantic admission MUST still use
    /// `attempt` and the preparation codec; skipped intent is not trusted content.
    static func attemptWitness(_ data: Data) throws -> NativeJournalAttemptWitness {
        guard data.count <= attemptLimit else { throw NativeEnrollmentJournalError.capacity }
        let scanned: (Range<Int>?, Int?) = try data.withUnsafeBytes { raw in
            var scanner = NativeJournalWitnessSpanScanner(bytes: raw)
            let range = try scanner.scan()
            return (range, scanner.intentDecodedBytes)
        }
        let remaining = data.count - (scanned.0?.count ?? 0)
        guard remaining <= phaseAttemptLimit else { throw NativeEnrollmentJournalError.capacity }
        let small: Data
        if let body = scanned.0 {
            var wrapper = Data(); wrapper.reserveCapacity(remaining)
            wrapper.append(data.prefix(body.lowerBound)); wrapper.append(data.suffix(data.count - body.upperBound))
            small = wrapper
        } else { small = data }
        let o = try object(small, limit: phaseAttemptLimit, keys: ["schemaVersion", "cloudRootID", "preparationID", "attemptID", "index", "method", "rootBindingIdentity", "ownIdentity", "candidateIdentity", "targetPayload", "reservation"], optional: ["predecessor", "intentPayload"])
        for key in ["cloudRootID", "preparationID", "attemptID"] { try uuid(o[key]) }
        for key in ["rootBindingIdentity", "ownIdentity", "candidateIdentity"] { try identity(o[key]) }
        if let predecessor = o["predecessor"] {
            guard let node = predecessor as? [String: Any] else { throw NativeEnrollmentJournalError.invalidRecord }
            do { try StructuralStoreCodec.keys(node, required: ["identity", "bytes"]) } catch { throw NativeEnrollmentJournalError.invalidRecord }
            try identity(node["identity"])
        }
        let a = try JSONDecoder().decode(NativeJournalAttempt.self, from: small)
        guard (1...3).contains(a.schemaVersion),
            (1...(a.schemaVersion == 1 ? legacyNodeLimit : nodeLimit)).contains(a.index),
            a.targetPayload.count <= frameLimit, (a.predecessor?.bytes.count ?? 0) <= frameLimit,
            try encode(a) == small else { throw NativeEnrollmentJournalError.invalidRecord }
        if a.method == .prepareIntent {
            guard let decoded = scanned.1, a.intentPayload == Data(),
                a.reservation == (try reservation(intentBytes: decoded)) else { throw NativeEnrollmentJournalError.invalidRecord }
        } else {
            guard scanned.0 == nil, a.intentPayload == nil, a.reservation == 0,
                data.count <= phaseAttemptLimit else { throw NativeEnrollmentJournalError.invalidRecord }
        }
        let f = try frame(a.targetPayload)
        guard ((a.schemaVersion == 1 && f.schemaVersion <= 2) || (a.schemaVersion == 2 && f.schemaVersion == 3) || (a.schemaVersion == 3 && f.schemaVersion == 4)),
            (a.method == .bindStageOwnership) == (f.stageOwnership != nil),
            (a.method == .pairedEvidence) == (f.pairedEvidence != nil),
            (a.method == .bindFinalOwnership) == (f.finalOwnership != nil),
            (a.method == .bindActivationAssociation) == (f.activationAssociation != nil),
            a.method != .prepareIntent || f.phase == 0 else { throw NativeEnrollmentJournalError.invalidRecord }
        return .init(a, decodedIntentBytes: scanned.1)
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

/// Projection references retain provenance without copying source/target payloads.
struct NativeJournalPairProjection: Codable, Equatable {
    enum Kind: String, Codable { case source, target }
    let intentAttemptID: UUID, kind: Kind
}
struct NativeJournalPairFiles: Codable, Equatable {
    let history: NativeJournalIdentity, enrollment: NativeJournalIdentity
}
struct NativeJournalPairRoot: Codable, Equatable {
    let directory: NativeJournalIdentity, lock: NativeJournalIdentity, binding: NativeJournalIdentity
    let initializationAttemptID: UUID
    let reservationAttemptID: UUID, reservationIdentity: NativeJournalIdentity
}
struct NativeJournalPairBaseline: Codable, Equatable {
    let projection: NativeJournalPairProjection, files: NativeJournalPairFiles, completionAttemptID: UUID
}
struct NativeJournalPairAssertion: Codable, Equatable {
    enum Role: String, Codable, CaseIterable {
        case initReserve, initBind, initComplete
        case sourceReserve, sourceBind, sourceComplete, targetReserve, targetBind, targetComplete
    }
    let role: Role, operationID: UUID
    let projection: NativeJournalPairProjection
    let root: NativeJournalPairRoot?
    let baseline: NativeJournalPairBaseline?
    let candidates: NativeJournalPairFiles?
    let workspaceReservation: Int
    func validate() throws {
        guard workspaceReservation == (role == .initReserve ? NativeJournalCodec.pairedReservationLimit : 0),
            (role == .initReserve) == (root == nil),
            [.sourceBind, .sourceComplete, .targetBind, .targetComplete].contains(role) == (candidates != nil),
            ![.initReserve, .initBind, .initComplete].contains(role) || baseline == nil,
            projection.kind == ([.targetReserve, .targetBind, .targetComplete].contains(role) ? .target : .source) else {
            throw NativeEnrollmentJournalError.invalidRecord
        }
    }
}
struct NativeJournalPairRootBinding: Codable, Equatable {
    let schemaVersion: Int, cloudRootID: UUID
    let journalBinding: NativeJournalIdentity, root: NativeJournalPairRoot
}

extension NativeJournalCodec {
    /// Conservative complete new layout proof, run before workspace admission.
    /// Old reservation accounting and old schemas are not repriced or relabeled.
    static func pairedLayoutReservationProof() throws {
        guard pairedCompletionReservation == 16_629_760, pairedCompletionReservation <= pairedReservationLimit,
            totalReservationLimit + pairedReservationLimit == combinedReservationLimit,
            nodeLimit * 512 == compactDeclarationLimit else { throw NativeEnrollmentJournalError.capacity }
        let id = UUID(), identity = NativeJournalIdentity(device: .max, inode: .max)
        let root = NativeJournalPairRoot(directory: identity, lock: identity, binding: identity, initializationAttemptID: id, reservationAttemptID: id, reservationIdentity: identity)
        let files = NativeJournalPairFiles(history: identity, enrollment: identity)
        let baseline = NativeJournalPairBaseline(projection: .init(intentAttemptID: id, kind: .target), files: files, completionAttemptID: id)
        guard try encode(NativeJournalPairRootBinding(schemaVersion: 1, cloudRootID: id, journalBinding: identity, root: root)).count <= frameLimit else { throw NativeEnrollmentJournalError.capacity }
        for role in NativeJournalPairAssertion.Role.allCases {
            let pair = NativeJournalPairAssertion(role: role, operationID: id,
                projection: .init(intentAttemptID: id, kind: [.targetReserve, .targetBind, .targetComplete].contains(role) ? .target : .source),
                root: role == .initReserve ? nil : root,
                baseline: [.initReserve, .initBind, .initComplete].contains(role) ? nil : baseline,
                candidates: [.sourceBind, .sourceComplete, .targetBind, .targetComplete].contains(role) ? files : nil,
                workspaceReservation: role == .initReserve ? pairedReservationLimit : 0)
            try pair.validate()
            let frame = NativeJournalFrame(schemaVersion: 3, cloudRootID: id, preparationID: id, attemptID: id, intentAttemptID: id, index: nodeLimit, phase: role == .targetComplete ? 3 : 2, pairedEvidence: pair)
            let target = try encode(frame)
            let attempt = NativeJournalAttempt(schemaVersion: 2, cloudRootID: id, preparationID: id, attemptID: id, index: nodeLimit, method: .pairedEvidence, rootBindingIdentity: identity, ownIdentity: identity,
                predecessor: .init(identity: identity, bytes: Data(repeating: 0, count: frameLimit)), candidateIdentity: identity, targetPayload: target, intentPayload: nil, reservation: 0)
            guard target.count <= frameLimit, try encode(attempt).count <= phaseAttemptLimit else { throw NativeEnrollmentJournalError.capacity }
        }
    }
}
