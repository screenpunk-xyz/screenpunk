import Foundation
import ScreenpunkCore
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
    private var settings = DeviceSettingsSnapshot()
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

    private func genericConnectionScope() -> GenericConnectionDeviceVault.Scope? {
        lock.lock(); defer { lock.unlock() }
        guard let owner = runtime.pairing.owner, let revision = runtime.activeRevision,
              let dashboardId = activeStoredRevision?.dashboardId else { return nil }
        return .init(owner: PeerPin.hex(owner.publicKey), dashboardId: dashboardId, revision: revision)
    }

    public func makeGenericConnectionRuntime() async throws -> ConnectionRuntime {
        guard let scope = genericConnectionScope() else { throw ConnectionFailure.permissionRequired }
        return try await genericConnectionVault.makeRuntime(scope: scope, currentScope: { [weak self] in self?.genericConnectionScope() })
    }
    private var publicSession: (scope: HomeAssistantDeviceRuntime.Scope, session: PublicReadSession)?
    public func publicReadSession() -> PublicReadSession? {
        guard let scope = homeAssistantScope(), let generation = scope.grantSet else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let existing = publicSession, existing.scope == scope { return existing.session }
        publicSession?.session.cancel(); publicSession = nil
        guard let config = try? homeAssistantVault.publicConfiguration(owner: scope.owner, dashboardId: scope.dashboardId,
            revision: scope.revision, generation: generation),
              let session = try? PublicReadSession(provisioning: config, isCurrent: { [weak self] in self?.homeAssistantScope() == scope }) else { return nil }
        publicSession = (scope, session); return session
    }
    private func clearPublicSession() { publicSession?.session.cancel(); publicSession = nil }

    private func homeAssistantScope() -> HomeAssistantDeviceRuntime.Scope? {
        lock.lock(); defer { lock.unlock() }
        guard let owner = runtime.pairing.owner, let revision = runtime.activeRevision, let dashboardId = activeStoredRevision?.dashboardId else { return nil }
        return .init(owner: PeerPin.hex(owner.publicKey), revision: revision, dashboardId: dashboardId, grantSet: screenSet?.grantSet)
    }
    private var deviceConfirmed = false
    private var pairingExpiry: DispatchWorkItem?
    private var pinnedController: [UInt8]?
    private var activeStoredRevision: StoredRevision?
    // Internal visibility allows transport-failure regression tests to cancel it.
    private(set) var listener: NWListener?
    private let listenerLock = NSLock()
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
        runtime: DeviceRuntime,
        identity: TLSIdentityMaterial,
        clock: PairingClock = SystemClock(),
        store: DeviceStateStore? = nil,
        homeAssistantVault: HomeAssistantDeviceVault = HomeAssistantDeviceVault(),
        genericConnectionVault: GenericConnectionDeviceVault = GenericConnectionDeviceVault(),
        requestBodyTimeout: TimeInterval = LANProtocolLimits.transferTimeoutSeconds,
        untrustedIdleTimeout: TimeInterval = DeviceLANServer.untrustedIdleTimeout,
        maxUntrustedConnections: Int = DeviceLANServer.maxUntrustedConnections
    ) {
        self.genericConnectionVault = genericConnectionVault
        self.homeAssistantVault = homeAssistantVault
        self.runtime = runtime
        self.identity = identity
        self.clock = clock
        self.store = store
        self.requestBodyTimeout = requestBodyTimeout
        self.untrustedIdleTimeout = untrustedIdleTimeout
        self.maxUntrustedConnections = max(1, maxUntrustedConnections)
        self.runtime.identity = identity.pairingIdentity
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

    /// Recreate a failed listener without touching pairing or installed content.
    /// May block during startup; callers should use a worker queue.
    public func start() throws {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        if let listener {
            switch listener.state {
            case .ready, .setup: return
            default: listener.cancel()
            }
        }
        listener = nil
        port = 0
        let parameters = try LANChannel.tlsParameters(
            identity: identity,
            pinnedPeer: { [weak self] in self?.ownerPin() },
            queue: queue
        )
        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.global(qos: .userInitiated).async {
                self?.accept(connection)
            }
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw TransferFailure.interrupted
        }
        if case .failed(let error) = listener.state {
            listener.cancel()
            throw error
        }
        guard case .ready = listener.state else {
            listener.cancel()
            throw TransferFailure.interrupted
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw TransferFailure.interrupted
        }
        self.listener = listener
        self.port = port
        advertiseBonjour(on: listener)
        lock.lock()
        runtime.advertisement = AdvertisedDevice(
            deviceId: runtime.profile.deviceId,
            host: "127.0.0.1",
            port: Int(port),
            source: .advertised
        )
        lock.unlock()
    }

    public func confirmLocally() throws {
        lock.lock()
        defer { lock.unlock() }
        expirePairingIfNeededLocked()
        guard let code = pairingCode ?? runtime.pairingCode else {
            throw PairingFailure.expired
        }
        deviceConfirmed = true
        if let owner = runtime.pairing.session?.candidateOwner {
            try runtime.confirmPairing(code: code, presentedOwner: owner, clock: clock)
        }
        pinnedController = runtime.pairing.owner?.publicKey
        persist()
        onChange?()
    }

    /// Cancels only the pending handshake. Existing ownership and deployed content remain intact.
    public func cancelPairing() {
        lock.lock()
        clearPendingPairingLocked()
        lock.unlock()
        onChange?()
    }

    /// Also called by the scheduled expiry and directly by deterministic tests.
    public func expirePairingIfNeeded() {
        lock.lock()
        expirePairingIfNeededLocked()
        lock.unlock()
    }

    private func expirePairingIfNeededLocked() {
        guard let session = runtime.pairing.session,
              clock.now.timeIntervalSince(session.createdAt) >= PairingLimits.expirySeconds else { return }
        clearPendingPairingLocked()
        onChange?()
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
        let work = DispatchWorkItem { [weak self] in self?.expirePairingIfNeeded() }
        pairingExpiry = work
        queue.asyncAfter(deadline: .now() + PairingLimits.expirySeconds + 0.1, execute: work)
    }

    /// Erases owner, active revision, package bytes, and everything on disk.
    public func unlink() {
        lock.lock()
        try? genericConnectionVault.revoke()
        genericConnectionGeneration = UUID()
        clearPublicSession()
        try? homeAssistantVault.revoke()
        try? homeAssistantVault.revokePublic()
        let homeAssistantRuntime = self.homeAssistantRuntime
        Task { await homeAssistantRuntime.cancelPending() }
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
        lock.unlock()
        onChange?()
    }

    public func stop() {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        listener?.cancel()
        listener = nil
        port = 0
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
        lock.lock()
        let saved: DeviceSettingsSnapshot
        do { saved = try updateSettingsLocked(update) }
        catch { lock.unlock(); throw error }
        lock.unlock()
        onChange?()
        return saved
    }

    /// The UI/runtime calls this only after consuming this exact revision.
    /// A late acknowledgement can never mark a newer edit as applied.
    public func markSettingsApplied(revision: String) {
        lock.lock()
        guard settings.revision == revision, settings.appliedRevision != revision else { lock.unlock(); return }
        settings.appliedRevision = revision
        lock.unlock()
        onChange?()
    }

    /// Suspension or runtime failure clears the live acknowledgement without
    /// changing the persisted desired configuration or its conflict token.
    public func markSettingsUnapplied(revision: String) {
        lock.lock()
        guard settings.revision == revision, settings.appliedRevision != nil else { lock.unlock(); return }
        settings.appliedRevision = nil
        lock.unlock()
        onChange?()
    }

    private func updateSettingsLocked(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot {
        let next = try settings.replacing(with: update)
        try validateDashboardSettings(next.value)
        if let store {
            var state = DevicePersistedState(runtime: runtime, activeStoredRevision: activeStoredRevision)
            state.screenSet = screenSet
            state.settings = next
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

    private func accept(_ connection: NWConnection) {
        guard startAndWaitReady(connection) else {
            connection.cancel()
            return
        }
        let peerPin = LANChannel.observedPeerPin(connection)
        let link = LANLink(connection: connection, queue: queue)
        serve(link, peerPin: peerPin)
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
    private func serve(_ link: LANLink, peerPin: [UInt8]?) {
        defer { link.cancel() }
        var countedUntrusted = false
        defer { if countedUntrusted { releaseUntrustedSlot() } }
        while true {
            do {
                let owner = ownerPin()
                let trusted = owner != nil && peerPin == owner
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
                let reply = handle(request, peerPin: peerPin)
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

    private func handle(_ request: LANEnvelope, peerPin: [UInt8]?) -> LANEnvelope {
        if request.method == LANMethod.pairConfirm.rawValue {
            _ = waitUntilDeviceConfirmed(timeout: 60)
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            guard request.protocolVersion == LANProtocolLimits.version else {
                throw TransferFailure.validationFailed
            }
            switch LANMethod(rawValue: request.method) {
            case .hello:
                let hello = LANHello(
                    role: .device,
                    deviceId: runtime.profile.deviceId,
                    pinHex: PeerPin.hex(identity.pin),
                    name: runtime.profile.name,
                    capabilities: ["home-assistant-http-v1", "home-assistant-services-v1", "camera-playback-v1", "screen-set-v1", "public-read-http-v1", "public-read-dynamic-path-v1", "device-settings-v1", "generic-connections-v1", "connection-inventory-v1"],
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
                onChange?()
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
                deviceConfirmed = false
                schedulePairingExpiryLocked()
                onChange?()
                return ok(
                    request,
                    payload: LANPairBeginResult(code: code, devicePinHex: PeerPin.hex(identity.pin))
                )
            case .pairConfirm:
                guard deviceConfirmed else { throw TransferFailure.interrupted }
                let body = try LANCodec.decodePayload(LANPairConfirm.self, json: request.payloadJSON)
                let controllerPin = try authenticatedPeer(peerPin, claimedHex: body.controllerPinHex)
                let controller = PairingIdentity(role: .controller, publicKey: controllerPin)
                try runtime.confirmPairing(code: body.code, presentedOwner: controller, clock: clock)
                pinnedController = runtime.pairing.owner?.publicKey
                // The session has done its job. Keeping it would leave
                // `runtime.pairingCode` set and the code view on screen.
                clearPendingPairingLocked()
                persist()
                onChange?()
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision, screens: screenSet?.screens.map(\.entry), selectedDashboardId: screenSet?.selectedDashboardId))
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
                        Task { await service.cancelPending() }
                    }
                    screenSet = nil
                    screenPackages = [:]
                    activePackage = PackageAssetStore(assets: staged)
                    activeStoredRevision = body.revision
                    persist()
                    onChange?()
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
                return ok(request, payload: try connectionInventory(owner: PeerPin.hex(peerPin!)))
            case .connectionsUpdateHome:
                try requireOwner(peerPin)
                let body = try LANCodec.decodePayload(DeviceHomeAssistantUpdate.self, json: request.payloadJSON)
                let owner = PeerPin.hex(peerPin!)
                let inventory = try connectionInventory(owner: owner)
                guard body.entries.allSatisfy({ inventory.entries.contains($0) && $0.kind == "Service integration" }) else { throw ConnectionFailure.permissionRequired }
                try homeAssistantVault.update(body, owner: owner, grantSet: screenSet?.grantSet)
                let service = homeAssistantRuntime
                Task { await service.cancelPending() }
                onChange?()
                return ok(request, payload: try connectionInventory(owner: owner))
            case .connectionsProvision:
                try requireOwner(peerPin)
                let body = try LANCodec.decodePayload(ConnectionProvisioning.self, json: request.payloadJSON)
                guard body.revision == runtime.activeRevision,
                      body.dashboardId == activeStoredRevision?.dashboardId else { throw TransferFailure.validationFailed }
                try genericConnectionVault.provision(body, owner: PeerPin.hex(peerPin!))
                genericConnectionGeneration = UUID()
                onChange?()
                return ok(request, payload: ConnectionProvisioningReceipt(deviceId: runtime.profile.deviceId,
                    dashboardId: body.dashboardId, revision: body.revision, provisioningId: body.provisioningId))
            case .connectionsRevoke:
                try requireOwner(peerPin)
                try genericConnectionVault.revoke()
                genericConnectionGeneration = UUID()
                onChange?()
                return ok(request, payload: ["revoked": true])
            case .homeAssistantProvision:
                try requireOwner(peerPin)
                let body = try LANCodec.decodePayload(HomeAssistantProvisioning.self, json: request.payloadJSON)
                guard body.revision == runtime.activeRevision,
                      body.dashboardId == activeStoredRevision?.dashboardId else { throw TransferFailure.validationFailed }
                if let generation = screenSet?.grantSet {
                    try homeAssistantVault.provisionInGeneration(body, owner: PeerPin.hex(peerPin!), generation: generation)
                } else {
                    try homeAssistantVault.provision(body, owner: PeerPin.hex(peerPin!))
                }
                onChange?()
                return ok(request, payload: HomeAssistantProvisioningReceipt(
                    deviceId: runtime.profile.deviceId, dashboardId: body.dashboardId, revision: body.revision,
                    connectionId: body.connectionId, provisioningId: body.provisioningId))
            case .homeAssistantRevoke:
                try requireOwner(peerPin)
                try homeAssistantVault.revoke()
                let service = homeAssistantRuntime
                Task { await service.cancelPending() }
                onChange?()
                return ok(request, payload: ["revoked": true])
            case .queryActive:
                try requireOwner(peerPin)
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision, screens: screenSet?.screens.map(\.entry), selectedDashboardId: screenSet?.selectedDashboardId))
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
                    ?? "failed"
            )
        }
    }

    /// Selection changes only after persistence succeeds; swiping never changes installed membership.
    public func selectScreen(_ dashboardId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var next = screenSet, next.screens.contains(where: { $0.revision.dashboardId == dashboardId }) else { return }
        guard next.selectedDashboardId != dashboardId else { return }
        next.selectedDashboardId = dashboardId
        if let store {
            var state = DevicePersistedState(runtime: runtime, activeStoredRevision: activeStoredRevision)
            state.screenSet = next
            state.settings = settings
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
        Task { await service.cancelPending() }
        onChange?()
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
        try homeAssistantVault.stage(body.screens.compactMap(\.homeAssistant), owner: owner, generation: generation)
        try homeAssistantVault.stagePublic(body.screens.compactMap(\.publicReads), owner: owner, generation: generation)
        let installed = DeviceInstalledScreenSet(deploymentId: body.deploymentId, contentDigest: digest,
            grantSet: generation, screens: screens, selectedDashboardId: body.selectedDashboardId)
        guard let selected = screens.first(where: { $0.revision.dashboardId == body.selectedDashboardId }) else {
            throw TransferFailure.validationFailed
        }
        var state = DevicePersistedState(owner: runtime.pairing.owner, activeRevision: selected.revision.revision,
            activeStoredRevision: selected.revision, lastDeployment: selected.deployment)
        state.screenSet = installed
        state.settings = settings
        try store?.save(state)
        committed = true
        clearPublicSession()
        screenSet = installed
        screenPackages = packages
        activateSelectionLocked(body.selectedDashboardId)
        let service = homeAssistantRuntime
        Task { await service.cancelPending() }
        // Cleanup after the commit cannot invalidate the newly selected generation.
        try? homeAssistantVault.retainGeneration(generation)
        try? homeAssistantVault.prunePublic(keeping: generation)
        store?.prunePackageGenerations(keeping: Set(screens.map(\.packageDirectory)))
        onChange?()
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
    private func requireOwner(_ peerPin: [UInt8]?) throws {
        guard let owner = runtime.pairing.owner?.publicKey, let peerPin, peerPin == owner else {
            throw TransferFailure.notPaired
        }
    }

    private func waitUntilDeviceConfirmed(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            expirePairingIfNeededLocked()
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
