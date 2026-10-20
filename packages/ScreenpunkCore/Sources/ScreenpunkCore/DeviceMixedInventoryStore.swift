import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Durable common inventory CAS. Decoding remains available when mutation
/// admission is disabled. No previous schema-3 state becomes exclusive Local state.
final class DeviceMixedInventoryStore {
    enum Failure: Error { case unsafeRoot, corruptHistory, staleGeneration, needsReview, disabled, persistence }
    struct Intent: Codable, Equatable { let operationID: UUID; let previous: Data?; let candidate: Data }
    struct Receipt: Codable, Equatable { let operationID: UUID; let generationID: UUID; let digest: String }
    final class Capture {
        let snapshot: DeviceMixedStructuralState
        let bytes: Data
        fileprivate let issuer: ObjectIdentifier
        fileprivate init(_ issuer: ObjectIdentifier, _ state: DeviceMixedStructuralState, _ bytes: Data) {
            self.issuer = issuer; snapshot = state; self.bytes = bytes
        }
    }
    enum CommitBoundary { case intentInstalled, currentInstalled, receiptInstalled }
    private let commitBoundary: (CommitBoundary) throws -> Void
    let root: URL
    let rootID: UUID
    private let mutex = NSLock()
    private struct Binding: Codable, Equatable { let rootID: UUID; let path: String; let device: UInt64; let inode: UInt64; let lockDevice: UInt64; let lockInode: UInt64 }
    private var borrowedRoot: Int32?
    private let filesystemContextFactory: (URL, Int32, URL?) throws -> DevicePersistedFilesystemContext
    private var activeFilesystemContext: DevicePersistedFilesystemContext?
    private var originalBindingBytes: Data?
    init(root: URL, rootID: UUID,
        filesystemContextFactory: @escaping (URL, Int32, URL?) throws -> DevicePersistedFilesystemContext = { try .capture(currentRoot: $0, heldRoot: $1, plannedPublicationRoot: $2) },
        commitBoundary: @escaping (CommitBoundary) throws -> Void = { _ in }) {
        self.root = Self.physicalParentPath(root); self.rootID = rootID
        self.filesystemContextFactory = filesystemContextFactory; self.commitBoundary = commitBoundary
    }
    private static func physicalParentPath(_ value: URL) -> URL {
        value.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(value.lastPathComponent,
            isDirectory: true).standardizedFileURL
    }
    var resourceGateDescriptor: DeviceLocalResourceDescriptor { get throws {
        try .existing(instance: ObjectIdentifier(self), path: root.path, rootID: rootID)
    } }
    /// Preserve the existing physical parent spelling; Foundation parent URL access can
    /// reintroduce the /var alias after the original root has been qualified.
    func incomingPackageRootExact(operationID: UUID) throws -> URL {
        var named = stat()
        guard lstat(root.path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
            let physical = realpath(root.path, nil) else { throw Failure.unsafeRoot }
        defer { free(physical) }
        let path = String(cString: physical)
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent + ".incoming-" + operationID.uuidString.lowercased()
        guard name.utf8.count <= 255, parent != path else { throw Failure.unsafeRoot }
        return URL(fileURLWithPath: parent + "/" + name, isDirectory: true)
    }
    /// The caller creates and owns this exact empty directory before initialization.
    /// Existing unrelated files, symlinks and incompatible bindings are refused.
    func initializeExplicit(recordedFinalRoot: URL? = nil) throws {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        try withRoot(plannedPublicationRoot: recordedFinalRoot.map { Self.physicalParentPath($0) }) { descriptor in
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            if let bytes = try read(descriptor, "mixed-root.json", maximum: 8192) {
                try requireBindingBytes(bytes, descriptor: descriptor,
                    recordedPath: recordedFinalRoot.map { Self.physicalParentPath($0).path })
                try validateNames(names); return
            }
            guard names.isEmpty || names == ["mixed.lock"] else { throw Failure.unsafeRoot }
            try replace(descriptor, "mixed-root.json", bytes: encode(binding(descriptor, recordedPath: recordedFinalRoot.map { Self.physicalParentPath($0).path }), maximum: 8192))
        }
    }
    /// Read-only opening never needs the concurrent-control capability flag.
    func readCurrent() throws -> Capture? {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in try checkedCurrent(descriptor) }
    }
    func withResourceGateScope(_ permit: DeviceLocalResourcePermit, _ body: () throws -> Void) throws {
        try permit.beginAcquisition(resourceGateDescriptor)
        mutex.lock(); defer { permit.invalidate(); mutex.unlock() }
        try withRoot { descriptor in
            try requireBinding(descriptor); borrowedRoot = descriptor
            defer { borrowedRoot = nil }
            try body(); try requireBinding(descriptor)
        }
    }
    /// Called only by the fixed mixed resolver while all source roots are held.
    /// The prior qualified capture is exact; IDs/candidate bytes are caller-retained
    /// and identical uncertain-write retries never regenerate a generation.
    func commitExact(operationID: UUID, previous: Capture?, candidate: DeviceMixedStructuralState,
        admissionEnabled: Bool, permit: DeviceLocalResourcePermit) throws -> (Capture, Receipt) {
        try commitInventoryExact(operationID: operationID, previous: previous, candidate: candidate,
            admissionEnabled: admissionEnabled, attachmentTransition: false, permit: permit)
    }
    func beginCloudDetachmentExact(operationID: UUID, previous: Capture, candidate: DeviceMixedStructuralState,
        retirement: NativeCloudCredentialRetirement, permit: DeviceLocalResourcePermit) throws -> (Capture, Receipt) {
        guard previous.snapshot.detachment == nil, previous.snapshot.logoutIntent == nil,
            retirement.installationID == previous.snapshot.installationOwner.installationID,
            candidate.installationOwner == previous.snapshot.installationOwner, candidate.detachment == nil,
            candidate.logoutIntent?.retirementMetadata == retirement.canonicalMetadata,
            candidate.cloudObservationEpoch == previous.snapshot.cloudObservationEpoch,
            (previous.snapshot.legacyLocalRoots == nil || candidate.legacyLocalRoots == previous.snapshot.legacyLocalRoots),
            candidate.entries == previous.snapshot.entries, candidate.configuredEntryID == previous.snapshot.configuredEntryID else { throw Failure.staleGeneration }
        return try commitInventoryExact(operationID: operationID, previous: previous, candidate: candidate,
            admissionEnabled: true, attachmentTransition: true, permit: permit)
    }
    func commitCloudDetachmentExact(operationID: UUID, previous: Capture, candidate: DeviceMixedStructuralState,
        revocation: NativeConfirmedCloudRevocation, permit: DeviceLocalResourcePermit) throws -> (Capture, Receipt) {
        guard let accepted = previous.snapshot.logoutIntent,
            operationID == accepted.detachOperationID, candidate.generationID == accepted.detachGenerationID,
            candidate.logoutIntent == nil, candidate.detachment?.retirementMetadata == accepted.retirementMetadata,
            revocation.installationOwner == previous.snapshot.installationOwner,
            candidate.legacyLocalRoots == previous.snapshot.legacyLocalRoots,
            candidate.cloudObservationEpoch == previous.snapshot.cloudObservationEpoch,
            previous.snapshot.detachment == nil, candidate.installationOwner == previous.snapshot.installationOwner,
            candidate.detachment?.revokedAt == revocation.revokedAt,
            candidate.entries == previous.snapshot.entries.filter({ if case .retainedLocal = $0 { return true }; return false }) else { throw Failure.staleGeneration }
        return try commitInventoryExact(operationID: operationID, previous: previous, candidate: candidate,
            admissionEnabled: true, attachmentTransition: true, permit: permit)
    }
    func commitCloudCleanupExact(operationID: UUID, previous: Capture, candidate: DeviceMixedStructuralState,
        receipt: NativeConfirmedCloudCleanup, permit: DeviceLocalResourcePermit) throws -> (Capture, Receipt) {
        guard let old = previous.snapshot.detachment, let next = candidate.detachment, !old.cleanupCompleted, next.cleanupCompleted,
            receipt.canonicalRetirementMetadata == old.retirementMetadata, next.retirementMetadata == old.retirementMetadata,
            next.revokedAt == old.revokedAt, candidate.installationOwner == previous.snapshot.installationOwner,
            candidate.entries == previous.snapshot.entries, candidate.configuredEntryID == previous.snapshot.configuredEntryID,
            candidate.legacyLocalRoots == previous.snapshot.legacyLocalRoots, candidate.cloudObservationEpoch == previous.snapshot.cloudObservationEpoch,
            candidate.logoutIntent == nil else { throw Failure.staleGeneration }
        return try commitInventoryExact(operationID: operationID, previous: previous, candidate: candidate,
            admissionEnabled: true, attachmentTransition: true, permit: permit)
    }
    func commitCloudAttachmentExact(operationID: UUID, previous: Capture, candidate: DeviceMixedStructuralState,
        permit: DeviceLocalResourcePermit) throws -> (Capture, Receipt) {
        guard previous.snapshot.detachment?.cleanupCompleted == true, candidate.detachment == nil,
            candidate.installationOwner.installationID != previous.snapshot.installationOwner.installationID,
            candidate.cloudObservationEpoch == candidate.installationOwner.installationID,
            candidate.legacyLocalRoots == previous.snapshot.legacyLocalRoots,
            candidate.entries == previous.snapshot.entries,
            candidate.configuredEntryID == previous.snapshot.configuredEntryID else { throw Failure.staleGeneration }
        return try commitInventoryExact(operationID: operationID, previous: previous, candidate: candidate,
            admissionEnabled: true, attachmentTransition: true, permit: permit)
    }
    private func commitInventoryExact(operationID: UUID, previous: Capture?, candidate: DeviceMixedStructuralState,
        admissionEnabled: Bool, attachmentTransition: Bool, permit: DeviceLocalResourcePermit) throws -> (Capture, Receipt) {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard admissionEnabled else { throw Failure.disabled }
        guard let descriptor = borrowedRoot else { throw DeviceLocalResourceGateFailure.invalidScope }
        if let previous {
            guard previous.issuer == ObjectIdentifier(self), candidate.generationID != previous.snapshot.generationID,
                  (attachmentTransition || (candidate.installationOwner == previous.snapshot.installationOwner && candidate.detachment == previous.snapshot.detachment && candidate.legacyLocalRoots == previous.snapshot.legacyLocalRoots && candidate.cloudObservationEpoch == previous.snapshot.cloudObservationEpoch && previous.snapshot.logoutIntent == nil && candidate.logoutIntent == nil)) else { throw Failure.staleGeneration }
        }
        let bytes = try DeviceMixedStructuralStateCodec.encode(candidate)
        let intent = Intent(operationID: operationID, previous: previous?.bytes, candidate: bytes)
        let intentName = operationID.uuidString.lowercased() + ".mixed-intent.json"
        let receiptName = operationID.uuidString.lowercased() + ".mixed-receipt.json"
        let encodedIntent = try encode(intent, maximum: 384 * 1024)
        let current = try checkedCurrent(descriptor, allowPending: operationID)
        if let recorded = try read(descriptor, intentName, maximum: 384 * 1024) {
            guard recorded == encodedIntent else { throw Failure.corruptHistory }
        } else {
            guard current?.bytes == previous?.bytes else { throw Failure.staleGeneration }
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            // Never discard history to permit a reused command. Bounded exhaustion requires review.
            guard names.filter({ $0.hasSuffix(".mixed-intent.json") }).count < 256 else { throw Failure.needsReview }
            try replace(descriptor, intentName, bytes: encodedIntent)
            try commitBoundary(.intentInstalled)
        }
        guard current?.bytes == previous?.bytes || current?.bytes == bytes else { throw Failure.staleGeneration }
        if current?.bytes != bytes { try replace(descriptor, "mixed-current.json", bytes: bytes); try commitBoundary(.currentInstalled) }
        let receipt = Receipt(operationID: operationID, generationID: candidate.generationID, digest: try DeviceNativeDeliveryAttachmentCodec.hash(bytes))
        let receiptBytes = try encode(receipt, maximum: 8192)
        if let recorded = try read(descriptor, receiptName, maximum: 8192) {
            guard recorded == receiptBytes else { throw Failure.corruptHistory }
        } else { try replace(descriptor, receiptName, bytes: receiptBytes) }
        guard let final = try checkedCurrent(descriptor), final.bytes == bytes else { throw Failure.persistence }
        return (final, receipt)
    }
    func verifyCompletedCandidateExact(operationID: UUID, candidate: DeviceMixedStructuralState, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot else { throw DeviceLocalResourceGateFailure.invalidScope }
        _ = try checkedCurrent(descriptor)
        guard let bytes = try read(descriptor, operationID.uuidString.lowercased() + ".mixed-intent.json", maximum: 384 * 1024),
            try decode(Intent.self, bytes, maximum: 384 * 1024).candidate == (try DeviceMixedStructuralStateCodec.encode(candidate)),
            try read(descriptor, operationID.uuidString.lowercased() + ".mixed-receipt.json", maximum: 8192) != nil else { throw Failure.corruptHistory }
    }
    func captureCurrentExact(permit: DeviceLocalResourcePermit) throws -> Capture? {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot else { throw DeviceLocalResourceGateFailure.invalidScope }
        return try checkedCurrent(descriptor)
    }
    func verifyExact(_ capture: Capture, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, capture.issuer == ObjectIdentifier(self),
              try checkedCurrent(descriptor)?.bytes == capture.bytes else { throw Failure.staleGeneration }
    }
    final class StaticGrantReceipt {
        fileprivate let issuer: ObjectIdentifier
        fileprivate let operationID: UUID
        fileprivate let bytes: Data
        fileprivate init(_ issuer: ObjectIdentifier, operationID: UUID, bytes: Data) { self.issuer = issuer; self.operationID = operationID; self.bytes = bytes }
    }
    struct StaticGrantFrame: Codable {
        let operationID: UUID
        let originalGenerationID: UUID
        let deliveryCommand: Data
        let deliveryPlan: Data
        let deliveryAssociation: DeviceNativeDeliveryCommandBinding.Association
        let journalRootID: UUID
        let candidate: Data
        let grantIdentity: DeviceGrantRevisionIdentity
        let grantOperationID: UUID
        let publicMetadata: Data
        let incomingPackageRootID: UUID
        let incomingPackagePath: String
    }
    /// Static-only Cloud grants have no secrets. Their qualified immutable public
    /// frame belongs to this common root, never an unrelated native grant root.
    func retainIncomingStaticGrantExact(_ command: DeviceMixedPreparedCloudCommand,
        incomingPackageRoot: DeviceLocalResourceDescriptor, permit: DeviceLocalResourcePermit) throws -> StaticGrantReceipt {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, command.capture.issuer == ObjectIdentifier(self),
              command.grantInput.identity.rootID == rootID,
              incomingPackageRoot.path == (try incomingPackageRootExact(operationID: command.delivery.nativeOperationID)).path,
              command.packageInputs.allSatisfy({ input in
                  guard case .supplied(let id, _, _) = input,
                        let value = command.candidate.entries.first(where: { $0.entryID == id }),
                        case .cloud(let entry, _) = value else { return false }
                  return entry.preparedPackage.rootID == incomingPackageRoot.rootID
              }),
              command.grantInput.credentials.isEmpty, command.grantInput.retainedRevisions.isEmpty,
              command.grantInput.entries.allSatisfy({ $0.generic == nil && $0.homeAssistant == nil && $0.publicReads == nil && $0.credentialReferences.isEmpty }),
              try checkedCurrent(descriptor)?.bytes == command.capture.bytes else { throw Failure.staleGeneration }
        let expectations = try command.packageInputs.map { input -> DeviceGrantEntryExpectation in
            guard case .supplied(let id, _, let package) = input else { throw Failure.corruptHistory }
            return .init(entryID: id, package: package)
        }
        let qualified = try DeviceNativeGrantRevisionQualifier.qualify(command.grantInput, expectedEntries: expectations)
        guard qualified.exactlyMatches(command.qualifiedGrant) else { throw Failure.corruptHistory }
        let frame = StaticGrantFrame(operationID: command.delivery.nativeOperationID,
            originalGenerationID: command.capture.snapshot.generationID, deliveryCommand: command.delivery.commandBytes,
            deliveryPlan: command.delivery.planBytes, deliveryAssociation: command.delivery.association, journalRootID: command.delivery.journalRootID,
            candidate: try DeviceMixedStructuralStateCodec.encode(command.candidate), grantIdentity: command.grantInput.identity,
            grantOperationID: command.grantOperationID, publicMetadata: qualified.publicMetadataBytes,
            incomingPackageRootID: incomingPackageRoot.rootID, incomingPackagePath: incomingPackageRoot.path)
        let bytes = try encode(frame, maximum: 256 * 1024)
        let name = frame.operationID.uuidString.lowercased() + ".mixed-static-grant.json"
        if let original = try read(descriptor, name, maximum: 256 * 1024) {
            guard original == bytes else { throw Failure.corruptHistory }
        } else { try replace(descriptor, name, bytes: bytes) }
        return .init(ObjectIdentifier(self), operationID: frame.operationID, bytes: bytes)
    }
    func verifyIncomingStaticGrantExact(_ receipt: StaticGrantReceipt, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, receipt.issuer == ObjectIdentifier(self),
              try read(descriptor, receipt.operationID.uuidString.lowercased() + ".mixed-static-grant.json", maximum: 256 * 1024) == receipt.bytes else { throw Failure.corruptHistory }
        _ = try decode(StaticGrantFrame.self, receipt.bytes, maximum: 256 * 1024)
    }
    struct AutomationFrame: Codable {
        let operationID: UUID, explicitBaseGenerationID: UUID, ownedGenerationID: UUID
        let targetEntryID: UUID, previousEntryID: UUID?, deadline: Date, alertID: String
        let navigation: TemporaryActivationNavigation
        let origin: String
    }
    func retainAutomationExact(_ frame: AutomationFrame, previous: Capture, restoring: Bool, permit: DeviceLocalResourcePermit) throws {
        try self.verifyExact(previous, permit: permit)
        guard let descriptor = borrowedRoot, frame.origin == "screenAutomation", frame.alertID.utf8.count <= 128,
            !frame.alertID.isEmpty else { throw Failure.needsReview }
        if let bytes = try read(descriptor, "mixed-automation.json", maximum: 8192) {
            let old = try decode(AutomationFrame.self, bytes, maximum: 8192)
            if restoring {
                guard old.ownedGenerationID == previous.snapshot.generationID, old.targetEntryID == frame.targetEntryID,
                    old.previousEntryID == frame.previousEntryID, old.alertID == frame.alertID,
                    old.explicitBaseGenerationID == frame.explicitBaseGenerationID else { throw Failure.needsReview }
            } else { guard old.alertID != frame.alertID else { throw Failure.needsReview } }
        } else { guard !restoring else { throw Failure.needsReview } }
        try replace(descriptor, "mixed-automation.json", bytes: encode(frame, maximum: 8192))
    }
    func automationExact() throws -> AutomationFrame? {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in
            _ = try checkedCurrent(descriptor)
            guard let bytes = try read(descriptor, "mixed-automation.json", maximum: 8192) else { return nil }
            let frame = try decode(AutomationFrame.self, bytes, maximum: 8192)
            guard frame.origin == "screenAutomation", !frame.alertID.isEmpty, frame.alertID.utf8.count <= 128 else { throw Failure.corruptHistory }
            return frame
        }
    }
    struct MountedFrame: Codable, Equatable { let generationID: UUID; let entryID: UUID?; let manifestDigest: String? }
    struct MountFailureFrame: Codable { let generationID: UUID; let entryID: UUID; let code: String }
    func mountedReferenceExact(permit: DeviceLocalResourcePermit) throws -> MountedFrame? {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot else { throw DeviceLocalResourceGateFailure.invalidScope }
        guard let bytes = try read(descriptor, "mixed-mounted.json", maximum: 8192) else { return nil }
        return try decode(MountedFrame.self, bytes, maximum: 8192)
    }
    func retainMountFailureExact(_ current: Capture, entryID: UUID, code: String, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, current.issuer == ObjectIdentifier(self),
            try checkedCurrent(descriptor)?.bytes == current.bytes, current.snapshot.configuredEntryID == entryID,
            ["navigation_failed", "render_process_terminated", "mount_validation_failed"].contains(code) else { throw Failure.staleGeneration }
        try replace(descriptor, "mixed-mount-failure.json", bytes: encode(MountFailureFrame(generationID: current.snapshot.generationID,
            entryID: entryID, code: code), maximum: 8192))
    }
    func mountFailureExact() throws -> MountFailureFrame? {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in
            guard let current = try checkedCurrent(descriptor), let bytes = try read(descriptor, "mixed-mount-failure.json", maximum: 8192) else { return nil }
            let frame = try decode(MountFailureFrame.self, bytes, maximum: 8192)
            guard ["navigation_failed", "render_process_terminated", "mount_validation_failed"].contains(frame.code) else { throw Failure.corruptHistory }
            return frame.generationID == current.snapshot.generationID && frame.entryID == current.snapshot.configuredEntryID ? frame : nil
        }
    }
    func retainMountedEmptyExact(_ current: Capture, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, current.issuer == ObjectIdentifier(self),
            try checkedCurrent(descriptor)?.bytes == current.bytes, current.snapshot.configuredEntryID == nil else { throw Failure.staleGeneration }
        try replace(descriptor, "mixed-mounted.json", bytes: encode(MountedFrame(generationID: current.snapshot.generationID,
            entryID: nil, manifestDigest: nil), maximum: 8192))
        if unlinkat(descriptor, "mixed-mount-failure.json", 0) != 0 && errno != ENOENT { throw Failure.persistence }
        guard fsync(descriptor) == 0 else { throw Failure.persistence }
    }
    func retainMountedExact(_ current: Capture, entryID: UUID, digest: String, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, current.issuer == ObjectIdentifier(self),
            try checkedCurrent(descriptor)?.bytes == current.bytes, current.snapshot.configuredEntryID == entryID,
            digest.utf8.count == 64 else { throw Failure.staleGeneration }
        try replace(descriptor, "mixed-mounted.json", bytes: encode(MountedFrame(generationID: current.snapshot.generationID,
            entryID: entryID, manifestDigest: digest), maximum: 8192))
        if unlinkat(descriptor, "mixed-mount-failure.json", 0) != 0 && errno != ENOENT { throw Failure.persistence }
        guard fsync(descriptor) == 0 else { throw Failure.persistence }
    }
    func mountedCaptureExact() throws -> Capture? {
        guard let frame = try mountedExact() else { return nil }
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in
            _ = try checkedCurrent(descriptor)
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasSuffix(".mixed-intent.json") {
                guard let bytes = try read(descriptor, name, maximum: 384 * 1024) else { throw Failure.corruptHistory }
                let candidate = try decode(Intent.self, bytes, maximum: 384 * 1024).candidate
                let state = try DeviceMixedStructuralStateCodec.decode(candidate)
                if state.generationID == frame.generationID { return Capture(ObjectIdentifier(self), state, candidate) }
            }
            throw Failure.corruptHistory
        }
    }
    func mountedExact() throws -> MountedFrame? {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in try checkedMounted(descriptor) }
    }
    /// Reuses the ordinary mounted-history validator in an already held common
    /// root scope. Scope exit retains its existing physical/context checks.
    func mountedExact(permit: DeviceLocalResourcePermit) throws -> MountedFrame? {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot else { throw DeviceLocalResourceGateFailure.invalidScope }
        return try checkedMounted(descriptor)
    }
    private func checkedMounted(_ descriptor: Int32) throws -> MountedFrame? {
        _ = try checkedCurrent(descriptor)
        guard let bytes = try read(descriptor, "mixed-mounted.json", maximum: 8192) else { return nil }
        let frame = try decode(MountedFrame.self, bytes, maximum: 8192)
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasSuffix(".mixed-intent.json") {
            guard let intentBytes = try read(descriptor, name, maximum: 384 * 1024) else { throw Failure.corruptHistory }
            let state = try DeviceMixedStructuralStateCodec.decode(decode(Intent.self, intentBytes, maximum: 384 * 1024).candidate)
            guard state.generationID == frame.generationID else { continue }
            guard state.configuredEntryID == frame.entryID else { throw Failure.corruptHistory }
            if frame.entryID == nil {
                guard frame.manifestDigest == nil else { throw Failure.corruptHistory }; return frame
            }
            guard let entry = state.entries.first(where: { $0.entryID == frame.entryID }) else { throw Failure.corruptHistory }
            let digest: String
            switch entry { case .retainedLocal(let local): digest = local.entry.revision.digest
            case .cloud(let cloud, _): digest = cloud.package.manifestDigest.text }
            guard frame.manifestDigest == digest else { throw Failure.corruptHistory }; return frame
        }
        throw Failure.corruptHistory
    }
    private struct CloudAcceptedFrame: Codable { let command: Data; let plan: Data; let previous: Data; var nativeOperationID: UUID? = nil; var journalRootID: UUID? = nil }
    func retainCloudAcceptedExact(binding: DeviceNativeDeliveryCommandBinding, previous: Capture, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, previous.issuer == ObjectIdentifier(self),
            try checkedCurrent(descriptor)?.bytes == previous.bytes else { throw Failure.staleGeneration }
        let bytes = try encode(CloudAcceptedFrame(command: binding.commandBytes, plan: binding.planBytes, previous: previous.bytes, nativeOperationID: binding.nativeOperationID, journalRootID: binding.journalRootID), maximum: 256 * 1024)
        let name = binding.association.operationID.uuidString.lowercased() + ".mixed-cloud-accepted.json"
        if let prior = try read(descriptor, name, maximum: 256 * 1024) { guard prior == bytes else { throw Failure.corruptHistory } }
        else { try replace(descriptor, name, bytes: bytes) }
    }
    struct CloudRejection { let binding: DeviceNativeDeliveryCommandBinding; let outcome: Data }
    func retainCloudRejectionExact(binding: DeviceNativeDeliveryCommandBinding, bytes: Data, acknowledgment: Bool,
        permit: DeviceLocalResourcePermit) throws -> Bool {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, bytes.count <= 16384,
            let acceptedBytes = try read(descriptor, binding.association.operationID.uuidString.lowercased() + ".mixed-cloud-accepted.json", maximum: 256 * 1024) else { throw Failure.needsReview }
        let accepted = try decode(CloudAcceptedFrame.self, acceptedBytes, maximum: 256 * 1024)
        guard accepted.command == binding.commandBytes, accepted.plan == binding.planBytes,
            accepted.nativeOperationID == binding.nativeOperationID, accepted.journalRootID == binding.journalRootID else { throw Failure.needsReview }
        let nativePrefix = binding.nativeOperationID.uuidString.lowercased()
        guard try read(descriptor, nativePrefix + ".mixed-intent.json", maximum: 384 * 1024) == nil,
            try read(descriptor, nativePrefix + ".mixed-receipt.json", maximum: 8192) == nil else { return false }
        let prefix = binding.association.operationID.uuidString.lowercased()
        let name = prefix + (acknowledgment ? ".mixed-rejection-ack.json" : ".mixed-rejection-outcome.json")
        if acknowledgment { guard try read(descriptor, prefix + ".mixed-rejection-outcome.json", maximum: 16384) != nil else { throw Failure.needsReview } }
        if let old = try read(descriptor, name, maximum: 16384) { guard old == bytes else { throw Failure.corruptHistory } }
        else { try replace(descriptor, name, bytes: bytes) }
        return true
    }
    func isCloudRejectedExact(operationID: UUID) throws -> Bool {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in
            _ = try checkedCurrent(descriptor)
            return try read(descriptor, operationID.uuidString.lowercased() + ".mixed-rejection-outcome.json", maximum: 16384) != nil
        }
    }
    func pendingCloudRejectionsExact() throws -> [CloudRejection] {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in
            guard let active = try checkedCurrent(descriptor), active.snapshot.detachment == nil,
                active.snapshot.logoutIntent == nil else { return [] }
            var result: [CloudRejection] = []
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasSuffix(".mixed-rejection-outcome.json") {
                let prefix = String(name.prefix(36))
                if try read(descriptor, prefix + ".mixed-rejection-ack.json", maximum: 16384) != nil { continue }
                guard let bytes = try read(descriptor, prefix + ".mixed-cloud-accepted.json", maximum: 256 * 1024),
                    let outcome = try read(descriptor, name, maximum: 16384) else { throw Failure.corruptHistory }
                let frame = try decode(CloudAcceptedFrame.self, bytes, maximum: 256 * 1024)
                guard let operation = frame.nativeOperationID, let journal = frame.journalRootID else { throw Failure.needsReview }
                let state = try DeviceMixedStructuralStateCodec.decode(frame.previous)
                if state.installationOwner != active.snapshot.installationOwner { continue }
                let capture = Capture(ObjectIdentifier(self), state, frame.previous)
                let object = try JSONSerialization.jsonObject(with: frame.command) as? [String: Any]
                let fields: Set<String> = ["schemaVersion", "operationId", "planId", "planDigest", "planByteLength", "installationId", "accountId", "locationId", "transitionId"]
                guard let object else { throw Failure.corruptHistory }
                let header = try JSONSerialization.data(withJSONObject: object.filter { fields.contains($0.key) }, options: [.sortedKeys])
                    .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                let binding = try DeviceNativeDeliveryCommandBinding.bindMixed(command: frame.command, associationHeader: header,
                    rawPlan: frame.plan, nativeOperationID: operation, journalRootID: journal, capture: capture)
                guard binding.association.operationID.uuidString.lowercased() == prefix,
                    try read(descriptor, operation.uuidString.lowercased() + ".mixed-intent.json", maximum: 384 * 1024) == nil else { throw Failure.corruptHistory }
                _ = try DeviceNativeDeliveryHTTPCodec.observe(outcome, kind: .terminalRequest, binding: binding,
                    requestID: nil, expectedOutcome: "not_activated")
                result.append(.init(binding: binding, outcome: outcome))
            }
            return result.sorted { $0.binding.sequence < $1.binding.sequence }
        }
    }
    struct LocalSourceRoot: Codable, Equatable, Sendable { let rootID: UUID; let path: String }
    struct LocalSourceFrame: Codable, Equatable { let operationID: UUID; let candidate: Data; let roots: [LocalSourceRoot] }
    func retainLocalSourceExact(operationID: UUID, candidate: DeviceMixedStructuralState,
        descriptors: [DeviceLocalResourceDescriptor], permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, descriptors.count == 4 else { throw Failure.corruptHistory }
        let frame = LocalSourceFrame(operationID: operationID, candidate: try DeviceMixedStructuralStateCodec.encode(candidate),
            roots: descriptors.map { .init(rootID: $0.rootID, path: $0.path) }.sorted { $0.path < $1.path })
        let bytes = try encode(frame, maximum: 160 * 1024)
        let name = operationID.uuidString.lowercased() + ".mixed-local-source.json"
        if let existing = try read(descriptor, name, maximum: 160 * 1024) { guard bytes == existing else { throw Failure.corruptHistory } }
        else { try replace(descriptor, name, bytes: bytes) }
    }
    func retainedLocalSourcesExact() throws -> [LocalSourceFrame] {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in
            _ = try checkedCurrent(descriptor)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            var result: [LocalSourceFrame] = []
            for name in names where name.hasSuffix(".mixed-local-source.json") {
                guard let bytes = try read(descriptor, name, maximum: 160 * 1024) else { throw Failure.corruptHistory }
                let frame = try decode(LocalSourceFrame.self, bytes, maximum: 160 * 1024)
                guard name == frame.operationID.uuidString.lowercased() + ".mixed-local-source.json", frame.roots.count == 4 else { throw Failure.corruptHistory }
                guard let intentBytes = try read(descriptor, frame.operationID.uuidString.lowercased() + ".mixed-intent.json", maximum: 384 * 1024) else { continue }
                guard try decode(Intent.self, intentBytes, maximum: 384 * 1024).candidate == frame.candidate else { throw Failure.corruptHistory }
                result.append(frame)
            }
            return result
        }
    }
    struct RetainedIncomingFrame {
        let frame: StaticGrantFrame
        let original: Capture
        let grant: StaticGrantReceipt
    }
    /// Returns only incoming graphs whose candidate is a completed historical CAS.
    /// Incomplete preparation remains retained without becoming installed content.
    func retainedIncomingFramesExact() throws -> [RetainedIncomingFrame] {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in
            _ = try checkedCurrent(descriptor)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            var result: [RetainedIncomingFrame] = []
            for name in names where name.hasSuffix(".mixed-static-grant.json") {
                guard let bytes = try read(descriptor, name, maximum: 256 * 1024) else { throw Failure.corruptHistory }
                let frame = try decode(StaticGrantFrame.self, bytes, maximum: 256 * 1024)
                guard name == frame.operationID.uuidString.lowercased() + ".mixed-static-grant.json" else { throw Failure.corruptHistory }
                guard let intentBytes = try read(descriptor, frame.operationID.uuidString.lowercased() + ".mixed-intent.json", maximum: 384 * 1024) else { continue }
                let intent = try decode(Intent.self, intentBytes, maximum: 384 * 1024)
                guard let previous = intent.previous, intent.candidate == frame.candidate,
                    try DeviceMixedStructuralStateCodec.decode(previous).generationID == frame.originalGenerationID else { throw Failure.corruptHistory }
                let prior = Capture(ObjectIdentifier(self), try DeviceMixedStructuralStateCodec.decode(previous), previous)
                result.append(.init(frame: frame, original: prior, grant: .init(ObjectIdentifier(self), operationID: frame.operationID, bytes: bytes)))
            }
            return result
        }
    }
    struct PendingOutcome {
        let operationID: UUID
        let outcome: Data?
        let request: Data
        let authorization: Data
    }
    func pendingIncomingOutcomesExact() throws -> [PendingOutcome] {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in
            guard let active = try checkedCurrent(descriptor), active.snapshot.detachment == nil,
                active.snapshot.logoutIntent == nil else { return [] }
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            var outcomes: [PendingOutcome] = []
            for name in names where name.hasSuffix(".mixed-static-grant.json") {
                guard let id = UUID(uuidString: String(name.prefix(36))) else { throw Failure.corruptHistory }
                let prefix = id.uuidString.lowercased()
                guard let intentBytes = try read(descriptor, prefix + ".mixed-intent.json", maximum: 384 * 1024) else { continue }
                let intent = try decode(Intent.self, intentBytes, maximum: 384 * 1024)
                if try DeviceMixedStructuralStateCodec.decode(intent.candidate).installationOwner != active.snapshot.installationOwner { continue }
                if try read(descriptor, prefix + ".mixed-http-acknowledgment.json", maximum: 16384) != nil || read(descriptor, prefix + ".mixed-http-failedAcknowledgment.json", maximum: 16384) != nil { continue }
                guard let request = try read(descriptor, prefix + ".mixed-http-request.json", maximum: 16384),
                    let authorization = try read(descriptor, prefix + ".mixed-http-authorization.json", maximum: 16384) else { throw Failure.corruptHistory }
                outcomes.append(.init(operationID: id, outcome: try read(descriptor, prefix + ".mixed-http-outcome.json", maximum: 16384),
                    request: request, authorization: authorization))
            }
            return outcomes
        }
    }
    enum HTTPRecordKind: String { case request, authorization, outcome, acknowledgment, failedAcknowledgment }
    func retainIncomingHTTPExact(_ incoming: DeviceMixedIncomingResources, kind: HTTPRecordKind,
        bytes: Data, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, bytes.count <= 16384,
            incoming.command.capture.issuer == ObjectIdentifier(self),
            try read(descriptor, incoming.command.delivery.nativeOperationID.uuidString.lowercased() + ".mixed-static-grant.json", maximum: 256 * 1024) == incoming.grant.bytes else { throw Failure.corruptHistory }
        let name = incoming.command.delivery.nativeOperationID.uuidString.lowercased() + ".mixed-http-" + kind.rawValue + ".json"
        if let prior = try read(descriptor, name, maximum: 16384) {
            guard prior == bytes else { throw Failure.corruptHistory }
        } else { try replace(descriptor, name, bytes: bytes) }
    }
    struct CloudObservation: Codable, Equatable {
        let previousGenerationID: UUID
        let generationID: UUID
        let exactBody: Data
    }
    private func cloudOutboxName(_ descriptor: Int32) throws -> String {
        guard let current = try checkedCurrent(descriptor), current.snapshot.detachment == nil,
            current.snapshot.logoutIntent == nil else { throw Failure.needsReview }
        if let epoch = current.snapshot.cloudObservationEpoch { return "mixed-cloud-observations." + epoch.uuidString.lowercased() + ".json" }
        return "mixed-cloud-observations.json"
    }
    private struct CloudOutbox: Codable { var knownGenerationID: UUID; var pending: [CloudObservation]; var issuedHeadGenerationID: UUID? = nil }
    /// Initial Cloud generation is supplied by an authenticated exact baseline receipt.
    /// Reopening cannot silently reset this durable synchronization checkpoint.
    func initializeCloudObservationCheckpointExact(_ generationID: UUID, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot else { throw DeviceLocalResourceGateFailure.invalidScope }
        if let bytes = try read(descriptor, try cloudOutboxName(descriptor), maximum: 8 * 1024 * 1024) {
            let original = try decode(CloudOutbox.self, bytes, maximum: 8 * 1024 * 1024)
            guard original.knownGenerationID == generationID else { throw Failure.staleGeneration }
            try validateOutbox(original); return
        }
        try replace(descriptor, try cloudOutboxName(descriptor), bytes: encode(CloudOutbox(knownGenerationID: generationID, pending: []), maximum: 8 * 1024 * 1024))
    }
    /// Continues the existing authenticated checkpoint; it never creates or
    /// resets one from a caller-supplied generation.
    func ensureCurrentCloudObservationExact(_ capture: Capture, stateBytes: Data, permit: DeviceLocalResourcePermit) throws {
        try permit.beginRead(ObjectIdentifier(self))
        do {
            defer { permit.endRead() }
            guard let descriptor = borrowedRoot, capture.issuer == ObjectIdentifier(self),
                try checkedCurrent(descriptor)?.bytes == capture.bytes else { throw Failure.staleGeneration }
            let outbox = try readOutbox(descriptor)
            if outbox.knownGenerationID == capture.snapshot.generationID, outbox.pending.isEmpty { return }
        }
        _ = try enqueueCloudObservationExact(capture, stateBytes: stateBytes, permit: permit)
    }
    /// The fixed mixed observation encoder supplies the complete canonical state.
    /// Exact previous generation and body are persisted together before network IO.
    func enqueueCloudObservationExact(_ capture: Capture, stateBytes: Data, permit: DeviceLocalResourcePermit) throws -> CloudObservation {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, capture.issuer == ObjectIdentifier(self),
              try checkedCurrent(descriptor)?.bytes == capture.bytes else { throw Failure.staleGeneration }
        var outbox = try readOutbox(descriptor)
        if let prior = outbox.pending.first(where: { $0.generationID == capture.snapshot.generationID }) {
            guard let object = try JSONSerialization.jsonObject(with: prior.exactBody) as? [String: Any],
                  let state = object["state"], try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) == stateBytes else { throw Failure.corruptHistory }
            return prior
        }
        // Unsent offline states are superseded by the newest durable state. An
        // issued head may have reached the server, so preserve its exact CAS body.
        if outbox.issuedHeadGenerationID == nil { outbox.pending = [] }
        else if outbox.pending.count > 1 { outbox.pending = [outbox.pending[0]] }
        let previous = outbox.pending.last?.generationID ?? outbox.knownGenerationID
        guard previous != capture.snapshot.generationID, outbox.pending.count < 64,
              stateBytes.count <= 128 * 1024,
              let state = try JSONSerialization.jsonObject(with: stateBytes) as? [String: Any],
              state["generationId"] as? String == capture.snapshot.generationID.uuidString.lowercased(),
              state["installationId"] as? String == capture.snapshot.installationOwner.installationID.uuidString.lowercased(),
              state["transitionId"] as? String == capture.snapshot.installationOwner.transitionID.uuidString.lowercased() else { throw Failure.needsReview }
        let body = try JSONSerialization.data(withJSONObject: ["previousGenerationId": previous.uuidString.lowercased(), "state": state], options: [.sortedKeys])
        let pending = CloudObservation(previousGenerationID: previous, generationID: capture.snapshot.generationID, exactBody: body)
        outbox.pending.append(pending); try validateOutbox(outbox)
        try replace(descriptor, try cloudOutboxName(descriptor), bytes: encode(outbox, maximum: 8 * 1024 * 1024))
        return pending
    }
    func verifyPendingCloudObservationHistoryExact(_ original: CloudObservation,
        permit: DeviceLocalResourcePermit) throws -> DeviceMixedStructuralState {
        try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
        guard let descriptor = borrowedRoot, try readOutbox(descriptor).pending.first == original else { throw Failure.staleGeneration }
        _ = try checkedCurrent(descriptor)
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasSuffix(".mixed-intent.json") {
            guard let bytes = try read(descriptor, name, maximum: 384 * 1024) else { throw Failure.corruptHistory }
            let intent = try decode(Intent.self, bytes, maximum: 384 * 1024)
            let candidate = try DeviceMixedStructuralStateCodec.decode(intent.candidate)
            if candidate.generationID == original.generationID {
                guard try read(descriptor, intent.operationID.uuidString.lowercased() + ".mixed-receipt.json", maximum: 8192) != nil else { throw Failure.corruptHistory }
                return candidate
            }
        }
        throw Failure.corruptHistory
    }
    func nextCloudObservationExact() throws -> CloudObservation? {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try withRoot { descriptor in
            try requireBinding(descriptor)
            var outbox = try readOutbox(descriptor)
            guard let head = outbox.pending.first else { return nil }
            if outbox.issuedHeadGenerationID == nil {
                outbox.issuedHeadGenerationID = head.generationID
                try replace(descriptor, try cloudOutboxName(descriptor), bytes: encode(outbox, maximum: 8 * 1024 * 1024))
            }
            return head
        }
    }
    /// Only the fixed authenticated transport owner calls this after exact success.
    /// A delayed response cannot dequeue a later command or regress Cloud generation.
    func acknowledgeCloudObservationExact(_ original: CloudObservation) throws {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        try withRoot { descriptor in
            try requireBinding(descriptor)
            var outbox = try readOutbox(descriptor)
            if outbox.knownGenerationID == original.generationID, outbox.pending.first != original { return }
            guard outbox.pending.first == original, outbox.knownGenerationID == original.previousGenerationID else { throw Failure.staleGeneration }
            outbox.pending.removeFirst(); outbox.knownGenerationID = original.generationID; outbox.issuedHeadGenerationID = nil
            try replace(descriptor, try cloudOutboxName(descriptor), bytes: encode(outbox, maximum: 8 * 1024 * 1024))
        }
    }
    private func readOutbox(_ descriptor: Int32) throws -> CloudOutbox {
        guard let bytes = try read(descriptor, try cloudOutboxName(descriptor), maximum: 8 * 1024 * 1024) else { throw Failure.needsReview }
        let outbox = try decode(CloudOutbox.self, bytes, maximum: 8 * 1024 * 1024)
        try validateOutbox(outbox); return outbox
    }
    private func validateOutbox(_ outbox: CloudOutbox) throws {
        guard outbox.issuedHeadGenerationID == nil || outbox.issuedHeadGenerationID == outbox.pending.first?.generationID else { throw Failure.corruptHistory }
        guard outbox.pending.count <= 64, Set(outbox.pending.map(\.generationID)).count == outbox.pending.count else { throw Failure.corruptHistory }
        var previous = outbox.knownGenerationID
        for pending in outbox.pending {
            guard pending.previousGenerationID == previous, pending.generationID != previous, pending.exactBody.count <= 132 * 1024,
                  let object = try JSONSerialization.jsonObject(with: pending.exactBody) as? [String: Any],
                  Set(object.keys) == ["previousGenerationId", "state"],
                  object["previousGenerationId"] as? String == previous.uuidString.lowercased(),
                  let state = object["state"] as? [String: Any],
                  state["generationId"] as? String == pending.generationID.uuidString.lowercased(),
                  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) == pending.exactBody else { throw Failure.corruptHistory }
            previous = pending.generationID
        }
    }
    private func checkedCurrent(_ descriptor: Int32, allowPending: UUID? = nil) throws -> Capture? {
        try requireBinding(descriptor)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try validateNames(names)
        var intents: [Intent] = []
        for name in names where name.hasSuffix(".mixed-intent.json") {
            guard let bytes = try read(descriptor, name, maximum: 384 * 1024) else { throw Failure.corruptHistory }
            let intent = try decode(Intent.self, bytes, maximum: 384 * 1024)
            guard name == intent.operationID.uuidString.lowercased() + ".mixed-intent.json" else { throw Failure.corruptHistory }
            _ = try DeviceMixedStructuralStateCodec.decode(intent.candidate)
            if let previous = intent.previous { _ = try DeviceMixedStructuralStateCodec.decode(previous) }
            intents.append(intent)
        }
        var tip: Data?, remaining = intents
        while !remaining.isEmpty {
            let next = remaining.filter { $0.previous == tip }
            guard next.count == 1, let intent = next.first, intent.candidate != tip else { throw Failure.corruptHistory }
            let receiptName = intent.operationID.uuidString.lowercased() + ".mixed-receipt.json"
            if let bytes = try read(descriptor, receiptName, maximum: 8192) {
                let state = try DeviceMixedStructuralStateCodec.decode(intent.candidate)
                let receipt = try decode(Receipt.self, bytes, maximum: 8192)
                guard receipt == Receipt(operationID: intent.operationID, generationID: state.generationID,
                    digest: try DeviceNativeDeliveryAttachmentCodec.hash(intent.candidate)) else { throw Failure.corruptHistory }
            } else {
                guard allowPending == intent.operationID, remaining.count == 1 else { throw Failure.needsReview }
                let current = try read(descriptor, "mixed-current.json", maximum: DeviceMixedStructuralStateCodec.maximumBytes)
                guard current == tip || current == intent.candidate else { throw Failure.corruptHistory }
                return try current.map { .init(ObjectIdentifier(self), try DeviceMixedStructuralStateCodec.decode($0), $0) }
            }
            tip = intent.candidate
            remaining.removeAll { $0.operationID == intent.operationID }
        }
        for name in names where name.hasSuffix(".mixed-receipt.json") {
            guard intents.contains(where: { name == $0.operationID.uuidString.lowercased() + ".mixed-receipt.json" }) else { throw Failure.corruptHistory }
        }
        let bytes = try read(descriptor, "mixed-current.json", maximum: DeviceMixedStructuralStateCodec.maximumBytes)
        guard bytes == tip else { throw Failure.corruptHistory }
        return try bytes.map { .init(ObjectIdentifier(self), try DeviceMixedStructuralStateCodec.decode($0), $0) }
    }

    /// Complete only a fully written explicit attachment CAS intent. This never
    /// invents a revoke receipt or changes its recorded predecessor/candidate.
    func recommitPendingCloudAttachmentExact() throws {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        try withRoot { descriptor in
            try requireBinding(descriptor)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path); try validateNames(names)
            var pending: [Intent] = []
            for name in names where name.hasSuffix(".mixed-intent.json") {
                guard let bytes = try read(descriptor, name, maximum: 384 * 1024) else { throw Failure.corruptHistory }
                let intent = try decode(Intent.self, bytes, maximum: 384 * 1024)
                if try read(descriptor, intent.operationID.uuidString.lowercased() + ".mixed-receipt.json", maximum: 8192) == nil { pending.append(intent) }
            }
            guard pending.count <= 1 else { throw Failure.corruptHistory }
            guard let intent = pending.first else { _ = try checkedCurrent(descriptor); return }
            guard let previousBytes = intent.previous else { throw Failure.needsReview }
            let previous = try DeviceMixedStructuralStateCodec.decode(previousBytes)
            let candidate = try DeviceMixedStructuralStateCodec.decode(intent.candidate)
            guard candidate.generationID != previous.generationID else { throw Failure.corruptHistory }
            let sameOwner = candidate.installationOwner == previous.installationOwner
            let sameLocal = candidate.entries == previous.entries.filter({ if case .retainedLocal = $0 { return true }; return false })
            let start = previous.detachment == nil && previous.logoutIntent == nil && candidate.detachment == nil
                && candidate.logoutIntent != nil && sameOwner && candidate.cloudObservationEpoch == previous.cloudObservationEpoch
                && (previous.legacyLocalRoots == nil || candidate.legacyLocalRoots == previous.legacyLocalRoots) && candidate.entries == previous.entries && candidate.configuredEntryID == previous.configuredEntryID
            let detach = previous.logoutIntent.map { accepted in
                candidate.logoutIntent == nil && candidate.detachment?.retirementMetadata == accepted.retirementMetadata
                    && candidate.detachment != nil && intent.operationID == accepted.detachOperationID
                    && candidate.generationID == accepted.detachGenerationID && sameOwner && sameLocal
                    && candidate.legacyLocalRoots == previous.legacyLocalRoots && candidate.cloudObservationEpoch == previous.cloudObservationEpoch
            } ?? false
            let cleanup = previous.detachment.map { old in
                candidate.detachment.map { next in
                    !old.cleanupCompleted && next.cleanupCompleted && next.retirementMetadata == old.retirementMetadata
                        && next.revokedAt == old.revokedAt && sameOwner && candidate.entries == previous.entries
                        && candidate.configuredEntryID == previous.configuredEntryID && candidate.legacyLocalRoots == previous.legacyLocalRoots
                        && candidate.cloudObservationEpoch == previous.cloudObservationEpoch && candidate.logoutIntent == nil
                } ?? false
            } ?? false
            let attach = previous.detachment?.cleanupCompleted == true && candidate.detachment == nil && candidate.logoutIntent == nil
                && !sameOwner && candidate.installationOwner.installationID != previous.installationOwner.installationID
                && candidate.cloudObservationEpoch == candidate.installationOwner.installationID && candidate.legacyLocalRoots == previous.legacyLocalRoots
                && candidate.entries == previous.entries && candidate.configuredEntryID == previous.configuredEntryID
            guard start || detach || cleanup || attach else { throw Failure.needsReview }
            let current = try checkedCurrent(descriptor, allowPending: intent.operationID)
            guard current?.bytes == previousBytes || current?.bytes == intent.candidate else { throw Failure.corruptHistory }
            if current?.bytes != intent.candidate { try replace(descriptor, "mixed-current.json", bytes: intent.candidate) }
            let receipt = Receipt(operationID: intent.operationID, generationID: candidate.generationID,
                digest: try DeviceNativeDeliveryAttachmentCodec.hash(intent.candidate))
            try replace(descriptor, intent.operationID.uuidString.lowercased() + ".mixed-receipt.json", bytes: encode(receipt, maximum: 8192))
            guard try checkedCurrent(descriptor)?.bytes == intent.candidate else { throw Failure.persistence }
        }
    }
    private func validateNames(_ names: [String]) throws {
        guard names.count <= 2308 else { throw Failure.corruptHistory }
        for name in names {
            if ["mixed.lock", "mixed-root.json", "mixed-current.json", "mixed-cloud-observations.json", "mixed-mounted.json", "mixed-mount-failure.json", "mixed-automation.json"].contains(name) { continue }
            let epochPrefix = "mixed-cloud-observations."
            if name.hasPrefix(epochPrefix), name.hasSuffix(".json") {
                let raw = String(name.dropFirst(epochPrefix.count).dropLast(5))
                guard let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw else { throw Failure.corruptHistory }
                continue
            }
            let suffix: String
            if name.hasSuffix(".mixed-intent.json") { suffix = ".mixed-intent.json" }
            else if name.hasSuffix(".mixed-receipt.json") { suffix = ".mixed-receipt.json" }
            else if name.hasSuffix(".mixed-static-grant.json") { suffix = ".mixed-static-grant.json" }
            else if name.hasSuffix(".mixed-local-source.json") { suffix = ".mixed-local-source.json" }
            else if name.hasSuffix(".mixed-cloud-accepted.json") { suffix = ".mixed-cloud-accepted.json" }
            else if name.hasSuffix(".mixed-rejection-outcome.json") { suffix = ".mixed-rejection-outcome.json" }
            else if name.hasSuffix(".mixed-rejection-ack.json") { suffix = ".mixed-rejection-ack.json" }
            else if name.hasSuffix(".mixed-http-request.json") { suffix = ".mixed-http-request.json" }
            else if name.hasSuffix(".mixed-http-authorization.json") { suffix = ".mixed-http-authorization.json" }
            else if name.hasSuffix(".mixed-http-outcome.json") { suffix = ".mixed-http-outcome.json" }
            else if name.hasSuffix(".mixed-http-acknowledgment.json") { suffix = ".mixed-http-acknowledgment.json" }
            else if name.hasSuffix(".mixed-http-failedAcknowledgment.json") { suffix = ".mixed-http-failedAcknowledgment.json" }
            else { throw Failure.corruptHistory }
            guard name.count == 36 + suffix.count, UUID(uuidString: String(name.prefix(36))) != nil else { throw Failure.corruptHistory }
        }
    }
    private func requireBinding(_ descriptor: Int32) throws {
        guard let bytes = try read(descriptor, "mixed-root.json", maximum: 8192) else { throw Failure.unsafeRoot }
        try requireBindingBytes(bytes, descriptor: descriptor)
    }
    private func requireBindingBytes(_ bytes: Data, descriptor: Int32, recordedPath: String? = nil) throws {
        if let originalBindingBytes { guard bytes == originalBindingBytes else { throw Failure.unsafeRoot } }
        // Retain the exact historical bytes and decoded identities. Current raw
        // descriptor identities are separate, never substituted into this proof.
        guard try bindingMatches(decode(Binding.self, bytes, maximum: 8192),
            binding(descriptor, recordedPath: recordedPath)) else { throw Failure.unsafeRoot }
        originalBindingBytes = bytes
    }
    static func recordedRoots(_ recorded: [LocalSourceRoot], matchCurrent current: [LocalSourceRoot]) -> Bool {
        recorded.count == current.count && zip(recorded, current).allSatisfy {
            $0.rootID == $1.rootID && DeviceFilesystemTraversal.recordedPath($0.path, matchesCurrentPath: $1.path)
        }
    }
    private func bindingMatches(_ recorded: Binding, _ current: Binding) -> Bool {
        guard let context = activeFilesystemContext else { return false }
        let sameBindingMount = recorded.device == recorded.lockDevice ||
            (recorded.device == current.device && recorded.lockDevice == current.lockDevice)
        return recorded.rootID == current.rootID && sameBindingMount &&
            context.matchesDurableIdentity(recordedDevice: recorded.device, recordedInode: recorded.inode,
                observedDevice: current.device, observedInode: current.inode) &&
            context.matchesDurableIdentity(recordedDevice: recorded.lockDevice, recordedInode: recorded.lockInode,
                observedDevice: current.lockDevice, observedInode: current.lockInode) &&
            context.matchesRecordedRootPath(recorded.path)
    }
    private func binding(_ descriptor: Int32, recordedPath: String? = nil) throws -> Binding {
        var value = stat(); guard fstat(descriptor, &value) == 0 else { throw Failure.unsafeRoot }
        var lock = stat()
        guard fstatat(descriptor, "mixed.lock", &lock, AT_SYMLINK_NOFOLLOW) == 0,
              lock.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeRoot }
        return .init(rootID: rootID, path: recordedPath ?? root.path, device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino),
            lockDevice: UInt64(truncatingIfNeeded: lock.st_dev), lockInode: UInt64(lock.st_ino))
    }
    private func withRoot<T>(plannedPublicationRoot: URL? = nil, _ body: (Int32) throws -> T) throws -> T {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unsafeRoot }; defer { close(descriptor) }
        var original = stat(), named = stat()
        guard fstat(descriptor, &original) == 0, lstat(root.path, &named) == 0,
              named.st_mode & S_IFMT == S_IFDIR, original.st_dev == named.st_dev, original.st_ino == named.st_ino else { throw Failure.unsafeRoot }
        let lock = openat(descriptor, "mixed.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Failure.unsafeRoot }; defer { close(lock) }
        var lockStat = stat(), namedLock = stat()
        guard fstat(lock, &lockStat) == 0, lockStat.st_mode & S_IFMT == S_IFREG,
              fstatat(descriptor, "mixed.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_dev == lockStat.st_dev, namedLock.st_ino == lockStat.st_ino else { throw Failure.unsafeRoot }
        guard flock(lock, LOCK_EX) == 0 else { throw Failure.persistence }; defer { flock(lock, LOCK_UN) }
        let context: DevicePersistedFilesystemContext
        do { context = try filesystemContextFactory(root, descriptor, plannedPublicationRoot) }
        catch { throw Failure.unsafeRoot }
        guard context.acceptsCurrentDevice(UInt64(truncatingIfNeeded: original.st_dev)),
            context.acceptsCurrentDevice(UInt64(truncatingIfNeeded: lockStat.st_dev)) else { throw Failure.unsafeRoot }
        let previousContext = activeFilesystemContext, previousBindingBytes = originalBindingBytes
        activeFilesystemContext = context; originalBindingBytes = nil
        defer { activeFilesystemContext = previousContext; originalBindingBytes = previousBindingBytes }
        let result = try body(descriptor)
        if let originalBindingBytes {
            guard try read(descriptor, "mixed-root.json", maximum: 8192) == originalBindingBytes else { throw Failure.unsafeRoot }
        }
        guard fstatat(descriptor, "mixed.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_mode & S_IFMT == S_IFREG, namedLock.st_dev == lockStat.st_dev,
              namedLock.st_ino == lockStat.st_ino else { throw Failure.unsafeRoot }
        guard lstat(root.path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
              original.st_dev == named.st_dev, original.st_ino == named.st_ino else { throw Failure.unsafeRoot }
        return result
    }
    private func read(_ parent: Int32, _ name: String, maximum: Int) throws -> Data? {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 { if errno == ENOENT { return nil }; throw Failure.persistence }; defer { close(descriptor) }
        var value = stat(); guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_size >= 0, value.st_size <= maximum else { throw Failure.corruptHistory }
        guard activeFilesystemContext?.acceptsCurrentDevice(UInt64(truncatingIfNeeded: value.st_dev)) == true else { throw Failure.unsafeRoot }
        var result = Data(count: Int(value.st_size))
        let count = result.withUnsafeMutableBytes { pointer in
            #if canImport(Darwin)
            Darwin.read(descriptor, pointer.baseAddress, pointer.count)
            #else
            Glibc.read(descriptor, pointer.baseAddress, pointer.count)
            #endif
        }
        var after = stat(), named = stat()
        guard count == result.count, fstat(descriptor, &after) == 0,
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_size == value.st_size, named.st_mode & S_IFMT == S_IFREG,
              named.st_dev == value.st_dev, named.st_ino == value.st_ino else { throw Failure.persistence }; return result
    }
    private func replace(_ parent: Int32, _ name: String, bytes: Data) throws {
        let temp = name + ".stage-" + UUID().uuidString.lowercased()
        let descriptor = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.persistence }
        defer { close(descriptor); unlinkat(parent, temp, 0) }
        var created = stat()
        guard fstat(descriptor, &created) == 0, created.st_mode & S_IFMT == S_IFREG,
            activeFilesystemContext?.acceptsCurrentDevice(UInt64(truncatingIfNeeded: created.st_dev)) == true else { throw Failure.unsafeRoot }
        let count = bytes.withUnsafeBytes { pointer in
            #if canImport(Darwin)
            Darwin.write(descriptor, pointer.baseAddress, pointer.count)
            #else
            Glibc.write(descriptor, pointer.baseAddress, pointer.count)
            #endif
        }
        guard count == bytes.count, fsync(descriptor) == 0,
              renameat(parent, temp, parent, name) == 0, fsync(parent) == 0 else { throw Failure.persistence }
    }
    private func encode<T: Encodable>(_ value: T, maximum: Int) throws -> Data { try DeviceLocalCompleteSetBounds.encode(value, maximum: maximum) }
    private func decode<T: Codable>(_ type: T.Type, _ bytes: Data, maximum: Int) throws -> T {
        let value = try JSONDecoder().decode(type, from: bytes)
        guard try encode(value, maximum: maximum) == bytes else { throw Failure.corruptHistory }; return value
    }
}
