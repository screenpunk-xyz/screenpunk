import Foundation

/// Module-internal store binding supplied only by the managed-store owner. This is not
/// Cloud admission. The owner must preserve its original promoted installation association.
struct NativeDeliveryExecutionStoreBinding {
    let packages: DevicePackagePreparationStore
    let grants: DeviceNativeGrantPreparationStore
    let structural: DeviceStructuralStore
    let journal: DeviceLocalProvisioningIntentStore
    let genesis: DeviceStructuralStore.NativeGenesisCheckpoint
}

@_spi(NativeInstallation) public struct NativeDeliveryArchiveInput {
    public let entryID: UUID, preparationOperationID: UUID
    public let archiveBytes: Data
    public let profileID: String, revisionName: String
    public let target: DeviceProfile
    public init(entryID: UUID, preparationOperationID: UUID, archiveBytes: Data,
                profileID: String, revisionName: String, target: DeviceProfile) {
        self.entryID = entryID; self.preparationOperationID = preparationOperationID
        self.archiveBytes = archiveBytes; self.profileID = profileID; self.revisionName = revisionName; self.target = target
    }
}
@_spi(NativeInstallation) public enum NativeDeliveryExecutionError: Error, Equatable {
    case bounds, association, unsupportedCapabilities, phase, unavailableDispatchCapability
}

/// Explicit host mounting observation for one original qualified content object.
/// Construction never follows configured selection automatically. The host calls
/// confirmation only after its WebView has mounted this exact asset snapshot.
@_spi(NativeInstallation) public final class NativeMountedContentObservation: @unchecked Sendable {
    public let generationID: UUID, entryID: UUID, packageDigest: String
    private let installation: NativeOperationalInstallation
    private let content: DeviceManagedStaticContent
    fileprivate init(installation: NativeOperationalInstallation, content: DeviceManagedStaticContent, packageDigest: String) {
        self.installation = installation; self.content = content; self.packageDigest = packageDigest
        generationID = content.generationID; entryID = content.entryID
    }
    func validatedBody(installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch) throws -> Data {
        guard installation === self.installation else { throw NativeDeliveryExecutionError.association }
        try current.validateInstallationExact(installation: installation)
        try content.verifyResources()
        try current.validateInstallationExact(installation: installation)
        return try JSONSerialization.data(withJSONObject: ["generationId": generationID.uuidString.lowercased(),
            "entryId": entryID.uuidString.lowercased(), "packageDigest": packageDigest], options: [.sortedKeys])
    }
}

/// Exact nonsecret outgoing bytes. Constructed only after the corresponding fixed durable
/// command. These bytes are not HTTP success, current installation admission or a live lease.
@_spi(NativeInstallation) public final class NativeDeliveryDurableBody {
    public let bytes: Data
    fileprivate let session: ObjectIdentifier
    fileprivate let kind: Kind
    fileprivate let installation: NativeOperationalInstallation
    fileprivate let requestID: UUID?
    fileprivate let requestStart: ContinuousClock.Instant?
    fileprivate enum Kind { case state, activation, outcome, unifiedOutcome }
    fileprivate init(_ bytes: Data, session: ObjectIdentifier, kind: Kind, installation: NativeOperationalInstallation,
                     requestID: UUID? = nil, requestStart: ContinuousClock.Instant? = nil) {
        self.bytes = bytes; self.session = session; self.kind = kind
        self.installation = installation; self.requestID = requestID; self.requestStart = requestStart
    }
    func requireOriginalInstallation(_ expected: NativeOperationalInstallation) throws {
        guard installation === expected else { throw NativeDeliveryExecutionError.association }
    }
    func requireStateOriginal(installation expected: NativeOperationalInstallation) throws {
        try Task.checkCancellation()
        guard installation === expected, kind == .state else { throw NativeDeliveryExecutionError.association }
    }
    func requireActivationOriginal(installation expected: NativeOperationalInstallation) throws -> UUID {
        try Task.checkCancellation()
        guard installation === expected, kind == .activation, let requestID, let requestStart,
              ContinuousClock().now < requestStart.advanced(by: .seconds(30)) else {
            throw NativeDeliveryExecutionError.association
        }
        return requestID
    }
    func requireOutcomeOriginal(installation expected: NativeOperationalInstallation) throws {
        try Task.checkCancellation()
        guard installation === expected, (kind == .unifiedOutcome || (kind == .outcome && requestID != nil && requestStart != nil)) else {
            throw NativeDeliveryExecutionError.association
        }
        // Original outcome reporting survives the dispatch lease; current owner is checked by the fixed collector.
    }
    func matchesOriginalBody(_ other: NativeDeliveryDurableBody) -> Bool {
        session == other.session && kind == other.kind && installation === other.installation
            && requestID == other.requestID && requestStart == other.requestStart && bytes == other.bytes
    }

}


