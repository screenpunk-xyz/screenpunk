import Foundation

/// Pure, nonsecret preparation proposals. No persistence, serialization, key
/// insertion, envelope authentication, transport or authority is provided here.
public enum NativePreparationFailure: Error, Equatable { case invalidProposal, illegalPhase, inventoryBlocked, capacityExceeded }
/// Structural assessment only: caller-supplied inventory remains an observation,
/// never an immutable-envelope/secret proof or a filesystem durability receipt.
public struct NativePreparationReconstructionAssessment: Sendable {
    public let recovery: NativeEnrollmentPreparation.Recovery
    /// References from a structurally matching inventory only. A blocked result
    /// lists none and still requires complete external inventory qualification.
    public let stagingEnvelopeReferencesRequiringExternalQualification: [String]
    public let native48ReferencesRequiringExternalQualification: [String]
    public var requiresExternalInventoryQualification: Bool { true }
    public var requiresPairedEvidenceDurabilityQualification: Bool { true }
    public var requiresJournalDurabilityQualification: Bool { true }
    private init(recovery: NativeEnrollmentPreparation.Recovery, stages: [String], finals: [String]) {
        self.recovery = recovery
        stagingEnvelopeReferencesRequiringExternalQualification = stages
        native48ReferencesRequiringExternalQualification = finals
    }
    fileprivate static func make(recovery: NativeEnrollmentPreparation.Recovery,
        inventory: NativeEnrollmentPreparation.Inventory) -> Self {
        // A blocked assessment offers no adoption/qualification plan for orphan
        // items. No caller-sized inventory is copied into the result.
        guard recovery != .blocked else { return .init(recovery: .blocked, stages: [], finals: []) }
        let stages = inventory.stageItems.compactMap { key, value in
            if case .descriptor = value { return key }; return nil
        }.sorted()
        let finals = inventory.finalItems.compactMap { key, value in
            if case .native48 = value { return key }; return nil
        }.sorted()
        return .init(recovery: recovery, stages: stages, finals: finals)
    }
}

