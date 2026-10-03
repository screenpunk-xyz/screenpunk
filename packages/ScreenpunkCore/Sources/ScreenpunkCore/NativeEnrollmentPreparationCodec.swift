import Foundation

/// A structural reconstruction proposal only. No inventory, persistence or
/// Keychain qualification is represented, and no preparation handle is produced.
public struct NativeEnrollmentPreparationReconstructionProposal: Sendable {
    public let preparationId: UUID, enrollmentId: UUID
    public let stageReference: String
    public let binding: DeviceManagementFormatHistory.Binding
    public let claimInput: NativeClaimInput
    public let phase: NativeEnrollmentPreparation.Phase
    public let sourceHistory: DeviceManagementFormatHistory, targetHistory: DeviceManagementFormatHistory
    public let sourceEnrollment: NativeEnrollmentEvidence, targetEnrollment: NativeEnrollmentEvidence
    public let reservedBytes: Int
    fileprivate init(id: UUID, enrollmentId: UUID, stage: String, binding: DeviceManagementFormatHistory.Binding,
        input: NativeClaimInput, phase: NativeEnrollmentPreparation.Phase, source: DeviceManagementFormatHistory,
        target: DeviceManagementFormatHistory, enrollment: NativeEnrollmentEvidence, proposed: NativeEnrollmentEvidence, bytes: Int) {
        preparationId = id; self.enrollmentId = enrollmentId; stageReference = stage; self.binding = binding
        claimInput = input; self.phase = phase; sourceHistory = source; targetHistory = target
        sourceEnrollment = enrollment; targetEnrollment = proposed; reservedBytes = bytes
    }
}

