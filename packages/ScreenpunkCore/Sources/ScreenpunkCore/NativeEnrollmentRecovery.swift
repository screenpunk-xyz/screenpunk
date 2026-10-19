import Foundation

/// Unmounted pure proposals. Every next input needs external durable qualification;
/// neither constructor success nor historical receipts establish protocol trust or authority.
public enum NativeEnrollmentRecoveryPlan: Sendable {
    case claimNeedsExternalDurableQualification(NativeClaimInput, credentialReference: String)
    case activationNeedsExternalDurableQualification(NativeActivationInput, credentialReference: String)
    case pendingClaimNeedsExternalRecoveryQualification
    case terminalClaimEvidence, historicalActivationOnly, blocked
}
public enum NativeEnrollmentRecovery {
    public static func proposingClaim(in evidence: NativeEnrollmentEvidence, history: DeviceManagementFormatHistory, enrollmentId: UUID, binding: DeviceManagementFormatHistory.Binding, input: NativeClaimInput) throws -> NativeEnrollmentEvidence {
        try validate(evidence, history: history)
        guard history.transitions.last?.phase == .intent, history.transitions.last?.transitionID == binding.transitionID,
              binding.format == .nativeInstallationV1, history.credentials.contains(binding), input.transitionId == binding.transitionID,
              !evidence.enrollments.contains(where: { $0.binding.transitionID == binding.transitionID || $0.binding.credentialGenerationID == binding.credentialGenerationID }) else { throw NativeEnrollmentFailure.mismatchedEvidence }
        // Completion reservation: name/profile <= 1536 escaped bytes total;
        // seven RFC3339 timestamps <= 1792 bytes (digits/punctuation do not escape);
        // UUID fields, reference and enum envelopes conservatively <= 4096 bytes.
        // Maximum completion <= 7424 bytes, below each 8192-byte reservation.
        let record = NativeEnrollmentEvidence.Enrollment(localEnrollmentId: enrollmentId, binding: binding, claimInput: input, events: [.claimProposed])
        let proposed = try NativeEnrollmentEvidence(evidence.enrollments + [record]); try validate(proposed, history: history); return proposed
    }
    public static func proposingClaimObservation(in evidence: NativeEnrollmentEvidence, history: DeviceManagementFormatHistory, enrollmentId: UUID, result: NativeClaimResult) throws -> NativeEnrollmentEvidence {
        switch result {
        case .activated(let receipt): return try proposingActivationObservation(in: evidence, history: history, enrollmentId: enrollmentId, receipt: receipt)
        case .claim(let receipt):
            return try change(evidence, history: history, id: enrollmentId) { r in
                try claimMatches(receipt, r: r)
                let event: NativeEnrollmentEvidence.Event = receipt.outcome == .pending ? .pendingClaimObserved(receipt) : .terminalClaimObserved(receipt)
                if let last = r.events.last, try nativeEnrollmentBytes(last) == nativeEnrollmentBytes(event) { return r.events }
                if let prior = pending(r) {
                    guard prior.installationId == receipt.installationId, prior.challengeId == receipt.challengeId,
                          prior.createdAt.utf8.elementsEqual(receipt.createdAt.utf8), prior.expiresAt.utf8.elementsEqual(receipt.expiresAt.utf8) else { throw NativeEnrollmentFailure.mismatchedEvidence }
                }
                switch r.events.last {
                case .claimProposed: break
                case .pendingClaimObserved, .activationProposed: guard receipt.outcome != .pending else { throw NativeEnrollmentFailure.illegalSuccessor }
                default: throw NativeEnrollmentFailure.illegalSuccessor
                }
                return r.events + [event]
            }
        }
    }
    public static func proposingActivation(in evidence: NativeEnrollmentEvidence, history: DeviceManagementFormatHistory, enrollmentId: UUID, requestId: UUID) throws -> NativeEnrollmentEvidence {
        try change(evidence, history: history, id: enrollmentId, requiresIntent: true) { r in
            guard case .pendingClaimObserved(let claim) = r.events.last else { throw NativeEnrollmentFailure.illegalSuccessor }
            return r.events + [.activationProposed(.init(installationId: claim.installationId, requestId: requestId, challengeId: claim.challengeId, transitionId: claim.transitionId))]
        }
    }
    public static func proposingActivationObservation(in evidence: NativeEnrollmentEvidence, history: DeviceManagementFormatHistory, enrollmentId: UUID, receipt: NativeActivationReceipt) throws -> NativeEnrollmentEvidence {
        try change(evidence, history: history, id: enrollmentId) { r in
            let event = NativeEnrollmentEvidence.Event.historicalActivationObserved(receipt)
            if let last = r.events.last, try nativeEnrollmentBytes(last) == nativeEnrollmentBytes(event) { return r.events }
            guard case .activationProposed(let input) = r.events.last,
                  receipt.requestId == input.requestId, receipt.installationId == input.installationId,
                  receipt.transitionId == input.transitionId, receipt.accountId == r.claimInput.accountId,
                  receipt.locationId == r.claimInput.locationId else { throw NativeEnrollmentFailure.mismatchedEvidence }
            return r.events + [event]
        }
    }
    public static func recoveryPlan(evidence: NativeEnrollmentEvidence, history: DeviceManagementFormatHistory, enrollmentId: UUID, availableCredentialReferences: Set<String>) -> NativeEnrollmentRecoveryPlan {
        guard (try? validate(evidence, history: history)) != nil, let r = evidence.enrollments.first(where: { $0.localEnrollmentId == enrollmentId }) else { return .blocked }
        switch r.events.last {
        case .terminalClaimObserved: return .terminalClaimEvidence
        case .historicalActivationObserved: return .historicalActivationOnly
        default: break
        }
        guard history.transitions.last?.transitionID == r.binding.transitionID, history.transitions.last?.phase == .intent,
              availableCredentialReferences.contains(r.binding.credentialReference) else { return .blocked }
        switch r.events.last {
        case .claimProposed: return .claimNeedsExternalDurableQualification(r.claimInput, credentialReference: r.binding.credentialReference)
        case .activationProposed(let input): return .activationNeedsExternalDurableQualification(input, credentialReference: r.binding.credentialReference)
        case .pendingClaimObserved: return .pendingClaimNeedsExternalRecoveryQualification
        default: return .blocked
        }
    }
    private static func pending(_ r: NativeEnrollmentEvidence.Enrollment) -> NativeClaimReceipt? {
        for event in r.events { if case .pendingClaimObserved(let claim) = event { return claim } }; return nil
    }
    private static func claimMatches(_ c: NativeClaimReceipt, r: NativeEnrollmentEvidence.Enrollment) throws {
        guard c.requestId == r.claimInput.requestId, c.transitionId == r.claimInput.transitionId, c.accountId == r.claimInput.accountId, c.locationId == r.claimInput.locationId else { throw NativeEnrollmentFailure.mismatchedEvidence }
    }
    private static func change(_ evidence: NativeEnrollmentEvidence, history: DeviceManagementFormatHistory, id: UUID, requiresIntent: Bool = false, operation: (NativeEnrollmentEvidence.Enrollment) throws -> [NativeEnrollmentEvidence.Event]) throws -> NativeEnrollmentEvidence {
        try validate(evidence, history: history)
        guard let index = evidence.enrollments.firstIndex(where: { $0.localEnrollmentId == id }) else { throw NativeEnrollmentFailure.mismatchedEvidence }
        let r = evidence.enrollments[index]
        if requiresIntent { guard history.transitions.last?.transitionID == r.binding.transitionID, history.transitions.last?.phase == .intent else { throw NativeEnrollmentFailure.illegalSuccessor } }
        var records = evidence.enrollments
        records[index] = .init(localEnrollmentId: r.localEnrollmentId, binding: r.binding, claimInput: r.claimInput, events: try operation(r))
        let proposed = try NativeEnrollmentEvidence(records); try validate(proposed, history: history); return proposed
    }
    private static func validate(_ evidence: NativeEnrollmentEvidence, history: DeviceManagementFormatHistory) throws {
        var ids = Set(history.transitions.map(\.transitionID) + history.credentials.map(\.credentialGenerationID))
        var bindings = Set<UUID>(), transitions = Set<UUID>()
        func fresh(_ id: UUID) throws { guard ids.insert(id).inserted else { throw NativeEnrollmentFailure.mismatchedEvidence } }
        var installations = Set<UUID>(), challenges = Set<UUID>(), generations = Set<UUID>()
        var serverOwners: [UUID: UUID] = [:]
        func server(_ identifier: UUID, enrollment: UUID) throws {
            if let owner = serverOwners[identifier], owner != enrollment { throw NativeEnrollmentFailure.mismatchedEvidence }
            serverOwners[identifier] = enrollment
        }
        for r in evidence.enrollments {
            guard history.credentials.contains(r.binding), r.binding.format == .nativeInstallationV1,
                  r.claimInput.transitionId == r.binding.transitionID, bindings.insert(r.binding.credentialGenerationID).inserted,
                  transitions.insert(r.binding.transitionID).inserted else { throw NativeEnrollmentFailure.mismatchedEvidence }
            try fresh(r.localEnrollmentId); try fresh(r.claimInput.requestId)
            for event in r.events {
                switch event {
                case .activationProposed(let input): try fresh(input.requestId)
                case .pendingClaimObserved(let c), .terminalClaimObserved(let c): try server(c.installationId, enrollment: r.localEnrollmentId); try server(c.challengeId, enrollment: r.localEnrollmentId)
                    installations.insert(c.installationId); challenges.insert(c.challengeId)
                case .historicalActivationObserved(let a): try server(a.installationId, enrollment: r.localEnrollmentId); try server(a.initialGeneration.generationId, enrollment: r.localEnrollmentId)
                    installations.insert(a.installationId); generations.insert(a.initialGeneration.generationId)
                default: break
                }
            }
        }
        guard installations.isDisjoint(with: challenges), installations.isDisjoint(with: generations), challenges.isDisjoint(with: generations), installations.union(challenges).union(generations).isDisjoint(with: ids) else { throw NativeEnrollmentFailure.mismatchedEvidence }
    }
}
