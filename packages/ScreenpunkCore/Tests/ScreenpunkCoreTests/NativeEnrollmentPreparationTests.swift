import XCTest
@testable import ScreenpunkCore
final class NativeEnrollmentPreparationTests: XCTestCase {
    func fixture() throws -> NativeEnrollmentPreparation {
        let old = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "old", format: .legacyLocal32)
        let history = try DeviceManagementFormatHistory(transitions: [.init(transitionID: old.transitionID, phase: .locallyFenced)], credentials: [old])
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "new", format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Cafe\u{301}", profile: "iPad")
        return try .proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage", binding: binding, claimInput: input, history: history, enrollment: .init(), retained: [], inventory: .init(finalItems: ["old": .legacy32], stageItems: [:]))
    }
    func descriptor(_ p: NativeEnrollmentPreparation, input: NativeClaimInput? = nil) -> NativeEnrollmentPreparation.StageDescriptor {
        .init(preparationId: p.preparationId, enrollmentId: p.enrollmentId, stageReference: p.stageReference, binding: p.binding, claimInput: input ?? p.claimInput)
    }
    func inventory(_ p: NativeEnrollmentPreparation, staged: Bool = false, final: Bool = false) -> NativeEnrollmentPreparation.Inventory {
        .init(finalItems: final ? ["old": .legacy32, "new": .native48] : ["old": .legacy32], stageItems: staged ? ["stage": .descriptor(descriptor(p))] : [:])
    }
    func testLegalPathExactDuplicateAndPreservation() throws {
        var p = try fixture()
        XCTAssertEqual(p.targetHistory.transitions.dropLast().map(\.transitionID), p.sourceHistory.transitions.map(\.transitionID))
        XCTAssertEqual(Array(p.targetHistory.credentials.dropLast()), p.sourceHistory.credentials)
        XCTAssertEqual(p.classify(history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p), retained: []), .confirmedPrestageAbsence)
        p = try p.proposingObservation(.stageAttempted, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p), retained: [])
        XCTAssertEqual(p.classify(history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p), retained: []), .ambiguousStageAttempt)
        XCTAssertThrowsError(try p.proposingObservation(.stageQualified, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p), retained: []))
        p = try p.proposingObservation(.stageQualified, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p, staged: true), retained: [])
        p = try p.proposingObservation(.pairedEvidenceQualified, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p, staged: true), retained: [])
        p = try p.proposingObservation(.promotionAttempted, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p, staged: true), retained: [])
        XCTAssertThrowsError(try p.proposingObservation(.promotionQualified, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p, staged: true), retained: []))
        p = try p.proposingObservation(.promotionQualified, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p, staged: true, final: true), retained: [])
        p = try p.proposingObservation(.complete, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p, staged: true, final: true), retained: [])
        XCTAssertEqual(p.classify(history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p, staged: true, final: true), retained: []), .completedEvidenceOnly)
        XCTAssertNoThrow(try p.proposingObservation(.complete, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p, staged: true, final: true), retained: []))
        XCTAssertThrowsError(try p.proposingObservation(.intent, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p), retained: []))
    }
    func testOrphansWrongFormatsMissingAndExactInputs() throws {
        let p = try fixture()
        let inventories: [NativeEnrollmentPreparation.Inventory] = [
            .init(finalItems: ["old": .legacy32, "orphan": .native48], stageItems: [:]),
            .init(finalItems: ["old": .native48], stageItems: [:]),
            .init(finalItems: [:], stageItems: [:]),
            .init(finalItems: ["old": .inaccessible], stageItems: [:]),
            .init(finalItems: ["old": .legacy32], stageItems: ["orphan": .descriptor(descriptor(p))]),
            .init(finalItems: ["old": .legacy32], stageItems: ["stage": .malformed]),
            .init(finalItems: ["old": .legacy32, "new": .native48], stageItems: [:])
        ]
        for i in inventories { XCTAssertEqual(p.classify(history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: i, retained: []), .blocked) }
        let attempted = try p.proposingObservation(.stageAttempted, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p), retained: [])
        let equivalent = try NativeClaimInput(requestId: p.claimInput.requestId, transitionId: p.claimInput.transitionId, accountId: p.claimInput.accountId, locationId: p.claimInput.locationId, name: "Café", profile: p.claimInput.profile)
        XCTAssertEqual(attempted.classify(history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: .init(finalItems: ["old": .legacy32], stageItems: ["stage": .descriptor(descriptor(p, input: equivalent))]), retained: []), .blocked)
        let staged = try attempted.proposingObservation(.stageQualified, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p, staged: true), retained: [])
        XCTAssertEqual(staged.classify(history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p), retained: []), .blocked)
        XCTAssertThrowsError(try p.proposingObservation(.pairedEvidenceQualified, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p), retained: []))
    }
    func testPairedUncertaintyRequiresExactSnapshots() throws {
        let p = try fixture()
        let attempted = try p.proposingObservation(.stageAttempted, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p), retained: [])
        let staged = try attempted.proposingObservation(.stageQualified, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: inventory(p, staged: true), retained: [])
        for h in [p.sourceHistory, p.targetHistory] {
            for e in [p.sourceEnrollment, p.targetEnrollment] {
                XCTAssertEqual(staged.classify(history: h, enrollment: e, inventory: inventory(p, staged: true), retained: []), .pairedEvidenceQualificationRequired)
                XCTAssertNoThrow(try staged.proposingObservation(.stageQualified, history: h, enrollment: e, inventory: inventory(p, staged: true), retained: []))
                let exactTarget = try nativeEnrollmentBytes(e) == nativeEnrollmentBytes(p.targetEnrollment)
                if h != p.targetHistory || !exactTarget {
                    XCTAssertThrowsError(try staged.proposingObservation(.pairedEvidenceQualified, history: h, enrollment: e, inventory: inventory(p, staged: true), retained: []))
                }
            }
        }
        let paired = try staged.proposingObservation(.pairedEvidenceQualified, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p, staged: true), retained: [])
        XCTAssertEqual(paired.classify(history: p.targetHistory, enrollment: .init(), inventory: inventory(p, staged: true), retained: []), .blocked)
        let r = p.targetEnrollment.enrollments[0]
        let changedInput = try NativeClaimInput(requestId: r.claimInput.requestId, transitionId: r.claimInput.transitionId, accountId: r.claimInput.accountId, locationId: r.claimInput.locationId, name: "Café", profile: r.claimInput.profile)
        let changed = try NativeEnrollmentEvidence([.init(localEnrollmentId: r.localEnrollmentId, binding: r.binding, claimInput: changedInput, events: r.events)])
        let extra = try NativeEnrollmentEvidence([.init(localEnrollmentId: r.localEnrollmentId, binding: r.binding, claimInput: r.claimInput, events: r.events + [.claimProposed])])
        for e in [changed, extra] { XCTAssertEqual(paired.classify(history: p.targetHistory, enrollment: e, inventory: inventory(p, staged: true), retained: []), .blocked) }
        XCTAssertThrowsError(try paired.proposingObservation(.stageQualified, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: inventory(p, staged: true), retained: []))
    }
    func testHistoricalNativeNeedsExactRetainedPreparationAndStage() throws {
        var old = try fixture()
        for next in [NativeEnrollmentPreparation.Phase.stageAttempted, .stageQualified, .pairedEvidenceQualified, .promotionAttempted, .promotionQualified, .complete] {
            let target = next.rawValue >= NativeEnrollmentPreparation.Phase.pairedEvidenceQualified.rawValue
            old = try old.proposingObservation(next, history: target ? old.targetHistory : old.sourceHistory, enrollment: target ? old.targetEnrollment : old.sourceEnrollment, inventory: inventory(old, staged: next != .stageAttempted, final: next.rawValue >= NativeEnrollmentPreparation.Phase.promotionQualified.rawValue), retained: [])
        }
        let source = try DeviceManagementFormatHistory(transitions: old.targetHistory.transitions.map { .init(transitionID: $0.transitionID, phase: .locallyFenced) }, credentials: old.targetHistory.credentials)
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "next", format: .nativeInstallationV1)
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: old.claimInput.accountId, locationId: old.claimInput.locationId, name: "next", profile: "iPhone")
        let inv = NativeEnrollmentPreparation.Inventory(finalItems: ["old": .legacy32, "new": .native48], stageItems: ["stage": .descriptor(descriptor(old))])
        let next = try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "next-stage", binding: binding, claimInput: claim, history: source, enrollment: old.targetEnrollment, retained: [old], inventory: inv)
        XCTAssertEqual(next.classify(history: source, enrollment: old.targetEnrollment, inventory: inv, retained: [old]), .confirmedPrestageAbsence)
        XCTAssertEqual(next.classify(history: source, enrollment: old.targetEnrollment, inventory: inv, retained: []), .blocked)
        XCTAssertEqual(next.classify(history: source, enrollment: old.targetEnrollment, inventory: inv, retained: [old,old]), .blocked)
        XCTAssertEqual(next.classify(history: source, enrollment: old.targetEnrollment, inventory: .init(finalItems: inv.finalItems, stageItems: [:]), retained: [old]), .blocked)
        XCTAssertThrowsError(try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "next-stage", binding: binding, claimInput: claim, history: source, enrollment: old.targetEnrollment, retained: [], inventory: inv))
        let wrong = try DeviceManagementFormatHistory.Binding(credentialGenerationID: old.binding.credentialGenerationID, transitionID: old.binding.transitionID, credentialReference: "wrong", format: .nativeInstallationV1)
        let wrongSource = try DeviceManagementFormatHistory(transitions: source.transitions, credentials: [source.credentials[0], wrong])
        XCTAssertThrowsError(try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "next-stage", binding: binding, claimInput: claim, history: wrongSource, enrollment: old.targetEnrollment, retained: [old], inventory: inv))
    }
    func testProposalIdentityHistoryAndCapacityGuards() throws {
        let p = try fixture()
        func proposal(_ id: UUID, history: DeviceManagementFormatHistory, retained: [NativeEnrollmentPreparation] = []) throws -> NativeEnrollmentPreparation {
            try .proposing(preparationId: id, enrollmentId: p.enrollmentId, stageReference: p.stageReference, binding: p.binding, claimInput: p.claimInput, history: history, enrollment: .init(), retained: retained, inventory: inventory(p))
        }
        XCTAssertThrowsError(try proposal(p.claimInput.requestId, history: p.sourceHistory))
        XCTAssertThrowsError(try proposal(p.preparationId, history: p.targetHistory))
        XCTAssertThrowsError(try proposal(p.preparationId, history: p.sourceHistory, retained: [p]))
        XCTAssertThrowsError(try proposal(p.preparationId, history: p.sourceHistory, retained: Array(repeating: p, count: 64)))
        let manyBindings = try (0..<64).map { index in
            try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "old-\(index)", format: .legacyLocal32)
        }
        let fullHistory = try DeviceManagementFormatHistory(transitions: manyBindings.map { .init(transitionID: $0.transitionID, phase: .locallyFenced) }, credentials: manyBindings)
        XCTAssertThrowsError(try proposal(p.preparationId, history: fullHistory))
        XCTAssertThrowsError(try NativeEnrollmentPreparation.proposing(preparationId: p.preparationId, enrollmentId: p.enrollmentId, stageReference: p.stageReference, binding: p.binding, claimInput: p.claimInput, history: p.sourceHistory, enrollment: .init(), retained: [], inventory: .init(finalItems: ["old": .legacy32, "unknown": .native48], stageItems: [:])))
        XCTAssertLessThan(p.reservedBytes, NativeEnrollmentPreparation.maximumReservedBytes)
    }
}