/// Local schema 1, one nonsecret preparation record at a time. Retained proposals
/// are structural context only; this codec does not qualify their phase as IO.
public enum NativeEnrollmentPreparationCodec {
    public enum Failure: Error, Equatable { case invalidJSON, invalidSchema, invalidContext, capacityExceeded }
    public static let maximumBytes = 2_097_152, maximumDepth = 16, maximumNodes = 131072
    public static func encodeReconstructionProposal(_ preparation: NativeEnrollmentPreparation,
        retained: [NativeEnrollmentPreparationReconstructionProposal] = []) throws -> Data {
        let object: [String: Any] = ["schemaVersion": 1, "preparationId": preparation.preparationId.uuidString,
            "enrollmentId": preparation.enrollmentId.uuidString, "stageReference": preparation.stageReference,
            "binding": try json(preparation.binding), "claimInput": try json(preparation.claimInput), "phase": preparation.phase.rawValue,
            "sourceHistory": try json(preparation.sourceHistory), "targetHistory": try json(preparation.targetHistory),
            "sourceEnrollment": try JSONSerialization.jsonObject(with: NativeEnrollmentEvidenceCodec.encode(preparation.sourceEnrollment, history: preparation.sourceHistory)),
            "targetEnrollment": try JSONSerialization.jsonObject(with: NativeEnrollmentEvidenceCodec.encode(preparation.targetEnrollment, history: preparation.targetHistory))]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maximumBytes else { throw Failure.capacityExceeded }
        _ = try decodeReconstructionProposal(data, retained: retained)
        return data
    }
    public static func decodeReconstructionProposal(_ data: Data,
        retained: [NativeEnrollmentPreparationReconstructionProposal] = []) throws -> NativeEnrollmentPreparationReconstructionProposal {
        guard retained.count < 64 else { throw Failure.capacityExceeded }
        var parser = PreparationJSONParser(data)
        let o = try fields(parser.parse(), ["schemaVersion", "preparationId", "enrollmentId", "stageReference", "binding", "claimInput", "phase", "sourceHistory", "targetHistory", "sourceEnrollment", "targetEnrollment"])
        guard case .integer(1) = o["schemaVersion"], case .integer(let p) = o["phase"], let phase = NativeEnrollmentPreparation.Phase(rawValue: p) else { throw Failure.invalidSchema }
        let id = try uuid(o["preparationId"]), enrollmentId = try uuid(o["enrollmentId"]), stage = try string(o["stageReference"])
        let binding = try parseBinding(o["binding"])
        let c = try fields(o["claimInput"], ["requestId", "transitionId", "accountId", "locationId", "name", "profile"])
        let input = try NativeClaimInput(requestId: uuid(c["requestId"]), transitionId: uuid(c["transitionId"]), accountId: uuid(c["accountId"]), locationId: uuid(c["locationId"]), name: string(c["name"]), profile: string(c["profile"]))
        let source = try history(o["sourceHistory"]), assertedTarget = try history(o["targetHistory"])
        let enrollment = try NativeEnrollmentEvidenceCodec.decode(bytes(o["sourceEnrollment"], limit: NativeEnrollmentEvidenceCodec.maximumBytes), history: source)
        let assertedEnrollment = try NativeEnrollmentEvidenceCodec.decode(bytes(o["targetEnrollment"], limit: NativeEnrollmentEvidenceCodec.maximumBytes), history: assertedTarget)
        _ = try DeviceManagementCredentialBinding(credentialGenerationID: binding.credentialGenerationID, transitionID: binding.transitionID, credentialReference: stage)
        let newIDs = [id, enrollmentId, binding.transitionID, binding.credentialGenerationID, input.requestId]
        var oldIDs = Set(source.transitions.map(\.transitionID) + source.credentials.map(\.credentialGenerationID) + retained.map(\.preparationId))
        for r in enrollment.enrollments {
            oldIDs.formUnion([r.localEnrollmentId, r.claimInput.requestId])
            for event in r.events {
                switch event {
                case .activationProposed(let i): oldIDs.insert(i.requestId)
                case .pendingClaimObserved(let c), .terminalClaimObserved(let c): oldIDs.formUnion([c.installationId, c.challengeId])
                case .historicalActivationObserved(let a): oldIDs.formUnion([a.installationId, a.initialGeneration.generationId])
                default: break
                }
            }
        }
        guard Set(newIDs).count == newIDs.count, Set(newIDs).isDisjoint(with: oldIDs),
            binding.format == .nativeInstallationV1, input.transitionId == binding.transitionID,
            source.transitions.allSatisfy({ $0.phase == .locallyFenced }),
            !source.credentials.contains(where: { $0.credentialReference.utf8.elementsEqual(binding.credentialReference.utf8) }),
            !stage.utf8.elementsEqual(binding.credentialReference.utf8),
            Set(retained.map(\.preparationId)).count == retained.count,
            retained.allSatisfy({ $0.phase == .complete && !$0.stageReference.utf8.elementsEqual(stage.utf8) }) else { throw Failure.invalidContext }
        let historical = source.credentials.filter { $0.format == .nativeInstallationV1 }
        guard historical.count == retained.count,
            historical.allSatisfy({ b in retained.filter { exactBinding($0.binding, b) }.count == 1 }) else { throw Failure.invalidContext }
        var previousIndex = -1
        for r in retained {
            guard let index = source.transitions.firstIndex(where: { $0.transitionID == r.binding.transitionID }), index > previousIndex,
                r.targetHistory.transitions.count == index + 1,
                r.targetHistory.transitions.map(\.transitionID) == Array(source.transitions.prefix(index + 1)).map(\.transitionID),
                try nativeEnrollmentBytes(r.targetHistory.credentials) == nativeEnrollmentBytes(Array(source.credentials.prefix(r.targetHistory.credentials.count))),
                r.targetEnrollment.enrollments.count <= enrollment.enrollments.count else { throw Failure.invalidContext }
            previousIndex = index
            for (old, current) in zip(r.targetEnrollment.enrollments, enrollment.enrollments) {
                guard old.localEnrollmentId == current.localEnrollmentId, exactBinding(old.binding, current.binding),
                    try nativeEnrollmentBytes(old.claimInput) == nativeEnrollmentBytes(current.claimInput),
                    old.events.count <= current.events.count,
                    try nativeEnrollmentBytes(old.events) == nativeEnrollmentBytes(Array(current.events.prefix(old.events.count))) else { throw Failure.invalidContext }
            }
        }
        let target = try DeviceManagementFormatHistory(transitions: source.transitions + [.init(transitionID: binding.transitionID, phase: .intent)], credentials: source.credentials + [binding])
        let proposed = try NativeEnrollmentRecovery.proposingClaim(in: enrollment, history: target, enrollmentId: enrollmentId, binding: binding, input: input)
        guard try nativeEnrollmentBytes(target) == nativeEnrollmentBytes(assertedTarget),
            try nativeEnrollmentBytes(proposed) == nativeEnrollmentBytes(assertedEnrollment) else { throw Failure.invalidContext }
        let reservation = 2 * DeviceManagementTransitionStore.maximumRecordBytes + (enrollment.enrollments.count + proposed.enrollments.count) * NativeEnrollmentEvidence.reservedBytesPerRecord + 4096
        guard reservation <= NativeEnrollmentPreparation.maximumReservedBytes,
            retained.reduce(reservation, { $0 + $1.reservedBytes }) <= NativeEnrollmentPreparation.maximumTotalReservedBytes else { throw Failure.capacityExceeded }
        return .init(id: id, enrollmentId: enrollmentId, stage: stage, binding: binding, input: input, phase: phase, source: source, target: target, enrollment: enrollment, proposed: proposed, bytes: reservation)
    }
    private static func exactBinding(_ a: DeviceManagementFormatHistory.Binding, _ b: DeviceManagementFormatHistory.Binding) -> Bool {
        a.credentialGenerationID == b.credentialGenerationID && a.transitionID == b.transitionID && a.format == b.format && a.credentialReference.utf8.elementsEqual(b.credentialReference.utf8)
    }
    private static func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: nativeEnrollmentBytes(value)) }
    private static func fields(_ value: PreparationJSON?, _ keys: Set<String>) throws -> [String: PreparationJSON] {
        guard case .object(let o) = value, Set(o.keys) == keys else { throw Failure.invalidSchema }; return o
    }
    private static func string(_ value: PreparationJSON?) throws -> String { guard case .string(let s) = value else { throw Failure.invalidSchema }; return s }
    private static func uuid(_ value: PreparationJSON?) throws -> UUID {
        let s = try string(value), b = Array(s.utf8)
        guard b.count == 36, b.enumerated().allSatisfy({ [8,13,18,23].contains($0.offset) ? $0.element == 45 : (48...57).contains($0.element) || (65...70).contains($0.element) || (97...102).contains($0.element) }), let id = UUID(uuidString: s) else { throw Failure.invalidSchema }; return id
    }
    private static func parseBinding(_ value: PreparationJSON?) throws -> DeviceManagementFormatHistory.Binding {
        let b = try fields(value, ["credentialGenerationID", "transitionID", "credentialReference", "format"])
        guard let format = CloudInstallationCredentialFormat(rawValue: try string(b["format"])) else { throw Failure.invalidSchema }
        return try .init(credentialGenerationID: uuid(b["credentialGenerationID"]), transitionID: uuid(b["transitionID"]), credentialReference: string(b["credentialReference"]), format: format)
    }
    private static func history(_ value: PreparationJSON?) throws -> DeviceManagementFormatHistory {
        let o = try fields(value, ["schemaVersion", "transitions", "credentials"])
        guard case .integer(3) = o["schemaVersion"], case .array(let t) = o["transitions"], case .array(let c) = o["credentials"], t.count <= 64, c.count <= 128 else { throw Failure.invalidSchema }
        let transitions = try t.map { v -> DeviceManagementTransitionEntry in
            let o = try fields(v, ["transitionID", "phase"])
            guard let phase = DeviceManagementTransitionPhase(rawValue: try string(o["phase"])) else { throw Failure.invalidSchema }
            return .init(transitionID: try uuid(o["transitionID"]), phase: phase)
        }
        let result = try DeviceManagementFormatHistory(transitions: transitions, credentials: c.map(parseBinding))
        guard try nativeEnrollmentBytes(result).count <= DeviceManagementTransitionStore.maximumRecordBytes else { throw Failure.capacityExceeded }; return result
    }
    private static func bytes(_ value: PreparationJSON?, limit: Int) throws -> Data {
        guard let value else { throw Failure.invalidSchema }
        let data = try JSONSerialization.data(withJSONObject: value.foundation, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        guard data.count <= limit else { throw Failure.capacityExceeded }; return data
    }
}
private indirect enum PreparationJSON { case object([String: PreparationJSON]), array([PreparationJSON]), string(String), integer(Int), other }
private struct PreparationJSONParser {
    typealias Failure = NativeEnrollmentPreparationCodec.Failure
    private let bytes: [UInt8]
    private var cursor = 0, nodes = 0
    init(_ data: Data) { bytes = Array(data.prefix(NativeEnrollmentPreparationCodec.maximumBytes + 1)) }
    mutating func parse() throws -> PreparationJSON {
        guard bytes.count <= NativeEnrollmentPreparationCodec.maximumBytes else { throw Failure.capacityExceeded }
        let result = try value(depth: 1, end: bytes.count); whitespace()
        guard cursor == bytes.count else { throw Failure.invalidJSON }; return result
    }
    private mutating func whitespace() { while cursor < bytes.count && [9,10,13,32].contains(bytes[cursor]) { cursor += 1 } }
    private mutating func value(depth: Int, end: Int, arrayLimit: Int? = nil) throws -> PreparationJSON {
        whitespace(); nodes += 1
        guard depth <= NativeEnrollmentPreparationCodec.maximumDepth, nodes <= NativeEnrollmentPreparationCodec.maximumNodes else { throw Failure.capacityExceeded }
        guard cursor < end else { throw Failure.invalidJSON }
        switch bytes[cursor] {
        case 123:
            cursor += 1; whitespace(); var result: [String: PreparationJSON] = [:]
            if cursor < end, bytes[cursor] == 125 { cursor += 1; return .object(result) }
            while true {
                nodes += 1; guard nodes <= NativeEnrollmentPreparationCodec.maximumNodes else { throw Failure.capacityExceeded }
                let key = try text(end: end); guard result[key] == nil else { throw Failure.invalidJSON }
                whitespace(); guard cursor < end, bytes[cursor] == 58 else { throw Failure.invalidJSON }; cursor += 1
                result[key] = try value(depth: depth + 1, end: end, arrayLimit: 128)
                whitespace(); guard cursor < end else { throw Failure.invalidJSON }
                if bytes[cursor] == 125 { cursor += 1; return .object(result) }
                guard bytes[cursor] == 44 else { throw Failure.invalidJSON }; cursor += 1; whitespace()
            }
        case 91:
            cursor += 1; whitespace(); var result: [PreparationJSON] = []
            if cursor < end, bytes[cursor] == 93 { cursor += 1; return .array(result) }
            while true {
                if let limit = arrayLimit, result.count >= limit { throw Failure.capacityExceeded }
                result.append(try value(depth: depth + 1, end: end, arrayLimit: 128))
                whitespace(); guard cursor < end else { throw Failure.invalidJSON }
                if bytes[cursor] == 93 { cursor += 1; return .array(result) }
                guard bytes[cursor] == 44 else { throw Failure.invalidJSON }; cursor += 1; whitespace()
            }
        case 34: return .string(try text(end: end))
        case 116, 102, 110:
            let word: [UInt8] = bytes[cursor] == 116 ? Array("true".utf8) : (bytes[cursor] == 102 ? Array("false".utf8) : Array("null".utf8))
            guard cursor + word.count <= end, Array(bytes[cursor..<(cursor + word.count)]) == word else { throw Failure.invalidJSON }; cursor += word.count; return .other
        case 45, 48...57:
            let start = cursor
            if bytes[cursor] == 45 { cursor += 1 }
            guard cursor < end, (48...57).contains(bytes[cursor]) else { throw Failure.invalidJSON }
            if bytes[cursor] == 48 { cursor += 1 } else { while cursor < end && (48...57).contains(bytes[cursor]) { cursor += 1; if cursor - start > 20 { throw Failure.invalidJSON } } }
            guard let n = Int(String(decoding: bytes[start..<cursor], as: UTF8.self)) else { throw Failure.invalidJSON }; return .integer(n)
        default: throw Failure.invalidJSON
        }
    }
    private mutating func text(end: Int) throws -> String {
        whitespace(); guard cursor < end, bytes[cursor] == 34 else { throw Failure.invalidJSON }; cursor += 1
        var decoded: [UInt8] = []
        while cursor < end {
            let b = bytes[cursor]; cursor += 1
            if b == 34 { guard let s = String(bytes: decoded, encoding: .utf8) else { throw Failure.invalidJSON }; return s }
            guard b >= 32 else { throw Failure.invalidJSON }
            if b != 92 { decoded.append(b) } else {
                guard cursor < end else { throw Failure.invalidJSON }; let escape = bytes[cursor]; cursor += 1
                switch escape {
                case 34, 92, 47: decoded.append(escape)
                case 98: decoded.append(8)
                case 102: decoded.append(12)
                case 110: decoded.append(10)
                case 114: decoded.append(13)
                case 116: decoded.append(9)
                case 117:
                    let first = try hex(end: end); var scalar = first
                    if (0xD800...0xDBFF).contains(first) {
                        guard cursor + 2 <= end, bytes[cursor] == 92, bytes[cursor + 1] == 117 else { throw Failure.invalidJSON }; cursor += 2
                        let second = try hex(end: end); guard (0xDC00...0xDFFF).contains(second) else { throw Failure.invalidJSON }
                        scalar = 0x10000 + (first - 0xD800) * 1024 + second - 0xDC00
                    } else if (0xDC00...0xDFFF).contains(first) { throw Failure.invalidJSON }
                    guard let unicode = UnicodeScalar(scalar) else { throw Failure.invalidJSON }; decoded.append(contentsOf: String(unicode).utf8)
                default: throw Failure.invalidJSON
                }
            }
            guard decoded.count <= 1024 else { throw Failure.capacityExceeded }
        }
        throw Failure.invalidJSON
    }
    private mutating func hex(end: Int) throws -> UInt32 {
        guard cursor + 4 <= end else { throw Failure.invalidJSON }; var result: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[cursor]; cursor += 1; let digit: UInt8
            switch b { case 48...57: digit = b - 48; case 65...70: digit = b - 55; case 97...102: digit = b - 87; default: throw Failure.invalidJSON }
            result = result * 16 + UInt32(digit)
        }
        return result
    }
}

private extension PreparationJSON {
    var foundation: Any {
        switch self {
        case .object(let o): return o.mapValues { $0.foundation }
        case .array(let a): return a.map { $0.foundation }
        case .string(let s): return s
        case .integer(let i): return i
        case .other: return NSNull()
        }
    }
}
