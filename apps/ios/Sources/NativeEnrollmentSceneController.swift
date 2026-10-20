import Foundation
import Darwin
import SwiftUI
import Combine
import OSLog
import CryptoKit
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) @_spi(NativeFilesystem) import ScreenpunkCore
@_spi(NativeInstallation) @_spi(NativeInstallationDriver) import ScreenpunkApple

/// Internal orchestration seam. Production always uses the existing fixed
/// transport; synthetic tests vary URLSession configuration without exposing IO proofs.
protocol NativeSceneDeliveryTransport {
    func send(_ request: NativeOperationalStatusRequest, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeOperationalStatusObservation
    func reportState(_ body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryStateHTTPObservation
    func command(installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryCommandHTTPObservation
    func preparing(_ command: NativeDeliveryCommandHTTPObservation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws
    func superseded(_ progress: NativeUnifiedCommandProgress, installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws
    func failed(_ failure: NativeUnifiedCommandMountFailure, code: NativeUnifiedMountFailureCode, installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws
    func plan(_ command: NativeDeliveryCommandHTTPObservation, nativeOperationID: UUID, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryPlanHTTPObservation
    func archives(_ plan: NativeDeliveryPlanHTTPObservation, current: NativeCurrentInstallationDispatch, target: DeviceProfile, profileID: String, revisionName: String, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryArchiveHTTPObservation
    func activate(_ body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryActivationHTTPObservation
    func receipt(_ body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation) async throws -> NativeDeliveryReceiptHTTPObservation
}
extension NativeInstallationStatusTransport: NativeSceneDeliveryTransport {}

/// One explicit original enrollment in the retained scene. No automatic startup,
/// missing-state import, SDK construction, or historical receipt admission.
@MainActor final class NativeEnrollmentSceneController: ObservableObject {
    enum State: Equatable { case idle, enrolling, needsAttention, screenDeliveryNeedsAttention, currentInstallation }
    enum CloudConnectionState: Equatable { case notConnected, connecting, connected, needsAttention }
    var cloudLocalConnectionInstallationID: UUID? { original?.result?.activation.installationId }
    var cloudConnectionIdentity: UUID? { cloudDisconnected ? nil : (original?.intent ?? retainedIntent)?.enrollmentID }
    /// Device connection is independent of the optional human account session.
    var cloudConnectionState: CloudConnectionState {
        if cloudLogoutCleanupPending { return .needsAttention }
        guard hasRecordedCloudInstallation, !cloudDisconnected else { return .notConnected }
        switch state {
        case .idle, .enrolling: return .connecting
        case .currentInstallation: return cloudDeliveryConnectionNeedsAttention ? .needsAttention : .connected
        case .needsAttention, .screenDeliveryNeedsAttention: return .needsAttention
        }
    }
    @Published private(set) var cloudDeliveryConnectionNeedsAttention = NativeCloudRealtimeConfiguration.enabled
    var cloudConnectionMessage: String? {
        if let deliveryMessage, state == .needsAttention || state == .screenDeliveryNeedsAttention { return deliveryMessage }
        if cloudDeliveryConnectionNeedsAttention {
            return "Screen updates are not connected. Check this device’s internet connection, then tap Retry connection."
        }
        return deliveryMessage
    }
    struct CloudScreenInventory: Equatable {
        struct Entry: Identifiable, Equatable {
            let id: UUID
            let name: String
            let source: String
        }
        let entries: [Entry]
        let selectedEntryID: UUID?
    }
    private struct DisplayInventoryOwner: Equatable {
        let session: ObjectIdentifier, authority: ObjectIdentifier
        let original: ObjectIdentifier?, context: ObjectIdentifier?
    }
    private struct DisplayInventoryProjection {
        let owner: DisplayInventoryOwner, epoch: UUID, generationID: UUID
        let inventory: CloudScreenInventory
        let cloudManifestDigests: Set<String>
        let manifests: [DashboardManifest]
        let hasManifests: Bool
    }
    private struct DisplayMetadataCapture: @unchecked Sendable {
        let association: DeviceUnifiedInventoryAssociation
        let manifests: [DashboardManifest]
        init(session: DeviceUnifiedInventorySession) throws {
            try Task.checkCancellation()
            let metadata = try session.validatedDisplayMetadata()
            association = metadata.association; manifests = metadata.manifests
            try Task.checkCancellation()
        }
    }
    @Published private var displayInventoryProjection: DisplayInventoryProjection?
    private var displayInventoryEpoch = UUID()
    private var displayInventoryForeground = true
    private var displayMetadataTask: Task<Void, Never>?
    private var displayMetadataRequestID: UUID?
    private var pendingDisplayMetadata: (session: DeviceUnifiedInventorySession, owner: DisplayInventoryOwner,
        association: DeviceUnifiedInventoryAssociation)?
    private var displayInventoryOwner: DisplayInventoryOwner? {
        guard displayInventoryForeground, !factoryResetInProgress, !intentRetirementPending else { return nil }
        if !cloudDisconnected, let original, !original.foregroundRevoked, let session = original.unifiedInventory,
            context === original.context, bootstrap?.currentAuthority === original.authority {
            return .init(session: ObjectIdentifier(session), authority: ObjectIdentifier(original.authority),
                original: ObjectIdentifier(original), context: original.context.map(ObjectIdentifier.init))
        }
        guard isCloudLoggedOut, let session = detachedInventory, let context = detachedContext,
            let authority = bootstrap?.currentAuthority else { return nil }
        return .init(session: ObjectIdentifier(session), authority: ObjectIdentifier(authority),
            original: nil, context: ObjectIdentifier(context))
    }
    /// Display metadata only. Layout must never reacquire the resource graph.
    /// Mounts, services and mutations continue to perform their own qualification.
    var displayScreenInventory: CloudScreenInventory? {
        guard let projection = displayInventoryProjection, projection.epoch == displayInventoryEpoch,
            projection.owner == displayInventoryOwner else { return nil }
        if let content {
            guard content.generationID == projection.generationID,
                content.entryID == projection.inventory.selectedEntryID else { return nil }
        } else if let generation = emptyDisplayGeneration {
            guard generation == projection.generationID, projection.inventory.selectedEntryID == nil else { return nil }
        }
        return projection.inventory
    }
    var displayInstalledManifests: [DashboardManifest] {
        guard displayScreenInventory != nil else { return [] }
        return displayInventoryProjection?.manifests ?? []
    }
    var displayCloudInstalledManifests: [DashboardManifest] {
        displayInstalledManifests.filter { displayInventoryProjection?.cloudManifestDigests.contains($0.digest ?? "") == true }
    }
    var hasPendingDisplayMetadataCaptureForTesting: Bool { displayMetadataTask != nil }
    /// Unavailable qualification is distinct from a genuinely qualified empty set.
    func installedCloudScreens() throws -> CloudScreenInventory {
        guard let inventory = displayScreenInventory else { throw CancellationError() }
        return inventory
    }
    private func invalidateDisplayInventory() {
        displayMetadataTask?.cancel(); displayMetadataRequestID = nil
        pendingDisplayMetadata = nil
        displayInventoryEpoch = UUID()
        displayInventoryProjection = nil
    }
    /// Consume an association already qualified by the existing synchronous
    /// transition. This neither validates again nor grants action authority.
    private func retainDisplayInventory(_ association: DeviceUnifiedInventoryAssociation,
        session: DeviceUnifiedInventorySession, manifests: [DashboardManifest]? = nil) {
        guard let owner = displayInventoryOwner, owner.session == ObjectIdentifier(session) else { return }
        let inventory = CloudScreenInventory(entries: association.entries.map {
            .init(id: $0.entryID, name: $0.displayName, source: $0.provenance)
        }, selectedEntryID: association.configuredEntryID)
        if let existing = displayInventoryProjection, existing.owner == owner,
            existing.epoch == displayInventoryEpoch, existing.generationID == association.generationID,
            existing.inventory == inventory, manifests == nil {
            if !existing.hasManifests { captureDisplayMetadata(session: session, owner: owner, association: association) }
            return
        }
        displayInventoryProjection = .init(owner: owner, epoch: displayInventoryEpoch,
            generationID: association.generationID, inventory: inventory,
            cloudManifestDigests: Set(association.entries.filter { $0.provenance == "cloud" }.map(\.manifestDigest)), manifests: manifests ?? [], hasManifests: manifests != nil)
        if manifests == nil { captureDisplayMetadata(session: session, owner: owner, association: association) }
    }
    /// Metadata refresh is controlled by qualified transitions, never view layout.
    /// No authority or resource scope crosses the worker suspension.
    private func captureDisplayMetadata(session: DeviceUnifiedInventorySession, owner: DisplayInventoryOwner,
        association: DeviceUnifiedInventoryAssociation) {
        guard displayMetadataTask == nil else {
            pendingDisplayMetadata = (session, owner, association)
            return
        }
        let id = UUID(), epoch = displayInventoryEpoch
        displayMetadataRequestID = id
        displayMetadataTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.displayMetadataTask = nil
                if self.displayMetadataRequestID == id { self.displayMetadataRequestID = nil }
                if let pending = self.pendingDisplayMetadata {
                    self.pendingDisplayMetadata = nil
                    if self.displayInventoryOwner == pending.owner {
                        self.captureDisplayMetadata(session: pending.session, owner: pending.owner, association: pending.association)
                    }
                }
            }
            do {
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) { try DisplayMetadataCapture(session: session) }
                let metadata = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard self.displayMetadataRequestID == id, self.displayInventoryEpoch == epoch,
                    self.displayInventoryOwner == owner,
                    self.displayInventoryProjection?.generationID == association.generationID,
                    self.displayInventoryProjection?.inventory.selectedEntryID == association.configuredEntryID,
                    metadata.association.generationID == association.generationID,
                    metadata.association.configuredEntryID == association.configuredEntryID else { return }
                self.retainDisplayInventory(metadata.association, session: session, manifests: metadata.manifests)
            } catch { /* Unavailable metadata never grants action authority or clears a qualified screen. */ }
        }
    }

    @Published private(set) var state: State = .idle {
        didSet {
            if state == .currentInstallation, !cloudDisconnected { disconnectMessage = nil }
            updatePresence()
        }
    }
    @Published private(set) var enrollmentProgressMessage: String?
    @Published private(set) var enrollmentDiagnostic: NativeEnrollmentFailureDiagnostic?
    private static let enrollmentLog = Logger(subsystem: "xyz.screenpunk.ios", category: "enrollment")
    private var enrollmentStage: NativeEnrollmentFailureDiagnostic.Stage = .selection
    enum WorkKind: String, CaseIterable {
        case enrollment, reconnect, cloudRelay
        var waitingMessage: String {
            switch self {
            case .enrollment: return "The original device connection is still running…"
            case .reconnect: return "The retained device connection is still being checked…"
            case .cloudRelay: return "The approved screen update is still running…"
            }
        }
    }
    private var task: Task<Void, Never>? {
        didSet { presence.setMainWorkActive(task != nil); updatePresence() }
    }
    private let presence = NativeEnrollmentPresenceScheduler(interval: TimeInterval(NativeCloudRealtimeConfiguration.reconciliationSeconds(
        realtimeEnabled: NativeCloudRealtimeConfiguration.enabled, concurrentControl: ScreenpunkDeviceReleaseQualification.concurrentControl)))
    private let realtime = NativeCloudRealtimeConsumer()
    private var presenceContext: DeviceManagementAuthority.CloudInstallationContext?
    @Published private(set) var cloudLogoutCleanupPending = false { didSet { if oldValue != cloudLogoutCleanupPending { invalidateDisplayInventory() } } }
    @Published private(set) var disconnectInProgress = false { didSet { if disconnectInProgress { invalidateDisplayInventory() } } }
    @Published private(set) var disconnectMessage: String?
    private var cloudDisconnected = false { didSet { if oldValue != cloudDisconnected { invalidateDisplayInventory() } } }
    var isCloudLoggedOut: Bool { cloudDisconnected && !cloudLogoutCleanupPending }
    private var detachedInventory: DeviceUnifiedInventorySession? { didSet { if oldValue !== detachedInventory { invalidateDisplayInventory() } } }
    private var detachedRestoreFailureMessage: String?
    @Published private var recordedDetachedRestorePending = false
    private var detachedRestoreOperationID: UUID?
    private var detachedRestoreEpoch = UUID()
    /// Routing only; discovering a marker never authorizes a screen or Local host.
    var localScreenRestoreInProgress: Bool {
        recordedDetachedRestorePending && isCloudLoggedOut && !hasUnfinishedCloudEnrollment &&
            !factoryResetInProgress && !intentRetirementPending && content == nil && emptyDisplayGeneration == nil
    }
    private var detachedContext: DeviceManagementAuthority.DetachedLocalContext? { didSet { if oldValue !== detachedContext { invalidateDisplayInventory() } } }
    private var retainedCommonRootID: UUID?
    private var cloudCleanup: @MainActor (DeviceDetachedLocalInventoryAssociation, URL) throws -> NativeConfirmedCloudCleanup = {
        try NativeEnrollmentKeychainBackend.cleanupCloudResources(after: $0, namespace: $1)
    }
    var requiresDeviceOwnedStartup: Bool { hasRecordedCloudInstallation || cloudDisconnected }
    private var commonInventoryURL: URL {
        intentJournal.directory.deletingLastPathComponent().appendingPathComponent("xyz.screenpunk.unified-inventory", isDirectory: true)
    }

    private var workKind: WorkKind?
    private var original: Original? { didSet { if oldValue !== original { invalidateDisplayInventory() } } }
    private var intentJournal: NativeEnrollmentIntentJournal
    private var retainedIntent: NativeEnrollmentIntentRecord?
    private var pendingOriginalIntent: NativeEnrollmentIntentRecord?
    private var originalRequestRetention: NativeEnrollmentRequestRetention = .uncertain
    @Published private(set) var intentRetirementPending = false { didSet { if oldValue != intentRetirementPending { invalidateDisplayInventory() } } }
    var hasRecordedCloudInstallation: Bool {
        !factoryResetInProgress && !intentRetirementPending && !cloudDisconnected && retainedIntent?.restoreRecordedInstallation == true
    }
    private weak var bootstrap: DeviceManagementBootstrap? { didSet { if oldValue !== bootstrap { invalidateDisplayInventory() } } }
    @Published private(set) var commonHost: DeviceLANHost?
    private var temporaryPoll: Task<Void, Never>?
    private var temporaryExpiry: Task<Void, Never>?
    private var temporaryDriver: DeviceUnifiedTemporaryActivationDriver?
    init(intentJournal: NativeEnrollmentIntentJournal = .application()) {
        self.intentJournal = intentJournal
        do {
            retainedIntent = try intentJournal.load()
            originalRequestRetention = retainedIntent == nil ? .notSaved : .retained
            // A saved request allocates its common UUID before any namespace is
            // created. Only a physically discovered existing binding can contain
            // a detached attachment; genuine absence is the normal fresh path.
            let existingCommonRootID = try intentJournal.discoverCommonRootID()
            retainedCommonRootID = retainedIntent?.commonInventoryRootID ?? existingCommonRootID
            if let rootID = existingCommonRootID {
                guard retainedIntent?.commonInventoryRootID == nil || retainedIntent?.commonInventoryRootID == rootID else { throw NativeEnrollmentIntentFailure(.changedOriginal) }
                if let detached = try DeviceUnifiedInventorySession.peekDetachedMetadata(commonRoot: commonInventoryURL, commonRootID: rootID) {
                cloudDisconnected = true; cloudLogoutCleanupPending = !detached.cleanupCompleted
                    if !cloudLogoutCleanupPending, retainedIntent?.transitionID == detached.retiredTransitionID { retainedIntent = nil }
                    recordedDetachedRestorePending = detached.cleanupCompleted
                }
            }
            if let retirement = try NativeEnrollmentIntentRetirement(original: intentJournal.directory).load(), retirement.phase != .retired {
                intentRetirementPending = true; state = .needsAttention
                deliveryMessage = "The original device reset has local enrollment cleanup to recover."
            } else if retainedIntent != nil, try DeviceLocalResetStore(directory: DeviceLocalResetStore.defaultDirectory()).load()?.phase == .completed,
                      try NativeEnrollmentIntentRetirement(original: intentJournal.directory).load() == nil {
                intentRetirementPending = true; state = .needsAttention
                deliveryMessage = "The completed reset's enrollment retirement record is missing. Retained files need support review before enrollment."
            }
        }
        catch { enrollmentStage = .originalRequest; reportEnrollmentFailure(error, installationEnrolled: false) }
    }
    /// Isolated guard fixture only: installs no production owner, credential,
    /// namespace or background driver. The supplied task remains caller-owned.
    convenience init(testIntentJournal: NativeEnrollmentIntentJournal, pendingTask: Task<Void, Never>? = nil,
                     workKind: WorkKind? = nil, factoryResetInProgress: Bool = false, intentRetirementPending: Bool = false) {
        self.init(intentJournal: testIntentJournal)
        self.task = pendingTask; self.workKind = workKind
        self.factoryResetInProgress = factoryResetInProgress; self.intentRetirementPending = intentRetirementPending
    }
    /// Original-capability fixture only; no live credential or transport effects.
    convenience init(testRetainedIntentJournal: NativeEnrollmentIntentJournal, lifecycle: CloudHumanSessionLifecycle,
                     authority: DeviceManagementAuthority, roots: DeviceManagementAuthority.FreshCloudEnrollmentRoots?,
                     drainingTask: Task<Void, Never>? = nil) throws {
        self.init(intentJournal: testRetainedIntentJournal)
        guard let intent = retainedIntent else { throw NativeEnrollmentActionFailure.originalChanged }
        let selection = try lifecycle.enrollmentSelection(accountID: intent.accountID, locationID: intent.locationID)
        if let roots { try authority.validateFreshCloudEnrollmentRoots(roots) }
        let proposal = try intent.proposal()
        let target = DeviceProfile(deviceId: proposal.claimInput.transitionId.uuidString.lowercased(), name: intent.name,
            orientation: intent.width > intent.height ? .landscape : .portrait, width: intent.width, height: intent.height)
        let retained = Original(selection: selection, authority: authority, proposal: proposal,
            origin: URL(string: intent.origin)!, name: intent.name, profile: intent.profile, target: target, intent: intent)
        retained.roots = roots; retained.rootsPreparationChosen = roots != nil; original = retained
        observeHumanContext(lifecycle)
        if let drainingTask {
            workKind = .enrollment
            task = Task { [weak self] in
                await drainingTask.value
                self?.task = nil; self?.workKind = nil
            }
        }
    }
    convenience init(testDetachedJournal: NativeEnrollmentIntentJournal, session: DeviceUnifiedInventorySession,
        context: DeviceManagementAuthority.DetachedLocalContext, bootstrap: DeviceManagementBootstrap,
        presentationCheckpoint: (@MainActor (DetachedPresentationCheckpoint) async throws -> Void)? = nil,
        foregroundReconnectObserver: (@MainActor () -> Void)? = nil,
        cleanup: @escaping @MainActor (DeviceDetachedLocalInventoryAssociation, URL) throws -> NativeConfirmedCloudCleanup) throws {
        self.init(intentJournal: testDetachedJournal)
        let association = try session.detachedAssociation()
        try association.validateCurrent()
        guard association.metadata.commonRootID == context.commonRootID,
            association.metadata.retiredInstallationID == context.retiredInstallationID,
            let authority = bootstrap.currentAuthority else { throw CancellationError() }
        try authority.validateDetachedLocalResources(context)
        detachedInventory = session; detachedContext = context; self.bootstrap = bootstrap
        detachedPresentationCheckpoint = presentationCheckpoint
        detachedForegroundReconnectObserver = foregroundReconnectObserver
        retainedCommonRootID = context.commonRootID; cloudDisconnected = true
        cloudLogoutCleanupPending = !association.metadata.cleanupCompleted
        cloudCleanup = cleanup
    }
    /// Observes the real fresh-owner resource validator; it supplies no result,
    /// resource or permission and is absent from production construction.
    convenience init(testColdDetachedJournal: NativeEnrollmentIntentJournal,
        resourceCheckpoint: @escaping @Sendable () throws -> Void,
        presentationCheckpoint: (@MainActor (DetachedPresentationCheckpoint) async throws -> Void)? = nil) {
        self.init(intentJournal: testColdDetachedJournal)
        coldDetachedValidationCheckpoint = resourceCheckpoint
        detachedPresentationCheckpoint = presentationCheckpoint
    }
    private var coldDetachedValidationCheckpoint: (@Sendable () throws -> Void)?
    /// Test fixture teardown closes admission before awaiting every worker it
    /// started. Callers release their own observation gates before draining.
    func drainRetiredWorkForTesting() async {
        let ordinary = task, presentation = detachedPresentationWork?.task
        let metadata = displayMetadataTask, resume = retainedSceneResume
        didEnterBackground()
        if let ordinary { await ordinary.value }
        if let presentation { _ = try? await presentation.value }
        if let metadata { await metadata.value }
        if let resume { await resume.value }
    }
    private var preparedConnectionFixture = false
    private var allowsConcurrentHostInstallation = true
    private var automaticDiscoveryEnabled = true
    private var makeDeliveryTransport: (URL) throws -> any NativeSceneDeliveryTransport = { try NativeInstallationStatusTransport(origin: $0) }
    private var sendMountedObservation: @MainActor (NativeScreenServiceRequest) async throws -> Data = { try await $0.performFixedTransport() }
    private var sendCapability: @MainActor (NativeConcurrentControlCapabilityRequest) async throws -> Void = { try await $0.performFixedTransport() }
    private var sendUnifiedObservation: @MainActor (NativeUnifiedObservationRequest) async throws -> Void = { try await $0.performFixedTransport() }
    private var sendEmptyObservation: @MainActor (NativeMountedEmptyObservationRequest) async throws -> Void = { try await $0.performFixedTransport() }
    /// Composed UI fixture: all enrollment/status/delivery objects were issued by
    /// the real Core pipeline. Only its fixed HTTPS session is test-configured.
    convenience init(testPreparedConnectionJournal: NativeEnrollmentIntentJournal,
        bootstrap: DeviceManagementBootstrap, authority: DeviceManagementAuthority,
        roots: DeviceManagementAuthority.FreshCloudEnrollmentRoots, result: NativeOperationalEnrollmentResult,
        context: DeviceManagementAuthority.CloudInstallationContext, native: NativeDeliveryExecutionSession,
        unified: DeviceUnifiedInventorySession, current: NativeCurrentInstallationDispatch,
        sendUnified: @escaping @MainActor (NativeUnifiedObservationRequest) async throws -> Void,
        sendEmpty: @escaping @MainActor (NativeMountedEmptyObservationRequest) async throws -> Void,
        transportFactory: ((URL) throws -> any NativeSceneDeliveryTransport)? = nil,
        sendMounted: (@MainActor (NativeScreenServiceRequest) async throws -> Data)? = nil,
        sendCapabilities: (@MainActor (NativeConcurrentControlCapabilityRequest) async throws -> Void)? = nil,
        installConcurrentHost: Bool = true, automaticDiscovery: Bool = false) throws {
        self.init(intentJournal: testPreparedConnectionJournal)
        guard let intent = retainedIntent,
            intent.transitionID == result.activation.transitionId,
            intent.accountID == result.activation.accountId, intent.locationID == result.activation.locationId,
            intent.cloudRootID == roots.cloudRootID, bootstrap.currentAuthority === authority else { throw CancellationError() }
        try current.requireInstallationAssociation(result.installation)
        let association = try unified.validatedAssociation()
        guard association.commonRootID == intent.commonInventoryRootID else { throw CancellationError() }
        let proposal = try intent.proposal()
        let target = DeviceProfile(deviceId: intent.transitionID.uuidString.lowercased(), name: intent.name,
            orientation: intent.width > intent.height ? .landscape : .portrait, width: intent.width, height: intent.height)
        let original = Original(selection: nil, authority: authority, proposal: proposal,
            origin: URL(string: intent.origin)!, name: intent.name, profile: intent.profile, target: target, intent: intent)
        original.roots = roots; original.result = result; original.context = context
        original.delivery.session = native; original.unifiedInventory = unified; original.deliveryCurrentDispatch = current
        self.original = original; self.context = context; self.bootstrap = bootstrap
        retainDisplayInventory(association, session: unified)
        self.sendUnifiedObservation = sendUnified; self.sendEmptyObservation = sendEmpty
        if let transportFactory { self.makeDeliveryTransport = transportFactory }
        if let sendMounted { self.sendMountedObservation = sendMounted }
        if let sendCapabilities { self.sendCapability = sendCapabilities }
        self.allowsConcurrentHostInstallation = installConcurrentHost
        preparedConnectionFixture = true; automaticDiscoveryEnabled = automaticDiscovery
    }
    func beginPreparedExplicitConnectionForTesting() throws -> UUID {
        guard preparedConnectionFixture, task == nil, let original else { throw CancellationError() }
        let operationID = admitExplicitConnectionOperation()
        original.explicitOperationID = operationID; state = .enrolling
        return operationID
    }
    func completePreparedExplicitConnectionForTesting(operationID: UUID, current: NativeCurrentInstallationDispatch) throws {
        guard preparedConnectionFixture, task == nil, let original, let unified = original.unifiedInventory,
            original.explicitOperationID == operationID, explicitConnectionOperationID == operationID,
            let result = original.result else { throw CancellationError() }
        try current.requireInstallationAssociation(result.installation)
        original.deliveryCurrentDispatch = current
        let association = try unified.validatedAssociation()
        retainDisplayInventory(association, session: unified)
        guard association.configuredEntryID == nil else { throw CancellationError() }
        try intentJournal.markRecordedInstallation(original.intent); retainedIntent = try intentJournal.load()
        publishEmptyDisplayIfChanged(generation: association.generationID)
        try finishExplicitConnectionDelivery(original, operationID: operationID)
        preparedConnectionFixture = false
    }
    // Internal fixture entry only: normal startup calls this helper after the
    // genuine LAN host starts. Prepared tests qualify driver scheduling without
    // creating simulator Keychain/TLS identities or changing the production path.
    func startPreparedTemporaryActivationForTesting() throws {
        guard preparedConnectionFixture, let original, let unified = original.unifiedInventory else { throw CancellationError() }
        startTemporaryActivation(original, unified: unified)
    }
    func runPreparedDeviceOnlyConnectionForTesting(restorePresentation: Bool = false) async throws {
        guard preparedConnectionFixture, task == nil, let original, let result = original.result,
            let context = original.context else { throw CancellationError() }
        startDeviceOnlyConnection(original, result: result, context: context, restorePresentation: restorePresentation)
        await task?.value
    }
    private var reportedMetadata: NativeEnrollmentDeviceMetadata?
    @Published private(set) var content: DeviceManagedStaticContent?
    @Published private(set) var deliveryMessage: String?
    private(set) var presentationLifetime: DeviceRuntimeLifetime?
    @Published private(set) var retainedDisplayContent: DeviceManagedStaticContent?
    private(set) var retainedDisplayLifetime: DeviceRuntimeLifetime?
    @Published private(set) var candidateMounted = false
    @Published private(set) var emptyDisplayGeneration: UUID?
    @Published private(set) var explicitConnectionOperationID: UUID?
    @Published private(set) var completedExplicitConnectionOperationID: UUID?
    private var preparedRuntime: DeviceUnifiedManagedRuntime?
    enum DetachedPresentationCheckpoint { case preparing, joining }
    // Only the internal detached fixture constructor supplies this checkpoint.
    private var detachedPresentationCheckpoint: (@MainActor (DetachedPresentationCheckpoint) async throws -> Void)?
    private struct DetachedPresentationWork {
        let id: UUID, session: DeviceUnifiedInventorySession
        let context: DeviceManagementAuthority.DetachedLocalContext
        let authority: DeviceManagementAuthority, host: DeviceLANHost
        let generationID: UUID, entryID: UUID
        let task: Task<Void, Error>
    }
    private var detachedPresentationWork: DetachedPresentationWork?
    // Synchronous event observation only; supplied by the internal fixture constructor.
    private var detachedForegroundReconnectObserver: (@MainActor () -> Void)?
    private struct DetachedForegroundReconnect {
        let bootstrap: DeviceManagementBootstrap
        let authority: DeviceManagementAuthority
        let commonRootID: UUID
    }
    private var pendingDetachedForegroundReconnect: DetachedForegroundReconnect?
    private var mountedReportInFlight: ObjectIdentifier?
    private var mountedReportDispatch: NativeCurrentInstallationDispatch?
    private var pendingMountedReport: (content: DeviceManagedStaticContent, lifetime: DeviceRuntimeLifetime,
        dispatch: NativeCurrentInstallationDispatch, original: Original)?
    private var presentationRuntime: DeviceUnifiedManagedRuntime?
    private var retainedDisplayRuntime: DeviceUnifiedManagedRuntime?
    private var presentationHost: DeviceLANHost?
    private var presentationActivityDomain: PresentationActivityDomain = .ordinary
    private var retainedDisplayHost: DeviceLANHost?
    private var retainedDisplayActivityDomain: PresentationActivityDomain = .ordinary
    @Published private var retainedScenePresentationPaused = false
    private var sceneIsForeground = true
    private struct RetainedDetachedScene {
        let id: UUID, pauseID: UUID
        let bootstrap: DeviceManagementBootstrap, authority: DeviceManagementAuthority
        let session: DeviceUnifiedInventorySession, context: DeviceManagementAuthority.DetachedLocalContext
        let host: DeviceLANHost, content: DeviceManagedStaticContent
        let runtime: DeviceUnifiedManagedRuntime, lifetime: DeviceRuntimeLifetime
        let generationID: UUID, entryID: UUID
    }
    // Only immutable association fields cross the worker boundary; no permit or
    // open store scope survives an await. This value is display data, not authority.
    private struct RetainedSceneValidation: @unchecked Sendable {
        let association: DeviceUnifiedInventoryAssociation
        let sameSelection: Bool
    }
    /// Only synchronized authority/session/runtime APIs cross the worker boundary.
    /// UI, host and lifecycle references remain on MainActor.
    private struct RetainedSceneVerifier: @unchecked Sendable {
        let authority: DeviceManagementAuthority
        let context: DeviceManagementAuthority.DetachedLocalContext
        let session: DeviceUnifiedInventorySession
        let runtime: DeviceUnifiedManagedRuntime
        let generationID: UUID
        let entryID: UUID
        func validate() throws -> RetainedSceneValidation {
            try Task.checkCancellation()
            try authority.validateDetachedLocalResources(context)
            let association = try session.validatedAssociation()
            let same = association.generationID == generationID && association.configuredEntryID == entryID
            // Historical mount proof alone is not current-selection authority.
            if same { try runtime.verifyActive() }
            try Task.checkCancellation()
            return RetainedSceneValidation(association: association, sameSelection: same)
        }
    }
    private var retainedDetachedScene: RetainedDetachedScene?
    private var retainedSceneResume: Task<Void, Never>?
    private var retainedSceneResumeID: UUID?
    private var retainedSceneResumeSceneID: UUID?
    private var pendingRetainedSceneReconnect: DetachedForegroundReconnect?
    private var presentationExpiry: Task<Void, Never>?
    private var presentationDispatch: NativeCurrentInstallationDispatch?
    private var humanObservations: [AnyCancellable] = []
    private weak var observedLifecycle: CloudHumanSessionLifecycle?
    private var revocationObserver: UUID?
    private var context: DeviceManagementAuthority.CloudInstallationContext? {
        didSet { if oldValue !== context { invalidateDisplayInventory(); presence.stop(); realtime.stop(); presenceContext = nil } }
    }
    private final class Original {
        let selection: CloudEnrollmentSelection?, authority: DeviceManagementAuthority
        let proposal: NativeFirstEnrollmentPreparation, origin: URL
        let activationRequestID: UUID, associationAttemptID: UUID
        let intent: NativeEnrollmentIntentRecord
        let accountID: UUID, locationID: UUID?, name: String, profile: String
        let target: DeviceProfile
        let delivery: Delivery
        var restoring = false
        var resumeRetainedRequest = false
        var foregroundRevoked = false
        var explicitOperationID: UUID?
        var deliveredExplicitOperationID: UUID?
        var deliveredDisplayGeneration: UUID?
        var confirmedDisplayGeneration: UUID?
        var rootsPreparationChosen = false
        var legacyMigration: DeviceLegacyMigrationSession?
        var unifiedInventory: DeviceUnifiedInventorySession?
        var deliveryCurrentDispatch: NativeCurrentInstallationDispatch?
        var pendingCloudOutcome: NativeDeliveryDurableBody?
        var cloudProgress: NativeUnifiedCommandProgress?
        var requestedCloudOperationID: UUID?
        let relayArchives = NativeRelayArchivePlan()
        var roots: DeviceManagementAuthority.FreshCloudEnrollmentRoots?
        var session: NativeFirstEnrollmentSession?, stores: NativeFirstManagedStores?
        var result: NativeOperationalEnrollmentResult?
        var context: DeviceManagementAuthority.CloudInstallationContext?
        init(selection: CloudEnrollmentSelection?, authority: DeviceManagementAuthority,
             proposal: NativeFirstEnrollmentPreparation, origin: URL, name: String, profile: String, target: DeviceProfile, intent: NativeEnrollmentIntentRecord, retainedDelivery: Delivery? = nil) {
            delivery = retainedDelivery ?? Delivery(intent: intent)
            self.intent = intent; activationRequestID = intent.activationRequestID; associationAttemptID = intent.associationAttemptID
            self.selection = selection; self.authority = authority; self.proposal = proposal; self.origin = origin; self.target = target
            accountID = intent.accountID; locationID = intent.locationID; self.name = name; self.profile = profile
        }
    }
    private final class Delivery {
        let nativeOperationID: UUID, grantOperationID: UUID, grantRevisionID: UUID, activationRequestID: UUID
        init(intent: NativeEnrollmentIntentRecord) {
            nativeOperationID = intent.firstDeliveryNativeOperationID ?? UUID()
            grantOperationID = intent.firstDeliveryGrantOperationID ?? UUID()
            grantRevisionID = intent.firstDeliveryGrantRevisionID ?? UUID()
            activationRequestID = intent.firstDeliveryActivationRequestID ?? UUID()
        }
        var session: NativeDeliveryExecutionSession?
        var stateBody: NativeDeliveryDurableBody?, stateAck: NativeDeliveryStateHTTPObservation?
        var command: NativeDeliveryCommandHTTPObservation?, plan: NativeDeliveryPlanHTTPObservation?, archives: NativeDeliveryArchiveHTTPObservation?
        var prepared = false
        var capabilityReported = false
        var activationBody: NativeDeliveryDurableBody?, authorization: NativeDeliveryActivationHTTPObservation?
        var outcome: NativeDeliveryDurableBody?, acknowledgment: UUID?
    }
    enum PresentationActivityDomain: Equatable { case ordinary, detachedLocal }
    struct PresentationFrame: Identifiable {
        let content: DeviceManagedStaticContent
        let lifetime: DeviceRuntimeLifetime
        let candidate: Bool
        let runtime: DeviceUnifiedManagedRuntime?
        let host: DeviceLANHost?
        let activityDomain: PresentationActivityDomain
        var id: ObjectIdentifier { ObjectIdentifier(lifetime) }
    }
    var presentationFrames: [PresentationFrame] {
        var frames: [PresentationFrame] = []
        if let retainedDisplayContent, let retainedDisplayLifetime {
            frames.append(.init(content: retainedDisplayContent, lifetime: retainedDisplayLifetime, candidate: false, runtime: retainedDisplayRuntime, host: retainedDisplayHost, activityDomain: retainedDisplayActivityDomain))
        }
        if let content, let presentationLifetime {
            frames.append(.init(content: content, lifetime: presentationLifetime, candidate: true, runtime: presentationRuntime, host: presentationHost, activityDomain: presentationActivityDomain))
        }
        return frames
    }
    var hasActiveEnrollmentWork: Bool { task != nil || retainedSceneResume != nil }
    var retainedForegroundRecoveryPending: Bool { original?.foregroundRevoked == true }
    var retainedDeliveryIdentifiersForTesting: [UUID]? {
        original.map { [$0.delivery.nativeOperationID, $0.delivery.grantOperationID,
            $0.delivery.grantRevisionID, $0.delivery.activationRequestID] }
    }
    var retainedAccountID: UUID? { original?.accountID ?? retainedIntent?.accountID ?? pendingOriginalIntent?.accountID }
    var retainedLocationID: UUID? { original != nil ? original?.locationID : (retainedIntent ?? pendingOriginalIntent)?.locationID }
    var retainedDeviceName: String? { original?.name ?? retainedIntent?.name ?? pendingOriginalIntent?.name }
    var retainedDeviceProfile: String? { original?.profile ?? retainedIntent?.profile ?? pendingOriginalIntent?.profile }
    var suggestedDeviceName: String? { captureReportedMetadata()?.name }
    var suggestedDeviceProfile: String? { captureReportedMetadata()?.profile }
    private func captureReportedMetadata() -> NativeEnrollmentDeviceMetadata? {
        if let reportedMetadata { return reportedMetadata }
        let captured = NativeEnrollmentDeviceMetadata.capture()
        reportedMetadata = captured
        return captured
    }
    func enroll(lifecycle: CloudHumanSessionLifecycle, bootstrap: DeviceManagementBootstrap,
                accountID: UUID, locationID: UUID?, name: String, viewport: CGSize) {
        if disconnectInProgress { deliveryMessage = "Disconnecting device…"; return }
        if factoryResetInProgress {
            publishEnrollmentAdmissionBlock(.resetInProgress); return
        }
        if intentRetirementPending {
            publishEnrollmentAdmissionBlock(.retirementPending); return
        }
        if task != nil {
            let diagnostic = NativeEnrollmentFailureDiagnostic(stage: .action, error: NativeEnrollmentActionFailure.busy)
            enrollmentDiagnostic = diagnostic
            enrollmentProgressMessage = workKind?.waitingMessage ?? "The original connection operation is still running…"
            deliveryMessage = diagnostic.message(installationEnrolled: original?.result != nil)
            state = .enrolling
            Self.enrollmentLog.info("Enrollment action retained: stage=action category=busy")
            return
        }
        self.bootstrap = bootstrap
        let operationID = admitExplicitConnectionOperation()
        enrollmentDiagnostic = nil; deliveryMessage = nil
        state = .enrolling
        setEnrollmentStage(.selection)
        do {
            if let original {
                setEnrollmentStage(.originalRequest)
                guard original.accountID == accountID else { throw NativeEnrollmentActionFailure.originalChanged }
                guard original.locationID == locationID,
                    original.name.utf8.elementsEqual(name.utf8) else { throw NativeEnrollmentActionFailure.originalChanged }
                setEnrollmentStage(.authority)
                guard bootstrap.currentAuthority === original.authority else { throw NativeEnrollmentActionFailure.authorityUnavailable }
                if original.foregroundRevoked {
                    setEnrollmentStage(.selection)
                    _ = try reauthorizeRetainedForegroundEnrollment(lifecycle: lifecycle, bootstrap: bootstrap,
                        accountID: accountID, locationID: locationID, name: name)
                    observeHumanContext(lifecycle)
                } else { try requireEnrollmentHumanContext(original) }
            } else {
                setEnrollmentStage(.metadata)
                guard let metadata = captureReportedMetadata() else { throw NativeEnrollmentActionFailure.unsupportedDevice }
                let profile = metadata.profile
                setEnrollmentStage(.viewport)
                let viewport = try NativeEnrollmentActionInput.fullScreenViewport()
                try NativeEnrollmentActionInput.validateViewport(viewport)
                setEnrollmentStage(.selection)
                let selection = try lifecycle.enrollmentSelection(accountID: accountID, locationID: locationID)
                setEnrollmentStage(.authority)
                guard let authority = bootstrap.currentAuthority else { throw NativeEnrollmentActionFailure.authorityUnavailable }
                setEnrollmentStage(.configuration)
                let origin = try CloudNativeConfiguration.load().apiOrigin
                setEnrollmentStage(.originalRequest)
                let intent: NativeEnrollmentIntentRecord
                if cloudDisconnected, let detachedInventory {
                    try intentJournal.retireDisconnectedOriginal(association: detachedInventory.detachedAssociation())
                }
                if let retained = try intentJournal.load() {
                    try NativeEnrollmentActionInput.requireOriginal(retained, accountID: accountID, locationID: locationID, name: name, origin: origin)
                    if let pendingOriginalIntent {
                        try NativeEnrollmentActionInput.requireSameOriginal(retained, pending: pendingOriginalIntent)
                    }
                    try intentJournal.saveOriginal(retained) // Reconfirm exact original publication durability.
                    intent = retained
                    retainedIntent = retained; pendingOriginalIntent = nil; originalRequestRetention = .retained
                } else {
                    originalRequestRetention = .notSaved
                    if let pendingOriginalIntent {
                        try NativeEnrollmentActionInput.requireOriginal(pendingOriginalIntent, accountID: accountID,
                            locationID: locationID, name: name, origin: origin)
                        intent = pendingOriginalIntent
                    } else {
                    intent = try NativeEnrollmentIntentRecord(accountID: accountID, locationID: locationID,
                        name: name, profile: profile, origin: origin, viewport: viewport,
                        legacyDashboardIDs: { if cloudDisconnected { return [] }; if case .localReady(let host) = bootstrap.state {
                            if let set = host.screenSet { return set.screens.map { $0.revision.dashboardId } }
                            return host.server?.store?.load()?.activeStoredRevision.map { [$0.dashboardId] } ?? []
                        }; return [] }(), legacyOwnerPresent: { if cloudDisconnected { return false }; if case .localReady(let host) = bootstrap.state {
                            let saved = host.server?.store?.load(); return saved?.contentOwner != nil || saved?.owner != nil
                        }; return false }(), reusingCommonRootID: cloudDisconnected ? retainedCommonRootID : nil)
                    pendingOriginalIntent = intent
                    }
                    // Durable immutable IDs BEFORE namespace, journal or Keychain effects.
                    try intentJournal.saveOriginal(intent)
                    retainedIntent = intent; pendingOriginalIntent = nil; originalRequestRetention = .retained
                }
                setEnrollmentStage(.layout)
                let proposal = try intent.proposal()
                try NativeFirstEnrollmentSession.validateFirstNativeLayout(proposal)
                let target = DeviceProfile(deviceId: proposal.claimInput.transitionId.uuidString.lowercased(), name: name,
                    orientation: intent.width > intent.height ? .landscape : .portrait,
                    width: intent.width, height: intent.height)
                original = Original(selection: selection, authority: authority, proposal: proposal, origin: origin,
                    name: name, profile: intent.profile, target: target, intent: intent)
                try authority.enterCloudForeground()
                observeHumanContext(lifecycle)
            }
            guard let original else { throw CancellationError() }
            original.explicitOperationID = operationID; original.deliveredExplicitOperationID = nil; original.deliveredDisplayGeneration = nil
            setEnrollmentStage(.legacyMigration)
            if original.legacyMigration == nil, original.intent.legacyMigrationRequired == true,
                case .localReady(let host) = bootstrap.state, let server = host.server,
                    server.store?.load()?.contentOwner != nil || server.store?.load()?.owner != nil {
                    let authority = original.authority, intent = original.intent, target = original.target
                    guard let lease = try authority.refresh(),
                        let packageID = intent.legacyPackageRootID, let grantID = intent.legacyGrantRootID,
                        let structuralID = intent.legacyStructuralRootID, let provisioningID = intent.legacyProvisioningRootID,
                        let commonID = intent.commonInventoryRootID, let entries = intent.legacyEntryIDs,
                        let packageOperations = intent.legacyPackageOperationIDs, let operationID = intent.legacyOperationID,
                        let grantOperationID = intent.legacyGrantOperationID, let generationID = intent.legacyGenerationID,
                        let revisionID = intent.legacyGrantRevisionID else { throw CancellationError() }
                    let ids = try NativeManagedLocalRootIDs(package: packageID, grant: grantID, structural: structuralID,
                        provisioning: provisioningID, contentGenesis: commonID)
                    let roots = try authority.prepareLocalInventoryRoots(lease: lease, ids: ids)
                    let anchor = roots.namespace.deletingLastPathComponent()
                    let legacy = try DeviceLegacyMigrationSession(packageRoot: roots.packageRoot, packageRootID: packageID,
                        grantRoot: roots.grantRoot, grantRootID: grantID, structuralRoot: roots.structuralRoot,
                        structuralRootID: structuralID, provisioningRoot: roots.provisioningRoot, provisioningRootID: provisioningID,
                        legacyStateRoot: DeviceStateStore.defaultRoot(), legacyArchiveRoot: DeviceStateStore.defaultRoot().appendingPathComponent("archives"),
                        resetRoot: anchor.appendingPathComponent("xyz.screenpunk.local-reset"),
                        cloudRoot: anchor.appendingPathComponent("xyz.screenpunk.managed"),
                        managementRoot: anchor.appendingPathComponent("xyz.screenpunk.management"),
                        preferencesRoot: anchor.appendingPathComponent("xyz.screenpunk.preferences"),
                        otherProtectedRoots: [anchor.appendingPathComponent("xyz.screenpunk.unified-inventory")],
                        credentialTransport: NativeEnrollmentKeychainBackend.grantTransport(rootID: grantID),
                        validateRoots: { try authority.validateLocalInventoryRoots(roots) })
                    try server.migrateLegacyInventory(into: legacy, entryIDs: entries, packageOperationIDs: packageOperations,
                        profile: target, profileID: intent.profile, operationID: operationID, grantOperationID: grantOperationID,
                        generationID: generationID, grantRevisionID: revisionID)
                    original.legacyMigration = legacy
                }
            setEnrollmentStage(.managedNamespace)
            if original.roots == nil {
                try original.authority.enterCloudForeground()
                if !original.rootsPreparationChosen {
                    let namespacePresent = try DeviceManagedNamespaceInspector.production().inspect().classification == .managedPresent
                    original.restoring = NativeEnrollmentActionInput.requiresRecordedRoots(
                        installationRecorded: original.intent.restoreRecordedInstallation, namespacePresent: namespacePresent)
                    original.rootsPreparationChosen = true
                }
                if cloudDisconnected, let detachedInventory, let detachedContext {
                    original.roots = try original.authority.prepareCloudEnrollmentAfterDetach(context: detachedContext,
                        association: detachedInventory.detachedAssociation(), claim: original.proposal.claimInput,
                        cloudRootID: original.intent.cloudRootID, localIDs: original.intent.localIDs())
                } else if original.restoring {
                    original.roots = try original.authority.restoreRecordedCloudEnrollmentRoots(claim: original.proposal.claimInput,
                        cloudRootID: original.intent.cloudRootID, localIDs: original.intent.localIDs())
                } else {
                    original.roots = try original.authority.prepareFreshCloudEnrollmentRoots(claim: original.proposal.claimInput,
                        recordedCloudRootID: original.intent.cloudRootID, recordedLocalIDs: original.intent.localIDs())
                }
            }
            guard let roots = original.roots else { throw CancellationError() }
            try requireEnrollmentHumanContext(original)
            if original.result == nil { try original.authority.validateFreshCloudEnrollmentRoots(roots) }
            let reset = DeviceLocalResetStore.defaultDirectory(), stateRoot = DeviceStateStore.defaultRoot()
            setEnrollmentStage(.managedStores)
            if original.stores == nil {
                let protected = NativeEnrollmentActionInput.protectedRoots(stateRoot: stateRoot, reset: reset,
                    journal: roots.journalRoot, management: DeviceManagementTransitionStore.defaultDirectory(),
                    preferences: roots.namespace.deletingLastPathComponent().appendingPathComponent("xyz.screenpunk.preferences"))
                original.stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protected,
                    grantTransport: NativeEnrollmentKeychainBackend.grantTransport(rootID: roots.localIDs.grant))
            }
            setEnrollmentStage(.credentialSession)
            if original.session == nil {
                original.session = try original.authority.makeFirstEnrollmentSession(roots: roots, proposal: original.proposal,
                    excludedLocalResetRoot: reset, storage: NativeEnrollmentKeychainBackend())
            }
            guard let session = original.session, let stores = original.stores else { throw CancellationError() }
            state = .enrolling
            workKind = .enrollment
            task = Task { [weak self] in
                guard let self else { return }
                defer { task = nil; workKind = nil; schedulePendingCloudRelay() }
                await presence.drain()
                do {
                    try Task.checkCancellation(); try requireEnrollmentHumanContext(original)
                    setEnrollmentStage(.enrollment)
                    if original.result == nil {
                        try original.authority.validateFreshCloudEnrollmentRoots(roots)
                        if original.restoring || original.resumeRetainedRequest {
                            original.result = try await session.resumeRetainedOriginal(origin: original.origin, tokenProvider: try requireEnrollmentTokens(original),
                                activationRequestID: original.activationRequestID, associationAttemptID: original.associationAttemptID, stores: stores)
                        } else {
                        original.result = try await session.enroll(origin: original.origin, tokenProvider: try requireEnrollmentTokens(original),
                            activationRequestID: original.activationRequestID, associationAttemptID: original.associationAttemptID, stores: stores)
                        }
                    }
                    if retainedIntent?.restoreRecordedInstallation != true {
                        setEnrollmentStage(.originalRequest)
                        try intentJournal.markRecordedInstallation(original.intent)
                        retainedIntent = try intentJournal.load()
                    }
                    try self.bootstrap?.recordedNativeInstallationDidQualify(authority: original.authority)
                    try Task.checkCancellation(); try requireEnrollmentHumanContext(original)
                    guard let result = original.result else { throw CancellationError() }
                    setEnrollmentStage(.installationBinding)
                    if original.context == nil {
                        try original.authority.validateFreshCloudEnrollmentRoots(roots)
                        original.context = try original.authority.bindOperationalInstallation(installation: result.installation,
                            activation: result.activation, origin: original.origin)
                    }
                    guard let bound = original.context else { throw CancellationError() }
                    context = bound
                    try restoreLegacyMigration(original, context: bound)
                    setEnrollmentStage(.installationStatus)
                    let request = try original.authority.prepareCloudStatusRequest(bound)
                    _ = try await self.makeDeliveryTransport(original.origin).send(request, authority: original.authority, context: bound)
                    try Task.checkCancellation(); try requireEnrollmentHumanContext(original)
                    let current = try original.authority.prepareCurrentInstallationDispatch(bound)
                    setEnrollmentStage(.screenDelivery)
                    try await deliver(original, result: result, current: current, context: bound)
                    try finishExplicitConnectionDelivery(original, operationID: operationID)
                } catch {
                    reportEnrollmentFailure(error, installationEnrolled: original.result != nil)
                }
            }
        } catch { reportEnrollmentFailure(error, installationEnrolled: original?.result != nil) }
    }
    private func admitExplicitConnectionOperation() -> UUID {
        let operationID = UUID()
        explicitConnectionOperationID = operationID; completedExplicitConnectionOperationID = nil
        return operationID
    }
    private func finishExplicitConnectionDelivery(_ original: Original, operationID: UUID) throws {
        enrollmentProgressMessage = nil; enrollmentDiagnostic = nil
        state = .currentInstallation
        original.deliveredExplicitOperationID = operationID
        original.deliveredDisplayGeneration = emptyDisplayGeneration ?? content?.generationID
        try completeExplicitConnectionIfReady(original, operationID: operationID)
    }
    /// Connection completion follows the acknowledged native connection and first
    /// prepared delivery. Actual renderer/empty mount receipts remain independent:
    /// the originating sheet must close before its covered display can appear.
    func requireExplicitConnectionCompletion(operationID: UUID) throws {
        guard completedExplicitConnectionOperationID == operationID, let original else { throw CancellationError() }
        try requireReadyExplicitConnection(original, operationID: operationID)
    }
    private func requireReadyExplicitConnection(_ original: Original, operationID: UUID) throws {
        guard !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress, state == .currentInstallation,
            self.original === original, explicitConnectionOperationID == operationID,
            original.explicitOperationID == operationID, original.deliveredExplicitOperationID == operationID,
            let deliveredGeneration = original.deliveredDisplayGeneration,
            !original.foregroundRevoked, let bound = original.context, context === bound else { throw CancellationError() }
        _ = try original.authority.qualifiedConcurrentControl(context: bound)
        if let empty = emptyDisplayGeneration {
            guard deliveredGeneration == empty, let unified = original.unifiedInventory else { throw CancellationError() }
            let association = try unified.validatedAssociation()
            retainDisplayInventory(association, session: unified)
            guard association.generationID == empty, association.configuredEntryID == nil else { throw CancellationError() }
        } else {
            guard let content, deliveredGeneration == content.generationID else { throw CancellationError() }
            if let unified = original.unifiedInventory {
                let association = try unified.validatedAssociation()
                retainDisplayInventory(association, session: unified)
                guard association.generationID == deliveredGeneration, association.configuredEntryID == content.entryID else { throw CancellationError() }
            }
            try requireCurrentPresentation()
        }
    }
    private func completeExplicitConnectionIfReady(_ original: Original, operationID: UUID) throws {
        guard self.original === original, explicitConnectionOperationID == operationID,
            original.explicitOperationID == operationID, original.deliveredExplicitOperationID == operationID,
            original.deliveredDisplayGeneration != nil, state == .currentInstallation else { return }
        try requireReadyExplicitConnection(original, operationID: operationID)
        completedExplicitConnectionOperationID = operationID
    }
    /// Explicit retry only, after the previous driver drains. Replaces revoked
    /// live capabilities, never the immutable request, delivery or durable evidence.
    @discardableResult func reauthorizeRetainedForegroundEnrollment(lifecycle: CloudHumanSessionLifecycle,
        bootstrap: DeviceManagementBootstrap, accountID: UUID, locationID: UUID?, name: String) throws -> Bool {
        guard !factoryResetInProgress, !intentRetirementPending, task == nil else { throw NativeEnrollmentActionFailure.busy }
        guard let previous = original, previous.foregroundRevoked else { return false }
        guard previous.accountID == accountID, previous.locationID == locationID,
            previous.name.utf8.elementsEqual(name.utf8) else { throw NativeEnrollmentActionFailure.originalChanged }
        guard bootstrap.currentAuthority === previous.authority else { throw NativeEnrollmentActionFailure.authorityUnavailable }
        let selection = try lifecycle.enrollmentSelection(accountID: accountID, locationID: locationID)
        try selection.validate()
        let renewed = Original(selection: selection, authority: previous.authority, proposal: previous.proposal,
            origin: previous.origin, name: previous.name, profile: previous.profile, target: previous.target,
            intent: previous.intent, retainedDelivery: previous.delivery)
        renewed.legacyMigration = previous.legacyMigration
        renewed.resumeRetainedRequest = true
        // Revoked roots/session cannot authorize a new generation. The normal
        // preparation below requalifies physical roots and strict journal/credential
        // replay before any resumed effect. Unknown or orphan state remains blocked.
        original = renewed
        return true
    }
    private func publishEnrollmentAdmissionBlock(_ reason: NativeEnrollmentActionFailure) {
        enrollmentStage = .action
        let diagnostic = NativeEnrollmentFailureDiagnostic(stage: .action, error: reason)
        enrollmentDiagnostic = diagnostic; enrollmentProgressMessage = nil
        deliveryMessage = diagnostic.message(installationEnrolled: false)
        state = .needsAttention
        Self.enrollmentLog.error("Enrollment action blocked: stage=action category=\(diagnostic.category.rawValue, privacy: .public)")
    }
    /// Presence uses the same installation proof, never a human credential or UI operation.
    private func updatePresence() {
        guard automaticDiscoveryEnabled, !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress,
            state == .currentInstallation || state == .screenDeliveryNeedsAttention,
            let original, !original.foregroundRevoked, original.result != nil,
            let bound = original.context, context === bound else { return }
        guard presenceContext !== bound else { return }
        presenceContext = bound
        var discoveredOperationID: UUID?
        var discoveredConfirmation: (DeviceManagedStaticContent, DeviceRuntimeLifetime, NativeCurrentInstallationDispatch)?
        presence.start(onFailure: { [weak self] in
            self?.cloudDeliveryConnectionNeedsAttention = true
        }, afterRequest: { [weak self, weak original] in
            guard let self, let original, self.original === original, self.context === bound,
                !self.disconnectInProgress, !self.factoryResetInProgress, !self.intentRetirementPending else { return }
            if !NativeCloudRealtimeConfiguration.enabled { self.cloudDeliveryConnectionNeedsAttention = false }
            let confirmation = discoveredConfirmation, operationID = discoveredOperationID
            discoveredConfirmation = nil; discoveredOperationID = nil
            if let confirmation {
                self.schedulePendingCloudConfirmation(original, context: bound, content: confirmation.0,
                    lifetime: confirmation.1, current: confirmation.2)
                return
            }
            guard let operationID else { return }
            // The scheduler has released its request before normal delivery
            // takes the main slot and drains foreground discovery.
            original.requestedCloudOperationID = operationID
            self.schedulePendingCloudRelay()
        }) { [weak self, weak original] in
            discoveredOperationID = nil; discoveredConfirmation = nil
            guard let self, let original, self.original === original,
                !self.factoryResetInProgress, !self.intentRetirementPending, !self.disconnectInProgress,
                !original.foregroundRevoked, self.context === bound, original.context === bound else { throw CancellationError() }
            let transport = try self.makeDeliveryTransport(original.origin)
            let request = try original.authority.prepareCloudStatusRequest(bound)
            _ = try await transport.send(request, authority: original.authority, context: bound)
            try Task.checkCancellation()
            guard self.original === original, self.context === bound else { throw CancellationError() }
            guard ScreenpunkDeviceReleaseQualification.concurrentControl,
                original.unifiedInventory != nil, let result = original.result else { return }
            let current = try original.authority.prepareCurrentInstallationDispatch(bound)
            let command = try await transport.command(installation: result.installation, current: current,
                authority: original.authority, context: bound)
            try Task.checkCancellation()
            guard self.original === original, self.context === bound else { throw CancellationError() }
            if command.hasCommand { discoveredOperationID = try command.commandOperationID() }
            // A successful status refresh supersedes the previous dispatch even
            // when the command queue is empty. Keep later mount/service reports
            // on the authenticated current observation for this same context.
            original.deliveryCurrentDispatch = current
            if self.presentationLifetime != nil { self.presentationDispatch = current }
            if self.candidateMounted, let shown = self.content, let lifetime = self.presentationLifetime,
                !lifetime.isRetired, original.confirmedDisplayGeneration != shown.generationID,
                let unified = original.unifiedInventory {
                let configured = try unified.validatedAssociation()
                self.retainDisplayInventory(configured, session: unified)
                if configured.installationID == result.activation.installationId,
                    configured.commonRootID == original.intent.commonInventoryRootID,
                    configured.generationID == shown.generationID, configured.configuredEntryID == shown.entryID,
                    try (original.pendingCloudOutcome != nil || unified.pendingCloudObservation() != nil) {
                    try current.requireInstallationAssociation(result.installation)
                    discoveredConfirmation = (shown, lifetime, current)
                    // Finish the retained original before optional realtime work
                    // can consume this fresh status lease. afterRequest owns the handoff.
                    return
                }
            }
            if NativeCloudRealtimeConfiguration.enabled {
                if !self.realtime.isStarted {
                    do {
                        let session = try await result.installation.makeRealtimeSessionRequest(origin: original.origin, current: current).performFixedTransport()
                        try Task.checkCancellation()
                        guard self.original === original, self.context === bound else { throw CancellationError() }
                        try await self.realtime.start(session, healthChanged: { [weak self] healthy in
                            self?.cloudDeliveryConnectionNeedsAttention = !healthy
                            self?.presence.setInterval(TimeInterval(healthy ? session.reconciliationMaxSeconds : 900))
                        }) { [weak self] in self?.presence.requestReconciliation() }
                    } catch {
                        self.realtime.stop()
                        self.cloudDeliveryConnectionNeedsAttention = true
                        try Task.checkCancellation()
                        // Optional realtime failure retains the bounded reconciliation
                        // fallback and never discards an already authenticated command.
                    }
                }
                self.realtime.acknowledgeReconciliation()
            }
        }
        if NativeCloudRealtimeConfiguration.enabled { presence.requestReconciliation() }
    }
    private func setEnrollmentStage(_ stage: NativeEnrollmentFailureDiagnostic.Stage) {
        enrollmentStage = stage
        Self.enrollmentLog.info("Enrollment stage: \(stage.rawValue, privacy: .public)")
        enrollmentProgressMessage = stage.progressMessage
    }
    private func reportEnrollmentFailure(_ error: Error, installationEnrolled: Bool) {
        completedExplicitConnectionOperationID = nil
        let diagnostic = NativeEnrollmentFailureDiagnostic(stage: enrollmentStage, error: error)
        if let failure = error as? NativeEnrollmentIntentFailure { originalRequestRetention = failure.retention }
        enrollmentDiagnostic = diagnostic; enrollmentProgressMessage = nil
        Self.enrollmentLog.error("Enrollment stopped: stage=\(diagnostic.stage.rawValue, privacy: .public) category=\(diagnostic.category.rawValue, privacy: .public) detail=\(diagnostic.detail ?? "", privacy: .public) installed=\(installationEnrolled, privacy: .public)")
        deliveryMessage = diagnostic.message(installationEnrolled: installationEnrolled, originalRetention: originalRequestRetention)
        state = installationEnrolled ? .screenDeliveryNeedsAttention : .needsAttention
    }
    /// Restores a genuinely completed installation with its device credential. Human account
    /// sign-in is deliberately absent; incomplete enrollment still requires its original user.
    func reconnectInstallation(bootstrap: DeviceManagementBootstrap) {
        guard !factoryResetInProgress, !disconnectInProgress else { return }
        displayInventoryForeground = true
        sceneIsForeground = true
        if retainedSceneResume != nil {
            if retainedDetachedScene?.id != retainedSceneResumeSceneID,
                let authority = bootstrap.currentAuthority, let rootID = retainedCommonRootID {
                pendingRetainedSceneReconnect = .init(bootstrap: bootstrap, authority: authority, commonRootID: rootID)
            }
            return
        }
        if resumeRetainedDetachedScene(bootstrap: bootstrap) { return }
        if cloudDisconnected {
            if content == nil, emptyDisplayGeneration == nil, !hasUnfinishedCloudEnrollment {
                recordedDetachedRestorePending = true
            }
            if task?.isCancelled == true, !intentRetirementPending,
                bootstrap.readyForRecordedNativeRestore || bootstrap.readyToValidateRecordedDetachedRestore,
                bootstrap.currentAuthority != nil, retainedCommonRootID != nil {
                detachedForegroundReconnectObserver?()
                if let authority = bootstrap.currentAuthority, let rootID = retainedCommonRootID {
                    pendingDetachedForegroundReconnect = .init(bootstrap: bootstrap, authority: authority, commonRootID: rootID)
                }
            }
            if detachedInventory == nil { restoreDetachedConnection(bootstrap: bootstrap); return }
            if retainedIntent == nil {
                guard task == nil, let unified = detachedInventory, let candidate = detachedContext,
                    let authority = bootstrap.currentAuthority else { return }
                self.bootstrap = bootstrap
                task = Task { [weak self] in
                    guard let self else { return }
                    defer {
                        task = nil
                        recordedDetachedRestorePending = false
                        replayPendingDetachedForegroundReconnect()
                    }
                    do {
                        try Task.checkCancellation()
                        let admitted = try await verifyDetachedDisplay(unified, context: candidate, authority: authority, acceptSession: true)
                        guard let local = admitted.localContext else { throw CancellationError() }
                        try await installDetachedLocalHost(unified, authority: authority, context: candidate, localContext: local)
                    } catch {
                        guard !(error is CancellationError), !Task.isCancelled,
                            detachedInventory === unified, detachedContext === candidate else { return }
                        logLocalStartupFailure(error, phase: .localHostSetup)
                        disconnectMessage = localConnectionFailureMessage(error)
                    }
                }
                return
            }
        }
        if intentRetirementPending {
            guard let authority = bootstrap.currentAuthority else { return }
            do {
                let retirement = NativeEnrollmentIntentRetirement(original: intentJournal.directory)
                guard let record = try retirement.load() else { throw CancellationError() }
                let identity = try authority.completedFactoryResetIdentity(resetID: record.resetID, scopeDigest: record.scopeDigest)
                try retirement.retire(resetID: identity.resetID, scopeDigest: identity.scopeDigest) { try identity.validateCompletion() }
                intentRetirementPending = false; retainedIntent = nil; original = nil
                intentJournal = .application(); state = .idle
                deliveryMessage = "The original device-local reset cleanup was recovered. Review local sign-in in Cloud account and use Sign out if needed. Your cloud account and projects were preserved."
            } catch {
                state = .needsAttention
                deliveryMessage = "The original reset cleanup needs recovery. Retry device checks; if original files were replaced, preserve them and contact support."
            }
            return
        }
        // An unmarked request may be incomplete, or completion acknowledgement
        // may have been lost. Both require explicit human recovery of the SAME
        // intent; probing device-only restoration here would consume the owner's
        // roots reservation before that explicit recovery can qualify it.
        guard !factoryResetInProgress, task == nil, original == nil, let intent = retainedIntent,
            intent.restoreRecordedInstallation, bootstrap.readyForRecordedNativeRestore,
            let authority = bootstrap.currentAuthority else { return }
        self.bootstrap = bootstrap
        enrollmentDiagnostic = nil; deliveryMessage = nil; state = .enrolling
        var installationEnrolled = false
        setEnrollmentStage(.layout)
        do {
            let proposal = try intent.proposal()
            let origin = try NativeOperationalInstallation.validatedOrigin(URL(string: intent.origin)!)
            try authority.enterCloudForeground()
            setEnrollmentStage(.managedNamespace)
            let roots = try authority.restoreRecordedCloudEnrollmentRoots(claim: proposal.claimInput,
                cloudRootID: intent.cloudRootID, localIDs: intent.localIDs())
            let stateRoot = DeviceStateStore.defaultRoot(), reset = DeviceLocalResetStore.defaultDirectory()
            let protected = NativeEnrollmentActionInput.protectedRoots(stateRoot: stateRoot, reset: reset,
                journal: roots.journalRoot, management: DeviceManagementTransitionStore.defaultDirectory(),
                preferences: roots.namespace.deletingLastPathComponent().appendingPathComponent("xyz.screenpunk.preferences"))
            setEnrollmentStage(.managedStores)
            let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protected,
                grantTransport: NativeEnrollmentKeychainBackend.grantTransport(rootID: roots.localIDs.grant))
            setEnrollmentStage(.credentialSession)
            let session = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal,
                excludedLocalResetRoot: reset, storage: NativeEnrollmentKeychainBackend())
            let result = try session.restoreCompleted(stores: stores)
            installationEnrolled = true
            // Display geometry is a current device observation, not enrollment authority.
            // Keep the saved request unchanged, including installations enrolled while a keyboard was open.
            let viewport = try NativeEnrollmentActionInput.fullScreenViewport()
            let target = DeviceProfile(deviceId: proposal.claimInput.transitionId.uuidString.lowercased(), name: intent.name,
                orientation: viewport.width > viewport.height ? .landscape : .portrait,
                width: Int(viewport.width.rounded()), height: Int(viewport.height.rounded()))
            let restored = Original(selection: nil, authority: authority, proposal: proposal, origin: origin,
                name: intent.name, profile: intent.profile, target: target, intent: intent)
            restored.restoring = true; restored.roots = roots; restored.stores = stores; restored.session = session; restored.result = result
            setEnrollmentStage(.installationBinding)
            let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: origin)
            restored.context = context; original = restored; self.context = context
            try restoreLegacyMigration(restored, context: context)
            startDeviceOnlyConnection(restored, result: result, context: context, restorePresentation: detachedInventory == nil)
        } catch { reportEnrollmentFailure(error, installationEnrolled: installationEnrolled) }
    }
    /// Settings retry uses the saved installation credential and exact retained request.
    /// It never opens an enrollment selection or asks the human session for tokens.
    func retryCloudConnection(bootstrap: DeviceManagementBootstrap) {
        guard !cloudLogoutCleanupPending, hasRecordedCloudInstallation, !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress, task == nil else { return }
        if let original {
            guard let result = original.result, let context = original.context,
                self.context === context, bootstrap.currentAuthority === original.authority,
                !original.foregroundRevoked else { return }
            self.bootstrap = bootstrap
            startDeviceOnlyConnection(original, result: result, context: context,
                restorePresentation: original.unifiedInventory == nil)
        } else { reconnectInstallation(bootstrap: bootstrap) }
    }
    private func startDeviceOnlyConnection(_ original: Original, result: NativeOperationalEnrollmentResult,
        context: DeviceManagementAuthority.CloudInstallationContext, restorePresentation: Bool) {
        presence.stop(); realtime.stop(); presenceContext = nil
        cloudDeliveryConnectionNeedsAttention = false
        enrollmentDiagnostic = nil; deliveryMessage = nil; state = .enrolling
        workKind = .reconnect
        task = Task { [weak self, weak original] in
            guard let self else { return }
            defer { task = nil; workKind = nil; schedulePendingCloudRelay() }
            await presence.drain()
            guard let original, self.original === original, self.context === context else { return }
            do {
                try Task.checkCancellation()
                if restorePresentation {
                    setEnrollmentStage(.screenDelivery)
                    try await restoreCommonPresentation(original, context: context)
                }
                if let unified = original.unifiedInventory, let rootID = original.intent.commonInventoryRootID,
                    try DeviceUnifiedInventorySession.peekPendingCloudDetachMetadata(commonRoot: commonInventoryURL, commonRootID: rootID) != nil {
                    try await finishCloudDisconnect(original, unified: unified, lifecycle: observedLifecycle)
                    return
                }
                setEnrollmentStage(.installationStatus)
                let status = try original.authority.prepareCloudStatusRequest(context)
                _ = try await self.makeDeliveryTransport(original.origin).send(status,
                    authority: original.authority, context: context)
                let current = try original.authority.prepareCurrentInstallationDispatch(context)
                setEnrollmentStage(.screenDelivery)
                try await deliver(original, result: result, current: current, context: context)
                try Task.checkCancellation()
                guard self.original === original, self.context === context else { throw CancellationError() }
                enrollmentProgressMessage = nil; enrollmentDiagnostic = nil; state = .currentInstallation
            } catch { reportEnrollmentFailure(error, installationEnrolled: true) }
        }
    }
    /// Explicit native disconnect. Human sign-out follows the confirmed native
    /// transition; it is never substituted for server revocation.
    func disconnectCloudDevice(lifecycle: CloudHumanSessionLifecycle) async {
        guard !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress else { return }
        disconnectInProgress = true; disconnectMessage = nil
        presence.stop(); realtime.stop(); presenceContext = nil
        original?.requestedCloudOperationID = nil
        let prior = task; prior?.cancel()
        if let prior { await prior.value }
        let operation = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; disconnectInProgress = false; updatePresence() }
            await presence.drain()
            await presence.drainCallbacks()
            do {
                try Task.checkCancellation()
                if let detachedInventory {
                    try await finishDetachedCleanup(detachedInventory, lifecycle: lifecycle)
                    if let detachedContext, let authority = bootstrap?.currentAuthority {
                        let local = try authority.acceptDetachedLocalSession(detachedInventory, context: detachedContext)
                        try await installDetachedLocalHost(detachedInventory, authority: authority, context: detachedContext, localContext: local)
                    }
                } else {
                    guard let original, let unified = original.unifiedInventory else { throw NativeEnrollmentActionFailure.authorityUnavailable }
                    try await finishCloudDisconnect(original, unified: unified, lifecycle: lifecycle)
                }
            } catch {
                disconnectMessage = cloudDisconnected
                    ? (cloudLogoutCleanupPending ? "Cloud is disconnected. Tap Retry log out to finish device cleanup." : "Cloud is disconnected. The local connection could not start.")
                    : "Could not disconnect from Cloud. Try again."
            }
        }
        task = operation
        await operation.value
    }

