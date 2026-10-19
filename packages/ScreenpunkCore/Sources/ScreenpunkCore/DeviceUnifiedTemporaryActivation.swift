import Foundation

/// Only the approved native event reader below can issue automatic selections.
/// This is not a local-controller or cloud-command authority.
final class DeviceUnifiedAutomaticSelectionPermit {
    enum Phase { case activate, restore }
    let explicitBaseGenerationID: UUID
    let owner: any NativeUnifiedAutomationOwner
    let phase: Phase
    let baseCapture: DeviceMixedInventoryStore.Capture
    let targetEntryID: UUID
    let previousEntryID: UUID?
    let deadline: Date
    let alertID: String
    let navigation: TemporaryActivationNavigation
    private let validate: () throws -> Void
    fileprivate init(explicitBaseGenerationID: UUID, owner: any NativeUnifiedAutomationOwner, phase: Phase, baseCapture: DeviceMixedInventoryStore.Capture, targetEntryID: UUID,
        previousEntryID: UUID?, deadline: Date, alertID: String, navigation: TemporaryActivationNavigation,
        validate: @escaping () throws -> Void) {
        self.explicitBaseGenerationID = explicitBaseGenerationID; self.owner = owner; self.phase = phase; self.baseCapture = baseCapture; self.targetEntryID = targetEntryID
        self.previousEntryID = previousEntryID; self.deadline = deadline; self.alertID = alertID
        self.navigation = navigation; self.validate = validate
    }
    func validateEvent() throws { try validate() }
}

