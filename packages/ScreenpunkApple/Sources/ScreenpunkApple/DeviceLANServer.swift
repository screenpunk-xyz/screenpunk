import Foundation
@_spi(NativeInstallation) import ScreenpunkCore
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif

#if canImport(Network) && canImport(Security)
/// Device-side TLS 1.3 listener. Pairing and deploy run over the authenticated channel.
///
/// The SAS transcript and the owner check bind to the controller pin observed in
/// each connection's TLS handshake, never to the pin a message claims. Owner,
/// active revision, and package bytes persist through `DeviceStateStore` so a
/// relaunch returns paired and rendering; Unlink erases all of it.
public struct DevicePendingPairingRequest: Sendable, Equatable {
    public let code: String
    public let sessionNonceHex: String
}

public final class DeviceLANServer: @unchecked Sendable {
    public private(set) var runtime: DeviceRuntime
    public private(set) var port: UInt16 = 0
    public private(set) var pairingCode: String?
    /// The owner tapped Confirm for the code on screen and the controller's
    /// `pair.confirm` has not completed yet. Lets the UI say so instead of
    /// showing the same code and button again.
    public var awaitingControllerConfirm: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deviceConfirmed && pairingCode != nil
    }
    /// Package bytes of `runtime.activeRevision`. Replaced only after a
    /// transfer activates; a failed transfer leaves the current package in place.
    public private(set) var activePackage: PackageAssetStore?
    public private(set) var screenSet: DeviceInstalledScreenSet?
    private let management: DeviceManagementContext
    private var postCommitActions: [() -> Void] = []
    public var onManagementSuspended: (() -> Void)?
    private var managementSuspended = false
    private var runtimeRetired = false
    private var invalidationObserver: UUID?
    private var listenerAttempt = UUID()
    private var pendingListener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    enum ManagementBoundary: Equatable { case listenerWillStart, listenerReady, handshakeReady, requestReceived(String), pairingWaitStarted }
    // Deterministic test observation only. Invoked outside all locks and never grants admission.
    var managementBoundary: ((ManagementBoundary) -> Void)?
    private func observeManagementBoundary(_ boundary: ManagementBoundary) {
        lock.lock(); let observation = managementBoundary; lock.unlock()
        observation?(boundary)
    }
    var activeConnectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }
    private var settings = DeviceSettingsSnapshot()
    private var temporaryActivationStatus = DeviceTemporaryActivationStatus()
    func updateTemporaryActivationStatus(_ status: DeviceTemporaryActivationStatus) throws {
        try managementTransaction {
            temporaryActivationStatus = status
        }
    }
    private var screenPackages: [String: PackageAssetStore] = [:]
    public var onChange: (() -> Void)?
    public let identity: TLSIdentityMaterial
    public let store: DeviceStateStore?
    public let genericConnectionVault: GenericConnectionDeviceVault
    public private(set) var genericConnectionGeneration = UUID()
    public let homeAssistantVault: HomeAssistantDeviceVault
    public lazy var homeAssistantRuntime = HomeAssistantDeviceRuntime(vault: homeAssistantVault) { [weak self] in
        self?.homeAssistantScope()
    }

    /// Uses the declaring package's grant while another screen is selected.
    /// Ambiguous declarations never select a target implicitly.
    func temporaryActivationScope() -> HomeAssistantDeviceRuntime.Scope? {
        lock.lock(); defer { lock.unlock() }
        return temporaryActivationScopeLocked()
    }
    private func temporaryActivationScopeLocked() -> HomeAssistantDeviceRuntime.Scope? {
        guard let owner = executionOwner, let set = screenSet else { return nil }
        let targets = set.screens.compactMap { screen -> (DeviceInstalledScreen, TemporaryActivationConfiguration)? in
            guard let data = screenPackages[screen.revision.dashboardId]?.assets["manifest.json"]?.data,
                  let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: data),
                  manifest.dashboardId == screen.revision.dashboardId, manifest.revision == screen.revision.revision,
                  let configuration = manifest.deviceBehavior?.temporaryActivation,
                  (try? configuration.validate()) != nil else { return nil }
            return (screen, configuration)
        }
        guard targets.count == 1, let (target, configuration) = targets.first,
              let record = try? homeAssistantVault.record(owner: PeerPin.hex(owner.publicKey), revision: target.revision.revision, grantSet: set.grantSet),
              record.configuration.dashboardId == target.revision.dashboardId,
              (try? record.configuration.authorize(operation: "getStates", parameters: [:])) != nil else { return nil }
        return .init(owner: PeerPin.hex(owner.publicKey), revision: target.revision.revision,
                     dashboardId: target.revision.dashboardId, grantSet: set.grantSet, temporaryActivation: configuration, authorityGeneration: authorityGeneration)
    }

    private func genericConnectionScope() -> GenericConnectionDeviceVault.Scope? {
        lock.lock(); defer { lock.unlock() }
        guard let owner = executionOwner, let revision = runtime.activeRevision,
              let dashboardId = activeStoredRevision?.dashboardId else { return nil }
        return .init(owner: PeerPin.hex(owner.publicKey), dashboardId: dashboardId, revision: revision, authorityGeneration: authorityGeneration)
    }

    public func makeGenericConnectionRuntime() async throws -> ConnectionRuntime {
        guard let scope = genericConnectionScope() else { throw ConnectionFailure.permissionRequired }
        let result = try await genericConnectionVault.makeRuntime(scope: scope, currentScope: { [weak self] in self?.genericConnectionScope() })
        guard genericConnectionScope() == scope, !Task.isCancelled else {
            try? await result.clearCredentials(); throw ConnectionFailure.permissionRequired
        }
        return result
    }
    private var publicSession: (scope: HomeAssistantDeviceRuntime.Scope, session: PublicReadSession)?
    public func publicReadSession() -> PublicReadSession? {
        guard let scope = homeAssistantScope(), let generation = scope.grantSet else { return nil }
        var retired: PublicReadSession?
        lock.lock(); defer { lock.unlock(); retired?.cancel() }
        guard !runtimeRetired else { return nil }
        if let existing = publicSession, existing.scope == scope { return existing.session }
        retired = publicSession?.session; publicSession = nil
        guard let config = try? homeAssistantVault.publicConfiguration(owner: scope.owner, dashboardId: scope.dashboardId,
            revision: scope.revision, generation: generation),
              let session = try? PublicReadSession(provisioning: config, isCurrent: { [weak self] in self?.homeAssistantScope() == scope }) else { return nil }
        publicSession = (scope, session); return session
    }
    private func clearPublicSession() {
        let retired = publicSession?.session; publicSession = nil
        afterCommitLocked { retired?.cancel() }
    }

    private func homeAssistantScope() -> HomeAssistantDeviceRuntime.Scope? {
        lock.lock(); defer { lock.unlock() }
        guard let owner = executionOwner, let revision = runtime.activeRevision, let dashboardId = activeStoredRevision?.dashboardId else { return nil }
        return .init(owner: PeerPin.hex(owner.publicKey), revision: revision, dashboardId: dashboardId, grantSet: screenSet?.grantSet, authorityGeneration: authorityGeneration)
    }
    private var contentOwner: PairingIdentity?
    private var managementGeneration = UUID()
    private var unifiedLocalSession: DeviceUnifiedInventorySession?
    private var unifiedMountStateAssociation: DeviceUnifiedMountStateAssociation?
    private var unifiedMountedAssociation: DeviceUnifiedMountedContentAssociation?
    private var unifiedLocalAssociation: DeviceUnifiedInventoryAssociation?
    @_spi(NativeInstallation) public var onCloudArchiveAdmission: ((UUID, UUID, UUID, String, Int) throws -> Void)?
    @_spi(NativeInstallation) public var onCloudArchiveReceived: ((UUID, UUID, UUID, Data) throws -> Void)?
    private struct CloudArchiveTransfer {
        let peer: [UInt8], installation: UUID, operation: UUID, package: UUID, sha: String, size: Int
        var bytes = Data()
        var updated = Date()
        var complete = false
    }
    private var cloudArchiveTransfers: [UUID: CloudArchiveTransfer] = [:]
    @_spi(NativeInstallation) public var onCloudRelayHint: ((UUID, UUID) -> Void)?
    @_spi(NativeInstallation) public var onCommonContentChanged: (() -> Void)?
    @_spi(NativeInstallation) public var prepareIncomingLocalScreens: ((UUID, PairingIdentity, [DeviceLegacyMigrationScreen], UUID?, @escaping () throws -> Void) throws -> DeviceIncomingLocalPreparation)?
    private var authorityGeneration: UUID?
    /// Content capabilities belong to their installer, independently of management.
    private var executionOwner: PairingIdentity? {
        let owner = contentOwner
        guard !runtimeRetired else { return nil }
        return owner
    }
    public private(set) var completedPairingSessionNonceHex: String?
    public var pendingPairingRequest: DevicePendingPairingRequest? {
        lock.lock(); defer { lock.unlock() }
        guard let code = pairingCode, let session = runtime.pairing.session,
              code == session.expectedCode else { return nil }
        return .init(code: code, sessionNonceHex: PeerPin.hex(session.transcript.sessionNonce))
    }
    public var pendingPairingSessionNonceHex: String? { pendingPairingRequest?.sessionNonceHex }
    private var deviceConfirmed = false
    private var pairingExpiry: DispatchWorkItem?
    private var pinnedController: [UInt8]?
    private var activeStoredRevision: StoredRevision?
    // Internal visibility allows transport-failure regression tests to cancel it.
    private(set) var listener: NWListener?
    private let queue = DispatchQueue(label: "xyz.screenpunk.lan.device")
    private let clock: PairingClock
    private let lock = NSLock()
    /// How long a frame body may trail its header. The wait *between* requests
    /// has no deadline for the owner; see `serve`.
    private let requestBodyTimeout: TimeInterval
    /// Peers that have not proven the owner pin get bounded service: at most
    /// `maxUntrustedConnections` at a time, each closed after
    /// `untrustedIdleTimeout` without a request. The window still covers the
    /// human pause between `pair.begin` and `pair.confirm`, which the code
    /// expiry already bounds. Each accepted connection holds a worker thread,
    /// so without these limits any LAN peer could starve the listener.
    public static let maxUntrustedConnections = 8
    public static let untrustedIdleTimeout: TimeInterval = PairingLimits.expirySeconds + 30
    private let untrustedIdleTimeout: TimeInterval
    private let maxUntrustedConnections: Int
    private var untrustedConnections = 0
    /// Number of non-owner connections currently being served. Test hook.
    var untrustedConnectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return untrustedConnections
    }

    public init(
        management: DeviceManagementContext,
        runtime: DeviceRuntime,
        identity: TLSIdentityMaterial,
        clock: PairingClock = SystemClock(),
        store: DeviceStateStore? = nil,
        homeAssistantVault: HomeAssistantDeviceVault = HomeAssistantDeviceVault(),
        genericConnectionVault: GenericConnectionDeviceVault = GenericConnectionDeviceVault(),
        requestBodyTimeout: TimeInterval = LANProtocolLimits.transferTimeoutSeconds,
        untrustedIdleTimeout: TimeInterval = DeviceLANServer.untrustedIdleTimeout,
        maxUntrustedConnections: Int = DeviceLANServer.maxUntrustedConnections
    ) throws {
        self.management = management
        self.genericConnectionVault = genericConnectionVault
        self.homeAssistantVault = homeAssistantVault
        self.runtime = runtime
        self.contentOwner = runtime.pairing.owner
        self.identity = identity
        self.clock = clock
        self.store = store
        self.requestBodyTimeout = requestBodyTimeout
        self.untrustedIdleTimeout = untrustedIdleTimeout
        self.maxUntrustedConnections = max(1, maxUntrustedConnections)
        self.runtime.identity = identity.pairingIdentity
        try management.withAuthority {
            restoreFromStore()
            let migratedDeployment = DeviceInstallIdentity.migrate(&self.runtime, pin: identity.pin)
            if migratedDeployment { persist() }
            if runtime.profile.model != nil {
                let orientation = self.runtime.profile.orientation
                self.runtime.profile.model = runtime.profile.model
                self.runtime.profile.width = runtime.profile.width
                self.runtime.profile.height = runtime.profile.height
                self.runtime.profile.orientation = .portrait
                self.runtime.profile.apply(orientation: orientation)
            }
        }
        invalidationObserver = try management.observeInvalidation { [weak self] in
            guard let self, self.suspendManagement() else { return }
            self.onManagementSuspended?()
        }
        try management.validate()
    }
    deinit {
        if let invalidationObserver { management.removeInvalidationObserver(invalidationObserver) }
        stop()
    }

    /// Lock ordering is always authority -> server. Work and callbacks escape neither lock.
    private func managementTransaction<T>(_ operation: () throws -> T) throws -> T {
        var actions: [() -> Void] = []
        defer { for action in actions { action() } }
        do {
            return try management.withAuthority {
                lock.lock()
                defer { actions = postCommitActions; postCommitActions = []; lock.unlock() }
                guard !managementSuspended, !runtimeRetired else { throw DeviceManagementAuthority.Failure.staleLease }
                return try operation()
            }
        } catch {
            if error is DeviceManagementAuthority.Failure, suspendManagement() { onManagementSuspended?() }
            throw error
        }
    }
    private func notifyLocked() { if let onChange { postCommitActions.append(onChange) } }
    private func afterCommitLocked(_ action: @escaping () -> Void) { postCommitActions.append(action) }

    /// Revocation-only cleanup is unconditional; it cannot install authority or modify retained content.
    @discardableResult public func suspendManagement() -> Bool {
        lock.lock()
        guard !managementSuspended else { lock.unlock(); return false }
        managementSuspended = true
        managementGeneration = UUID()
        clearPendingPairingLocked()
        completedPairingSessionNonceHex = nil
        lock.unlock()
        stop()
        return true
    }

    /// Terminal content/management fence. Persisted content and credential records stay intact.
    public func retireForReset() {
        lock.lock()
        guard !runtimeRetired else { lock.unlock(); return }
        runtimeRetired = true; authorityGeneration = UUID()
        let session = publicSession?.session; publicSession = nil
        lock.unlock()
        _ = suspendManagement()
        session?.cancel()
        let service = homeAssistantRuntime
        Task { await service.cancelPending() }
    }

    /// Recreate a failed listener without touching pairing or installed content.
    /// May block during startup; callers should use a worker queue.
    public func start() throws {
        let attempt = UUID()
        let needed = try managementTransaction {
            if let listener, case .ready = listener.state { return false }
            let previous = self.listener; let pending = pendingListener; let links = Array(connections.values)
            self.listener = nil; pendingListener = nil; connections = [:]; port = 0; listenerAttempt = attempt
            afterCommitLocked { previous?.cancel(); pending?.cancel(); for link in links { link.cancel() } }
            return true
        }
        guard needed else { return }
        let parameters = try LANChannel.tlsParameters(identity: identity,
            pinnedPeer: { [weak self] in self?.ownerPin() }, allowPairingCandidates: true, queue: queue)
        let candidate = try NWListener(using: parameters, on: .any)
        var installed = false
        defer {
            if !installed {
                candidate.cancel()
                lock.lock()
                if pendingListener === candidate { pendingListener = nil }
                lock.unlock()
            }
        }
        let ready = DispatchSemaphore(value: 0)
        candidate.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            DispatchQueue.global(qos: .userInitiated).async { self?.accept(connection, listenerAttempt: attempt) }
        }
        try managementTransaction {
            guard listenerAttempt == attempt else { throw TransferFailure.interrupted }
            pendingListener = candidate
        }
        // No authority/server lock is held during network setup or readiness waits.
        observeManagementBoundary(.listenerWillStart)
        candidate.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw TransferFailure.interrupted }
        if case .failed(let error) = candidate.state { throw error }
        guard case .ready = candidate.state, let candidatePort = candidate.port?.rawValue else { throw TransferFailure.interrupted }
        observeManagementBoundary(.listenerReady)
        try managementTransaction {
            guard listenerAttempt == attempt, pendingListener === candidate else { throw TransferFailure.interrupted }
            self.listener = candidate; pendingListener = nil; port = candidatePort
            advertiseBonjour(on: candidate)
            runtime.advertisement = AdvertisedDevice(deviceId: runtime.profile.deviceId, host: "127.0.0.1",
                port: Int(candidatePort), source: .advertised)
            installed = true
        }
    }

    public func confirmLocally(expectedSessionNonceHex: String? = nil) throws {
        try managementTransaction {
            expirePairingIfNeededLocked()
            guard pairingCode != nil, runtime.pairing.session != nil else { throw PairingFailure.expired }
            if let expectedSessionNonceHex {
                guard runtime.pairing.session.map({ PeerPin.hex($0.transcript.sessionNonce) }) == expectedSessionNonceHex else { throw PairingFailure.identityChanged }
            }
            deviceConfirmed = true
            notifyLocked()
        }
    }

    /// Cancels only the pending handshake. Existing ownership and deployed content remain intact.
    public func cancelPairing(expectedSessionNonceHex: String? = nil) throws {
        try managementTransaction {
            if let expectedSessionNonceHex, runtime.pairing.session.map({ PeerPin.hex($0.transcript.sessionNonce) }) != expectedSessionNonceHex { return }
            clearPendingPairingLocked()
            notifyLocked()
        }
    }

    /// Also called by the scheduled expiry and directly by deterministic tests.
    public func expirePairingIfNeeded(expectedSessionNonceHex: String? = nil) throws {
        try managementTransaction {
            if let expectedSessionNonceHex, runtime.pairing.session.map({ PeerPin.hex($0.transcript.sessionNonce) }) != expectedSessionNonceHex { return }
            expirePairingIfNeededLocked()
        }
    }

    private func expirePairingIfNeededLocked() {
        guard let session = runtime.pairing.session,
              clock.now.timeIntervalSince(session.createdAt) >= PairingLimits.expirySeconds else { return }
        clearPendingPairingLocked()
        notifyLocked()
    }

    private func clearPendingPairingLocked() {
        pairingExpiry?.cancel()
        pairingExpiry = nil
        runtime.pairing.session = nil
        pairingCode = nil
        deviceConfirmed = false
    }

    private func schedulePairingExpiryLocked() {
        pairingExpiry?.cancel()
        let nonce = runtime.pairing.session.map { PeerPin.hex($0.transcript.sessionNonce) }
        let work = DispatchWorkItem { [weak self] in try? self?.expirePairingIfNeeded(expectedSessionNonceHex: nonce) }
        pairingExpiry = work
        afterCommitLocked { [queue] in queue.asyncAfter(deadline: .now() + PairingLimits.expirySeconds + 0.1, execute: work) }
    }

    /// Erases owner, active revision, package bytes, and everything on disk.
    public func unlink() throws {
        try managementTransaction {
            managementGeneration = UUID()
            authorityGeneration = UUID()
            contentOwner = nil
            completedPairingSessionNonceHex = nil
            try? genericConnectionVault.revoke()
            genericConnectionGeneration = UUID()
            clearPublicSession()
            try? homeAssistantVault.revoke()
            try? homeAssistantVault.revokePublic()
            let homeAssistantRuntime = self.homeAssistantRuntime
            afterCommitLocked { Task { await homeAssistantRuntime.cancelPending() } }
            clearPendingPairingLocked()
            runtime.unlink()
            screenSet = nil
            settings = DeviceSettingsSnapshot()
            screenPackages = [:]
            activePackage = nil
            activeStoredRevision = nil
            pairingCode = nil
            deviceConfirmed = false
            pinnedController = nil
            try? store?.erase()
            notifyLocked()
        }
    }

    /// Durable local disconnect. Credentials, retained content grants, and settings remain.
    public func disconnect(keepScreens: Bool) throws {
        try updateLocalContent(disconnect: true, removing: keepScreens ? [] : nil)
    }

    public func removeScreen(_ dashboardId: String) throws {
        try updateLocalContent(disconnect: false, removing: [dashboardId])
    }

    public func removeAllScreens() throws {
        try updateLocalContent(disconnect: false, removing: nil)
    }

    /// Explicit migration of the exact retained legacy set. Entry/preparation identities are
    /// persisted by the caller before this operation; folder names and display names never
    /// become common inventory identity. The legacy state and vaults remain untouched.
    @_spi(NativeInstallation) public func migrateLegacyInventory(into session: DeviceLegacyMigrationSession,
        entryIDs: [String: UUID], packageOperationIDs: [String: UUID], profile: DeviceProfile, profileID: String,
        operationID: UUID, grantOperationID: UUID, generationID: UUID, grantRevisionID: UUID) throws {
        try managementTransaction {
            guard let store, let baseline = store.load(), let owner = contentOwner,
                owner.isWellFormed, owner.role == .controller else { throw DeviceManagementAuthority.Failure.staleLease }
            let screens: [DeviceInstalledScreen]
            if let set = baseline.screenSet { screens = set.screens }
            else if let revision = baseline.activeStoredRevision, let deployment = baseline.lastDeployment {
                screens = [.init(name: revision.name, revision: revision, deployment: deployment, packageDirectory: "package")]
            } else { screens = [] }
            guard screens.count <= 12, Set(screens.map { $0.revision.dashboardId }).count == screens.count,
                Set(entryIDs.keys) == Set(screens.map { $0.revision.dashboardId }),
                Set(packageOperationIDs.keys) == Set(entryIDs.keys) else { throw ConnectionFailure.validationFailed }
            var inputs: [DeviceLegacyMigrationScreen] = []
            let pin = PeerPin.hex(owner.publicKey)
            // Locks are retained recursively until all approvals have entered the durable
            // protected migration transaction. This follows LAN server -> HA -> Generic order.
            func consume(_ index: Int) throws {
                if index == screens.count {
                    let selectedDashboard = baseline.screenSet?.selectedDashboardId ?? baseline.activeStoredRevision?.dashboardId
                    try session.prepareAndCommit(screens: inputs, selected: selectedDashboard.flatMap { entryIDs[$0] }, owner: owner,
                        profile: profile, profileID: profileID, operationID: operationID, grantOperationID: grantOperationID,
                        generationID: generationID, grantRevisionID: grantRevisionID, legacyGrantSet: baseline.screenSet?.grantSet,
                        validateOriginal: { guard store.load() == baseline else { throw ConnectionFailure.validationFailed } })
                    return
                }
                let screen = screens[index], id = screen.revision.dashboardId
                let files = try store.loadPackageFiles(directory: screen.packageDirectory)
                guard let manifest = files.first(where: { $0.path == "manifest.json" }),
                    Set(files.map(\.path)).count == files.count else { throw ConnectionFailure.validationFailed }
                try homeAssistantVault.withMigrationConfiguration(owner: pin, dashboardId: id, revision: screen.revision.revision,
                    grantSet: baseline.screenSet?.grantSet) { home, reads in
                    try genericConnectionVault.withMigrationConfiguration(owner: pin, dashboardId: id, revision: screen.revision.revision) { generic in
                        inputs.append(.init(entryID: entryIDs[id]!, packageOperationID: packageOperationIDs[id]!,
                            displayName: screen.name, revision: screen.revision, manifest: manifest.data,
                            files: Dictionary(uniqueKeysWithValues: files.filter { $0.path != "manifest.json" }.map { ($0.path, $0.data) }),
                            homeAssistant: home, generic: generic, publicReads: reads))
                        try consume(index + 1)
                    }
                }
            }
            try consume(0)
        }
    }

    /// The state-file replacement is the commit point; an IO failure leaves authority and content intact.
    private func updateLocalContent(disconnect: Bool, removing ids: Set<String>?) throws {
        try managementTransaction {
            try management.acceptCommandIntentUnderAuthority()
            var nextRuntime = runtime
            var nextSet = screenSet
            var nextStored = activeStoredRevision
            nextRuntime.stagedRevision = nil
            if disconnect { nextRuntime.pairing = DevicePairingState() }
            if var set = nextSet {
                set.screens.removeAll { ids == nil || ids!.contains($0.revision.dashboardId) }
                if set.screens.isEmpty { nextSet = nil; nextStored = nil }
                else {
                    if !set.screens.contains(where: { $0.revision.dashboardId == set.selectedDashboardId }) {
                        set.selectedDashboardId = set.screens[0].revision.dashboardId
                    }
                    let selected = set.screens.first { $0.revision.dashboardId == set.selectedDashboardId }!
                    nextStored = selected.revision
                    nextRuntime.lastDeployment = selected.deployment
                    nextSet = set
                }
            } else if ids == nil || ids!.contains(nextStored?.dashboardId ?? "") { nextStored = nil }
            nextRuntime.activeRevision = nextStored?.revision
            if nextStored == nil { nextRuntime.lastDeployment = nil }
            var state = DevicePersistedState(runtime: nextRuntime, activeStoredRevision: nextStored)
            state.screenSet = nextSet
            state.settings = settings
            state.contentOwner = contentOwner
            try store?.save(state)
            runtime = nextRuntime
            screenSet = nextSet
            activeStoredRevision = nextStored
            contentOwner = state.contentOwner
            authorityGeneration = UUID()
            genericConnectionGeneration = UUID()
            clearPublicSession()
            if disconnect {
                managementGeneration = UUID()
                completedPairingSessionNonceHex = nil
                clearPendingPairingLocked()
                pinnedController = nil
                deviceConfirmed = false
            }
            let retained = Set(nextSet?.screens.map { $0.revision.dashboardId } ?? [])
            screenPackages = screenPackages.filter { retained.contains($0.key) }
            if let set = nextSet { activateSelectionLocked(set.selectedDashboardId) }
            else if nextStored == nil { activePackage = nil }
            let service = homeAssistantRuntime
            afterCommitLocked { Task { await service.cancelPending() } }
            let directories = nextSet?.screens.map { $0.packageDirectory } ?? (nextStored == nil ? [] : ["package"])
            store?.prunePackageGenerations(keeping: Set(directories))
            notifyLocked()
        }
    }

    public func stop() {
        lock.lock()
        let current = listener; let pending = pendingListener; let links = Array(connections.values)
        listener = nil; pendingListener = nil; connections = [:]; port = 0; listenerAttempt = UUID()
        lock.unlock()
        current?.cancel(); pending?.cancel()
        for connection in links { connection.cancel() }
    }

    public var advertisedDevice: AdvertisedDevice {
        lock.lock()
        let value = runtime.advertisement
        lock.unlock()
        return value
    }

    /// A snapshot is durable desired configuration. Runtime acknowledgement is
    /// separate, so a sleeping renderer is never reported as already applied.
    public var settingsSnapshot: DeviceSettingsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    @discardableResult
    public func updateSettingsLocally(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot {
        return try managementTransaction {
            let saved = try updateSettingsLocked(update)
            notifyLocked()
            return saved
        }
    }

    /// The UI/runtime calls this only after consuming this exact revision.
    /// A late acknowledgement can never mark a newer edit as applied.
    public func markSettingsApplied(revision: String) throws {
        try managementTransaction {
            guard settings.revision == revision, settings.appliedRevision != revision else { return }
            settings.appliedRevision = revision
            notifyLocked()
        }
    }

    /// Suspension or runtime failure clears the live acknowledgement without
    /// changing the persisted desired configuration or its conflict token.
    public func markSettingsUnapplied(revision: String) throws {
        try managementTransaction {
            guard settings.revision == revision, settings.appliedRevision != nil else { return }
            settings.appliedRevision = nil
            notifyLocked()
        }
    }

    private func updateSettingsLocked(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot {
        let next = try settings.replacing(with: update)
        try validateDashboardSettings(next.value)
        if let store {
            var state = DevicePersistedState(runtime: runtime, activeStoredRevision: activeStoredRevision)
            state.screenSet = screenSet
            state.settings = next
            state.contentOwner = contentOwner
            do { try store.save(state) }
            catch { throw DeviceSettingsFailure.persistenceFailed }
        }
        settings = next
        return next
    }

    private func validateDashboardSettings(_ value: DeviceSettings) throws {
        // Validate edits against installed author declarations. Unchanged dormant
        // preferences may survive a dashboard revision that removed their target;
        // runtime reconciliation ignores those values without blocking brightness edits.
        let ids = Set(value.startingPageByDashboard.keys).union(value.eventRuleOverrides.keys)
        for id in ids {
            let changedPage = value.startingPageByDashboard[id] != settings.value.startingPageByDashboard[id]
                ? value.startingPageByDashboard[id] : nil
            let changedRules = (value.eventRuleOverrides[id] ?? [:]).filter {
                settings.value.eventRuleOverrides[id]?[$0.key] != $0.value
            }
            guard changedPage != nil || !changedRules.isEmpty else { continue }
            let package = screenPackages[id] ?? (activeStoredRevision?.dashboardId == id ? activePackage : nil)
            guard let package, let data = package.assets["manifest.json"]?.data,
                  let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: data), manifest.dashboardId == id else {
                throw DeviceSettingsFailure.invalidSettings
            }
            do {
                try EventNavigationEngine.validate(manifest: manifest,
                    startingPageId: changedPage, overrides: changedRules)
            } catch { throw DeviceSettingsFailure.invalidSettings }
        }
    }

    // MARK: Persistence

    public var installedManifests: [DashboardManifest] {
        var packages = Array(screenPackages.values)
        if let activePackage { packages.append(activePackage) }
        var seen = Set<String>()
        return packages.compactMap { package in
            guard let data = package.assets["manifest.json"]?.data,
                  let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: data),
                  seen.insert(manifest.dashboardId).inserted else { return nil }
            return manifest
        }
    }

    private func restoreFromStore() {
        guard let store, let state = store.load() else { return }
        runtime.restore(state)
        let restoredOwner = state.contentOwner ?? state.owner
        contentOwner = restoredOwner?.isWellFormed == true && restoredOwner?.role == .controller ? restoredOwner : nil
        if let saved = state.settings {
            settings = saved
            settings.appliedRevision = nil
        }
        pinnedController = state.owner?.publicKey
        activeStoredRevision = state.activeStoredRevision
        if let installed = state.screenSet {
            var packages: [String: PackageAssetStore] = [:]
            for screen in installed.screens {
                guard let files = try? store.loadPackageFiles(directory: screen.packageDirectory), !files.isEmpty else { return }
                packages[screen.revision.dashboardId] = packageStore(files)
            }
            screenSet = installed
            screenPackages = packages
            activateSelectionLocked(installed.selectedDashboardId)
            return
        }
        if runtime.activeRevision != nil,
           let files = try? store.loadPackageFiles(), files.isEmpty == false
        {
            var assets: [String: PackageAsset] = [:]
            for file in files {
                guard let path = try? PackageAssetStore.hostRelativePath(file.path) else { continue }
                assets[path] = PackageAsset(path: path, data: file.data, mime: PackageAssetStore.mime(for: path))
            }
            activePackage = PackageAssetStore(assets: assets)
        }
    }

    /// Caller holds `lock`.
    private func persist() {
        guard let store else { return }
        var state = DevicePersistedState(runtime: runtime, activeStoredRevision: activeStoredRevision)
        state.screenSet = screenSet
        state.settings = settings
        state.contentOwner = contentOwner
        try? store.save(state)
    }

    // MARK: Connections

    private func ownerPin() -> [UInt8]? {
        lock.lock()
        let pin = pinnedController ?? runtime.pairing.owner?.publicKey
        lock.unlock()
        return pin
    }

    /// TXT carries the protocol version, the opaque id, and a display name
    /// (`n`). The name is untrusted and only labels the device on the Mac.
    private func advertiseBonjour(on listener: NWListener) {
        var txt = [
            "v": "\(DiscoveryService.protocolMajor)",
            "id": runtime.profile.deviceId
        ]
        if let name = DeviceDisplayName.sanitize(runtime.profile.name) {
            txt["n"] = name
        }
        listener.service = NWListener.Service(
            name: runtime.profile.deviceId,
            type: DiscoveryService.type,
            txtRecord: NWTXTRecord(txt)
        )
    }

    private func accept(_ connection: NWConnection, listenerAttempt attempt: UUID) {
        let identifier = ObjectIdentifier(connection)
        defer {
            lock.lock(); connections.removeValue(forKey: identifier); lock.unlock()
            connection.cancel()
        }
        do {
            let connectionGeneration = try managementTransaction {
                guard listenerAttempt == attempt, listener != nil else { throw TransferFailure.interrupted }
                connections[identifier] = connection
                return managementGeneration
            }
            guard startAndWaitReady(connection) else { return }
            observeManagementBoundary(.handshakeReady)
            try managementTransaction {
                guard listenerAttempt == attempt, connections[identifier] != nil else { throw TransferFailure.interrupted }
            }
            let peerPin = LANChannel.observedPeerPin(connection)
            let link = LANLink(connection: connection, queue: queue)
            serve(link, peerPin: peerPin, listenerAttempt: attempt, managementGeneration: connectionGeneration)
        } catch { return }
    }

    /// Installs the state handler before `start` so a fast handshake cannot be
    /// missed. Returns false when the handshake did not complete in time; a
    /// half-open peer is dropped rather than parked on a worker thread.
    private func startAndWaitReady(_ connection: NWConnection) -> Bool {
        let done = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state { done.signal() }
            if case .failed = state { done.signal() }
            if case .cancelled = state { done.signal() }
        }
        connection.start(queue: queue)
        guard done.wait(timeout: .now() + 8) == .success else { return false }
        if case .ready = connection.state { return true }
        return false
    }

    private func connectionInventory(owner: String) throws -> DeviceConnectionInventory {
        let screens: [LANScreenSetEntry]
        if let screenSet { screens = screenSet.screens.map(\.entry) }
        else if let revision = activeStoredRevision { screens = [.init(dashboardId: revision.dashboardId, revision: revision.revision, name: "Current screen")] }
        else { screens = [] }
        var entries: [DeviceConnectionEntry] = []
        for screen in screens {
            entries += try homeAssistantVault.inventory(owner: owner, screen: screen, grantSet: screenSet?.grantSet)
            entries += try genericConnectionVault.inventory(owner: owner, screen: screen)
        }
        return .init(deviceId: runtime.profile.deviceId, entries: entries)
    }

    /// One connection, one request at a time, for as long as the peer keeps it
    /// open. Any failure closes the connection so the controller sees a dead
    /// socket rather than requests that are read and never answered.
    ///
    /// The owner (handshake pin equals the pinned owner) waits without a
    /// deadline. Everyone else counts against `maxUntrustedConnections` and
    /// idles out after `untrustedIdleTimeout`; a connection that becomes the
    /// owner mid-way (pairing just completed) leaves the untrusted pool.
    private func serve(_ link: LANLink, peerPin: [UInt8]?, listenerAttempt attempt: UUID, managementGeneration: UUID) {
        defer { link.cancel() }
        var connectionGeneration = managementGeneration
        var countedUntrusted = false
        defer { if countedUntrusted { releaseUntrustedSlot() } }
        while true {
            do {
                try managementTransaction {
                    guard listenerAttempt == attempt else { throw TransferFailure.interrupted }
                }
                let trusted = isApprovedPeer(peerPin)
                if trusted {
                    if countedUntrusted { releaseUntrustedSlot(); countedUntrusted = false }
                } else if !countedUntrusted {
                    guard acquireUntrustedSlot() else { break }
                    countedUntrusted = true
                }
                let request = try link.receiveRequest(
                    idleTimeout: trusted ? nil : untrustedIdleTimeout,
                    bodyTimeout: trusted ? requestBodyTimeout : min(requestBodyTimeout, 15),
                    maximumBytes: trusted ? LANProtocolLimits.maxMessageBytes : LANProtocolLimits.legacyMessageBytes)
                observeManagementBoundary(.requestReceived(request.method))
                let reply = handle(request, peerPin: peerPin, managementGeneration: &connectionGeneration, listenerAttempt: attempt)
                try link.send(reply)
            } catch {
                break
            }
        }
    }

    private func acquireUntrustedSlot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard untrustedConnections < maxUntrustedConnections else { return false }
        untrustedConnections += 1
        return true
    }

    private func releaseUntrustedSlot() {
        lock.lock(); defer { lock.unlock() }
        untrustedConnections = max(0, untrustedConnections - 1)
    }

    private func handle(_ request: LANEnvelope, peerPin: [UInt8]?, managementGeneration requestGeneration: inout UUID, listenerAttempt attempt: UUID) -> LANEnvelope {
        if request.method == LANMethod.cloudArchiveChunk.rawValue {
            do { return try handleCloudArchiveChunk(request, peerPin: peerPin, listenerAttempt: attempt) }
            catch { return failureReply(request, error: error) }
        }
        if request.method == LANMethod.cloudRelay.rawValue {
            do {
                let body = try LANCodec.decodePayload(LANCloudRelay.self, json: request.payloadJSON)
                guard let installation = UUID(uuidString: body.installationId), let operation = UUID(uuidString: body.operationId), let peerPin else { throw TransferFailure.validationFailed }
                let callback = try managementTransaction { () throws -> (UUID, UUID) -> Void in
                    try requireOwner(peerPin)
                    guard listenerAttempt == attempt, let association = unifiedLocalAssociation,
                          association.installationID == installation, let callback = onCloudRelayHint else { throw TransferFailure.validationFailed }
                    return callback
                }
                callback(installation, operation)
                return ok(request, payload: LANCloudRelayReceipt(accepted: true, installationId: installation.uuidString.lowercased(), operationId: operation.uuidString.lowercased()))
            } catch { return failureReply(request, error: error) }
        }
        if request.method == LANMethod.queryActive.rawValue {
            do {
                let common = try managementTransaction { management.isConcurrent && unifiedLocalSession != nil }
                if common { return try handleUnifiedStatus(request, peerPin: peerPin, listenerAttempt: attempt) }
            } catch { return failureReply(request, error: error) }
        }
        if request.method == LANMethod.screenInstall.rawValue {
            do { return try handleUnifiedLocalInstall(request, peerPin: peerPin, listenerAttempt: attempt) }
            catch { return failureReply(request, error: error) }
        }
        if request.method == LANMethod.screenSelect.rawValue || request.method == LANMethod.screenRemove.rawValue {
            do { return try handleUnifiedLocalChange(request, peerPin: peerPin, listenerAttempt: attempt) }
            catch { return failureReply(request, error: error) }
        }
        if request.method == LANMethod.pairConfirm.rawValue {
            observeManagementBoundary(.pairingWaitStarted)
            _ = waitUntilDeviceConfirmed(timeout: 60)
        }
        do { return try managementTransaction {
            guard listenerAttempt == attempt, listener != nil else { throw TransferFailure.interrupted }
            return handleLocked(request, peerPin: peerPin, managementGeneration: &requestGeneration)
        } }
        catch { return failureReply(request, error: error) }
    }

    private func failureReply(_ request: LANEnvelope, error: Error) -> LANEnvelope {
        LANEnvelope(requestId: request.requestId, method: request.method, ok: false,
            error: (error as? DeviceSettingsFailure)?.rawValue ?? (error as? PairingFailure)?.rawValue
                ?? (error as? TransferFailure)?.rawValue ?? (error as? ConnectionFailure)?.rawValue
                ?? (error is DeviceCommandIntentCoordinator.Failure ? "needsReview" : nil)
                ?? (error is DeviceManagementAuthority.Failure ? TransferFailure.notPaired.rawValue : "failed"))
    }

    /// Caller holds authority and server locks.
    private func handleLocked(_ request: LANEnvelope, peerPin: [UInt8]?, managementGeneration requestGeneration: inout UUID) -> LANEnvelope {
        do {
            guard request.protocolVersion == LANProtocolLimits.version else {
                throw TransferFailure.validationFailed
            }
            let method = LANMethod(rawValue: request.method)
            if method != .hello && method != .pairBegin && method != .pairConfirm {
                guard requestGeneration == managementGeneration else { throw TransferFailure.notPaired }
            }
            if management.isConcurrent {
                let allowed: [LANMethod] = [.hello, .pairBegin, .pairConfirm, .pairRevoke, .queryActive, .settingsGet, .settingsUpdate]
                guard let method, allowed.contains(method) else { throw TransferFailure.validationFailed }
            }
            switch method {
            case .hello:
                let hello = LANHello(
                    role: .device,
                    deviceId: runtime.profile.deviceId,
                    pinHex: PeerPin.hex(identity.pin),
                    name: runtime.profile.name,
                    capabilities: ["apple-maps-v1", "apple-maps-interactive-v1", "home-assistant-http-v1", "home-assistant-services-v1", "camera-playback-v1", "screen-set-v1", "public-read-http-v1", "public-read-dynamic-path-v1", "device-settings-v1", "generic-connections-v1", "connection-inventory-v1", "home-assistant-temporary-activation-v1", "multiple-local-controllers-v1"] + (unifiedLocalSession == nil ? [] : ["unified-local-screen-control-v1"]) + (unifiedLocalSession != nil && prepareIncomingLocalScreens != nil ? ["unified-local-screen-install-v1"] : []) + (unifiedLocalSession != nil && onCloudRelayHint != nil ? ["cloud-command-relay-v1"] : []) + (unifiedLocalSession != nil && onCloudArchiveAdmission != nil && onCloudArchiveReceived != nil ? ["cloud-archive-relay-v1"] : []),
                    maxTransferBytes: LANProtocolLimits.maxMessageBytes,
                    profile: runtime.profile
                )
                return ok(request, payload: hello)
            case .settingsGet:
                try requireOwner(peerPin)
                return ok(request, payload: settings)
            case .settingsUpdate:
                try requireOwner(peerPin)
                let update = try LANCodec.decodePayload(DeviceSettingsUpdate.self, json: request.payloadJSON)
                let saved = try updateSettingsLocked(update)
                notifyLocked()
                return ok(request, payload: saved)
            case .pairBegin:
                let body = try LANCodec.decodePayload(LANPairBegin.self, json: request.payloadJSON)
                let controllerPin = try authenticatedPeer(peerPin, claimedHex: body.controllerPinHex)
                guard let nonce = PeerPin.parseHex(body.sessionNonceHex),
                      nonce.count == PairingLimits.sessionNonceByteCount
                else {
                    throw TransferFailure.validationFailed
                }
                let controller = PairingIdentity(role: .controller, publicKey: controllerPin)
                let transcript = PairingTranscript(
                    devicePublicKey: identity.pin,
                    controllerPublicKey: controllerPin,
                    sessionNonce: nonce
                )
                let code = expectedCode(for: transcript)
                try runtime.beginPairing(
                    transcript: transcript,
                    expectedCode: code,
                    candidateOwner: controller,
                    clock: clock
                )
                pairingCode = code
                completedPairingSessionNonceHex = nil
                deviceConfirmed = false
                schedulePairingExpiryLocked()
                notifyLocked()
                return ok(
                    request,
                    payload: LANPairBeginResult(code: code, devicePinHex: PeerPin.hex(identity.pin))
                )
            case .pairConfirm:
                guard deviceConfirmed else { throw TransferFailure.interrupted }
                let body = try LANCodec.decodePayload(LANPairConfirm.self, json: request.payloadJSON)
                let controllerPin = try authenticatedPeer(peerPin, claimedHex: body.controllerPinHex)
                let controller = PairingIdentity(role: .controller, publicKey: controllerPin)
                var confirmedRuntime = runtime
                do {
                    try confirmedRuntime.confirmPairing(code: body.code, presentedOwner: controller, clock: clock)
                } catch {
                    // Validation may increment the transient wrong-code counter; ownership never commits here.
                    runtime.pairing.session = confirmedRuntime.pairing.session
                    throw error
                }
                var confirmedState = DevicePersistedState(runtime: confirmedRuntime, activeStoredRevision: activeStoredRevision)
                confirmedState.screenSet = screenSet
                confirmedState.settings = settings
                confirmedState.contentOwner = contentOwner
                try store?.save(confirmedState)
                completedPairingSessionNonceHex = runtime.pairing.session.map { PeerPin.hex($0.transcript.sessionNonce) }
                runtime = confirmedRuntime
                // Approving another peer does not retire existing approved
                // connections or content capabilities. Every request rechecks trust.
                pinnedController = runtime.pairing.owner?.publicKey
                // The session has done its job. Keeping it would leave
                // `runtime.pairingCode` set and the code view on screen.
                clearPendingPairingLocked()
                persist()
                notifyLocked()
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision, screens: screenSet?.screens.map(\.entry), selectedDashboardId: screenSet?.selectedDashboardId, temporaryActivation: temporaryActivationStatus, controllerApproved: true, localControllerPinHex: peerPin.map(PeerPin.hex), approvedControllerCount: runtime.pairing.approvedControllers.count))
            case .pairRevoke:
                try requireOwner(peerPin)
                guard let peerPin else { throw TransferFailure.notPaired }
                try revokeControllerLocked(PairingIdentity(role: .controller, publicKey: peerPin))
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision, screens: screenSet?.screens.map(\.entry), selectedDashboardId: screenSet?.selectedDashboardId, controllerApproved: false, localControllerPinHex: PeerPin.hex(peerPin), approvedControllerCount: runtime.pairing.approvedControllers.count))
            case .deploySet:
                try requireOwner(peerPin)
                let body = try LANCodec.decodePayload(LANScreenSetDeployBody.self, json: request.payloadJSON)
                return ok(request, payload: try installScreenSetLocked(body, owner: PeerPin.hex(peerPin!)))
            case .deploy:
                try requireOwner(peerPin)
                let body = try LANCodec.decodePayload(LANDeployBody.self, json: request.payloadJSON)
                // Idempotent on deploymentId: a retry answers with the recorded
                // outcome and leaves the installed package alone. The same id
                // with a different revision is a protocol error, never a
                // silent replacement of the active screen.
                if let last = runtime.lastDeployment, last.deploymentId == body.deployment.deploymentId {
                    guard last.revision == body.revision.revision, last.dashboardId == body.revision.dashboardId else {
                        throw TransferFailure.validationFailed
                    }
                    return ok(request, payload: last)
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let digest = PeerPin.hex(PeerPin.sha256(try encoder.encode(body)))
                try management.acceptDeploymentUnderAuthority(key: PeerPin.hex(peerPin!) + ":" + body.deployment.deploymentId, digest: digest)
                let staged = try stageFiles(body.files)
                guard staged["index.html"] != nil else { throw TransferFailure.validationFailed }
                let stagedDirectory = try store?.stagePackage(
                    staged.values.sorted { $0.path < $1.path }.map { (path: $0.path, data: $0.data) }
                )
                let before = runtime
                var outcome = try runtime.receiveDeployment(body.deployment, revision: body.revision)
                if outcome.phase == .active {
                    if let store, let stagedDirectory {
                        do {
                            try store.activatePackage(staged: stagedDirectory)
                        } catch {
                            store.discardStaged(stagedDirectory)
                            runtime = before
                            outcome.phase = .failed
                            outcome.error = TransferFailure.interrupted.rawValue
                            runtime.lastDeployment = outcome
                            persist()
                            return ok(request, payload: outcome)
                        }
                    }
                    // Exact-revision binding denies superseded grants immediately.
                    // Retire their secrets as well; a failed deployment never reaches here.
                    if before.activeRevision != runtime.activeRevision || activeStoredRevision?.dashboardId != body.revision.dashboardId {
                        clearPublicSession()
                        try? homeAssistantVault.revoke()
                        try? homeAssistantVault.revokePublic()
                        let service = homeAssistantRuntime
                        afterCommitLocked { Task { await service.cancelPending() } }
                    }
                    screenSet = nil
                    screenPackages = [:]
                    activePackage = PackageAssetStore(assets: staged)
                    activeStoredRevision = body.revision
                    contentOwner = contentOwner ?? runtime.pairing.owner
                    authorityGeneration = UUID()
                    genericConnectionGeneration = UUID()
                    persist()
                    notifyLocked()
                } else {
                    if let store, let stagedDirectory {
                        store.discardStaged(stagedDirectory)
                    }
                    // The failed record persists so a same-id retry answers the
                    // same way after a relaunch; the active package is untouched.
                    persist()
                }
                return ok(request, payload: outcome)
            case .connectionsInventory:
                try requireOwner(peerPin)
                return ok(request, payload: try connectionInventory(owner: localContentOwnerPin()))
            case .connectionsUpdateHome:
                try requireOwner(peerPin)
                let body = try LANCodec.decodePayload(DeviceHomeAssistantUpdate.self, json: request.payloadJSON)
                let owner = try localContentOwnerPin()
                let inventory = try connectionInventory(owner: owner)
                guard body.entries.allSatisfy({ inventory.entries.contains($0) && $0.kind == "Service integration" }) else { throw ConnectionFailure.permissionRequired }
                try homeAssistantVault.update(body, owner: owner, grantSet: screenSet?.grantSet)
                let service = homeAssistantRuntime
                afterCommitLocked { Task { await service.cancelPending() } }
                notifyLocked()
                return ok(request, payload: try connectionInventory(owner: owner))
            case .connectionsProvision:
                try requireOwner(peerPin)
                let body = try LANCodec.decodePayload(ConnectionProvisioning.self, json: request.payloadJSON)
                guard body.revision == runtime.activeRevision,
                      body.dashboardId == activeStoredRevision?.dashboardId else { throw TransferFailure.validationFailed }
                try genericConnectionVault.provision(body, owner: localContentOwnerPin())
                genericConnectionGeneration = UUID()
                notifyLocked()
                return ok(request, payload: ConnectionProvisioningReceipt(deviceId: runtime.profile.deviceId,
                    dashboardId: body.dashboardId, revision: body.revision, provisioningId: body.provisioningId))
            case .connectionsRevoke:
                try requireOwner(peerPin)
                try genericConnectionVault.revoke()
                genericConnectionGeneration = UUID()
                notifyLocked()
                return ok(request, payload: ["revoked": true])
            case .homeAssistantProvision:
                try requireOwner(peerPin)
                let body = try LANCodec.decodePayload(HomeAssistantProvisioning.self, json: request.payloadJSON)
                guard body.revision == runtime.activeRevision,
                      body.dashboardId == activeStoredRevision?.dashboardId else { throw TransferFailure.validationFailed }
                if let generation = screenSet?.grantSet {
                    try homeAssistantVault.provisionInGeneration(body, owner: try localContentOwnerPin(), generation: generation)
                } else {
                    try homeAssistantVault.provision(body, owner: localContentOwnerPin())
                }
                notifyLocked()
                return ok(request, payload: HomeAssistantProvisioningReceipt(
                    deviceId: runtime.profile.deviceId, dashboardId: body.dashboardId, revision: body.revision,
                    connectionId: body.connectionId, provisioningId: body.provisioningId))
            case .homeAssistantRevoke:
                try requireOwner(peerPin)
                try homeAssistantVault.revoke()
                let service = homeAssistantRuntime
                afterCommitLocked { Task { await service.cancelPending() } }
                notifyLocked()
                return ok(request, payload: ["revoked": true])
            case .screenSelect, .screenRemove, .screenInstall, .cloudRelay, .cloudArchiveChunk:
                throw TransferFailure.validationFailed
            case .queryActive:
                try requireOwner(peerPin)
                if management.isConcurrent, let association = unifiedLocalAssociation, let peerPin { return ok(request, payload: unifiedControllerStatus(association, peerPin: peerPin)) }
                let cloudID = try management.qualifiedCloudInstallationIDUnderAuthority()?.uuidString.lowercased()
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision, screens: screenSet?.screens.map(\.entry), selectedDashboardId: screenSet?.selectedDashboardId, temporaryActivation: temporaryActivationStatus, cloudInstallationId: cloudID, controllerApproved: true, localControllerPinHex: peerPin.map(PeerPin.hex), approvedControllerCount: runtime.pairing.approvedControllers.count))
            case .none:
                throw TransferFailure.validationFailed
            }
        } catch {
            return LANEnvelope(
                requestId: request.requestId,
                method: request.method,
                ok: false,
                error: (error as? DeviceSettingsFailure)?.rawValue
                    ?? (error as? PairingFailure)?.rawValue
                    ?? (error as? TransferFailure)?.rawValue
                    ?? (error as? ConnectionFailure)?.rawValue
                    ?? (error is DeviceStateStoreError ? TransferFailure.interrupted.rawValue : nil)
                    ?? (error is DeviceCommandIntentCoordinator.Failure ? "needsReview" : nil)
                    ?? "failed"
            )
        }
    }

    /// Selection changes only after persistence succeeds; swiping never changes installed membership.
    public func selectScreen(_ dashboardId: String) throws {
        try managementTransaction {
            try management.acceptCommandIntentUnderAuthority()
            try selectScreenLocked(dashboardId)
        }
    }

    /// Checkpoint writes and selection share the same captured admission and declaration scope.
    func commitTemporaryActivationSelection(_ selection: String?, expectedScope: HomeAssistantDeviceRuntime.Scope,
        beforeSelection: () throws -> Void, afterSelection: () throws -> Void) throws -> Bool {
        try managementTransaction {
            guard temporaryActivationScopeLocked() == expectedScope else { throw ConnectionFailure.permissionRequired }
            try beforeSelection()
            let exists = selection.map { id in screenSet?.screens.contains { $0.revision.dashboardId == id } == true } ?? false
            if let selection, exists { try selectScreenLocked(selection) }
            try afterSelection()
            return exists
        }
    }

    private func selectScreenLocked(_ dashboardId: String) throws {
        guard var next = screenSet, next.screens.contains(where: { $0.revision.dashboardId == dashboardId }) else { return }
        guard next.selectedDashboardId != dashboardId else { return }
        next.selectedDashboardId = dashboardId
        if let store {
            var state = DevicePersistedState(runtime: runtime, activeStoredRevision: activeStoredRevision)
            state.screenSet = next
            state.settings = settings
            state.contentOwner = contentOwner
            if let screen = next.screens.first(where: { $0.revision.dashboardId == dashboardId }) {
                state.activeRevision = screen.revision.revision
                state.activeStoredRevision = screen.revision
                state.lastDeployment = screen.deployment
            }
            try store.save(state)
        }
        screenSet = next
        clearPublicSession()
        activateSelectionLocked(dashboardId)
        let service = homeAssistantRuntime
        afterCommitLocked { Task { await service.cancelPending() } }
        notifyLocked()
    }

    private func activateSelectionLocked(_ dashboardId: String) {
        guard let screen = screenSet?.screens.first(where: { $0.revision.dashboardId == dashboardId }) else { return }
        activeStoredRevision = screen.revision
        activePackage = screenPackages[dashboardId]
        runtime.activeRevision = screen.revision.revision
        runtime.lastDeployment = screen.deployment
        runtime.profile.apply(orientation: screen.revision.orientation)
    }

    private func packageStore(_ files: [(path: String, data: Data)]) -> PackageAssetStore {
        var assets: [String: PackageAsset] = [:]
        for file in files {
            guard let path = try? PackageAssetStore.hostRelativePath(file.path) else { continue }
            assets[path] = PackageAsset(path: path, data: file.data, mime: PackageAssetStore.mime(for: path))
        }
        return PackageAssetStore(assets: assets)
    }

    /// Immutable package directories and grant generations are prepared first. Replacing the
    /// device-state file is the sole commit point, so interrupted preparation is unreachable.
    private func installScreenSetLocked(_ body: LANScreenSetDeployBody, owner: String) throws -> LANScreenSetReceipt {
        try body.validate()
        guard body.deviceId == runtime.profile.deviceId else { throw TransferFailure.targetMismatch }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = PeerPin.hex(PeerPin.sha256(try encoder.encode(body)))
        if let current = screenSet, current.deploymentId == body.deploymentId {
            guard current.contentDigest == digest else { throw TransferFailure.validationFailed }
            return .init(deploymentId: current.deploymentId, deviceId: body.deviceId,
                         screens: current.screens.map(\.entry), selectedDashboardId: current.deployedSelectedDashboardId)
        }
        try management.acceptDeploymentUnderAuthority(key: owner + ":" + body.deploymentId, digest: digest)
        let generation = UUID().uuidString
        var directories: [URL] = []
        var screens: [DeviceInstalledScreen] = []
        var packages: [String: PackageAssetStore] = [:]
        var committed = false
        defer {
            if !committed {
                for directory in directories { store?.discardStaged(directory) }
                try? homeAssistantVault.removeGeneration(generation)
                try? homeAssistantVault.prunePublic(removing: generation)
            }
        }
        for item in body.screens {
            var candidate = runtime
            candidate.lastDeployment = nil
            let outcome = try candidate.receiveDeployment(item.deployment.deployment, revision: item.deployment.revision)
            guard outcome.phase == .active else { throw TransferFailure.targetMismatch }
            let assets = try stageFiles(item.deployment.files)
            guard assets["index.html"] != nil else { throw TransferFailure.validationFailed }
            if let manifestData = assets["manifest.json"]?.data {
                let manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestData)
                try manifest.deviceBehavior?.validate()
                guard manifest.dashboardId == item.deployment.revision.dashboardId,
                      manifest.revision == item.deployment.revision.revision else { throw TransferFailure.validationFailed }
            }
            if let reads = item.publicReads {
                guard let manifestData = assets["manifest.json"]?.data else { throw TransferFailure.validationFailed }
                let manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestData)
                try PackageValidator.validate(manifest)
                let expected = try PublicReadProvisioning(manifest: manifest)
                guard reads.dashboardId == expected.dashboardId, reads.revision == expected.revision,
                      reads.connections.allSatisfy({ expected.connections.contains($0) }) else { throw TransferFailure.validationFailed }
            }
            let files = assets.values.map { (path: $0.path, data: $0.data) }
            let directory = try store?.stagePackage(files)
            if let directory { directories.append(directory) }
            screens.append(.init(name: item.name, revision: item.deployment.revision, deployment: outcome,
                                 packageDirectory: directory?.lastPathComponent ?? "package"))
            packages[item.deployment.revision.dashboardId] = PackageAssetStore(assets: assets)
        }
        let grantOwner = try localContentOwnerPin()
        try homeAssistantVault.stage(body.screens.compactMap(\.homeAssistant), owner: grantOwner, generation: generation)
        try homeAssistantVault.stagePublic(body.screens.compactMap(\.publicReads), owner: grantOwner, generation: generation)
        let installed = DeviceInstalledScreenSet(deploymentId: body.deploymentId, contentDigest: digest,
            grantSet: generation, screens: screens, selectedDashboardId: body.selectedDashboardId)
        guard let selected = screens.first(where: { $0.revision.dashboardId == body.selectedDashboardId }) else {
            throw TransferFailure.validationFailed
        }
        var state = DevicePersistedState(owner: runtime.pairing.owner, activeRevision: selected.revision.revision,
            activeStoredRevision: selected.revision, lastDeployment: selected.deployment)
        state.approvedControllers = runtime.pairing.approvedControllers
        state.screenSet = installed
        state.settings = settings
        state.contentOwner = contentOwner ?? runtime.pairing.owner
        try store?.save(state)
        contentOwner = contentOwner ?? runtime.pairing.owner
        authorityGeneration = UUID()
        genericConnectionGeneration = UUID()
        committed = true
        clearPublicSession()
        screenSet = installed
        screenPackages = packages
        activateSelectionLocked(body.selectedDashboardId)
        let service = homeAssistantRuntime
        afterCommitLocked { Task { await service.cancelPending() } }
        // Cleanup after the commit cannot invalidate the newly selected generation.
        try? homeAssistantVault.retainGeneration(generation)
        try? homeAssistantVault.prunePublic(keeping: generation)
        store?.prunePackageGenerations(keeping: Set(screens.map(\.packageDirectory)))
        notifyLocked()
        return .init(deploymentId: body.deploymentId, deviceId: body.deviceId,
                     screens: screens.map(\.entry), selectedDashboardId: body.selectedDashboardId)
    }

    /// The pin a message claims must be the pin that completed this
    /// connection's handshake. Returns the authenticated pin.
    private func authenticatedPeer(_ peerPin: [UInt8]?, claimedHex: String) throws -> [UInt8] {
        guard let peerPin, peerPin.count == PairingLimits.identityByteCount else {
            throw TransferFailure.validationFailed
        }
        guard PeerPin.matches(expected: peerPin, presentedHex: claimedHex) else {
            throw PairingFailure.identityChanged
        }
        return peerPin
    }

    /// Deploy and active-revision queries are owner-only, checked against the
    /// handshake pin even though TLS already rejects other peers.
    /// Control approval never retargets immutable content/grant-root ownership.
    private func localContentOwnerPin() throws -> String {
        guard let owner = contentOwner ?? runtime.pairing.owner, owner.isWellFormed, owner.role == .controller else { throw TransferFailure.notPaired }
        return PeerPin.hex(owner.publicKey)
    }

    private func requireOwner(_ peerPin: [UInt8]?) throws {
        guard let peerPin, runtime.pairing.isApproved(PairingIdentity(role: .controller, publicKey: peerPin)) else {
            throw TransferFailure.notPaired
        }
    }

    @_spi(NativeInstallation) public func attachUnifiedLocalSession(_ session: DeviceUnifiedInventorySession) throws {
        let association = try session.validatedAssociation()
        try managementTransaction {
            guard management.isConcurrent, management.commonRootID == association.commonRootID,
                  try management.qualifiedCloudInstallationIDUnderAuthority() == association.installationID else { throw DeviceManagementAuthority.Failure.staleLease }
            unifiedLocalSession = session; unifiedLocalAssociation = association
        }
    }

    private func handleUnifiedStatus(_ request: LANEnvelope, peerPin: [UInt8]?, listenerAttempt attempt: UUID) throws -> LANEnvelope {
        guard let peerPin else { throw TransferFailure.notPaired }
        let session = try managementTransaction { () throws -> DeviceUnifiedInventorySession in
            guard listenerAttempt == attempt, let session = unifiedLocalSession else { throw DeviceManagementAuthority.Failure.staleLease }
            try requireOwner(peerPin); return session
        }
        let association = try session.validatedAssociation()
        let mounted = try session.mountedAssociation()
        let mountState = try session.mountStateAssociation()
        return try managementTransaction {
            guard listenerAttempt == attempt, unifiedLocalSession === session else { throw DeviceManagementAuthority.Failure.staleLease }
            try requireOwner(peerPin); unifiedLocalAssociation = association; unifiedMountedAssociation = mounted; unifiedMountStateAssociation = mountState
            return ok(request, payload: unifiedControllerStatus(association, peerPin: peerPin))
        }
    }

    private func unifiedControllerStatus(_ association: DeviceUnifiedInventoryAssociation, peerPin: [UInt8]) -> LANActiveQuery {
        let selected = association.entries.first { $0.entryID == association.configuredEntryID }
        let mountedCurrent = unifiedMountedAssociation?.currentlyConfigured == true
            && unifiedMountedAssociation?.generationID == association.generationID
            && unifiedMountedAssociation?.entryID == association.configuredEntryID
        let pendingState = unifiedMountStateAssociation?.generationID == association.generationID ? unifiedMountStateAssociation : nil
        return LANActiveQuery(revision: selected?.revision, screens: association.entries.map { .init(dashboardId: $0.dashboardID, revision: $0.revision, name: $0.displayName) }, selectedDashboardId: selected?.dashboardID, cloudInstallationId: association.installationID.uuidString.lowercased(), controllerApproved: true, localControllerPinHex: PeerPin.hex(peerPin), approvedControllerCount: runtime.pairing.approvedControllers.count, stateGenerationId: association.generationID.uuidString.lowercased(), commonEntries: association.entries.map { .init(entryId: $0.entryID.uuidString.lowercased(), dashboardId: $0.dashboardID, revision: $0.revision, name: $0.displayName, origin: $0.provenance) }, configuredEntryId: association.configuredEntryID?.uuidString.lowercased(), activeGenerationId: mountedCurrent ? unifiedMountedAssociation?.generationID.uuidString.lowercased() : nil, activeEntryId: mountedCurrent ? unifiedMountedAssociation?.entryID?.uuidString.lowercased() : nil, lastSuccessfulEntryId: unifiedMountedAssociation?.entryID?.uuidString.lowercased(), mountState: mountedCurrent ? "applied" : (pendingState?.state == "failed" ? "failed" : (pendingState?.state == "preparing" ? "preparing" : (association.configuredEntryID == nil ? "none" : "requested"))), mountFailureCode: pendingState?.failureCode)
    }

    private func handleUnifiedLocalChange(_ request: LANEnvelope, peerPin: [UInt8]?, listenerAttempt attempt: UUID) throws -> LANEnvelope {
        guard let peerPin else { throw TransferFailure.notPaired }
        let session = try managementTransaction { () throws -> DeviceUnifiedInventorySession in
            guard listenerAttempt == attempt, management.isConcurrent, let session = unifiedLocalSession else { throw DeviceManagementAuthority.Failure.staleLease }
            try requireOwner(peerPin); return session
        }
        let before = try session.validatedAssociation()
        let body = try LANCodec.decodePayload(LANScreenManagementChange.self, json: request.payloadJSON)
        guard let operationID = UUID(uuidString: body.operationId), let expected = UUID(uuidString: body.expectedGenerationId) else { throw TransferFailure.validationFailed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = PeerPin.hex(PeerPin.sha256(Data((request.method + ":" + PeerPin.hex(peerPin) + ":").utf8) + (try encoder.encode(body))))
        let key = "unified-local:" + operationID.uuidString.lowercased()
        let known = try managementTransaction { () throws -> Bool in
            try requireOwner(peerPin)
            return try management.validateKnownLocalDeploymentUnderAuthority(key: key, digest: digest)
        }
        if known {
            // Accepted intent alone is not success. Only the exact completed
            // common generation is an activation/structural receipt.
            guard before.generationID == operationID else { throw DeviceCommandIntentCoordinator.Failure.needsReview }
            return try managementTransaction { try requireOwner(peerPin); return ok(request, payload: unifiedControllerStatus(before, peerPin: peerPin)) }
        }
        guard before.generationID == expected else { throw DeviceCommandIntentCoordinator.Failure.needsReview }
        guard let target = before.entries.first(where: { $0.dashboardID == body.dashboardId }) else { throw TransferFailure.validationFailed }
        let remove = request.method == LANMethod.screenRemove.rawValue
        let retained = before.entries.filter { !remove || $0.entryID != target.entryID }.map(\.entryID)
        let selected = remove ? (before.configuredEntryID == target.entryID ? retained.first : before.configuredEntryID) : target.entryID
        try managementTransaction { try requireOwner(peerPin); try management.acceptDeploymentUnderAuthority(key: key, digest: digest) }
        let owner = try prepareUnifiedLocalControllerOwner(commonRootID: before.commonRootID, authenticatedPeerPin: peerPin)
        try session.selectOrRemove(operationID: operationID, generationID: operationID, retainedEntryIDs: retained, selected: selected, owner: owner)
        let changed = try session.validatedAssociation()
        let (reply,callback) = try managementTransaction { () throws -> (LANEnvelope, (() -> Void)?) in
            guard listenerAttempt == attempt, unifiedLocalSession === session else { throw DeviceManagementAuthority.Failure.staleLease }
            try requireOwner(peerPin); unifiedLocalAssociation = changed
            return (ok(request, payload: unifiedControllerStatus(changed, peerPin: peerPin)), onCommonContentChanged)
        }
        callback?(); return reply
    }

    private func handleCloudArchiveChunk(_ request: LANEnvelope, peerPin: [UInt8]?, listenerAttempt attempt: UUID) throws -> LANEnvelope {
        guard let peerPin else { throw TransferFailure.notPaired }
        let body = try LANCodec.decodePayload(LANCloudArchiveChunk.self, json: request.payloadJSON)
        guard let transfer = UUID(uuidString: body.transferId), let installation = UUID(uuidString: body.installationId),
              let operation = UUID(uuidString: body.operationId), let package = UUID(uuidString: body.packageId),
              body.archiveSha256.count == 64, body.archiveSha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              (1...25*1024*1024).contains(body.archiveBytes), body.offset >= 0,
              body.dataBase64.utf8.count <= 349528, let chunk = Data(base64Encoded: body.dataBase64),
              chunk.base64EncodedString() == body.dataBase64, !chunk.isEmpty, chunk.count <= 256*1024,
              body.offset <= body.archiveBytes - chunk.count else { throw TransferFailure.validationFailed }
        let (admit,receive) = try managementTransaction { () throws -> ((UUID,UUID,UUID,String,Int)throws->Void,(UUID,UUID,UUID,Data)throws->Void) in
            try requireOwner(peerPin)
            guard listenerAttempt == attempt, unifiedLocalAssociation?.installationID == installation,
                  let admit = onCloudArchiveAdmission, let receive = onCloudArchiveReceived else { throw TransferFailure.notPaired }
            return (admit,receive)
        }
        // Only an original fixed Cloud plan can authorize receipt of these bytes.
        // The callback runs outside the authority lock and must revalidate every chunk.
        try admit(installation,operation,package,body.archiveSha256,body.archiveBytes)
        let completed = try managementTransaction { () throws -> Data? in
            try requireOwner(peerPin)
            guard listenerAttempt == attempt, unifiedLocalAssociation?.installationID == installation else { throw TransferFailure.notPaired }
            cloudArchiveTransfers = cloudArchiveTransfers.filter { Date().timeIntervalSince($0.value.updated) < 120 }
            if cloudArchiveTransfers[transfer] == nil {
                // Completed buffers never block a later deployment. Retain at
                // most the latest completion alongside the bounded active upload.
                while cloudArchiveTransfers.count >= 2,
                      let completed = cloudArchiveTransfers.filter({ $0.value.complete }).min(by: { $0.value.updated < $1.value.updated }) {
                    cloudArchiveTransfers.removeValue(forKey: completed.key)
                }
                guard body.offset == 0, cloudArchiveTransfers.count < 2 else { throw TransferFailure.validationFailed }
                cloudArchiveTransfers[transfer] = .init(peer: peerPin, installation: installation, operation: operation, package: package, sha: body.archiveSha256, size: body.archiveBytes)
            }
            guard var value = cloudArchiveTransfers[transfer], value.peer == peerPin, value.installation == installation,
                  value.operation == operation, value.package == package, value.sha == body.archiveSha256, value.size == body.archiveBytes else { throw TransferFailure.validationFailed }
            if body.offset < value.bytes.count {
                guard body.offset + chunk.count <= value.bytes.count, value.bytes.subdata(in: body.offset..<body.offset+chunk.count) == chunk else { throw TransferFailure.validationFailed }
            } else {
                guard body.offset == value.bytes.count, !value.complete else { throw TransferFailure.validationFailed }
                value.bytes.append(chunk)
            }
            guard body.final == (body.offset + chunk.count == body.archiveBytes) else { throw TransferFailure.validationFailed }
            value.updated = Date(); cloudArchiveTransfers[transfer] = value
            if body.final {
                guard value.bytes.count == value.size, PeerPin.hex(PeerPin.sha256(value.bytes)) == value.sha else { cloudArchiveTransfers.removeValue(forKey: transfer); throw TransferFailure.validationFailed }
                return value.complete ? nil : value.bytes
            }
            return nil
        }
        if let completed {
            try receive(installation,operation,package,completed)
            try managementTransaction {
                try requireOwner(peerPin)
                guard listenerAttempt == attempt, var value = cloudArchiveTransfers[transfer] else { throw TransferFailure.interrupted }
                value.complete = true; cloudArchiveTransfers[transfer] = value
            }
        }
        return ok(request, payload: LANCloudArchiveChunkReceipt(transferId: transfer.uuidString.lowercased(), receivedBytes: body.offset + chunk.count, complete: body.final))
    }

    private func handleUnifiedLocalInstall(_ request: LANEnvelope, peerPin: [UInt8]?, listenerAttempt attempt: UUID) throws -> LANEnvelope {
        guard let peerPin else { throw TransferFailure.notPaired }
        let (session,prepare) = try managementTransaction { () throws -> (DeviceUnifiedInventorySession, (UUID, PairingIdentity, [DeviceLegacyMigrationScreen], UUID?, @escaping () throws -> Void) throws -> DeviceIncomingLocalPreparation) in
            guard listenerAttempt == attempt, management.isConcurrent, let session = unifiedLocalSession,
                  let prepare = prepareIncomingLocalScreens else { throw DeviceManagementAuthority.Failure.staleLease }
            try requireOwner(peerPin); return (session, prepare)
        }
        let before = try session.validatedAssociation()
        let body = try LANCodec.decodePayload(LANUnifiedScreenInstall.self, json: request.payloadJSON)
        guard let operation = UUID(uuidString: body.operationId), let expected = UUID(uuidString: body.expectedGenerationId),
              (1...12).contains(body.incoming.count) else { throw TransferFailure.validationFailed }
        let retained = body.retainedEntryIds.compactMap(UUID.init(uuidString:))
        let incomingIDs = body.incoming.compactMap { UUID(uuidString: $0.entryId) }
        let selected = body.selectedEntryId.flatMap(UUID.init(uuidString:))
        guard retained.count == body.retainedEntryIds.count, Set(retained).count == retained.count,
              Set(retained).isSubset(of: Set(before.entries.map(\.entryID))),
              incomingIDs.count == body.incoming.count, Set(incomingIDs).count == incomingIDs.count,
              Set(retained + incomingIDs).count <= 12,
              body.selectedEntryId == nil || selected != nil,
              selected == nil || Set(retained + incomingIDs).contains(selected!),
              Set(body.incoming.map { $0.screen.deployment.revision.dashboardId }).count == body.incoming.count else { throw TransferFailure.validationFailed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = PeerPin.hex(PeerPin.sha256(Data((request.method + ":" + PeerPin.hex(peerPin) + ":").utf8) + (try encoder.encode(body))))
        let key = "unified-local:" + operation.uuidString.lowercased()
        let known = try managementTransaction { try requireOwner(peerPin); return try management.validateKnownLocalDeploymentUnderAuthority(key: key, digest: digest) }
        if known {
            guard before.generationID == operation else { throw DeviceCommandIntentCoordinator.Failure.needsReview }
            return try managementTransaction { try requireOwner(peerPin); return ok(request, payload: unifiedControllerStatus(before, peerPin: peerPin)) }
        }
        guard before.generationID == expected else { throw DeviceCommandIntentCoordinator.Failure.needsReview }
        for (entryID,item) in zip(incomingIDs,body.incoming) {
            if let old = before.entries.first(where: { $0.entryID == entryID }) {
                guard old.provenance == "retainedLocal", retained.contains(entryID), old.dashboardID == item.screen.deployment.revision.dashboardId else { throw TransferFailure.validationFailed }
            }
            let deployment = item.screen.deployment
            guard deployment.deployment.deviceId == runtime.profile.deviceId,
                  deployment.deployment.dashboardId == deployment.revision.dashboardId,
                  deployment.deployment.revision == deployment.revision.revision else { throw TransferFailure.targetMismatch }
        }
        try managementTransaction { try requireOwner(peerPin); try management.acceptDeploymentUnderAuthority(key: key, digest: digest) }
        let owner = try prepareUnifiedLocalControllerOwner(commonRootID: before.commonRootID, authenticatedPeerPin: peerPin)
        let inputs = try zip(incomingIDs,body.incoming).map { entryID,item -> DeviceLegacyMigrationScreen in
            let assets = try stageFiles(item.screen.deployment.files)
            guard let manifest = assets["manifest.json"]?.data, assets["index.html"] != nil else { throw TransferFailure.validationFailed }
            let decoded = try JSONDecoder().decode(DashboardManifest.self, from: manifest)
            try PackageValidator.validate(decoded)
            guard decoded.dashboardId == item.screen.deployment.revision.dashboardId,
                  decoded.revision == item.screen.deployment.revision.revision else { throw TransferFailure.validationFailed }
            if let reads = item.screen.publicReads { try reads.validate() }
            if let ha = item.screen.homeAssistant { try ha.validate() }
            return .init(entryID: entryID, packageOperationID: UUID(), displayName: item.screen.name,
                revision: item.screen.deployment.revision, manifest: manifest, files: assets.filter { $0.key != "manifest.json" }.mapValues(\.data),
                homeAssistant: item.screen.homeAssistant, generic: nil, publicReads: item.screen.publicReads)
        }
        let preparation = try prepare(operation, PairingIdentity(role: .controller, publicKey: peerPin), inputs, selected) { [weak self] in
            guard let self else { throw DeviceManagementAuthority.Failure.staleLease }
            try self.managementTransaction {
                guard self.listenerAttempt == attempt, self.unifiedLocalSession === session else { throw DeviceManagementAuthority.Failure.staleLease }
                try self.requireOwner(peerPin)
            }
        }
        try session.installLocal(preparation, operationID: operation, generationID: operation,
                                 retainedEntryIDs: retained, selected: selected, owner: owner)
        let changed = try session.validatedAssociation()
        let (reply,callback) = try managementTransaction { () throws -> (LANEnvelope, (() -> Void)?) in
            guard listenerAttempt == attempt, unifiedLocalSession === session else { throw DeviceManagementAuthority.Failure.staleLease }
            try requireOwner(peerPin); unifiedLocalAssociation = changed
            return (ok(request, payload: unifiedControllerStatus(changed, peerPin: peerPin)), onCommonContentChanged)
        }
        callback?(); return reply
    }

    /// Nominal fixed dispatch owner exists only inside the authenticated LAN server.
    /// It captures approval and latest intent before preparation, then rechecks
    /// the current registry while its lock spans the exact resource CAS.
    private final class UnifiedLocalControllerOwner: NativeUnifiedLocalInventoryOwner {
        let commonRootID: UUID
        let peerPinHex: String
        private weak var server: DeviceLANServer?
        private let peerPin: [UInt8]
        private let checkpoint: DeviceCommandIntentCoordinator.Checkpoint?
        init(server: DeviceLANServer, commonRootID: UUID, peerPin: [UInt8], checkpoint: DeviceCommandIntentCoordinator.Checkpoint?) {
            self.server = server; self.commonRootID = commonRootID; self.peerPin = peerPin
            self.peerPinHex = PeerPin.hex(peerPin); self.checkpoint = checkpoint
        }
        func performFixedUnifiedLocalDispatch(command: NativeInstallationUnifiedLocalDispatchCommand) throws -> NativeInstallationUnifiedLocalDispatchResult {
            guard let server else { throw DeviceManagementAuthority.Failure.staleLease }
            return try server.management.performFixedUnifiedLocalDispatch(command: command, peerPinHex: peerPinHex, checkpoint: checkpoint) {
                server.lock.lock(); defer { server.lock.unlock() }
                guard !server.managementSuspended, !server.runtimeRetired else { throw DeviceManagementAuthority.Failure.staleLease }
                try server.requireOwner(self.peerPin)
                return try command.performDuringFixedOwner()
            }
        }
    }

    private func prepareUnifiedLocalControllerOwner(commonRootID: UUID, authenticatedPeerPin: [UInt8]) throws -> any NativeUnifiedLocalInventoryOwner {
        let checkpoint = try management.acceptUnifiedLocalIntent(peerPinHex: PeerPin.hex(authenticatedPeerPin)) {
            lock.lock(); defer { lock.unlock() }
            guard !managementSuspended, !runtimeRetired else { throw DeviceManagementAuthority.Failure.staleLease }
            try requireOwner(authenticatedPeerPin)
        }
        return UnifiedLocalControllerOwner(server: self, commonRootID: commonRootID, peerPin: authenticatedPeerPin, checkpoint: checkpoint)
    }

    private func isApprovedPeer(_ peerPin: [UInt8]?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let peerPin else { return false }
        return runtime.pairing.isApproved(PairingIdentity(role: .controller, publicKey: peerPin))
    }

    public var approvedLocalControllers: [PairingIdentity] {
        lock.lock(); defer { lock.unlock() }
        return runtime.pairing.approvedControllers
    }

    /// On-device explicit removal of one approved pin. A live session is denied
    /// on its next request; other peers, enrollment and installed screens remain.
    public func revokeLocalController(_ controller: PairingIdentity) throws {
        try managementTransaction { try revokeControllerLocked(controller) }
    }

    private func revokeControllerLocked(_ controller: PairingIdentity) throws {
        guard runtime.pairing.isApproved(controller) else { throw TransferFailure.notPaired }
        var next = runtime
        next.pairing.revoke(controller)
        var state = DevicePersistedState(runtime: next, activeStoredRevision: activeStoredRevision)
        state.screenSet = screenSet; state.settings = settings; state.contentOwner = contentOwner
        try store?.save(state)
        runtime = next
        if runtime.pairing.session == nil { clearPendingPairingLocked() }
        notifyLocked()
    }

    private func waitUntilDeviceConfirmed(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do { try expirePairingIfNeeded() } catch { return false }
            lock.lock()
            let done = deviceConfirmed
            let cancelled = pairingCode == nil
            lock.unlock()
            if done { return true }
            if cancelled { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock()
        let done = deviceConfirmed
        lock.unlock()
        return done
    }

    private func expectedCode(for transcript: PairingTranscript) -> String {
        #if canImport(CryptoKit)
        return PairingSAS.matchingCode(for: transcript)
        #else
        return "000000"
        #endif
    }

    /// Hash-checks every blob before anything can activate. Nothing here
    /// touches `activePackage`; a rejected transfer keeps the current dashboard.
    private func stageFiles(_ files: [LANFileBlob]) throws -> [String: PackageAsset] {
        var staged: [String: PackageAsset] = [:]
        for file in files {
            guard let data = Data(base64Encoded: file.dataBase64) else {
                throw TransferFailure.validationFailed
            }
            let digest = PeerPin.hex(PeerPin.sha256(data))
            if digest != file.sha256.lowercased() {
                throw TransferFailure.validationFailed
            }
            let normalized = try PackagePath.normalize(file.path)
            guard let path = try? PackageAssetStore.hostRelativePath(normalized) else {
                throw TransferFailure.validationFailed
            }
            if staged[path] != nil {
                throw TransferFailure.validationFailed
            }
            staged[path] = PackageAsset(path: path, data: data, mime: PackageAssetStore.mime(for: path))
        }
        return staged
    }

    private func ok<T: Encodable>(_ request: LANEnvelope, payload: T) -> LANEnvelope {
        LANEnvelope(
            requestId: request.requestId,
            method: request.method,
            ok: true,
            payloadJSON: try? LANCodec.encodePayload(payload)
        )
    }
}
#endif
