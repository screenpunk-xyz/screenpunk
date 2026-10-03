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
    private func nextRecord(history: DeviceManagementFormatHistory, enrollment: NativeEnrollmentEvidence,
        phase: Int = 6, preparationId: UUID = UUID(), enrollmentId: UUID = UUID(), stage: String = UUID().uuidString,
        binding: DeviceManagementFormatHistory.Binding? = nil, requestId: UUID = UUID()) throws -> Data {
        let b = try binding ?? DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: UUID().uuidString, format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: requestId, transitionId: b.transitionID, accountId: UUID(), locationId: UUID(), name: "Cafe\u{301} 😀", profile: " iPad ")
        let target = try DeviceManagementFormatHistory(transitions: history.transitions + [.init(transitionID: b.transitionID, phase: .intent)], credentials: history.credentials + [b])
        let proposed = try NativeEnrollmentRecovery.proposingClaim(in: enrollment, history: target, enrollmentId: enrollmentId, binding: b, input: input)
        func json<T: Encodable>(_ v: T) throws -> Any { try JSONSerialization.jsonObject(with: nativeEnrollmentBytes(v)) }
        return try data(["schemaVersion": 1, "preparationId": preparationId.uuidString, "enrollmentId": enrollmentId.uuidString,
            "stageReference": stage, "binding": try json(b), "claimInput": try json(input), "phase": phase,
            "sourceHistory": try json(history), "targetHistory": try json(target),
            "sourceEnrollment": try JSONSerialization.jsonObject(with: NativeEnrollmentEvidenceCodec.encode(enrollment, history: history)),
            "targetEnrollment": try JSONSerialization.jsonObject(with: NativeEnrollmentEvidenceCodec.encode(proposed, history: target))])
    }
    private func fenced(_ h: DeviceManagementFormatHistory) throws -> DeviceManagementFormatHistory {
        try .init(transitions: h.transitions.map { .init(transitionID: $0.transitionID, phase: .locallyFenced) }, credentials: h.credentials)
    }
    func testStreamArrayEquivalenceAndUnfinishedContinuation() throws {
        let p = try fixture()
        var history = p.sourceHistory, enrollment = p.sourceEnrollment
        var context = NativePreparationReconstructionContext.empty(), retained: [NativeEnrollmentPreparationReconstructionProposal] = []
        for index in 0..<3 {
            let encoded = try nextRecord(history: history, enrollment: enrollment)
            let streamed = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(encoded, context: context)
            let array = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(encoded, retained: retained)
            XCTAssertEqual(try nativeEnrollmentBytes(streamed.proposal.targetEnrollment), try nativeEnrollmentBytes(array.targetEnrollment))
            XCTAssertEqual(try nativeEnrollmentBytes(streamed.proposal.sourceHistory), try nativeEnrollmentBytes(array.sourceHistory))
            XCTAssertEqual(streamed.proposal.reservedBytes, array.reservedBytes)
            context = try XCTUnwrap(streamed.continuation); retained.append(array)
            XCTAssertEqual(context.retainedDeclarationCount, index + 1)
            XCTAssertEqual(context.totalReservedBytes, retained.reduce(0) { $0 + $1.reservedBytes })
            history = try fenced(array.targetHistory); enrollment = array.targetEnrollment
        }
        for phase in 0..<6 {
            let unfinished = try nextRecord(history: history, enrollment: enrollment, phase: phase)
            let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(unfinished, context: context)
            XCTAssertNil(step.continuation)
            XCTAssertEqual(step.proposal.phase.rawValue, phase)
            XCTAssertNoThrow(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(unfinished, retained: retained))
        }
        let valid = try nextRecord(history: history, enrollment: enrollment)
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(valid, retained: Array(repeating: retained[0], count: 64)))
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(valid, context: .empty()))
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(valid, retained: Array(retained.reversed())))
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(valid, retained: Array(retained.dropFirst())))
    }
    func testStreamKeepsEveryHistoricalRoleAndStageDeclaration() throws {
        let p = try fixture()
        let firstData = try nextRecord(history: p.sourceHistory, enrollment: p.sourceEnrollment)
        let first = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(firstData, context: .empty())
        let firstContext = try XCTUnwrap(first.continuation)
        let old = first.proposal
        let legitimate = try NativeClaimReceipt(installationId: UUID(), requestId: old.claimInput.requestId, transitionId: old.claimInput.transitionId, challengeId: UUID(), accountId: old.claimInput.accountId, locationId: old.claimInput.locationId, createdAt: "2026-10-01T00:00:00Z", expiresAt: "2026-10-01T00:10:00Z", outcome: .pending)
        let firstHistory = try fenced(first.proposal.targetHistory)
        let claimed = try NativeEnrollmentRecovery.proposingClaimObservation(in: first.proposal.targetEnrollment, history: first.proposal.targetHistory, enrollmentId: old.enrollmentId, result: .claim(legitimate))
        let activationId = UUID()
        let activatedInput = try NativeEnrollmentRecovery.proposingActivation(in: claimed, history: first.proposal.targetHistory, enrollmentId: old.enrollmentId, requestId: activationId)
        let generation = try NativeGenerationReceipt(generationId: UUID(), createdAt: "2026-10-01T00:01:00Z", renewAfter: "2026-10-31T00:01:00Z", expiresAt: "2026-12-30T00:01:00Z")
        let activation = try NativeActivationReceipt(installationId: legitimate.installationId, deviceId: legitimate.installationId, requestId: activationId, accountId: old.claimInput.accountId, locationId: old.claimInput.locationId, transitionId: old.claimInput.transitionId, activatedAt: generation.createdAt, initialGeneration: generation)
        let observed = try NativeEnrollmentRecovery.proposingActivationObservation(in: activatedInput, history: first.proposal.targetHistory, enrollmentId: old.enrollmentId, receipt: activation)
        let secondData = try nextRecord(history: firstHistory, enrollment: observed)
        let second = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(secondData, context: firstContext)
        let context = try XCTUnwrap(second.continuation)
        let history = try fenced(second.proposal.targetHistory), enrollment = second.proposal.targetEnrollment
        for id in [old.preparationId, old.enrollmentId, old.binding.transitionID, old.binding.credentialGenerationID, old.claimInput.requestId, legitimate.installationId, legitimate.challengeId, activationId, generation.generationId] {
            let raw = try nextRecord(history: history, enrollment: enrollment, preparationId: id)
            XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(raw, context: context))
            XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(raw, retained: [first.proposal, second.proposal]))
        }
        let reusedStage = try nextRecord(history: history, enrollment: enrollment, stage: old.stageReference)
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(reusedStage, context: context))
        // A later historical observation cannot capture an earlier preparation UUID.
        let receipt = try NativeClaimReceipt(installationId: old.preparationId, requestId: second.proposal.claimInput.requestId, transitionId: second.proposal.claimInput.transitionId, challengeId: UUID(), accountId: second.proposal.claimInput.accountId, locationId: second.proposal.claimInput.locationId, createdAt: "2026-10-01T00:00:00Z", expiresAt: "2026-10-01T00:10:00Z", outcome: .cancelled)
        let changed = try NativeEnrollmentRecovery.proposingClaimObservation(in: enrollment, history: history, enrollmentId: second.proposal.enrollmentId, result: .claim(receipt))
        let captured = try nextRecord(history: history, enrollment: changed)
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(captured, context: context))
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(captured, retained: [first.proposal, second.proposal]))
    }
    func testStreamExactHistoricalClaimsEventsAndOrderedPrefixes() throws {
        let raw = try nextRecord(history: fixture().sourceHistory, enrollment: .init())
        let first = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(raw, context: .empty())
        let h = try fenced(first.proposal.targetHistory), r = first.proposal
        let receipt = try NativeClaimReceipt(installationId: UUID(), requestId: r.claimInput.requestId, transitionId: r.claimInput.transitionId, challengeId: UUID(), accountId: r.claimInput.accountId, locationId: r.claimInput.locationId, createdAt: "2026-10-01T00:00:00.125000Z", expiresAt: "2026-10-01T00:10:00.125000Z", outcome: .cancelled)
        let observed = try NativeEnrollmentRecovery.proposingClaimObservation(in: r.targetEnrollment, history: h, enrollmentId: r.enrollmentId, result: .claim(receipt))
        let secondData = try nextRecord(history: h, enrollment: observed)
        let second = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(secondData, context: XCTUnwrap(first.continuation))
        let context = try XCTUnwrap(second.continuation), nextH = try fenced(second.proposal.targetHistory)
        let base = try nextRecord(history: nextH, enrollment: second.proposal.targetEnrollment)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: base) as? [String: Any])
        for mutation in ["name", "events", "drop", "order"] {
            var mutated = object
            for key in ["sourceEnrollment", "targetEnrollment"] {
                var evidence = try XCTUnwrap(mutated[key] as? [String: Any]), records = try XCTUnwrap(evidence["enrollments"] as? [[String: Any]])
                switch mutation {
                case "name":
                    var claim = try XCTUnwrap(records[0]["claimInput"] as? [String: Any]); claim["name"] = "Café 😀"; records[0]["claimInput"] = claim
                case "events": records[0]["events"] = [["kind": "claimProposed"]]
                case "drop": records.removeFirst()
                default: records.swapAt(0, 1)
                }
                evidence["enrollments"] = records; mutated[key] = evidence
            }
            XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(mutated), context: context))
            XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(mutated), retained: [first.proposal, second.proposal]))
        }
        for key in ["sourceHistory", "targetHistory"] {
            var h = try XCTUnwrap(object[key] as? [String: Any]), credentials = try XCTUnwrap(h["credentials"] as? [[String: Any]])
            credentials.swapAt(0, 1); h["credentials"] = credentials; object[key] = h
        }
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(object), context: context))
        XCTAssertThrowsError(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(data(object), retained: [first.proposal, second.proposal]))
    }
    func testStreamCapacityAndRetainedRepresentationBound() throws {
        let p = try fixture()
        var history = p.sourceHistory, enrollment = p.sourceEnrollment, context = NativePreparationReconstructionContext.empty()
        var aggregateSnapshotBytes = 0
        for count in 1...63 {
            let raw = try nextRecord(history: history, enrollment: enrollment)
            aggregateSnapshotBytes += raw.count
            let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(raw, context: context)
            context = try XCTUnwrap(step.continuation)
            XCTAssertEqual(context.retainedDeclarationCount, count)
            XCTAssertLessThanOrEqual(context.retainedCanonicalPayloadBytes, NativePreparationReconstructionContext.maximumRetainedCanonicalPayloadBytes)
            XCTAssertLessThanOrEqual(context.totalReservedBytes, NativeEnrollmentPreparation.maximumTotalReservedBytes)
            history = try fenced(step.proposal.targetHistory); enrollment = step.proposal.targetEnrollment
        }
        XCTAssertGreaterThan(aggregateSnapshotBytes, context.retainedCanonicalPayloadBytes * 10)
        // The actual schema3 transition cap is reached before the64-preparation cap.
        XCTAssertThrowsError(try nextRecord(history: history, enrollment: enrollment))
        XCTAssertEqual(context.retainedDeclarationCount, 63)
    }

}
