import Foundation
import Darwin
import SwiftUI
import Combine
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) import ScreenpunkCore
@_spi(NativeInstallation) @_spi(NativeInstallationDriver) import ScreenpunkApple

/// One explicit original enrollment in the retained scene. No automatic startup,
/// missing-state import, SDK construction, or historical receipt admission.
@MainActor final class NativeEnrollmentSceneController: ObservableObject {
    enum State: Equatable { case idle, enrolling, needsAttention, currentInstallation }
    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var original: Original?
    private var intentJournal: NativeEnrollmentIntentJournal
    private var retainedIntent: NativeEnrollmentIntentRecord?
    @Published private(set) var intentRetirementPending = false
    private weak var bootstrap: DeviceManagementBootstrap?
    @Published private(set) var commonHost: DeviceLANHost?
    private var temporaryPoll: Task<Void, Never>?
    private var temporaryExpiry: Task<Void, Never>?
    private var temporaryDriver: DeviceUnifiedTemporaryActivationDriver?
    init(intentJournal: NativeEnrollmentIntentJournal = .application()) {
        self.intentJournal = intentJournal
        do {
            retainedIntent = try intentJournal.load()
            if let retirement = try NativeEnrollmentIntentRetirement(original: intentJournal.directory).load(), retirement.phase != .retired {
                intentRetirementPending = true; state = .needsAttention
                deliveryMessage = "The original device reset has local enrollment cleanup to recover."
            } else if retainedIntent != nil, try DeviceLocalResetStore(directory: DeviceLocalResetStore.defaultDirectory()).load()?.phase == .completed,
                      try NativeEnrollmentIntentRetirement(original: intentJournal.directory).load() == nil {
                intentRetirementPending = true; state = .needsAttention
                deliveryMessage = "The completed reset's enrollment retirement record is missing. Retained files need support review before enrollment."
            }
        }
        catch { state = .needsAttention; deliveryMessage = "The retained enrollment request needs recovery." }
    }
    private var reportedMetadata: NativeEnrollmentDeviceMetadata?
    @Published private(set) var content: DeviceManagedStaticContent?
    @Published private(set) var deliveryMessage: String?
    private(set) var presentationLifetime: DeviceRuntimeLifetime?
    @Published private(set) var retainedDisplayContent: DeviceManagedStaticContent?
    private(set) var retainedDisplayLifetime: DeviceRuntimeLifetime?
    @Published private(set) var candidateMounted = false
    @Published private(set) var emptyDisplayGeneration: UUID?
    private var preparedRuntime: DeviceUnifiedManagedRuntime?
    private var presentationRuntime: DeviceUnifiedManagedRuntime?
    private var retainedDisplayRuntime: DeviceUnifiedManagedRuntime?
    private var presentationExpiry: Task<Void, Never>?
    private var presentationDispatch: NativeCurrentInstallationDispatch?
    private var humanObservations: [AnyCancellable] = []
    private weak var observedLifecycle: CloudHumanSessionLifecycle?
    private var revocationObserver: UUID?
    private var context: DeviceManagementAuthority.CloudInstallationContext?
    private final class Original {
        let selection: CloudEnrollmentSelection?, authority: DeviceManagementAuthority
        let proposal: NativeFirstEnrollmentPreparation, origin: URL
        let activationRequestID: UUID, associationAttemptID: UUID
        let intent: NativeEnrollmentIntentRecord
        let accountID: UUID, locationID: UUID?, name: String, profile: String
        let target: DeviceProfile
        let delivery: Delivery
        var restoring = false
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
             proposal: NativeFirstEnrollmentPreparation, origin: URL, name: String, profile: String, target: DeviceProfile, intent: NativeEnrollmentIntentRecord) {
            delivery = Delivery(intent: intent)
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
    struct PresentationFrame: Identifiable {
        let content: DeviceManagedStaticContent
        let lifetime: DeviceRuntimeLifetime
        let candidate: Bool
        let runtime: DeviceUnifiedManagedRuntime?
        var id: ObjectIdentifier { ObjectIdentifier(lifetime) }
    }
    var presentationFrames: [PresentationFrame] {
        var frames: [PresentationFrame] = []
        if let retainedDisplayContent, let retainedDisplayLifetime {
            frames.append(.init(content: retainedDisplayContent, lifetime: retainedDisplayLifetime, candidate: false, runtime: retainedDisplayRuntime))
        }
        if let content, let presentationLifetime {
            frames.append(.init(content: content, lifetime: presentationLifetime, candidate: true, runtime: presentationRuntime))
        }
        return frames
    }
    var retainedAccountID: UUID? { original?.accountID ?? retainedIntent?.accountID }
    var retainedLocationID: UUID? { original != nil ? original?.locationID : retainedIntent?.locationID }
    var retainedDeviceName: String? { original?.name ?? retainedIntent?.name }
    var retainedDeviceProfile: String? { original?.profile ?? retainedIntent?.profile }
    var suggestedDeviceName: String? { captureReportedMetadata()?.name }
    private func captureReportedMetadata() -> NativeEnrollmentDeviceMetadata? {
        if let reportedMetadata { return reportedMetadata }
        let captured = NativeEnrollmentDeviceMetadata.capture()
        reportedMetadata = captured
        return captured
    }
    func enroll(lifecycle: CloudHumanSessionLifecycle, bootstrap: DeviceManagementBootstrap,
                accountID: UUID, locationID: UUID?, name: String, viewport: CGSize) {
        guard !factoryResetInProgress, !intentRetirementPending, task == nil else { return }
        self.bootstrap = bootstrap
        do {
            if let original {
                guard original.accountID == accountID else {
                    deliveryMessage = "This device installation belongs to its retained workspace. Reconnect there to preserve its screens and local pairings."
                    state = .needsAttention; return
                }
                guard original.locationID == locationID,
                    original.name.utf8.elementsEqual(name.utf8), bootstrap.currentAuthority === original.authority else { throw CancellationError() }
                try requireEnrollmentHumanContext(original)
            } else {
                guard let metadata = captureReportedMetadata() else { throw CancellationError() }
                let profile = metadata.profile
                guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
                    viewport.width <= 16384, viewport.height <= 16384 else { throw CancellationError() }
                let selection = try lifecycle.enrollmentSelection(accountID: accountID, locationID: locationID)
                guard let authority = bootstrap.currentAuthority else { throw CancellationError() }
                let origin = try CloudNativeConfiguration.load().apiOrigin
                let intent: NativeEnrollmentIntentRecord
                if let retained = try intentJournal.load() {
                    guard retained.accountID == accountID, retained.locationID == locationID,
                        retained.name == name, retained.origin == origin.absoluteString else { throw CancellationError() }
                    intent = retained
                    retainedIntent = retained
                } else {
                    intent = try NativeEnrollmentIntentRecord(accountID: accountID, locationID: locationID,
                        name: name, profile: profile, origin: origin, viewport: viewport,
                        legacyDashboardIDs: { if case .localReady(let host) = bootstrap.state {
                            if let set = host.screenSet { return set.screens.map { $0.revision.dashboardId } }
                            return host.server?.store?.load()?.activeStoredRevision.map { [$0.dashboardId] } ?? []
                        }; return [] }(), legacyOwnerPresent: { if case .localReady(let host) = bootstrap.state {
                            let saved = host.server?.store?.load(); return saved?.contentOwner != nil || saved?.owner != nil
                        }; return false }())
                    // Durable immutable IDs BEFORE namespace, journal or Keychain effects.
                    try intentJournal.saveOriginal(intent)
                    retainedIntent = intent
                }
                let proposal = try intent.proposal()
                try NativeFirstEnrollmentSession.validateFirstNativeLayout(proposal)
                let target = DeviceProfile(deviceId: proposal.claimInput.transitionId.uuidString.lowercased(), name: name,
                    orientation: intent.width > intent.height ? .landscape : .portrait,
                    width: intent.width, height: intent.height)
                original = Original(selection: selection, authority: authority, proposal: proposal, origin: origin,
                    name: name, profile: intent.profile, target: target, intent: intent)
                if case .localReady(let host) = bootstrap.state, let server = host.server,
                    server.store?.load()?.contentOwner != nil || server.store?.load()?.owner != nil {
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
                    original?.legacyMigration = legacy
                }
                try authority.enterCloudForeground()
                observeHumanContext(lifecycle)
            }
            guard let original else { throw CancellationError() }
            if original.roots == nil {
                try original.authority.enterCloudForeground()
                let namespacePresent = try DeviceManagedNamespaceInspector.production().inspect().classification == .managedPresent
                if original.intent.restoreRecordedInstallation || namespacePresent {
                    original.restoring = true
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
            if original.stores == nil {
                let protected = NativeManagedProtectedRoots(legacyState: stateRoot,
                    // Protect the entire existing Local state tree; do not invent a separate archive locator.
                    legacyArchive: stateRoot, reset: reset,
                    cloudEnrollment: roots.journalRoot, management: DeviceManagementTransitionStore.defaultDirectory(),
                    preferences: roots.namespace.deletingLastPathComponent().appendingPathComponent("xyz.screenpunk.preferences"))
                original.stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protected,
                    grantTransport: NativeEnrollmentKeychainBackend.grantTransport(rootID: roots.localIDs.grant))
            }
            if original.session == nil {
                original.session = try original.authority.makeFirstEnrollmentSession(roots: roots, proposal: original.proposal,
                    excludedLocalResetRoot: reset, storage: NativeEnrollmentKeychainBackend())
            }
            guard let session = original.session, let stores = original.stores else { throw CancellationError() }
            state = .enrolling
            task = Task { [weak self] in
                guard let self else { return }
                defer { task = nil; schedulePendingCloudRelay() }
                do {
                    try Task.checkCancellation(); try requireEnrollmentHumanContext(original)
                    if original.result == nil {
                        try original.authority.validateFreshCloudEnrollmentRoots(roots)
                        if original.restoring {
                            original.result = try await session.resumeRecorded(origin: original.origin, tokenProvider: try requireEnrollmentTokens(original),
                                activationRequestID: original.activationRequestID, associationAttemptID: original.associationAttemptID, stores: stores)
                        } else {
                        original.result = try await session.enroll(origin: original.origin, tokenProvider: try requireEnrollmentTokens(original),
                            activationRequestID: original.activationRequestID, associationAttemptID: original.associationAttemptID, stores: stores)
                        try intentJournal.markRecordedInstallation(original.intent)
                        }
                    }
                    try Task.checkCancellation(); try requireEnrollmentHumanContext(original)
                    guard let result = original.result else { throw CancellationError() }
                    if original.context == nil {
                        try original.authority.validateFreshCloudEnrollmentRoots(roots)
                        original.context = try original.authority.bindOperationalInstallation(installation: result.installation,
                            activation: result.activation, origin: original.origin)
                    }
                    guard let bound = original.context else { throw CancellationError() }
                    context = bound
                    try restoreLegacyMigration(original, context: bound)
                    let request = try original.authority.prepareCloudStatusRequest(bound)
                    _ = try await NativeInstallationStatusTransport(origin: original.origin).send(request, authority: original.authority, context: bound)
                    try Task.checkCancellation(); try requireEnrollmentHumanContext(original)
                    let current = try original.authority.prepareCurrentInstallationDispatch(bound)
                    try await deliver(original, result: result, current: current, context: bound)
                    state = .currentInstallation
                } catch {
                    state = .needsAttention
                    deliveryMessage = "The requested screen change could not be completed. The last accepted screen is retained."
                }
            }
        } catch { deliveryMessage = "Enrollment could not be safely resumed. Your original request is retained."; state = .needsAttention }
    }
    /// Restores a genuinely completed installation with its device credential. Human account
    /// sign-in is deliberately absent; incomplete enrollment still requires its original user.
    func reconnectInstallation(bootstrap: DeviceManagementBootstrap) {
        guard !factoryResetInProgress else { return }
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
        guard !factoryResetInProgress, task == nil, original == nil, let intent = retainedIntent, let authority = bootstrap.currentAuthority else { return }
        self.bootstrap = bootstrap
        do {
            let proposal = try intent.proposal()
            let origin = try NativeOperationalInstallation.validatedOrigin(URL(string: intent.origin)!)
            try authority.enterCloudForeground()
            let roots = try authority.restoreRecordedCloudEnrollmentRoots(claim: proposal.claimInput,
                cloudRootID: intent.cloudRootID, localIDs: intent.localIDs())
            let stateRoot = DeviceStateStore.defaultRoot(), reset = DeviceLocalResetStore.defaultDirectory()
            let protected = NativeManagedProtectedRoots(legacyState: stateRoot, legacyArchive: stateRoot, reset: reset,
                cloudEnrollment: roots.journalRoot, management: DeviceManagementTransitionStore.defaultDirectory(),
                preferences: roots.namespace.deletingLastPathComponent().appendingPathComponent("xyz.screenpunk.preferences"))
            let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protected,
                grantTransport: NativeEnrollmentKeychainBackend.grantTransport(rootID: roots.localIDs.grant))
            let session = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal,
                excludedLocalResetRoot: reset, storage: NativeEnrollmentKeychainBackend())
            let result = try session.restoreCompleted(stores: stores)
            let target = DeviceProfile(deviceId: proposal.claimInput.transitionId.uuidString.lowercased(), name: intent.name,
                orientation: intent.width > intent.height ? .landscape : .portrait, width: intent.width, height: intent.height)
            let restored = Original(selection: nil, authority: authority, proposal: proposal, origin: origin,
                name: intent.name, profile: intent.profile, target: target, intent: intent)
            restored.restoring = true; restored.roots = roots; restored.stores = stores; restored.session = session; restored.result = result
            let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: origin)
            restored.context = context; original = restored; self.context = context
            try restoreLegacyMigration(restored, context: context)
            task = Task { [weak self] in
                guard let self else { return }; defer { task = nil; schedulePendingCloudRelay() }
                do {
                    try await self.restoreCommonPresentation(restored, context: context)
                    let status = try authority.prepareCloudStatusRequest(context)
                    _ = try await NativeInstallationStatusTransport(origin: origin).send(status, authority: authority, context: context)
                    let current = try authority.prepareCurrentInstallationDispatch(context)
                    try await deliver(restored, result: result, current: current, context: context)
                    state = .currentInstallation
                } catch { state = .needsAttention; deliveryMessage = "The retained device connection needs recovery." }
            }
        } catch { state = .needsAttention; deliveryMessage = "The retained device connection needs recovery." }
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
        let d = original.delivery, transport = try NativeInstallationStatusTransport(origin: original.origin)
        try requireEnrollmentHumanContext(original); try Task.checkCancellation()
        if !d.capabilityReported {
            let capability = try result.installation.makeConcurrentControlCapabilityRequest(origin: original.origin,
                current: current, qualified: original.authority.qualifiedConcurrentControl(context: context))
            try await capability.performFixedTransport(); d.capabilityReported = true
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
            let unified = try original.authority.makeUnifiedInventorySession(context: context, current: current,
                commonRootID: rootID, local: original.legacyMigration, native: session)
            if try !unified.restoreCompleted(current: current) {
                try unified.migrate(current: current, operationID: operationID, generationID: generationID, admissionEnabled: true)
            }
            original.unifiedInventory = unified
            original.deliveryCurrentDispatch = current
            try installCommonHost(original, context: context, unified: unified)
            let association = try unified.validatedAssociation()
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
        let transport = try NativeInstallationStatusTransport(origin: original.origin)
        original.deliveryCurrentDispatch = current
        while let observation = try unified.pendingCloudObservation() {
            try await result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                current: current, observation: observation).performFixedTransport()
        }
        let mountState = try unified.mountStateAssociation()
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
        if let empty = emptyDisplayGeneration, let mounted = try unified.mountedAssociation(),
            mounted.currentlyConfigured, mounted.entryID == nil, mounted.generationID == empty {
            await reportEmptyDisplayMounted(expectedGeneration: empty)
        }
        if let rejected = try unified.restorePendingCloudNotActivatedOutcome(current: current) {
            let receipt = try await transport.receipt(rejected, installation: result.installation)
            _ = try unified.retainCloudNotActivatedAcknowledgment(body: rejected, observation: receipt)
        }
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
                let configured = try unified.validatedAssociation()
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
        while let observation = try unified.pendingCloudObservation() {
            try await result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                current: current, observation: observation).performFixedTransport()
        }
        let configured = try unified.validatedAssociation()
        if configured.configuredEntryID == nil {
            retirePresentation(); emptyDisplayGeneration = configured.generationID
            try installCommonHost(original, context: context, unified: unified); return
        }
        if command.hasCommand { return }
        if try unified.mountStateAssociation().state == "failed" { return }
        if candidateMounted, let shown = content,
            shown.generationID == configured.generationID, shown.entryID == configured.configuredEntryID {
            presentationDispatch = current; return
        }
        let selected = try await prepareUnifiedContent(unified, operationID: original.delivery.nativeOperationID)
        stagePresentation(selected, current: current)
        if let server = commonHost?.server { try server.attachUnifiedLocalSession(unified) }
        try installCommonHost(original, context: context, unified: unified)
        deliveryMessage = command.hasCommand ? "Screen prepared. Waiting for the display to mount." : "Device connected."
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
        let unified = try original.authority.restoreUnifiedInventorySession(context: context,
            commonRootID: rootID, local: original.legacyMigration, native: delivery,
            restoreIncomingLocal: { associations in
                try associations.map { association in
                    let intent = try self.intentJournal.loadLocalCommand(association.operationID, installation: result.activation.installationId)
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
        if configured.configuredEntryID == nil {
            retirePresentation(); emptyDisplayGeneration = configured.generationID
            try installCommonHost(original, context: context, unified: unified); return
        }
        let selected: DeviceManagedStaticContent
        if try unified.mountStateAssociation().state == "failed" {
            let runtime = try await unified.lastSuccessfulManagedRuntime(operationID: operationID,
                http: URLSessionHTTPTransport(), webSocket: URLSessionWebSocketTransport(),
                resolver: LiteralOrResolvedDestinationResolver(), clock: SystemClock())
            preparedRuntime = runtime; selected = runtime.content
        } else {
            selected = try await prepareUnifiedContent(unified, operationID: operationID)
        }
        stagePresentation(selected, current: nil)
        deliveryMessage = "Restored the last accepted screen. Checking the cloud connection."
        try installCommonHost(original, context: context, unified: unified)
    }
    private func installCommonHost(_ original: Original, context: DeviceManagementAuthority.CloudInstallationContext,
                                   unified: DeviceUnifiedInventorySession) throws {
        guard commonHost == nil, try original.authority.qualifiedConcurrentControl(context: context),
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
        server.prepareIncomingLocalScreens = { operationID, peer, screens, selected, validateOriginal in
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
            try session.prepareAndCommit(screens: retainedScreens, selected: sourceSelection, owner: peer, profile: original.target,
                profileID: original.profile, operationID: operationID, grantOperationID: intent.grantOperation,
                generationID: intent.generation, grantRevisionID: intent.grantRevision, legacyGrantSet: nil,
                validateOriginal: validateOriginal)
            return try DeviceIncomingLocalPreparation(completed: session, operationID: operationID)
        }
        server.onCommonContentChanged = { [weak self, weak original] in
            Task { @MainActor in
                guard let self, let original, self.original === original else { return }
                do {
                    let association = try unified.validatedAssociation()
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
                            let transport = try NativeInstallationStatusTransport(origin: original.origin)
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
        guard self.original === original else { throw CancellationError() }
        let association = try unified.validatedAssociation()
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
        guard content === expectedContent, presentationLifetime === expectedLifetime,
            let original else { throw CancellationError() }
        let observation: NativeMountedContentObservation?
        if let unified = original.unifiedInventory {
            try unified.confirmMountedLocalContent(expectedContent)
            observation = presentationDispatch.flatMap { try? unified.confirmMountedContent(expectedContent, current: $0) }
        } else {
            guard let session = original.delivery.session, let current = presentationDispatch else { throw CancellationError() }
            observation = try session.confirmMountedStaticContent(expectedContent, current: current)
        }
        try requireCurrentPresentation()
        candidateMounted = true
        retainedDisplayLifetime?.retire(); retainedDisplayLifetime = nil; retainedDisplayContent = nil; retainedDisplayRuntime = nil
        guard let result = original.result, let session = original.delivery.session,
            let current = presentationDispatch, let observation else {
            deliveryMessage = "Screen mounted. Cloud confirmation is pending."; return
        }
        do {
        let transport = try NativeInstallationStatusTransport(origin: original.origin)
        if let unified = original.unifiedInventory {
            while let state = try unified.pendingCloudObservation() {
                try await result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                    current: current, observation: state).performFixedTransport()
            }
        }
        let request = try result.installation.makeMountedContentObservationRequest(origin: original.origin,
            current: current, observation: observation)
        _ = try await request.performFixedTransport()
        if let unified = original.unifiedInventory, let outcome = original.pendingCloudOutcome {
            let receipt = try await transport.receipt(outcome, installation: result.installation)
            _ = try unified.retainCloudOutcomeAcknowledgment(body: outcome, observation: receipt)
            original.pendingCloudOutcome = nil
            original.cloudProgress = nil
        } else if let outcome = original.delivery.outcome,
                  original.delivery.acknowledgment == nil {
            let receipt = try await transport.receipt(outcome, installation: result.installation)
            original.delivery.acknowledgment = try session.retainOutcomeAcknowledgment(body: outcome, observation: receipt)
        }
        try requireCurrentPresentation()
        deliveryMessage = "Screen mounted. Activation receipt confirmed."
        } catch {
            deliveryMessage = "Screen mounted. Cloud confirmation is pending."
        }
    }
    func invokeService(expectedContent: DeviceManagedStaticContent, expectedLifetime: DeviceRuntimeLifetime, invocationID: UUID, bindingID: UUID, operation: String, input: String) async throws -> Data {
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
        if let common = original?.unifiedInventory {
            guard let mounted = try common.mountedAssociation(),
                mounted.generationID == expected.generationID, mounted.entryID == expected.entryID else { throw CancellationError() }
        }
    }
    func requireCurrentPresentation() throws {
        guard let original, let content, let lifetime = presentationLifetime, !lifetime.isRetired else { throw CancellationError() }
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
    private func prepareUnifiedContent(_ unified: DeviceUnifiedInventorySession, operationID: UUID) async throws -> DeviceManagedStaticContent {
        let runtime = try await unified.makeManagedRuntime(operationID: operationID,
            http: URLSessionHTTPTransport(), webSocket: URLSessionWebSocketTransport(),
            resolver: LiteralOrResolvedDestinationResolver(), clock: SystemClock())
        preparedRuntime = runtime
        return runtime.content
    }
    private func stagePresentation(_ next: DeviceManagedStaticContent, current: NativeCurrentInstallationDispatch?) {
        emptyDisplayGeneration = nil
        presentationExpiry?.cancel(); presentationExpiry = nil
        if candidateMounted, let content, let presentationLifetime {
            retainedDisplayLifetime?.retire()
            retainedDisplayContent = content; retainedDisplayLifetime = presentationLifetime
            retainedDisplayRuntime = presentationRuntime
        } else { presentationLifetime?.retire() }
        candidateMounted = false
        presentationLifetime = DeviceRuntimeLifetime(); presentationDispatch = current; content = next
        presentationRuntime = preparedRuntime?.content === next ? preparedRuntime : nil
        preparedRuntime = nil
    }
    private func schedulePendingCloudRelay() {
        guard task == nil, let original, original.requestedCloudOperationID != nil,
            let result = original.result, let context = original.context,
            let unified = original.unifiedInventory else { return }
        task = Task { [weak self, weak original] in
            guard let self, let original else { return }
            defer { self.task = nil; self.schedulePendingCloudRelay() }
            do {
                let transport = try NativeInstallationStatusTransport(origin: original.origin)
                let status = try original.authority.prepareCloudStatusRequest(context)
                _ = try await transport.send(status, authority: original.authority, context: context)
                let current = try original.authority.prepareCurrentInstallationDispatch(context)
                try await self.deliverCommon(original, result: result, current: current, context: context, unified: unified)
            } catch {
                // Retrying requires another explicit hint after an unsuccessful verification.
                original.requestedCloudOperationID = nil
                self.deliveryMessage = "The relayed cloud command needs recovery."
            }
        }
    }
    func reportEmptyDisplayMounted(expectedGeneration: UUID) async {
        guard emptyDisplayGeneration == expectedGeneration, let original, let unified = original.unifiedInventory else { return }
        do {
            let association = try unified.validatedAssociation()
            guard association.generationID == expectedGeneration, association.configuredEntryID == nil else { throw CancellationError() }
            try unified.confirmMountedEmptyDisplay()
            deliveryMessage = "Empty display applied."
            if let result = original.result, let current = original.deliveryCurrentDispatch {
                while let observation = try unified.pendingCloudObservation() {
                    try await result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                        current: current, observation: observation).performFixedTransport()
                }
                let blank = try unified.retainedMountedEmptyObservation()
                try await result.installation.makeMountedEmptyObservationRequest(origin: original.origin,
                    current: current, observation: blank).performFixedTransport()
            }
            if let outcome = original.pendingCloudOutcome, let result = original.result {
                let transport = try NativeInstallationStatusTransport(origin: original.origin)
                if let current = original.deliveryCurrentDispatch {
                    while let observation = try unified.pendingCloudObservation() {
                        try await result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                            current: current, observation: observation).performFixedTransport()
                    }
                }
                let receipt = try await transport.receipt(outcome, installation: result.installation)
                _ = try unified.retainCloudOutcomeAcknowledgment(body: outcome, observation: receipt)
                original.pendingCloudOutcome = nil
            }
        } catch { deliveryMessage = "Empty display confirmation is pending." }
    }
    func reportMountFailed(expectedContent: DeviceManagedStaticContent, expectedLifetime: DeviceRuntimeLifetime, code: String) async {
        guard content === expectedContent, presentationLifetime === expectedLifetime else { return }
        do { try original?.unifiedInventory?.confirmMountFailure(expectedContent, code: code) }
        catch { deliveryMessage = "The failed display needs recovery."; return }
        let failure = try? original?.unifiedInventory?.retainedCloudMountFailure()
        let reportingOriginal = original
        original?.pendingCloudOutcome = nil
        presentationLifetime?.retire()
        content = retainedDisplayContent; presentationLifetime = retainedDisplayLifetime
        presentationRuntime = retainedDisplayRuntime
        retainedDisplayContent = nil; retainedDisplayLifetime = nil; retainedDisplayRuntime = nil
        candidateMounted = content != nil
        deliveryMessage = "The new screen could not mount. The previous display is retained."
        if let original = reportingOriginal, let result = original.result,
            let current = original.deliveryCurrentDispatch, let failure,
            let failureCode = NativeUnifiedMountFailureCode(rawValue: code), let context = original.context {
            do {
                let transport = try NativeInstallationStatusTransport(origin: original.origin)
                if let unified = original.unifiedInventory {
                    while let observation = try unified.pendingCloudObservation() {
                        try await result.installation.makeUnifiedCloudObservationRequest(origin: original.origin,
                            current: current, observation: observation).performFixedTransport()
                    }
                }
                try await transport.failed(failure, code: failureCode, installation: result.installation,
                    current: current, authority: original.authority, context: context)
            } catch { deliveryMessage = "The new screen could not mount. Cloud failure confirmation is pending." }
        }
    }
    private func retirePresentation() {
        emptyDisplayGeneration = nil
        presentationExpiry?.cancel(); presentationExpiry = nil
        presentationLifetime?.retire(); presentationLifetime = nil; presentationDispatch = nil; content = nil; presentationRuntime = nil; preparedRuntime = nil
        retainedDisplayLifetime?.retire(); retainedDisplayLifetime = nil; retainedDisplayContent = nil; retainedDisplayRuntime = nil; candidateMounted = false
    }
    @Published private(set) var factoryResetInProgress = false
    private var pendingFactoryResetReceipt: DeviceOwnedFactoryResetReceipt?
    private var resetHumanSignOut: ((CloudHumanSessionLifecycle) -> Task<Void, Never>?)?
    private var resetHumanSignOutComplete: (() -> Bool)?
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
            task = nil
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
        original = nil; context = nil; retainedIntent = nil; reportedMetadata = nil
        let signedOut = resetHumanSignOutComplete?() == true
        pendingFactoryResetReceipt = nil; resetHumanSignOut = nil; resetHumanSignOutComplete = nil; intentJournal = .application(); state = .idle
        deliveryMessage = signedOut
            ? "This device has been reset and signed out. Its cloud account, projects, and cloud device record were preserved."
            : "This device-local reset is complete. Review local sign-in and retry Sign out in Cloud account if needed. Your cloud account, projects, and device record were preserved."
    }
    func didEnterBackground() {
        if factoryResetInProgress { retirePresentation(); return }
        temporaryPoll?.cancel(); temporaryPoll = nil
        temporaryExpiry?.cancel(); temporaryExpiry = nil
        if let driver = temporaryDriver { Task { await driver.cancel() } }
        temporaryDriver = nil
        task?.cancel(); retirePresentation()
        commonHost?.retireForReset(); commonHost = nil
        if let original { try? original.authority.leaveCloudForeground() }
        context = nil
        if original?.result != nil {
            retainedIntent = try? intentJournal.load()
            original = nil
        }
        if state == .enrolling || state == .currentInstallation { state = .needsAttention }
    }
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
    init(accountID: UUID, locationID: UUID?, name: String, profile: String, origin: URL, viewport: CGSize, legacyDashboardIDs: [String] = [], legacyOwnerPresent: Bool = false) throws {
        version = 1; self.accountID = accountID; self.locationID = locationID; self.name = name; self.profile = profile
        self.origin = origin.absoluteString; width = Int(viewport.width.rounded()); height = Int(viewport.height.rounded())
        preparationID = UUID(); enrollmentID = UUID(); transitionID = UUID(); requestID = UUID(); credentialGenerationID = UUID()
        credentialReference = "native." + UUID().uuidString.lowercased(); stageReference = "stage." + UUID().uuidString.lowercased()
        activationRequestID = UUID(); associationAttemptID = UUID(); cloudRootID = UUID(); commonInventoryRootID = UUID(); unifiedMigrationOperationID = UUID(); unifiedMigrationGenerationID = UUID()
        firstDeliveryNativeOperationID = UUID(); firstDeliveryGrantOperationID = UUID(); firstDeliveryGrantRevisionID = UUID(); firstDeliveryActivationRequestID = UUID()
        packageRootID = UUID(); grantRootID = UUID(); structuralRootID = UUID(); provisioningRootID = UUID(); contentGenesisID = UUID()
        guard legacyDashboardIDs.count <= 12, Set(legacyDashboardIDs).count == legacyDashboardIDs.count else { throw CancellationError() }
        legacyPackageRootID = UUID(); legacyGrantRootID = UUID(); legacyStructuralRootID = UUID(); legacyProvisioningRootID = UUID()
        legacyMigrationRequired = legacyOwnerPresent
        legacyEntryIDs = Dictionary(uniqueKeysWithValues: legacyDashboardIDs.map { ($0, UUID()) })
        legacyPackageOperationIDs = Dictionary(uniqueKeysWithValues: legacyDashboardIDs.map { ($0, UUID()) })
        legacyOperationID = UUID(); legacyGrantOperationID = UUID(); legacyGenerationID = UUID(); legacyGrantRevisionID = UUID()
        _ = try proposal(); _ = try localIDs()
    }
    func proposal() throws -> NativeFirstEnrollmentPreparation {
        guard version == 1, width > 0, height > 0, width <= 16384, height <= 16384,
            let originURL = URL(string: origin), try NativeOperationalInstallation.validatedOrigin(originURL) == originURL else { throw CancellationError() }
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
        guard !retired else { throw CancellationError() }
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
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try requirePhysical(directory, directory: true)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try requirePhysical(file, directory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16384 else { throw CancellationError() }
        let data = try Data(contentsOf: file)
        guard data.count <= 16384 else { throw CancellationError() }
        let record = try JSONDecoder().decode(NativeEnrollmentIntentRecord.self, from: data)
        _ = try record.proposal(); _ = try record.localIDs()
        return record
    }
    func saveOriginal(_ record: NativeEnrollmentIntentRecord) throws {
        if let previous = try load() { guard previous == record else { throw CancellationError() }; return }
        try publish(record)
    }
    func markRecordedInstallation(_ original: NativeEnrollmentIntentRecord) throws {
        guard var previous = try load(), previous == original else { throw CancellationError() }
        previous.restoreRecordedInstallation = true; try publish(previous)
    }
    private func publish(_ record: NativeEnrollmentIntentRecord) throws {
        try writeFence.mutate { try publishUnlocked(record) }
    }
    private func publishUnlocked(_ record: NativeEnrollmentIntentRecord) throws {
        _ = try record.proposal(); _ = try record.localIDs()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        try requirePhysical(directory, directory: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record); guard data.count <= 16384 else { throw CancellationError() }
        try data.write(to: file, options: .atomic)
        try requirePhysical(file, directory: false)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CancellationError() }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw CancellationError() }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CancellationError() }; defer { close(parent) }
        guard fsync(parent) == 0 else { throw CancellationError() }
    }
    private func requirePhysical(_ url: URL, directory: Bool) throws {
        guard url.path == url.resolvingSymlinksInPath().path else { throw CancellationError() }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
            directory || info.st_nlink == 1 else { throw CancellationError() }
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
    fileprivate func loadLocalCommand(_ operation: UUID, installation: UUID) throws -> NativeIncomingLocalIntent {
        try requirePhysical(directory, directory: true)
        let file = directory.appendingPathComponent("local-command-" + operation.uuidString.lowercased() + ".json")
        try requirePhysical(file, directory: false)
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard (size?.intValue ?? Int.max) <= 4096 else { throw CancellationError() }
        let value = try JSONDecoder().decode(NativeIncomingLocalIntent.self, from: Data(contentsOf: file))
        guard value.installation == installation, value.operation == operation else { throw CancellationError() }
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
