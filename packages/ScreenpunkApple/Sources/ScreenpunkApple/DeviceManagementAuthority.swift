import Foundation
import Darwin
import Security
import CryptoKit
@_spi(ManagementMigration) @_spi(NativeInstallation) import ScreenpunkCore

/// In-process authority only. External filesystem/Keychain writers are not excluded.
/// Only internal Local reset bookkeeping writes are provided. Production Cloud writers remain
/// disabled until owner-mediated exact uncertain-write recovery is implemented.
/// All future management callers must share this owner and acquire it before their
/// server lock. Do not wait for asynchronous callbacks from a gated operation.
public final class DeviceManagementAuthority: @unchecked Sendable {
    public struct Lease: Sendable {
        fileprivate let owner: UUID
        fileprivate let generation: UUID
    }
    public enum Failure: Error, Equatable {
        case staleLease, reentrantOperation, resetConflict, noResetAttempt
    }
    private let lock = NSRecursiveLock()
    private let commandIntents: DeviceCommandIntentCoordinator?
    private let concurrentControlQualified: Bool
    private let identity = UUID()
    private var generation = UUID()
    private struct Evidence: Equatable {
        let history: DeviceManagementEvidence?
        let references: Set<String>
        let inventory: [String: CloudInstallationCredentialFormat]
        let reset: DeviceLocalResetRecord?
    }
    private var quarantined = false
    private var observedHistory: DeviceManagementEvidence?
    private var evidence: Evidence?
    private var permitted = false
    private var executing = false
    private var invalidationObservers: [UUID: () -> Void] = [:]
    private var unifiedInvalidationObservers: [UUID: () -> Void] = [:]
    private var invalidationActions: [() -> Void] = []
    private let reset: any DeviceLocalResetEvidence
    private struct ResetAttempt { let record: DeviceLocalResetRecord; let beginsNew: Bool }
    private var resetAttempt: ResetAttempt?
    private var resetQuarantined = false
    private var observedReset: DeviceLocalResetRecord?
    private struct OwnedResetBinding {
        let manifest: DeviceFactoryResetManifest
        let scope: DeviceLocalResetCleanupScope
        let previousRecord: DeviceLocalResetRecord?
        let origin: CloudInstallationContext?
        let withOriginal: (((() throws -> Void)) throws -> Void)?
    }
    private var factoryResetResourceContext: CloudInstallationContext?
    private var ownedReset: OwnedResetBinding?
    @MainActor private var factoryResetPreparation: DeviceOwnedFactoryResetPreparation?
    private let journal: any CloudInstallationTransitionJournal
    private let credentials: CloudInstallationCredentialStore
    private let managedNamespace: DeviceManagedNamespaceInspector
    private let supportAnchorSetup: DeviceProductionSupportAnchorSetup
    private var supportAnchorPending = false
    private var observedNamespace: DeviceManagedNamespaceEvidence?
    private var managedNamespaceQuarantined = false
    private let cloudProcess = UUID()
    private var cloudGeneration = UUID()
    private var cloudForeground = false
    private var cloudInstallation: CloudInstallationContext?
    private var cloudRequestID: UUID?
    private var cloudAcceptedStartedAt: TimeInterval?
    private var cloudAcceptedObservation: NativeOperationalStatusObservation?
    private var cloudRequestStartedAt: TimeInterval?
    private var freshCloudRoots: FreshCloudEnrollmentRoots?
    private var freshOperationalReader: FreshEnrollmentStepOwner?
    private var unifiedRoot: (context: CloudInstallationContext, root: UnifiedRootReservation)?
    private var cloudClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @_spi(NativeInstallation) public final class CloudInstallationContext: @unchecked Sendable {
        fileprivate let owner: UUID, process: UUID, generation: UUID
        fileprivate let installation: NativeOperationalInstallation, activation: NativeActivationReceipt, origin: URL
        fileprivate let resetBaseline: DeviceLocalResetRecord?
        fileprivate init(owner: UUID, process: UUID, generation: UUID, installation: NativeOperationalInstallation,
            activation: NativeActivationReceipt, origin: URL, resetBaseline: DeviceLocalResetRecord?) {
            self.owner = owner; self.process = process; self.generation = generation; self.installation = installation
            self.activation = activation; self.origin = origin; self.resetBaseline = resetBaseline
        }
    }

    public init(journal: any CloudInstallationTransitionJournal, credentials: CloudInstallationCredentialStore, reset: any DeviceLocalResetEvidence = DeviceLocalResetEvidenceAdapter.production(), managedNamespace: DeviceManagedNamespaceInspector = .production(), supportAnchorSetup: DeviceProductionSupportAnchorSetup = .production(), commandIntents: DeviceCommandIntentCoordinator? = nil, concurrentControlQualified: Bool = false) {
        self.commandIntents = commandIntents
        self.concurrentControlQualified = concurrentControlQualified
        self.journal = journal
        self.credentials = credentials
        self.reset = reset
        self.managedNamespace = managedNamespace
        self.supportAnchorSetup = supportAnchorSetup
    }

