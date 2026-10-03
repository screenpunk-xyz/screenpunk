import XCTest
@testable import ScreenpunkCore
final class NativeEnrollmentEvidenceCodecTests: XCTestCase {
    func fixture(terminal: Bool = false) throws -> (DeviceManagementFormatHistory, NativeEnrollmentEvidence) {
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "native", format: .nativeInstallationV1)
        let history = try DeviceManagementFormatHistory(transitions: [.init(transitionID: binding.transitionID, phase: .intent)], credentials: [binding])
        let id = UUID(), input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Cafe\u{301} 😀", profile: " iPad ")
        var e = try NativeEnrollmentRecovery.proposingClaim(in: .init(), history: history, enrollmentId: id, binding: binding, input: input)
        if terminal {
            let receipt = try NativeClaimReceipt(installationId: UUID(), requestId: input.requestId, transitionId: input.transitionId, challengeId: UUID(), accountId: input.accountId, locationId: input.locationId, createdAt: "2026-10-01T01:00:00.125000+01:00", expiresAt: "2026-10-01T01:10:00.125000+01:00", outcome: .cancelled)
            e = try NativeEnrollmentRecovery.proposingClaimObservation(in: e, history: history, enrollmentId: id, result: .claim(receipt))
        }
        return (history,e)
    }
    func object(_ e: NativeEnrollmentEvidence, _ h: DeviceManagementFormatHistory) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: NativeEnrollmentEvidenceCodec.encode(e, history: h)) as? [String: Any])
    }
    func data(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) }
    func testExactRoundtripTerminalAndFencedProposalOnly() throws {
        for terminal in [false,true] {
            let (h,e) = try fixture(terminal: terminal)
            let fenced = try DeviceManagementFormatHistory(transitions: h.transitions.map { .init(transitionID: $0.transitionID, phase: .locallyFenced) }, credentials: h.credentials)
            let original = try nativeEnrollmentBytes(fenced)
            let bytes = try NativeEnrollmentEvidenceCodec.encode(e, history: fenced)
            let decoded = try NativeEnrollmentEvidenceCodec.decode(bytes, history: fenced)
            XCTAssertEqual(try nativeEnrollmentBytes(decoded), try nativeEnrollmentBytes(e))
            XCTAssertEqual(try nativeEnrollmentBytes(fenced), original)
            XCTAssertTrue(decoded.enrollments[0].claimInput.name.utf8.elementsEqual(e.enrollments[0].claimInput.name.utf8))
            if !terminal {
                guard case .blocked = NativeEnrollmentRecovery.recoveryPlan(evidence: decoded, history: fenced, enrollmentId: e.enrollments[0].localEnrollmentId, availableCredentialReferences: ["native"]) else { return XCTFail() }
            } else if case .terminalClaimObserved(let c) = decoded.enrollments[0].events.last {
                XCTAssertEqual(c.createdAt, "2026-10-01T01:00:00.125000+01:00")
            } else { XCTFail() }
        }
    }
    func testDuplicateUnknownVersionTypesUUIDAndSurrogates() throws {
        let (h,e) = try fixture()
        let encoded = try NativeEnrollmentEvidenceCodec.encode(e, history: h)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for invalid in [
            "{\"schemaVersion\":1,\"schemaVersion\":1,\"enrollments\":[]}",
            "{\"schemaVersion\":1,\"schema\\u0056ersion\":1,\"enrollments\":[]}",
            "{\"schemaVersion\":true,\"enrollments\":[]}",
            "{\"schemaVersion\":2,\"enrollments\":[]}",
            "{\"schemaVersion\":1,\"enrollments\":[],\"extra\":0}",
            text.replacingOccurrences(of: "claimProposed", with: "unknown"),
            text.replacingOccurrences(of: "nativeInstallationV1", with: "legacyLocal32"),
            text.replacingOccurrences(of: " iPad ", with: "\\uD800"),
            text.replacingOccurrences(of: " iPad ", with: "\\uDC00"),
            text.replacingOccurrences(of: " iPad ", with: "\\uD800\\u0041"),
            text + "true"
        ] { XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(Data(invalid.utf8), history: h)) }
        var o = try object(e,h), records = try XCTUnwrap(o["enrollments"] as? [[String: Any]])
        records[0]["enrollmentId"] = "00000000000000000000000000000000"; o["enrollments"] = records
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(data(o), history: h))
        var badUTF8 = encoded; badUTF8.insert(0xFF, at: badUTF8.startIndex)
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(badUTF8, history: h))
        var escaped = text.replacingOccurrences(of: " iPad ", with: "\\uD83D\\uDE00")
        let decoded = try NativeEnrollmentEvidenceCodec.decode(Data(escaped.utf8), history: h)
        XCTAssertEqual(decoded.enrollments[0].claimInput.profile, "😀")
        escaped = text.replacingOccurrences(of: "\"claimInput\":", with: "\"claimInput\":{},\"claim\\u0049nput\":")
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(Data(escaped.utf8), history: h))
    }
    func testPersistedDuplicateAndIllegalOrderingReject() throws {
        let (h,e) = try fixture(terminal: true)
        var o = try object(e,h), records = try XCTUnwrap(o["enrollments"] as? [[String: Any]])
        let events = try XCTUnwrap(records[0]["events"] as? [[String: Any]])
        for bad in [[events[0],events[1],events[1]], [events[1],events[0]], [events[0],events[0]], []] {
            records[0]["events"] = bad; o["enrollments"] = records
            XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(data(o), history: h))
        }
    }
    func testCompleteHistoryCrossRoleCollisionAndRecordOrder() throws {
        let (h,e) = try fixture()
        let later = try DeviceManagementFormatHistory.Binding(credentialGenerationID: e.enrollments[0].claimInput.requestId, transitionID: UUID(), credentialReference: "later", format: .legacyLocal32)
        let full = try DeviceManagementFormatHistory(transitions: [.init(transitionID: h.transitions[0].transitionID, phase: .locallyFenced), .init(transitionID: later.transitionID, phase: .locallyFenced)], credentials: h.credentials + [later])
        let encoded = try NativeEnrollmentEvidenceCodec.encode(e, history: h)
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(encoded, history: full))
        let (otherH, otherE) = try fixture()
        let two = try DeviceManagementFormatHistory(transitions: [.init(transitionID: h.transitions[0].transitionID, phase: .locallyFenced), otherH.transitions[0]], credentials: h.credentials + otherH.credentials.map { try! .init(credentialGenerationID: $0.credentialGenerationID, transitionID: $0.transitionID, credentialReference: "other", format: $0.format) })
        var o = try object(e,h)
        var other = try XCTUnwrap((try object(otherE,otherH))["enrollments"] as? [[String: Any]])
        var binding = try XCTUnwrap(other[0]["binding"] as? [String: Any]); binding["credentialReference"] = "other"; other[0]["binding"] = binding
        let first = try XCTUnwrap(o["enrollments"] as? [[String: Any]])
        o["enrollments"] = first + other
        XCTAssertNoThrow(try NativeEnrollmentEvidenceCodec.decode(data(o), history: two))
        o["enrollments"] = other + first
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(data(o), history: two))
    }
    func testActivationRoundtripAndNestedUnknownFields() throws {
        let (h,first) = try fixture()
        let r = first.enrollments[0], c = try NativeClaimReceipt(installationId: UUID(), requestId: r.claimInput.requestId, transitionId: r.claimInput.transitionId, challengeId: UUID(), accountId: r.claimInput.accountId, locationId: r.claimInput.locationId, createdAt: "2026-10-01T00:00:00.125Z", expiresAt: "2026-10-01T00:10:00.125Z", outcome: .pending)
        var e = try NativeEnrollmentRecovery.proposingClaimObservation(in: first, history: h, enrollmentId: r.localEnrollmentId, result: .claim(c))
        let request = UUID()
        e = try NativeEnrollmentRecovery.proposingActivation(in: e, history: h, enrollmentId: r.localEnrollmentId, requestId: request)
        let g = try NativeGenerationReceipt(generationId: UUID(), createdAt: "2026-10-01T00:01:00.125Z", renewAfter: "2026-10-31T00:01:00.125Z", expiresAt: "2026-12-30T00:01:00.125Z")
        let a = try NativeActivationReceipt(installationId: c.installationId, deviceId: c.installationId, requestId: request, accountId: c.accountId, locationId: c.locationId, transitionId: c.transitionId, activatedAt: g.createdAt, initialGeneration: g)
        e = try NativeEnrollmentRecovery.proposingActivationObservation(in: e, history: h, enrollmentId: r.localEnrollmentId, receipt: a)
        let bytes = try NativeEnrollmentEvidenceCodec.encode(e, history: h)
        XCTAssertEqual(try nativeEnrollmentBytes(NativeEnrollmentEvidenceCodec.decode(bytes, history: h)), try nativeEnrollmentBytes(e))
        let fenced = try DeviceManagementFormatHistory(transitions: [.init(transitionID: r.binding.transitionID, phase: .locallyFenced)], credentials: h.credentials)
        let decoded = try NativeEnrollmentEvidenceCodec.decode(bytes, history: fenced)
        guard case .historicalActivationOnly = NativeEnrollmentRecovery.recoveryPlan(evidence: decoded, history: fenced, enrollmentId: r.localEnrollmentId, availableCredentialReferences: []) else { return XCTFail() }
        let original = try object(e,h)
        for field in ["binding", "claimInput", "event", "receipt", "generation"] {
            var o = original, records = try XCTUnwrap(o["enrollments"] as? [[String: Any]])
            if field == "binding" || field == "claimInput" {
                var nested = try XCTUnwrap(records[0][field] as? [String: Any]); nested["unknown"] = 1; records[0][field] = nested
            } else {
                var events = try XCTUnwrap(records[0]["events"] as? [[String: Any]])
                if field == "event" { events[3]["unknown"] = 1 }
                else {
                    var receipt = try XCTUnwrap(events[3]["receipt"] as? [String: Any])
                    if field == "receipt" { receipt["unknown"] = 1 }
                    else { var generation = try XCTUnwrap(receipt["initialGeneration"] as? [String: Any]); generation["unknown"] = 1; receipt["initialGeneration"] = generation }
                    events[3]["receipt"] = receipt
                }
                records[0]["events"] = events
            }
            o["enrollments"] = records
            XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(data(o), history: h))
        }
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for invalid in [text.replacingOccurrences(of: "\"outcome\":", with: "\"outcome\":\"pending\",\"out\\u0063ome\":"), text.replacingOccurrences(of: "\"generationId\":", with: "\"generationId\":\"" + g.generationId.uuidString + "\",\"generationId\":")] {
            XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(Data(invalid.utf8), history: h))
        }
    }
    func testBoundsBeforeMaterialization() throws {
        let (h,e) = try fixture()
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(Data(repeating: 32, count: NativeEnrollmentEvidenceCodec.maximumBytes + 1), history: h))
        let deep = "{\"schemaVersion\":1,\"enrollments\":[],\"x\":" + String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17) + "}"
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(Data(deep.utf8), history: h))
        let nodes = "{\"schemaVersion\":1,\"enrollments\":[],\"x\":[" + Array(repeating: "null", count: 65536).joined(separator: ",") + "]}"
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(Data(nodes.utf8), history: h))
        var o = try object(e,h), r = try XCTUnwrap(o["enrollments"] as? [[String: Any]])
        o["enrollments"] = Array(repeating: r[0], count: 65)
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(data(o), history: h))
        r[0]["events"] = Array(repeating: ["kind":"claimProposed"], count: 5); o["enrollments"] = r
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(data(o), history: h))
        let oversized = "{\"schemaVersion\":1,\"enrollments\":[{" + String(repeating: " ", count: 8192) + "}]}"
        XCTAssertThrowsError(try NativeEnrollmentEvidenceCodec.decode(Data(oversized.utf8), history: h))
    }
}
