import Foundation

@_spi(NativeInstallation) public final class NativeInstallationUnifiedCloudAcceptanceResult {
    fileprivate let command: ObjectIdentifier
    fileprivate init(_ command: NativeInstallationUnifiedCloudAcceptanceCommand) { self.command = ObjectIdentifier(command) }
}
/// Issued only from the original fixed authenticated command/plan collector.
/// It durably accepts explicit intent without claiming package readiness or activation.
@_spi(NativeInstallation) public final class NativeInstallationUnifiedCloudAcceptanceCommand {
    public let commonRootID: UUID, installationID: UUID, operationID: UUID
    public let key: String, digest: String
    public let requiresConcurrentQualification: Bool
    private let current: NativeCurrentInstallationDispatch
    private let persist: () throws -> Void
    private let validate: () throws -> Void
    private let mutex = NSLock()
    private var invoking = false, consumed = false
    init(current: NativeCurrentInstallationDispatch, binding: DeviceNativeDeliveryCommandBinding,
        commonRootID: UUID, containsLocal: Bool, validate: @escaping () throws -> Void, persist: @escaping () throws -> Void) throws {
        self.current = current; self.persist = persist; self.validate = validate; self.commonRootID = commonRootID
        installationID = binding.association.installationID; operationID = binding.association.operationID
        key = "cloud:" + installationID.uuidString.lowercased() + ":" + operationID.uuidString.lowercased()
        digest = try DeviceNativeDeliveryAttachmentCodec.hash(binding.commandBytes + binding.planBytes)
        requiresConcurrentQualification = containsLocal
    }
    func beginFixedInvocation(current: NativeCurrentInstallationDispatch) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard self.current === current, !invoking, !consumed else { throw NativeDeliveryExecutionError.phase }; invoking = true
    }
    func endFixedInvocation() { mutex.lock(); invoking = false; mutex.unlock() }
    public func performDuringFixedOwner() throws -> NativeInstallationUnifiedCloudAcceptanceResult {
        mutex.lock(); guard invoking, !consumed else { mutex.unlock(); throw NativeDeliveryExecutionError.phase }
        consumed = true; mutex.unlock()
        try validate(); try persist(); try validate(); return .init(self)
    }
    func validateResult(_ result: NativeInstallationUnifiedCloudAcceptanceResult) throws {
        guard result.command == ObjectIdentifier(self) else { throw NativeDeliveryExecutionError.association }
    }
}