public struct NativeEnrollmentPreparation: Sendable {
    public enum Phase: Int, Sendable {
        case intent, stageAttempted, stageQualified, pairedEvidenceQualified
        case promotionAttempted, promotionQualified, complete
    }
    public static let maximumPreparations = 64
    public static let maximumReservedBytes = 2_097_152
    public static let maximumTotalReservedBytes = maximumPreparations * maximumReservedBytes
    public let preparationId: UUID
    public let enrollmentId: UUID
    public let stageReference: String
    public let binding: DeviceManagementFormatHistory.Binding
    public let sourceHistory: DeviceManagementFormatHistory
    public let targetHistory: DeviceManagementFormatHistory
    public let sourceEnrollment: NativeEnrollmentEvidence
    public let targetEnrollment: NativeEnrollmentEvidence
    public let claimInput: NativeClaimInput
    public let phase: Phase
    /// Structural completion reservation, not an encoded durable record size.
    public let reservedBytes: Int
    private init(preparationId: UUID, enrollmentId: UUID, stageReference: String, binding: DeviceManagementFormatHistory.Binding,
                 sourceHistory: DeviceManagementFormatHistory, targetHistory: DeviceManagementFormatHistory,
                 sourceEnrollment: NativeEnrollmentEvidence, targetEnrollment: NativeEnrollmentEvidence,
                 claimInput: NativeClaimInput, phase: Phase, reservedBytes: Int) {
        self.preparationId = preparationId; self.enrollmentId = enrollmentId; self.stageReference = stageReference
        self.binding = binding; self.sourceHistory = sourceHistory; self.targetHistory = targetHistory
        self.sourceEnrollment = sourceEnrollment; self.targetEnrollment = targetEnrollment
        self.claimInput = claimInput; self.phase = phase; self.reservedBytes = reservedBytes
    }
    /// Caller supplies the full retained preparation inventory; only one may be unfinished.
    public static func proposing(preparationId: UUID, enrollmentId: UUID, stageReference: String,
        binding: DeviceManagementFormatHistory.Binding, claimInput: NativeClaimInput,
        history: DeviceManagementFormatHistory, enrollment: NativeEnrollmentEvidence,
        retained: [NativeEnrollmentPreparation], inventory: Inventory) throws -> Self {
        guard retained.count < maximumPreparations, Set(retained.map(\.preparationId)).count == retained.count, retained.allSatisfy({ $0.phase == .complete }) else { throw NativePreparationFailure.capacityExceeded }
        _ = try DeviceManagementCredentialBinding(credentialGenerationID: binding.credentialGenerationID, transitionID: binding.transitionID, credentialReference: stageReference)
        var existingIDs = Set(history.transitions.map(\.transitionID) + history.credentials.map(\.credentialGenerationID) + retained.map(\.preparationId))
        for record in enrollment.enrollments {
            existingIDs.formUnion([record.localEnrollmentId, record.claimInput.requestId])
            for event in record.events {
                switch event {
                case .activationProposed(let i): existingIDs.insert(i.requestId)
                case .pendingClaimObserved(let c), .terminalClaimObserved(let c): existingIDs.formUnion([c.installationId, c.challengeId])
                case .historicalActivationObserved(let a): existingIDs.formUnion([a.installationId, a.initialGeneration.generationId])
                default: break
                }
            }
        }
        let newIDs = [preparationId, enrollmentId, binding.transitionID, binding.credentialGenerationID, claimInput.requestId]
        guard Set(newIDs).count == newIDs.count, Set(newIDs).isDisjoint(with: existingIDs),
              history.transitions.allSatisfy({ $0.phase == .locallyFenced }), binding.format == .nativeInstallationV1,
              claimInput.transitionId == binding.transitionID, stageReference != binding.credentialReference,
              !retained.contains(where: { $0.stageReference == stageReference || $0.binding.credentialReference == binding.credentialReference }),
              !history.credentials.contains(where: { $0.credentialReference == binding.credentialReference }) else { throw NativePreparationFailure.invalidProposal }
        let target = try DeviceManagementFormatHistory(transitions: history.transitions + [.init(transitionID: binding.transitionID, phase: .intent)], credentials: history.credentials + [binding])
        let proposed = try NativeEnrollmentRecovery.proposingClaim(in: enrollment, history: target, enrollmentId: enrollmentId, binding: binding, input: claimInput)
        // Two history snapshots reserve the existing 64KiB format limit. Two
        // enrollment snapshots reserve every record's complete four-event path.
        let bytes = 2 * DeviceManagementTransitionStore.maximumRecordBytes + (enrollment.enrollments.count + proposed.enrollments.count) * NativeEnrollmentEvidence.reservedBytesPerRecord + 4096
        guard bytes <= maximumReservedBytes, retained.reduce(bytes, { $0 + $1.reservedBytes }) <= maximumTotalReservedBytes else { throw NativePreparationFailure.capacityExceeded }
        let result = Self(preparationId: preparationId, enrollmentId: enrollmentId, stageReference: stageReference, binding: binding,
                     sourceHistory: history, targetHistory: target, sourceEnrollment: enrollment, targetEnrollment: proposed,
                     claimInput: claimInput, phase: .intent, reservedBytes: bytes)
        guard result.classify(history: history, enrollment: enrollment, inventory: inventory, retained: retained) == .confirmedPrestageAbsence else { throw NativePreparationFailure.inventoryBlocked }
        return result
    }
    /// Caller-provided metadata only; a future Apple adapter must qualify the
    /// immutable envelope and exact raw secret. This type never proves possession.
    public struct StageDescriptor: Sendable {
        public let preparationId: UUID, enrollmentId: UUID
        public let stageReference: String
        public let binding: DeviceManagementFormatHistory.Binding
        public let claimInput: NativeClaimInput
        public init(preparationId: UUID, enrollmentId: UUID, stageReference: String, binding: DeviceManagementFormatHistory.Binding, claimInput: NativeClaimInput) {
            self.preparationId = preparationId; self.enrollmentId = enrollmentId; self.stageReference = stageReference; self.binding = binding; self.claimInput = claimInput
        }
    }
    public enum FinalItem: Sendable { case legacy32, native48, inaccessible, malformed }
    public enum StageItem: Sendable { case descriptor(StageDescriptor), inaccessible, malformed }
    public struct Inventory: Sendable {
        public let finalItems: [String: FinalItem]
        public let stageItems: [String: StageItem]
        public init(finalItems: [String: FinalItem], stageItems: [String: StageItem]) { self.finalItems = finalItems; self.stageItems = stageItems }
    }
    public enum Recovery: Equatable, Sendable {
        case confirmedPrestageAbsence
        /// No regeneration, key adoption or remote attempt is authorized.
        case ambiguousStageAttempt
        case envelopeQualificationRequired, pairedEvidenceQualificationRequired
        case exactPromotionQualificationRequired, completedEvidenceOnly, blocked
    }
    public func classify(history: DeviceManagementFormatHistory, enrollment: NativeEnrollmentEvidence, inventory: Inventory, retained: [NativeEnrollmentPreparation]) -> Recovery {
        guard retained.count < Self.maximumPreparations else { return .blocked }
        return classify(history: history, enrollment: enrollment, inventory: inventory,
            declarations: retained.map(InventoryDeclaration.init), retainedPhasesValid: retained.allSatisfy { $0.phase == .complete })
    }
    /// Uses validated streamed provenance and actual caller-supplied current
    /// observations. It returns no preparation handle and acknowledges no IO.
    public static func assessingReconstruction(_ step: NativePreparationReconstructionStep,
        currentHistory: DeviceManagementFormatHistory, currentEnrollment: NativeEnrollmentEvidence,
        inventory: Inventory) -> NativePreparationReconstructionAssessment {
        let p = step.proposal
        let structural = Self(preparationId: p.preparationId, enrollmentId: p.enrollmentId, stageReference: p.stageReference,
            binding: p.binding, sourceHistory: p.sourceHistory, targetHistory: p.targetHistory,
            sourceEnrollment: p.sourceEnrollment, targetEnrollment: p.targetEnrollment,
            claimInput: p.claimInput, phase: p.phase, reservedBytes: p.reservedBytes)
        let recovery = structural.classify(history: currentHistory, enrollment: currentEnrollment, inventory: inventory,
            declarations: step.priorDeclarations.map(InventoryDeclaration.init), retainedPhasesValid: true)
        return .make(recovery: recovery, inventory: inventory)
    }
    private func classify(history: DeviceManagementFormatHistory, enrollment: NativeEnrollmentEvidence,
        inventory: Inventory, declarations: [InventoryDeclaration], retainedPhasesValid: Bool) -> Recovery {
        guard retainedPhasesValid, (try? validateInventory(inventory, declarations: declarations)) != nil else { return .blocked }
        guard let currentBytes = try? nativeEnrollmentBytes(enrollment),
              let sourceBytes = try? nativeEnrollmentBytes(sourceEnrollment),
              let targetBytes = try? nativeEnrollmentBytes(targetEnrollment),
              let currentHistoryBytes = try? nativeEnrollmentBytes(history),
              let sourceHistoryBytes = try? nativeEnrollmentBytes(sourceHistory),
              let targetHistoryBytes = try? nativeEnrollmentBytes(targetHistory) else { return .blocked }
        let sourceHistoryMatches = currentHistoryBytes == sourceHistoryBytes
        let targetHistoryMatches = currentHistoryBytes == targetHistoryBytes
        let sourceMatches = currentBytes == sourceBytes, targetMatches = currentBytes == targetBytes
        switch phase {
        case .intent:
            guard sourceHistoryMatches, sourceMatches, inventory.stageItems[stageReference] == nil else { return .blocked }
            return .confirmedPrestageAbsence
        case .stageAttempted:
            guard sourceHistoryMatches, sourceMatches else { return .blocked }
            return inventory.stageItems[stageReference] == nil ? .ambiguousStageAttempt : .envelopeQualificationRequired
        case .stageQualified:
            guard (sourceHistoryMatches || targetHistoryMatches), (sourceMatches || targetMatches) else { return .blocked }
            return .pairedEvidenceQualificationRequired
        case .pairedEvidenceQualified:
            guard targetHistoryMatches, targetMatches else { return .blocked }; return .exactPromotionQualificationRequired
        case .promotionAttempted, .promotionQualified:
            guard targetHistoryMatches, targetMatches else { return .blocked }; return .exactPromotionQualificationRequired
        case .complete:
            guard targetHistoryMatches, targetMatches else { return .blocked }; return .completedEvidenceOnly
        }
    }
    /// A monotonic typed observation proposal, never an acknowledgment of IO.
    public func proposingObservation(_ next: Phase, history: DeviceManagementFormatHistory,
        enrollment: NativeEnrollmentEvidence, inventory: Inventory, retained: [NativeEnrollmentPreparation]) throws -> Self {
        guard next == phase || next.rawValue == phase.rawValue + 1 else { throw NativePreparationFailure.illegalPhase }
        let result = Self(preparationId: preparationId, enrollmentId: enrollmentId, stageReference: stageReference, binding: binding,
                          sourceHistory: sourceHistory, targetHistory: targetHistory, sourceEnrollment: sourceEnrollment, targetEnrollment: targetEnrollment,
                          claimInput: claimInput, phase: next, reservedBytes: reservedBytes)
        guard result.classify(history: history, enrollment: enrollment, inventory: inventory, retained: retained) != .blocked else { throw NativePreparationFailure.inventoryBlocked }
        return result
    }
    private struct InventoryDeclaration {
        let preparationId: UUID, enrollmentId: UUID
        let stageReference: String
        let binding: DeviceManagementFormatHistory.Binding
        let claimInput: NativeClaimInput
        init(_ p: NativeEnrollmentPreparation) {
            preparationId = p.preparationId; enrollmentId = p.enrollmentId; stageReference = p.stageReference
            binding = p.binding; claimInput = p.claimInput
        }
        init(_ p: PreparationDeclaration) {
            preparationId = p.preparationId; enrollmentId = p.enrollmentId; stageReference = p.stageReference
            binding = p.binding; claimInput = p.claimInput
        }
        func matches(_ d: StageDescriptor) -> Bool {
            preparationId == d.preparationId && enrollmentId == d.enrollmentId && stageReference.utf8.elementsEqual(d.stageReference.utf8)
                && binding == d.binding && claimInput == d.claimInput
        }
    }
    private func validateInventory(_ inventory: Inventory, declarations retained: [InventoryDeclaration]) throws {
        guard inventory.stageItems.count <= Self.maximumPreparations,
              inventory.finalItems.count <= DeviceManagementTransitionHistory.maximumCredentials,
              retained.count < Self.maximumPreparations, Set(retained.map(\.preparationId)).count == retained.count,
              Set(retained.map { $0.binding.credentialGenerationID }).count == retained.count,
              retained.allSatisfy({ $0.preparationId != preparationId }) else { throw NativePreparationFailure.inventoryBlocked }
        let historicalNative = sourceHistory.credentials.filter { $0.format == .nativeInstallationV1 }
        guard historicalNative.count == retained.count,
              historicalNative.allSatisfy({ key in retained.filter { $0.binding == key }.count == 1 }),
              retained.allSatisfy({ historicalNative.contains($0.binding) }) else { throw NativePreparationFailure.inventoryBlocked }
        let all = retained + [InventoryDeclaration(self)]
        guard Set(all.map(\.stageReference)).count == all.count else { throw NativePreparationFailure.inventoryBlocked }
        let declaredStages = Set(all.map(\.stageReference))
        let declaredFinals = Set(targetHistory.credentials.map(\.credentialReference))
        guard Set(inventory.stageItems.keys).isSubset(of: declaredStages), Set(inventory.finalItems.keys).isSubset(of: declaredFinals) else { throw NativePreparationFailure.inventoryBlocked }
        for key in targetHistory.credentials {
            if key == binding && phase.rawValue < Phase.promotionQualified.rawValue {
                if inventory.finalItems[key.credentialReference] != nil && phase.rawValue < Phase.promotionAttempted.rawValue { throw NativePreparationFailure.inventoryBlocked }
                if inventory.finalItems[key.credentialReference] == nil { continue }
            }
            guard let item = inventory.finalItems[key.credentialReference] else { throw NativePreparationFailure.inventoryBlocked }
            switch (key.format, item) {
            case (.legacyLocal32, .legacy32), (.nativeInstallationV1, .native48): break
            default: throw NativePreparationFailure.inventoryBlocked
            }
        }
        for record in all {
            guard let item = inventory.stageItems[record.stageReference] else {
                if record.preparationId == preparationId && phase.rawValue <= Phase.stageAttempted.rawValue { continue }
                throw NativePreparationFailure.inventoryBlocked
            }
            guard case .descriptor(let descriptor) = item, record.matches(descriptor) else { throw NativePreparationFailure.inventoryBlocked }
        }
    }
}