/// Only this file can create the fixed command/result. The bridge opens its invocation window
/// solely while the original concrete authority operation is held; escape is explicitly invalidated.
@_spi(NativeInstallation) public final class NativeInstallationStructuralDispatchResult {
    fileprivate let command: ObjectIdentifier
    fileprivate let acknowledgment: DeviceNativeStructuralCommitAcknowledgment
    fileprivate init(_ command: NativeInstallationStructuralDispatchCommand,
                     _ acknowledgment: DeviceNativeStructuralCommitAcknowledgment) {
        self.command = ObjectIdentifier(command); self.acknowledgment = acknowledgment
    }
}
@_spi(NativeInstallation) public final class NativeInstallationStructuralDispatchCommand: CustomReflectable {
    private let coordinator: DeviceNativeGrantPrivateCoordinator
    private let request: DeviceNativeProvisioningRequest
    private let terminal: DeviceNativeBoundGrantTerminal
    private let authorization: DeviceNativeRetainedAuthorization
    private let observation: NativeDeliveryActivationHTTPObservation
    private let body: NativeDeliveryDurableBody
    private let installation: NativeOperationalInstallation
    private let current: NativeCurrentInstallationDispatch
    private let start: ContinuousClock.Instant
    private let mutex = NSLock()
    private enum Phase { case sealed, opened, executing, consumed, closed }
    private var phase = Phase.sealed
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    fileprivate init(coordinator: DeviceNativeGrantPrivateCoordinator, request: DeviceNativeProvisioningRequest,
        terminal: DeviceNativeBoundGrantTerminal, authorization: DeviceNativeRetainedAuthorization,
        observation: NativeDeliveryActivationHTTPObservation, body: NativeDeliveryDurableBody,
        installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch,
        start: ContinuousClock.Instant) {
        self.coordinator = coordinator; self.request = request; self.terminal = terminal
        self.authorization = authorization; self.observation = observation; self.body = body
        self.installation = installation; self.current = current; self.start = start
    }
    // These module-internal methods are called only by the fixed nominal bridge command, not
    // an arbitrary public closure or a caller-selected mutation permit.
    func beginFixedInvocation(current: NativeCurrentInstallationDispatch) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard current === self.current, phase == .sealed else { throw NativeDeliveryExecutionError.phase }
        phase = .opened
    }
    func endFixedInvocation() { mutex.lock(); phase = .closed; mutex.unlock() }
    /// Called by the concrete management authority while its original serialized operation is held.
    /// Existing synchronous backend/fault seams retain their nonreentrant contract; no network IO.
    public func performFixedUnderAuthority() throws -> NativeInstallationStructuralDispatchResult {
        mutex.lock()
        guard phase == .opened else { mutex.unlock(); throw NativeDeliveryExecutionError.phase }
        phase = .executing; mutex.unlock()
        defer { mutex.lock(); if phase == .executing { phase = .consumed }; mutex.unlock() }
        try Task.checkCancellation()
        guard ContinuousClock().now < start.advanced(by: .seconds(30)) else { throw NativeDeliveryExecutionError.unavailableDispatchCapability }
        let response = try observation.validatedResponse(for: body, installation: installation)
        guard response == authorization.responseBytes else { throw NativeDeliveryExecutionError.association }
        try coordinator.verifyNativeRetainedAuthorizationExact(request, original: authorization)
        let parsed = try DeviceNativeDeliveryHTTPCodec.observe(response, kind: .activationResponse,
            binding: request.delivery, requestID: authorization.requestID)
        guard let digest = parsed.authorizationDigest else { throw NativeDeliveryExecutionError.association }
        guard !digest.isEmpty else { throw NativeDeliveryExecutionError.association }
        try current.validateFixedCommandEvidence(installation: installation, association: request.delivery.association)
        try Task.checkCancellation()
        guard ContinuousClock().now < start.advanced(by: .seconds(30)) else { throw NativeDeliveryExecutionError.unavailableDispatchCapability }
        return .init(self, try coordinator.commitNativeStructuralExact(request, terminal: terminal))
    }
    fileprivate func unwrap(_ result: NativeInstallationStructuralDispatchResult) throws -> DeviceNativeStructuralCommitAcknowledgment {
        guard result.command == ObjectIdentifier(self) else { throw NativeDeliveryExecutionError.association }
        return result.acknowledgment
    }
}

@_spi(NativeInstallation) public final class NativeInstallationUnifiedStructuralDispatchResult {
    fileprivate let command: ObjectIdentifier
    let capture: DeviceMixedInventoryStore.Capture
    let receipt: DeviceMixedInventoryStore.Receipt
    fileprivate init(_ command: NativeInstallationUnifiedStructuralDispatchCommand,
        result: (DeviceMixedInventoryStore.Capture, DeviceMixedInventoryStore.Receipt)) {
        self.command = ObjectIdentifier(command); capture = result.0; receipt = result.1
    }
}

