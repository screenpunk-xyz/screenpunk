import Foundation

/// Strict wire observations only. Neither parsing nor retained server dates admit dispatch.
/// Original authorization remains reportable after expiry; no persisted lease is revived.
enum DeviceNativeDeliveryHTTPCodec {
    typealias C = DeviceNativeDeliveryAttachmentCodec
    enum Kind { case activationRequest, activationResponse, terminalRequest, terminalResponse }
    struct Observation {
        let bytes: Data
        let activationRequestID: UUID?
        let authorizationDigest: String?
        let outcome: String?
        let receiptID: UUID?
    }
    private static let common: Set<String> = ["schemaVersion","operationId","planId","installationId","accountId","locationId","transitionId","expectedInstalledSetGenerationId","desiredSetGenerationId","planDigest","planByteLength","sequence","resultingSetDigest"]
    static func activationRequest(binding: DeviceNativeDeliveryCommandBinding, requestID: UUID) throws -> Data {
        var object = association(binding)
        object["activationRequestId"] = requestID.uuidString.lowercased()
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        _ = try observe(bytes, kind: .activationRequest, binding: binding, requestID: requestID)
        return bytes
    }
    /// Terminal request decoding validates wire semantics, not the truth of the claimed outcome.
    /// No terminal request constructor exists until genuine completion/no-dispatch proof is available.
    static func observe(_ bytes: Data, kind: Kind, binding: DeviceNativeDeliveryCommandBinding,
                        requestID: UUID?, authorizationDigest: String? = nil,
                        expectedOutcome: String? = nil) throws -> Observation {
        let extra: Set<String>
        let limit: Int
        switch kind {
        case .activationRequest: extra = ["activationRequestId"]; limit = 4096
        case .activationResponse: extra = ["activationRequestId","authorizationDigest","authorizedAt","expiresAt"]; limit = 4096
        case .terminalRequest: extra = ["activationRequestId","authorizationDigest","outcome","previousGenerationId","resultingGenerationId","renderState"]; limit = 16384
        case .terminalResponse: extra = ["receiptId","receivedAt","outcome"]; limit = 16384
        }
        let object = try C.object(bytes, limit: limit, keys: common.union(extra))
        let expected = association(binding)
        for name in common {
            if name == "schemaVersion" { guard try C.integer(object[name], maximum: 1) == 1 else { throw C.Failure.invalidSchema } }
            else if name == "planByteLength" { guard try C.integer(object[name], maximum: 65536) == UInt64(binding.association.planByteLength) else { throw C.Failure.invalidSchema } }
            else {
                guard let actual = object[name] as? String, let wanted = expected[name] as? String,
                      actual.utf8.elementsEqual(wanted.utf8) else { throw C.Failure.invalidSchema }
            }
        }
        guard binding.sequence > 0, binding.sequence <= UInt64(Int64.max) else { throw C.Failure.invalidSchema }
        var id: UUID?, digest: String?, outcome: String?, receipt: UUID?
        switch kind {
        case .activationRequest, .activationResponse:
            id = try C.uuid(object["activationRequestId"])
            guard let requestID, id == requestID else { throw C.Failure.invalidSchema }
            if kind == .activationResponse {
                digest = try C.hashText(object["authorizationDigest"])
                if let authorizationDigest { guard digest!.utf8.elementsEqual(authorizationDigest.utf8) else { throw C.Failure.invalidSchema } }
                let start = try timestamp(object["authorizedAt"]), end = try timestamp(object["expiresAt"])
                guard try nativeEnrollmentInterval(end, start, seconds: 30) else { throw C.Failure.invalidSchema }
            }
        case .terminalRequest:
            outcome = try terminalOutcome(object["outcome"])
            let bothNull = object["activationRequestId"] is NSNull && object["authorizationDigest"] is NSNull
            if bothNull {
                guard outcome == "not_activated", requestID == nil, authorizationDigest == nil else { throw C.Failure.invalidSchema }
            } else {
                id = try C.uuid(object["activationRequestId"]); digest = try C.hashText(object["authorizationDigest"])
                guard let requestID, let authorizationDigest, id == requestID,
                      digest!.utf8.elementsEqual(authorizationDigest.utf8) else { throw C.Failure.invalidSchema }
            }
            guard try C.uuid(object["previousGenerationId"]) == binding.expectedGenerationID,
                  try C.uuid(object["resultingGenerationId"]) == (outcome == "activated" ? binding.desiredGenerationID : binding.expectedGenerationID),
                  let render = object["renderState"] as? String, ["not-observed","ready","failed"].contains(render) else { throw C.Failure.invalidSchema }
        case .terminalResponse:
            outcome = try terminalOutcome(object["outcome"])
            receipt = try C.uuid(object["receiptId"]); _ = try timestamp(object["receivedAt"])
        }
        if let expectedOutcome { guard outcome == expectedOutcome else { throw C.Failure.invalidSchema } }
        return .init(bytes: bytes, activationRequestID: id, authorizationDigest: digest, outcome: outcome, receiptID: receipt)
    }
    struct CommandPollObservation {
        let commandBytes:Data?
        let nextCheckSeconds:Int
    }
    /// Defensive local wrapper cap; exact member bytes feed the existing binding decoder.
    /// Null does not imply idle, ownership, approval or a fabricated command.
    static func commandPoll(_ bytes:Data)throws->CommandPollObservation {
        let object=try C.object(bytes,limit:17*1024,keys:["command","nextCheckSeconds"])
        let next=try C.integer(object["nextCheckSeconds"],maximum:900)
        guard next == 5 || next == 900 else{throw C.Failure.invalidSchema}
        guard object["command"] is NSNull || object["command"] is [String:Any] else{throw C.Failure.invalidSchema}
        if object["command"] is NSNull {return .init(commandBytes:nil,nextCheckSeconds:Int(next))}
        var scanner=PollMemberScanner(bytes:Array(bytes))
        let range=try scanner.commandRange()
        guard range.count <= 16384 else{throw C.Failure.capacity}
        return .init(commandBytes:bytes.subdata(in:range),nextCheckSeconds:Int(next))
    }
    // Lexical range extraction runs only AFTER the strict bounded parser proves valid JSON.
    // It never reserializes the member and has no exported parser surface.
    private struct PollMemberScanner {
        let bytes:[UInt8]
        var cursor=0
        mutating func whitespace(){while cursor<bytes.count && [9,10,13,32].contains(bytes[cursor]){cursor += 1}}
        mutating func stringEnd()throws {
            guard cursor<bytes.count,bytes[cursor] == 34 else{throw C.Failure.invalidJSON};cursor += 1
            while cursor<bytes.count {
                let byte=bytes[cursor];cursor += 1
                if byte == 34{return}
                if byte == 92 {guard cursor<bytes.count else{throw C.Failure.invalidJSON};cursor += 1}
            }
            throw C.Failure.invalidJSON
        }
        mutating func valueEnd()throws {
            whitespace();guard cursor<bytes.count else{throw C.Failure.invalidJSON}
            if bytes[cursor] == 34 {try stringEnd();return}
            if bytes[cursor] == 123 || bytes[cursor] == 91 {
                let close:UInt8=bytes[cursor] == 123 ? 125:93;cursor += 1
                while cursor<bytes.count {
                    whitespace()
                    if bytes[cursor] == close {cursor += 1;return}
                    if bytes[cursor] == 44 || bytes[cursor] == 58 {cursor += 1;continue}
                    try valueEnd()
                }
                throw C.Failure.invalidJSON
            }
            while cursor<bytes.count && ![9,10,13,32,44,125,93].contains(bytes[cursor]){cursor += 1}
        }
        mutating func commandRange()throws->Range<Int> {
            whitespace();guard bytes[cursor] == 123 else{throw C.Failure.invalidJSON};cursor += 1
            while cursor<bytes.count {
                whitespace();if bytes[cursor] == 125 {break}
                let keyStart=cursor;try stringEnd()
                let key=try JSONDecoder().decode(String.self,from:Data(bytes[keyStart..<cursor]))
                whitespace();guard cursor<bytes.count,bytes[cursor] == 58 else{throw C.Failure.invalidJSON};cursor += 1
                whitespace();let start=cursor;try valueEnd();let end=cursor
                if key.utf8.elementsEqual("command".utf8){return start..<end}
                whitespace();if cursor<bytes.count,bytes[cursor] == 44{cursor += 1}
            }
            throw C.Failure.invalidSchema
        }
    }
    private static func terminalOutcome(_ value: Any?) throws -> String {
        guard let value = value as? String, ["activated","not_activated"].contains(value) else { throw C.Failure.invalidSchema }; return value
    }
    private static func association(_ binding: DeviceNativeDeliveryCommandBinding) -> [String: Any] {
        let a = binding.association
        return ["schemaVersion":1,"operationId":a.operationID.uuidString.lowercased(),"planId":a.planID.uuidString.lowercased(),"installationId":a.installationID.uuidString.lowercased(),"accountId":a.accountID.uuidString.lowercased(),"locationId":a.locationID.uuidString.lowercased(),"transitionId":a.transitionID.uuidString.lowercased(),"expectedInstalledSetGenerationId":binding.expectedGenerationID.uuidString.lowercased(),"desiredSetGenerationId":binding.desiredGenerationID.uuidString.lowercased(),"planDigest":a.planDigest,"planByteLength":a.planByteLength,"sequence":String(binding.sequence),"resultingSetDigest":binding.resultingSetDigest]
    }
    private static func timestamp(_ value: Any?) throws -> String {
        guard let text = value as? String, text.utf8.prefix(257).count <= 256 else { throw C.Failure.invalidSchema }
        _ = try nativeEnrollmentTime(text)
        return text
    }
}
