import Foundation

/// Fixed diagnostic categories only; no filesystem, credential, or authority evidence.
@_spi(NativeInstallation) public enum NativeEnrollmentLocalFailureCategory: String, Equatable, Sendable {
    case packageStore, grantStore, structuralStore, provisioningStore, nativeJournal, nativePromotion
    case mixedInventory, resourceGate, commandFence, operationalTransport
    case deliveryExecution, managedRender, structuralCodec, screenService
}
@_spi(NativeInstallation) public enum NativeEnrollmentLocalFailureReason: String, Equatable, Sendable {
    case unsafeRoot, unsafeBinding, invalidRecord, capacity, conflict, repairRequired
    case outcomeUncertain, io, blocked, scopeOverlap, sizeLimit, digestUnavailable
    case corruptHistory, staleGeneration, needsReview, disabled, persistence
    case invalidRoots, reentrant, invalidScope, corruptJournal, conflictingOperation
    case invalidResponse, responseTooLarge, redirected, transport, bounds
    case association, unsupportedCapabilities, phase, unavailableDispatchCapability, invalidContent
    case emptySelection, invalidJSON, duplicateKey, invalidSchema, offline
    case quotaExhausted, disconnected, unavailable
}
@_spi(NativeInstallation) public struct NativeEnrollmentLocalFailureDiagnostic: Equatable, Sendable {
    public let domain: NativeEnrollmentLocalFailureCategory
    public let reason: NativeEnrollmentLocalFailureReason
    private init(_ domain: NativeEnrollmentLocalFailureCategory, _ reason: NativeEnrollmentLocalFailureReason) {
        self.domain = domain; self.reason = reason
    }
    /// Classify exact Core error types without descriptions, associated values or fallback inference.
    public static func classify(_ error: any Error) -> Self? {
        if let value = error as? DevicePackagePreparationError {
            switch value {
            case .invalidMetadata: return .init(.packageStore, .invalidRecord)
            case .sizeLimit: return .init(.packageStore, .sizeLimit)
            case .scopeOverlap: return .init(.packageStore, .scopeOverlap)
            case .unsafeBinding: return .init(.packageStore, .unsafeBinding)
            case .conflict: return .init(.packageStore, .conflict)
            case .capacity: return .init(.packageStore, .capacity)
            case .repairRequired: return .init(.packageStore, .repairRequired)
            case .outcomeUncertain: return .init(.packageStore, .outcomeUncertain)
            case .digestUnavailable: return .init(.packageStore, .digestUnavailable)
            case .io: return .init(.packageStore, .io)
            }
        }
        if let value = error as? DeviceNativeGrantPreparationError {
            switch value {
            case .invalidRecord: return .init(.grantStore, .invalidRecord)
            case .sizeLimit: return .init(.grantStore, .sizeLimit)
            case .unsafeBinding: return .init(.grantStore, .unsafeBinding)
            case .scopeOverlap: return .init(.grantStore, .scopeOverlap)
            case .conflict: return .init(.grantStore, .conflict)
            case .capacity: return .init(.grantStore, .capacity)
            case .repairRequired: return .init(.grantStore, .repairRequired)
            case .outcomeUncertain: return .init(.grantStore, .outcomeUncertain)
            case .io: return .init(.grantStore, .io)
            }
        }
        if let value = error as? DeviceStructuralStoreError {
            switch value {
            case .invalidRecord: return .init(.structuralStore, .invalidRecord)
            case .tooLarge: return .init(.structuralStore, .sizeLimit)
            case .unsafeBinding: return .init(.structuralStore, .unsafeBinding)
            case .conflict: return .init(.structuralStore, .conflict)
            case .capacity: return .init(.structuralStore, .capacity)
            case .outcomeUncertain: return .init(.structuralStore, .outcomeUncertain)
            case .io: return .init(.structuralStore, .io)
            }
        }
        if let value = error as? DeviceLocalProvisioningIntentStore.Failure {
            switch value {
            case .unsafeRoot: return .init(.provisioningStore, .unsafeRoot)
            case .conflict: return .init(.provisioningStore, .conflict)
            case .uncertain: return .init(.provisioningStore, .outcomeUncertain)
            case .capacity: return .init(.provisioningStore, .capacity)
            case .io: return .init(.provisioningStore, .io)
            }
        }
        if let value = error as? NativeEnrollmentJournalError {
            switch value {
            case .invalidRecord: return .init(.nativeJournal, .invalidRecord)
            case .capacity: return .init(.nativeJournal, .capacity)
            case .unsafeRoot: return .init(.nativeJournal, .unsafeRoot)
            case .conflict: return .init(.nativeJournal, .conflict)
            case .outcomeUncertain: return .init(.nativeJournal, .outcomeUncertain)
            case .io: return .init(.nativeJournal, .io)
            }
        }
        if let value = error as? NativeEnrollmentPromotionError {
            switch value {
            case .blocked: return .init(.nativePromotion, .blocked)
            case .conflict: return .init(.nativePromotion, .conflict)
            case .outcomeUncertain: return .init(.nativePromotion, .outcomeUncertain)
            }
        }
        if let value = error as? DeviceMixedInventoryStore.Failure {
            switch value {
            case .unsafeRoot: return .init(.mixedInventory, .unsafeRoot)
            case .corruptHistory: return .init(.mixedInventory, .corruptHistory)
            case .staleGeneration: return .init(.mixedInventory, .staleGeneration)
            case .needsReview: return .init(.mixedInventory, .needsReview)
            case .disabled: return .init(.mixedInventory, .disabled)
            case .persistence: return .init(.mixedInventory, .persistence)
            }
        }
        if let value = error as? DeviceLocalResourceGateFailure {
            switch value {
            case .invalidRoots: return .init(.resourceGate, .invalidRoots)
            case .reentrant: return .init(.resourceGate, .reentrant)
            case .invalidScope: return .init(.resourceGate, .invalidScope)
            }
        }
        if let value = error as? DeviceCommandIntentCoordinator.Failure {
            switch value {
            case .needsReview: return .init(.commandFence, .needsReview)
            case .corruptJournal: return .init(.commandFence, .corruptJournal)
            case .conflictingOperation: return .init(.commandFence, .conflictingOperation)
            case .persistence: return .init(.commandFence, .persistence)
            }
        }
        if let value = error as? NativeOperationalTransportFailure {
            switch value {
            case .invalidResponse: return .init(.operationalTransport, .invalidResponse)
            case .responseTooLarge: return .init(.operationalTransport, .responseTooLarge)
            case .redirected: return .init(.operationalTransport, .redirected)
            case .transport: return .init(.operationalTransport, .transport)
            }
        }
        if let value = error as? NativeDeliveryExecutionError {
            switch value {
            case .bounds: return .init(.deliveryExecution, .bounds)
            case .association: return .init(.deliveryExecution, .association)
            case .unsupportedCapabilities: return .init(.deliveryExecution, .unsupportedCapabilities)
            case .phase: return .init(.deliveryExecution, .phase)
            case .unavailableDispatchCapability: return .init(.deliveryExecution, .unavailableDispatchCapability)
            }
        }
        if let value = error as? DeviceManagedRenderFailure {
            switch value {
            case .unsupportedCapabilities: return .init(.managedRender, .unsupportedCapabilities)
            case .invalidContent: return .init(.managedRender, .invalidContent)
            case .emptySelection: return .init(.managedRender, .emptySelection)
            case .sizeLimit: return .init(.managedRender, .sizeLimit)
            }
        }
        if let value = error as? DeviceNativeStructuralFailure {
            switch value {
            case .capacity: return .init(.structuralCodec, .capacity)
            case .invalidJSON: return .init(.structuralCodec, .invalidJSON)
            case .duplicateKey: return .init(.structuralCodec, .duplicateKey)
            case .invalidSchema: return .init(.structuralCodec, .invalidSchema)
            }
        }
        if let value = error as? NativeScreenServiceFailure {
            switch value {
            case .offline: return .init(.screenService, .offline)
            case .quotaExhausted: return .init(.screenService, .quotaExhausted)
            case .disconnected: return .init(.screenService, .disconnected)
            case .unavailable: return .init(.screenService, .unavailable)
            }
        }
        return nil
    }
}