/// Nominal command; only a genuine fixed HTTPS authorization and exact prepared
/// resource graph can construct it. The fixed owner holds intent/root admission.
@_spi(NativeInstallation) public final class NativeInstallationUnifiedStructuralDispatchCommand {
    public var resultingGenerationID: UUID { incoming.command.candidate.generationID }
    public let commonRootID: UUID, installationID: UUID
    public let requiresConcurrentQualification: Bool
    private let resolver: DeviceMixedResourceResolver
    private let original: DeviceMixedResolvedResources
    private let store: DeviceMixedInventoryStore
    private let incoming: DeviceMixedIncomingResources
    private let installation: NativeOperationalInstallation
    private let current: NativeCurrentInstallationDispatch
    private let body: NativeDeliveryDurableBody
    private let observation: NativeDeliveryActivationHTTPObservation
    private let mutex = NSLock()
    private var invoking = false, consumed = false
    fileprivate init(resolver: DeviceMixedResourceResolver, original: DeviceMixedResolvedResources,
        store: DeviceMixedInventoryStore, incoming: DeviceMixedIncomingResources,
        installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch,
        body: NativeDeliveryDurableBody, observation: NativeDeliveryActivationHTTPObservation) {
        self.resolver = resolver; self.original = original; self.store = store; self.incoming = incoming
        self.installation = installation; self.current = current; self.body = body; self.observation = observation
        commonRootID = store.rootID; installationID = incoming.command.candidate.installationOwner.installationID
        requiresConcurrentQualification = (incoming.command.capture.snapshot.entries + incoming.command.candidate.entries).contains { if case .retainedLocal = $0 { return true }; return false }
    }
    func beginFixedInvocation(current: NativeCurrentInstallationDispatch) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard self.current === current, !invoking, !consumed else { throw NativeDeliveryExecutionError.phase }
        invoking = true
    }
    func endFixedInvocation() { mutex.lock(); invoking = false; mutex.unlock() }
    public func performDuringFixedOwner() throws -> NativeInstallationUnifiedStructuralDispatchResult {
        mutex.lock()
        guard invoking, !consumed else { mutex.unlock(); throw NativeDeliveryExecutionError.phase }
        consumed = true; mutex.unlock()
        let requestID = try body.requireActivationOriginal(installation: installation)
        let response = try observation.validatedResponse(for: body, installation: installation)
        let authorization = try DeviceNativeDeliveryHTTPCodec.observe(response, kind: .activationResponse,
            binding: incoming.command.delivery, requestID: requestID)
        guard authorization.authorizationDigest != nil else { throw NativeDeliveryExecutionError.association }
        try current.validateFixedUnifiedCommandEvidence(installation: installation, association: incoming.command.delivery.association)
        let result = try resolver.commitIncomingCloudResourcesExact(original, store: store, incoming: incoming, admissionEnabled: true)
        try current.validateFixedUnifiedCommandEvidence(installation: installation, association: incoming.command.delivery.association)
        return .init(self, result: result)
    }
    func unwrap(_ result: NativeInstallationUnifiedStructuralDispatchResult) throws -> (DeviceMixedInventoryStore.Capture, DeviceMixedInventoryStore.Receipt) {
        guard result.command == ObjectIdentifier(self) else { throw NativeDeliveryExecutionError.association }
        return (result.capture, result.receipt)
    }
}

@_spi(NativeInstallation) public protocol NativeUnifiedLocalInventoryOwner: AnyObject {
    var commonRootID: UUID { get }
    var peerPinHex: String { get }
    func performFixedUnifiedLocalDispatch(command: NativeInstallationUnifiedLocalDispatchCommand) throws -> NativeInstallationUnifiedLocalDispatchResult
}
@_spi(NativeInstallation) public final class NativeInstallationUnifiedLocalDispatchResult {
    fileprivate let command: ObjectIdentifier
    let capture: DeviceMixedInventoryStore.Capture
    fileprivate init(_ command: NativeInstallationUnifiedLocalDispatchCommand, capture: DeviceMixedInventoryStore.Capture) {
        self.command = ObjectIdentifier(command); self.capture = capture
    }
}
/// Fixed approved-peer owner holds registry/latest-intent admission throughout
/// this resource transaction. No public constructor or raw permission boolean.
@_spi(NativeInstallation) public final class NativeInstallationUnifiedLocalDispatchCommand {
    public var resultingGenerationID: UUID { generationID }
    public let commonRootID: UUID, installationID: UUID
    public let peerPinHex: String
    private let resolver: DeviceMixedResourceResolver
    private let original: DeviceMixedResolvedResources
    private let store: DeviceMixedInventoryStore
    private let previous: DeviceMixedInventoryStore.Capture
    private let operationID: UUID, generationID: UUID
    private let retained: [UUID], selected: UUID?
    private let owner: any NativeUnifiedLocalInventoryOwner
    private let incoming: DeviceMixedIncomingLocalResources?
    private let mutex = NSLock()
    private var invoking = false, consumed = false
    init(resolver: DeviceMixedResourceResolver, original: DeviceMixedResolvedResources,
        store: DeviceMixedInventoryStore, previous: DeviceMixedInventoryStore.Capture,
        operationID: UUID, generationID: UUID, retained: [UUID], selected: UUID?, owner: any NativeUnifiedLocalInventoryOwner, incoming: DeviceMixedIncomingLocalResources? = nil) throws {
        guard owner.commonRootID == store.rootID, owner.peerPinHex.utf8.count == 64,
              owner.peerPinHex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw NativeDeliveryExecutionError.association }
        self.resolver = resolver; self.original = original; self.store = store; self.previous = previous
        self.operationID = operationID; self.generationID = generationID; self.retained = retained; self.selected = selected; self.owner = owner; self.incoming = incoming
        commonRootID = store.rootID; installationID = previous.snapshot.installationOwner.installationID; peerPinHex = owner.peerPinHex
    }
    func dispatch() throws -> NativeInstallationUnifiedLocalDispatchResult {
        mutex.lock(); guard !invoking, !consumed else { mutex.unlock(); throw NativeDeliveryExecutionError.phase }
        invoking = true; mutex.unlock()
        defer { mutex.lock(); invoking = false; mutex.unlock() }
        return try owner.performFixedUnifiedLocalDispatch(command: self)
    }
    public func performDuringFixedOwner() throws -> NativeInstallationUnifiedLocalDispatchResult {
        mutex.lock(); guard invoking, !consumed else { mutex.unlock(); throw NativeDeliveryExecutionError.phase }
        consumed = true; mutex.unlock()
        if let incoming {
            let capture = try resolver.commitIncomingLocalExact(original, store: store, previous: previous,
                source: incoming, operationID: operationID, generationID: generationID, retainedEntryIDs: retained,
                selected: selected, peerPinHex: peerPinHex)
            return .init(self, capture: capture)
        }
        let result = try resolver.commitSelectionOrRemovalExact(original, store: store, previous: previous,
            operationID: operationID, generationID: generationID, retainedEntryIDs: retained,
            configuredEntryID: selected, admissionEnabled: true)
        return .init(self, capture: result.0)
    }
    func unwrap(_ result: NativeInstallationUnifiedLocalDispatchResult) throws -> DeviceMixedInventoryStore.Capture {
        guard result.command == ObjectIdentifier(self) else { throw NativeDeliveryExecutionError.association }; return result.capture
    }
}