    @_spi(NativeInstallation) public final class DetachedLocalContext: @unchecked Sendable {
        public let commonRoot: URL, commonRootID: UUID, retiredInstallationID: UUID
        fileprivate let root: UnifiedRootReservation
        fileprivate let resetBaseline: DeviceLocalResetRecord?
        fileprivate let owner: UUID
        fileprivate var active = false
        fileprivate init(root: UnifiedRootReservation, owner: UUID, retiredInstallationID: UUID,
            resetBaseline: DeviceLocalResetRecord?) {
            self.root = root; self.owner = owner; self.retiredInstallationID = retiredInstallationID
            self.resetBaseline = resetBaseline; commonRoot = root.root; commonRootID = root.rootID
        }
    }
    private var detachedCandidate: DetachedLocalContext?
    private var detachedLocal: DetachedLocalContext?
    /// Called before the explicit mixed detach; an inactive candidate grants no LAN authority.
    @_spi(NativeInstallation) public func prepareCloudDetachment(context: CloudInstallationContext,
        session: DeviceUnifiedInventorySession) throws -> DetachedLocalContext {
        let association = try session.validatedAssociation()
        return try serialized {
            try checkCloud(context)
            guard concurrentControlQualified, let original = unifiedRoot, original.context === context,
                original.root.rootID == association.commonRootID,
                association.installationID == context.activation.installationId else { throw Failure.staleLease }
            try original.root.validate()
            let candidate = DetachedLocalContext(root: original.root, owner: identity,
                retiredInstallationID: context.activation.installationId, resetBaseline: try cloudResetAllowed())
            detachedCandidate = candidate
            return candidate
        }
    }
    /// The caller only discovered metadata. Source and detached-CAS validation must
    /// finish in Core before acceptDetachedLocalSession can grant a Local context.
    @_spi(NativeInstallation) public func prepareDetachedLocalRestore(commonRootID: UUID,
        retiredInstallationID: UUID) throws -> DetachedLocalContext {
        try serialized {
            try supportAnchorSetup.validateForInspection()
            let root = try physicalInventoryParent(managedNamespace.inspect().namespaceURL.deletingLastPathComponent())
                .appendingPathComponent("xyz.screenpunk.unified-inventory", isDirectory: true)
            let anchor = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard anchor >= 0 else { throw Failure.staleLease }
            let descriptor = openat(anchor, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { close(anchor); throw Failure.staleLease }
            var parentInfo = stat(), info = stat()
            guard fstat(anchor, &parentInfo) == 0, fstat(descriptor, &info) == 0 else {
                close(descriptor); close(anchor); throw Failure.staleLease
            }
            let reservation = UnifiedRootReservation(root: root, rootID: commonRootID, anchor: anchor,
                descriptor: descriptor, anchorIdentity: parentInfo, identity: info)
            try reservation.validate()
            let candidate = DetachedLocalContext(root: reservation, owner: identity,
                retiredInstallationID: retiredInstallationID, resetBaseline: try cloudResetAllowed())
            detachedCandidate = candidate
            return candidate
        }
    }
    @_spi(NativeInstallation) public func validateDetachedLocalResources(_ context: DetachedLocalContext) throws {
        try serialized { try checkDetachedLocal(context, requireActive: false) }
    }
    private func checkDetachedLocal(_ context: DetachedLocalContext, requireActive: Bool) throws {
        guard context.owner == identity, detachedCandidate === context || detachedLocal === context,
            !requireActive || (detachedLocal === context && context.active),
            try cloudResetAllowed() == context.resetBaseline else { throw Failure.staleLease }
        try context.root.validate()
    }
    @_spi(NativeInstallation) public func acceptDetachedLocalSession(_ session: DeviceUnifiedInventorySession,
        context: DetachedLocalContext) throws -> DeviceManagementContext {
        let association = try session.detachedAssociation()
        try association.validateCurrent()
        return try serialized {
            try checkDetachedLocal(context, requireActive: false)
            guard association.metadata.commonRootID == context.commonRootID,
                association.metadata.retiredInstallationID == context.retiredInstallationID else { throw Failure.staleLease }
            invalidateCloud()
            unifiedRoot = nil; detachedLocal = context; detachedCandidate = nil; context.active = true
            return DeviceManagementContext(authority: self, detached: context)
        }
    }
    fileprivate func withDetachedLocalAuthority<T>(_ context: DetachedLocalContext, operation: () throws -> T) throws -> T {
        try serialized {
            try checkDetachedLocal(context, requireActive: true)
            let value = try operation()
            try checkDetachedLocal(context, requireActive: true)
            return value
        }
    }
    private func liveUnifiedLocalRoot() throws -> (root: UnifiedRootReservation, installationID: UUID) {
        if let detachedLocal {
            try checkDetachedLocal(detachedLocal, requireActive: true)
            return (detachedLocal.root, detachedLocal.retiredInstallationID)
        }
        guard let original = unifiedRoot else { throw Failure.staleLease }
        try checkUnifiedLocalRoot(original)
        return (original.root, original.context.activation.installationId)
    }
    fileprivate func observeDetachedInvalidation(_ context: DetachedLocalContext,
        action: @escaping () -> Void) throws -> UUID {
        try serialized {
            try checkDetachedLocal(context, requireActive: true)
            let id = UUID(); unifiedInvalidationObservers[id] = action; return id
        }
    }
    @_spi(NativeInstallation) public func retireDetachedLocalContext(_ context: DetachedLocalContext) throws {
        try serialized {
            try checkDetachedLocal(context, requireActive: true)
            context.active = false; detachedLocal = nil; detachedCandidate = nil
            invalidationActions.append(contentsOf: unifiedInvalidationObservers.values)
            unifiedInvalidationObservers.removeAll()
        }
    }
    /// Explicit logout cleanup must have made the original Cloud namespace truly
    /// absent. No ordinary fresh-enrollment absence/ownership fence is relaxed.
    @_spi(NativeInstallation) public func prepareCloudEnrollmentAfterDetach(context: DetachedLocalContext,
        association: DeviceDetachedLocalInventoryAssociation, claim: NativeClaimInput,
        cloudRootID: UUID, localIDs: NativeManagedLocalRootIDs) throws -> FreshCloudEnrollmentRoots {
        try association.validateCurrent()
        try serialized {
            try checkDetachedLocal(context, requireActive: true)
            guard association.metadata.commonRootID == context.commonRootID,
                association.metadata.retiredInstallationID == context.retiredInstallationID, association.metadata.cleanupCompleted else { throw Failure.staleLease }
            if freshCloudRoots?.claim != claim { freshCloudRoots = nil }
        }
        if try managedNamespace.inspect().classification == .managedPresent {
            // A retry may reopen only the caller's same persisted new request;
            // Core still proves all IDs/journal/Keychain ownership before use.
            return try restoreRecordedCloudEnrollmentRoots(claim: claim, cloudRootID: cloudRootID, localIDs: localIDs)
        }
        return try prepareFreshCloudRoots(claim: claim, recordedCloudRootID: cloudRootID,
            recordedLocalIDs: localIDs, afterDetached: true)
    }
    @_spi(NativeInstallation) public func reattachCloudInventory(detached: DeviceUnifiedInventorySession,
        detachedContext: DetachedLocalContext, context: CloudInstallationContext,
        native: NativeDeliveryExecutionSession, current: NativeCurrentInstallationDispatch,
        operationID: UUID, generationID: UUID) throws -> DeviceUnifiedInventorySession {
        let prior = try detached.detachedAssociation()
        try prior.validateCurrent()
        let root = try serialized { () throws -> UnifiedRootReservation in
            try checkDetachedLocal(detachedContext, requireActive: true); try checkCloud(context)
            guard prior.metadata.cleanupCompleted, prior.metadata.commonRootID == detachedContext.commonRootID,
                prior.metadata.retiredInstallationID == detachedContext.retiredInstallationID else { throw Failure.staleLease }
            return detachedContext.root
        }
        // Core validates before and after its attachment CAS. Before that CAS
        // the exact retained root still belongs to the sealed detached context;
        // it cannot already be registered as the new attached owner. Once the
        // handoff below registers it, every later check uses normal admission.
        let validateAttachment: () throws -> Void = { [self] in
            try serialized {
                try checkCloud(context); try root.validate()
                if let attached = unifiedRoot {
                    guard attached.context === context, attached.root === root else { throw Failure.staleLease }
                    try checkUnifiedLocalRoot(attached)
                } else {
                    try checkDetachedLocal(detachedContext, requireActive: true)
                    guard detachedContext.root === root else { throw Failure.staleLease }
                }
            }
        }
        let session = try detached.reattachCloud(native: native, current: current,
            operationID: operationID, generationID: generationID,
            validateAttached: validateAttachment,
            validateMutation: { [self] in
                try validateAttachment()
                try serialized { try checkCloud(context); try root.validate(); guard concurrentControlQualified else { throw Failure.staleLease } }
            }, automationOwner: { [self] base in try makeAutomaticSelectionOwner(context: context, commonRootID: root.rootID, baseGenerationID: base) })
        try serialized {
            try checkCloud(context); try root.validate()
            unifiedRoot = (context, root)
            detachedContext.active = false; detachedLocal = nil; detachedCandidate = nil
            invalidationActions.append(contentsOf: unifiedInvalidationObservers.values)
            unifiedInvalidationObservers.removeAll()
        }
        return session
    }
    /// Original first-native directory ownership. No server IDs or management
    /// permission are manufactured by this local initialization reservation.
    @_spi(NativeInstallation) public final class FreshCloudEnrollmentRoots {
        public let namespace: URL, journalRoot: URL, cloudRootID: UUID
        public let localIDs: NativeManagedLocalRootIDs
        fileprivate let owner: UUID, process: UUID, generation: UUID, claim: NativeClaimInput
        fileprivate let originalAbsence: DeviceManagedNamespaceEvidence
        fileprivate let resetBaseline: DeviceLocalResetRecord?
        fileprivate var present: DeviceManagedNamespaceEvidence?
        fileprivate var ready = false, uncertainCreation = false
        fileprivate var anchor: Int32 = -1
        fileprivate struct Node {
            let name: String, parent: Int32, descriptor: Int32, device: dev_t, inode: ino_t
        }
        fileprivate var nodes: [Node] = []
        fileprivate init(owner: UUID, process: UUID, generation: UUID, claim: NativeClaimInput,
            absence: DeviceManagedNamespaceEvidence, reset: DeviceLocalResetRecord?, recordedCloudRootID: UUID? = nil,
            recordedLocalIDs: NativeManagedLocalRootIDs? = nil) throws {
            self.owner = owner; self.process = process; self.generation = generation; self.claim = claim
            originalAbsence = absence; resetBaseline = reset; namespace = absence.namespaceURL
            journalRoot = namespace.appendingPathComponent("enrollment", isDirectory: true); cloudRootID = recordedCloudRootID ?? UUID()
            localIDs = try recordedLocalIDs ?? .init(package: UUID(), grant: UUID(), structural: UUID(), provisioning: UUID(), contentGenesis: UUID())
        }
        deinit { for node in nodes.reversed() { close(node.descriptor) }; if anchor >= 0 { close(anchor) } }
    }
    /// Explicit user enrollment intent only. Missing/error history is never converted
    /// into an empty history. Any existing managed namespace is refused, not adopted.
    @_spi(NativeInstallation) public func prepareFreshCloudEnrollmentRoots(claim: NativeClaimInput, recordedCloudRootID: UUID? = nil,
        recordedLocalIDs: NativeManagedLocalRootIDs? = nil) throws -> FreshCloudEnrollmentRoots {
        try prepareFreshCloudRoots(claim: claim, recordedCloudRootID: recordedCloudRootID,
            recordedLocalIDs: recordedLocalIDs, afterDetached: false)
    }
    private func prepareFreshCloudRoots(claim: NativeClaimInput, recordedCloudRootID: UUID?,
        recordedLocalIDs: NativeManagedLocalRootIDs?, afterDetached: Bool) throws -> FreshCloudEnrollmentRoots {
        try serialized {
            if let original = freshCloudRoots {
                guard original.claim == claim else { throw Failure.staleLease }
                try checkFreshCloudRoots(original, requireReady: false)
                try createFreshCloudRoots(original); return original
            }
            guard cloudForeground, (!managedNamespaceQuarantined || afterDetached), !quarantined, observedHistory == nil,
                try journal.loadEvidence() == nil, try credentials.references().isEmpty else { throw Failure.staleLease }
            let resetBaseline = try cloudResetAllowed()
            try supportAnchorSetup.validateForInspection()
            let absence = try managedNamespace.inspect()
            guard absence.classification == .confirmedAbsent, afterDetached || observedNamespace == nil || observedNamespace == absence else { throw Failure.staleLease }
            // Revoke Local before any creation. Failed initialization stays retained
            // on this SAME owner; namespace presence never reopens Local permission.
            invalidate(); managedNamespaceQuarantined = true
            let original = try FreshCloudEnrollmentRoots(owner: identity, process: cloudProcess, generation: cloudGeneration,
                claim: claim, absence: absence, reset: resetBaseline,
                recordedCloudRootID: recordedCloudRootID, recordedLocalIDs: recordedLocalIDs)
            freshCloudRoots = original
            try createFreshCloudRoots(original); return original
        }
    }
    /// Pin an existing namespace for qualified recorded-installation recovery.
    /// This only reserves an owner; the Core session must independently replay
    /// the journal and compare current Keychain material before it can bind.
    @_spi(NativeInstallation) public func restoreRecordedCloudEnrollmentRoots(claim: NativeClaimInput,
        cloudRootID: UUID, localIDs: NativeManagedLocalRootIDs) throws -> FreshCloudEnrollmentRoots {
        try restoreRecordedCloudRoots(claim: claim, cloudRootID: cloudRootID, localIDs: localIDs, inspector: managedNamespace)
    }
    private func restoreRecordedCloudRoots(claim: NativeClaimInput, cloudRootID: UUID,
        localIDs: NativeManagedLocalRootIDs, inspector: DeviceManagedNamespaceInspector) throws -> FreshCloudEnrollmentRoots {
        try serialized {
            guard cloudForeground else { throw Failure.staleLease }
            if let original = freshCloudRoots, original.generation == cloudGeneration {
                guard original.originalAbsence.classification == .managedPresent,
                    original.claim == claim, original.cloudRootID == cloudRootID,
                    original.localIDs.package == localIDs.package, original.localIDs.grant == localIDs.grant,
                    original.localIDs.structural == localIDs.structural, original.localIDs.provisioning == localIDs.provisioning,
                    original.localIDs.contentGenesis == localIDs.contentGenesis else { throw Failure.staleLease }
                // An earlier restore may fail before its session is retained. Retry
                // only this exact reservation; Core must still replay all durable
                // journal/credential evidence before operational binding.
                try checkFreshCloudRoots(original, requireReady: true)
                return original
            }
            freshCloudRoots = nil
            let baseline = try cloudResetAllowed()
            try supportAnchorSetup.validateForInspection()
            let present = try inspector.inspect()
            guard present.classification == .managedPresent else { throw Failure.staleLease }
            invalidate(); managedNamespaceQuarantined = true
            let original = try FreshCloudEnrollmentRoots(owner: identity, process: cloudProcess,
                generation: cloudGeneration, claim: claim, absence: present, reset: baseline,
                recordedCloudRootID: cloudRootID, recordedLocalIDs: localIDs)
            original.present = present
            original.anchor = open(original.namespace.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard original.anchor >= 0 else { throw Failure.staleLease }
            func pin(_ name: String, parent: Int32) throws -> Int32 {
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Failure.staleLease }
                var opened = stat(), named = stat()
                guard fstat(fd, &opened) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                    named.st_mode & S_IFMT == S_IFDIR, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                    close(fd); throw Failure.staleLease
                }
                original.nodes.append(.init(name: name, parent: parent, descriptor: fd,
                    device: opened.st_dev, inode: opened.st_ino))
                return fd
            }
            let namespaceFD = try pin(DeviceNativeManagedRootLocator.namespaceName, parent: original.anchor)
            for name in DeviceNativeManagedRootLocator.futureChildNames + ["enrollment"] { _ = try pin(name, parent: namespaceFD) }
            guard try inspector.inspect() == present else { throw Failure.staleLease }
            freshCloudRoots = original; original.ready = true
            try checkFreshCloudRoots(original, requireReady: true)
            return original
        }
    }
    /// Fixed original owner factory. The caller cannot substitute a validator,
    /// Local lease, or detached namespace classification for this SAME owner.
    @_spi(NativeInstallation) public func makeFirstEnrollmentSession(roots: FreshCloudEnrollmentRoots,
        proposal: NativeFirstEnrollmentPreparation, excludedLocalResetRoot: URL,
        storage: any NativeEnrollmentCredentialStorage) throws -> NativeFirstEnrollmentSession {
        try validateFreshCloudEnrollmentRoots(roots)
        guard roots.claim == proposal.claimInput else { throw Failure.staleLease }
        let owner = FreshEnrollmentStepOwner(authority: self, roots: roots)
        let session = try NativeFirstEnrollmentSession(namespace: roots.namespace, journalRoot: roots.journalRoot,
            cloudRootID: roots.cloudRootID, excludedLocalResetRoot: excludedLocalResetRoot,
            proposal: proposal, storage: storage, owner: owner)
        try validateFreshCloudEnrollmentRoots(roots)
        try serialized { freshOperationalReader = owner }; return session
    }
    @_spi(NativeInstallation) public func validateFreshCloudEnrollmentRoots(_ original: FreshCloudEnrollmentRoots) throws {
        try serialized { try checkFreshCloudRoots(original, requireReady: true) }
    }
    private func checkFreshCloudRoots(_ original: FreshCloudEnrollmentRoots, requireReady: Bool) throws {
        guard freshCloudRoots === original, cloudForeground, original.owner == identity,
            original.process == cloudProcess, original.generation == cloudGeneration,
            !original.uncertainCreation, !requireReady || original.ready else { throw Failure.staleLease }
        guard try cloudResetAllowed() == original.resetBaseline else { invalidateCloud(); throw Failure.staleLease }
        let current = try managedNamespace.inspect()
        guard current.hasSameCheckedAnchor(as: original.originalAbsence),
            original.present.map({ $0 == current }) ?? (current.classification == .confirmedAbsent) else { throw Failure.staleLease }
        if original.anchor >= 0 {
            var opened = stat(), named = stat()
            guard fstat(original.anchor, &opened) == 0,
                lstat(original.namespace.deletingLastPathComponent().path, &named) == 0,
                named.st_mode & S_IFMT == S_IFDIR, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { throw Failure.staleLease }
        }
        for node in original.nodes {
            var named = stat(), opened = stat()
            guard fstatat(node.parent, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                fstat(node.descriptor, &opened) == 0, named.st_mode & S_IFMT == S_IFDIR,
                named.st_dev == node.device, named.st_ino == node.inode,
                opened.st_dev == node.device, opened.st_ino == node.inode else { throw Failure.staleLease }
        }
    }
    private func createFreshCloudRoots(_ original: FreshCloudEnrollmentRoots) throws {
        try checkFreshCloudRoots(original, requireReady: false)
        if original.anchor < 0 {
            original.anchor = open(original.namespace.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard original.anchor >= 0 else { throw Failure.staleLease }
            // Re-observe the original checked ancestry after opening, before mkdir.
            guard try managedNamespace.inspect() == original.originalAbsence else { throw Failure.staleLease }
        }
        func create(_ name: String, parent: Int32) throws {
            if original.nodes.contains(where: { $0.name == name && $0.parent == parent }) { return }
            try checkFreshCloudRoots(original, requireReady: false)
            original.uncertainCreation = true // Never adopt an EEXIST race/unrecorded node.
            guard mkdirat(parent, name, 0o700) == 0 else { throw Failure.staleLease }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.staleLease }
            var opened = stat(), named = stat()
            guard fstat(fd, &opened) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                opened.st_mode & S_IFMT == S_IFDIR, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { close(fd); throw Failure.staleLease }
            original.nodes.append(.init(name: name, parent: parent, descriptor: fd, device: opened.st_dev, inode: opened.st_ino))
            original.uncertainCreation = false // Exact created node is retained BEFORE fsync.
        }
        try create(DeviceNativeManagedRootLocator.namespaceName, parent: original.anchor)
        guard let namespaceNode = original.nodes.first else { throw Failure.staleLease }
        let observed = try managedNamespace.inspect()
        guard observed.classification == .managedPresent, observed.hasSameCheckedAnchor(as: original.originalAbsence) else { throw Failure.staleLease }
        if let previous = original.present { guard previous == observed else { throw Failure.staleLease } }
        else { original.present = observed }
        for name in DeviceNativeManagedRootLocator.futureChildNames + ["enrollment"] { try create(name, parent: namespaceNode.descriptor) }
        // Retry synchronizes only retained exact child/parent descriptors. No
        // unrelated ancestor fsync, UUID regeneration, or visible-node adoption.
        try checkFreshCloudRoots(original, requireReady: false)
        for node in original.nodes { guard fsync(node.descriptor) == 0, fsync(node.parent) == 0 else { throw Failure.staleLease } }
        try checkFreshCloudRoots(original, requireReady: false); original.ready = true
    }

    @_spi(NativeInstallation) public final class LocalInventoryRoots {
        public let namespace: URL, packageRoot: URL, grantRoot: URL, structuralRoot: URL, provisioningRoot: URL
        public let ids: NativeManagedLocalRootIDs
        fileprivate let lease: Lease
        fileprivate let resetBaseline: DeviceLocalResetRecord?
        fileprivate let reservations: [UnifiedRootReservation]
        fileprivate init(namespace: URL, ids: NativeManagedLocalRootIDs, lease: Lease, resetBaseline: DeviceLocalResetRecord?, reservations: [UnifiedRootReservation]) {
            self.namespace = namespace; self.ids = ids; self.lease = lease; self.resetBaseline = resetBaseline; self.reservations = reservations
            packageRoot = namespace.appendingPathComponent("packages", isDirectory: true)
            grantRoot = namespace.appendingPathComponent("grants", isDirectory: true)
            structuralRoot = namespace.appendingPathComponent("structural", isDirectory: true)
            provisioningRoot = namespace.appendingPathComponent("provisioning", isDirectory: true)
        }
    }
    /// Called only after the original four root UUIDs have been recorded durably.
    /// Physical reservation is separate from Core's package/grant/journal qualification.
    @_spi(NativeInstallation) public func prepareLocalInventoryRoots(lease: Lease,
        ids: NativeManagedLocalRootIDs) throws -> LocalInventoryRoots {
        try serialized {
            guard permitted, lease.owner == identity, lease.generation == generation,
                let current = verifiedEvidence(), current == evidence else { throw Failure.staleLease }
            let namespace = try managedNamespace.inspect().namespaceURL.deletingLastPathComponent()
                .appendingPathComponent("xyz.screenpunk.local-inventory", isDirectory: true)
            var reservations: [UnifiedRootReservation] = []
            func pin(_ root: URL, id: UUID) throws {
                let anchor = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard anchor >= 0 else { throw Failure.staleLease }
                var anchorStat = stat()
                guard fstat(anchor, &anchorStat) == 0 else { close(anchor); throw Failure.staleLease }
                if mkdirat(anchor, root.lastPathComponent, 0o700) != 0 && errno != EEXIST { close(anchor); throw Failure.staleLease }
                let fd = openat(anchor, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { close(anchor); throw Failure.staleLease }
                var value = stat()
                guard fstat(fd, &value) == 0 else { close(fd); close(anchor); throw Failure.staleLease }
                let reservation = UnifiedRootReservation(root: root, rootID: id, anchor: anchor,
                    descriptor: fd, anchorIdentity: anchorStat, identity: value)
                try reservation.validate()
                guard fsync(fd) == 0, fsync(anchor) == 0 else { throw Failure.staleLease }
                reservations.append(reservation)
            }
            try pin(namespace, id: ids.contentGenesis)
            for (name, id) in [("packages", ids.package), ("grants", ids.grant),
                ("structural", ids.structural), ("provisioning", ids.provisioning)] {
                try pin(namespace.appendingPathComponent(name, isDirectory: true), id: id)
            }
            guard let after = verifiedEvidence(), after == evidence else { throw Failure.staleLease }
            return LocalInventoryRoots(namespace: namespace, ids: ids, lease: lease, resetBaseline: try reset.load(), reservations: reservations)
        }
    }
    private func physicalInventoryParent(_ input: URL) throws -> URL {
        let before = open(input.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard before >= 0 else { throw Failure.staleLease }; defer { close(before) }
        guard let path = realpath(input.path, nil) else { throw Failure.staleLease }; defer { free(path) }
        let result = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        let after = open(result.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard after >= 0 else { throw Failure.staleLease }; defer { close(after) }
        var first = stat(), last = stat()
        guard fstat(before, &first) == 0, fstat(after, &last) == 0,
            first.st_dev == last.st_dev, first.st_ino == last.st_ino else { throw Failure.staleLease }
        return result
    }
    /// Reopens retained Local source roots from committed mixed metadata. This
    /// never creates a namespace or derives Local authority from metadata alone.
    @_spi(NativeInstallation) public func restoreDetachedLocalInventoryRoots(context: DetachedLocalContext,
        operationID: UUID? = nil, ids: NativeManagedLocalRootIDs) throws -> LocalInventoryRoots {
        try serialized {
            try checkDetachedLocal(context, requireActive: false)
            let name = operationID.map { "xyz.screenpunk.local-operation-" + $0.uuidString.lowercased() } ?? "xyz.screenpunk.local-inventory"
            let namespace = context.commonRoot.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            var reservations: [UnifiedRootReservation] = []
            for (root, id) in [(namespace, ids.contentGenesis),
                (namespace.appendingPathComponent("packages", isDirectory: true), ids.package),
                (namespace.appendingPathComponent("grants", isDirectory: true), ids.grant),
                (namespace.appendingPathComponent("structural", isDirectory: true), ids.structural),
                (namespace.appendingPathComponent("provisioning", isDirectory: true), ids.provisioning)] {
                let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else { throw Failure.staleLease }
                let fd = openat(parent, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { close(parent); throw Failure.staleLease }
                var p = stat(), n = stat()
                guard fstat(parent, &p) == 0, fstat(fd, &n) == 0 else { close(fd); close(parent); throw Failure.staleLease }
                let reservation = UnifiedRootReservation(root: root, rootID: id, anchor: parent,
                    descriptor: fd, anchorIdentity: p, identity: n)
                try reservation.validate(); reservations.append(reservation)
            }
            try checkDetachedLocal(context, requireActive: false)
            return LocalInventoryRoots(namespace: namespace, ids: ids,
                lease: Lease(owner: identity, generation: generation), resetBaseline: context.resetBaseline, reservations: reservations)
        }
    }

    /// Reserves disjoint incoming package roots after the host has durably recorded
    /// its operation and root identities. Final mutation still requires a sealed peer command.
    @_spi(NativeInstallation) public func prepareIncomingLocalInventoryRoots(context: DeviceManagementContext,
        operationID: UUID, ids: NativeManagedLocalRootIDs) throws -> LocalInventoryRoots {
        try serialized {
            guard context.belongs(to: self), context.isConcurrent, concurrentControlQualified else { throw Failure.staleLease }
            let original = try liveUnifiedLocalRoot()
            guard context.commonRootID == original.root.rootID else { throw Failure.staleLease }
            let namespace = try physicalInventoryParent(original.root.root.deletingLastPathComponent())
                .appendingPathComponent("xyz.screenpunk.local-operation-" + operationID.uuidString.lowercased(), isDirectory: true)
            var reservations: [UnifiedRootReservation] = []
            for (root, id) in [(namespace, ids.contentGenesis),
                (namespace.appendingPathComponent("packages", isDirectory: true), ids.package),
                (namespace.appendingPathComponent("grants", isDirectory: true), ids.grant),
                (namespace.appendingPathComponent("structural", isDirectory: true), ids.structural),
                (namespace.appendingPathComponent("provisioning", isDirectory: true), ids.provisioning)] {
                let anchor = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard anchor >= 0 else { throw Failure.staleLease }
                var anchorStat = stat()
                guard fstat(anchor, &anchorStat) == 0 else { close(anchor); throw Failure.staleLease }
                if mkdirat(anchor, root.lastPathComponent, 0o700) != 0 && errno != EEXIST { close(anchor); throw Failure.staleLease }
                let fd = openat(anchor, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { close(anchor); throw Failure.staleLease }
                var value = stat()
                guard fstat(fd, &value) == 0 else { close(fd); close(anchor); throw Failure.staleLease }
                let reservation = UnifiedRootReservation(root: root, rootID: id, anchor: anchor,
                    descriptor: fd, anchorIdentity: anchorStat, identity: value)
                try reservation.validate()
                guard fsync(fd) == 0, fsync(anchor) == 0 else { throw Failure.staleLease }
                reservations.append(reservation)
            }
            _ = try liveUnifiedLocalRoot()
            return LocalInventoryRoots(namespace: namespace, ids: ids,
                lease: Lease(owner: identity, generation: generation), resetBaseline: try reset.load(), reservations: reservations)
        }
    }

    /// Opens only original incoming roots. Core independently verifies the completed
    /// operation, exact root bindings and grant/package journals before admitting content.
    @_spi(NativeInstallation) public func restoreIncomingLocalInventoryRoots(context: CloudInstallationContext,
        operationID: UUID, ids: NativeManagedLocalRootIDs) throws -> LocalInventoryRoots {
        try serialized {
            guard context.owner == identity, resetAttempt == nil, !resetQuarantined,
                try reset.load() == context.resetBaseline else { throw Failure.staleLease }
            try context.installation.verifyManagedNamespace(managedNamespace.inspect())
            let namespace = try physicalInventoryParent(managedNamespace.inspect().namespaceURL.deletingLastPathComponent())
                .appendingPathComponent("xyz.screenpunk.local-operation-" + operationID.uuidString.lowercased(), isDirectory: true)
            var reservations: [UnifiedRootReservation] = []
            for (root, id) in [(namespace, ids.contentGenesis),
                (namespace.appendingPathComponent("packages", isDirectory: true), ids.package),
                (namespace.appendingPathComponent("grants", isDirectory: true), ids.grant),
                (namespace.appendingPathComponent("structural", isDirectory: true), ids.structural),
                (namespace.appendingPathComponent("provisioning", isDirectory: true), ids.provisioning)] {
                let anchor = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard anchor >= 0 else { throw Failure.staleLease }
                var anchorStat = stat()
                guard fstat(anchor, &anchorStat) == 0 else { close(anchor); throw Failure.staleLease }
                let fd = openat(anchor, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { close(anchor); throw Failure.staleLease }
                var value = stat()
                guard fstat(fd, &value) == 0 else { close(fd); close(anchor); throw Failure.staleLease }
                let reservation = UnifiedRootReservation(root: root, rootID: id, anchor: anchor,
                    descriptor: fd, anchorIdentity: anchorStat, identity: value)
                try reservation.validate()
                reservations.append(reservation)
            }
            try context.installation.verifyManagedNamespace(managedNamespace.inspect())
            guard resetAttempt == nil, !resetQuarantined, try reset.load() == context.resetBaseline else { throw Failure.staleLease }
            return LocalInventoryRoots(namespace: namespace, ids: ids,
                lease: Lease(owner: identity, generation: generation), resetBaseline: try reset.load(), reservations: reservations)
        }
    }

    /// Qualified enrolled restart only. Opens the original roots without creating,
    /// resetting or adopting contents; Core must replay the completed migration next.
    @_spi(NativeInstallation) public func restoreRecordedLocalInventoryRoots(context: CloudInstallationContext,
        ids: NativeManagedLocalRootIDs) throws -> LocalInventoryRoots {
        try serialized {
            guard context.owner == identity, context.process == cloudProcess, resetAttempt == nil,
                !resetQuarantined, try reset.load() == context.resetBaseline else { throw Failure.staleLease }
            try context.installation.verifyManagedNamespace(managedNamespace.inspect())
            let namespace = try managedNamespace.inspect().namespaceURL.deletingLastPathComponent()
                .appendingPathComponent("xyz.screenpunk.local-inventory", isDirectory: true)
            var reservations: [UnifiedRootReservation] = []
            for (root, id) in [(namespace, ids.contentGenesis),
                (namespace.appendingPathComponent("packages", isDirectory: true), ids.package),
                (namespace.appendingPathComponent("grants", isDirectory: true), ids.grant),
                (namespace.appendingPathComponent("structural", isDirectory: true), ids.structural),
                (namespace.appendingPathComponent("provisioning", isDirectory: true), ids.provisioning)] {
                let anchor = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard anchor >= 0 else { throw Failure.staleLease }
                let fd = openat(anchor, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { close(anchor); throw Failure.staleLease }
                var anchorStat = stat(), value = stat()
                guard fstat(anchor, &anchorStat) == 0, fstat(fd, &value) == 0 else { close(fd); close(anchor); throw Failure.staleLease }
                let reservation = UnifiedRootReservation(root: root, rootID: id, anchor: anchor,
                    descriptor: fd, anchorIdentity: anchorStat, identity: value)
                try reservation.validate(); reservations.append(reservation)
            }
            guard context.owner == identity, context.process == cloudProcess, resetAttempt == nil,
                !resetQuarantined, try reset.load() == context.resetBaseline else { throw Failure.staleLease }
            try context.installation.verifyManagedNamespace(managedNamespace.inspect())
            return LocalInventoryRoots(namespace: namespace, ids: ids,
                lease: Lease(owner: identity, generation: generation), resetBaseline: try reset.load(), reservations: reservations)
        }
    }
    /// Physical ownership checkpoint only; a completed migration can outlive its
    /// original Local permission. Core independently checks command/grant admission.
    @_spi(NativeInstallation) public func validateLocalInventoryRoots(_ roots: LocalInventoryRoots) throws {
        lock.lock(); defer { lock.unlock() }
        guard roots.lease.owner == identity, resetAttempt == nil, !resetQuarantined,
            try reset.load() == roots.resetBaseline else { throw Failure.staleLease }
        for reservation in roots.reservations { try reservation.validate() }
    }

    /// Independent common inventory root. A recorded UUID qualifies the binding; directory
    /// presence alone never grants an existing Local or Cloud installation authority.
    final class UnifiedRootReservation {
        let root: URL, rootID: UUID, anchor: Int32, descriptor: Int32
        let anchorIdentity: stat, identity: stat
        init(root: URL, rootID: UUID, anchor: Int32, descriptor: Int32, anchorIdentity: stat, identity: stat) {
            self.root = root; self.rootID = rootID; self.anchor = anchor; self.descriptor = descriptor
            self.anchorIdentity = anchorIdentity; self.identity = identity
        }
        deinit { close(descriptor); close(anchor) }
        func validate() throws {
            var anchorOpened = stat(), anchorNamed = stat(), opened = stat(), named = stat()
            guard fstat(anchor, &anchorOpened) == 0, lstat(root.deletingLastPathComponent().path, &anchorNamed) == 0,
                anchorNamed.st_mode & S_IFMT == S_IFDIR, anchorOpened.st_dev == anchorIdentity.st_dev,
                anchorOpened.st_ino == anchorIdentity.st_ino, anchorNamed.st_dev == anchorIdentity.st_dev,
                anchorNamed.st_ino == anchorIdentity.st_ino,
                fstat(descriptor, &opened) == 0, fstatat(anchor, root.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                named.st_mode & S_IFMT == S_IFDIR, opened.st_dev == identity.st_dev, opened.st_ino == identity.st_ino,
                named.st_dev == identity.st_dev, named.st_ino == identity.st_ino else { throw Failure.staleLease }
        }
    }
    /// Trusted release qualification only; default production builds deny new concurrent
    /// command admission. Existing mixed inventory reads retain their independent schema.
    @_spi(NativeInstallation) public func qualifiedConcurrentControl(context: CloudInstallationContext) throws -> Bool {
        try serialized { try checkCloud(context); return concurrentControlQualified }
    }
    @_spi(NativeInstallation) public func makeUnifiedInventorySession(context: CloudInstallationContext,
        current: NativeCurrentInstallationDispatch, commonRootID: UUID,
        local: DeviceLegacyMigrationSession? = nil, native: NativeDeliveryExecutionSession) throws -> DeviceUnifiedInventorySession {
        // Core owner callbacks may reenter this authority, so validate outside its synchronous gate.
        try current.requireInstallationAssociation(context.installation)
        try native.validateUnifiedInventoryAssociation(current: current)
        let reservation = try serialized { () throws -> UnifiedRootReservation in
            try checkCloud(context)
            let namespace = try managedNamespace.inspect().namespaceURL
            let root = namespace.deletingLastPathComponent().standardizedFileURL.appendingPathComponent("xyz.screenpunk.unified-inventory", isDirectory: true)
            let anchor = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard anchor >= 0 else { throw Failure.staleLease }
            var anchorIdentity = stat()
            guard fstat(anchor, &anchorIdentity) == 0 else { close(anchor); throw Failure.staleLease }
            var finalInfo = stat()
            var exists = fstatat(anchor, root.lastPathComponent, &finalInfo, AT_SYMLINK_NOFOLLOW) == 0
            if !exists && errno != ENOENT { close(anchor); throw Failure.staleLease }
            if exists {
                guard finalInfo.st_mode & S_IFMT == S_IFDIR else { close(anchor); throw Failure.staleLease }
                let candidate = openat(anchor, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard candidate >= 0 else { close(anchor); throw Failure.staleLease }
                var bindingInfo = stat()
                let bound = fstatat(candidate, "mixed-root.json", &bindingInfo, AT_SYMLINK_NOFOLLOW) == 0
                if !bound {
                    guard errno == ENOENT else { close(candidate); close(anchor); throw Failure.staleLease }
                    var named = stat(), opened = stat()
                    guard fstat(candidate, &opened) == 0,
                        fstatat(anchor, root.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                        opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                        close(candidate); close(anchor); throw Failure.staleLease
                    }
                    // An unbound orphan is never adopted or erased. Preserve it at an
                    // exact new sibling name before preparing this original logical UUID.
                    let retained = "xyz.screenpunk.unified-inventory.orphan." + UUID().uuidString.lowercased()
                    guard renameatx_np(anchor, root.lastPathComponent, anchor, retained, UInt32(RENAME_EXCL)) == 0,
                        fsync(anchor) == 0 else { close(candidate); close(anchor); throw Failure.staleLease }
                    exists = false
                }
                close(candidate)
            }
            if !exists {
                let stageName = "xyz.screenpunk.unified-inventory.staging." + UUID().uuidString.lowercased()
                guard mkdirat(anchor, stageName, 0o700) == 0 else { close(anchor); throw Failure.staleLease }
                let stage = root.deletingLastPathComponent().appendingPathComponent(stageName, isDirectory: true)
                let stageFD = openat(anchor, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard stageFD >= 0 else { close(anchor); throw Failure.staleLease }
                defer { close(stageFD) }
                var stageIdentity = stat()
                guard fstat(stageFD, &stageIdentity) == 0 else { close(anchor); throw Failure.staleLease }
                // Bind the final pathname while still private; no inventory material or
                // server association exists until the fully bound inode is promoted.
                do {
                    try DeviceUnifiedInventorySession.prepareOwnedRootForPromotion(stagingRoot: stage,
                        finalRoot: root, rootID: commonRootID)
                    try checkCloud(context)
                    var stageNamed = stat(), promoted = stat()
                    guard fstatat(anchor, stageName, &stageNamed, AT_SYMLINK_NOFOLLOW) == 0,
                        stageNamed.st_mode & S_IFMT == S_IFDIR, stageNamed.st_dev == stageIdentity.st_dev,
                        stageNamed.st_ino == stageIdentity.st_ino,
                        renameatx_np(anchor, stageName, anchor, root.lastPathComponent, UInt32(RENAME_EXCL)) == 0,
                        fstatat(anchor, root.lastPathComponent, &promoted, AT_SYMLINK_NOFOLLOW) == 0,
                        promoted.st_dev == stageIdentity.st_dev, promoted.st_ino == stageIdentity.st_ino,
                        fsync(anchor) == 0 else { throw Failure.staleLease }
                } catch { close(anchor); throw error } // Retain every uncertain staged inode.
            }
            let fd = openat(anchor, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { close(anchor); throw Failure.staleLease }
            var identity = stat()
            guard fstat(fd, &identity) == 0 else { close(fd); close(anchor); throw Failure.staleLease }
            let reservation = UnifiedRootReservation(root: root, rootID: commonRootID, anchor: anchor,
                descriptor: fd, anchorIdentity: anchorIdentity, identity: identity)
            try reservation.validate()
            do {
                // Both fresh promotion and restart must retain the original UUID binding.
                let binding = openat(fd, "mixed-root.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard binding >= 0 else { throw Failure.staleLease }
                defer { close(binding) }
                var info = stat()
                guard fstat(binding, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                    info.st_size > 0, info.st_size <= 8192 else { throw Failure.staleLease }
                var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
                guard read(binding, &bytes, bytes.count) == bytes.count,
                    let value = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                    let text = value["rootID"] as? String, UUID(uuidString: text) == commonRootID else { throw Failure.staleLease }
            }
            guard fsync(fd) == 0, fsync(anchor) == 0 else { throw Failure.staleLease }
            try checkCloud(context); try reservation.validate(); return reservation
        }
        let session = DeviceUnifiedInventorySession(local: local, native: native,
            commonRoot: reservation.root, commonRootID: commonRootID, validateOriginal: { [self, reservation, context] in
                try validateUnifiedResourceContext(context: context, reservation: reservation)
            }, validateMutation: { [self, reservation, context] in
                try serialized {
                    try checkUnifiedLocalRoot((context, reservation))
                    guard concurrentControlQualified else { throw Failure.staleLease }
                }
            }, automationOwner: { [self] base in try makeAutomaticSelectionOwner(context: context, commonRootID: commonRootID, baseGenerationID: base) })
        try current.requireInstallationAssociation(context.installation)
        try native.validateUnifiedInventoryAssociation(current: current)
        try serialized {
            try checkCloud(context); try reservation.validate()
            if let previous = unifiedRoot {
                guard previous.context === context, previous.root.rootID == commonRootID else { throw Failure.staleLease }
                try previous.root.validate()
            }
            unifiedRoot = (context, reservation)
        }
        return session
    }

    /// Future scene lifecycle calls only; entering never creates or restores admission.
    @_spi(NativeInstallation) public func enterCloudForeground() throws {
        try serialized { if !cloudForeground { invalidateCloud(); cloudForeground = true } }
    }
    @_spi(NativeInstallation) public func leaveCloudForeground() throws {
        try serialized { cloudForeground = false; invalidateCloud() }
    }
    private func invalidateCloud() {
        // Cloud connection lifetime is independent of the retained physical Local owner.
        cloudGeneration = UUID(); cloudInstallation = nil; cloudRequestID = nil; cloudAcceptedStartedAt = nil; cloudAcceptedObservation = nil; cloudRequestStartedAt = nil
    }
    private func cloudResetAllowed() throws -> DeviceLocalResetRecord? {
        do {
            guard resetAttempt == nil, migrationAttempt == nil, !resetQuarantined else { throw Failure.staleLease }
            let record = try reset.load(), digest = try reset.scopeDigest
            guard observedReset == nil || observedReset == record,
                record == nil || (record?.scopeDigest == digest && record?.phase == .completed) else { throw Failure.staleLease }
            if let record { observedReset = record }
            return record
        } catch {
            invalidateCloud(); throw error
        }
    }
    @_spi(NativeInstallation) public func bindOperationalInstallation(installation: NativeOperationalInstallation,
        activation: NativeActivationReceipt, origin: URL) throws -> CloudInstallationContext {
        let origin = try NativeOperationalInstallation.validatedOrigin(origin)
        try installation.validateActivation(activation)
        try installation.requireDurableActivationAssociation(activation)
        return try serialized {
            guard cloudForeground else { throw Failure.staleLease }
            let resetBaseline = try cloudResetAllowed()
            if let reader = freshOperationalReader {
                try reader.validateQualifiedInstallation(installation)
                try checkFreshCloudRoots(reader.roots, requireReady: true)
            }
            try installation.verifyManagedNamespace(managedNamespace.inspect())
            // Attaching a new context revokes the old one; no Local classification changes.
            invalidateCloud()
            let context = CloudInstallationContext(owner: identity, process: cloudProcess, generation: cloudGeneration,
                installation: installation, activation: activation, origin: origin, resetBaseline: resetBaseline)
            cloudInstallation = context
            freshOperationalReader?.attachOperationalContext(context)
            return context
        }
    }
    private func checkCloud(_ context: CloudInstallationContext) throws {
        guard cloudForeground, context.owner == identity, context.process == cloudProcess,
            context.generation == cloudGeneration, cloudInstallation === context else { throw Failure.staleLease }
        let currentReset = try cloudResetAllowed()
        guard currentReset == context.resetBaseline else {
            // A completed external reset is still a new lifetime. The old
            // context cannot adopt it or reuse a previously accepted start time.
            invalidateCloud(); throw Failure.staleLease
        }
        try context.installation.verifyManagedNamespace(managedNamespace.inspect())
    }
    @_spi(NativeInstallation) public func prepareCloudStatusRequest(_ context: CloudInstallationContext) throws -> NativeOperationalStatusRequest {
        try serialized { try checkCloud(context); cloudAcceptedStartedAt = nil; cloudAcceptedObservation = nil; cloudRequestID = nil; cloudRequestStartedAt = nil }
        // Original credential read is outside this owner and every journal/server/Gate lock.
        let request = try context.installation.makeStatusRequest(origin: context.origin, activation: context.activation)
        return try serialized { try checkCloud(context); cloudRequestID = request.requestID; return request }
    }
    @_spi(NativeInstallation) public func beginCloudStatusRequest(_ context: CloudInstallationContext, requestID: UUID) throws {
        try serialized {
            try checkCloud(context)
            guard requestID == cloudRequestID, cloudRequestStartedAt == nil else { throw Failure.staleLease }
            let now = cloudClock(); guard now.isFinite, now >= 0 else { throw Failure.staleLease }
            cloudRequestStartedAt = now
        }
    }
    @_spi(NativeInstallation) public func acceptCloudStatus(_ observation: NativeOperationalStatusObservation,
        context: CloudInstallationContext) throws {
        try serialized {
            try checkCloud(context)
            guard observation.requestID == cloudRequestID, observation.belongs(to: context.installation) else { throw Failure.staleLease }
            let now = cloudClock()
            guard let started = cloudRequestStartedAt, Self.cloudStatusFresh(requestStartedAt: started, now: now) else { throw Failure.staleLease }
            cloudAcceptedStartedAt = started; cloudAcceptedObservation = observation; cloudRequestID = nil; cloudRequestStartedAt = nil
        }
    }
    /// Entry validation only. This is not a standalone runtime lease or permission to write.
    /// Future fixed server/Gate dispatch must stay inside this same serialized owner operation.
    @_spi(NativeInstallation) public func validateCloudRequestStart(_ context: CloudInstallationContext) throws {
        try serialized { try cloudFresh(context) }
    }
    static func cloudStatusFresh(requestStartedAt: TimeInterval, now: TimeInterval) -> Bool {
        requestStartedAt.isFinite && requestStartedAt >= 0 && now.isFinite && now >= requestStartedAt && now - requestStartedAt <= 30
    }
    private func cloudFresh(_ context: CloudInstallationContext) throws {
        try checkCloud(context)
        guard let observed = cloudAcceptedStartedAt else { throw Failure.staleLease }
        let now = cloudClock()
        guard Self.cloudStatusFresh(requestStartedAt: observed, now: now) else { cloudAcceptedStartedAt = nil; throw Failure.staleLease }
    }
    @_spi(NativeInstallation) public func prepareCurrentInstallationDispatch(_ context: CloudInstallationContext) throws -> NativeCurrentInstallationDispatch {
        let (started, observation, checkpoint) = try serialized {
            try cloudFresh(context)
            guard let observation = cloudAcceptedObservation else { throw Failure.staleLease }
            return (cloudClock(), observation, try commandIntents?.checkpoint())
        }
        let owner = CurrentInstallationDispatchOwner(authority: self, context: context, startedAt: started, checkpoint: checkpoint)
        return try context.installation.makeCurrentDispatch(observation: observation, owner: owner)
    }
    fileprivate func validateOperationalReadContext(_ context: CloudInstallationContext) throws {
        lock.lock()
        if factoryResetResourceContext === context {
            defer { lock.unlock() }
            try checkFactoryResetResourceContext(context, allowPersistedOriginal: true)
        } else {
            lock.unlock(); try serialized { try checkCloud(context) }
        }
    }
    private func validateUnifiedResourceContext(context: CloudInstallationContext, reservation: UnifiedRootReservation) throws {
        lock.lock()
        if factoryResetResourceContext === context {
            defer { lock.unlock() }
            try checkFactoryResetResourceContext(context)
            try checkUnifiedLocalRoot((context, reservation))
        } else { lock.unlock(); try serialized { try checkUnifiedLocalRoot((context, reservation)) } }
    }
    private func checkFactoryResetResourceContext(_ context: CloudInstallationContext, allowPersistedOriginal: Bool = false) throws {
        let record = try reset.load()
        let exactPersisted = allowPersistedOriginal && ownedReset?.origin === context && record?.phase == .pending && record?.resetID == ownedReset?.manifest.resetID && record?.scopeDigest == ownedReset?.scope.authorityScope.digest
        guard context.owner == identity, context.process == cloudProcess,
            (resetAttempt == nil && !resetQuarantined && record == context.resetBaseline) || exactPersisted,
            !supportAnchorPending, supportAnchorSetup.allowsNamespaceInspection,
            try journal.loadEvidence() == nil else { throw Failure.staleLease }
        try supportAnchorSetup.validateForInspection()
        try context.installation.verifyManagedNamespace(managedNamespace.inspect())
    }
    private func withFactoryResetResources<T>(_ context: CloudInstallationContext, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let originalExecuting = executing; executing = true
        defer { executing = originalExecuting }
        do {
            guard factoryResetResourceContext == nil else { throw Failure.staleLease }
            try checkFactoryResetResourceContext(context)
            factoryResetResourceContext = context
            defer { factoryResetResourceContext = nil }
            let result = try operation()
            try checkFactoryResetResourceContext(context, allowPersistedOriginal: true)
            return result
        }
    }
    fileprivate func validateDispatchContext(_ context: CloudInstallationContext, installation: NativeOperationalInstallation, startedAt: TimeInterval, checkpoint: DeviceCommandIntentCoordinator.Checkpoint?) throws {
        try serialized {
            guard context.installation === installation, Self.cloudStatusFresh(requestStartedAt: startedAt, now: cloudClock()) else { throw Failure.staleLease }
            try cloudFresh(context)
            if let checkpoint { try commandIntents?.requireUnchanged(checkpoint) }
        }
    }
    fileprivate func performFixedStructuralDispatch(_ context: CloudInstallationContext,
        startedAt: TimeInterval, checkpoint: DeviceCommandIntentCoordinator.Checkpoint?, command: NativeInstallationStructuralDispatchCommand) throws -> NativeInstallationStructuralDispatchResult {
        try serialized {
            guard Self.cloudStatusFresh(requestStartedAt: startedAt, now: cloudClock()) else { throw Failure.staleLease }
            try cloudFresh(context)
            if let checkpoint { try commandIntents?.requireUnchanged(checkpoint) }
            // Existing fixed synchronous Security inventory/read may run under resource locks.
            // Same-thread reentry rejects via serialized's executing guard; no network/UI.
            let result = try command.performFixedUnderAuthority()
            try cloudFresh(context)
            guard Self.cloudStatusFresh(requestStartedAt: startedAt, now: cloudClock()) else { throw Failure.staleLease }
            return result
        }
    }
    /// Restores only an already bound common inventory. No directory creation,
    /// genesis, network status or mutation admission is manufactured by recovery.
    @_spi(NativeInstallation) public func restoreUnifiedInventorySession(context: CloudInstallationContext,
        commonRootID: UUID, local: DeviceLegacyMigrationSession? = nil,
        native: NativeDeliveryExecutionSession,
        restoreIncomingLocal: ([DeviceUnifiedLocalSourceAssociation]) throws -> [DeviceIncomingLocalPreparation] = { sources in
            guard sources.isEmpty else { throw Failure.staleLease }; return []
        }) throws -> DeviceUnifiedInventorySession {
        try native.validateUnifiedInventoryResourceAssociation()
        let reservation = try serialized { () throws -> UnifiedRootReservation in
            guard context.owner == identity, context.process == cloudProcess, resetAttempt == nil,
                !resetQuarantined, try reset.load() == context.resetBaseline else { throw Failure.staleLease }
            try context.installation.verifyManagedNamespace(managedNamespace.inspect())
            let root = try managedNamespace.inspect().namespaceURL.deletingLastPathComponent().standardizedFileURL
                .appendingPathComponent("xyz.screenpunk.unified-inventory", isDirectory: true)
            let anchor = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard anchor >= 0 else { throw Failure.staleLease }
            let fd = openat(anchor, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { close(anchor); throw Failure.staleLease }
            var anchorStat = stat(), value = stat()
            guard fstat(anchor, &anchorStat) == 0, fstat(fd, &value) == 0 else { close(fd); close(anchor); throw Failure.staleLease }
            let result = UnifiedRootReservation(root: root, rootID: commonRootID, anchor: anchor,
                descriptor: fd, anchorIdentity: anchorStat, identity: value)
            try result.validate()
            // Core restore verifies the full binding, actual source resources and durable tip.
            return result
        }
        let previous = try serialized { () throws -> (context: CloudInstallationContext, root: UnifiedRootReservation)? in
            let old = unifiedRoot
            if let old {
                guard old.root.rootID == commonRootID,
                    old.context.activation.installationId == context.activation.installationId,
                    old.context.resetBaseline == context.resetBaseline else { throw Failure.staleLease }
                try old.root.validate()
            }
            unifiedRoot = (context, reservation); return old
        }
        func makeSession(_ incoming: [DeviceIncomingLocalPreparation]) -> DeviceUnifiedInventorySession {
            DeviceUnifiedInventorySession(local: local, incomingLocal: incoming, native: native,
            commonRoot: reservation.root, commonRootID: commonRootID,
            validateOriginal: { [self, reservation, context] in
                try serialized { try checkUnifiedLocalRoot((context, reservation)) }
            }, validateMutation: { [self, reservation, context] in
                try serialized { try checkUnifiedLocalRoot((context, reservation)); guard concurrentControlQualified else { throw Failure.staleLease } }
            }, automationOwner: { [self] base in try makeAutomaticSelectionOwner(context: context, commonRootID: commonRootID, baseGenerationID: base) })
        }
        do {
            let probe = makeSession([])
            let sources = try probe.retainedLocalSourceAssociations()
            let incoming = try restoreIncomingLocal(sources) // Outside serialized authority.
            let session = makeSession(incoming)
            guard try session.restoreCompleted() else { throw Failure.staleLease }
            try native.validateUnifiedInventoryResourceAssociation()
            try serialized { try checkUnifiedLocalRoot((context, reservation)) }
            return session
        } catch {
            try serialized { if unifiedRoot?.context === context { unifiedRoot = previous } }
            throw error
        }
    }

    private func checkUnifiedLocalRoot(_ original: (context: CloudInstallationContext, root: UnifiedRootReservation)) throws {
        guard let registered = unifiedRoot, registered.context === original.context,
            registered.root.rootID == original.root.rootID,
            original.context.owner == identity, original.context.process == cloudProcess,
            resetAttempt == nil, !resetQuarantined,
            try reset.load() == original.context.resetBaseline else { throw Failure.staleLease }
        // Qualified physical installation association outlives cloud credentials/status.
        // Core still verifies the retained source grants and complete immutable inventory.
        try original.context.installation.verifyManagedNamespace(managedNamespace.inspect())
        try original.root.validate()
    }
    @_spi(NativeInstallation) public func makeConcurrentLocalContext(context: CloudInstallationContext,
        session: DeviceUnifiedInventorySession) throws -> DeviceManagementContext {
        let association = try session.validatedAssociation()
        return try serialized {
            guard concurrentControlQualified, let original = unifiedRoot, original.context === context,
                association.commonRootID == original.root.rootID,
                association.installationID == context.activation.installationId else { throw Failure.staleLease }
            try checkUnifiedLocalRoot(original)
            return DeviceManagementContext(authority: self, concurrent: context, commonRootID: original.root.rootID)
        }
    }
    fileprivate func withUnifiedHostAuthority<T>(context: CloudInstallationContext, commonRootID: UUID,
        operation: () throws -> T) throws -> T {
        try serialized {
            guard concurrentControlQualified, let original = unifiedRoot, original.context === context,
                original.root.rootID == commonRootID else { throw Failure.staleLease }
            try checkUnifiedLocalRoot(original)
            let result = try operation()
            try checkUnifiedLocalRoot(original); return result
        }
    }
    fileprivate func observeUnifiedInvalidation(context: CloudInstallationContext, commonRootID: UUID,
        action: @escaping () -> Void) throws -> UUID {
        try serialized {
            guard concurrentControlQualified, let original = unifiedRoot, original.context === context,
                original.root.rootID == commonRootID else { throw Failure.staleLease }
            try checkUnifiedLocalRoot(original)
            let id = UUID(); unifiedInvalidationObservers[id] = action; return id
        }
    }
    /// Trusted LAN adapter only. Pair-registry admission is checked while this owner
    /// is held before accepting the intent, and again for the nominal fixed commit.
    func acceptUnifiedLocalIntent(peerPinHex: String, validateApproved: () throws -> Void) throws -> DeviceCommandIntentCoordinator.Checkpoint? {
        try serialized {
            guard concurrentControlQualified, let commandIntents,
                peerPinHex.count == 64, PeerPin.bytes(peerPinHex)?.count == 32 else { throw Failure.staleLease }
            _ = try liveUnifiedLocalRoot(); try validateApproved()
            try commandIntents.acceptLocalIntent()
            return try commandIntents.checkpoint()
        }
    }
    private func makeAutomaticSelectionOwner(context: CloudInstallationContext, commonRootID: UUID,
        baseGenerationID: UUID) throws -> any NativeUnifiedAutomationOwner {
        try serialized {
            guard concurrentControlQualified, let commandIntents, let original = unifiedRoot,
                original.context === context, original.root.rootID == commonRootID else { throw Failure.staleLease }
            try checkUnifiedLocalRoot(original)
            let checkpoint = try commandIntents.automationCheckpoint(baseGenerationID: baseGenerationID)
            return FixedAutomaticSelectionOwner(authority: self, context: context, commonRootID: commonRootID, checkpoint: checkpoint)
        }
    }
    fileprivate func performFixedAutomaticSelection(context: CloudInstallationContext, commonRootID: UUID,
        checkpoint: DeviceCommandIntentCoordinator.Checkpoint, command: NativeInstallationAutomaticSelectionCommand) throws -> NativeInstallationAutomaticSelectionResult {
        try serialized {
            guard concurrentControlQualified, let commandIntents, let original = unifiedRoot,
                original.context === context, original.root.rootID == commonRootID,
                command.commonRootID == commonRootID, command.installationID == context.activation.installationId else { throw Failure.staleLease }
            try checkUnifiedLocalRoot(original); try commandIntents.requireUnchanged(checkpoint)
            let result = try command.performDuringFixedOwner()
            try checkUnifiedLocalRoot(original); try commandIntents.requireUnchanged(checkpoint)
            return result
        }
    }
    func performFixedUnifiedLocalDispatch(command: NativeInstallationUnifiedLocalDispatchCommand,
        peerPinHex: String, checkpoint: DeviceCommandIntentCoordinator.Checkpoint?,
        performApproved: () throws -> NativeInstallationUnifiedLocalDispatchResult) throws -> NativeInstallationUnifiedLocalDispatchResult {
        try serialized {
            let original = try liveUnifiedLocalRoot()
            guard concurrentControlQualified,
                original.root.rootID == command.commonRootID,
                command.installationID == original.installationID,
                command.peerPinHex == peerPinHex,
                commandIntents != nil, checkpoint != nil else { throw Failure.staleLease }
            // Local approved control continues during Cloud network outages; only
            // the genuine installation/reset lifetime is required here.
            _ = try liveUnifiedLocalRoot()
            if let checkpoint { try commandIntents?.requireUnchanged(checkpoint) }
            let result = try performApproved() // Fixed LAN adapter retains registry lock throughout.
            _ = try liveUnifiedLocalRoot()
            if let checkpoint {
                try commandIntents?.requireUnchanged(checkpoint)
                try commandIntents?.recordCommittedInventory(checkpoint: checkpoint, generationID: command.resultingGenerationID)
            }
            return result
        }
    }
    fileprivate func performFixedUnifiedCloudAcceptance(_ context: CloudInstallationContext,
        startedAt: TimeInterval, checkpoint: DeviceCommandIntentCoordinator.Checkpoint?,
        command: NativeInstallationUnifiedCloudAcceptanceCommand) throws -> (NativeInstallationUnifiedCloudAcceptanceResult, DeviceCommandIntentCoordinator.Checkpoint) {
        try serialized {
            guard let commandIntents, let checkpoint, let original = unifiedRoot,
                original.context === context, original.root.rootID == command.commonRootID,
                command.installationID == context.activation.installationId,
                (!command.requiresConcurrentQualification || concurrentControlQualified),
                Self.cloudStatusFresh(requestStartedAt: startedAt, now: cloudClock()) else { throw Failure.staleLease }
            try cloudFresh(context); try original.root.validate(); try commandIntents.requireUnchanged(checkpoint)
            let result = try command.performDuringFixedOwner()
            let accepted = try commandIntents.acceptCloudDeployment(operationID: command.operationID, key: command.key, digest: command.digest)
            try cloudFresh(context); try original.root.validate(); try commandIntents.requireUnchanged(accepted)
            return (result, accepted)
        }
    }
    fileprivate func performFixedUnifiedStructuralDispatch(_ context: CloudInstallationContext,
        startedAt: TimeInterval, checkpoint: DeviceCommandIntentCoordinator.Checkpoint?,
        command: NativeInstallationUnifiedStructuralDispatchCommand) throws -> NativeInstallationUnifiedStructuralDispatchResult {
        try serialized {
            guard (!command.requiresConcurrentQualification || (concurrentControlQualified && commandIntents != nil && checkpoint != nil)),
                Self.cloudStatusFresh(requestStartedAt: startedAt, now: cloudClock()),
                let original = unifiedRoot, original.context === context,
                original.root.rootID == command.commonRootID,
                command.installationID == context.activation.installationId else { throw Failure.staleLease }
            try cloudFresh(context); try original.root.validate()
            if let checkpoint { try commandIntents?.requireUnchanged(checkpoint) }
            let result = try command.performDuringFixedOwner()
            try cloudFresh(context); try original.root.validate()
            guard Self.cloudStatusFresh(requestStartedAt: startedAt, now: cloudClock()) else { throw Failure.staleLease }
            if let checkpoint {
                try commandIntents?.requireUnchanged(checkpoint)
                try commandIntents?.recordCommittedInventory(checkpoint: checkpoint, generationID: command.resultingGenerationID)
            }
            return result
        }
    }
    /// Internal fixed-consumer seam: owner -> server -> Gate. No asynchronous/provider callback.
    func withCloudInstallationAuthority(_ context: CloudInstallationContext, operation: () throws -> Void) throws {
        try serialized { try cloudFresh(context); try operation() }
    }

    /// Production bootstrap only, before first inspection. Failed setup remains on
    /// this owner and never turns its visible uncertain directory into permission.
    func prepareProductionSupportAnchor() throws {
        try serialized {
            guard !managedNamespaceQuarantined else { throw Failure.staleLease }
            if observedNamespace != nil { try checkManagedNamespace(); return }
            invalidate(); supportAnchorPending = true
            try supportAnchorSetup.prepare()
            try supportAnchorSetup.prepareDefaultDeviceStateRoot()
            supportAnchorPending = false
        }
    }

    /// Inspection only for a completed detached Local inventory. This does not
    /// create a lease/context or qualify any inventory resource for management.
    func validateRecordedDetachedLocalStartup(commonRootID: UUID, retiredInstallationID: UUID) throws {
        try serialized {
            guard !supportAnchorPending, supportAnchorSetup.allowsNamespaceInspection else { throw Failure.staleLease }
            try supportAnchorSetup.validateForInspection()
            _ = try cloudResetAllowed()
            let namespace = try managedNamespace.inspect()
            guard namespace.classification == .confirmedAbsent else { throw Failure.staleLease }
            let root = try physicalInventoryParent(namespace.namespaceURL.deletingLastPathComponent())
                .appendingPathComponent("xyz.screenpunk.unified-inventory", isDirectory: true)
            guard let metadata = try DeviceUnifiedInventorySession.peekDetachedMetadata(commonRoot: root, commonRootID: commonRootID),
                metadata.commonRootID == commonRootID, metadata.retiredInstallationID == retiredInstallationID,
                metadata.cleanupCompleted else { throw Failure.staleLease }
        }
    }

    /// Same owner gates startup, retained rendering, reset and legacy management. Snapshot
    /// checks do not exclude external filesystem writers; future managed writes share this owner.
    func requireLegacyNamespaceAbsent() throws {
        try serialized { try checkManagedNamespace() }
    }
    /// Prepared-owner routing check only. No native identity, lease, root
    /// reservation or credential is adopted here; exact restore remains separate.
    func validateRecordedNativeStartup() throws {
        try serialized {
            guard !supportAnchorPending, supportAnchorSetup.allowsNamespaceInspection else { throw Failure.staleLease }
            try supportAnchorSetup.validateForInspection()
            _ = try cloudResetAllowed()
            guard try managedNamespace.inspect().classification == .managedPresent else { throw Failure.staleLease }
        }
    }
    private func checkManagedNamespace() throws {
        guard !managedNamespaceQuarantined else { throw Failure.staleLease }
        guard !supportAnchorPending, supportAnchorSetup.allowsNamespaceInspection else { throw Failure.staleLease }
        do {
            try supportAnchorSetup.validateForInspection()
            let current = try managedNamespace.inspect()
            guard current.classification == .confirmedAbsent,
                  observedNamespace == nil || observedNamespace == current else {
                managedNamespaceQuarantined = true; invalidate(); throw Failure.staleLease
            }
            observedNamespace = current
        } catch {
            managedNamespaceQuarantined = true; invalidate(); throw error
        }
    }

    /// Starts blocked and revokes previous leases even when classification fails.
    public func refresh() throws -> Lease? {
        try serialized {
            invalidate()
            guard let current = verifiedEvidence() else { return nil }
            evidence = current
            permitted = true
            return Lease(owner: identity, generation: generation)
        }
    }

    public func revoke() throws {
        try serialized {
            invalidationActions.append(contentsOf: unifiedInvalidationObservers.values)
            unifiedInvalidationObservers = [:]; unifiedRoot = nil
            invalidate()
        }
    }

    /// Keep the operation short and synchronous. It may not return an escaping
    /// authority capability, schedule management work, or call this owner again.
    /// Listener setup and request commit must each validate their lease separately.
    public func withLocalAuthority(_ lease: Lease, operation: () throws -> Void) throws {
        try serialized {
            guard permitted, lease.owner == identity, lease.generation == generation else { throw Failure.staleLease }
            guard let current = verifiedEvidence() else {
                invalidate()
                throw Failure.staleLease
            }
            guard current == evidence else {
                quarantined = true
                invalidate()
                throw Failure.staleLease
            }
            try operation()
        }
    }

    // Future in-process transition writes must route through this owner after exact
    // uncertain-write recovery is implemented. This slice exposes no Cloud write API. Fresh entry
    // checks detect external changes, but do not exclude external TOCTOU writers.
    private func verifiedEvidence() -> Evidence? {
        guard !quarantined, migrationAttempt == nil else { return nil }
        do {
            try checkManagedNamespace()
            let history = try journal.loadEvidence()
            // Conservatively require owner-mediated writes after observing history.
            // This lifetime high-water guard is not persistent rollback protection.
            if let observedHistory, history != observedHistory { quarantined = true; return nil }
            if let history { observedHistory = history }
            guard let resetEvidence = try permittedReset() else { return nil }
            let references = try credentials.references()
            if let evidence, evidence.history != history || evidence.references != references || evidence.reset != resetEvidence.record {
                quarantined = true; return nil
            }
            let before = Evidence(history: history, references: references, inventory: try credentials.inventory(history: history?.formattedHistory), reset: resetEvidence.record)
            if let evidence, before != evidence { quarantined = true; return nil }
            switch CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials) {
            case .blocked: return nil
            case .legacyLocal, .locallyFenced: break
            }
            guard let resetAfter = try permittedReset() else { return nil }
            let afterHistory = try journal.loadEvidence()
            let afterReferences = try credentials.references()
            guard before.history == afterHistory, before.references == afterReferences, before.reset == resetAfter.record else {
                quarantined = true; return nil
            }
            let after = Evidence(history: afterHistory, references: afterReferences, inventory: try credentials.inventory(history: afterHistory?.formattedHistory), reset: resetAfter.record)
            guard before == after else { quarantined = true; return nil }
            return after
        } catch { return nil }
    }

    private enum MigrationStage { case prepared, acknowledged }
    private struct MigrationAttempt { let source: DeviceManagementTransitionHistory; var stage: MigrationStage }
    private var migrationAttempt: MigrationAttempt?

    /// Explicit schema upgrade only; never returns a lease. Call refresh separately after acknowledgement.
    public func migrateLegacyHistory(expected: DeviceManagementTransitionHistory) throws {
        try serialized { try performMigration(expected: expected, recommit: false) }
    }
    public func recommitLegacyMigration(expected: DeviceManagementTransitionHistory) throws {
        try serialized { try performMigration(expected: expected, recommit: true) }
    }
    private func performMigration(expected: DeviceManagementTransitionHistory, recommit: Bool) throws {
        try checkManagedNamespace()
        invalidate()
        guard !quarantined, let store = journal as? DeviceManagementTransitionStore,
              try permittedReset() != nil else { throw Failure.staleLease }
        let target = try DeviceManagementFormatHistory(legacy: expected)
        if recommit {
            guard migrationAttempt?.source == expected else { throw Failure.staleLease }
        } else {
            guard migrationAttempt == nil else { throw Failure.staleLease }
            let actual = try journal.loadEvidence()
            guard actual == .legacy(expected) || actual == .formatted(target) else { quarantined = true; throw Failure.staleLease }
            if let observedHistory, observedHistory != actual { quarantined = true; throw Failure.staleLease }
            if let evidence, evidence.history != actual { quarantined = true; throw Failure.staleLease }
        }
        let migrationReferences = try credentials.references()
        if let evidence, evidence.references != migrationReferences { quarantined = true; throw Failure.staleLease }
        let before = try credentials.inventory(history: target)
        if !recommit { migrationAttempt = MigrationAttempt(source: expected, stage: .prepared) }
        if migrationAttempt?.stage == .prepared {
            if recommit, try store.hasUncertainLegacyMigration(expected: expected) {
                _ = try store.recommitLegacyMigration(expected: expected)
            } else {
                _ = try store.migrateLegacyHistory(expected: expected)
            }
            // Retain actual method acknowledgement before any potentially failing post-commit inspection.
            migrationAttempt?.stage = .acknowledged
        }
        guard try permittedReset() != nil else { throw Failure.staleLease }
        let afterReferences = try credentials.references()
        guard afterReferences == migrationReferences else { quarantined = true; throw Failure.staleLease }
        let after = try credentials.inventory(history: target)
        guard before == after, try journal.loadEvidence() == .formatted(target) else { quarantined = true; throw Failure.staleLease }
        observedHistory = .formatted(target)
        evidence = nil
        migrationAttempt = nil
        // permitted stays false. Only explicit fresh classification can issue authority.
    }

    /// Snapshot only: future reset coordinator must serialize presentation/suspension.
    /// Pending/corrupt reset must suppress retained WebViews as well as management.
    /// Eligibility observation only. Explicit reset still obtains/validates a new
    /// lease on this same owner and follows the existing scoped reset coordinator.
    func blockedLocalResetEligible() -> Bool {
        (try? serialized { verifiedEvidence() != nil }) ?? false
    }
    public func resetRenderingAllowed() -> Bool {
        (try? serialized { try permittedReset() != nil }) ?? false
    }
    private struct PermittedReset { let record: DeviceLocalResetRecord? }
    private func permittedReset() throws -> PermittedReset? {
        try checkManagedNamespace()
        guard resetAttempt == nil else { return nil }
        let digest = try reset.scopeDigest
        let record = try reset.load()
        if let observedReset, record != observedReset { resetQuarantined = true; quarantined = true; return nil }
        if let evidence, record != evidence.reset { resetQuarantined = true; quarantined = true; return nil }
        if let record { observedReset = record }
        guard !resetQuarantined, record == nil || (record?.scopeDigest == digest && record?.phase == .completed) else { return nil }
        return .init(record: record)
    }

    /// Device-owned explicit reset; enrollment identity and resource ownership,
    /// rather than Cloud command freshness or rollout flags, authorize issuance.
    @_spi(NativeInstallation) @MainActor public func prepareFactoryReset(context: CloudInstallationContext,
        session: DeviceUnifiedInventorySession?, native: NativeDeliveryExecutionSession,
        installation: NativeOperationalInstallation) throws -> DeviceOwnedFactoryResetPreparation {
        try prepareFactoryReset(context: context, session: session, native: native, installation: installation, provider: .production)
    }
    @MainActor func prepareFactoryReset(context: CloudInstallationContext,
        session: DeviceUnifiedInventorySession?, native: NativeDeliveryExecutionSession,
        installation: NativeOperationalInstallation, provider: DeviceLocalResetWriterProvider, ownedCredentials: (any DeviceOwnedResetCredentialCleanup)? = nil,
        baseCredentialSnapshot: (() throws -> [DeviceFactoryResetManifest.Credential])? = nil) throws -> DeviceOwnedFactoryResetPreparation {
        guard context.installation === installation else { throw Failure.staleLease }
        if let prepared = factoryResetPreparation {
            try validateFactoryResetPreparation(prepared.resetID); return prepared
        }
        let initial = try serialized { () throws -> (DeviceLocalResetEvidenceAdapter, DeviceLocalResetScope, DeviceLocalResetRecord?) in
            guard context.owner == identity, context.process == cloudProcess, resetAttempt == nil,
                ownedReset == nil, !resetQuarantined, !supportAnchorPending,
                supportAnchorSetup.allowsNamespaceInspection else { throw Failure.staleLease }
            try supportAnchorSetup.validateForInspection()
            try installation.verifyManagedNamespace(managedNamespace.inspect())
            guard try journal.loadEvidence() == nil else { throw Failure.resetConflict }
            guard let adapter = reset as? DeviceLocalResetEvidenceAdapter,
                try adapter.load() == context.resetBaseline else { throw Failure.resetConflict }
            return (adapter, try adapter.factoryResetBase(), try adapter.load())
        }
        let (resource, enrollment) = try withFactoryResetResources(context) {
            (try session?.qualifiedResetResourcesExact() ?? native.qualifiedResetResourcesExact(),
                try installation.qualifiedResetEnrollmentResourcesExact())
        }
        guard resource.installationID == context.activation.installationId,
            enrollment.installationID == resource.installationID else { throw Failure.staleLease }
        let anchor = try DeviceLocalResetScope.canonical(initial.1.deviceRoot.deletingLastPathComponent())
        let roots = resource.roots + enrollment.roots
        var parents = Set<String>()
        let rootPaths = Set(roots.map(\.path))
        for root in roots {
            guard root.path.hasPrefix(anchor.path + "/") else { throw Failure.resetConflict }
            var parent = URL(fileURLWithPath: root.path).deletingLastPathComponent()
            while parent.path != anchor.path {
                guard parent.path.hasPrefix(anchor.path + "/"), !rootPaths.contains(parent.path) else { throw Failure.resetConflict }
                parents.insert(parent.path); parent.deleteLastPathComponent()
            }
        }
        let containers = try parents.map { path -> DeviceFactoryResetManifest.Root in
            let canonical = try DeviceLocalResetScope.canonical(URL(fileURLWithPath: path))
            let fd = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.resetConflict }; defer { close(fd) }
            var opened = stat(), named = stat()
            guard fstat(fd, &opened) == 0, lstat(canonical.path, &named) == 0,
                named.st_mode & S_IFMT == S_IFDIR, opened.st_dev == named.st_dev,
                opened.st_ino == named.st_ino else { throw Failure.resetConflict }
            return .init(rootID: UUID(), path: canonical.path, device: UInt64(truncatingIfNeeded: opened.st_dev), inode: UInt64(truncatingIfNeeded: opened.st_ino))
        }
        let resetID = UUID()
        let snapshot: () throws -> [DeviceFactoryResetManifest.Credential] = baseCredentialSnapshot ?? { try self.snapshotBaseResetCredentials(initial.1) }
        let baseCredentials = try snapshot()
        let baseItems = Set(initial.1.credentialItems)
        guard baseCredentials.allSatisfy({ baseItems.contains(.init(service: $0.service, account: $0.account)) }) else {
            throw Failure.resetConflict
        }
        let manifest = try DeviceFactoryResetManifest(evidence: resource, resetID: resetID,
            installationID: resource.installationID, baseScopeDigest: initial.1.digest,
            additionalRoots: enrollment.roots.map { .init(rootID: $0.rootID, path: $0.path, device: $0.device, inode: $0.inode) },
            additionalCredentials: enrollment.credentials.map { .init(service: $0.service, account: $0.account,
                persistentReference: $0.persistentReference, byteCount: $0.byteCount, valueSHA256: $0.valueSHA256) } + baseCredentials, containers: containers)
        try manifest.validateStructure(); try manifest.validateContainerMembership()
        let configured = try DeviceLocalResetCleanupScope(v4: initial.1, anchor: anchor, manifest: manifest)
        let withOriginal: (() throws -> Void) throws -> Void = { operation in
            try self.withFactoryResetResources(context) {
            try resource.withCurrentResourcesExact {
                try enrollment.withCurrentResourcesExact {
                    guard try self.journal.loadEvidence() == nil,
                        try snapshot() == baseCredentials else { throw Failure.resetConflict }
                    try operation()
                }
            }
            }
        }
        try serialized {
            guard context.owner == identity, context.process == cloudProcess, resetAttempt == nil, ownedReset == nil,
                try initial.0.load() == initial.2 else { throw Failure.resetConflict }
            try installation.verifyManagedNamespace(managedNamespace.inspect())
            try withOriginal {
                try manifest.validateContainerMembership()
                try DeviceFactoryResetManifestStore(directory: initial.0.resetStore.directory).save(manifest)
                try initial.0.adoptOwnedScope(configured.authorityScope)
                ownedReset = .init(manifest: manifest, scope: configured, previousRecord: initial.2,
                    origin: context, withOriginal: withOriginal)
            }
        }
        let lifecycle = try DeviceLocalResetLifecycle(scope: configured, authorityFactory: { self }, provider: provider,
            cleanup: .init(scope: configured, ownedCredentials: ownedCredentials))
        let preparation = DeviceOwnedFactoryResetPreparation(resetID: resetID, lifecycle: lifecycle,
            context: .init(authority: self, factoryResetID: resetID))
        factoryResetPreparation = preparation; return preparation
    }
    @_spi(NativeInstallation) @MainActor public func recoverFactoryReset() throws -> DeviceOwnedFactoryResetPreparation? {
        try recoverFactoryReset(provider: .production)
    }
    @MainActor func recoverFactoryReset(provider: DeviceLocalResetWriterProvider,
        ownedCredentials: (any DeviceOwnedResetCredentialCleanup)? = nil) throws -> DeviceOwnedFactoryResetPreparation? {
        guard let adapter = reset as? DeviceLocalResetEvidenceAdapter else { _ = try reset.load(); return nil }
        let base = try adapter.factoryResetBase()
        if let prepared = factoryResetPreparation,
            try serialized({ let current = try adapter.resetStore.load(); return ownedReset?.manifest.resetID == prepared.resetID && current == ownedReset?.previousRecord }) {
            try validateFactoryResetPreparation(prepared.resetID); return prepared
        }
        guard let record = try adapter.resetStore.load() else { return nil }
        let anchor = try DeviceLocalResetScope.canonical(base.deviceRoot.deletingLastPathComponent())
        let configured = try DeviceLocalResetLifecycle.restoredProductionScope(base: base, anchor: anchor, store: adapter.resetStore)
        guard let manifest = configured.ownedManifest else { return nil }
        try serialized {
            guard resetAttempt == nil, !resetQuarantined, record.resetID == manifest.resetID,
                record.scopeDigest == configured.authorityScope.digest else { throw Failure.resetConflict }
            try supportAnchorSetup.validateForInspection()
            try adapter.adoptOwnedScope(configured.authorityScope)
            ownedReset = .init(manifest: manifest, scope: configured, previousRecord: record, origin: nil, withOriginal: nil)
            observedReset = record
            try validateFactoryResetRecord(record)
            if record.phase == .pending { quarantineFactoryResetWriters() }
            else { ownedReset = nil; factoryResetPreparation = nil }
        }
        guard record.phase == .pending else { return nil }
        let lifecycle = try DeviceLocalResetLifecycle(scope: configured, authorityFactory: { self }, provider: provider,
            cleanup: .init(scope: configured, ownedCredentials: ownedCredentials))
        return .init(resetID: record.resetID, lifecycle: lifecycle, context: nil)
    }

    /// Historical completion identity only. The App must already hold its
    /// pre-effects, exact enrollment-intent retirement sidecar; this proof cannot
    /// create a new cleanup scope or reopen any current device authority.
    @_spi(NativeInstallation) @MainActor public func completedFactoryResetIdentity(resetID: UUID,
        scopeDigest: String) throws -> DeviceOwnedFactoryResetCompletionIdentity {
        guard let adapter = reset as? DeviceLocalResetEvidenceAdapter else { throw Failure.resetConflict }
        let base = try adapter.factoryResetBase()
        let anchor = try DeviceLocalResetScope.canonical(base.deviceRoot.deletingLastPathComponent())
        let configured = try DeviceLocalResetLifecycle.restoredProductionScope(base: base, anchor: anchor, store: adapter.resetStore)
        guard let manifest = configured.ownedManifest, manifest.resetID == resetID,
            configured.authorityScope.digest == scopeDigest,
            let record = try adapter.resetStore.load(), record.phase == .completed,
            record.resetID == resetID, record.scopeDigest == scopeDigest else { throw Failure.resetConflict }
        let bytes = try manifest.canonicalBytes
        let validate: () throws -> Void = { [self] in
            try serialized {
                try supportAnchorSetup.validateForInspection()
                try base.validateCurrentPaths()
                guard try adapter.resetStore.load() == record,
                    let current = try DeviceFactoryResetManifestStore(directory: adapter.resetStore.directory).load(resetID: resetID),
                    try current.canonicalBytes == bytes else { throw Failure.resetConflict }
                try current.validateStructure()
            }
        }
        try validate()
        return .init(resetID: resetID, scopeDigest: scopeDigest, validate: validate)
    }

    private func snapshotBaseResetCredentials(_ base: DeviceLocalResetScope) throws -> [DeviceFactoryResetManifest.Credential] {
        try base.credentialItems.compactMap { item in
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service, kSecAttrAccount as String: item.account,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                kSecReturnAttributes as String: true, kSecReturnData as String: true,
                kSecReturnPersistentRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let attributes = result as? [String: Any],
                attributes[kSecAttrService as String] as? String == item.service,
                attributes[kSecAttrAccount as String] as? String == item.account,
                let reference = attributes[kSecValuePersistentRef as String] as? Data,
                let bytes = attributes[kSecValueData as String] as? Data, !bytes.isEmpty,
                !reference.isEmpty else { throw Failure.resetConflict }
            // Secrets never leave this bounded local snapshot or enter the manifest.
            return .init(service: item.service, account: item.account, persistentReference: reference, byteCount: bytes.count, valueSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
    }

    func ownedFactoryResetCompletionValidation(_ record: DeviceLocalResetRecord) throws -> () throws -> Void {
        let checkpoint = try serialized { () throws -> (UUID, UUID, DeviceManagedNamespaceEvidence) in
            guard let ownedReset, record.phase == .completed, record.resetID == ownedReset.manifest.resetID,
                record.scopeDigest == ownedReset.scope.authorityScope.digest, resetAttempt == nil,
                try reset.load() == record else { throw Failure.resetConflict }
            try validateFactoryResetRecord(record)
            let namespace = try managedNamespace.inspect()
            guard namespace.classification == .confirmedAbsent else { throw Failure.resetConflict }
            return (generation, cloudGeneration, namespace)
        }
        return { [self] in
            try serialized {
                guard let ownedReset, ownedReset.manifest.resetID == record.resetID,
                    generation == checkpoint.0, cloudGeneration == checkpoint.1,
                    resetAttempt == nil, try reset.load() == record,
                    try managedNamespace.inspect() == checkpoint.2 else { throw Failure.staleLease }
                try validateFactoryResetRecord(record)
            }
        }
    }

    private func validateFactoryResetRecord(_ record: DeviceLocalResetRecord?) throws {
        guard let ownedReset else { try checkManagedNamespace(); return }
        guard !resetQuarantined, record == nil || (record?.resetID == ownedReset.manifest.resetID &&
            record?.scopeDigest == ownedReset.scope.authorityScope.digest) || record == ownedReset.previousRecord else {
            throw Failure.resetConflict
        }
        try supportAnchorSetup.validateForInspection()
        try ownedReset.scope.authorityScope.validateCurrentPaths()
        guard let adapter = reset as? DeviceLocalResetEvidenceAdapter,
            let durable = try DeviceFactoryResetManifestStore(directory: adapter.resetStore.directory).load(resetID: ownedReset.manifest.resetID),
            try durable.canonicalBytes == ownedReset.manifest.canonicalBytes else { throw Failure.resetConflict }
        try durable.validateStructure()
        if record?.phase != .completed || record?.resetID != durable.resetID { try durable.validateContainerMembership() }
    }
    fileprivate func validateFactoryResetPreparation(_ resetID: UUID) throws {
        try serialized {
            guard let ownedReset, ownedReset.manifest.resetID == resetID, resetAttempt == nil,
                try reset.load() == ownedReset.previousRecord, let origin = ownedReset.origin,
                origin.owner == identity, origin.process == cloudProcess else { throw Failure.resetConflict }
            try origin.installation.verifyManagedNamespace(managedNamespace.inspect())
            try validateFactoryResetRecord(ownedReset.previousRecord)
            guard let withOriginal = ownedReset.withOriginal else { throw Failure.resetConflict }
            try withOriginal {}
        }
    }
    private func quarantineFactoryResetWriters() {
        invalidationActions.append(contentsOf: unifiedInvalidationObservers.values)
        unifiedInvalidationObservers = [:]
        unifiedRoot = nil
        invalidate()
    }
    fileprivate func beginFactoryReset(_ resetID: UUID, record: DeviceLocalResetRecord) throws {
        try validateFactoryResetPreparation(resetID)
        try serialized {
            guard let ownedReset, record.resetID == resetID, ownedReset.manifest.resetID == resetID,
                record.phase == .pending, record.scopeDigest == ownedReset.scope.authorityScope.digest,
                resetAttempt == nil, try reset.load() == ownedReset.previousRecord else { throw Failure.resetConflict }
            try validateFactoryResetRecord(ownedReset.previousRecord)
            guard let origin = ownedReset.origin, origin.owner == identity, origin.process == cloudProcess,
                let withOriginal = ownedReset.withOriginal else { throw Failure.resetConflict }
            try origin.installation.verifyManagedNamespace(managedNamespace.inspect())
            try withOriginal {
                // Keep the genuine complete graph pinned until the original intent is durable.
                resetAttempt = .init(record: record, beginsNew: ownedReset.previousRecord != nil)
                defer { quarantineFactoryResetWriters() }
                try writeResetAttempt()
            }
        }
    }

    enum ResetRecoverySnapshot: Equatable {
        case absent, pending(DeviceLocalResetRecord), completed(DeviceLocalResetRecord), uncertain(DeviceLocalResetRecord)
    }
    func configuredResetScopeDigest() throws -> String {
        try serialized { try reset.scopeDigest }
    }
    /// Recovery evidence only, never Local admission or a cleanup capability.
    func resetRecoverySnapshot() throws -> ResetRecoverySnapshot {
        try serialized {
            guard !resetQuarantined else { throw Failure.resetConflict }
            let digest = try reset.scopeDigest
            if let attempt = resetAttempt {
                guard attempt.record.scopeDigest == digest else { throw Failure.resetConflict }
                // An uncertain journal deliberately fences reads until this literal
                // original write is acknowledged. Validate retained ownership first.
                try validateFactoryResetRecord(attempt.record)
                return .uncertain(attempt.record)
            }
            let record = try reset.load()
            try validateFactoryResetRecord(record)
            if let observedReset, observedReset != record {
                // A reconstructed physical owner may finish through the retained original
                // driver. Admit only its literal original pending -> completed transition.
                guard let ownedReset, ownedReset.origin == nil, observedReset.phase == .pending,
                    record == (try observedReset.completed()), record?.resetID == ownedReset.manifest.resetID,
                    record?.scopeDigest == ownedReset.scope.authorityScope.digest else {
                    resetQuarantined = true; invalidate(); throw Failure.resetConflict
                }
                // validateFactoryResetRecord above checked the same immutable sidecar and marker.
            }
            guard let record else { return .absent }
            let preparedPreviousCompletion = ownedReset?.previousRecord == record && record.phase == .completed && ownedReset?.origin != nil
            guard record.scopeDigest == digest || preparedPreviousCompletion else { throw Failure.resetConflict }
            observedReset = record
            return record.phase == .pending ? .pending(record) : .completed(record)
        }
    }

    func withPendingResetStep(_ record: DeviceLocalResetRecord, operation: () throws -> Void) throws {
        try serialized {
            try validateFactoryResetRecord(try reset.load())
            guard !resetQuarantined, resetAttempt == nil, record.phase == .pending,
                  record.scopeDigest == (try reset.scopeDigest), try reset.load() == record else { throw Failure.resetConflict }
            try operation()
        }
    }
    /// Internal, explicit Local reset only. No cleanup is executed here.
    func beginLocalReset(_ lease: Lease, record: DeviceLocalResetRecord) throws {
        try serialized {
            try checkManagedNamespace()
            defer { invalidate() }
            guard permitted, lease.owner == identity, lease.generation == generation,
                  verifiedEvidence() == evidence, record.phase == .pending,
                  record.scopeDigest == (try reset.scopeDigest), resetAttempt == nil else { throw Failure.resetConflict }
            let previous = try reset.load()
            guard previous == nil || (previous?.phase == .completed && previous?.resetID != record.resetID) else { throw Failure.resetConflict }
            resetAttempt = .init(record: record, beginsNew: previous != nil)
            try writeResetAttempt()
        }
    }
    func recommitResetAttempt() throws {
        try serialized { defer { invalidate() }; try writeResetAttempt() }
    }
    /// Completion is solely the future cleanup caller's assertion; no Cloud meaning.
    func completeLocalReset(expected pending: DeviceLocalResetRecord) throws {
        try serialized {
            try validateFactoryResetRecord(try reset.load())
            defer { invalidate() }
            guard resetAttempt == nil, pending.phase == .pending, pending.scopeDigest == (try reset.scopeDigest),
                  try reset.load() == pending else { throw Failure.resetConflict }
            resetAttempt = .init(record: try pending.completed(), beginsNew: false)
            try writeResetAttempt()
        }
    }
    private func writeResetAttempt() throws {
        guard let attempt = resetAttempt else { throw Failure.noResetAttempt }
        try validateFactoryResetRecord(attempt.record)
        if attempt.beginsNew { try reset.beginNewReset(attempt.record) } else { try reset.save(attempt.record) }
        guard try reset.load() == attempt.record else { throw Failure.resetConflict }
        observedReset = attempt.record
        resetAttempt = nil
        // Owner-mediated reset changes require new classification, never stale contexts.
        evidence = nil
    }

    private func invalidate() {
        invalidateCloud()
        permitted = false; generation = UUID()
        invalidationActions.append(contentsOf: invalidationObservers.values)
        invalidationObservers = [:]
    }
    /// Called only inside the captured management context's authority transaction.
    /// Detached Local keeps the retired installation identity without Cloud authority.
    fileprivate func validateUnifiedLocalAttachmentUnderAuthority(commonRootID: UUID, installationID: UUID) throws {
        let live = try liveUnifiedLocalRoot()
        guard live.root.rootID == commonRootID, live.installationID == installationID else { throw Failure.staleLease }
    }
    fileprivate func qualifiedCloudInstallationIDUnderAuthority() throws -> UUID? {
        guard let context = cloudInstallation else { return nil }
        try checkCloud(context)
        return context.activation.installationId
    }
    fileprivate func acceptLocalCommandIntent() throws { try commandIntents?.acceptLocalIntent() }
    fileprivate func validateKnownLocalDeploymentUnderAuthority(key: String, digest: String) throws -> Bool {
        _ = try liveUnifiedLocalRoot()
        return try commandIntents?.knownDeployment(key: key, digest: digest) ?? false
    }
    fileprivate func acceptLocalDeployment(key: String, digest: String) throws { try commandIntents?.acceptLocalDeployment(key: key, digest: digest) }
    fileprivate func observeInvalidation(_ lease: Lease, _ action: @escaping () -> Void) throws -> UUID {
        try serialized {
            guard permitted, lease.owner == identity, lease.generation == generation else { throw Failure.staleLease }
            let identifier = UUID(); invalidationObservers[identifier] = action; return identifier
        }
    }
    fileprivate func removeInvalidationObserver(_ identifier: UUID) {
        lock.lock(); invalidationObservers.removeValue(forKey: identifier); unifiedInvalidationObservers.removeValue(forKey: identifier); lock.unlock()
    }

    private func serialized<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        guard !executing else { lock.unlock(); throw Failure.reentrantOperation }
        executing = true
        defer {
            executing = false
            let actions = invalidationActions; invalidationActions = []
            lock.unlock()
            for action in actions { action() }
        }
        return try operation()
    }
}

/// Captured Local admission. A context never refreshes or mints a lease.
public struct DeviceManagementContext: @unchecked Sendable {
    private let authority: DeviceManagementAuthority
    private let lease: DeviceManagementAuthority.Lease?
    private let concurrent: DeviceManagementAuthority.CloudInstallationContext?
    private let detached: DeviceManagementAuthority.DetachedLocalContext?
    private let factoryResetID: UUID?
    let commonRootID: UUID?
    var isConcurrent: Bool { concurrent != nil || detached != nil }
    public init(authority: DeviceManagementAuthority, lease: DeviceManagementAuthority.Lease) {
        self.authority = authority; self.lease = lease; concurrent = nil; detached = nil; commonRootID = nil; factoryResetID = nil
    }
    fileprivate init(authority: DeviceManagementAuthority, concurrent: DeviceManagementAuthority.CloudInstallationContext, commonRootID: UUID) {
        self.authority = authority; lease = nil; self.concurrent = concurrent; detached = nil; self.commonRootID = commonRootID; factoryResetID = nil
    }
    fileprivate init(authority: DeviceManagementAuthority, factoryResetID: UUID) {
        self.authority = authority; lease = nil; concurrent = nil; detached = nil; commonRootID = nil; self.factoryResetID = factoryResetID
    }
    fileprivate init(authority: DeviceManagementAuthority, detached: DeviceManagementAuthority.DetachedLocalContext) {
        self.authority = authority; lease = nil; concurrent = nil; self.detached = detached
        commonRootID = detached.commonRootID; factoryResetID = nil
    }
    func belongs(to owner: DeviceManagementAuthority) -> Bool { authority === owner }
    func validateUnifiedLocalAttachmentUnderAuthority(commonRootID: UUID, installationID: UUID) throws {
        try authority.validateUnifiedLocalAttachmentUnderAuthority(commonRootID: commonRootID, installationID: installationID)
    }
    func qualifiedCloudInstallationIDUnderAuthority() throws -> UUID? { try authority.qualifiedCloudInstallationIDUnderAuthority() }
    func acceptCommandIntentUnderAuthority() throws { try authority.acceptLocalCommandIntent() }
    func validateKnownLocalDeploymentUnderAuthority(key: String, digest: String) throws -> Bool {
        try authority.validateKnownLocalDeploymentUnderAuthority(key: key, digest: digest)
    }
    func acceptDeploymentUnderAuthority(key: String, digest: String) throws { try authority.acceptLocalDeployment(key: key, digest: digest) }
    public func validate() throws { if let factoryResetID { try authority.validateFactoryResetPreparation(factoryResetID); return }; try withAuthority {} }
    public func revoke() throws { try authority.revoke() }
    func beginLocalReset(record: DeviceLocalResetRecord) throws { if let factoryResetID { try authority.beginFactoryReset(factoryResetID, record: record); return }; guard let lease else { throw DeviceManagementAuthority.Failure.staleLease }; try authority.beginLocalReset(lease, record: record) }
    func observeInvalidation(_ action: @escaping () -> Void) throws -> UUID {
        if let detached { return try authority.observeDetachedInvalidation(detached, action: action) }
        if let concurrent, let commonRootID { return try authority.observeUnifiedInvalidation(context: concurrent, commonRootID: commonRootID, action: action) }
        guard let lease else { throw DeviceManagementAuthority.Failure.staleLease }
        return try authority.observeInvalidation(lease, action)
    }
    func removeInvalidationObserver(_ identifier: UUID) { authority.removeInvalidationObserver(identifier) }
    // The synchronous closure is internal: callers cannot obtain an escaping unchecked capability.
    func acceptUnifiedLocalIntent(peerPinHex: String, validateApproved: () throws -> Void) throws -> DeviceCommandIntentCoordinator.Checkpoint? {
        // The retained Local wrapper identifies the SAME process owner, while the
        // concurrent route independently validates qualified Cloud/root admission.
        try authority.acceptUnifiedLocalIntent(peerPinHex: peerPinHex, validateApproved: validateApproved)
    }
    func performFixedUnifiedLocalDispatch(command: NativeInstallationUnifiedLocalDispatchCommand,
        peerPinHex: String, checkpoint: DeviceCommandIntentCoordinator.Checkpoint?,
        performApproved: () throws -> NativeInstallationUnifiedLocalDispatchResult) throws -> NativeInstallationUnifiedLocalDispatchResult {
        try authority.performFixedUnifiedLocalDispatch(command: command, peerPinHex: peerPinHex,
            checkpoint: checkpoint, performApproved: performApproved)
    }
    func withAuthority<T>(_ operation: () throws -> T) throws -> T {
        if let detached { return try authority.withDetachedLocalAuthority(detached, operation: operation) }
        if let concurrent, let commonRootID { return try authority.withUnifiedHostAuthority(context: concurrent, commonRootID: commonRootID, operation: operation) }
        guard let lease else { throw DeviceManagementAuthority.Failure.staleLease }
        var result: Result<T, Error>?
        try authority.withLocalAuthority(lease) { result = Result { try operation() } }
        return try result!.get()
    }
}

/// Original in-process step reservation only; no lock crosses journal, backend,
/// SDK, or network calls. Revocation prevents the next step/result publication.
/// This does not exclude hostile same-UID filesystem writers.
private final class FreshEnrollmentStepOwner: NativeFirstEnrollmentOwner, @unchecked Sendable {
    private let authority: DeviceManagementAuthority
    fileprivate let roots: DeviceManagementAuthority.FreshCloudEnrollmentRoots
    private let lock = NSLock()
    private var driving = false
    private var reading = false
    private var qualifiedInstallation: NativeOperationalInstallation?
    private var operationalContext: DeviceManagementAuthority.CloudInstallationContext?
    init(authority: DeviceManagementAuthority, roots: DeviceManagementAuthority.FreshCloudEnrollmentRoots) {
        self.authority = authority; self.roots = roots
    }
    func beginFixedEnrollmentStep() throws {
        lock.lock(); guard !driving, !reading, qualifiedInstallation == nil else { lock.unlock(); throw DeviceManagementAuthority.Failure.staleLease }
        driving = true; lock.unlock()
        do { try authority.validateFreshCloudEnrollmentRoots(roots) }
        catch { lock.lock(); driving = false; lock.unlock(); throw error }
    }
    func validateFixedEnrollmentStep() throws {
        lock.lock(); let active = driving; lock.unlock()
        guard active else { throw DeviceManagementAuthority.Failure.staleLease }
        try authority.validateFreshCloudEnrollmentRoots(roots)
    }
    func qualifyOperationalReads(installation: NativeOperationalInstallation, activation: NativeActivationReceipt) throws {
        try validateFixedEnrollmentStep()
        try installation.validateActivation(activation)
        try installation.requireDurableActivationAssociation(activation)
        try validateFixedEnrollmentStep()
        lock.lock(); qualifiedInstallation = installation; lock.unlock()
    }
    func validateQualifiedInstallation(_ installation: NativeOperationalInstallation) throws {
        lock.lock(); let same = qualifiedInstallation === installation; lock.unlock()
        guard same else { throw DeviceManagementAuthority.Failure.staleLease }
        // Called by Authority under its own serialization immediately before
        // transitioning to the new exact operational generation/context.
    }
    func attachOperationalContext(_ context: DeviceManagementAuthority.CloudInstallationContext) {
        lock.lock(); operationalContext = context; lock.unlock()
    }
    func validateCurrentDispatchOwner(_ candidate: any NativeCurrentInstallationOwner) throws {
        lock.lock(); let context = operationalContext; lock.unlock()
        guard let context, let candidate = candidate as? CurrentInstallationDispatchOwner,
            candidate.belongs(to: authority, context: context) else { throw DeviceManagementAuthority.Failure.staleLease }
        try authority.validateOperationalReadContext(context)
    }
    func validateOperationalContext() throws {
        lock.lock(); let context = operationalContext; lock.unlock()
        guard let context else { throw DeviceManagementAuthority.Failure.staleLease }
        try authority.validateOperationalReadContext(context)
    }
    func validateOperationalOrigin(_ origin: URL) throws {
        lock.lock(); let context = operationalContext; lock.unlock()
        guard let context, Data(origin.absoluteString.utf8) == Data(context.origin.absoluteString.utf8) else {
            throw DeviceManagementAuthority.Failure.staleLease
        }
        try authority.validateOperationalReadContext(context)
    }
    func beginOperationalCredentialRead() throws {
        lock.lock()
        guard !driving, !reading, qualifiedInstallation != nil else { lock.unlock(); throw DeviceManagementAuthority.Failure.staleLease }
        reading = true; let context = operationalContext; lock.unlock()
        do {
            if let context { try authority.validateOperationalReadContext(context) }
            else { try authority.validateFreshCloudEnrollmentRoots(roots) }
        } catch { lock.lock(); reading = false; lock.unlock(); throw error }
    }
    func finishOperationalCredentialRead() throws {
        lock.lock(); let active = reading, context = operationalContext; lock.unlock()
        defer { lock.lock(); reading = false; lock.unlock() }
        guard active else { throw DeviceManagementAuthority.Failure.staleLease }
        if let context { try authority.validateOperationalReadContext(context) }
        else { try authority.validateFreshCloudEnrollmentRoots(roots) }
    }
    func finishFixedEnrollmentStep() throws {
        defer { lock.lock(); driving = false; lock.unlock() }
        try validateFixedEnrollmentStep()
    }
}

private final class CurrentInstallationDispatchOwner: NativeCurrentInstallationOwner, @unchecked Sendable {
    private let authority: DeviceManagementAuthority
    private let context: DeviceManagementAuthority.CloudInstallationContext
    private let startedAt: TimeInterval
    private var checkpoint: DeviceCommandIntentCoordinator.Checkpoint?
    private let acceptanceLock = NSLock()
    private var acceptedCommand: (operationID: UUID, key: String, digest: String)?
    init(authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext, startedAt: TimeInterval, checkpoint: DeviceCommandIntentCoordinator.Checkpoint?) {
        self.checkpoint = checkpoint
        self.authority = authority; self.context = context; self.startedAt = startedAt
    }
    func belongs(to authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) -> Bool {
        self.authority === authority && self.context === context
    }
    private func currentCheckpoint() -> DeviceCommandIntentCoordinator.Checkpoint? {
        acceptanceLock.lock(); defer { acceptanceLock.unlock() }; return checkpoint
    }
    func validateCurrentInstallationDispatch(installation: NativeOperationalInstallation) throws {
        try authority.validateDispatchContext(context, installation: installation, startedAt: startedAt, checkpoint: currentCheckpoint())
    }
    func performFixedUnifiedCloudAcceptance(current: NativeCurrentInstallationDispatch,
        command: NativeInstallationUnifiedCloudAcceptanceCommand) throws -> NativeInstallationUnifiedCloudAcceptanceResult {
        acceptanceLock.lock(); defer { acceptanceLock.unlock() }
        if let acceptedCommand {
            guard acceptedCommand.operationID == command.operationID, acceptedCommand.key == command.key,
                acceptedCommand.digest == command.digest else { throw DeviceManagementAuthority.Failure.staleLease }
        }
        let (result, accepted) = try authority.performFixedUnifiedCloudAcceptance(context,
            startedAt: startedAt, checkpoint: checkpoint, command: command)
        checkpoint = accepted
        acceptedCommand = (command.operationID, command.key, command.digest)
        return result
    }
    func performFixedUnifiedStructuralDispatch(current: NativeCurrentInstallationDispatch,
        command: NativeInstallationUnifiedStructuralDispatchCommand) throws -> NativeInstallationUnifiedStructuralDispatchResult {
        try authority.performFixedUnifiedStructuralDispatch(context, startedAt: startedAt, checkpoint: currentCheckpoint(), command: command)
    }
    func performFixedStructuralDispatch(current: NativeCurrentInstallationDispatch, command: NativeInstallationStructuralDispatchCommand) throws -> NativeInstallationStructuralDispatchResult {
        try authority.performFixedStructuralDispatch(context, startedAt: startedAt, checkpoint: currentCheckpoint(), command: command)
    }
}

private final class FixedAutomaticSelectionOwner: NativeUnifiedAutomationOwner {
    let commonRootID: UUID
    private let authority: DeviceManagementAuthority
    private let context: DeviceManagementAuthority.CloudInstallationContext
    private let checkpoint: DeviceCommandIntentCoordinator.Checkpoint
    init(authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext, commonRootID: UUID,
        checkpoint: DeviceCommandIntentCoordinator.Checkpoint) {
        self.authority = authority; self.context = context; self.commonRootID = commonRootID; self.checkpoint = checkpoint
    }
    func performFixedAutomaticSelection(_ command: NativeInstallationAutomaticSelectionCommand) throws -> NativeInstallationAutomaticSelectionResult {
        try authority.performFixedAutomaticSelection(context: context, commonRootID: commonRootID, checkpoint: checkpoint, command: command)
    }
}
