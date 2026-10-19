import XCTest
@testable import ScreenpunkCore

final class NativeEnrollmentPreparationReconstructionTests: XCTestCase {
    private func fixture(finalReference: String = "native", stageReference: String = "stage") throws -> NativeEnrollmentPreparation {
        let old = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "legacy", format: .legacyLocal32)
        let source = try DeviceManagementFormatHistory(transitions: [.init(transitionID: old.transitionID, phase: .locallyFenced)], credentials: [old])
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: finalReference, format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Cafe\u{301}", profile: " iPad ")
        return try .proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: stageReference, binding: binding, claimInput: input,
            history: source, enrollment: .init(), retained: [], inventory: .init(finalItems: ["legacy": .legacy32], stageItems: [:]))
    }
    private func step(_ p: NativeEnrollmentPreparation, phase: Int, context: NativePreparationReconstructionContext = .empty(),
        retained: [NativeEnrollmentPreparationReconstructionProposal] = []) throws -> NativePreparationReconstructionStep {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: NativeEnrollmentPreparationCodec.encodeReconstructionProposal(p, retained: retained)) as? [String: Any])
        object["phase"] = phase
        return try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(JSONSerialization.data(withJSONObject: object), context: context)
    }
    private func descriptor(_ p: NativeEnrollmentPreparation, input: NativeClaimInput? = nil) -> NativeEnrollmentPreparation.StageDescriptor {
        .init(preparationId: p.preparationId, enrollmentId: p.enrollmentId, stageReference: p.stageReference, binding: p.binding, claimInput: input ?? p.claimInput)
    }
    private func inventory(_ p: NativeEnrollmentPreparation, staged: Bool, final: Bool) -> NativeEnrollmentPreparation.Inventory {
        .init(finalItems: final ? ["legacy": .legacy32, "native": .native48] : ["legacy": .legacy32], stageItems: staged ? [p.stageReference: .descriptor(descriptor(p))] : [:])
    }
    private func assess(_ s: NativePreparationReconstructionStep, h: DeviceManagementFormatHistory? = nil,
        e: NativeEnrollmentEvidence? = nil, inventory: NativeEnrollmentPreparation.Inventory) throws -> NativePreparationReconstructionAssessment {
        NativeEnrollmentPreparation.assessingReconstruction(s, currentHistory: try h ?? s.proposal.sourceHistory,
            currentEnrollment: e ?? s.proposal.sourceEnrollment, inventory: inventory)
    }
    func testEveryPhaseAndAllExactPairCombinations() throws {
        let p = try fixture()
        for phase in 0...6 {
            let s = try step(p, phase: phase), items = inventory(p, staged: phase >= 2, final: phase >= 5)
            for targetHistory in [false, true] {
                for targetEnrollment in [false, true] {
                    let result = try assess(s, h: targetHistory ? p.targetHistory : p.sourceHistory,
                        e: targetEnrollment ? p.targetEnrollment : p.sourceEnrollment, inventory: items)
                    let expected: NativeEnrollmentPreparation.Recovery
                    if phase < 2 {
                        expected = targetHistory || targetEnrollment ? .blocked : (phase == 0 ? .confirmedPrestageAbsence : .ambiguousStageAttempt)
                    } else if phase == 2 { expected = .pairedEvidenceQualificationRequired }
                    else if !targetHistory || !targetEnrollment { expected = .blocked }
                    else { expected = phase == 6 ? .completedEvidenceOnly : .exactPromotionQualificationRequired }
                    XCTAssertEqual(result.recovery, expected, "phase\(phase), history\(targetHistory), enrollment\(targetEnrollment)")
                    XCTAssertTrue(result.requiresExternalInventoryQualification)
                    XCTAssertTrue(result.requiresPairedEvidenceDurabilityQualification)
                    XCTAssertTrue(result.requiresJournalDurabilityQualification)
                }
            }
        }
    }
    func testAttemptAbsenceNeverAllowsRegenerationAndMetadataNeverProvesSecrets() throws {
        let p = try fixture(), attempted = try step(p, phase: 1)
        XCTAssertEqual(try assess(attempted, inventory: inventory(p, staged: false, final: false)).recovery, .ambiguousStageAttempt)
        let observed = try assess(attempted, inventory: inventory(p, staged: true, final: false))
        XCTAssertEqual(observed.recovery, .envelopeQualificationRequired)
        XCTAssertEqual(observed.stagingEnvelopeReferencesRequiringExternalQualification, ["stage"])
        for phase in 2...6 {
            let s = try step(p, phase: phase)
            XCTAssertEqual(try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: inventory(p, staged: false, final: phase >= 5)).recovery, .blocked)
        }
        let terminal = try assess(try step(p, phase: 6), h: p.targetHistory, e: p.targetEnrollment, inventory: inventory(p, staged: true, final: true))
        XCTAssertEqual(terminal.recovery, .completedEvidenceOnly)
        XCTAssertEqual(terminal.stagingEnvelopeReferencesRequiringExternalQualification, ["stage"])
        XCTAssertEqual(terminal.native48ReferencesRequiringExternalQualification, ["native"])
        XCTAssertTrue(terminal.requiresJournalDurabilityQualification)
    }
    func testUnknownWrongMissingAndInaccessibleItemsBlock() throws {
        let p = try fixture(), s = try step(p, phase: 6)
        let validStage: NativeEnrollmentPreparation.StageItem = .descriptor(descriptor(p))
        let cases: [NativeEnrollmentPreparation.Inventory] = [
            .init(finalItems: ["legacy": .legacy32, "native": .native48, "orphan": .native48], stageItems: ["stage": validStage]),
            .init(finalItems: ["legacy": .legacy32, "native": .native48], stageItems: ["stage": validStage, "orphan": .malformed]),
            .init(finalItems: ["native": .native48], stageItems: ["stage": validStage]),
            .init(finalItems: ["legacy": .legacy32], stageItems: ["stage": validStage]),
            .init(finalItems: ["legacy": .native48, "native": .native48], stageItems: ["stage": validStage]),
            .init(finalItems: ["legacy": .legacy32, "native": .legacy32], stageItems: ["stage": validStage]),
            .init(finalItems: ["legacy": .inaccessible, "native": .native48], stageItems: ["stage": validStage]),
            .init(finalItems: ["legacy": .legacy32, "native": .malformed], stageItems: ["stage": validStage]),
            .init(finalItems: ["legacy": .legacy32, "native": .native48], stageItems: ["stage": .inaccessible]),
            .init(finalItems: ["legacy": .legacy32, "native": .native48], stageItems: ["stage": .malformed])
        ]
        for items in cases {
            let result = try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: items)
            XCTAssertEqual(result.recovery, .blocked)
            XCTAssertTrue(result.requiresExternalInventoryQualification)
            XCTAssertTrue(result.stagingEnvelopeReferencesRequiringExternalQualification.isEmpty)
        }
        let oversized = NativeEnrollmentPreparation.Inventory(finalItems: Dictionary(uniqueKeysWithValues: (0..<129).map { ("item-\($0)", .native48) }), stageItems: [:])
        XCTAssertEqual(try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: oversized).recovery, .blocked)
        let tooManyStages = NativeEnrollmentPreparation.Inventory(finalItems: ["legacy": .legacy32, "native": .native48], stageItems: Dictionary(uniqueKeysWithValues: (0..<65).map { ("stage-\($0)", .malformed) }))
        XCTAssertEqual(try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: tooManyStages).recovery, .blocked)
        XCTAssertEqual(p.classify(history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p, staged: false, final: false), retained: Array(repeating: p, count: 64)), .blocked)
    }
    func testExactUTF8CurrentEvidenceAndStageInputsRequired() throws {
        let p = try fixture(), s = try step(p, phase: 6)
        let equivalent = try NativeClaimInput(requestId: p.claimInput.requestId, transitionId: p.claimInput.transitionId, accountId: p.claimInput.accountId,
            locationId: p.claimInput.locationId, name: "Café", profile: p.claimInput.profile)
        let wrongStage = NativeEnrollmentPreparation.Inventory(finalItems: ["legacy": .legacy32, "native": .native48], stageItems: ["stage": .descriptor(descriptor(p, input: equivalent))])
        XCTAssertEqual(try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: wrongStage).recovery, .blocked)
        let r = p.targetEnrollment.enrollments[0]
        let changed = try NativeEnrollmentEvidence([.init(localEnrollmentId: r.localEnrollmentId, binding: r.binding, claimInput: equivalent, events: r.events)])
        XCTAssertEqual(try assess(s, h: p.targetHistory, e: changed, inventory: inventory(p, staged: true, final: true)).recovery, .blocked)
        let extra = try NativeEnrollmentEvidence([.init(localEnrollmentId: r.localEnrollmentId, binding: r.binding, claimInput: r.claimInput, events: r.events + [.claimProposed])])
        XCTAssertEqual(try assess(s, h: p.targetHistory, e: extra, inventory: inventory(p, staged: true, final: true)).recovery, .blocked)
        let dropped = try DeviceManagementFormatHistory(transitions: [.init(transitionID: p.binding.transitionID, phase: .intent)], credentials: [p.binding])
        XCTAssertEqual(try assess(s, h: dropped, e: p.targetEnrollment, inventory: inventory(p, staged: true, final: true)).recovery, .blocked)
    }
    func testRetainedProvenanceRequiresEveryHistoricalStageAndFinal() throws {
        var old = try fixture()
        for phase in [NativeEnrollmentPreparation.Phase.stageAttempted, .stageQualified, .pairedEvidenceQualified, .promotionAttempted, .promotionQualified, .complete] {
            let paired = phase.rawValue >= NativeEnrollmentPreparation.Phase.pairedEvidenceQualified.rawValue
            old = try old.proposingObservation(phase, history: paired ? old.targetHistory : old.sourceHistory, enrollment: paired ? old.targetEnrollment : old.sourceEnrollment,
                inventory: inventory(old, staged: phase != .stageAttempted, final: phase.rawValue >= 5), retained: [])
        }
        let previous = try step(old, phase: 6), context = try XCTUnwrap(previous.continuation)
        let h = try DeviceManagementFormatHistory(transitions: old.targetHistory.transitions.map { .init(transitionID: $0.transitionID, phase: .locallyFenced) }, credentials: old.targetHistory.credentials)
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "next", format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Next", profile: "iPhone")
        let next = try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "next-stage", binding: binding, claimInput: input,
            history: h, enrollment: old.targetEnrollment, retained: [old], inventory: inventory(old, staged: true, final: true))
        let s = try step(next, phase: 2, context: context, retained: [previous.proposal])
        let items = NativeEnrollmentPreparation.Inventory(finalItems: ["legacy": .legacy32, "native": .native48], stageItems: ["stage": .descriptor(descriptor(old)), "next-stage": .descriptor(descriptor(next))])
        let assessment = try assess(s, inventory: items)
        XCTAssertEqual(assessment.recovery, .pairedEvidenceQualificationRequired)
        XCTAssertEqual(assessment.stagingEnvelopeReferencesRequiringExternalQualification, ["next-stage", "stage"])
        XCTAssertEqual(assessment.native48ReferencesRequiringExternalQualification, ["native"])
        XCTAssertEqual(s.priorDeclarations.count, 1)
        for reference in ["stage", "next-stage"] {
            var stages = items.stageItems; stages.removeValue(forKey: reference)
            XCTAssertEqual(try assess(s, inventory: .init(finalItems: items.finalItems, stageItems: stages)).recovery, .blocked)
        }
        for reference in ["legacy", "native"] {
            var finals = items.finalItems; finals.removeValue(forKey: reference)
            XCTAssertEqual(try assess(s, inventory: .init(finalItems: finals, stageItems: items.stageItems)).recovery, .blocked)
        }
        var stages = items.stageItems
        stages["stage"] = .descriptor(.init(preparationId: old.preparationId, enrollmentId: old.enrollmentId, stageReference: "stage", binding: old.binding, claimInput: input))
        XCTAssertEqual(try assess(s, inventory: .init(finalItems: items.finalItems, stageItems: stages)).recovery, .blocked)
        XCTAssertEqual(context.retainedDeclarationCount, 1)
        XCTAssertLessThanOrEqual(context.retainedCanonicalPayloadBytes, NativePreparationReconstructionContext.maximumRetainedCanonicalPayloadBytes)
    }
    func testKelvinFinalInventoryAliasCannotSatisfyASCIIReference() throws {
        let p = try fixture(finalReference: "K"), s = try step(p, phase: 6)
        let stages: [String: NativeEnrollmentPreparation.StageItem] = ["stage": .descriptor(descriptor(p))]
        let valid = NativeEnrollmentPreparation.Inventory(finalItems: ["legacy": .legacy32, "K": .native48], stageItems: stages)
        let control = try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: valid)
        XCTAssertEqual(control.recovery, .completedEvidenceOnly)
        XCTAssertEqual(control.native48ReferencesRequiringExternalQualification, ["K"])
        let alias = NativeEnrollmentPreparation.Inventory(finalItems: ["legacy": .legacy32, "\u{212A}": .native48], stageItems: stages)
        XCTAssertNotNil(alias.finalItems["K"]) // Actual stdlib normalized lookup.
        XCTAssertFalse("K".utf8.elementsEqual("\u{212A}".utf8))
        let rejected = try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: alias)
        XCTAssertEqual(rejected.recovery, .blocked)
        XCTAssertTrue(rejected.native48ReferencesRequiringExternalQualification.isEmpty)
        XCTAssertTrue(rejected.stagingEnvelopeReferencesRequiringExternalQualification.isEmpty)
    }
    func testKelvinStageInventoryAliasCannotSatisfyASCIIReference() throws {
        let p = try fixture(stageReference: "K"), s = try step(p, phase: 6)
        let finals: [String: NativeEnrollmentPreparation.FinalItem] = ["legacy": .legacy32, "native": .native48]
        let valid = NativeEnrollmentPreparation.Inventory(finalItems: finals, stageItems: ["K": .descriptor(descriptor(p))])
        let control = try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: valid)
        XCTAssertEqual(control.recovery, .completedEvidenceOnly)
        XCTAssertEqual(control.stagingEnvelopeReferencesRequiringExternalQualification, ["K"])
        let alias = NativeEnrollmentPreparation.Inventory(finalItems: finals, stageItems: ["\u{212A}": .descriptor(descriptor(p))])
        XCTAssertNotNil(alias.stageItems["K"]) // Descriptor itself still declares ASCII K.
        let rejected = try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: alias)
        XCTAssertEqual(rejected.recovery, .blocked)
        XCTAssertTrue(rejected.stagingEnvelopeReferencesRequiringExternalQualification.isEmpty)
        XCTAssertTrue(rejected.native48ReferencesRequiringExternalQualification.isEmpty)
    }
    func testInventoryReferenceGrammarIsBoundedForEveryKey() throws {
        let p = try fixture(), s = try step(p, phase: 6)
        for key in ["", "space key", "slash/key", String(repeating: "x", count: 129), "é"] {
            var finals = inventory(p, staged: true, final: true).finalItems; finals[key] = .native48
            XCTAssertEqual(try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: .init(finalItems: finals, stageItems: inventory(p, staged: true, final: true).stageItems)).recovery, .blocked)
            var stages = inventory(p, staged: true, final: true).stageItems; stages[key] = .descriptor(descriptor(p))
            XCTAssertEqual(try assess(s, h: p.targetHistory, e: p.targetEnrollment, inventory: .init(finalItems: inventory(p, staged: true, final: true).finalItems, stageItems: stages)).recovery, .blocked)
        }
        XCTAssertEqual(p.classify(history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: .init(finalItems: ["legacy": .legacy32, "\u{212A}": .native48], stageItems: [:]), retained: []), .blocked)
    }

}