/// Fixed first delivery with short state reservations. Installation, authority, store and backend
/// calls are ALWAYS outside the session mutex. Concurrent/reentrant methods fail promptly;
/// late cleanup can release only its exact reservation and cannot overwrite a newer state.
@_spi(NativeInstallation) public final class NativeDeliveryExecutionSession: CustomReflectable {
    private struct State {
        var baseline: DeviceStructuralStore.NativeGenesisCheckpoint
        var request: DeviceNativeProvisioningRequest?
        var terminal: DeviceNativeBoundGrantTerminal?
        var activationRequest: DeviceNativeActivationRequestReceipt?
        var activationBody: NativeDeliveryDurableBody?
        var authorization: DeviceNativeRetainedAuthorization?
        var authorizationObservation: NativeDeliveryActivationHTTPObservation?
        var staticContent: DeviceManagedStaticContent?
        var structuralAcknowledgment: DeviceNativeStructuralCommitAcknowledgment?
        var completion: DeviceNativeProvisioningCompletionAcknowledgment?
        var outgoing: DeviceNativeOutgoingActivatedReceipt?
        var outcomeBody: NativeDeliveryDurableBody?
        var exactPreparation: Data?
        var activationStart: ContinuousClock.Instant?
        var originalActivationRequestID: UUID?
    }
    private final class Reservation { let original: State; init(_ state: State) { original = state } }
    private let stores: NativeDeliveryExecutionStoreBinding
    private let installation: NativeOperationalInstallation
    private let activation: NativeActivationReceipt
    private let coordinator: DeviceNativeGrantPrivateCoordinator
    private let mutex = NSLock()
    private var state: State
    private var active: Reservation?
    enum ActivationRetentionTestBoundary { case beforeRetain, afterRetain }
    private var activationRetentionTestFault: ((ActivationRetentionTestBoundary) throws -> Void)?
    // Internal synthetic fault seam only; it cannot construct or renew any capability/receipt.
    func setActivationRetentionFaultForTesting(_ fault: ((ActivationRetentionTestBoundary) throws -> Void)?) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard active == nil else { throw NativeDeliveryExecutionError.phase }
        activationRetentionTestFault = fault
    }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    private init(stores: NativeDeliveryExecutionStoreBinding, installation: NativeOperationalInstallation,
                 activation: NativeActivationReceipt) {
        self.stores = stores; self.installation = installation; self.activation = activation
        state = State(baseline: stores.genesis)
        coordinator = .init(journal: stores.journal, structural: stores.structural, packages: stores.packages, grants: stores.grants)
    }
    private func begin() throws -> Reservation {
        mutex.lock(); defer { mutex.unlock() }
        guard active == nil else { throw NativeDeliveryExecutionError.phase }
        let reservation = Reservation(state); active = reservation; return reservation
    }
    private func finish(_ reservation: Reservation, _ next: State) {
        mutex.lock(); defer { mutex.unlock() }
        guard active === reservation else { return }
        // Retain exact process latches and genuinely obtained intermediate ACKs even on failure.
        // No failed command can publish an outgoing body or fabricate store qualification.
        state = next; active = nil
    }
    static func make(stores: NativeDeliveryExecutionStoreBinding, installation: NativeOperationalInstallation,
                     activation: NativeActivationReceipt) throws -> NativeDeliveryExecutionSession {
        try installation.validateActivation(activation); try installation.requireDurableActivationAssociation(activation)
        let owner = stores.genesis.state.owner
        guard owner.installationID == activation.installationId, owner.accountID == activation.accountId,
              owner.locationID == activation.locationId, owner.transitionID == activation.transitionId,
              stores.genesis.state.entries.isEmpty, stores.genesis.state.configuredEntryID == nil,
              stores.genesis.rootID == stores.structural.rootID else { throw NativeDeliveryExecutionError.association }
        return .init(stores: stores, installation: installation, activation: activation)
    }
    public func freshGenesisObservation(current: NativeCurrentInstallationDispatch) throws -> NativeDeliveryDurableBody {
        let reservation = try begin(); var work = reservation.original; defer { finish(reservation, work) }
        guard work.request == nil else { throw NativeDeliveryExecutionError.phase }
        try current.validateInstallationExact(installation: installation)
        let checked = try stores.structural.initializeNativeGenesisExplicit(work.baseline.state)
        guard checked.state == work.baseline.state else { throw NativeDeliveryExecutionError.association }
        try current.validateInstallationExact(installation: installation)
        work.baseline = checked
        let owner = checked.state.owner
        let object: [String: Any] = ["schemaVersion": 1, "installationId": owner.installationID.uuidString.lowercased(),
            "transitionId": owner.transitionID.uuidString.lowercased(), "generationId": checked.state.generationID.uuidString.lowercased(),
            "entries": [], "configuredEntryId": NSNull()]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= 16384 else { throw NativeDeliveryExecutionError.bounds }
        return .init(bytes, session: ObjectIdentifier(self), kind: .state, installation: installation)
    }
    public func prepareStaticFirstDelivery(command: Data, associationHeader: String, rawPlan: Data,
        nativeOperationID: UUID, grantOperationID: UUID, grantRevisionID: UUID, archives: [NativeDeliveryArchiveInput]) throws {
        try Task.checkCancellation()
        let reservation = try begin(); var work = reservation.original; defer { finish(reservation, work) }
        guard work.request == nil else { throw NativeDeliveryExecutionError.phase }
        try installation.requireDurableActivationAssociation(activation)
        let effective = NativeDeliveryExecutionStoreBinding(packages: stores.packages, grants: stores.grants,
            structural: stores.structural, journal: stores.journal, genesis: work.baseline)
        let next = try Self.makeStaticRequest(stores: effective, command: command, associationHeader: associationHeader,
            rawPlan: rawPlan, nativeOperationID: nativeOperationID, grantOperationID: grantOperationID,
            grantRevisionID: grantRevisionID, archives: archives)
        let plan = try DeviceNativeProvisioningPlanner.qualify(next)
        guard work.exactPreparation == nil || work.exactPreparation == plan.intentBytes else { throw NativeDeliveryExecutionError.association }
        try Task.checkCancellation(); work.exactPreparation = plan.intentBytes
        let attachment = try stores.journal.publishDeliveryAttachmentExact(next.delivery)
        let joined = try DeviceNativeProvisioningCoordinator(journal: stores.journal, structural: stores.structural)
            .joinExact(next, plan: plan, attachment: attachment)
        let resolution = try stores.packages.resolveRetainedTerminalExact([])
        let anchor = try coordinator.prepareExact(next, plan: plan, joined: joined, packageResolution: resolution)
        let batch = try coordinator.preparePackagesExact(next, anchor: anchor)
        let credentials = try coordinator.completeCredentialsExact(next, batch: batch)
        work.terminal = try coordinator.closeNativeGrantExact(next, progress: credentials); work.request = next
    }
    public func retainActivationRequest(requestID: UUID) throws -> NativeDeliveryDurableBody {
        let reservation = try begin(); var work = reservation.original; defer { finish(reservation, work) }
        guard let request = work.request, let terminal = work.terminal else { throw NativeDeliveryExecutionError.phase }
        if let original = work.originalActivationRequestID { guard original == requestID else { throw NativeDeliveryExecutionError.association } }
        else { work.originalActivationRequestID = requestID; work.activationStart = ContinuousClock().now }
        if let body = work.activationBody { return body }
        try activationRetentionTestFault?(.beforeRetain)
        let retained = try coordinator.retainNativeActivationRequestExact(request, terminal: terminal, requestID: requestID)
        try activationRetentionTestFault?(.afterRetain)
        work.activationRequest = retained
        let body = NativeDeliveryDurableBody(retained.requestBytes, session: ObjectIdentifier(self), kind: .activation,
            installation: installation, requestID: requestID, requestStart: work.activationStart)
        work.activationBody = body; return body
    }
    /// Only the privately issued fixed HTTPS activation observation can supply accepted bytes.
    /// Parsed/caller JSON has no production overload and cannot authorize structural dispatch.
    public func retainAuthorization(requestBody: NativeDeliveryDurableBody,
        observation: NativeDeliveryActivationHTTPObservation) throws {
        let reservation = try begin(); var work = reservation.original; defer { finish(reservation, work) }
        guard let body = work.activationBody, body.matchesOriginalBody(requestBody),
              let request = work.request, let original = work.activationRequest else { throw NativeDeliveryExecutionError.association }
        let response = try observation.validatedResponse(for: body, installation: installation)
        guard response.count <= 4096 else { throw NativeDeliveryExecutionError.bounds }
        work.authorization = try coordinator.retainNativeAuthorizationExact(request, original: original, response: response)
        work.authorizationObservation = observation
    }
    public func dispatchAndRetainActivatedOutcome(current: NativeCurrentInstallationDispatch) throws -> NativeDeliveryDurableBody {
        let reservation = try begin(); var work = reservation.original; defer { finish(reservation, work) }
        guard let request = work.request, let terminal = work.terminal, let authorization = work.authorization,
              let observation = work.authorizationObservation, let body = work.activationBody,
              let start = work.activationStart else { throw NativeDeliveryExecutionError.phase }
        if work.structuralAcknowledgment == nil {
            let command = NativeInstallationStructuralDispatchCommand(coordinator: coordinator, request: request,
                terminal: terminal, authorization: authorization, observation: observation, body: body,
                installation: installation, current: current, start: start)
            // The concrete authority holds its original operation through the complete fixed
            // resource command and scope exit. There is no check-then-ordinary-commit fallback.
            let result = try current.performFixedStructuralDispatch(command)
            work.structuralAcknowledgment = try command.unwrap(result)
        }
        if work.completion == nil {
            guard let original = work.structuralAcknowledgment else { throw NativeDeliveryExecutionError.phase }
            work.completion = try coordinator.completeNativeProvisioningExact(request, original: original)
        }
        guard let completion = work.completion else { throw NativeDeliveryExecutionError.phase }
        if work.outgoing == nil { work.outgoing = try coordinator.retainNativeActivatedReceiptExact(request, completed: completion, authorization: authorization) }
        guard let outgoing = work.outgoing else { throw NativeDeliveryExecutionError.phase }
        if let body = work.outcomeBody { return body }
        let outgoingBody = NativeDeliveryDurableBody(outgoing.bytes, session: ObjectIdentifier(self), kind: .outcome,
            installation: installation, requestID: authorization.requestID, requestStart: start)
        work.outcomeBody = outgoingBody; return outgoingBody
    }
    /// Original completed resources only. Current installation permission is checked separately;
    /// the returned immutable snapshot is not an ongoing presentation authorization.
    func confirmUnifiedMountedContentExact(_ content: DeviceManagedStaticContent,
        inventory: DeviceMixedInventoryStore.Capture, current: NativeCurrentInstallationDispatch) throws -> NativeMountedContentObservation {
        try current.validateInstallationExact(installation: installation)
        guard inventory.snapshot.installationOwner.installationID == activation.installationId,
              inventory.snapshot.installationOwner.accountID == activation.accountId,
              inventory.snapshot.installationOwner.transitionID == activation.transitionId,
              content.generationID == inventory.snapshot.generationID,
              content.entryID == inventory.snapshot.configuredEntryID,
              let entry = inventory.snapshot.entries.first(where: { $0.entryID == content.entryID }) else { throw NativeDeliveryExecutionError.association }
        let digest: String
        switch entry {
        case .retainedLocal(let local): digest = local.entry.revision.digest
        case .cloud(let cloud, _): digest = cloud.package.manifestDigest.text
        }
        try content.verifyResources()
        try current.validateInstallationExact(installation: installation)
        return NativeMountedContentObservation(installation: installation, content: content, packageDigest: digest)
    }
    func makeUnifiedActivationBodyExact(bytes: Data, requestID: UUID, current: NativeCurrentInstallationDispatch,
        session: ObjectIdentifier) throws -> NativeDeliveryDurableBody {
        try current.validateInstallationExact(installation: installation)
        return NativeDeliveryDurableBody(bytes, session: session, kind: .activation, installation: installation,
            requestID: requestID, requestStart: ContinuousClock().now)
    }
    func makeUnifiedAcceptanceExact(current: NativeCurrentInstallationDispatch, binding: DeviceNativeDeliveryCommandBinding,
        commonRootID: UUID, containsLocal: Bool, persist: @escaping () throws -> Void) throws -> NativeInstallationUnifiedCloudAcceptanceCommand {
        try current.validateInstallationExact(installation: installation)
        try current.validateFixedUnifiedCommandEvidence(installation: installation, association: binding.association)
        return try .init(current: current, binding: binding, commonRootID: commonRootID, containsLocal: containsLocal,
            validate: { [installation] in
                try current.validateFixedUnifiedCommandEvidence(installation: installation, association: binding.association)
            }, persist: persist)
    }
    func validateUnifiedAuthorizationExact(body: NativeDeliveryDurableBody,
        observation: NativeDeliveryActivationHTTPObservation, binding: DeviceNativeDeliveryCommandBinding) throws -> Data {
        let requestID = try body.requireActivationOriginal(installation: installation)
        let bytes = try observation.validatedResponse(for: body, installation: installation)
        _ = try DeviceNativeDeliveryHTTPCodec.observe(bytes, kind: .activationResponse, binding: binding, requestID: requestID)
        return bytes
    }
    func validateUnifiedReceiptExact(body: NativeDeliveryDurableBody, observation: NativeDeliveryReceiptHTTPObservation,
        binding: DeviceNativeDeliveryCommandBinding, expectedOutcome: String = "activated") throws -> (Data, UUID) {
        let response = try observation.validatedResponse(for: body, installation: installation)
        let parsed = try DeviceNativeDeliveryHTTPCodec.observe(response, kind: .terminalResponse, binding: binding,
            requestID: nil, expectedOutcome: expectedOutcome)
        guard let receiptID = parsed.receiptID else { throw NativeDeliveryExecutionError.association }
        return (response, receiptID)
    }
    func makeUnifiedOutcomeBodyExact(bytes: Data, requestID: UUID?, current: NativeCurrentInstallationDispatch,
        session: ObjectIdentifier) throws -> NativeDeliveryDurableBody {
        try current.validateInstallationExact(installation: installation)
        return NativeDeliveryDurableBody(bytes, session: session, kind: .unifiedOutcome, installation: installation,
            requestID: requestID, requestStart: nil)
    }
    func makeUnifiedStructuralCommandExact(resolver: DeviceMixedResourceResolver, original: DeviceMixedResolvedResources,
        store: DeviceMixedInventoryStore, incoming: DeviceMixedIncomingResources,
        body: NativeDeliveryDurableBody, observation: NativeDeliveryActivationHTTPObservation,
        current: NativeCurrentInstallationDispatch) throws -> NativeInstallationUnifiedStructuralDispatchCommand {
        try current.validateInstallationExact(installation: installation)
        let requestID = try body.requireActivationOriginal(installation: installation)
        _ = try DeviceNativeDeliveryHTTPCodec.observe(observation.validatedResponse(for: body, installation: installation),
            kind: .activationResponse, binding: incoming.command.delivery, requestID: requestID)
        return .init(resolver: resolver, original: original, store: store, incoming: incoming,
            installation: installation, current: current, body: body, observation: observation)
    }
    public func validateUnifiedInventoryAssociation(current: NativeCurrentInstallationDispatch) throws {
        _ = try mixedInventorySourceExact(current: current)
    }
    public func restoreCompletedStaticDelivery(nativeOperationID: UUID, grantOperationID: UUID, grantRevisionID: UUID) throws {
        let reservation = try begin(); var work = reservation.original
        defer { finish(reservation, work) }
        guard work.request == nil, work.completion == nil else { throw NativeDeliveryExecutionError.phase }
        let restored = try coordinator.restoreCompletedStaticSourceExact(operationID: nativeOperationID,
            grantOperationID: grantOperationID, grantRevisionID: grantRevisionID, baseline: work.baseline)
        try installation.requireDurableActivationAssociation(activation)
        work.request = restored.0; work.completion = restored.1
    }
    /// Genuine enrollment genesis or genuinely completed delivery; never a synthetic empty completion.
    func mixedInventorySourceExact(current: NativeCurrentInstallationDispatch? = nil) throws -> (DeviceNativeGrantPrivateCoordinator, DeviceMixedNativeSource) {
        let reservation = try begin(); let work = reservation.original
        defer { finish(reservation, work) }
        if let current { try current.validateInstallationExact(installation: installation) }
        let source: DeviceMixedNativeSource
        if let request = work.request, let completion = work.completion {
            try coordinator.verifyUnifiedInventorySourceExact(request, completed: completion)
            source = .completed(request, completion)
        } else {
            guard work.request == nil, work.completion == nil else { throw NativeDeliveryExecutionError.phase }
            try coordinator.verifyUnifiedGenesisSourceExact(work.baseline)
            source = .genesis(work.baseline, .init(journalID: stores.journal.rootID, structuralID: stores.structural.rootID,
                packageID: stores.packages.rootID, grantID: stores.grants.rootID))
        }
        try installation.requireDurableActivationAssociation(activation)
        if let current { try current.validateInstallationExact(installation: installation) }
        return (coordinator, source)
    }
    func mixedResourceSourceExact() throws -> (DeviceNativeGrantPrivateCoordinator, DeviceNativeProvisioningRequest, DeviceNativeProvisioningCompletionAcknowledgment) {
        let reservation = try begin(); let work = reservation.original
        defer { finish(reservation, work) }
        guard let request = work.request, let completion = work.completion else { throw NativeDeliveryExecutionError.phase }
        try coordinator.verifyUnifiedInventorySourceExact(request, completed: completion)
        try installation.requireDurableActivationAssociation(activation)
        return (coordinator, request, completion)
    }
    public func qualifiedResetResourcesExact() throws -> DeviceOwnedInstallationResetResources {
        let source = try mixedInventorySourceExact()
        let result = try DeviceMixedResourceResolver(native: source.0).qualifiedNativeResetResourcesExact(source.1)
        try installation.requireDurableActivationAssociation(activation)
        return result
    }
    public func validateUnifiedInventoryResourceAssociation() throws {
        _ = try mixedInventorySourceExact()
    }
    /// Original completed resource graph only. This accessor does not admit a command
    /// or manufacture a current installation dispatch capability.
    func mixedResourceSourceExact(current: NativeCurrentInstallationDispatch) throws ->
        (DeviceNativeGrantPrivateCoordinator, DeviceNativeProvisioningRequest, DeviceNativeProvisioningCompletionAcknowledgment) {
        let reservation = try begin(); let work = reservation.original
        defer { finish(reservation, work) }
        guard let request = work.request, let completion = work.completion else { throw NativeDeliveryExecutionError.phase }
        try current.validateFixedCommandEvidence(installation: installation, association: request.delivery.association)
        return (coordinator, request, completion)
    }
    public func completedStaticContent(current:NativeCurrentInstallationDispatch)throws->DeviceManagedStaticContent {
        let reservation=try begin();var work=reservation.original;defer{finish(reservation,work)}
        guard let request=work.request,let completed=work.completion else {throw NativeDeliveryExecutionError.phase}
        try current.validateInstallationExact(installation:installation)
        let content: DeviceManagedStaticContent
        if let original = work.staticContent { content = original }
        else { content = try coordinator.projectNativeCompletedStaticExact(request,completed:completed); work.staticContent = content }
        try current.validateInstallationExact(installation:installation)
        try content.verifyResources();return content
    }
    public func confirmMountedStaticContent(_ content: DeviceManagedStaticContent, current: NativeCurrentInstallationDispatch) throws -> NativeMountedContentObservation {
        try mountObservation(content: content, current: current)
    }
    public func mountObservation(content: DeviceManagedStaticContent,
        current: NativeCurrentInstallationDispatch) throws -> NativeMountedContentObservation {
        let reservation = try begin(); let work = reservation.original
        defer { finish(reservation, work) }
        guard work.staticContent === content, let request = work.request,
              content.generationID == request.candidate.generationID,
              let entry = request.candidate.entries.first(where: { $0.entryID == content.entryID }) else { throw NativeDeliveryExecutionError.association }
        try current.validateInstallationExact(installation: installation)
        try content.verifyResources()
        try current.validateInstallationExact(installation: installation)
        return .init(installation: installation, content: content, packageDigest: entry.package.manifestDigest.text)
    }
    public func retainOutcomeAcknowledgment(body: NativeDeliveryDurableBody,
        observation: NativeDeliveryReceiptHTTPObservation) throws -> UUID {
        let reservation = try begin(); var work = reservation.original; defer { finish(reservation, work) }
        guard let original = work.outcomeBody, original.matchesOriginalBody(body),
              let request = work.request, let outgoing = work.outgoing else { throw NativeDeliveryExecutionError.association }
        let response = try observation.validatedResponse(for: original, installation: installation)
        guard response.count <= 16384 else { throw NativeDeliveryExecutionError.bounds }
        return try coordinator.retainNativeReceiptAcknowledgmentExact(request, outgoing: outgoing, response: response).receiptID
    }
    // Nonsecret test observation cannot construct authority, receipts or renew an attempt.
    func originalActivationAttemptForTesting() -> (UUID, ContinuousClock.Instant)? {
        mutex.lock(); defer { mutex.unlock() }
        guard let id = state.originalActivationRequestID, let start = state.activationStart else { return nil }
        return (id, start)
    }
    /// Pure assembly from genuine bounded archives and an explicit genuine initialized baseline.
    /// This internal helper creates no installation authority and performs no store effects.
    static func makeStaticRequest(stores: NativeDeliveryExecutionStoreBinding, command: Data,
        associationHeader: String, rawPlan: Data, nativeOperationID: UUID, grantOperationID: UUID,
        grantRevisionID: UUID, archives: [NativeDeliveryArchiveInput]) throws -> DeviceNativeProvisioningRequest {
        guard archives.count <= 12, command.count <= 16384, rawPlan.count <= 65536,
              associationHeader.utf8.prefix(1367).count <= 1366,
              archives.allSatisfy({ $0.archiveBytes.count <= 25 * 1024 * 1024
                  && $0.profileID.utf8.prefix(1025).count <= 1024
                  && $0.revisionName.utf8.prefix(1025).count <= 1024 }) else { throw NativeDeliveryExecutionError.bounds }
        let binding = try DeviceNativeDeliveryCommandBinding.bind(command: command, associationHeader: associationHeader,
            rawPlan: rawPlan, nativeOperationID: nativeOperationID, journalRootID: stores.journal.rootID)
        let owner = stores.genesis.state.owner
        guard binding.association.installationID == owner.installationID,
              binding.association.accountID == owner.accountID,
              binding.association.transitionID == owner.transitionID,
              binding.expectedGenerationID == stores.genesis.state.generationID,
              archives.count == binding.resultingSet.entries.count else { throw NativeDeliveryExecutionError.association }
        var seen = Set<UUID>(), packages: [DeviceProvisioningPackageInput] = []
        var entries: [DeviceNativeStructuralEntry] = [], grantEntries: [DeviceGrantEntryInput] = []
        var expectations: [DeviceGrantEntryExpectation] = []
        for cloud in binding.resultingSet.entries {
            guard case .cloud(let descriptor) = cloud.provenance,
                  let supplied = archives.first(where: { $0.entryID == cloud.entryID }),
                  seen.insert(supplied.entryID).inserted else { throw NativeDeliveryExecutionError.association }
            let expected = DevicePackageExpectation(revision: .init(revision: descriptor.revision.uuidString.lowercased(), dashboardId: descriptor.dashboardID.uuidString.lowercased(),
                name: supplied.revisionName, digest: descriptor.manifestDigest.text, orientation: supplied.target.orientation,
                width: supplied.target.width, height: supplied.target.height),
                target: supplied.target, profileID: supplied.profileID)
            let qualified = try DeviceNativeArchiveQualifier.qualifyApprovedManifestName(supplied.archiveBytes, descriptor: descriptor, expected: expected).package
            guard qualified.manifest.connections.isEmpty else { throw NativeDeliveryExecutionError.unsupportedCapabilities }
            let reference = try PackagePreparationCodec.expectedReference(.init(operationID: supplied.preparationOperationID,
                package: qualified), rootID: stores.packages.rootID)
            packages.append(.supplied(entryID: cloud.entryID, operationID: supplied.preparationOperationID, package: qualified))
            entries.append(try .validating(entryID: cloud.entryID, displayName: qualified.manifest.name, package: descriptor, preparedPackage: reference))
            grantEntries.append(.init(entryID: cloud.entryID, revision: qualified.revision, generic: nil,
                homeAssistant: nil, publicReads: nil, credentialReferences: []))
            expectations.append(.init(entryID: cloud.entryID, package: qualified))
        }
        guard seen.count == archives.count else { throw NativeDeliveryExecutionError.association }
        let candidate = try DeviceNativeStructuralState.validating(generationID: binding.desiredGenerationID,
            owner: .nativeInstallation(owner), entries: entries, configuredEntryID: binding.resultingSet.configuredEntryID)
        let input = DeviceNativeGrantRevisionInput(schemaVersion: 2,
            identity: .init(rootID: stores.grants.rootID, revisionID: grantRevisionID), owner: owner,
            entries: grantEntries, credentials: [], retainedRevisions: [])
        let qualifiedGrant = try DeviceNativeGrantRevisionQualifier.qualify(input, expectedEntries: expectations)
        let next = DeviceNativeProvisioningRequest(roots: .init(journalID: stores.journal.rootID,
            structuralID: stores.structural.rootID, packageID: stores.packages.rootID, grantID: stores.grants.rootID),
            delivery: binding, grantOperationID: grantOperationID, baseline: stores.genesis, candidate: candidate,
            packages: packages, grantInput: input, qualifiedGrant: qualifiedGrant)
        _ = try DeviceNativeProvisioningPlanner.qualify(next)
        return next
    }
}
