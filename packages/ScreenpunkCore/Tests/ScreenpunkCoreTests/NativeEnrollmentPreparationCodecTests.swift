import XCTest
@testable import ScreenpunkCore

final class NativeEnrollmentPreparationCodecTests: XCTestCase {
    private func fixture() throws -> NativeEnrollmentPreparation {
        let old = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "old", format: .legacyLocal32)
        let history = try DeviceManagementFormatHistory(transitions: [.init(transitionID: old.transitionID, phase: .locallyFenced)], credentials: [old])
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "new", format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Cafe\u{301}", profile: "iPad")
        return try .proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage", binding: binding, claimInput: input, history: history, enrollment: .init(), retained: [], inventory: .init(finalItems: ["old": .legacy32], stageItems: [:]))
    }
    private func inventory(_ p: NativeEnrollmentPreparation, staged: Bool, final: Bool) -> NativeEnrollmentPreparation.Inventory {
        let descriptor = NativeEnrollmentPreparation.StageDescriptor(preparationId: p.preparationId, enrollmentId: p.enrollmentId, stageReference: p.stageReference, binding: p.binding, claimInput: p.claimInput)
        return .init(finalItems: final ? ["old": .legacy32, "new": .native48] : ["old": .legacy32], stageItems: staged ? [p.stageReference: .descriptor(descriptor)] : [:])
    }
    private func object(_ p: NativeEnrollmentPreparation) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: NativeEnrollmentPreparationCodec.encodeReconstructionProposal(p)) as? [String: Any])
    }
    private func data(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) }
    func testExactProposalAndEveryPhaseMetadataWithoutQualification() throws {
        let p = try fixture()
        for phase in 0...6 {
            var o = try object(p); o["phase"] = phase
            let decoded = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o))
            XCTAssertEqual(decoded.phase.rawValue, phase)
            XCTAssertEqual(decoded.preparationId, p.preparationId)
            XCTAssertEqual(decoded.reservedBytes, p.reservedBytes)
            XCTAssertEqual(try nativeEnrollmentBytes(decoded.targetHistory), try nativeEnrollmentBytes(p.targetHistory))
            XCTAssertEqual(try nativeEnrollmentBytes(decoded.targetEnrollment), try nativeEnrollmentBytes(p.targetEnrollment))
            XCTAssertTrue(decoded.claimInput.name.utf8.elementsEqual(p.claimInput.name.utf8))
        }
        // Phase metadata cannot acknowledge staging, promotion or persistence:
        // there is intentionally no conversion to a preparation handle.
    }
    func testIndependentTargetAssertionsAndExactInputs() throws {
        let p = try fixture(), base = try object(p)
        for key in ["targetHistory", "targetEnrollment"] {
            var o = base; o[key] = base[key == "targetHistory" ? "sourceHistory" : "sourceEnrollment"]
            XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
        }
        var o = base, c = try XCTUnwrap(o["claimInput"] as? [String: Any]); c["name"] = "Café"; o["claimInput"] = c
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
        o = base; o["reservedBytes"] = 1
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
        o = base; var h = try XCTUnwrap(o["sourceHistory"] as? [String: Any]), t = try XCTUnwrap(h["transitions"] as? [[String: Any]])
        t[0]["phase"] = "intent"; h["transitions"] = t; o["sourceHistory"] = h
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
    }
    func testRolesSchemaAndBoundedStrictJSON() throws {
        let p = try fixture(), base = try object(p)
        for key in ["preparationId", "enrollmentId"] {
            var o = base; o[key] = p.claimInput.requestId.uuidString
            XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
        }
        for phase in [-1, 7] { var o = base; o["phase"] = phase; XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o))) }
        var o = base; o["schemaVersion"] = 2; XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
        o = base; o["preparationId"] = "not-a-uuid"; XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
        let text = String(decoding: try data(base), as: UTF8.self)
        for prefix in ["\"schemaVersion\":1,", "\"schema\\u0056ersion\":1,", "\"unknown\":null,"] {
            XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(Data(("{" + prefix + text.dropFirst()).utf8)))
        }
        for malformed in ["{\"a\":\"\\uD800\"}", "{\"a\":\"\\uDC00\"}", "{\"a\":true}", "[" + String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 18)] {
            XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(Data(malformed.utf8)))
        }
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(Data([123,34,255,34,58,49,125])))
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(Data(repeating: 32, count: NativeEnrollmentPreparationCodec.maximumBytes + 1)))
        o = base; o["stageReference"] = String(repeating: "s", count: 1025)
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
        o = base; var h = try XCTUnwrap(o["sourceHistory"] as? [String: Any]); h["schemaVersion"] = 2; o["sourceHistory"] = h
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
    }
    func testNestedUnknownFieldsDuplicatesAndLimits() throws {
        let base = try object(fixture())
        for key in ["binding", "claimInput", "sourceHistory", "targetHistory", "sourceEnrollment", "targetEnrollment"] {
            var o = base, nested = try XCTUnwrap(o[key] as? [String: Any]); nested["unknown"] = 1; o[key] = nested
            XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
        }
        let text = String(decoding: try data(base), as: UTF8.self)
        let duplicate = text.replacingOccurrences(of: "\"credentialReference\":", with: "\"credentialReference\":\"alias\",\"credential\\u0052eference\":")
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(Data(duplicate.utf8)))
        var o = base, source = try XCTUnwrap(o["sourceHistory"] as? [String: Any])
        let credentials = try XCTUnwrap(source["credentials"] as? [[String: Any]])
        source["credentials"] = Array(repeating: credentials[0], count: 129); o["sourceHistory"] = source
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o)))
        // Node bound is enforced during parsing, before schema projection.
        let nodes = "[" + Array(repeating: "[" + Array(repeating: "0", count: 128).joined(separator: ",") + "]", count: 128).joined(separator: ",") + "]"
        let tooManyNodes = "[" + Array(repeating: nodes, count: 8).joined(separator: ",") + "]"
        XCTAssertLessThan(tooManyNodes.utf8.count, NativeEnrollmentPreparationCodec.maximumBytes)
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(Data(tooManyNodes.utf8)))
    }
    func testRetainedHistoricalMappingsAndLaterFences() throws {
        var old = try fixture()
        for phase in [NativeEnrollmentPreparation.Phase.stageAttempted, .stageQualified, .pairedEvidenceQualified, .promotionAttempted, .promotionQualified, .complete] {
            let target = phase.rawValue >= NativeEnrollmentPreparation.Phase.pairedEvidenceQualified.rawValue
            old = try old.proposingObservation(phase, history: target ? old.targetHistory : old.sourceHistory,
                enrollment: target ? old.targetEnrollment : old.sourceEnrollment,
                inventory: inventory(old, staged: phase != .stageAttempted, final: phase.rawValue >= NativeEnrollmentPreparation.Phase.promotionQualified.rawValue), retained: [])
        }
        let retained = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeEnrollmentPreparationCodec.encodeReconstructionProposal(old))
        let source = try DeviceManagementFormatHistory(transitions: old.targetHistory.transitions.map { .init(transitionID: $0.transitionID, phase: .locallyFenced) }, credentials: old.targetHistory.credentials)
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "next", format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Next", profile: "iPhone")
        let receipt = try NativeClaimReceipt(installationId: UUID(), requestId: old.claimInput.requestId, transitionId: old.claimInput.transitionId, challengeId: UUID(), accountId: old.claimInput.accountId, locationId: old.claimInput.locationId, createdAt: "2026-10-01T01:00:00.125000+01:00", expiresAt: "2026-10-01T01:10:00.125000+01:00", outcome: .cancelled)
        let laterEnrollment = try NativeEnrollmentRecovery.proposingClaimObservation(in: old.targetEnrollment, history: source, enrollmentId: old.enrollmentId, result: .claim(receipt))
        let next = try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "next-stage", binding: binding, claimInput: input, history: source, enrollment: laterEnrollment, retained: [old], inventory: inventory(old, staged: true, final: true))
        let encoded = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(next, retained: [retained])
        let decoded = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(encoded, retained: [retained])
        XCTAssertEqual(decoded.sourceHistory.transitions.last?.phase, .locallyFenced)
        XCTAssertEqual(decoded.sourceEnrollment.enrollments.first?.events.count, 2)
        guard case .terminalClaimObserved(let observation) = decoded.sourceEnrollment.enrollments.first?.events.last else { return XCTFail() }
        XCTAssertTrue(observation.createdAt.utf8.elementsEqual(receipt.createdAt.utf8))
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(encoded))
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(encoded, retained: [retained, retained]))
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); o["stageReference"] = retained.stageReference
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o), retained: [retained]))
        o = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); o["sourceEnrollment"] = ["schemaVersion": 1, "enrollments": []]
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(o), retained: [retained]))
        // Old reconstruction remains valid without asking it to classify the new current history.
        XCTAssertNoThrow(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeEnrollmentPreparationCodec.encodeReconstructionProposal(old)))
    }
    func testLegacy128CredentialsPreservedAndCompletionReservation() throws {
        let transition = UUID()
        let keys = try (0..<127).map { try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: transition, credentialReference: "legacy-\($0)", format: .legacyLocal32) }
        let h = try DeviceManagementFormatHistory(transitions: [.init(transitionID: transition, phase: .locallyFenced)], credentials: keys)
        let b = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "native", format: .nativeInstallationV1)
        let c = try NativeClaimInput(requestId: UUID(), transitionId: b.transitionID, accountId: UUID(), locationId: UUID(), name: String(repeating: "x", count: 80), profile: "iPhone")
        let p = try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage", binding: b, claimInput: c, history: h, enrollment: .init(), retained: [], inventory: .init(finalItems: Dictionary(uniqueKeysWithValues: keys.map { ($0.credentialReference, .legacy32) }), stageItems: [:]))
        let bytes = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(p)
        let r = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(bytes)
        XCTAssertEqual(r.targetHistory.credentials.count, 128)
        XCTAssertEqual(r.reservedBytes, p.reservedBytes)
        XCTAssertLessThan(bytes.count, r.reservedBytes)
    }
}
