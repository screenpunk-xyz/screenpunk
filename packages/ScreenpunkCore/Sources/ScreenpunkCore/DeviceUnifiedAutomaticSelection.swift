import Foundation

@_spi(NativeInstallation) public protocol NativeUnifiedAutomationOwner: AnyObject {
    var commonRootID: UUID { get }
    func performFixedAutomaticSelection(_ command: NativeInstallationAutomaticSelectionCommand) throws -> NativeInstallationAutomaticSelectionResult
}
@_spi(NativeInstallation) public final class NativeInstallationAutomaticSelectionResult {
    fileprivate let command: ObjectIdentifier
    let capture: DeviceMixedInventoryStore.Capture
    fileprivate init(_ command: NativeInstallationAutomaticSelectionCommand, capture: DeviceMixedInventoryStore.Capture) {
        self.command = ObjectIdentifier(command); self.capture = capture
    }
}
/// Produced only by the device's qualified HA recipe reader. It advances content
/// generation without pretending an automatic event was a new controller intent.
@_spi(NativeInstallation) public final class NativeInstallationAutomaticSelectionCommand {
    public let commonRootID: UUID, installationID: UUID, baseGenerationID: UUID, resultingGenerationID: UUID
    private let owner: any NativeUnifiedAutomationOwner
    private let permit: DeviceUnifiedAutomaticSelectionPermit
    private let resolver: DeviceMixedResourceResolver
    private let original: DeviceMixedResolvedResources
    private let store: DeviceMixedInventoryStore
    private let operationID = UUID()
    private let mutex = NSLock()
    private var invoking = false, consumed = false
    init(owner: any NativeUnifiedAutomationOwner, permit: DeviceUnifiedAutomaticSelectionPermit,
        resolver: DeviceMixedResourceResolver, original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore) throws {
        guard owner.commonRootID == store.rootID else { throw DeviceStructuralStoreError.conflict }
        self.owner = owner; self.permit = permit; self.resolver = resolver; self.original = original; self.store = store
        commonRootID = store.rootID; installationID = permit.baseCapture.snapshot.installationOwner.installationID
        baseGenerationID = permit.baseCapture.snapshot.generationID; resultingGenerationID = UUID()
    }
    func dispatch() throws -> NativeInstallationAutomaticSelectionResult {
        mutex.lock(); guard !invoking, !consumed else { mutex.unlock(); throw DeviceStructuralStoreError.conflict }
        invoking = true; mutex.unlock()
        defer { mutex.lock(); invoking = false; mutex.unlock() }
        let result = try owner.performFixedAutomaticSelection(self)
        guard result.command == ObjectIdentifier(self) else { throw DeviceStructuralStoreError.conflict }
        return result
    }
    public func performDuringFixedOwner() throws -> NativeInstallationAutomaticSelectionResult {
        mutex.lock(); guard invoking, !consumed else { mutex.unlock(); throw DeviceStructuralStoreError.conflict }
        consumed = true; mutex.unlock()
        // This validation is resource-only; no session or owner lock re-entry.
        try permit.validateEvent()
        let capture = try resolver.commitAutomaticSelectionExact(original, store: store, permit: permit,
            operationID: operationID, generationID: resultingGenerationID)
        return .init(self, capture: capture)
    }
}