    private func finishCloudDisconnect(_ original: Original, unified: DeviceUnifiedInventorySession,
        lifecycle: CloudHumanSessionLifecycle?) async throws {
        guard self.original === original, let result = original.result, let context = original.context,
            let rootID = original.intent.commonInventoryRootID else { throw CancellationError() }
        let authority = original.authority
        let detached = try authority.prepareCloudDetachment(context: context, session: unified)
        let pending: DevicePendingCloudDetachMetadata
        if let recorded = try DeviceUnifiedInventorySession.peekPendingCloudDetachMetadata(commonRoot: commonInventoryURL, commonRootID: rootID) {
            guard recorded.installationID == result.activation.installationId else { throw CancellationError() }
            pending = recorded
        } else {
            guard let native = original.delivery.session else { throw CancellationError() }
            let retirement = try result.installation.captureCloudCredentialRetirement(native: native)
            pending = try unified.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
                detachOperationID: UUID(), detachGenerationID: UUID())
        }
        // An idempotent response from the original native bearer is required.
        // An HTTP error, including unauthorized, can never prove revocation.
        let request = try result.installation.makeSelfRevocationRequest(origin: original.origin, activation: result.activation)
        let proof = try await request.performFixedTransport(origin: original.origin)
        try proof.requireInstallation(result.installation)
        let local = try unified.detachCloud(revocation: proof, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID,
            validateDetached: { try authority.validateDetachedLocalResources(detached) },
            validateMutation: { try authority.validateDetachedLocalResources(detached) })
        let localContext = try authority.acceptDetachedLocalSession(local, context: detached)
        detachedInventory = local; detachedContext = detached; retainedCommonRootID = rootID
        cloudDisconnected = true; cloudLogoutCleanupPending = true
        stopCommonHostAndPresentation()
        self.original = nil; self.context = nil
        try await finishDetachedCleanup(local, lifecycle: lifecycle)
        try await installDetachedLocalHost(local, authority: authority, context: detached, localContext: localContext)
    }
    /// Stable IDs for the cleanup CAS are derived from the recorded original
    /// transition. Replaying a lost acknowledgment cannot create another operation.
    private nonisolated static func detachedStepID(_ transition: UUID, _ label: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((transition.uuidString.lowercased() + ":" + label).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
            bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private func finishDetachedCleanup(_ unified: DeviceUnifiedInventorySession,
        lifecycle: CloudHumanSessionLifecycle?) async throws {
        var association = try unified.detachedAssociation()
        try DeviceCloudHomeAssistantStore.shared.revoke(installationID: association.metadata.retiredInstallationID)
        cloudLogoutCleanupPending = !association.metadata.cleanupCompleted
        if cloudLogoutCleanupPending {
            let proof = try cloudCleanup(association, association.credentialRetirement().namespaceURL)
            try unified.finishCloudDetachCleanup(receipt: proof,
                operationID: Self.detachedStepID(association.metadata.retiredTransitionID, "cleanup-operation"),
                generationID: Self.detachedStepID(association.metadata.retiredTransitionID, "cleanup-generation"))
            association = try unified.detachedAssociation()
        }
        cloudLogoutCleanupPending = !association.metadata.cleanupCompleted
        try intentJournal.retireDisconnectedOriginal(association: association)
        // Never retire a later fresh Connect record sharing the same Local root.
        completeDetachedCleanupState(retainedIntent: try intentJournal.load())
        if let lifecycle, let signOut = lifecycle.signOut() {
            await signOut.value
            if lifecycle.coordinator?.signOutState == .failed {
                disconnectMessage = "Device disconnected. Account sign-out needs another try."
            }
        }
    }
    private func completeDetachedCleanupState(retainedIntent: NativeEnrollmentIntentRecord?) {
        self.retainedIntent = retainedIntent; pendingOriginalIntent = nil
        originalRequestRetention = retainedIntent == nil ? .notSaved : .retained
        if let revocationObserver { observedLifecycle?.removeOriginalRevocationObserver(revocationObserver) }
        revocationObserver = nil; humanObservations.removeAll(); observedLifecycle = nil
        cloudDisconnected = true; original = nil; context = nil
        stopCommonHostAndPresentation()
        state = .idle; enrollmentDiagnostic = nil; enrollmentProgressMessage = nil; deliveryMessage = nil
    }
    private func stopCommonHostAndPresentation() {
        temporaryPoll?.cancel(); temporaryPoll = nil; temporaryExpiry?.cancel(); temporaryExpiry = nil
        if let driver = temporaryDriver { Task { await driver.cancel() } }; temporaryDriver = nil
        commonHost?.retireForReset(); commonHost = nil; retirePresentation()
    }
    /// Explicit Local selection resumes only the completed detached device-owned
    /// session. It cannot turn a Cloud installation or unfinished cleanup into Local authority.
    func requestLocalConnection(bootstrap: DeviceManagementBootstrap) async -> String? {
        guard isCloudLoggedOut, !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress else {
            return "Local setup is unavailable while the device connection is being checked."
        }
        displayInventoryForeground = true
        if let retained = retainedDetachedScene {
            reconnectInstallation(bootstrap: bootstrap)
            while let resume = retainedSceneResume { await resume.value }
            if sceneIsForeground, hasRetainedSceneOwner(retained),
                retained.host.isRetainedSceneActivityAllowed() { return nil }
        }
        if let task { await task.value }
        guard isCloudLoggedOut, !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress else {
            return "Local setup is unavailable while the device connection is being checked."
        }
        if detachedInventory == nil {
            restoreDetachedConnection(bootstrap: bootstrap)
            if let task { await task.value }
        }
        if detachedInventory == nil, let detachedRestoreFailureMessage { return detachedRestoreFailureMessage }
        var phase = LocalStartupPhase.localAssociation
        do {
            guard !Task.isCancelled, isCloudLoggedOut, !factoryResetInProgress, !intentRetirementPending,
                !disconnectInProgress, let unified = detachedInventory, let candidate = detachedContext,
                let authority = bootstrap.currentAuthority else { throw CancellationError() }
            phase = .localSessionAccept
            self.bootstrap = bootstrap
            let admitted = try await verifyDetachedDisplay(unified, context: candidate, authority: authority, acceptSession: true)
            guard let localContext = admitted.localContext else { throw CancellationError() }
            phase = .localHostSetup
            try await installDetachedLocalHost(unified, authority: authority, context: candidate, localContext: localContext)
            guard let commonHost, !commonHost.lifetime.isRetired else { throw CancellationError() }
            commonHost.start()
            disconnectMessage = nil
            return nil
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return localConnectionFailureMessage(error) }
            logLocalStartupFailure(error, phase: phase)
            let message = localConnectionFailureMessage(error)
            disconnectMessage = message
            return message
        }
    }
    private enum LocalStartupPhase: String {
        case localAssociation = "local.association", localAuthority = "local.authority"
        case localSessionAccept = "local.sessionAccept", localHostSetup = "local.hostSetup"
        case restoreMetadata = "restore.metadata", restoreAuthority = "restore.authority"
        case restoreAttachmentRecovery = "restore.attachmentRecovery", restoreSourceMetadata = "restore.sourceMetadata"
        case restoreSourceRestore = "restore.sourceRestore", restoreSession = "restore.sessionRestore"
        case restoreSessionAccept = "restore.sessionAccept", restoreCleanup = "restore.cleanup", restoreHostSetup = "restore.hostSetup"
        case hostAdmission = "host.admission", hostAttach = "host.attach", hostHandlers = "host.handlers"
        case hostReadyValidation = "host.readyValidation"
    }
    /// Only fixed vocabulary and exact typed OSStatus; never Error descriptions or payloads.
    private func logLocalStartupFailure(_ error: Error, phase: LocalStartupPhase) {
        let family: String, reason: String
        var status: Int32?
        if let failure = error as? TLSIdentityLoadError {
            family = "tlsIdentity"
            switch failure {
            case .keychain(let value): reason = "keychain"; status = value
            case .corruptMaterial: reason = "corruptMaterial"
            }
        } else if let failure = error as? DeviceManagementAuthority.Failure {
            family = "authority"
            switch failure {
            case .staleLease: reason = "staleLease"
            case .reentrantOperation: reason = "reentrantOperation"
            case .resetConflict: reason = "resetConflict"
            case .noResetAttempt: reason = "noResetAttempt"
            }
        } else if error is CancellationError {
            family = "cancellation"; reason = "cancelled"
        } else if let failure = error as? NativeEnrollmentActionFailure {
            family = "action"
            switch failure {
            case .unsupportedDevice: reason = "unsupportedDevice"
            case .originalChanged: reason = "originalChanged"
            case .authorityUnavailable: reason = "authorityUnavailable"
            case .invalidViewport: reason = "invalidViewport"
            case .busy: reason = "busy"
            case .resetInProgress: reason = "resetInProgress"
            case .retirementPending: reason = "retirementPending"
            }
        } else if let failure = error as? TransferFailure {
            family = "transfer"
            if case .validationFailed = failure { reason = "validationFailed" } else { reason = "other" }
        } else if let failure = NativeEnrollmentLocalFailureDiagnostic.classify(error) {
            family = failure.domain.rawValue; reason = failure.reason.rawValue
        } else {
            family = "unknown"; reason = "unknown"
        }
        let numericStatus = status.map { String($0) } ?? ""
        Self.enrollmentLog.error("Local startup stopped: phase=\(phase.rawValue, privacy: .public) family=\(family, privacy: .public) reason=\(reason, privacy: .public) status=\(numericStatus, privacy: .public)")
    }
    private func localConnectionFailureMessage(_ error: Error) -> String {
        let detail = NativeEnrollmentLocalFailureDiagnostic.classify(error)
            .map { " (\($0.domain.rawValue)/\($0.reason.rawValue))" } ?? ""
        return "The local connection could not start. Try again." + detail
    }

    private struct ColdDetachedPreparation: @unchecked Sendable {
        let authority: DeviceManagementAuthority
        let context: DeviceManagementAuthority.DetachedLocalContext
        let commonRoot: URL, commonRootID: UUID
        let journal: NativeEnrollmentIntentJournal
        let checkpoint: (@Sendable () throws -> Void)?
        func restore() throws -> ColdDetachedPrepared {
            let validate = {
                try Task.checkCancellation()
                try authority.validateDetachedLocalResources(context)
                try checkpoint?()
                try Task.checkCancellation()
            }
            try validate()
            try DeviceUnifiedInventorySession.recommitPendingCloudAttachment(commonRoot: commonRoot,
                commonRootID: commonRootID, validateOriginal: validate)
            let sources = try DeviceUnifiedInventorySession.peekLocalSourceMetadata(commonRoot: commonRoot, commonRootID: commonRootID)
            let legacy = try sources.legacyLocalRoots.isEmpty ? nil : Self.restoreSource(authority: authority,
                context: context, commonRoot: commonRoot, operationID: nil, descriptors: sources.legacyLocalRoots)
            let incoming = try sources.incomingLocal.map { source in
                try DeviceIncomingLocalPreparation(completed: Self.restoreSource(authority: authority,
                    context: context, commonRoot: commonRoot, operationID: source.operationID, descriptors: source.roots), operationID: source.operationID)
            }
            let session = try DeviceUnifiedInventorySession.restoreDetached(local: legacy, incomingLocal: incoming,
                commonRoot: commonRoot, commonRootID: commonRootID, validateOriginal: validate,
                validateMutation: { try authority.validateDetachedLocalResources(context) })
            let localContext = try authority.acceptDetachedLocalSession(session, context: context)
            guard let detached = try DeviceUnifiedInventorySession.peekDetachedMetadata(commonRoot: commonRoot, commonRootID: commonRootID),
                detached.commonRootID == context.commonRootID,
                detached.retiredInstallationID == context.retiredInstallationID else { throw CancellationError() }
            let complete = detached.cleanupCompleted
            var retainedIntent: NativeEnrollmentIntentRecord?
            var display: DetachedDisplayValidation?
            if complete {
                // An absent journal has no retirement mutation to authorize.
                // A retained record still uses its existing exact retirement proof.
                if try journal.load() != nil {
                    try journal.retireDisconnectedOriginal(association: session.detachedAssociation())
                }
                retainedIntent = try journal.load()
                display = try DetachedDisplayVerifier(session: session, authority: authority,
                    context: context, commonRoot: commonRoot).validate(acceptSession: false)
            }
            try validate()
            return .init(session: session, localContext: localContext, completedCleanup: complete,
                retainedIntent: retainedIntent, display: display)
        }
        private static func restoreSource(authority: DeviceManagementAuthority,
            context: DeviceManagementAuthority.DetachedLocalContext, commonRoot: URL, operationID: UUID?,
            descriptors: [DeviceUnifiedLocalSourceAssociation.Root]) throws -> DeviceLegacyMigrationSession {
            guard descriptors.count == 4 else { throw CancellationError() }
            let names = ["packages", "grants", "structural", "provisioning"]
            guard Set(descriptors.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == Set(names) else { throw CancellationError() }
            let ordered = names.compactMap { name in descriptors.first { URL(fileURLWithPath: $0.path).lastPathComponent == name } }
            let ids = try NativeManagedLocalRootIDs(package: ordered[0].rootID, grant: ordered[1].rootID,
                structural: ordered[2].rootID, provisioning: ordered[3].rootID,
                contentGenesis: NativeEnrollmentSceneController.detachedStepID(operationID ?? context.commonRootID, "local-source"))
            let roots = try authority.restoreDetachedLocalInventoryRoots(context: context, operationID: operationID, ids: ids)
            let expected = [roots.packageRoot, roots.grantRoot, roots.structuralRoot, roots.provisioningRoot]
            guard zip(expected, ordered).allSatisfy({ $0.0.standardizedFileURL.path == URL(fileURLWithPath: $0.1.path).standardizedFileURL.path }) else { throw CancellationError() }
            let source = try NativeEnrollmentSceneController.makeLocalSource(authority: authority, roots: roots, commonInventoryURL: commonRoot)
            try source.restoreCompleted()
            return source
        }
    }
    private struct ColdDetachedPrepared: @unchecked Sendable {
        let session: DeviceUnifiedInventorySession
        let localContext: DeviceManagementContext
        let completedCleanup: Bool
        let retainedIntent: NativeEnrollmentIntentRecord?
        let display: DetachedDisplayValidation?
    }
    private struct DetachedDisplayVerifier: @unchecked Sendable {
        let session: DeviceUnifiedInventorySession
        let authority: DeviceManagementAuthority
        let context: DeviceManagementAuthority.DetachedLocalContext
        let commonRoot: URL
        func validate(acceptSession: Bool) throws -> DetachedDisplayValidation {
            try Task.checkCancellation()
            try authority.validateDetachedLocalResources(context)
            guard let before = try DeviceUnifiedInventorySession.peekDetachedMetadata(commonRoot: commonRoot, commonRootID: context.commonRootID),
                before.cleanupCompleted, before.commonRootID == context.commonRootID,
                before.retiredInstallationID == context.retiredInstallationID else { throw CancellationError() }
            // One full exact-current graph qualification also supplies the display
            // association. Cheap detachment reads bind it to the same saved CAS;
            // repeating that graph immediately would add no await/authority fence.
            let metadata = try DisplayMetadataCapture(session: session)
            guard let after = try DeviceUnifiedInventorySession.peekDetachedMetadata(commonRoot: commonRoot, commonRootID: context.commonRootID),
                after.cleanupCompleted, after.commonRootID == before.commonRootID,
                after.retiredInstallationID == before.retiredInstallationID, after.generationID == before.generationID,
                metadata.association.commonRootID == after.commonRootID,
                metadata.association.installationID == after.retiredInstallationID,
                metadata.association.generationID == after.generationID else { throw CancellationError() }
            try authority.validateDetachedLocalResources(context)
            let localContext: DeviceManagementContext?
            if acceptSession { localContext = try authority.acceptDetachedLocalSession(session, context: context) }
            else { localContext = nil }
            return .init(association: metadata.association, manifests: metadata.manifests, localContext: localContext)
        }
    }
    private struct DetachedDisplayValidation: @unchecked Sendable {
        let association: DeviceUnifiedInventoryAssociation
        let manifests: [DashboardManifest]
        let localContext: DeviceManagementContext?
    }
    private func verifyDetachedDisplay(_ unified: DeviceUnifiedInventorySession,
        context: DeviceManagementAuthority.DetachedLocalContext, authority: DeviceManagementAuthority,
        acceptSession: Bool = false) async throws -> DetachedDisplayValidation {
        let epoch = displayInventoryEpoch, restoreEpoch = detachedRestoreEpoch, expectedHost = commonHost
        let verifier = DetachedDisplayVerifier(session: unified, authority: authority, context: context, commonRoot: context.commonRoot)
        let worker = Task.detached(priority: .userInitiated) { try verifier.validate(acceptSession: acceptSession) }
        let metadata = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard sceneIsForeground, displayInventoryEpoch == epoch, detachedRestoreEpoch == restoreEpoch,
            !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress, isCloudLoggedOut, original == nil,
            detachedInventory === unified, detachedContext === context, bootstrap?.currentAuthority === authority,
            commonHost === expectedHost, expectedHost?.lifetime.isRetired != true else { throw CancellationError() }
        retainDisplayInventory(metadata.association, session: unified, manifests: metadata.manifests)
        return metadata
    }
    /// Discovering the marker grants no Local authority: restore all exact roots,
    /// resources and the committed CAS before accepting the new Local context.
    private func restoreDetachedConnection(bootstrap: DeviceManagementBootstrap) {
        guard task == nil, !disconnectInProgress, !factoryResetInProgress, !intentRetirementPending,
            bootstrap.readyForRecordedNativeRestore || (isCloudLoggedOut && bootstrap.readyToValidateRecordedDetachedRestore),
            let authority = bootstrap.currentAuthority, let rootID = retainedCommonRootID else { return }
        self.bootstrap = bootstrap
        detachedRestoreFailureMessage = nil
        let operationID = UUID(), epoch = detachedRestoreEpoch
        detachedRestoreOperationID = operationID
        recordedDetachedRestorePending = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                if detachedRestoreOperationID == operationID {
                    detachedRestoreOperationID = nil; recordedDetachedRestorePending = false
                }
                if self.retainedIntent?.restoreRecordedInstallation == true { reconnectInstallation(bootstrap: bootstrap) }
                else { replayPendingDetachedForegroundReconnect() }
            }
            var phase = LocalStartupPhase.restoreMetadata
            do {
                guard let metadata = try DeviceUnifiedInventorySession.peekDetachedMetadata(commonRoot: commonInventoryURL, commonRootID: rootID) else { throw CancellationError() }
                phase = .restoreAuthority
                if metadata.cleanupCompleted {
                    try bootstrap.validateRecordedDetachedLocalStartup(commonRootID: rootID,
                        retiredInstallationID: metadata.retiredInstallationID)
                } else {
                    guard bootstrap.readyForRecordedNativeRestore else { throw CancellationError() }
                }
                let candidate = try authority.prepareDetachedLocalRestore(commonRootID: rootID,
                    retiredInstallationID: metadata.retiredInstallationID)
                detachedContext = candidate
                phase = .restoreSourceRestore
                let preparation = ColdDetachedPreparation(authority: authority, context: candidate,
                    commonRoot: commonInventoryURL, commonRootID: rootID, journal: intentJournal,
                    checkpoint: coldDetachedValidationCheckpoint)
                let worker = Task.detached(priority: .userInitiated) { try preparation.restore() }
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard sceneIsForeground, detachedRestoreOperationID == operationID, detachedRestoreEpoch == epoch,
                    self.bootstrap === bootstrap, bootstrap.currentAuthority === authority,
                    retainedCommonRootID == rootID, detachedContext === candidate,
                    detachedInventory == nil, isCloudLoggedOut, !disconnectInProgress,
                    !factoryResetInProgress, !intentRetirementPending else { throw CancellationError() }
                let unified = prepared.session
                detachedInventory = unified
                phase = .restoreCleanup
                if prepared.completedCleanup {
                    cloudLogoutCleanupPending = false
                    completeDetachedCleanupState(retainedIntent: prepared.retainedIntent)
                }
                else { try await finishDetachedCleanup(unified, lifecycle: nil) }
                phase = .restoreHostSetup
                try await installDetachedLocalHost(unified, authority: authority, context: candidate,
                    localContext: prepared.localContext, admittedDisplay: prepared.display)
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                logLocalStartupFailure(error, phase: phase)
                state = .needsAttention
                detachedRestoreFailureMessage = localConnectionFailureMessage(error)
                disconnectMessage = detachedRestoreFailureMessage
            }
        }
    }
    /// A foreground event can arrive before cancelled detached work leaves its
    /// defer. Replay that event once, only under the same current owner and roots.
    private func replayPendingDetachedForegroundReconnect() {
        guard let request = pendingDetachedForegroundReconnect else { return }
        pendingDetachedForegroundReconnect = nil
        guard task == nil, cloudDisconnected, original == nil, !factoryResetInProgress,
            !disconnectInProgress, !intentRetirementPending,
            bootstrap === request.bootstrap, request.bootstrap.currentAuthority === request.authority,
            retainedCommonRootID == request.commonRootID,
            request.bootstrap.readyForRecordedNativeRestore || request.bootstrap.readyToValidateRecordedDetachedRestore else { return }
        reconnectInstallation(bootstrap: request.bootstrap)
    }
    private func restoredLocalSource(authority: DeviceManagementAuthority,
        roots: DeviceManagementAuthority.LocalInventoryRoots) throws -> DeviceLegacyMigrationSession {
        let source = try restoredOrNewLocalSource(authority: authority, roots: roots)
        try source.restoreCompleted(); return source
    }
    private func restoredOrNewLocalSource(authority: DeviceManagementAuthority,
        roots: DeviceManagementAuthority.LocalInventoryRoots) throws -> DeviceLegacyMigrationSession {
        try Self.makeLocalSource(authority: authority, roots: roots, commonInventoryURL: commonInventoryURL)
    }
    private nonisolated static func makeLocalSource(authority: DeviceManagementAuthority,
        roots: DeviceManagementAuthority.LocalInventoryRoots, commonInventoryURL: URL) throws -> DeviceLegacyMigrationSession {
        let anchor = roots.namespace.deletingLastPathComponent(), ids = roots.ids
        let source = try DeviceLegacyMigrationSession(packageRoot: roots.packageRoot, packageRootID: ids.package,
            grantRoot: roots.grantRoot, grantRootID: ids.grant, structuralRoot: roots.structuralRoot,
            structuralRootID: ids.structural, provisioningRoot: roots.provisioningRoot, provisioningRootID: ids.provisioning,
            legacyStateRoot: DeviceStateStore.defaultRoot(), legacyArchiveRoot: DeviceStateStore.defaultRoot().appendingPathComponent("archives"),
            resetRoot: DeviceLocalResetStore.defaultDirectory(), cloudRoot: anchor.appendingPathComponent("xyz.screenpunk.managed"),
            managementRoot: DeviceManagementTransitionStore.defaultDirectory(), preferencesRoot: anchor.appendingPathComponent("xyz.screenpunk.preferences"),
            otherProtectedRoots: [commonInventoryURL], credentialTransport: NativeEnrollmentKeychainBackend.grantTransport(rootID: ids.grant),
            validateRoots: { try authority.validateLocalInventoryRoots(roots) })
        return source
    }
    private func installDetachedLocalHost(_ unified: DeviceUnifiedInventorySession, authority: DeviceManagementAuthority,
        context: DeviceManagementAuthority.DetachedLocalContext, localContext: DeviceManagementContext,
        admittedDisplay: DetachedDisplayValidation? = nil) async throws {
        try Task.checkCancellation()
        guard !factoryResetInProgress, !intentRetirementPending, isCloudLoggedOut, original == nil,
            detachedInventory === unified, detachedContext === context,
            let bootstrap, bootstrap.currentAuthority === authority else { throw CancellationError() }
        try localContext.validate()
        // Preserve qualified display metadata even if TLS host creation fails.
        let association: DeviceUnifiedInventoryAssociation
        if let admittedDisplay {
            association = admittedDisplay.association
            retainDisplayInventory(association, session: unified, manifests: admittedDisplay.manifests)
        } else { association = try await verifyDetachedDisplay(unified, context: context, authority: authority).association }
        if commonHost == nil {
            guard suggestedDeviceProfile != nil else { throw NativeEnrollmentActionFailure.unsupportedDevice }
            var phase = LocalStartupPhase.hostAdmission
            let host: DeviceLANHost
            do {
                host = try bootstrap.installConcurrentHost(context: localContext) { host in
                    guard let server = host.server else { throw CancellationError() }
                    phase = .hostAttach
                    try server.attachUnifiedLocalSession(unified)
                    phase = .hostHandlers
                    let journal = intentJournal
                    server.prepareIncomingLocalScreens = { [localTarget = host.runtime.profile] operationID, peer, screens, selected, validateOriginal in
                        let intent = try journal.retainLocalCommand(operationID, installation: context.retiredInstallationID, screens: screens)
                        let roots = try authority.prepareIncomingLocalInventoryRoots(context: localContext, operationID: operationID, ids: intent.rootIDs())
                        let source = try self.restoredOrNewLocalSource(authority: authority, roots: roots)
                        let retained = try screens.map { screen in
                            guard let id = intent.packages[screen.entryIdentity.uuidString.lowercased()] else { throw CancellationError() }
                            return screen.retainingPackagePreparationIdentity(id)
                        }
                        let choice = selected.flatMap { candidate in retained.contains { $0.entryIdentity == candidate } ? candidate : nil } ?? retained.first?.entryIdentity
                        try source.prepareAndCommit(screens: retained, selected: choice, owner: peer, profile: localTarget,
                            profileID: localTarget.deviceId, operationID: operationID, grantOperationID: intent.grantOperation,
                            generationID: intent.generation, grantRevisionID: intent.grantRevision, legacyGrantSet: nil, validateOriginal: validateOriginal)
                        return try DeviceIncomingLocalPreparation(completed: source, operationID: operationID)
                    }
                    server.onCommonContentChanged = { [weak self, weak host] in
                        Task { @MainActor in
                            guard let self, let host, self.detachedInventory === unified, self.commonHost === host,
                                !host.lifetime.isRetired else { return }
                            if !self.sceneIsForeground || self.retainedDetachedScene != nil {
                                return
                            }
                            do { try await self.presentDetachedLocal(unified) }
                            catch {
                                guard !(error is CancellationError), !Task.isCancelled,
                                    self.detachedInventory === unified, self.commonHost === host, !host.lifetime.isRetired else { return }
                                self.deliveryMessage = "The local screen could not be displayed."
                            }
                        }
                    }
                    phase = .hostReadyValidation
                }
            } catch {
                logLocalStartupFailure(error, phase: phase)
                throw error
            }
            commonHost = host; host.start()
        }
        try await presentDetachedLocal(unified, admittedAssociation: association)
    }
    private func presentDetachedLocal(_ unified: DeviceUnifiedInventorySession,
        admittedAssociation: DeviceUnifiedInventoryAssociation? = nil) async throws {
        try Task.checkCancellation()
        guard let candidate = detachedContext, let authority = bootstrap?.currentAuthority,
            let host = commonHost, detachedInventory === unified, !host.lifetime.isRetired else { throw CancellationError() }
        // Installed callbacks capture freshly here. Only the synchronous host
        // admission handoff can supply its existing qualified association.
        let association: DeviceUnifiedInventoryAssociation
        if let admittedAssociation { association = admittedAssociation }
        else { association = try await verifyDetachedDisplay(unified, context: candidate, authority: authority).association }
        if let work = detachedPresentationWork {
            let same = work.session === unified && work.context === candidate && work.authority === authority
                && work.host === host && work.generationID == association.generationID
                && work.entryID == association.configuredEntryID
            try await detachedPresentationCheckpoint?(.joining)
            do { try await work.task.value }
            catch { if same { throw error } }
            // A different owner/selection waits for old work to finish before any
            // new runtime can replace Core's presentation identity.
            try Task.checkCancellation()
            return try await presentDetachedLocal(unified)
        }
        guard let entryID = association.configuredEntryID else {
            try await prepareDetachedPresentation(unified, candidate: candidate, authority: authority, host: host,
                generationID: association.generationID, entryID: nil)
            return
        }
        let id = UUID()
        let work = Task { @MainActor in
            defer { if self.detachedPresentationWork?.id == id { self.detachedPresentationWork = nil } }
            try await self.prepareDetachedPresentation(unified, candidate: candidate, authority: authority, host: host,
                generationID: association.generationID, entryID: entryID)
        }
        detachedPresentationWork = .init(id: id, session: unified, context: candidate, authority: authority,
            host: host, generationID: association.generationID, entryID: entryID, task: work)
        try await work.value
        try Task.checkCancellation()
    }
    private func hasCurrentDetachedFrame(generationID: UUID, entryID: UUID) -> Bool {
        guard let content, let lifetime = presentationLifetime, !lifetime.isRetired,
            content.generationID == generationID, content.entryID == entryID,
            let runtime = presentationRuntime else { return false }
        return runtime.content === content
    }
    private func prepareDetachedPresentation(_ unified: DeviceUnifiedInventorySession,
        candidate: DeviceManagementAuthority.DetachedLocalContext, authority: DeviceManagementAuthority,
        host: DeviceLANHost, generationID: UUID, entryID: UUID?) async throws {
        guard commonHost === host else { throw CancellationError() }
        let association = try await verifyDetachedDisplay(unified, context: candidate, authority: authority).association
        guard commonHost === host, association.generationID == generationID, association.configuredEntryID == entryID else { throw CancellationError() }
        guard let entryID else {
            publishEmptyDisplayIfChanged(generation: generationID)
            return
        }
        if hasCurrentDetachedFrame(generationID: generationID, entryID: entryID) { return }
        var admitted = association
        if let detachedPresentationCheckpoint {
            try await detachedPresentationCheckpoint(.preparing)
            admitted = try await verifyDetachedDisplay(unified, context: candidate, authority: authority).association
        }
        guard commonHost === host, admitted.generationID == generationID, admitted.configuredEntryID == entryID else { throw CancellationError() }
        let next = try await prepareUnifiedContent(unified,
            operationID: Self.detachedStepID(generationID, "display"), admittedAssociation: admitted)
        do {
            let current = try await verifyDetachedDisplay(unified, context: candidate, authority: authority).association
            guard commonHost === host, current.generationID == generationID, current.configuredEntryID == entryID else {
                throw CancellationError()
            }
            // This is the sole detached issuer. Once Core binds next it must be
            // staged, never discarded in favor of an earlier projected object.
            stagePresentation(next, current: nil, activityDomain: .detachedLocal)
            recordedDetachedRestorePending = false
        } catch {
            if preparedRuntime?.content === next { preparedRuntime = nil }
            throw error
        }
    }
    private func requireEnrollmentTokens(_ original: Original) throws -> any CloudNativeTokenProvider {
        guard let selection = original.selection else { throw CancellationError() }
        try selection.validate(); return selection.tokens
    }
    /// Human authorization is required until enrollment finishes. Device operations thereafter
    /// are authorized by the retained installation credential and current authority lease.
    private func requireEnrollmentHumanContext(_ original: Original) throws {
        if original.result == nil { guard let selection = original.selection else { throw CancellationError() }; try selection.validate() }
    }
    private func restoreLegacyMigration(_ original: Original, context: DeviceManagementAuthority.CloudInstallationContext) throws {
        guard original.legacyMigration == nil, original.intent.legacyMigrationRequired == true else { return }
        let intent = original.intent
        guard let packageID = intent.legacyPackageRootID, let grantID = intent.legacyGrantRootID,
            let structuralID = intent.legacyStructuralRootID, let provisioningID = intent.legacyProvisioningRootID,
            let commonID = intent.commonInventoryRootID else { throw CancellationError() }
        let ids = try NativeManagedLocalRootIDs(package: packageID, grant: grantID, structural: structuralID,
            provisioning: provisioningID, contentGenesis: commonID)
        let roots = try original.authority.restoreRecordedLocalInventoryRoots(context: context, ids: ids)
        let anchor = roots.namespace.deletingLastPathComponent()
        let session = try DeviceLegacyMigrationSession(packageRoot: roots.packageRoot, packageRootID: packageID,
            grantRoot: roots.grantRoot, grantRootID: grantID, structuralRoot: roots.structuralRoot,
            structuralRootID: structuralID, provisioningRoot: roots.provisioningRoot, provisioningRootID: provisioningID,
            legacyStateRoot: DeviceStateStore.defaultRoot(), legacyArchiveRoot: DeviceStateStore.defaultRoot().appendingPathComponent("archives"),
            resetRoot: anchor.appendingPathComponent("xyz.screenpunk.local-reset"), cloudRoot: anchor.appendingPathComponent("xyz.screenpunk.managed"),
            managementRoot: anchor.appendingPathComponent("xyz.screenpunk.management"), preferencesRoot: anchor.appendingPathComponent("xyz.screenpunk.preferences"),
            otherProtectedRoots: [anchor.appendingPathComponent("xyz.screenpunk.unified-inventory")],
            credentialTransport: NativeEnrollmentKeychainBackend.grantTransport(rootID: grantID),
            validateRoots: { try original.authority.validateLocalInventoryRoots(roots) })
        try session.restoreCompleted()
        original.legacyMigration = session
    }
    private func observeHumanContext(_ lifecycle: CloudHumanSessionLifecycle) {
        humanObservations.removeAll()
        if let id = revocationObserver { observedLifecycle?.removeOriginalRevocationObserver(id) }
        observedLifecycle = lifecycle
        revocationObserver = lifecycle.observeOriginalRevocation { [weak self] in
            guard let self, self.original?.result == nil else { return }
            self.didEnterBackground()
        }
        let changed: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let original = self.original else { return }
                do { try requireEnrollmentHumanContext(original) }
                catch { self.didEnterBackground() }
            }
        }
        humanObservations.append(lifecycle.objectWillChange.sink { changed() })
        if let coordinator = lifecycle.coordinator { humanObservations.append(coordinator.objectWillChange.sink { changed() }) }
    }
    private func deliver(_ original: Original, result: NativeOperationalEnrollmentResult,
        current: NativeCurrentInstallationDispatch, context: DeviceManagementAuthority.CloudInstallationContext) async throws {
        let d = original.delivery, transport = try self.makeDeliveryTransport(original.origin)
        try requireEnrollmentHumanContext(original); try Task.checkCancellation()
        if !d.capabilityReported {
            let capability = try result.installation.makeConcurrentControlCapabilityRequest(origin: original.origin,
                current: current, qualified: original.authority.qualifiedConcurrentControl(context: context))
            try await sendCapability(capability); d.capabilityReported = true
        }
        if let unified = original.unifiedInventory {
            try await deliverCommon(original, result: result, current: current, context: context, unified: unified)
            return
        }
        guard original.intent.firstDeliveryNativeOperationID != nil, original.intent.firstDeliveryGrantOperationID != nil,
            original.intent.firstDeliveryGrantRevisionID != nil, original.intent.firstDeliveryActivationRequestID != nil else { throw CancellationError() }
        if d.session == nil { d.session = try result.installation.makeDeliveryExecutionSession(current: current) }
        guard let session = d.session else { throw CancellationError() }
        if d.stateBody == nil { d.stateBody = try session.freshGenesisObservation(current: current) }
        if d.stateAck == nil, let body = d.stateBody {
            d.stateAck = try await transport.reportState(body, installation: result.installation, current: current,
                authority: original.authority, context: context)
        }
        if try original.authority.qualifiedConcurrentControl(context: context) {
            guard let rootID = original.intent.commonInventoryRootID,
                let operationID = original.intent.unifiedMigrationOperationID,
                let generationID = original.intent.unifiedMigrationGenerationID else { throw CancellationError() }
            let unified: DeviceUnifiedInventorySession
            if let detachedInventory, let detachedContext {
                commonHost?.retireForReset(); commonHost = nil
                unified = try original.authority.reattachCloudInventory(detached: detachedInventory,
                    detachedContext: detachedContext, context: context, native: session, current: current,
                    operationID: operationID, generationID: generationID)
                cloudDisconnected = false; disconnectMessage = nil; self.detachedInventory = nil; self.detachedContext = nil
                guard let body = d.stateBody, let acknowledged = d.stateAck else { throw NativeDeliveryExecutionError.association }
                try unified.retainCloudCheckpoint(authenticatedGenerationID: acknowledged.acceptedGenerationID(body: body, installation: result.installation))
            } else {
                unified = try original.authority.makeUnifiedInventorySession(context: context, current: current,
                    commonRootID: rootID, local: original.legacyMigration, native: session)
            }
            if try !unified.restoreCompleted(current: current) {
                try unified.migrate(current: current, operationID: operationID, generationID: generationID, admissionEnabled: true)
                guard let body = d.stateBody, let acknowledged = d.stateAck else { throw NativeDeliveryExecutionError.association }
                let baseline = try acknowledged.acceptedGenerationID(body: body, installation: result.installation)
                try unified.retainCloudCheckpoint(authenticatedGenerationID: baseline)
            }
            original.unifiedInventory = unified
            original.deliveryCurrentDispatch = current
            try installCommonHost(original, context: context, unified: unified)
            let association = try unified.validatedAssociation()
            retainDisplayInventory(association, session: unified)
            if association.configuredEntryID == nil {
                retirePresentation(); emptyDisplayGeneration = association.generationID
            } else {
                let snapshot = try await prepareUnifiedContent(unified, operationID: operationID)
                stagePresentation(snapshot, current: current)
            }
            try await deliverCommon(original, result: result, current: current, context: context, unified: unified)
            return
        }
        try requireEnrollmentHumanContext(original); try Task.checkCancellation()
        if d.command == nil {
            let command = try await transport.command(installation: result.installation, current: current,
                authority: original.authority, context: context)
            try requireEnrollmentHumanContext(original); try Task.checkCancellation()
            guard command.hasCommand else { deliveryMessage = "No screen is ready yet. Publish a screen, then check again."; return }
            try await transport.preparing(command, current: current, authority: original.authority, context: context)
            d.command = command
        }
        if d.plan == nil, let command = d.command {
            d.plan = try await transport.plan(command, nativeOperationID: d.nativeOperationID, current: current,
                authority: original.authority, context: context)
        }
        try requireEnrollmentHumanContext(original); try Task.checkCancellation()
        if d.archives == nil, let plan = d.plan {
            d.archives = try await transport.archives(plan, current: current, target: original.target,
                profileID: original.profile, revisionName: original.name, authority: original.authority, context: context)
        }
        try requireEnrollmentHumanContext(original); try Task.checkCancellation()
        if !d.prepared {
            guard let archives = d.archives else { throw CancellationError() }
            try archives.prepare(session: session, grantOperationID: d.grantOperationID, grantRevisionID: d.grantRevisionID)
            d.prepared = true
        }
        if d.activationBody == nil { d.activationBody = try session.retainActivationRequest(requestID: d.activationRequestID) }
        if d.authorization == nil, let body = d.activationBody {
            d.authorization = try await transport.activate(body, installation: result.installation, current: current,
                authority: original.authority, context: context)
        }
        try requireEnrollmentHumanContext(original); try Task.checkCancellation()
        guard let activationBody = d.activationBody, let authorization = d.authorization else { throw CancellationError() }
        if d.outcome == nil {
            try session.retainAuthorization(requestBody: activationBody, observation: authorization)
            d.outcome = try session.dispatchAndRetainActivatedOutcome(current: current)
        }
        original.deliveryCurrentDispatch = current
        var snapshot = try session.completedStaticContent(current: current)
        do {
            if original.unifiedInventory == nil {
                guard let rootID = original.intent.commonInventoryRootID else { throw CancellationError() }
                original.unifiedInventory = try original.authority.makeUnifiedInventorySession(context: context, current: current,
                    commonRootID: rootID, local: original.legacyMigration, native: session)
                guard let unified = original.unifiedInventory else { throw CancellationError() }
                if try !unified.restoreCompleted(current: current) {
                    guard let operationID = original.intent.unifiedMigrationOperationID,
                        let generationID = original.intent.unifiedMigrationGenerationID else { throw CancellationError() }
                    try unified.migrate(current: current, operationID: operationID, generationID: generationID,
                        admissionEnabled: try original.authority.qualifiedConcurrentControl(context: context))
                }
            }
            guard let unified = original.unifiedInventory else { throw CancellationError() }
            try unified.retainCloudCheckpoint(authenticatedGenerationID: snapshot.generationID)
            while let observation = try unified.pendingCloudObservation() {
                let request = try result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                    current: current, observation: observation)
                try await request.performFixedTransport()
            }
            snapshot = try await prepareUnifiedContent(unified, operationID: snapshot.operationID)
            try installCommonHost(original, context: context, unified: unified)
        }
        try current.requirePresentationCurrent(); try requireEnrollmentHumanContext(original)
        stagePresentation(snapshot, current: current)
        let lifetime = presentationLifetime
        deliveryMessage = "Screen prepared. Waiting for the display to mount."
        if original.unifiedInventory == nil {
        presentationExpiry = Task { [weak self, weak lifetime] in
            do { try await current.waitForPresentationExpiry() }
            catch { if Task.isCancelled { return } }
            guard let self, self.presentationLifetime === lifetime else { return }
            self.retirePresentation(); self.deliveryMessage = "Connection verification expired. Check again to display the screen." 
        }
        }
    }
    private func deliverCommon(_ original: Original, result: NativeOperationalEnrollmentResult,
        current: NativeCurrentInstallationDispatch, context: DeviceManagementAuthority.CloudInstallationContext,
        unified: DeviceUnifiedInventorySession) async throws {
        let transport = try self.makeDeliveryTransport(original.origin)
        original.deliveryCurrentDispatch = current
        try unified.ensureCurrentCloudObservation()
        while let observation = try unified.pendingCloudObservation() {
            try await sendUnifiedObservation(result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                current: current, observation: observation))
        }
        let mountState = try unified.mountStateAssociation()
        if mountState.state == "failed", !candidateMounted,
            let shown = content, let lifetime = presentationLifetime, !lifetime.isRetired,
            try canRevalidateMountedCloud(original, unified: unified, mountState: mountState),
            shown.generationID == mountState.generationID, shown.entryID == mountState.entryID {
            try current.requireInstallationAssociation(result.installation)
            if let pending = try unified.restorePendingCloudOutcome(current: current) {
                original.pendingCloudOutcome = pending
            }
            presentationDispatch = current
            // The revalidated current Cloud frame must supply a NEW actual mount
            // before its old validation-failure journal can be cleared or reported.
            return
        }
        if mountState.state == "failed" {
            original.pendingCloudOutcome = nil
            if try unified.restorePendingCloudMountFailure(current: current),
                let code = mountState.failureCode.flatMap(NativeUnifiedMountFailureCode.init(rawValue:)) {
                let failure = try unified.retainedCloudMountFailure()
                try await transport.failed(failure, code: code, installation: result.installation,
                    current: current, authority: original.authority, context: context)
            }
        } else if let pending = try unified.restorePendingCloudOutcome(current: current) {
            original.pendingCloudOutcome = pending
        }
        // A committed original must finish reporting before another command can
        // be fetched or accepted against its already replaced generation.
        if original.pendingCloudOutcome != nil {
            let configured = try unified.validatedAssociation()
            retainDisplayInventory(configured, session: unified)
            if configured.configuredEntryID == nil {
                publishEmptyDisplayIfChanged(generation: configured.generationID)
                if let mounted = try unified.mountedAssociation(), mounted.currentlyConfigured,
                    mounted.entryID == nil, mounted.generationID == configured.generationID {
                    await reportEmptyDisplayMounted(expectedGeneration: configured.generationID)
                }
            } else if let shown = content, shown.generationID == configured.generationID,
                shown.entryID == configured.configuredEntryID, let lifetime = presentationLifetime {
                presentationDispatch = current
                if candidateMounted { try await reportMountedContent(expectedContent: shown, expectedLifetime: lifetime) }
            } else {
                let selected = try await prepareUnifiedContent(unified, operationID: original.delivery.nativeOperationID)
                stagePresentation(selected, current: current)
            }
            try installCommonHost(original, context: context, unified: unified)
            return
        }
        if let empty = emptyDisplayGeneration, let mounted = try unified.mountedAssociation(),
            mounted.currentlyConfigured, mounted.entryID == nil, mounted.generationID == empty {
            await reportEmptyDisplayMounted(expectedGeneration: empty)
        }
        if let rejected = try unified.restorePendingCloudNotActivatedOutcome(current: current) {
            let receipt = try await transport.receipt(rejected, installation: result.installation)
            _ = try unified.retainCloudNotActivatedAcknowledgment(body: rejected, observation: receipt)
        }
        Self.enrollmentLog.info("Common delivery reached: phase=commandRequest")
        let command = try await transport.command(installation: result.installation, current: current,
            authority: original.authority, context: context)
        if let expected = original.requestedCloudOperationID {
            guard command.hasCommand, try command.commandOperationID() == expected else {
                original.requestedCloudOperationID = nil
                deliveryMessage = "The relayed cloud command is no longer current and needs review."; return
            }
            original.requestedCloudOperationID = nil
        }
        if command.hasCommand {
            original.cloudProgress = try command.retainedProgress(current: current)
            try await transport.preparing(command, current: current, authority: original.authority, context: context)
            let identity = try command.commandOperationID()
            let ids = try intentJournal.retainCloudCommand(identity, installation: result.activation.installationId)
            let plan = try await transport.plan(command, nativeOperationID: ids.nativeOperationID,
                current: current, authority: original.authority, context: context)
            let accepted = try plan.acceptUnified(session: unified, current: current)
            do {
                original.relayArchives.retain(installation: result.activation.installationId, operation: identity, plan: plan, current: current)
                let archives = try await transport.archives(plan, current: current, target: original.target,
                    profileID: original.profile, revisionName: original.name, authority: original.authority, context: context)
                try archives.prepareUnified(session: unified, current: current, packageRootID: ids.packageRootID,
                    grantOperationID: ids.grantOperationID, grantRevisionID: ids.grantRevisionID)
                let body = try unified.retainCloudActivationRequest(requestID: ids.activationRequestID, current: current)
                let authorization = try await transport.activate(body, installation: result.installation, current: current,
                    authority: original.authority, context: context)
                try unified.retainCloudAuthorization(requestBody: body, observation: authorization)
                let outcome = try unified.dispatchCloudAndRetainActivatedOutcome(current: current)
                original.pendingCloudOutcome = outcome
                try unified.ensureCurrentCloudObservation()
                let configured = try unified.validatedAssociation()
                self.retainDisplayInventory(configured, session: unified)
                if configured.configuredEntryID == nil {
                    retirePresentation(); emptyDisplayGeneration = configured.generationID
                    if let server = commonHost?.server { try server.attachUnifiedLocalSession(unified) }
                    return
                }
                let selected = try await prepareUnifiedContent(unified, operationID: ids.nativeOperationID)
                stagePresentation(selected, current: current)
                if let server = commonHost?.server { try server.attachUnifiedLocalSession(unified) }
                original.pendingCloudOutcome = outcome
            } catch {
                if let rejected = try? unified.retainCloudNotActivatedOutcome(current: current, command: accepted) {
                    do {
                        let receipt = try await transport.receipt(rejected, installation: result.installation)
                        _ = try unified.retainCloudNotActivatedAcknowledgment(body: rejected, observation: receipt)
                        deliveryMessage = "The cloud screen could not prepare. The current display is retained."
                    } catch { deliveryMessage = "The cloud preparation failure confirmation is pending." }
                }
                throw error
            }
        }
        // The actual mount callback drains the durably queued state before its
        // runtime proof and original receipt. Keep rendering independent of IO.
        if command.hasCommand { return }
        while let observation = try unified.pendingCloudObservation() {
            try await sendUnifiedObservation(result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                current: current, observation: observation))
        }
        let configured = try unified.validatedAssociation()
        retainDisplayInventory(configured, session: unified)
        if configured.configuredEntryID == nil {
            publishEmptyDisplayIfChanged(generation: configured.generationID)
            try installCommonHost(original, context: context, unified: unified); return
        }
        if command.hasCommand { return }
        if try unified.mountStateAssociation().state == "failed" { return }
        if candidateMounted, let shown = content,
            shown.generationID == configured.generationID, shown.entryID == configured.configuredEntryID {
            presentationDispatch = current
            if let lifetime = presentationLifetime, original.confirmedDisplayGeneration != shown.generationID {
                try await reportMountedContent(expectedContent: shown, expectedLifetime: lifetime)
            }
            return
        }
        let selected = try await prepareUnifiedContent(unified, operationID: original.delivery.nativeOperationID)
        stagePresentation(selected, current: current)
        if let server = commonHost?.server { try server.attachUnifiedLocalSession(unified) }
        try installCommonHost(original, context: context, unified: unified)
        deliveryMessage = command.hasCommand ? "Screen prepared. Waiting for the display to mount." : "Device connected."
    }
    /// Delivery may finish after the mounted blank's asynchronous confirmation.
    /// Re-publishing that same view must preserve its proof and mounted identity.
    func publishEmptyDisplayIfChanged(generation: UUID) {
        guard emptyDisplayGeneration != generation else { return }
        retirePresentation(); emptyDisplayGeneration = generation
    }
    private func canRevalidateMountedCloud(_ original: Original, unified: DeviceUnifiedInventorySession,
        mountState: DeviceUnifiedMountStateAssociation) throws -> Bool {
        guard original.unifiedInventory === unified, mountState.state == "failed",
            mountState.failureCode == "mount_validation_failed", let result = original.result else { return false }
        let configured = try unified.validatedAssociation()
        retainDisplayInventory(configured, session: unified)
        guard configured.installationID == result.activation.installationId,
            configured.commonRootID == original.intent.commonInventoryRootID,
            configured.generationID == mountState.generationID, configured.configuredEntryID == mountState.entryID,
            configured.entries.first(where: { $0.entryID == configured.configuredEntryID })?.provenance == "cloud",
            let mounted = try unified.mountedAssociation(), mounted.currentlyConfigured,
            mounted.generationID == configured.generationID, mounted.entryID == configured.configuredEntryID else { return false }
        return true
    }
    private func restoreCommonPresentation(_ original: Original,
                                           context: DeviceManagementAuthority.CloudInstallationContext) async throws {
        guard let result = original.result, let roots = original.roots,
            let rootID = original.intent.commonInventoryRootID else { return }
        let commonRoot = roots.namespace.deletingLastPathComponent()
            .appendingPathComponent("xyz.screenpunk.unified-inventory", isDirectory: true)
        // Absence means enrollment has not yet installed a screen. Presence requires
        // complete durable qualification; corrupt state never falls back to genesis.
        guard FileManager.default.fileExists(atPath: commonRoot.path) else { return }
        guard let operationID = original.intent.firstDeliveryNativeOperationID,
            let grantOperationID = original.intent.firstDeliveryGrantOperationID,
            let grantRevisionID = original.intent.firstDeliveryGrantRevisionID else { throw CancellationError() }
        let delivery = try result.installation.makeDurableResourceExecutionSession()
        do { try delivery.validateUnifiedInventoryResourceAssociation() }
        catch {
            try delivery.restoreCompletedStaticDelivery(nativeOperationID: operationID,
                grantOperationID: grantOperationID, grantRevisionID: grantRevisionID)
            try delivery.validateUnifiedInventoryResourceAssociation()
        }
        if original.legacyMigration == nil {
            let sources = try DeviceUnifiedInventorySession.peekLocalSourceMetadata(commonRoot: commonRoot, commonRootID: rootID)
            if !sources.legacyLocalRoots.isEmpty {
                let descriptors = sources.legacyLocalRoots
                guard descriptors.count == 4 else { throw CancellationError() }
                let ids = try NativeManagedLocalRootIDs(package: descriptors[0].rootID, grant: descriptors[1].rootID,
                    structural: descriptors[2].rootID, provisioning: descriptors[3].rootID, contentGenesis: rootID)
                let localRoots = try original.authority.restoreRecordedLocalInventoryRoots(context: context, ids: ids)
                let expected = [localRoots.packageRoot, localRoots.grantRoot, localRoots.structuralRoot, localRoots.provisioningRoot]
                guard zip(expected, descriptors).allSatisfy({ $0.0.standardizedFileURL.path == URL(fileURLWithPath: $0.1.path).standardizedFileURL.path }) else { throw CancellationError() }
                original.legacyMigration = try restoredLocalSource(authority: original.authority, roots: localRoots)
            }
        }
        let unified = try original.authority.restoreUnifiedInventorySession(context: context,
            commonRootID: rootID, local: original.legacyMigration, native: delivery,
            restoreIncomingLocal: { associations in
                try associations.map { association in
                    let intent = try self.intentJournal.loadLocalCommand(association.operationID)
                    let roots = try original.authority.restoreIncomingLocalInventoryRoots(context: context,
                        operationID: association.operationID, ids: intent.rootIDs())
                    let expected = [roots.packageRoot.standardizedFileURL.path: intent.package, roots.grantRoot.standardizedFileURL.path: intent.grant,
                        roots.structuralRoot.standardizedFileURL.path: intent.structural, roots.provisioningRoot.standardizedFileURL.path: intent.provisioning]
                    guard association.roots.count == 4, association.roots.allSatisfy({ expected[URL(fileURLWithPath: $0.path).standardizedFileURL.path] == $0.rootID }) else { throw CancellationError() }
                    let anchor = roots.namespace.deletingLastPathComponent()
                    let local = try DeviceLegacyMigrationSession(packageRoot: roots.packageRoot, packageRootID: intent.package,
                        grantRoot: roots.grantRoot, grantRootID: intent.grant, structuralRoot: roots.structuralRoot,
                        structuralRootID: intent.structural, provisioningRoot: roots.provisioningRoot, provisioningRootID: intent.provisioning,
                        legacyStateRoot: DeviceStateStore.defaultRoot(), legacyArchiveRoot: DeviceStateStore.defaultRoot().appendingPathComponent("archives"),
                        resetRoot: DeviceLocalResetStore.defaultDirectory(), cloudRoot: roots.namespace.deletingLastPathComponent().appendingPathComponent("xyz.screenpunk.managed"),
                        managementRoot: DeviceManagementTransitionStore.defaultDirectory(), preferencesRoot: anchor.appendingPathComponent("xyz.screenpunk.preferences"),
                        otherProtectedRoots: [anchor.appendingPathComponent("xyz.screenpunk.unified-inventory")],
                        credentialTransport: NativeEnrollmentKeychainBackend.grantTransport(rootID: intent.grant),
                        validateRoots: { try original.authority.validateLocalInventoryRoots(roots) })
                    try local.restoreCompleted()
                    return try DeviceIncomingLocalPreparation(completed: local, operationID: association.operationID)
                }
            })
        original.delivery.session = delivery
        original.unifiedInventory = unified
        let configured = try unified.validatedAssociation()
        retainDisplayInventory(configured, session: unified)
        if configured.configuredEntryID == nil {
            retirePresentation(); emptyDisplayGeneration = configured.generationID
            try installCommonHost(original, context: context, unified: unified); return
        }
        let selected: DeviceManagedStaticContent
        let mountState = try unified.mountStateAssociation()
        if mountState.state == "failed", try !canRevalidateMountedCloud(original, unified: unified, mountState: mountState) {
            do {
                let runtime = try await unified.lastSuccessfulManagedRuntime(operationID: operationID,
                    http: URLSessionHTTPTransport(), webSocket: URLSessionWebSocketTransport(),
                    resolver: LiteralOrResolvedDestinationResolver(), clock: SystemClock(),
                    cloudHomeAssistant: { try DeviceCloudHomeAssistantStore.shared.configuration(installationID: $0, manifest: $1) })
                preparedRuntime = runtime; selected = runtime.content
            } catch DeviceManagedRenderFailure.invalidContent {
                // Fall back only when no managed historical presentation is available.
                // Preserve the real failure if no such fallback is available.
                try installCommonHost(original, context: context, unified: unified); return
            }
        } else {
            selected = try await prepareUnifiedContent(unified, operationID: operationID)
        }
        stagePresentation(selected, current: nil)
        deliveryMessage = "Restored the last accepted screen. Checking the cloud connection."
        try installCommonHost(original, context: context, unified: unified)
    }
    private func installCommonHost(_ original: Original, context: DeviceManagementAuthority.CloudInstallationContext,
                                   unified: DeviceUnifiedInventorySession) throws {
        guard allowsConcurrentHostInstallation, commonHost == nil, try original.authority.qualifiedConcurrentControl(context: context),
            let bootstrap, let installationResult = original.result else { return }
        let localContext = try original.authority.makeConcurrentLocalContext(context: context, session: unified)
        let host = try bootstrap.installConcurrentHost(context: localContext)
        guard let server = host.server else { throw CancellationError() }
        try server.attachUnifiedLocalSession(unified)
        guard let installationRoots = original.roots else { throw CancellationError() }
        let journal = intentJournal
        let relay = original.relayArchives
        server.onCloudArchiveAdmission = { installation, operation, package, digest, count in
            try relay.require(installation: installation, operation: operation, package: package, digest: digest, count: count)
        }
        server.onCloudArchiveReceived = { installation, operation, package, bytes in
            try relay.receive(installation: installation, operation: operation, package: package, bytes: bytes)
        }
        server.onCloudRelayHint = { [weak self, weak original] installationID, operationID in
            Task { @MainActor in
                guard let self, let original, self.original === original,
                    installationResult.activation.installationId == installationID else { return }
                original.requestedCloudOperationID = operationID
                self.schedulePendingCloudRelay()
            }
        }
        server.prepareIncomingLocalScreens = { [localTarget = host.runtime.profile] operationID, peer, screens, selected, validateOriginal in
            let intent = try journal.retainLocalCommand(operationID, installation: installationResult.activation.installationId, screens: screens)
            let roots = try original.authority.prepareIncomingLocalInventoryRoots(context: localContext,
                operationID: operationID, ids: intent.rootIDs())
            let anchor = roots.namespace.deletingLastPathComponent()
            let session = try DeviceLegacyMigrationSession(packageRoot: roots.packageRoot, packageRootID: intent.package,
                grantRoot: roots.grantRoot, grantRootID: intent.grant, structuralRoot: roots.structuralRoot,
                structuralRootID: intent.structural, provisioningRoot: roots.provisioningRoot, provisioningRootID: intent.provisioning,
                legacyStateRoot: DeviceStateStore.defaultRoot(), legacyArchiveRoot: DeviceStateStore.defaultRoot().appendingPathComponent("archives"),
                resetRoot: DeviceLocalResetStore.defaultDirectory(), cloudRoot: installationRoots.namespace,
                managementRoot: DeviceManagementTransitionStore.defaultDirectory(), preferencesRoot: anchor.appendingPathComponent("xyz.screenpunk.preferences"),
                otherProtectedRoots: [anchor.appendingPathComponent("xyz.screenpunk.unified-inventory")],
                credentialTransport: NativeEnrollmentKeychainBackend.grantTransport(rootID: intent.grant),
                validateRoots: { try original.authority.validateLocalInventoryRoots(roots) })
            let retainedScreens = try screens.map { screen in
                guard let packageID = intent.packages[screen.entryIdentity.uuidString.lowercased()] else { throw CancellationError() }
                return screen.retainingPackagePreparationIdentity(packageID)
            }
            let sourceSelection = selected.flatMap { selected in
                retainedScreens.contains(where: { $0.entryIdentity == selected }) ? selected : nil
            } ?? retainedScreens.first?.entryIdentity
            try session.prepareAndCommit(screens: retainedScreens, selected: sourceSelection, owner: peer, profile: localTarget,
                profileID: localTarget.deviceId, operationID: operationID, grantOperationID: intent.grantOperation,
                generationID: intent.generation, grantRevisionID: intent.grantRevision, legacyGrantSet: nil,
                validateOriginal: validateOriginal)
            return try DeviceIncomingLocalPreparation(completed: session, operationID: operationID)
        }
        server.onCommonContentChanged = { [weak self, weak original] in
            Task { @MainActor in
                guard let self, let original, self.original === original, !self.disconnectInProgress else { return }
                self.presence.beginCallback(); defer { self.presence.endCallback() }
                await self.presence.drain()
                do {
                    let association = try unified.validatedAssociation()
                    self.retainDisplayInventory(association, session: unified)
                    if association.configuredEntryID == nil {
                        self.retirePresentation(); self.emptyDisplayGeneration = association.generationID
                        self.deliveryMessage = "Preparing an empty display."; return
                    }
                    let selected = try await self.prepareUnifiedContent(unified, operationID: original.delivery.nativeOperationID)
                    self.stagePresentation(selected, current: original.deliveryCurrentDispatch)
                    self.deliveryMessage = "Screen changed by an approved local controller."
                    if let progress = original.cloudProgress, let result = original.result, let context = original.context {
                        original.cloudProgress = nil
                        do {
                            let transport = try self.makeDeliveryTransport(original.origin)
                            let status = try original.authority.prepareCloudStatusRequest(context)
                            _ = try await transport.send(status, authority: original.authority, context: context)
                            let current = try original.authority.prepareCurrentInstallationDispatch(context)
                            original.deliveryCurrentDispatch = current
                            try await transport.superseded(progress, installation: result.installation, current: current,
                                authority: original.authority, context: context)
                        } catch { original.cloudProgress = progress }
                    }
                } catch { self.deliveryMessage = "The local screen change needs recovery." }
            }
        }
        commonHost = host
        host.start()
        startTemporaryActivation(original, unified: unified)
    }
    private func startTemporaryActivation(_ original: Original, unified: DeviceUnifiedInventorySession) {
        temporaryPoll?.cancel(); temporaryExpiry?.cancel()
        if let prior = temporaryDriver { Task { await prior.cancel() } }
        let driver = unified.makeTemporaryActivationDriver(http: URLSessionHTTPTransport(), resolver: LiteralOrResolvedDestinationResolver())
        temporaryDriver = driver
        temporaryPoll = Task { [weak self, weak original] in
            while !Task.isCancelled {
                guard let self, let original, self.original === original else { return }
                do { if try await driver.poll() { try await self.presentAutomaticSelection(original, unified: unified) } }
                catch { if Task.isCancelled { return } }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        // Expiry proceeds independently when the event source cannot respond.
        temporaryExpiry = Task { [weak self, weak original] in
            while !Task.isCancelled {
                guard let self, let original, self.original === original else { return }
                do { if try await driver.expire() { try await self.presentAutomaticSelection(original, unified: unified) } }
                catch { if Task.isCancelled { return } }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func presentAutomaticSelection(_ original: Original, unified: DeviceUnifiedInventorySession) async throws {
        guard !disconnectInProgress else { throw CancellationError() }
        presence.beginCallback(); defer { presence.endCallback() }
        await presence.drain()
        guard self.original === original else { throw CancellationError() }
        let association = try unified.validatedAssociation()
        retainDisplayInventory(association, session: unified)
        if association.configuredEntryID == nil {
            retirePresentation(); emptyDisplayGeneration = association.generationID
        } else {
            let selected = try await prepareUnifiedContent(unified, operationID: original.delivery.nativeOperationID)
            stagePresentation(selected, current: original.deliveryCurrentDispatch)
        }
        if let server = commonHost?.server { try server.attachUnifiedLocalSession(unified) }
        deliveryMessage = "Preparing the approved automatic screen change."
    }
    func reportMountedContent(expectedContent: DeviceManagedStaticContent, expectedLifetime: DeviceRuntimeLifetime) async throws {
        guard !disconnectInProgress else { throw CancellationError() }
        if original == nil, detachedInventory != nil,
            commonHost?.isRetainedSceneActivityAllowed() != true { throw CancellationError() }
        presence.beginCallback(); defer { presence.endCallback() }
        await presence.drain()
        if original == nil, detachedInventory != nil,
            commonHost?.isRetainedSceneActivityAllowed() != true { throw CancellationError() }
        guard content === expectedContent, presentationLifetime === expectedLifetime, !expectedLifetime.isRetired else { throw CancellationError() }
        if original == nil, let detachedInventory {
            try requireCurrentPresentation(); try detachedInventory.confirmMountedLocalContent(expectedContent)
            candidateMounted = true; return
        }
        guard let original else { throw CancellationError() }
        let explicitOperation = original.explicitOperationID
        let localObservation: NativeMountedContentObservation?
        if let unified = original.unifiedInventory {
            try unified.confirmMountedLocalContent(expectedContent)
            localObservation = nil
        } else {
            guard let session = original.delivery.session, let current = presentationDispatch else { throw CancellationError() }
            localObservation = try session.confirmMountedStaticContent(expectedContent, current: current)
        }
        candidateMounted = true
        do {
        let observation: NativeMountedContentObservation?
        if let unified = original.unifiedInventory, let current = presentationDispatch {
            observation = try unified.confirmMountedContent(expectedContent, current: current)
            if original.pendingCloudOutcome == nil, original.confirmedDisplayGeneration != expectedContent.generationID {
                let configured = try unified.validatedAssociation()
                self.retainDisplayInventory(configured, session: unified)
                if configured.generationID == expectedContent.generationID,
                    configured.configuredEntryID == expectedContent.entryID,
                    configured.entries.first(where: { $0.entryID == expectedContent.entryID })?.provenance == "cloud" {
                    // A retained validation-failure marker can hide the original
                    // outcome until this NEW qualified local mount has cleared it.
                    original.pendingCloudOutcome = try unified.restorePendingCloudOutcome(current: current)
                }
            }
        } else { observation = localObservation }
        try requireCurrentPresentation()
        retainedDisplayLifetime?.retire(); retainedDisplayLifetime = nil; retainedDisplayContent = nil; retainedDisplayRuntime = nil
        guard let result = original.result, let session = original.delivery.session,
            let current = presentationDispatch, let observation else {
            deliveryMessage = "Screen mounted. Cloud confirmation is pending."; return
        }
        if original.confirmedDisplayGeneration == expectedContent.generationID { return }
        let reportingIdentity = ObjectIdentifier(expectedLifetime)
        if mountedReportInFlight != nil {
            if mountedReportInFlight != reportingIdentity || mountedReportDispatch !== current {
                pendingMountedReport = (expectedContent, expectedLifetime, current, original)
            }
            return
        }
        mountedReportInFlight = reportingIdentity; mountedReportDispatch = current
        defer { finishMountedReport(reportingIdentity) }
        let cloudOutcome = original.pendingCloudOutcome
        func requireReportFrame() throws {
            guard self.original === original, content === expectedContent,
                presentationLifetime === expectedLifetime, !expectedLifetime.isRetired,
                presentationDispatch === current else { throw CancellationError() }
            try requireCurrentPresentation()
        }
        try requireReportFrame()
        let transport = try self.makeDeliveryTransport(original.origin)
        if let unified = original.unifiedInventory {
            try unified.ensureCurrentCloudObservation()
            while let state = try unified.pendingCloudObservation() {
                try requireReportFrame()
                try await sendUnifiedObservation(result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                    current: current, observation: state))
                try requireReportFrame()
            }
        }
        try requireReportFrame()
        let request = try result.installation.makeMountedContentObservationRequest(origin: original.origin,
            current: current, observation: observation)
        _ = try await sendMountedObservation(request)
        try requireReportFrame()
        if let unified = original.unifiedInventory, let outcome = cloudOutcome {
            let receipt = try await transport.receipt(outcome, installation: result.installation)
            try requireReportFrame()
            _ = try unified.retainCloudOutcomeAcknowledgment(body: outcome, observation: receipt)
            if original.pendingCloudOutcome === outcome { original.pendingCloudOutcome = nil }
            original.cloudProgress = nil
        } else if let outcome = original.delivery.outcome,
                  original.delivery.acknowledgment == nil {
            let receipt = try await transport.receipt(outcome, installation: result.installation)
            original.delivery.acknowledgment = try session.retainOutcomeAcknowledgment(body: outcome, observation: receipt)
        }
        try requireCurrentPresentation()
        guard content === expectedContent, presentationLifetime === expectedLifetime else { throw CancellationError() }
        deliveryMessage = "Screen mounted. Activation receipt confirmed."
        if self.original === original, original.explicitOperationID == explicitOperation {
            original.confirmedDisplayGeneration = expectedContent.generationID
            if let explicitOperation { try completeExplicitConnectionIfReady(original, operationID: explicitOperation) }
        }
        } catch {
            let diagnostic = NativeEnrollmentFailureDiagnostic(stage: .screenDelivery, error: error)
            Self.enrollmentLog.error("Mounted display confirmation stopped: category=\(diagnostic.category.rawValue, privacy: .public) detail=\(diagnostic.detail ?? "", privacy: .public)")
            deliveryMessage = "Screen mounted. Cloud confirmation is pending."
        }
    }
    private func finishMountedReport(_ identity: ObjectIdentifier) {
        guard mountedReportInFlight == identity else { return }
        mountedReportInFlight = nil; mountedReportDispatch = nil
        guard let pending = pendingMountedReport else { return }
        pendingMountedReport = nil
        // Replay only an attempt that actually arrived while blocked. Failure
        // does not schedule another attempt or revive a retired presentation.
        Task { [weak self] in
            guard let self, !self.disconnectInProgress, !self.factoryResetInProgress,
                !self.intentRetirementPending, self.original === pending.original,
                self.content === pending.content, self.presentationLifetime === pending.lifetime,
                !pending.lifetime.isRetired, self.presentationDispatch === pending.dispatch else { return }
            try? await self.reportMountedContent(expectedContent: pending.content, expectedLifetime: pending.lifetime)
        }
    }
    func invokeService(expectedContent: DeviceManagedStaticContent, expectedLifetime: DeviceRuntimeLifetime, invocationID: UUID, bindingID: UUID, operation: String, input: String) async throws -> Data {
        guard !disconnectInProgress else { throw CancellationError() }
        if original == nil, detachedInventory != nil,
            commonHost?.isRetainedSceneActivityAllowed() != true { throw CancellationError() }
        presence.beginCallback(); defer { presence.endCallback() }
        await presence.drain()
        if original == nil, detachedInventory != nil,
            commonHost?.isRetainedSceneActivityAllowed() != true { throw CancellationError() }
        try requireMountedServiceFrame(expectedContent, lifetime: expectedLifetime)
        try requireCurrentPresentation()
        guard let original, let result = original.result, let current = presentationDispatch else { throw CancellationError() }
        let request = try result.installation.makeScreenServiceRequest(origin: original.origin, current: current,
            invocationID: invocationID, bindingID: bindingID, operation: operation, input: input)
        let response = try await request.performFixedTransport()
        try requireCurrentPresentation()
        try requireMountedServiceFrame(expectedContent, lifetime: expectedLifetime)
        return response
    }
    private func requireMountedServiceFrame(_ expected: DeviceManagedStaticContent, lifetime: DeviceRuntimeLifetime) throws {
        guard !lifetime.isRetired,
            (candidateMounted && content === expected && presentationLifetime === lifetime) ||
            (retainedDisplayContent === expected && retainedDisplayLifetime === lifetime) else { throw CancellationError() }
        try expected.verifyResources()
        if let common = original?.unifiedInventory ?? detachedInventory {
            guard let mounted = try common.mountedAssociation(),
                mounted.generationID == expected.generationID, mounted.entryID == expected.entryID else { throw CancellationError() }
        }
    }
    func requireCurrentPresentation() throws {
        guard let content, let lifetime = presentationLifetime, !lifetime.isRetired else { throw CancellationError() }
        if original == nil, let detachedInventory {
            try detachedInventory.detachedAssociation().validateCurrent(); try content.verifyResources(); return
        }
        guard let original else { throw CancellationError() }
        do {
            try requireEnrollmentHumanContext(original)
            if original.unifiedInventory == nil {
                guard let presentationDispatch else { throw CancellationError() }
                try presentationDispatch.requirePresentationCurrent()
            }
            try content.verifyResources()
            try requireEnrollmentHumanContext(original)
            if original.unifiedInventory == nil {
                guard let presentationDispatch else { throw CancellationError() }
                try presentationDispatch.requirePresentationCurrent()
            }
        }
        catch { retirePresentation(); throw error }
    }
    func prepareUnifiedContent(_ unified: DeviceUnifiedInventorySession, operationID: UUID,
        admittedAssociation: DeviceUnifiedInventoryAssociation? = nil) async throws -> DeviceManagedStaticContent {
        // Classification metadata can come from the immediately preceding qualified
        // transition. Core issuance still qualifies its exact source and presentation.
        let association = try admittedAssociation ?? unified.validatedAssociation()
        if admittedAssociation == nil { retainDisplayInventory(association, session: unified) }
        guard let selected = association.entries.first(where: { $0.entryID == association.configuredEntryID }) else {
            throw DeviceManagedRenderFailure.emptySelection
        }
        guard ["cloud", "retainedLocal"].contains(selected.provenance) else { throw DeviceManagedRenderFailure.invalidContent }
        let runtime = try await unified.makeManagedRuntime(operationID: operationID,
            http: URLSessionHTTPTransport(), webSocket: URLSessionWebSocketTransport(),
            resolver: LiteralOrResolvedDestinationResolver(), clock: SystemClock(),
            cloudHomeAssistant: { try DeviceCloudHomeAssistantStore.shared.configuration(installationID: $0, manifest: $1) })
        preparedRuntime = runtime
        return runtime.content
    }
    func stagePresentation(_ next: DeviceManagedStaticContent, current: NativeCurrentInstallationDispatch?,
        activityDomain: PresentationActivityDomain = .ordinary) {
        emptyDisplayGeneration = nil
        presentationExpiry?.cancel(); presentationExpiry = nil
        if candidateMounted, let content, let presentationLifetime {
            retainedDisplayLifetime?.retire()
            retainedDisplayContent = content; retainedDisplayLifetime = presentationLifetime
            retainedDisplayRuntime = presentationRuntime
            retainedDisplayHost = presentationHost
            retainedDisplayActivityDomain = presentationActivityDomain
        } else { presentationLifetime?.retire() }
        candidateMounted = false
        presentationLifetime = DeviceRuntimeLifetime(); presentationDispatch = current; content = next
        presentationRuntime = preparedRuntime?.content === next ? preparedRuntime : nil
        presentationHost = commonHost; presentationActivityDomain = activityDomain
        preparedRuntime = nil
    }
    private func schedulePendingCloudConfirmation(_ original: Original,
        context: DeviceManagementAuthority.CloudInstallationContext, content expectedContent: DeviceManagedStaticContent,
        lifetime expectedLifetime: DeviceRuntimeLifetime, current: NativeCurrentInstallationDispatch) {
        guard task == nil, !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress,
            self.original === original, self.context === context, original.context === context,
            !original.foregroundRevoked, let result = original.result, let unified = original.unifiedInventory else { return }
        workKind = .cloudRelay; state = .enrolling
        task = Task { [weak self, weak original] in
            guard let self else { return }
            defer { self.task = nil; self.workKind = nil; self.schedulePendingCloudRelay() }
            await self.presence.drain()
            guard let original else { return }
            do {
                try Task.checkCancellation()
                guard !self.factoryResetInProgress, !self.intentRetirementPending, !self.disconnectInProgress,
                    self.original === original, self.context === context, original.context === context,
                    !original.foregroundRevoked, original.unifiedInventory === unified,
                    original.deliveryCurrentDispatch === current, self.presentationDispatch === current,
                    self.content === expectedContent, self.presentationLifetime === expectedLifetime,
                    !expectedLifetime.isRetired, self.candidateMounted else { throw CancellationError() }
                try current.requireInstallationAssociation(result.installation)
                let configured = try unified.validatedAssociation()
                self.retainDisplayInventory(configured, session: unified)
                let mounted = try unified.mountedAssociation()
                guard configured.installationID == result.activation.installationId,
                    configured.commonRootID == original.intent.commonInventoryRootID,
                    configured.generationID == expectedContent.generationID,
                    configured.configuredEntryID == expectedContent.entryID,
                    mounted?.currentlyConfigured == true, mounted?.generationID == expectedContent.generationID,
                    mounted?.entryID == expectedContent.entryID else { throw CancellationError() }
                self.setEnrollmentStage(.screenDelivery)
                try await self.deliverCommon(original, result: result, current: current, context: context, unified: unified)
                try Task.checkCancellation()
                guard self.original === original, self.context === context,
                    self.content === expectedContent, self.presentationLifetime === expectedLifetime,
                    !expectedLifetime.isRetired, self.presentationDispatch === current else { throw CancellationError() }
                self.enrollmentProgressMessage = nil; self.enrollmentDiagnostic = nil
                self.state = .currentInstallation
            } catch { self.reportEnrollmentFailure(error, installationEnrolled: true) }
        }
    }
    private func schedulePendingCloudRelay() {
        guard !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress, task == nil,
            let original, original.requestedCloudOperationID != nil,
            let result = original.result, let context = original.context,
            let unified = original.unifiedInventory else { return }
        workKind = .cloudRelay
        enrollmentDiagnostic = nil; state = .enrolling
        setEnrollmentStage(.installationStatus)
        task = Task { [weak self, weak original] in
            guard let self else { return }
            defer { self.task = nil; self.workKind = nil; self.schedulePendingCloudRelay() }
            await self.presence.drain()
            guard let original else { return }
            do {
                let transport = try self.makeDeliveryTransport(original.origin)
                let status = try original.authority.prepareCloudStatusRequest(context)
                _ = try await transport.send(status, authority: original.authority, context: context)
                let current = try original.authority.prepareCurrentInstallationDispatch(context)
                self.setEnrollmentStage(.screenDelivery)
                try await self.deliverCommon(original, result: result, current: current, context: context, unified: unified)
                self.enrollmentProgressMessage = nil; self.enrollmentDiagnostic = nil
                self.state = .currentInstallation
            } catch {
                // Retrying requires another explicit hint after an unsuccessful verification.
                original.requestedCloudOperationID = nil
                self.reportEnrollmentFailure(error, installationEnrolled: true)
            }
        }
    }
    func reportEmptyDisplayMounted(expectedGeneration: UUID) async {
        guard !disconnectInProgress else { return }
        presence.beginCallback(); defer { presence.endCallback() }
        await presence.drain()
        guard emptyDisplayGeneration == expectedGeneration else { return }
        if original == nil, let detachedInventory {
            do {
                let association = try detachedInventory.validatedAssociation()
                retainDisplayInventory(association, session: detachedInventory)
                guard association.generationID == expectedGeneration, association.configuredEntryID == nil else { throw CancellationError() }
                try detachedInventory.confirmMountedEmptyDisplay()
            } catch { deliveryMessage = "The local display could not be confirmed." }
            return
        }
        guard let original, let unified = original.unifiedInventory else { return }
        let explicitOperation = original.explicitOperationID
        enum ConfirmationStage: String { case association, mount, cloudOutbox, cloudObservation, blankProof, blankTransport, activationReceipt, completionAssociation, completionPublication }
        var phase = ConfirmationStage.association
        do {
            let association = try unified.validatedAssociation()
            retainDisplayInventory(association, session: unified)
            guard association.generationID == expectedGeneration, association.configuredEntryID == nil else { throw CancellationError() }
            phase = .mount
            try unified.confirmMountedEmptyDisplay()
            deliveryMessage = "Empty display applied."
            guard let result = original.result, let current = original.deliveryCurrentDispatch else { throw CancellationError() }
            phase = .cloudOutbox
            while let observation = try unified.pendingCloudObservation() {
                phase = .cloudObservation
                try await sendUnifiedObservation(result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                    current: current, observation: observation))
                phase = .cloudOutbox
            }
            phase = .blankProof
            let blank = try unified.retainedMountedEmptyObservation()
            phase = .blankTransport
            try await sendEmptyObservation(result.installation.makeMountedEmptyObservationRequest(origin: original.origin,
                current: current, observation: blank))
            phase = .activationReceipt
            if let outcome = original.pendingCloudOutcome, let result = original.result {
                let transport = try self.makeDeliveryTransport(original.origin)
                if let current = original.deliveryCurrentDispatch {
                    while let observation = try unified.pendingCloudObservation() {
                        try await sendUnifiedObservation(result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                            current: current, observation: observation))
                    }
                }
                let receipt = try await transport.receipt(outcome, installation: result.installation)
                _ = try unified.retainCloudOutcomeAcknowledgment(body: outcome, observation: receipt)
                original.pendingCloudOutcome = nil
            }
            phase = .completionAssociation
            guard self.original === original, emptyDisplayGeneration == expectedGeneration,
                original.explicitOperationID == explicitOperation else { throw CancellationError() }
            original.confirmedDisplayGeneration = expectedGeneration
            phase = .completionPublication
            if let explicitOperation { try completeExplicitConnectionIfReady(original, operationID: explicitOperation) }
        } catch {
            let diagnostic = NativeEnrollmentFailureDiagnostic(stage: .screenDelivery, error: error)
            Self.enrollmentLog.error("Empty display confirmation stopped: phase=\(phase.rawValue, privacy: .public) category=\(diagnostic.category.rawValue, privacy: .public)")
            deliveryMessage = "Empty display confirmation is pending."
        }
    }
    func reportMountFailed(expectedContent: DeviceManagedStaticContent, expectedLifetime: DeviceRuntimeLifetime, code: String) async {
        guard !disconnectInProgress else { return }
        presence.beginCallback(); defer { presence.endCallback() }
        await presence.drain()
        guard content === expectedContent, presentationLifetime === expectedLifetime else { return }
        do { try original?.unifiedInventory?.confirmMountFailure(expectedContent, code: code) }
        catch { deliveryMessage = "The failed display needs recovery."; return }
        let failure = try? original?.unifiedInventory?.retainedCloudMountFailure()
        let reportingOriginal = original
        original?.pendingCloudOutcome = nil
        presentationLifetime?.retire()
        content = retainedDisplayContent; presentationLifetime = retainedDisplayLifetime
        presentationRuntime = retainedDisplayRuntime; presentationHost = retainedDisplayHost; presentationActivityDomain = retainedDisplayActivityDomain
        retainedDisplayContent = nil; retainedDisplayLifetime = nil; retainedDisplayRuntime = nil; retainedDisplayHost = nil; retainedDisplayActivityDomain = .ordinary
        candidateMounted = content != nil
        deliveryMessage = "The new screen could not mount. The previous display is retained."
        if let original = reportingOriginal, let result = original.result,
            let current = original.deliveryCurrentDispatch, let failure,
            let failureCode = NativeUnifiedMountFailureCode(rawValue: code), let context = original.context {
            do {
                let transport = try self.makeDeliveryTransport(original.origin)
                if let unified = original.unifiedInventory {
                    while let observation = try unified.pendingCloudObservation() {
                        try await sendUnifiedObservation(result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                            current: current, observation: observation))
                    }
                }
                try await transport.failed(failure, code: failureCode, installation: result.installation,
                    current: current, authority: original.authority, context: context)
            } catch { deliveryMessage = "The new screen could not mount. Cloud failure confirmation is pending." }
        }
    }
    private func retirePresentation(cancelRetainedResume: Bool = true) {
        cancelRetainedSceneResume(cancelWork: cancelRetainedResume)
        detachedPresentationWork?.task.cancel()
        pendingMountedReport = nil
        completedExplicitConnectionOperationID = nil; original?.confirmedDisplayGeneration = nil
        emptyDisplayGeneration = nil
        presentationExpiry?.cancel(); presentationExpiry = nil
        presentationLifetime?.retire(); presentationLifetime = nil; presentationDispatch = nil; content = nil; presentationRuntime = nil; preparedRuntime = nil; presentationHost = nil; presentationActivityDomain = .ordinary
        retainedDisplayLifetime?.retire(); retainedDisplayLifetime = nil; retainedDisplayContent = nil; retainedDisplayRuntime = nil; retainedDisplayHost = nil; retainedDisplayActivityDomain = .ordinary; candidateMounted = false
    }
    @Published private(set) var factoryResetInProgress = false { didSet { if oldValue != factoryResetInProgress { invalidateDisplayInventory() } } }
    private var pendingFactoryResetReceipt: DeviceOwnedFactoryResetReceipt?
    private var resetHumanSignOut: ((CloudHumanSessionLifecycle) -> Task<Void, Never>?)?
    private var resetHumanSignOutComplete: (() -> Bool)?
    /// One presentation signal for a durable unfinished original. It grants no
    /// recovery authority and never competes with owned reset cleanup.
    var hasUnfinishedCloudEnrollment: Bool {
        retainedIntent?.restoreRecordedInstallation == false && !intentRetirementPending &&
            !factoryResetInProgress && pendingFactoryResetReceipt == nil
    }
    var canFactoryReset: Bool {
        !factoryResetInProgress && (pendingFactoryResetReceipt != nil || (original?.context != nil && original?.result != nil && original?.delivery.session != nil))
    }
    var factoryResetRecoveryMessage: String? {
        if intentRetirementPending, !canFactoryReset {
            return "Recover the original device reset cleanup before enrolling again. If its saved receipt or original files changed, preserve them and contact support."
        }
        guard !canFactoryReset, retainedIntent != nil else { return nil }
        return "Recover the original enrollment in Cloud account before resetting this device. Staged credentials are preserved. If recovery is revoked or unavailable, ask your workspace administrator to disconnect the original device and contact support about the retained local state."
    }
    /// Explicit device-local reset. The sealed preparation retains the original
    /// owned scope and reset ID before any mutating host is retired.
    func factoryReset(lifecycle: CloudHumanSessionLifecycle) async {
        guard !factoryResetInProgress, let bootstrap else { return }
        factoryResetInProgress = true
        presence.stop(); realtime.stop(); await presence.drain()
        defer { factoryResetInProgress = false }
        do {
            if let receipt = pendingFactoryResetReceipt {
                try await completeFactoryReset(receipt, lifecycle: lifecycle, bootstrap: bootstrap)
                return
            }
            guard let original, let context = original.context,
                let installation = original.result?.installation, let native = original.delivery.session else { return }
            if resetHumanSignOut == nil, let coordinator = lifecycle.coordinator, let identity = coordinator.humanIdentity {
                var started = false
                resetHumanSignOut = { current in
                    guard current.coordinator === coordinator,
                        coordinator.humanIdentity == identity || (started && coordinator.humanIdentity == nil && coordinator.signOutState != .idle) else { return nil }
                    started = true
                    return coordinator.signOutState == .failed ? current.retrySignOut() : current.signOut()
                }
                resetHumanSignOutComplete = { started && coordinator.signOutState == .succeeded }
            }
            let preparation: DeviceOwnedFactoryResetPreparation
            if let pendingReset = try original.authority.recoverFactoryReset() {
                preparation = pendingReset
            } else {
                preparation = try original.authority.prepareFactoryReset(context: context,
                    session: original.unifiedInventory, native: native, installation: installation)
            }
            let pending = task
            pending?.cancel()
            if let pending { await pending.value }
            task = nil; workKind = nil
            temporaryPoll?.cancel(); temporaryPoll = nil
            temporaryExpiry?.cancel(); temporaryExpiry = nil
            if let driver = temporaryDriver { await driver.cancel() }
            temporaryDriver = nil
            commonHost?.retireForReset(); commonHost = nil
            retirePresentation()
            try intentJournal.freezeWritesForReset {
                try NativeEnrollmentIntentRetirement(original: intentJournal.directory).capture(resetID: preparation.resetID,
                    scopeDigest: preparation.scopeDigest, installationID: original.result!.activation.installationId,
                    expected: original.intent, journal: intentJournal)
            }
            intentRetirementPending = true
            let receipt = try await preparation.execute()
            pendingFactoryResetReceipt = receipt
            try await completeFactoryReset(receipt, lifecycle: lifecycle, bootstrap: bootstrap)
        } catch {
            state = .needsAttention
            deliveryMessage = "Device reset needs recovery. Retry the original reset before reconnecting."
        }
    }
    private func completeFactoryReset(_ receipt: DeviceOwnedFactoryResetReceipt,
        lifecycle: CloudHumanSessionLifecycle, bootstrap: DeviceManagementBootstrap) async throws {
        try receipt.validateCompletion()
        try NativeEnrollmentIntentRetirement(original: intentJournal.directory).retire(resetID: receipt.resetID,
            scopeDigest: receipt.scopeDigest) { try receipt.validateCompletion() }
        intentRetirementPending = false
        humanObservations.removeAll()
        if let revocationObserver { observedLifecycle?.removeOriginalRevocationObserver(revocationObserver) }
        observedLifecycle = nil; revocationObserver = nil
        let signOut = resetHumanSignOut?(lifecycle)
        if let signOut { await signOut.value }
        try await bootstrap.completeOwnedFactoryReset(receipt)
        original = nil; context = nil; retainedIntent = nil; pendingOriginalIntent = nil; originalRequestRetention = .notSaved; reportedMetadata = nil
        let signedOut = resetHumanSignOutComplete?() == true
        pendingFactoryResetReceipt = nil; resetHumanSignOut = nil; resetHumanSignOutComplete = nil; intentJournal = .application(); state = .idle
        deliveryMessage = signedOut
            ? "This device has been reset and signed out. Its cloud account, projects, and cloud device record were preserved."
            : "This device-local reset is complete. Review local sign-in and retry Sign out in Cloud account if needed. Your cloud account, projects, and device record were preserved."
    }
    /// Ordinary OS suspension may keep only a genuinely mounted detached Local
    /// frame. It preserves pixels, never an unchecked operation capability.
    func sceneDidEnterBackground() {
        guard !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress,
            isCloudLoggedOut, original == nil, retainedIntent == nil, task == nil,
            detachedPresentationWork == nil, candidateMounted,
            let session = detachedInventory, let context = detachedContext,
            let bootstrap, let authority = bootstrap.currentAuthority,
            let host = commonHost, !host.lifetime.isRetired,
            let content, let lifetime = presentationLifetime, !lifetime.isRetired,
            let runtime = presentationRuntime, runtime.content === content,
            presentationActivityDomain == .detachedLocal, presentationHost === host, let pauseID = host.pauseRetainingRuntime() else {
            didEnterBackground()
            return
        }
        // Close the independent Host gate first, then fence document/effect
        // epochs synchronously even if SwiftUI never observes the paused value.
        lifetime.suspendPresentation()
        let retained = RetainedDetachedScene(id: UUID(), pauseID: pauseID,
            bootstrap: bootstrap, authority: authority, session: session, context: context,
            host: host, content: content, runtime: runtime, lifetime: lifetime,
            generationID: content.generationID, entryID: content.entryID)
        retainedDetachedScene = retained
        sceneIsForeground = false
        retainedSceneResume?.cancel()
        pendingRetainedSceneReconnect = nil
        retainedScenePresentationPaused = true
        displayInventoryForeground = false; invalidateDisplayInventory()
        pendingDetachedForegroundReconnect = nil
        presence.stop(); realtime.stop(); presenceContext = nil
        explicitConnectionOperationID = nil; completedExplicitConnectionOperationID = nil
        temporaryPoll?.cancel(); temporaryPoll = nil; temporaryExpiry?.cancel(); temporaryExpiry = nil
        if let driver = temporaryDriver { Task { await driver.cancel() } }
        temporaryDriver = nil
    }
    private func hasRetainedSceneOwner(_ retained: RetainedDetachedScene) -> Bool {
        !factoryResetInProgress && !intentRetirementPending && !disconnectInProgress && isCloudLoggedOut && original == nil
            && bootstrap === retained.bootstrap && retained.bootstrap.currentAuthority === retained.authority
            && detachedInventory === retained.session && detachedContext === retained.context
            && commonHost === retained.host && !retained.host.lifetime.isRetired
            && content === retained.content && presentationLifetime === retained.lifetime && !retained.lifetime.isRetired
            && presentationRuntime === retained.runtime && presentationHost === retained.host
            && presentationActivityDomain == .detachedLocal && candidateMounted
            && retained.content.generationID == retained.generationID && retained.content.entryID == retained.entryID
    }
    private func cancelRetainedSceneResume(cancelWork: Bool = true) {
        retainedDetachedScene = nil
        if cancelWork { retainedSceneResume?.cancel() }
        // Keep the slot until its noninterruptible synchronous verification has
        // actually drained; a newer foreground request joins via the defer.
        retainedScenePresentationPaused = false
    }
    private func replayRetainedSceneReconnect() {
        guard let request = pendingRetainedSceneReconnect else { return }
        pendingRetainedSceneReconnect = nil
        guard sceneIsForeground, retainedSceneResume == nil,
            !factoryResetInProgress, !intentRetirementPending, !disconnectInProgress,
            bootstrap === request.bootstrap, request.bootstrap.currentAuthority === request.authority,
            retainedCommonRootID == request.commonRootID else { return }
        reconnectInstallation(bootstrap: request.bootstrap)
    }
    /// Returns true when this invocation belongs to the retained-frame path.
    /// No graph/authority IO is performed in the scene activation callback.
    private func resumeRetainedDetachedScene(bootstrap: DeviceManagementBootstrap) -> Bool {
        guard let retained = retainedDetachedScene else { return false }
        guard retained.bootstrap === bootstrap, hasRetainedSceneOwner(retained) else {
            didEnterBackground()
            sceneIsForeground = true; displayInventoryForeground = true
            return false
        }
        guard retainedSceneResume == nil else { return true }
        let id = UUID(); retainedSceneResumeID = id; retainedSceneResumeSceneID = retained.id
        retainedSceneResume = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.retainedSceneResumeID == id {
                    self.retainedSceneResumeID = nil; self.retainedSceneResumeSceneID = nil; self.retainedSceneResume = nil
                    self.replayRetainedSceneReconnect()
                }
            }
            do {
                try await retained.host.drainRetainedPause(retained.pauseID)
                try Task.checkCancellation()
                guard self.sceneIsForeground, self.retainedDetachedScene?.id == retained.id,
                    self.hasRetainedSceneOwner(retained) else { return }
                let verifier = RetainedSceneVerifier(authority: retained.authority, context: retained.context,
                    session: retained.session, runtime: retained.runtime,
                    generationID: retained.generationID, entryID: retained.entryID)
                let worker = Task.detached(priority: .userInitiated) { try verifier.validate() }
                let validation = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard self.sceneIsForeground, self.retainedDetachedScene?.id == retained.id,
                    self.hasRetainedSceneOwner(retained) else { return }
                self.retainDisplayInventory(validation.association, session: retained.session)
                if validation.sameSelection {
                    guard retained.host.activateRetainedResume(retained.pauseID) else { throw NativeEnrollmentActionFailure.authorityUnavailable }
                    self.retainedDetachedScene = nil
                    self.retainedScenePresentationPaused = false
                } else {
                    // Current selection changed while paused. Retire the old
                    // proof before opening admission, then use the normal issuer
                    // and genuine mounted callback for the current selection.
                    do {
                        self.retirePresentation(cancelRetainedResume: false)
                        guard retained.host.activateRetainedResume(retained.pauseID) else { throw NativeEnrollmentActionFailure.authorityUnavailable }
                        try await self.presentDetachedLocal(retained.session)
                    }
                    catch {
                        guard !(error is CancellationError), !Task.isCancelled, self.sceneIsForeground,
                            self.detachedInventory === retained.session, self.detachedContext === retained.context,
                            self.commonHost === retained.host, self.bootstrap?.currentAuthority === retained.authority else { return }
                        self.logLocalStartupFailure(error, phase: .localHostSetup)
                        self.didEnterBackground()
                        self.state = .needsAttention
                        self.deliveryMessage = "The local screen could not be displayed."
                    }
                }
            } catch {
                guard !(error is CancellationError), !Task.isCancelled, self.sceneIsForeground,
                    self.retainedDetachedScene?.id == retained.id, self.hasRetainedSceneOwner(retained) else { return }
                self.logLocalStartupFailure(error, phase: .localHostSetup)
                self.didEnterBackground()
                self.state = .needsAttention
                self.disconnectMessage = self.localConnectionFailureMessage(error)
            }
        }
        return true
    }
    func didEnterBackground() {
        sceneIsForeground = false
        detachedRestoreEpoch = UUID(); recordedDetachedRestorePending = false
        pendingRetainedSceneReconnect = nil
        cancelRetainedSceneResume()
        displayInventoryForeground = false
        invalidateDisplayInventory()
        pendingDetachedForegroundReconnect = nil
        presence.stop(); realtime.stop(); presenceContext = nil
        explicitConnectionOperationID = nil; completedExplicitConnectionOperationID = nil
        if factoryResetInProgress { retirePresentation(); return }
        temporaryPoll?.cancel(); temporaryPoll = nil
        temporaryExpiry?.cancel(); temporaryExpiry = nil
        if let driver = temporaryDriver { Task { await driver.cancel() } }
        temporaryDriver = nil
        task?.cancel(); retirePresentation()
        commonHost?.retireForReset(); commonHost = nil
        if let detachedContext, let authority = bootstrap?.currentAuthority {
            try? authority.retireDetachedLocalContext(detachedContext)
            self.detachedContext = nil; detachedInventory = nil
        }
        if let original {
            if original.result == nil { original.foregroundRevoked = true }
            try? original.authority.leaveCloudForeground()
        }
        context = nil
        if original?.result != nil {
            retainedIntent = try? intentJournal.load()
            original = nil
        }
        if state == .enrolling || state == .currentInstallation { state = .needsAttention }
    }
}

