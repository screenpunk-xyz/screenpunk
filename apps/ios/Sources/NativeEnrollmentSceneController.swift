import Foundation
import SwiftUI
import Combine
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) import ScreenpunkCore
@_spi(NativeInstallation) import ScreenpunkApple

/// One explicit original enrollment in the retained scene. No automatic startup,
/// missing-state import, SDK construction, or historical receipt admission.
@MainActor final class NativeEnrollmentSceneController: ObservableObject {
    enum State: Equatable { case idle, enrolling, needsAttention, currentInstallation }
    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var original: Original?
    @Published private(set) var content: DeviceManagedStaticContent?
    @Published private(set) var deliveryMessage: String?
    private(set) var presentationLifetime: DeviceRuntimeLifetime?
    private var presentationExpiry: Task<Void, Never>?
    private var presentationDispatch: NativeCurrentInstallationDispatch?
    private var humanObservations: [AnyCancellable] = []
    private weak var observedLifecycle: CloudHumanSessionLifecycle?
    private var revocationObserver: UUID?
    private var context: DeviceManagementAuthority.CloudInstallationContext?
    private final class Original {
        let selection: CloudEnrollmentSelection, authority: DeviceManagementAuthority
        let proposal: NativeFirstEnrollmentPreparation, origin: URL
        let activationRequestID = UUID(), associationAttemptID = UUID()
        let accountID: UUID, locationID: UUID, name: String, profile: String
        let target: DeviceProfile
        let delivery = Delivery()
        var roots: DeviceManagementAuthority.FreshCloudEnrollmentRoots?
        var session: NativeFirstEnrollmentSession?, stores: NativeFirstManagedStores?
        var result: NativeOperationalEnrollmentResult?
        var context: DeviceManagementAuthority.CloudInstallationContext?
        init(selection: CloudEnrollmentSelection, authority: DeviceManagementAuthority,
             proposal: NativeFirstEnrollmentPreparation, origin: URL, name: String, profile: String, target: DeviceProfile) {
            self.selection = selection; self.authority = authority; self.proposal = proposal; self.origin = origin; self.target = target
            accountID = selection.accountID; locationID = selection.locationID; self.name = name; self.profile = profile
        }
    }
    private final class Delivery {
        let nativeOperationID = UUID(), grantOperationID = UUID(), grantRevisionID = UUID(), activationRequestID = UUID()
        var session: NativeDeliveryExecutionSession?
        var stateBody: NativeDeliveryDurableBody?, stateAck: NativeDeliveryStateHTTPObservation?
        var command: NativeDeliveryCommandHTTPObservation?, plan: NativeDeliveryPlanHTTPObservation?, archives: NativeDeliveryArchiveHTTPObservation?
        var prepared = false
        var activationBody: NativeDeliveryDurableBody?, authorization: NativeDeliveryActivationHTTPObservation?
        var outcome: NativeDeliveryDurableBody?, acknowledgment: UUID?
    }
    var retainedDeviceName: String? { original?.name }
    var retainedDeviceProfile: String? { original?.profile }
    func enroll(lifecycle: CloudHumanSessionLifecycle, bootstrap: DeviceManagementBootstrap,
                accountID: UUID, locationID: UUID, name: String, profile: String, viewport: CGSize) {
        guard task == nil else { return }
        do {
            if let original {
                guard original.accountID == accountID, original.locationID == locationID,
                    original.name.utf8.elementsEqual(name.utf8), original.profile.utf8.elementsEqual(profile.utf8), bootstrap.currentAuthority === original.authority else { throw CancellationError() }
                try original.selection.validate()
            } else {
                guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
                    viewport.width <= 16384, viewport.height <= 16384 else { throw CancellationError() }
                let selection = try lifecycle.enrollmentSelection(accountID: accountID, locationID: locationID)
                guard let authority = bootstrap.currentAuthority else { throw CancellationError() }
                let origin = try CloudNativeConfiguration.load().apiOrigin
                let transition = UUID()
                let claim = try NativeClaimInput(requestId: UUID(), transitionId: transition,
                    accountId: selection.accountID, locationId: selection.locationID, name: name, profile: profile)
                // Local identifiers are retained original metadata, never server IDs.
                let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: transition,
                    credentialReference: "native." + UUID().uuidString.lowercased(), format: .nativeInstallationV1)
                let proposal = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(),
                    stageReference: "stage." + UUID().uuidString.lowercased(), binding: binding, claimInput: claim)
                try NativeFirstEnrollmentSession.validateFirstNativeLayout(proposal)
                try authority.enterCloudForeground()
                // Exact immutable operation is retained BEFORE namespace/store/journal effects.
                let target = DeviceProfile(deviceId: transition.uuidString.lowercased(), name: name,
                    orientation: viewport.width > viewport.height ? .landscape : .portrait,
                    width: Int(viewport.width.rounded()), height: Int(viewport.height.rounded()))
                original = Original(selection: selection, authority: authority, proposal: proposal, origin: origin, name: name, profile: profile, target: target)
                observeHumanContext(lifecycle)
            }
            guard let original else { throw CancellationError() }
            if original.roots == nil {
                original.roots = try original.authority.prepareFreshCloudEnrollmentRoots(claim: original.proposal.claimInput)
            }
            guard let roots = original.roots else { throw CancellationError() }
            try original.selection.validate()
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
                defer { task = nil }
                do {
                    try Task.checkCancellation(); try original.selection.validate()
                    if original.result == nil {
                        try original.authority.validateFreshCloudEnrollmentRoots(roots)
                        original.result = try await session.enroll(origin: original.origin, tokenProvider: original.selection.tokens,
                            activationRequestID: original.activationRequestID, associationAttemptID: original.associationAttemptID, stores: stores)
                    }
                    try Task.checkCancellation(); try original.selection.validate()
                    guard let result = original.result else { throw CancellationError() }
                    if original.context == nil {
                        try original.authority.validateFreshCloudEnrollmentRoots(roots)
                        original.context = try original.authority.bindOperationalInstallation(installation: result.installation,
                            activation: result.activation, origin: original.origin)
                    }
                    guard let bound = original.context else { throw CancellationError() }
                    context = bound
                    let request = try original.authority.prepareCloudStatusRequest(bound)
                    _ = try await NativeInstallationStatusTransport(origin: original.origin).send(request, authority: original.authority, context: bound)
                    try Task.checkCancellation(); try original.selection.validate()
                    let current = try original.authority.prepareCurrentInstallationDispatch(bound)
                    try await deliver(original, result: result, current: current, context: bound)
                    state = .currentInstallation
                } catch { retirePresentation(); state = .needsAttention }
            }
        } catch { state = .needsAttention }
    }
    private func observeHumanContext(_ lifecycle: CloudHumanSessionLifecycle) {
        humanObservations.removeAll()
        if let id = revocationObserver { observedLifecycle?.removeOriginalRevocationObserver(id) }
        observedLifecycle = lifecycle
        revocationObserver = lifecycle.observeOriginalRevocation { [weak self] in self?.didEnterBackground() }
        let changed: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let original = self.original else { return }
                do { try original.selection.validate() }
                catch { self.didEnterBackground() }
            }
        }
        humanObservations.append(lifecycle.objectWillChange.sink { changed() })
        if let coordinator = lifecycle.coordinator { humanObservations.append(coordinator.objectWillChange.sink { changed() }) }
    }
    private func deliver(_ original: Original, result: NativeOperationalEnrollmentResult,
        current: NativeCurrentInstallationDispatch, context: DeviceManagementAuthority.CloudInstallationContext) async throws {
        let d = original.delivery, transport = try NativeInstallationStatusTransport(origin: original.origin)
        try original.selection.validate(); try Task.checkCancellation()
        if d.session == nil { d.session = try result.installation.makeDeliveryExecutionSession(current: current) }
        guard let session = d.session else { throw CancellationError() }
        if d.stateBody == nil { d.stateBody = try session.freshGenesisObservation(current: current) }
        if d.stateAck == nil, let body = d.stateBody {
            d.stateAck = try await transport.reportState(body, installation: result.installation, current: current,
                authority: original.authority, context: context)
        }
        try original.selection.validate(); try Task.checkCancellation()
        if d.command == nil {
            let command = try await transport.command(installation: result.installation, current: current,
                authority: original.authority, context: context)
            try original.selection.validate(); try Task.checkCancellation()
            guard command.hasCommand else { deliveryMessage = "No screen is ready yet. Publish a screen, then check again."; return }
            d.command = command
        }
        if d.plan == nil, let command = d.command {
            d.plan = try await transport.plan(command, nativeOperationID: d.nativeOperationID, current: current,
                authority: original.authority, context: context)
        }
        try original.selection.validate(); try Task.checkCancellation()
        if d.archives == nil, let plan = d.plan {
            d.archives = try await transport.archives(plan, current: current, target: original.target,
                profileID: original.profile, revisionName: original.name, authority: original.authority, context: context)
        }
        try original.selection.validate(); try Task.checkCancellation()
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
        try original.selection.validate(); try Task.checkCancellation()
        guard let activationBody = d.activationBody, let authorization = d.authorization else { throw CancellationError() }
        if d.outcome == nil {
            try session.retainAuthorization(requestBody: activationBody, observation: authorization)
            d.outcome = try session.dispatchAndRetainActivatedOutcome(current: current)
        }
        if d.acknowledgment == nil, let outcome = d.outcome {
            let ack = try await transport.receipt(outcome, installation: result.installation)
            try original.selection.validate(); try Task.checkCancellation()
            d.acknowledgment = try session.retainOutcomeAcknowledgment(body: outcome, observation: ack)
        }
        let snapshot = try session.completedStaticContent(current: current)
        try current.requirePresentationCurrent(); try original.selection.validate()
        retirePresentation()
        let lifetime = DeviceRuntimeLifetime(); presentationLifetime = lifetime; presentationDispatch = current; content = snapshot
        deliveryMessage = "Screen installed. Delivery receipt confirmed."
        presentationExpiry = Task { [weak self, weak lifetime] in
            do { try await current.waitForPresentationExpiry() }
            catch { if Task.isCancelled { return } }
            guard let self, self.presentationLifetime === lifetime else { return }
            self.retirePresentation(); self.deliveryMessage = "Connection verification expired. Check again to display the screen." 
        }
    }
    func requireCurrentPresentation() throws {
        guard let original, let content, let lifetime = presentationLifetime, !lifetime.isRetired,
            let presentationDispatch else { throw CancellationError() }
        do {
            try original.selection.validate(); try presentationDispatch.requirePresentationCurrent(); try content.verifyResources()
            try original.selection.validate(); try presentationDispatch.requirePresentationCurrent()
        }
        catch { retirePresentation(); throw error }
    }
    private func retirePresentation() {
        presentationExpiry?.cancel(); presentationExpiry = nil
        presentationLifetime?.retire(); presentationLifetime = nil; presentationDispatch = nil; content = nil
    }
    func didEnterBackground() {
        task?.cancel(); retirePresentation()
        if let original { try? original.authority.leaveCloudForeground() }
        context = nil
        if state == .enrolling || state == .currentInstallation { state = .needsAttention }
    }
}
