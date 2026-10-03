import Foundation

/// Local schema version 1, not an HTTP response decoder or durable storage API.
/// Decoding reconstructs proposals; it never establishes authority or persistence.
public enum NativeEnrollmentEvidenceCodec {
    public enum Failure: Error, Equatable { case invalidJSON, invalidSchema, capacityExceeded, invalidHistory }
    public static let maximumBytes = 1_048_576, maximumRecordBytes = 8192, maximumDepth = 16, maximumNodes = 65536
    public static func decode(_ data: Data, history: DeviceManagementFormatHistory) throws -> NativeEnrollmentEvidence {
        var parser = EnrollmentJSONParser(data)
        let root = try object(parser.parse(), keys: ["schemaVersion", "enrollments"])
        guard case .integer(1) = root["schemaVersion"] else { throw Failure.invalidSchema }
        let records = try array(root["enrollments"]).map(parseRecord)
        guard records.count <= 64 else { throw Failure.capacityExceeded }
        try validateRoles(records, history: history)
        var evidence = NativeEnrollmentEvidence(), previousIndex = -1
        for record in records {
            guard let index = history.transitions.firstIndex(where: { $0.transitionID == record.binding.transitionID }), index > previousIndex,
                  history.credentials.contains(record.binding) else { throw Failure.invalidHistory }
            previousIndex = index
            // Private structural replay view only. The caller's actual history is
            // unchanged, and must still govern any later recovery classification.
            var transitions = Array(history.transitions.prefix(index + 1))
            transitions[index] = .init(transitionID: record.binding.transitionID, phase: .intent)
            let ids = Set(transitions.map(\.transitionID))
            let replayHistory = try DeviceManagementFormatHistory(transitions: transitions, credentials: history.credentials.filter { ids.contains($0.transitionID) })
            guard case .claimProposed = record.events.first else { throw Failure.invalidSchema }
            evidence = try NativeEnrollmentRecovery.proposingClaim(in: evidence, history: replayHistory, enrollmentId: record.id, binding: record.binding, input: record.input)
            for event in record.events.dropFirst() {
                let count = evidence.enrollments.last!.events.count
                switch event {
                case .claimProposed: throw Failure.invalidSchema
                case .pendingClaimObserved(let c), .terminalClaimObserved(let c):
                    evidence = try NativeEnrollmentRecovery.proposingClaimObservation(in: evidence, history: replayHistory, enrollmentId: record.id, result: .claim(c))
                case .activationProposed(let input):
                    evidence = try NativeEnrollmentRecovery.proposingActivation(in: evidence, history: replayHistory, enrollmentId: record.id, requestId: input.requestId)
                case .historicalActivationObserved(let a):
                    evidence = try NativeEnrollmentRecovery.proposingActivationObservation(in: evidence, history: replayHistory, enrollmentId: record.id, receipt: a)
                }
                // Exact retries are legal runtime observations, but duplicate
                // persisted events are invalid rather than silently discarded.
                guard evidence.enrollments.last!.events.count == count + 1,
                      try nativeEnrollmentBytes(evidence.enrollments.last!.events.last!) == nativeEnrollmentBytes(event) else { throw Failure.invalidSchema }
            }
        }
        return evidence
    }
    public static func encode(_ evidence: NativeEnrollmentEvidence, history: DeviceManagementFormatHistory) throws -> Data {
        guard evidence.enrollments.count <= 64 else { throw Failure.capacityExceeded }
        var records: [[String: Any]] = []
        for record in evidence.enrollments {
            guard record.events.count <= 4 else { throw Failure.capacityExceeded }
            let value: [String: Any] = ["enrollmentId": uuid(record.localEnrollmentId), "binding": try json(record.binding), "claimInput": try json(record.claimInput), "events": try record.events.map(eventObject)]
            guard try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]).count <= maximumRecordBytes else { throw Failure.capacityExceeded }
            records.append(value)
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "enrollments": records], options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maximumBytes else { throw Failure.capacityExceeded }
        let rebuilt = try decode(data, history: history)
        guard try nativeEnrollmentBytes(rebuilt) == nativeEnrollmentBytes(evidence) else { throw Failure.invalidSchema }
        return data
    }
    private static func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: nativeEnrollmentBytes(value)) }
    private static func uuid(_ value: UUID) -> String { value.uuidString.lowercased() }
    private static func eventObject(_ event: NativeEnrollmentEvidence.Event) throws -> [String: Any] {
        switch event {
        case .claimProposed: return ["kind": "claimProposed"]
        case .pendingClaimObserved(let c): return ["kind": "pendingClaimObserved", "receipt": try json(c)]
        case .terminalClaimObserved(let c): return ["kind": "terminalClaimObserved", "receipt": try json(c)]
        case .activationProposed(let i): return ["kind": "activationProposed", "input": try json(i)]
        case .historicalActivationObserved(let a): return ["kind": "historicalActivationObserved", "receipt": try json(a)]
        }
    }
    private struct Record {
        let id: UUID, binding: DeviceManagementFormatHistory.Binding, input: NativeClaimInput, events: [NativeEnrollmentEvidence.Event]
    }
    private static func parseRecord(_ value: EnrollmentJSON) throws -> Record {
        let o = try object(value, keys: ["enrollmentId", "binding", "claimInput", "events"])
        let b = try object(required(o, "binding"), keys: ["credentialGenerationID", "transitionID", "credentialReference", "format"])
        guard try string(b["format"]) == CloudInstallationCredentialFormat.nativeInstallationV1.rawValue else { throw Failure.invalidSchema }
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: id(b["credentialGenerationID"]), transitionID: id(b["transitionID"]), credentialReference: string(b["credentialReference"]), format: .nativeInstallationV1)
        let c = try object(required(o, "claimInput"), keys: ["requestId", "transitionId", "accountId", "locationId", "name", "profile"])
        let input = try NativeClaimInput(requestId: id(c["requestId"]), transitionId: id(c["transitionId"]), accountId: id(c["accountId"]), locationId: id(c["locationId"]), name: string(c["name"]), profile: string(c["profile"]))
        let events = try array(o["events"]).map(parseEvent)
        guard (1...4).contains(events.count) else { throw Failure.capacityExceeded }
        return Record(id: try id(o["enrollmentId"]), binding: binding, input: input, events: events)
    }
    private static func parseEvent(_ value: EnrollmentJSON) throws -> NativeEnrollmentEvidence.Event {
        guard case .object(let raw) = value else { throw Failure.invalidSchema }
        switch try string(raw["kind"]) {
        case "claimProposed": _ = try object(value, keys: ["kind"]); return .claimProposed
        case "pendingClaimObserved", "terminalClaimObserved":
            let o = try object(value, keys: ["kind", "receipt"]), c = try claim(required(o, "receipt"))
            if try string(o["kind"]) == "pendingClaimObserved" { guard c.outcome == .pending else { throw Failure.invalidSchema }; return .pendingClaimObserved(c) }
            guard c.outcome != .pending else { throw Failure.invalidSchema }; return .terminalClaimObserved(c)
        case "activationProposed":
            let o = try object(value, keys: ["kind", "input"]), i = try object(required(o, "input"), keys: ["installationId", "requestId", "challengeId", "transitionId"])
            return .activationProposed(try .init(installationId: id(i["installationId"]), requestId: id(i["requestId"]), challengeId: id(i["challengeId"]), transitionId: id(i["transitionId"])))
        case "historicalActivationObserved":
            let o = try object(value, keys: ["kind", "receipt"]), a = try object(required(o, "receipt"), keys: ["installationId", "deviceId", "requestId", "accountId", "locationId", "transitionId", "activatedAt", "initialGeneration"])
            let g = try object(required(a, "initialGeneration"), keys: ["generationId", "createdAt", "renewAfter", "expiresAt"])
            let generation = try NativeGenerationReceipt(generationId: id(g["generationId"]), createdAt: string(g["createdAt"]), renewAfter: string(g["renewAfter"]), expiresAt: string(g["expiresAt"]))
            return .historicalActivationObserved(try .init(installationId: id(a["installationId"]), deviceId: id(a["deviceId"]), requestId: id(a["requestId"]), accountId: id(a["accountId"]), locationId: id(a["locationId"]), transitionId: id(a["transitionId"]), activatedAt: string(a["activatedAt"]), initialGeneration: generation))
        default: throw Failure.invalidSchema
        }
    }
    private static func claim(_ value: EnrollmentJSON) throws -> NativeClaimReceipt {
        let c = try object(value, keys: ["installationId", "requestId", "transitionId", "challengeId", "accountId", "locationId", "createdAt", "expiresAt", "outcome"])
        guard let outcome = NativeClaimReceipt.Outcome(rawValue: try string(c["outcome"])) else { throw Failure.invalidSchema }
        return try .init(installationId: id(c["installationId"]), requestId: id(c["requestId"]), transitionId: id(c["transitionId"]), challengeId: id(c["challengeId"]), accountId: id(c["accountId"]), locationId: id(c["locationId"]), createdAt: string(c["createdAt"]), expiresAt: string(c["expiresAt"]), outcome: outcome)
    }
    private static func validateRoles(_ records: [Record], history: DeviceManagementFormatHistory) throws {
        var ids = Set(history.transitions.map(\.transitionID) + history.credentials.map(\.credentialGenerationID))
        func fresh(_ id: UUID) throws { guard ids.insert(id).inserted else { throw Failure.invalidSchema } }
        var servers: [UUID: (UUID, String)] = [:]
        func server(_ id: UUID, owner: UUID, role: String) throws {
            if let prior = servers[id], prior.0 != owner || prior.1 != role { throw Failure.invalidSchema }
            servers[id] = (owner, role)
        }
        for r in records {
            try fresh(r.id); try fresh(r.input.requestId)
            for e in r.events {
                switch e {
                case .activationProposed(let i): try fresh(i.requestId)
                case .pendingClaimObserved(let c), .terminalClaimObserved(let c): try server(c.installationId, owner: r.id, role: "installation"); try server(c.challengeId, owner: r.id, role: "challenge")
                case .historicalActivationObserved(let a): try server(a.installationId, owner: r.id, role: "installation"); try server(a.initialGeneration.generationId, owner: r.id, role: "generation")
                default: break
                }
            }
        }
        guard Set(servers.keys).isDisjoint(with: ids) else { throw Failure.invalidSchema }
    }
    private static func required(_ o: [String: EnrollmentJSON], _ key: String) throws -> EnrollmentJSON { guard let v = o[key] else { throw Failure.invalidSchema }; return v }
    private static func object(_ v: EnrollmentJSON, keys: Set<String>) throws -> [String: EnrollmentJSON] { guard case .object(let o) = v, Set(o.keys) == keys else { throw Failure.invalidSchema }; return o }
    private static func array(_ v: EnrollmentJSON?) throws -> [EnrollmentJSON] { guard case .array(let a) = v else { throw Failure.invalidSchema }; return a }
    private static func string(_ v: EnrollmentJSON?) throws -> String { guard case .string(let s) = v else { throw Failure.invalidSchema }; return s }
    private static func id(_ v: EnrollmentJSON?) throws -> UUID {
        let s = try string(v), b = Array(s.utf8.prefix(37))
        guard b.count == 36 else { throw Failure.invalidSchema }
        for i in b.indices {
            if [8,13,18,23].contains(i) { guard b[i] == 45 else { throw Failure.invalidSchema } }
            else { guard (48...57).contains(b[i]) || (65...70).contains(b[i]) || (97...102).contains(b[i]) else { throw Failure.invalidSchema } }
        }
        guard let result = UUID(uuidString: s) else { throw Failure.invalidSchema }; return result
    }
}