/// Small, fixed vocabulary only. Never exposes private server messages, paths or credentials.
struct NativeEnrollmentFailureDiagnostic: Equatable {
    enum Stage: String, CaseIterable {
        case action, selection, metadata, viewport, authority, configuration, originalRequest, layout
        case legacyMigration, managedNamespace, managedStores, credentialSession, enrollment
        case installationBinding, installationStatus, screenDelivery
        var progressMessage: String {
            switch self {
            case .action: return "Checking the original connection operation…"
            case .selection: return "Checking the selected workspace and location…"
            case .metadata, .viewport: return "Checking this device…"
            case .authority, .configuration, .originalRequest, .layout: return "Preparing the original connection request…"
            case .legacyMigration: return "Preserving existing screens and local pairings…"
            case .managedNamespace, .managedStores, .credentialSession: return "Preparing secure device storage…"
            case .enrollment: return "Connecting this device to the workspace…"
            case .installationBinding, .installationStatus: return "Checking the enrolled device connection…"
            case .screenDelivery: return "Checking the workspace screen…"
            }
        }
        var label: String {
            switch self {
            case .action: return "operation checks"
            case .selection: return "workspace authorization"
            case .metadata: return "device information"
            case .viewport: return "display dimensions"
            case .authority: return "device authority"
            case .configuration: return "cloud configuration"
            case .originalRequest: return "original request"
            case .layout: return "enrollment layout"
            case .legacyMigration: return "existing screen preservation"
            case .managedNamespace: return "secure storage preparation"
            case .managedStores: return "protected device storage"
            case .credentialSession: return "credential preparation"
            case .enrollment: return "enrollment"
            case .installationBinding: return "device connection binding"
            case .installationStatus: return "device connection status"
            case .screenDelivery: return "screen delivery"
            }
        }
    }
    enum Category: String { case cancelled, authorization, configuration, invalidInput, originalChanged, localState, transport, busy, resetInProgress, retirementPending, journalPath, journalRead, journalRecord, journalWrite, namespacePath, namespaceAccess, namespaceRead, namespaceChanged, authorityExpired, resetConflict, nativeStore, nativeCredential, grantCredential }
    let stage: Stage
    let category: Category
    /// Built only from fixed typed diagnostic enums, never arbitrary Error text.
    let detail: String?
    let localDiagnostic: NativeEnrollmentLocalFailureDiagnostic?
    let credentialDiagnostic: NativeEnrollmentKeychainBackend.FailureDiagnostic?
    init(stage: Stage, error: Error) {
        self.stage = stage
        let local = NativeEnrollmentLocalFailureDiagnostic.classify(error)
        let credential = NativeEnrollmentKeychainBackend.diagnostic(for: error)
        localDiagnostic = local; credentialDiagnostic = credential
        detail = local.map { $0.domain.rawValue + "/" + $0.reason.rawValue }
            ?? credential.map { $0.domain.rawValue + "/" + $0.reason.rawValue }
        if local != nil { category = .nativeStore }
        else if let credential { category = credential.domain == .grantCredential ? .grantCredential : .nativeCredential }
        else if let failure = error as? NativeEnrollmentActionFailure {
            switch failure {
            case .originalChanged: category = .originalChanged
            case .authorityUnavailable: category = .localState
            case .invalidViewport, .unsupportedDevice: category = .invalidInput
            case .busy: category = .busy
            case .resetInProgress: category = .resetInProgress
            case .retirementPending: category = .retirementPending
            }
        } else if let failure = error as? NativeEnrollmentIntentFailure {
            switch failure.reason {
            case .unsafePath, .invalidNode, .linkedFile: category = .journalPath
            case .readUnavailable: category = .journalRead
            case .invalidRecord, .capacity: category = .journalRecord
            case .changedOriginal: category = .originalChanged
            case .publication: category = .journalWrite
            case .retired: category = .retirementPending
            }
        } else if let failure = error as? DeviceNativeManagedRootFailure {
            switch failure {
            case .invalidLocator: category = .namespacePath
            case .unavailable(let code): category = code == EPERM || code == EACCES ? .namespaceAccess : .namespaceRead
            case .changedAnchor, .changedNamespace: category = .namespaceChanged
            }
        } else if let failure = error as? DeviceManagementAuthority.Failure {
            switch failure {
            case .staleLease, .noResetAttempt: category = .authorityExpired
            case .reentrantOperation: category = .busy
            case .resetConflict: category = .resetConflict
            }
        } else if error is URLError { category = .transport }
        else if stage == .selection { category = .authorization }
        else if stage == .configuration { category = .configuration }
        else if error is CancellationError { category = .cancelled }
        else { category = .localState }
    }
    func message(installationEnrolled: Bool, originalRetention: NativeEnrollmentRequestRetention = .uncertain) -> String {
        if stage == .screenDelivery, let localDiagnostic {
            if localDiagnostic.reason == .unsupportedCapabilities {
                return "This screen uses connections or features that Cloud delivery on this device does not support. Your setup and existing screens are retained. Reconnecting cannot retry a completed failed delivery. Use a supported screen, then review and confirm a new deployment."
            }
            if localDiagnostic.domain == .packageArchive || localDiagnostic.domain == .packageCompatibility {
                return "The screen package could not be verified for this device. Your setup and existing screens are retained. Check the screen’s device profile and package, then review and confirm a new deployment."
            }
        }
        switch category {
        case .busy: return "The original connection operation is already running. Wait for it to finish."
        case .resetInProgress: return "A device reset is still running. Wait for it to finish before connecting."
        case .retirementPending: return "The original device reset needs local cleanup. Use Recover reset before connecting."
        default: break
        }
        let prefix = installationEnrolled ? "This device is enrolled, but its screen connection needs attention" : "Device connection needs attention"
        let guidance: String
        switch category {
        case .originalChanged: guidance = "Return to the original workspace, location and device name to retry the same request."
        case .authorization: guidance = "Check sign-in and the original workspace and location, then retry the same request."
        case .configuration: guidance = "Cloud configuration needs attention before this request can continue."
        case .invalidInput: guidance = "Check the device name and display information, then retry."
        case .cancelled: guidance = originalRetention.guidance + " Reopen Cloud account and retry."
        case .localState: guidance = originalRetention.guidance + " Tap Retry connection to try again."
        case .journalPath, .journalRead, .journalRecord, .journalWrite:
            guidance = originalRetention.guidance + " Request storage needs attention. Tap Retry connection to try again."
        case .namespacePath, .namespaceAccess, .namespaceRead, .namespaceChanged:
            guidance = originalRetention.guidance + " Secure device storage could not be verified. Tap Retry connection to try again."
        case .nativeStore:
            guidance = originalRetention.guidance + " Secure enrollment storage needs attention. Tap Retry connection to try again."
        case .nativeCredential, .grantCredential:
            guidance = originalRetention.guidance + " Secure enrollment credentials could not be verified. Tap Retry connection to try again."
        case .authorityExpired:
            guidance = "Device connection authorization expired. Reopen Cloud account and retry the same request."
        case .resetConflict:
            guidance = "Device reset needs attention. Reopen Cloud account and choose Retry connection."
        case .transport: guidance = "Check the network connection, then retry the same request."
        case .busy, .resetInProgress, .retirementPending: guidance = "Wait for the original operation to finish before connecting."
        }
        return "\(prefix). \(guidance)"
    }
}
private enum NativeEnrollmentActionFailure: Error { case originalChanged, authorityUnavailable, invalidViewport, unsupportedDevice, busy, resetInProgress, retirementPending }
enum NativeEnrollmentActionInput {
    @MainActor static func fullScreenViewport() throws -> CGSize {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw NativeEnrollmentActionFailure.invalidViewport
        }
        return try screenViewport(screen: scene.screen.bounds.size, landscape: scene.interfaceOrientation.isLandscape)
    }
    static func screenViewport(screen: CGSize, landscape: Bool) throws -> CGSize {
        try validateViewport(screen)
        let short = min(screen.width, screen.height), long = max(screen.width, screen.height)
        return landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }
    static func requiresRecordedRoots(installationRecorded: Bool, namespacePresent: Bool) -> Bool {
        installationRecorded || namespacePresent
    }
    static func validateViewport(_ viewport: CGSize) throws {
        guard viewport.width.isFinite, viewport.height.isFinite,
            viewport.width.rounded() >= 1, viewport.height.rounded() >= 1,
            viewport.width <= 16384, viewport.height <= 16384 else { throw NativeEnrollmentActionFailure.invalidViewport }
    }
    static func requireOriginal(_ retained: NativeEnrollmentIntentRecord, accountID: UUID, locationID: UUID?, name: String, origin: URL) throws {
        guard retained.accountID == accountID, retained.locationID == locationID,
            retained.name.utf8.elementsEqual(name.utf8), retained.origin == origin.absoluteString else { throw NativeEnrollmentActionFailure.originalChanged }
    }
    static func requireSameOriginal(_ retained: NativeEnrollmentIntentRecord, pending: NativeEnrollmentIntentRecord) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var completed = pending; completed.restoreRecordedInstallation = true
        let retainedBytes = try encoder.encode(retained)
        let pendingBytes = try encoder.encode(pending), completedBytes = try encoder.encode(completed)
        guard retainedBytes == pendingBytes || retainedBytes == completedBytes else {
            throw NativeEnrollmentIntentFailure(.changedOriginal, retention: .retained)
        }
    }
    static func protectedRoots(stateRoot: URL, reset: URL, journal: URL, management: URL, preferences: URL) -> NativeManagedProtectedRoots {
        // Preserve the original package/grant scope across app versions. Core's
        // adapter removes only this exact redundant legacy alias for provisioning.
        NativeManagedProtectedRoots(legacyState: stateRoot, legacyArchive: stateRoot,
            reset: reset, cloudEnrollment: journal, management: management, preferences: preferences)
    }
}

