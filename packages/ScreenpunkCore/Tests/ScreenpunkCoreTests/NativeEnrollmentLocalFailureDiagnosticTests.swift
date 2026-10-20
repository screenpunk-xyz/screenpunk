import XCTest
@_spi(NativeInstallation) @_spi(ManagedRender) @testable import ScreenpunkCore

final class NativeEnrollmentLocalFailureDiagnosticTests: XCTestCase {
    func testExactInternalErrorsMapToFixedDomainAndReason() throws {
        check(DevicePackagePreparationError.invalidMetadata, .packageStore, .invalidRecord)
        check(DevicePackagePreparationError.sizeLimit, .packageStore, .sizeLimit)
        check(DevicePackagePreparationError.scopeOverlap, .packageStore, .scopeOverlap)
        check(DevicePackagePreparationError.unsafeBinding, .packageStore, .unsafeBinding)
        check(DevicePackagePreparationError.conflict, .packageStore, .conflict)
        check(DevicePackagePreparationError.capacity, .packageStore, .capacity)
        check(DevicePackagePreparationError.repairRequired, .packageStore, .repairRequired)
        check(DevicePackagePreparationError.outcomeUncertain, .packageStore, .outcomeUncertain)
        check(DevicePackagePreparationError.digestUnavailable, .packageStore, .digestUnavailable)
        check(DevicePackagePreparationError.io(13), .packageStore, .io)
        check(DeviceNativeGrantPreparationError.invalidRecord, .grantStore, .invalidRecord)
        check(DeviceNativeGrantPreparationError.sizeLimit, .grantStore, .sizeLimit)
        check(DeviceNativeGrantPreparationError.unsafeBinding, .grantStore, .unsafeBinding)
        check(DeviceNativeGrantPreparationError.scopeOverlap, .grantStore, .scopeOverlap)
        check(DeviceNativeGrantPreparationError.conflict, .grantStore, .conflict)
        check(DeviceNativeGrantPreparationError.capacity, .grantStore, .capacity)
        check(DeviceNativeGrantPreparationError.repairRequired, .grantStore, .repairRequired)
        check(DeviceNativeGrantPreparationError.outcomeUncertain, .grantStore, .outcomeUncertain)
        check(DeviceNativeGrantPreparationError.io(13), .grantStore, .io)
        check(DeviceStructuralStoreError.invalidRecord, .structuralStore, .invalidRecord)
        check(DeviceStructuralStoreError.tooLarge, .structuralStore, .sizeLimit)
        check(DeviceStructuralStoreError.unsafeBinding, .structuralStore, .unsafeBinding)
        check(DeviceStructuralStoreError.conflict, .structuralStore, .conflict)
        check(DeviceStructuralStoreError.capacity, .structuralStore, .capacity)
        check(DeviceStructuralStoreError.outcomeUncertain, .structuralStore, .outcomeUncertain)
        check(DeviceStructuralStoreError.io(13), .structuralStore, .io)
        check(DeviceLocalProvisioningIntentStore.Failure.unsafeRoot, .provisioningStore, .unsafeRoot)
        check(DeviceLocalProvisioningIntentStore.Failure.conflict, .provisioningStore, .conflict)
        check(DeviceLocalProvisioningIntentStore.Failure.uncertain, .provisioningStore, .outcomeUncertain)
        check(DeviceLocalProvisioningIntentStore.Failure.capacity, .provisioningStore, .capacity)
        check(DeviceLocalProvisioningIntentStore.Failure.io(13), .provisioningStore, .io)
        check(NativeEnrollmentJournalError.invalidRecord, .nativeJournal, .invalidRecord)
        check(NativeEnrollmentJournalError.capacity, .nativeJournal, .capacity)
        check(NativeEnrollmentJournalError.unsafeRoot, .nativeJournal, .unsafeRoot)
        check(NativeEnrollmentJournalError.conflict, .nativeJournal, .conflict)
        check(NativeEnrollmentJournalError.outcomeUncertain, .nativeJournal, .outcomeUncertain)
        check(NativeEnrollmentJournalError.io(13), .nativeJournal, .io)
        check(NativeEnrollmentPromotionError.blocked, .nativePromotion, .blocked)
        check(NativeEnrollmentPromotionError.conflict, .nativePromotion, .conflict)
        check(NativeEnrollmentPromotionError.outcomeUncertain, .nativePromotion, .outcomeUncertain)
    }
    func testUnknownAndAssociatedIOValuesRevealNoAdditionalDiagnostic() {
        struct Unrelated: Error {}
        XCTAssertNil(NativeEnrollmentLocalFailureDiagnostic.classify(Unrelated()))
        XCTAssertNil(NativeEnrollmentLocalFailureDiagnostic.classify(DeviceNativeManagedRootFailure.changedAnchor))
        XCTAssertEqual(NativeEnrollmentLocalFailureDiagnostic.classify(NativeEnrollmentJournalError.io(1)),
                       NativeEnrollmentLocalFailureDiagnostic.classify(NativeEnrollmentJournalError.io(999)))
    }
    func testDeliveryBoundaryFailuresMapToExactStaticFamilyAndCase() {
        checkStatic(DeviceMixedInventoryStore.Failure.unsafeRoot, "mixedInventory/unsafeRoot")
        checkStatic(DeviceMixedInventoryStore.Failure.corruptHistory, "mixedInventory/corruptHistory")
        checkStatic(DeviceMixedInventoryStore.Failure.staleGeneration, "mixedInventory/staleGeneration")
        checkStatic(DeviceMixedInventoryStore.Failure.needsReview, "mixedInventory/needsReview")
        checkStatic(DeviceMixedInventoryStore.Failure.disabled, "mixedInventory/disabled")
        checkStatic(DeviceMixedInventoryStore.Failure.persistence, "mixedInventory/persistence")
        checkStatic(DeviceLocalResourceGateFailure.invalidRoots, "resourceGate/invalidRoots")
        checkStatic(DeviceLocalResourceGateFailure.reentrant, "resourceGate/reentrant")
        checkStatic(DeviceLocalResourceGateFailure.invalidScope, "resourceGate/invalidScope")
        checkStatic(DeviceCommandIntentCoordinator.Failure.needsReview, "commandFence/needsReview")
        checkStatic(DeviceCommandIntentCoordinator.Failure.corruptJournal, "commandFence/corruptJournal")
        checkStatic(DeviceCommandIntentCoordinator.Failure.conflictingOperation, "commandFence/conflictingOperation")
        checkStatic(DeviceCommandIntentCoordinator.Failure.persistence, "commandFence/persistence")
        checkStatic(NativeOperationalTransportFailure.invalidResponse, "operationalTransport/invalidResponse")
        checkStatic(NativeOperationalTransportFailure.responseTooLarge, "operationalTransport/responseTooLarge")
        checkStatic(NativeOperationalTransportFailure.redirected, "operationalTransport/redirected")
        checkStatic(NativeOperationalTransportFailure.transport, "operationalTransport/transport")
        checkStatic(NativeDeliveryExecutionError.bounds, "deliveryExecution/bounds")
        checkStatic(NativeDeliveryExecutionError.association, "deliveryExecution/association")
        checkStatic(NativeDeliveryExecutionError.unsupportedCapabilities, "deliveryExecution/unsupportedCapabilities")
        checkStatic(NativeDeliveryExecutionError.phase, "deliveryExecution/phase")
        checkStatic(NativeDeliveryExecutionError.unavailableDispatchCapability, "deliveryExecution/unavailableDispatchCapability")
        checkStatic(DeviceManagedRenderFailure.unsupportedCapabilities, "managedRender/unsupportedCapabilities")
        checkStatic(DeviceManagedRenderFailure.invalidContent, "managedRender/invalidContent")
        checkStatic(DeviceManagedRenderFailure.emptySelection, "managedRender/emptySelection")
        checkStatic(DeviceManagedRenderFailure.sizeLimit, "managedRender/sizeLimit")
        checkStatic(DeviceNativeStructuralFailure.capacity, "structuralCodec/capacity")
        checkStatic(DeviceNativeStructuralFailure.invalidJSON, "structuralCodec/invalidJSON")
        checkStatic(DeviceNativeStructuralFailure.duplicateKey, "structuralCodec/duplicateKey")
        checkStatic(DeviceNativeStructuralFailure.invalidSchema, "structuralCodec/invalidSchema")
        checkStatic(NativeScreenServiceFailure.offline, "screenService/offline")
        checkStatic(NativeScreenServiceFailure.quotaExhausted, "screenService/quotaExhausted")
        checkStatic(NativeScreenServiceFailure.disconnected, "screenService/disconnected")
        checkStatic(NativeScreenServiceFailure.unavailable, "screenService/unavailable")
    }
    func testPackageRejectionKeepsAUsefulFixedDiagnostic() {
        check(DevicePackageQualificationError.targetMismatch, .packageCompatibility, .targetMismatch)
        check(DevicePackageQualificationError.digestMismatch, .packageCompatibility, .digestMismatch)
        check(DeviceNativeArchiveQualificationError.integrity, .packageArchive, .integrity)
        check(DeviceNativeArchiveQualificationError.invalidZIP, .packageArchive, .invalidZIP)
    }
    func testUnknownDescriptionsAndAssociatedContextRemainUnobserved() {
        struct DescribedFailure: Error, CustomStringConvertible, LocalizedError {
            var description: String { XCTFail("Classification must not inspect an arbitrary Error description"); return "synthetic-secret" }
            var errorDescription: String? { XCTFail("Classification must not inspect localized Error text"); return "synthetic-secret" }
        }
        XCTAssertNil(NativeEnrollmentLocalFailureDiagnostic.classify(DescribedFailure()))
        XCTAssertNil(NativeEnrollmentLocalFailureDiagnostic.classify(NSError(domain: "synthetic-private-domain", code: 8675309,
            userInfo: [NSLocalizedDescriptionKey: "synthetic-secret"])))
        XCTAssertNil(NativeEnrollmentLocalFailureDiagnostic.classify(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "synthetic-secret"))))
    }
    private func checkStatic(_ error: any Error, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let diagnostic = NativeEnrollmentLocalFailureDiagnostic.classify(error)
        XCTAssertEqual(diagnostic.map { $0.domain.rawValue + "/" + $0.reason.rawValue }, expected, file: file, line: line)
    }
    private func check(_ error: any Error, _ domain: NativeEnrollmentLocalFailureCategory,
                       _ reason: NativeEnrollmentLocalFailureReason, file: StaticString = #filePath, line: UInt = #line) {
        let diagnostic = NativeEnrollmentLocalFailureDiagnostic.classify(error)
        XCTAssertEqual(diagnostic?.domain, domain, file: file, line: line)
        XCTAssertEqual(diagnostic?.reason, reason, file: file, line: line)
    }
}