/// Reads exactly the installed recipe's approved entity. Transport credentials
/// stay in this actor; package JavaScript cannot provide event data or targets.
@_spi(ManagedRender) public actor DeviceUnifiedTemporaryActivationDriver {
    private let session: DeviceUnifiedInventorySession
    private let http: any HTTPTransport
    private let resolver: any DestinationResolver
    private let clock: any PairingClock
    private var navigation = TemporaryActivationNavigation()
    private var ownedGeneration: UUID?
    private var retainedOwner: (any NativeUnifiedAutomationOwner)?
    private var explicitBaseGenerationID: UUID?
    private var lastAutomationGenerationID: UUID?
    private var hydrated = false
    private var previousEntryID: UUID?
    private var activeTargetEntryID: UUID?
    private var retired = false
    private var inFlight = false
    init(session: DeviceUnifiedInventorySession, http: any HTTPTransport, resolver: any DestinationResolver, clock: any PairingClock) {
        self.session = session; self.http = http; self.resolver = resolver; self.clock = clock
    }
    private func hydrate() throws {
        guard !hydrated else { return }
        if let frame = try session.automationCheckpointExact() {
            navigation = frame.navigation; ownedGeneration = frame.ownedGenerationID
            previousEntryID = frame.previousEntryID; activeTargetEntryID = frame.targetEntryID
            explicitBaseGenerationID = frame.explicitBaseGenerationID
            lastAutomationGenerationID = frame.generationID
            let current = try session.automationSourceExact()
            if current.capture.snapshot.generationID == frame.generationID {
                retainedOwner = try? session.automationOwnerExact(baseGenerationID: frame.explicitBaseGenerationID)
            }
        }
        hydrated = true
    }
    public func cancel() { retired = true }
    public func expire() throws -> Bool {
        guard !retired else { throw CancellationError() }
        try hydrate()
        guard let ownedGeneration, let owner = retainedOwner, let explicitBase = explicitBaseGenerationID, let target = activeTargetEntryID,
            let deadline = navigation.expiresAt, clock.now >= deadline, let alertID = navigation.alertId else { return false }
        let source = try session.automationSourceExact()
        guard source.capture.snapshot.generationID == ownedGeneration else {
            navigation.manualSelection(); self.ownedGeneration = nil; retainedOwner = nil; previousEntryID = nil; return false
        }
        let selected = source.capture.snapshot.configuredEntryID?.uuidString.lowercased() ?? "blank"
        let originalNavigation = navigation
        guard navigation.expire(selected: selected, now: clock.now) != nil else { return false }
        let clock = self.clock
        let permit = DeviceUnifiedAutomaticSelectionPermit(explicitBaseGenerationID: explicitBase, owner: owner, phase: .restore, baseCapture: source.capture, targetEntryID: target,
            previousEntryID: previousEntryID, deadline: deadline, alertID: alertID, navigation: navigation, validate: {
                guard clock.now >= deadline else { throw ConnectionFailure.permissionRequired }; try source.validate()
            })
        do {
            let committed = try session.commitAutomaticSelectionExact(permit)
            if committed {
                self.ownedGeneration = nil; activeTargetEntryID = nil; previousEntryID = nil
                lastAutomationGenerationID = try session.automationCheckpointExact()?.generationID
            }
            else { navigation = originalNavigation }
            return committed
        } catch { navigation = originalNavigation; throw error }
    }
    public func poll() async throws -> Bool {
        guard !retired else { throw CancellationError() }
        guard !inFlight else { return false }
        try hydrate()
        inFlight = true; defer { inFlight = false }
        try Task.checkCancellation()
        let source = try session.automationSourceExact()
        if let lastAutomationGenerationID, source.capture.snapshot.generationID != lastAutomationGenerationID {
            navigation.manualSelection(); ownedGeneration = nil; retainedOwner = nil; previousEntryID = nil
            explicitBaseGenerationID = nil; activeTargetEntryID = nil; self.lastAutomationGenerationID = nil
        }
        if retainedOwner != nil, let originalBase = explicitBaseGenerationID {
            do { _ = try session.automationOwnerExact(baseGenerationID: originalBase) }
            catch {
                navigation.manualSelection(); ownedGeneration = nil; retainedOwner = nil; previousEntryID = nil
                explicitBaseGenerationID = nil; activeTargetEntryID = nil; lastAutomationGenerationID = nil
            }
        }
        var candidates: [(UUID, TemporaryActivationConfiguration, HomeAssistantProvisioning)] = []
        var dashboards = Set<String>()
        for entry in source.capture.snapshot.entries {
            guard case .retainedLocal = entry else { continue }
            let local = try source.resolver.installedLocalRuntimeSourceExact(source.original, store: source.store,
                current: source.capture, entryID: entry.entryID)
            guard let recipe = local.package.manifest.deviceBehavior?.temporaryActivation else { continue }
            try recipe.validate()
            guard source.capture.snapshot.entries.filter({ $0.dashboardID == entry.dashboardID }).count == 1,
                dashboards.insert(entry.dashboardID).inserted else { throw ConnectionFailure.permissionRequired }
            let seed = try local.gate.makeUnifiedRuntimeSeedExact(binding: local.binding, entryID: local.entryID)
            guard let configuration = seed.homeAssistant else { throw ConnectionFailure.permissionRequired }
            _ = try configuration.authorize(operation: "getStates", parameters: [:])
            candidates.append((entry.entryID, recipe, configuration))
        }
        if candidates.isEmpty { return false }
        guard candidates.count == 1, let (target, recipe, configuration) = candidates.first else {
            throw ConnectionFailure.permissionRequired
        }
        let explicitBase = retainedOwner != nil ? (explicitBaseGenerationID ?? source.capture.snapshot.generationID) : source.capture.snapshot.generationID
        let owner = try retainedOwner ?? session.automationOwnerExact(baseGenerationID: explicitBase)
        try source.validate()
        let destination = try ConnectionPolicy.authorize(grant: configuration.connectionGrant(path: "/api/states/" + recipe.entityId, write: false),
            operationName: "request", parameters: [:], resolvedAddresses: resolver.addresses(for: ConnectionPolicy.originHost(configuration.origin)),
            binding: .init(authRef: "home-device", placement: .bearer))
        let response = try await http.send(.init(url: destination.url, method: "GET", headers: ["Authorization": "Bearer " + configuration.token],
            body: nil, timeout: 10, maxBytes: 65536))
        try Task.checkCancellation(); guard !retired else { throw CancellationError() }; try source.validate()
        guard response.status != 401, response.status != 403 else { throw ConnectionFailure.permissionRequired }
        guard response.status == 200, response.body.count <= 65536,
            let state = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            state["entity_id"] as? String == recipe.entityId else { throw ConnectionFailure.validationFailed }
        let selected = source.capture.snapshot.configuredEntryID?.uuidString.lowercased() ?? "blank"
        let originalNavigation = navigation
        guard let proposed = navigation.receive(state: state, configuration: recipe, target: target.uuidString.lowercased(), selected: selected, now: clock.now),
            let deadline = navigation.expiresAt, let alertID = navigation.alertId else { return false }
        let phase: DeviceUnifiedAutomaticSelectionPermit.Phase = proposed == target.uuidString.lowercased() ? .activate : .restore
        if phase == .activate { previousEntryID = source.capture.snapshot.configuredEntryID; activeTargetEntryID = target }
        let permit = DeviceUnifiedAutomaticSelectionPermit(explicitBaseGenerationID: explicitBase, owner: owner, phase: phase, baseCapture: source.capture, targetEntryID: target,
            previousEntryID: previousEntryID, deadline: deadline, alertID: alertID, navigation: navigation, validate: source.validate)
        do {
            let committed = try session.commitAutomaticSelectionExact(permit)
            if committed {
                let committedFrame = try session.automationCheckpointExact()
                ownedGeneration = phase == .activate ? committedFrame?.ownedGenerationID : nil
                lastAutomationGenerationID = committedFrame?.generationID
                retainedOwner = owner
                explicitBaseGenerationID = explicitBase
                if phase == .restore { activeTargetEntryID = nil; previousEntryID = nil }
            }
            else { navigation = originalNavigation }
            return committed
        } catch { navigation = originalNavigation; throw error }
    }
}
extension DeviceUnifiedInventorySession {
    @_spi(ManagedRender) public func makeTemporaryActivationDriver(http: any HTTPTransport, resolver: any DestinationResolver, clock: any PairingClock = SystemClock()) -> DeviceUnifiedTemporaryActivationDriver {
        DeviceUnifiedTemporaryActivationDriver(session: self, http: http, resolver: resolver, clock: clock)
    }
}