enum NativeEnrollmentRequestRetention: String {
    case notSaved, retained, uncertain
    var guidance: String {
        switch self {
        case .notSaved: return "Your setup has not been saved yet."
        case .retained: return "Your setup is saved."
        case .uncertain: return "We could not confirm whether your setup was saved."
        }
    }
}
struct NativeEnrollmentIntentFailure: Error, Equatable {
    enum Reason: String { case unsafePath, invalidNode, linkedFile, readUnavailable, invalidRecord, capacity, changedOriginal, publication, retired }
    let reason: Reason
    let retention: NativeEnrollmentRequestRetention
    init(_ reason: Reason, retention: NativeEnrollmentRequestRetention = .uncertain) { self.reason = reason; self.retention = retention }
}

/// Nonsecret identifiers only. Provider and installation credentials remain in
/// Keychain; loading this record never grants device authority.
struct NativeEnrollmentIntentRecord: Codable, Equatable {
    let version: Int
    let accountID: UUID, locationID: UUID?
    let name: String, profile: String, origin: String
    let width: Int, height: Int
    let preparationID: UUID, enrollmentID: UUID, transitionID: UUID, requestID: UUID
    let credentialGenerationID: UUID, credentialReference: String, stageReference: String
    let activationRequestID: UUID, associationAttemptID: UUID, cloudRootID: UUID
    let packageRootID: UUID, grantRootID: UUID, structuralRootID: UUID, provisioningRootID: UUID, contentGenesisID: UUID
    let commonInventoryRootID: UUID?
    let unifiedMigrationOperationID: UUID?, unifiedMigrationGenerationID: UUID?
    let firstDeliveryNativeOperationID: UUID?, firstDeliveryGrantOperationID: UUID?, firstDeliveryGrantRevisionID: UUID?, firstDeliveryActivationRequestID: UUID?
    let legacyPackageRootID: UUID?, legacyGrantRootID: UUID?, legacyStructuralRootID: UUID?, legacyProvisioningRootID: UUID?
    let legacyEntryIDs: [String: UUID]?, legacyPackageOperationIDs: [String: UUID]?
    let legacyMigrationRequired: Bool?
    let legacyOperationID: UUID?, legacyGrantOperationID: UUID?, legacyGenerationID: UUID?, legacyGrantRevisionID: UUID?
    var restoreRecordedInstallation = false
    init(accountID: UUID, locationID: UUID?, name: String, profile: String, origin: URL, viewport: CGSize, legacyDashboardIDs: [String] = [], legacyOwnerPresent: Bool = false, reusingCommonRootID: UUID? = nil) throws {
        try NativeEnrollmentActionInput.validateViewport(viewport)
        version = 1; self.accountID = accountID; self.locationID = locationID; self.name = name; self.profile = profile
        self.origin = origin.absoluteString; width = Int(viewport.width.rounded()); height = Int(viewport.height.rounded())
        preparationID = UUID(); enrollmentID = UUID(); transitionID = UUID(); requestID = UUID(); credentialGenerationID = UUID()
        credentialReference = "native." + UUID().uuidString.lowercased(); stageReference = "stage." + UUID().uuidString.lowercased()
        activationRequestID = UUID(); associationAttemptID = UUID(); cloudRootID = UUID(); commonInventoryRootID = reusingCommonRootID ?? UUID(); unifiedMigrationOperationID = UUID(); unifiedMigrationGenerationID = UUID()
        firstDeliveryNativeOperationID = UUID(); firstDeliveryGrantOperationID = UUID(); firstDeliveryGrantRevisionID = UUID(); firstDeliveryActivationRequestID = UUID()
        packageRootID = UUID(); grantRootID = UUID(); structuralRootID = UUID(); provisioningRootID = UUID(); contentGenesisID = UUID()
        guard legacyDashboardIDs.count <= 12, Set(legacyDashboardIDs).count == legacyDashboardIDs.count else { throw NativeEnrollmentIntentFailure(.invalidRecord, retention: .notSaved) }
        legacyPackageRootID = UUID(); legacyGrantRootID = UUID(); legacyStructuralRootID = UUID(); legacyProvisioningRootID = UUID()
        legacyMigrationRequired = legacyOwnerPresent
        legacyEntryIDs = Dictionary(uniqueKeysWithValues: legacyDashboardIDs.map { ($0, UUID()) })
        legacyPackageOperationIDs = Dictionary(uniqueKeysWithValues: legacyDashboardIDs.map { ($0, UUID()) })
        legacyOperationID = UUID(); legacyGrantOperationID = UUID(); legacyGenerationID = UUID(); legacyGrantRevisionID = UUID()
        _ = try proposal(); _ = try localIDs()
    }
    func proposal() throws -> NativeFirstEnrollmentPreparation {
        guard version == 1, width > 0, height > 0, width <= 16384, height <= 16384,
            let originURL = URL(string: origin), try NativeOperationalInstallation.validatedOrigin(originURL) == originURL else { throw NativeEnrollmentIntentFailure(.invalidRecord) }
        let claim = try NativeClaimInput(requestId: requestID, transitionId: transitionID,
            accountId: accountID, locationId: locationID, name: name, profile: profile)
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: credentialGenerationID,
            transitionID: transitionID, credentialReference: credentialReference, format: .nativeInstallationV1)
        return try .init(preparationId: preparationID, enrollmentId: enrollmentID,
            stageReference: stageReference, binding: binding, claimInput: claim)
    }
    func localIDs() throws -> NativeManagedLocalRootIDs {
        try .init(package: packageRootID, grant: grantRootID, structural: structuralRootID,
            provisioning: provisioningRootID, contentGenesis: contentGenesisID)
    }
}