private indirect enum EnrollmentJSON { case object([String: EnrollmentJSON]), array([EnrollmentJSON]), string(String), integer(Int), other }
private struct EnrollmentJSONParser {
    typealias Failure = NativeEnrollmentEvidenceCodec.Failure
    private let bytes: [UInt8]
    private var cursor = 0, nodes = 0
    init(_ data: Data) { bytes = Array(data.prefix(NativeEnrollmentEvidenceCodec.maximumBytes + 1)) }
    mutating func parse() throws -> EnrollmentJSON {
        guard bytes.count <= NativeEnrollmentEvidenceCodec.maximumBytes else { throw Failure.capacityExceeded }
        let result = try value(depth: 1, end: bytes.count); whitespace()
        guard cursor == bytes.count else { throw Failure.invalidJSON }; return result
    }
    private mutating func whitespace() { while cursor < bytes.count && [9,10,13,32].contains(bytes[cursor]) { cursor += 1 } }
    private mutating func value(depth: Int, end: Int, arrayLimit: Int? = nil, records: Bool = false) throws -> EnrollmentJSON {
        whitespace(); nodes += 1
        guard depth <= NativeEnrollmentEvidenceCodec.maximumDepth, nodes <= NativeEnrollmentEvidenceCodec.maximumNodes else { throw Failure.capacityExceeded }
        guard cursor < end else { throw Failure.invalidJSON }
        switch bytes[cursor] {
        case 123:
            cursor += 1; whitespace(); var result: [String: EnrollmentJSON] = [:]
            if cursor < end, bytes[cursor] == 125 { cursor += 1; return .object(result) }
            while true {
                nodes += 1; guard nodes <= NativeEnrollmentEvidenceCodec.maximumNodes else { throw Failure.capacityExceeded }
                let key = try text(end: end); guard result[key] == nil else { throw Failure.invalidJSON }
                whitespace(); guard cursor < end, bytes[cursor] == 58 else { throw Failure.invalidJSON }; cursor += 1
                result[key] = try value(depth: depth + 1, end: end, arrayLimit: key == "enrollments" && depth == 1 ? 64 : (key == "events" && depth == 3 ? 4 : nil), records: key == "enrollments" && depth == 1)
                whitespace(); guard cursor < end else { throw Failure.invalidJSON }
                if bytes[cursor] == 125 { cursor += 1; return .object(result) }
                guard bytes[cursor] == 44 else { throw Failure.invalidJSON }; cursor += 1; whitespace()
            }
        case 91:
            cursor += 1; whitespace(); var result: [EnrollmentJSON] = []
            if cursor < end, bytes[cursor] == 93 { cursor += 1; return .array(result) }
            while true {
                if let limit = arrayLimit, result.count >= limit { throw Failure.capacityExceeded }
                let itemEnd = records ? min(end, cursor + NativeEnrollmentEvidenceCodec.maximumRecordBytes) : end
                result.append(try value(depth: depth + 1, end: itemEnd))
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
