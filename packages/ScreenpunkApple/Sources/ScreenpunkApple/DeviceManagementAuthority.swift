import Foundation
import Darwin
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
    private var invalidationActions: [() -> Void] = []
    private let reset: any DeviceLocalResetEvidence
    private struct ResetAttempt { let record: DeviceLocalResetRecord; let beginsNew: Bool }
    private var resetAttempt: ResetAttempt?
    private var resetQuarantined = false
    private var observedReset: DeviceLocalResetRecord?
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

    public init(journal: any CloudInstallationTransitionJournal, credentials: CloudInstallationCredentialStore, reset: any DeviceLocalResetEvidence = DeviceLocalResetEvidenceAdapter.production(), managedNamespace: DeviceManagedNamespaceInspector = .production(), supportAnchorSetup: DeviceProductionSupportAnchorSetup = .production()) {
        self.journal = journal
        self.credentials = credentials
        self.reset = reset
        self.managedNamespace = managedNamespace
        self.supportAnchorSetup = supportAnchorSetup
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
            absence: DeviceManagedNamespaceEvidence, reset: DeviceLocalResetRecord?) throws {
            self.owner = owner; self.process = process; self.generation = generation; self.claim = claim
            originalAbsence = absence; resetBaseline = reset; namespace = absence.namespaceURL
            journalRoot = namespace.appendingPathComponent("enrollment", isDirectory: true); cloudRootID = UUID()
            localIDs = try .init(package: UUID(), grant: UUID(), structural: UUID(), provisioning: UUID(), contentGenesis: UUID())
        }
        deinit { for node in nodes.reversed() { close(node.descriptor) }; if anchor >= 0 { close(anchor) } }
    }
    /// Explicit user enrollment intent only. Missing/error history is never converted
    /// into an empty history. Any existing managed namespace is refused, not adopted.
    @_spi(NativeInstallation) public func prepareFreshCloudEnrollmentRoots(claim: NativeClaimInput) throws -> FreshCloudEnrollmentRoots {
        try serialized {
            if let original = freshCloudRoots {
                guard original.claim == claim else { throw Failure.staleLease }
                try checkFreshCloudRoots(original, requireReady: false)
                try createFreshCloudRoots(original); return original
            }
            guard cloudForeground, !managedNamespaceQuarantined, !quarantined, observedHistory == nil,
                try journal.loadEvidence() == nil, try credentials.references().isEmpty else { throw Failure.staleLease }
            let resetBaseline = try cloudResetAllowed()
            try supportAnchorSetup.validateForInspection()
            let absence = try managedNamespace.inspect()
            guard absence.classification == .confirmedAbsent, observedNamespace == nil || observedNamespace == absence else { throw Failure.staleLease }
            // Revoke Local before any creation. Failed initialization stays retained
            // on this SAME owner; namespace presence never reopens Local permission.
            invalidate(); managedNamespaceQuarantined = true
            let original = try FreshCloudEnrollmentRoots(owner: identity, process: cloudProcess, generation: cloudGeneration,
                claim: claim, absence: absence, reset: resetBaseline)
            freshCloudRoots = original
            try createFreshCloudRoots(original); return original
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

    /// Future scene lifecycle calls only; entering never creates or restores admission.
    @_spi(NativeInstallation) public func enterCloudForeground() throws {
        try serialized { if !cloudForeground { invalidateCloud(); cloudForeground = true } }
    }
    @_spi(NativeInstallation) public func leaveCloudForeground() throws {
        try serialized { cloudForeground = false; invalidateCloud() }
    }
    private func invalidateCloud() {
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
        let (started, observation) = try serialized {
            try cloudFresh(context)
            guard let observation = cloudAcceptedObservation else { throw Failure.staleLease }
            return (cloudClock(), observation)
        }
        let owner = CurrentInstallationDispatchOwner(authority: self, context: context, startedAt: started)
        return try context.installation.makeCurrentDispatch(observation: observation, owner: owner)
    }
    fileprivate func validateOperationalReadContext(_ context: CloudInstallationContext) throws {
        try serialized { try checkCloud(context) }
    }
    fileprivate func validateDispatchContext(_ context: CloudInstallationContext, installation: NativeOperationalInstallation, startedAt: TimeInterval) throws {
        try serialized {
            guard context.installation === installation, Self.cloudStatusFresh(requestStartedAt: startedAt, now: cloudClock()) else { throw Failure.staleLease }
            try cloudFresh(context)
        }
    }
    fileprivate func performFixedStructuralDispatch(_ context: CloudInstallationContext,
        startedAt: TimeInterval, command: NativeInstallationStructuralDispatchCommand) throws -> NativeInstallationStructuralDispatchResult {
        try serialized {
            guard Self.cloudStatusFresh(requestStartedAt: startedAt, now: cloudClock()) else { throw Failure.staleLease }
            try cloudFresh(context)
            // Existing fixed synchronous Security inventory/read may run under resource locks.
            // Same-thread reentry rejects via serialized's executing guard; no network/UI.
            let result = try command.performFixedUnderAuthority()
            try cloudFresh(context)
            guard Self.cloudStatusFresh(requestStartedAt: startedAt, now: cloudClock()) else { throw Failure.staleLease }
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
            supportAnchorPending = false
        }
    }

    /// Same owner gates startup, retained rendering, reset and legacy management. Snapshot
    /// checks do not exclude external filesystem writers; future managed writes share this owner.
    func requireLegacyNamespaceAbsent() throws {
        try serialized { try checkManagedNamespace() }
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
        try serialized { invalidate() }
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

    enum ResetRecoverySnapshot: Equatable {
        case absent, pending(DeviceLocalResetRecord), completed(DeviceLocalResetRecord), uncertain(DeviceLocalResetRecord)
    }
    func configuredResetScopeDigest() throws -> String {
        try serialized { try reset.scopeDigest }
    }
    /// Recovery evidence only, never Local admission or a cleanup capability.
    func resetRecoverySnapshot() throws -> ResetRecoverySnapshot {
        try serialized {
            try checkManagedNamespace()
            guard !resetQuarantined else { throw Failure.resetConflict }
            let digest = try reset.scopeDigest
            if let attempt = resetAttempt {
                guard attempt.record.scopeDigest == digest else { throw Failure.resetConflict }
                return .uncertain(attempt.record)
            }
            let record = try reset.load()
            if let observedReset, observedReset != record { resetQuarantined = true; invalidate(); throw Failure.resetConflict }
            guard let record else { return .absent }
            guard record.scopeDigest == digest else { throw Failure.resetConflict }
            observedReset = record
            return record.phase == .pending ? .pending(record) : .completed(record)
        }
    }

    func withPendingResetStep(_ record: DeviceLocalResetRecord, operation: () throws -> Void) throws {
        try serialized {
            try checkManagedNamespace()
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
            try checkManagedNamespace()
            defer { invalidate() }
            guard resetAttempt == nil, pending.phase == .pending, pending.scopeDigest == (try reset.scopeDigest),
                  try reset.load() == pending else { throw Failure.resetConflict }
            resetAttempt = .init(record: try pending.completed(), beginsNew: false)
            try writeResetAttempt()
        }
    }
    private func writeResetAttempt() throws {
        try checkManagedNamespace()
        guard let attempt = resetAttempt else { throw Failure.noResetAttempt }
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
    fileprivate func observeInvalidation(_ lease: Lease, _ action: @escaping () -> Void) throws -> UUID {
        try serialized {
            guard permitted, lease.owner == identity, lease.generation == generation else { throw Failure.staleLease }
            let identifier = UUID(); invalidationObservers[identifier] = action; return identifier
        }
    }
    fileprivate func removeInvalidationObserver(_ identifier: UUID) {
        lock.lock(); invalidationObservers.removeValue(forKey: identifier); lock.unlock()
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
    private let lease: DeviceManagementAuthority.Lease
    public init(authority: DeviceManagementAuthority, lease: DeviceManagementAuthority.Lease) {
        self.authority = authority; self.lease = lease
    }
    func belongs(to owner: DeviceManagementAuthority) -> Bool { authority === owner }
    public func validate() throws { try authority.withLocalAuthority(lease) {} }
    public func revoke() throws { try authority.revoke() }
    func beginLocalReset(record: DeviceLocalResetRecord) throws { try authority.beginLocalReset(lease, record: record) }
    func observeInvalidation(_ action: @escaping () -> Void) throws -> UUID { try authority.observeInvalidation(lease, action) }
    func removeInvalidationObserver(_ identifier: UUID) { authority.removeInvalidationObserver(identifier) }
    // The synchronous closure is internal: callers cannot obtain an escaping unchecked capability.
    func withAuthority<T>(_ operation: () throws -> T) throws -> T {
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
    init(authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext, startedAt: TimeInterval) {
        self.authority = authority; self.context = context; self.startedAt = startedAt
    }
    func belongs(to authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) -> Bool {
        self.authority === authority && self.context === context
    }
    func validateCurrentInstallationDispatch(installation: NativeOperationalInstallation) throws {
        try authority.validateDispatchContext(context, installation: installation, startedAt: startedAt)
    }
    func performFixedStructuralDispatch(current: NativeCurrentInstallationDispatch, command: NativeInstallationStructuralDispatchCommand) throws -> NativeInstallationStructuralDispatchResult {
        try authority.performFixedStructuralDispatch(context, startedAt: startedAt, command: command)
    }
}