/// Each original journal instance owns one write generation. Reset drains mutations
/// under this lock and permanently closes it; a fresh enrollment gets a new fence.
private final class NativeEnrollmentIntentWriteFence {
    private let lock = NSRecursiveLock()
    private var retired = false
    func mutate<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { throw NativeEnrollmentIntentFailure(.retired) }
        return try operation()
    }
    func freeze<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        retired = true
        return try operation()
    }
}
/// A stable sibling of device state; never removed by local unpairing. Every
/// publication is bounded, atomic and fsynced before enrollment may proceed.
struct NativeEnrollmentIntentJournal {
    let directory: URL
    private let writeFence: NativeEnrollmentIntentWriteFence
    init(directory: URL) { self.directory = directory; writeFence = .init() }
    func freezeWritesForReset<T>(_ operation: () throws -> T) throws -> T {
        try writeFence.freeze(operation)
    }
    static func application() -> Self {
        let requested = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let parent = requested.deletingLastPathComponent()
        let base: URL
        if let physical = realpath(parent.path, nil) {
            defer { free(physical) }
            base = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                .appendingPathComponent(requested.lastPathComponent, isDirectory: true)
        } else { base = requested }
        return .init(directory: base.appendingPathComponent("xyz.screenpunk.enrollment-intent", isDirectory: true))
    }
    private var file: URL { directory.appendingPathComponent("original.json") }
    func load() throws -> NativeEnrollmentIntentRecord? {
        guard let directoryFD = try physicalDescriptor(directory, directory: true, allowMissing: true) else { return nil }
        defer { close(directoryFD) }
        guard let fd = try physicalDescriptor(file, directory: false, allowMissing: true) else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
        guard before.st_size >= 0, before.st_size <= 16384 else { throw NativeEnrollmentIntentFailure(.capacity) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
            if count == 0 { break }
            guard data.count + count <= 16384 else { throw NativeEnrollmentIntentFailure(.capacity) }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let namedFD = try physicalDescriptor(file, directory: false) else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
        defer { close(namedFD) }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, fstat(namedFD, &named) == 0,
            held.st_dev == before.st_dev, held.st_ino == before.st_ino, held.st_size == before.st_size,
            named.st_dev == held.st_dev, named.st_ino == held.st_ino, named.st_size == held.st_size else { throw NativeEnrollmentIntentFailure(.unsafePath) }
        do {
            let record = try JSONDecoder().decode(NativeEnrollmentIntentRecord.self, from: data)
            _ = try record.proposal(); _ = try record.localIDs()
            return record
        } catch { throw NativeEnrollmentIntentFailure(.invalidRecord) }
    }
    func saveOriginal(_ record: NativeEnrollmentIntentRecord) throws {
        if let previous = try load() {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let priorBytes = try encoder.encode(previous), requestedBytes = try encoder.encode(record)
            guard priorBytes == requestedBytes else { throw NativeEnrollmentIntentFailure(.changedOriginal, retention: .retained) }
            try writeFence.mutate {
                guard let fd = try physicalDescriptor(file, directory: false) else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
                defer { close(fd) }
                guard let parent = try physicalDescriptor(directory, directory: true) else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
                defer { close(parent) }
                guard fsync(fd) == 0, fsync(parent) == 0 else { throw NativeEnrollmentIntentFailure(.publication) }
            }
            return
        }
        do { try publish(record) }
        catch let failure as NativeEnrollmentIntentFailure {
            throw NativeEnrollmentIntentFailure(failure.reason, retention: failure.reason == .retired ? .notSaved : failure.retention)
        }
    }
    func discoverCommonRootID() throws -> UUID? {
        let root = directory.deletingLastPathComponent().appendingPathComponent("xyz.screenpunk.unified-inventory", isDirectory: true)
        guard let fd = try physicalDescriptor(root.appendingPathComponent("mixed-root.json"), directory: false, allowMissing: true) else { return nil }
        defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 8192 else { throw NativeEnrollmentIntentFailure(.invalidRecord) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard read(fd, &bytes, bytes.count) == bytes.count,
            let object = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
            let id = object["rootID"] as? String, let result = UUID(uuidString: id) else { throw NativeEnrollmentIntentFailure(.invalidRecord) }
        return result // Discovery only; Core independently verifies the root/CAS/resources.
    }
    func retireDisconnectedOriginal(association: DeviceDetachedLocalInventoryAssociation) throws {
        try association.validateCurrent()
        guard association.metadata.cleanupCompleted else { throw NativeEnrollmentIntentFailure(.publication) }
        try writeFence.mutate {
            guard let prior = try load() else { return }
            guard prior.commonInventoryRootID == association.metadata.commonRootID else { throw NativeEnrollmentIntentFailure(.changedOriginal) }
            // A later fresh Connect must never be retired with its predecessor.
            guard prior.transitionID == association.metadata.retiredTransitionID else { return }
            let parent = try physicalDescriptor(directory, directory: true)
            guard let parent else { throw NativeEnrollmentIntentFailure(.readUnavailable) }; defer { close(parent) }
            guard let original = try physicalDescriptor(file, directory: false) else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
            defer { close(original) }
            var held = stat(), named = stat()
            guard fstat(original, &held) == 0,
                fstatat(parent, file.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1 else { throw NativeEnrollmentIntentFailure(.unsafePath) }
            try association.validateCurrent()
            guard unlinkat(parent, file.lastPathComponent, 0) == 0 else { throw NativeEnrollmentIntentFailure(.publication) }
            guard fsync(parent) == 0 else { throw NativeEnrollmentIntentFailure(.publication) }
            try association.validateCurrent()
        }
    }
    func markRecordedInstallation(_ original: NativeEnrollmentIntentRecord) throws {
        var marked = original; marked.restoreRecordedInstallation = true
        guard let previous = try load() else { throw NativeEnrollmentIntentFailure(.changedOriginal, retention: .notSaved) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let previousBytes = try encoder.encode(previous)
        let originalBytes = try encoder.encode(original), markedBytes = try encoder.encode(marked)
        guard previousBytes == originalBytes || previousBytes == markedBytes else { throw NativeEnrollmentIntentFailure(.changedOriginal, retention: .retained) }
        // The previous publication may have reached disk before its durability
        // acknowledgement failed. Re-publish/sync only the exact same successor;
        // unrelated, changed or corrupt requests never become completion evidence.
        try publish(marked)
    }
    private func publish(_ record: NativeEnrollmentIntentRecord) throws {
        try writeFence.mutate { try publishUnlocked(record) }
    }
    private func publishUnlocked(_ record: NativeEnrollmentIntentRecord) throws {
        var publicationStarted = false
        do {
            _ = try record.proposal(); _ = try record.localIDs()
            if try physicalDescriptor(directory, directory: true, allowMissing: true).map({ fd in close(fd); return true }) != true {
                try requirePhysical(directory.deletingLastPathComponent(), directory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            try requirePhysical(directory, directory: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            guard data.count <= 16384 else { throw NativeEnrollmentIntentFailure(.capacity, retention: .notSaved) }
            publicationStarted = true
            try data.write(to: file, options: .atomic)
            guard let fd = try physicalDescriptor(file, directory: false) else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw NativeEnrollmentIntentFailure(.publication) }
            guard let parent = try physicalDescriptor(directory, directory: true) else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw NativeEnrollmentIntentFailure(.publication) }
        } catch let failure as NativeEnrollmentIntentFailure {
            throw NativeEnrollmentIntentFailure(failure.reason, retention: publicationStarted ? .uncertain : .notSaved)
        } catch { throw NativeEnrollmentIntentFailure(.publication, retention: publicationStarted ? .uncertain : .notSaved) }
    }
    private func requirePhysical(_ url: URL, directory: Bool) throws {
        guard let fd = try physicalDescriptor(url, directory: directory) else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
        close(fd)
    }
    /// Traverse below the OS-authorized physical container on iOS. Caller path
    /// components are never resolved or rewritten; named and held nodes must agree.
    private func physicalDescriptor(_ url: URL, directory: Bool, allowMissing: Bool = false) throws -> Int32? {
        guard url.isFileURL else { throw NativeEnrollmentIntentFailure(.unsafePath) }
        let traversal: DeviceFilesystemTraversal
        do { traversal = try .plan(for: url.path) } catch { throw NativeEnrollmentIntentFailure(.unsafePath) }
        var fd = open(traversal.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
        do {
            var root = stat()
            guard fstat(fd, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else { throw NativeEnrollmentIntentFailure(.invalidNode) }
            if traversal.components.isEmpty && !directory { throw NativeEnrollmentIntentFailure(.invalidNode) }
            for (index, component) in traversal.components.enumerated() {
                let isDirectory = index < traversal.components.count - 1 || directory
                var named = stat()
                if fstatat(fd, component, &named, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT && allowMissing { close(fd); return nil }
                    throw NativeEnrollmentIntentFailure(.readUnavailable)
                }
                guard named.st_mode & S_IFMT != S_IFLNK else { throw NativeEnrollmentIntentFailure(.unsafePath) }
                guard named.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG) else { throw NativeEnrollmentIntentFailure(.invalidNode) }
                guard isDirectory || named.st_nlink == 1 else { throw NativeEnrollmentIntentFailure(.linkedFile) }
                let next = openat(fd, component, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (isDirectory ? O_DIRECTORY : 0))
                guard next >= 0 else { throw NativeEnrollmentIntentFailure(.readUnavailable) }
                var held = stat(), current = stat()
                guard fstat(next, &held) == 0, fstatat(fd, component, &current, AT_SYMLINK_NOFOLLOW) == 0,
                    held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                    current.st_dev == held.st_dev, current.st_ino == held.st_ino,
                    current.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG), isDirectory || held.st_nlink == 1 else {
                    close(next); throw NativeEnrollmentIntentFailure(.unsafePath)
                }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

}

private struct NativeIncomingCloudIntent: Codable {
    let installationID: UUID
    let commandID: UUID
    let nativeOperationID: UUID
    let packageRootID: UUID
    let grantOperationID: UUID
    let grantRevisionID: UUID
    let activationRequestID: UUID
}
extension NativeEnrollmentIntentJournal {
    fileprivate func retainCloudCommand(_ commandID: UUID, installation: UUID) throws -> NativeIncomingCloudIntent {
        try writeFence.mutate { try retainCloudCommandUnlocked(commandID, installation: installation) }
    }
    private func retainCloudCommandUnlocked(_ commandID: UUID, installation: UUID) throws -> NativeIncomingCloudIntent {
        try requirePhysical(directory, directory: true)
        let file = directory.appendingPathComponent("cloud-command-" + commandID.uuidString.lowercased() + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            try requirePhysical(file, directory: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4096 else { throw CancellationError() }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.count <= 4096 else { throw CancellationError() }
            let value = try JSONDecoder().decode(NativeIncomingCloudIntent.self, from: data)
            guard value.commandID == commandID, value.installationID == installation else { throw CancellationError() }
            return value
        }
        let retained = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("cloud-command-") }
        guard retained.count < 4096 else { throw CancellationError() }
        let value = NativeIncomingCloudIntent(installationID: installation, commandID: commandID,
            nativeOperationID: UUID(), packageRootID: UUID(), grantOperationID: UUID(),
            grantRevisionID: UUID(), activationRequestID: UUID())
        let data = try JSONEncoder().encode(value)
        guard data.count <= 4096 else { throw CancellationError() }
        try data.write(to: file, options: .atomic)
        try requirePhysical(file, directory: false)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CancellationError() }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw CancellationError() }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CancellationError() }; defer { close(parent) }
        guard fsync(parent) == 0 else { throw CancellationError() }
        return value
    }
}

private struct NativeIncomingLocalIntent: Codable {
    let installation: UUID
    let operation: UUID
    let package: UUID, grant: UUID, structural: UUID, provisioning: UUID, genesis: UUID
    let grantOperation: UUID, generation: UUID, grantRevision: UUID
    let packages: [String: UUID]
    func rootIDs() throws -> NativeManagedLocalRootIDs {
        try .init(package: package, grant: grant, structural: structural, provisioning: provisioning, contentGenesis: genesis)
    }
}
extension NativeEnrollmentIntentJournal {
    fileprivate func loadLocalCommand(_ operation: UUID, installation: UUID? = nil) throws -> NativeIncomingLocalIntent {
        try requirePhysical(directory, directory: true)
        let file = directory.appendingPathComponent("local-command-" + operation.uuidString.lowercased() + ".json")
        try requirePhysical(file, directory: false)
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard (size?.intValue ?? Int.max) <= 4096 else { throw CancellationError() }
        let value = try JSONDecoder().decode(NativeIncomingLocalIntent.self, from: Data(contentsOf: file))
        guard (installation == nil || value.installation == installation), value.operation == operation else { throw CancellationError() }
        _ = try value.rootIDs(); return value
    }
    fileprivate func retainLocalCommand(_ operation: UUID, installation: UUID, screens: [DeviceLegacyMigrationScreen]) throws -> NativeIncomingLocalIntent {
        try writeFence.mutate { try retainLocalCommandUnlocked(operation, installation: installation, screens: screens) }
    }
    private func retainLocalCommandUnlocked(_ operation: UUID, installation: UUID, screens: [DeviceLegacyMigrationScreen]) throws -> NativeIncomingLocalIntent {
        try requirePhysical(directory, directory: true)
        let file = directory.appendingPathComponent("local-command-" + operation.uuidString.lowercased() + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            try requirePhysical(file, directory: false)
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard (size?.intValue ?? Int.max) <= 4096 else { throw CancellationError() }
            let value = try JSONDecoder().decode(NativeIncomingLocalIntent.self, from: Data(contentsOf: file))
            guard value.installation == installation, value.operation == operation,
                Set(value.packages.keys) == Set(screens.map { $0.entryIdentity.uuidString.lowercased() }) else { throw CancellationError() }
            _ = try value.rootIDs(); return value
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.filter({ $0.lastPathComponent.hasPrefix("local-command-") }).count < 4096 else { throw CancellationError() }
        let value = NativeIncomingLocalIntent(installation: installation, operation: operation,
            package: UUID(), grant: UUID(), structural: UUID(), provisioning: UUID(), genesis: UUID(),
            grantOperation: UUID(), generation: UUID(), grantRevision: UUID(),
            packages: Dictionary(uniqueKeysWithValues: screens.map { ($0.entryIdentity.uuidString.lowercased(), $0.packagePreparationIdentity) }))
        _ = try value.rootIDs()
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try requirePhysical(file, directory: false)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CancellationError() }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw CancellationError() }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CancellationError() }; defer { close(parent) }
        guard fsync(parent) == 0 else { throw CancellationError() }
        return value
    }
}

private final class NativeRelayArchivePlan {
    private let lock = NSLock()
    private var retained: (UUID, UUID, NativeDeliveryPlanHTTPObservation, NativeCurrentInstallationDispatch)?
    func retain(installation: UUID, operation: UUID, plan: NativeDeliveryPlanHTTPObservation, current: NativeCurrentInstallationDispatch) {
        lock.lock(); defer { lock.unlock() }; retained = (installation, operation, plan, current)
    }
    func require(installation: UUID, operation: UUID, package: UUID, digest: String, count: Int) throws {
        lock.lock(); let original = retained; lock.unlock()
        guard let original, original.0 == installation, original.1 == operation else { throw CancellationError() }
        try original.2.requireRelayedArchive(current: original.3, packageID: package, digest: digest, byteCount: count)
    }
    func receive(installation: UUID, operation: UUID, package: UUID, bytes: Data) throws {
        lock.lock(); let original = retained; lock.unlock()
        guard let original, original.0 == installation, original.1 == operation else { throw CancellationError() }
        try original.2.retainRelayedArchive(current: original.3, packageID: package, bytes: bytes)
    }
}

/// Main-actor admission prevents presence from invalidating an in-flight delivery observation.
/// User work cancels and drains presence without occupying the controller's visible work slot.
@MainActor final class NativeEnrollmentPresenceScheduler {
    private let wait: (() async throws -> Void)?
    private(set) var reconciliationInterval: TimeInterval
    private var cadenceGeneration = UUID()
    private var timer: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var pause: Task<Void, Never>?
    private var wakeWaiter: CheckedContinuation<Void, Never>?
    private var reconciliationPending = false
    private var generation = UUID()
    private var mainWorkActive = false
    private var callbacks = 0
    private var callbackWaiters: [CheckedContinuation<Void, Never>] = []
    init(wait: (() async throws -> Void)? = nil, interval: TimeInterval = 60) {
        self.wait = wait; reconciliationInterval = interval
    }
    func setInterval(_ interval: TimeInterval) {
        guard reconciliationInterval != interval else { return }
        reconciliationInterval = interval; cadenceGeneration = UUID()
        // Re-arm the wait without turning a health transition into SQL work.
        if wakeWaiter != nil { releaseWaiter() }
    }
    var hasInFlightRequest: Bool { request != nil }
    func requestReconciliation() {
        reconciliationPending = true
        if !mainWorkActive, callbacks == 0 { releaseWaiter() }
    }
    private func releaseWaiter() {
        pause?.cancel(); pause = nil
        let waiter = wakeWaiter; wakeWaiter = nil; waiter?.resume()
    }
    private func waitForTick(_ expected: UUID) async -> Bool {
        if reconciliationPending, !mainWorkActive, callbacks == 0 { return true }
        let cadence = cadenceGeneration, interval = reconciliationInterval
        await withCheckedContinuation { continuation in
            wakeWaiter = continuation
            pause = Task { [weak self, wait] in
                do {
                    if let wait { try await wait() }
                    else { try await Task.sleep(for: .seconds(interval)) }
                } catch { return }
                guard let self, self.generation == expected else { return }
                self.releaseWaiter()
            }
        }
        return cadence == cadenceGeneration || reconciliationPending
    }
    func start(onFailure: @escaping () -> Void = {}, afterRequest: @escaping () -> Void = {}, send: @escaping () async throws -> Void) {
        stop()
        let current = generation
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let shouldReconcile = await self.waitForTick(current)
                guard !Task.isCancelled, self.generation == current else { return }
                guard shouldReconcile else { continue }
                guard !self.mainWorkActive, self.callbacks == 0 else { continue }
                self.reconciliationPending = false
                var succeeded = false
                let pending = Task {
                    do { try Task.checkCancellation(); try await send(); try Task.checkCancellation(); succeeded = true }
                    catch { if !Task.isCancelled { onFailure() } }
                }
                self.request = pending
                await pending.value
                if self.generation == current {
                    self.request = nil
                    if succeeded && !pending.isCancelled { afterRequest() }
                }
            }
        }
    }
    func setMainWorkActive(_ active: Bool) {
        mainWorkActive = active
        if active { if request != nil { reconciliationPending = true }; request?.cancel() }
        else if reconciliationPending { releaseWaiter() }
    }
    func beginCallback() { callbacks += 1; if request != nil { reconciliationPending = true }; request?.cancel() }
    func endCallback() {
        precondition(callbacks > 0); callbacks -= 1
        if callbacks == 0 {
            let waiting = callbackWaiters; callbackWaiters.removeAll(); waiting.forEach { $0.resume() }
            if reconciliationPending, !mainWorkActive { releaseWaiter() }
        }
    }
    func drainCallbacks() async {
        if callbacks > 0 { await withCheckedContinuation { callbackWaiters.append($0) } }
    }
    func drain() async { if let request { await request.value } }
    func stop() {
        generation = UUID(); timer?.cancel(); timer = nil; request?.cancel()
        reconciliationPending = false; releaseWaiter()
    }
}
