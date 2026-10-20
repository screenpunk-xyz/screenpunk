import Foundation
import SwiftUI
import ScreenpunkCore

#if canImport(Network) && canImport(Security)
/// Owns the device TLS listener and publishes pairing/deploy state to SwiftUI.
public final class DeviceLANHost: ObservableObject {
    @Published public var runtime: DeviceRuntime
    @Published public var pairingCode: String?
    /// Confirm was tapped here; the Mac has not finished `pair.confirm` yet.
    @Published public var awaitingControllerConfirm = false
    @Published public var port: UInt16 = 0
    @Published public var errorMessage: String?
    @Published public var activePackage: PackageAssetStore?
    @Published public var completedPairingSessionNonceHex: String?
    @Published public var pendingPairingSessionNonceHex: String?
    @Published public var pendingPairingRequest: DevicePendingPairingRequest?
    @Published public var screenSet: DeviceInstalledScreenSet?
    @Published public var settingsSnapshot: DeviceSettingsSnapshot?
    @Published public var genericConnectionGeneration = UUID()
    public let server: DeviceLANServer?
    private let management: DeviceManagementContext
    private let lifecycleLock = NSLock()
    private var managementSuspended = false
    private var runtimeRetired = false
    private let runtimeLifetime = DeviceRuntimeLifetime()
    @MainActor private var lifetimeRegistration: UUID?
    @MainActor public var lifetime: DeviceRuntimeLifetime {
        if lifetimeRegistration == nil, !runtimeLifetime.isRetired {
            lifetimeRegistration = runtimeLifetime.register { [weak self] in self?.retireForReset() }
        }
        return runtimeLifetime
    }
    private let recoveryQueue = DispatchQueue(label: "xyz.screenpunk.lan.recovery")
    private var recoveryTimer: DispatchSourceTimer?
    private var listenerError: String?
    private var temporaryActivation: DeviceTemporaryActivationRuntime?
    private var foreground = false
    private var retainedScenePaused = false
    private var retainedSceneEpoch: UUID?

    /// Scheduling state only, not authority. Renderer/bridge callbacks consult this
    /// BEFORE any resource/management validation, including before SwiftUI updates.
    @_spi(NativeInstallation) public func isRetainedSceneActivityAllowed() -> Bool {
        lifecycleLock.lock()
        let allowed = !runtimeRetired && !managementSuspended && !retainedScenePaused
        lifecycleLock.unlock()
        return allowed && (server?.isRetainedSceneActivityAllowed() ?? true)
    }

    /// Sendable scheduling check for queued callbacks. Captures only the server's
    /// independent locked gate, never Host/Server or an authority/resource owner.
    @_spi(NativeInstallation) public func retainedSceneActivityCheck() -> @Sendable () -> Bool {
        server?.retainedSceneActivityCheck() ?? { false }
    }

    /// Fast MainActor fence only. Never takes authority/server/resource locks.
    @_spi(NativeInstallation) @MainActor public func pauseRetainingRuntime() -> UUID? {
        lifecycleLock.lock()
        guard !runtimeRetired, !managementSuspended, let token = server?.pauseRetainedSceneActivity() else {
            lifecycleLock.unlock(); return nil
        }
        retainedScenePaused = true; retainedSceneEpoch = token
        recoveryTimer?.cancel(); recoveryTimer = nil
        lifecycleLock.unlock()
        foreground = false
        // The server's early scope gate is already closed, so this cannot wait
        // for a resource owner just to discover the temporary activation scope.
        temporaryActivation?.update(active: false)
        return token
    }

    /// Stop and drain on the existing worker queue. No MainActor synchronous join.
    @_spi(NativeInstallation) public func drainRetainedPause(_ token: UUID) async throws {
        guard let server else { throw TransferFailure.interrupted }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recoveryQueue.async {
                do { try server.drainRetainedSceneActivity(token); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
    }

    /// Caller has revalidated the exact retained owner/runtime/CURRENT selection
    /// off-main. This only reopens scheduling and queues listener recovery.
    @_spi(NativeInstallation) @MainActor public func activateRetainedResume(_ token: UUID) -> Bool {
        lifecycleLock.lock()
        guard !runtimeRetired, !managementSuspended, retainedScenePaused,
            retainedSceneEpoch == token, server?.activateRetainedSceneActivity(token) == true else {
            lifecycleLock.unlock(); return false
        }
        retainedScenePaused = false
        lifecycleLock.unlock()
        foreground = true
        recoveryQueue.async { [weak self] in
            guard let self, self.isCurrentRetainedActivity(token) else { return }
            self.resumeForActivity(token)
        }
        return true
    }
    private func isCurrentRetainedActivity(_ token: UUID) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return !runtimeRetired && !managementSuspended && !retainedScenePaused && retainedSceneEpoch == token
    }

    @MainActor public func setForeground(_ active: Bool) {
        guard !isRuntimeRetired else { return }
        foreground = active
        if temporaryActivation == nil, let server { temporaryActivation = DeviceTemporaryActivationRuntime(server: server) }
        temporaryActivation?.update(active: active)
    }

    /// `store` defaults to the per-user device home so pairing and the active
    /// package survive a relaunch. Tests pass a temporary store.
    public convenience init(runtime: DeviceRuntime, management: DeviceManagementContext, store: DeviceStateStore? = nil) throws {
        try self.init(runtime: runtime, management: management, store: store, identityProvider: { try TLSIdentity.loadOrCreate(role: .device) })
    }
    init(runtime: DeviceRuntime, management: DeviceManagementContext, store: DeviceStateStore?,
         identityProvider: () throws -> TLSIdentityMaterial,
         homeAssistantVault: HomeAssistantDeviceVault? = nil, genericConnectionVault: GenericConnectionDeviceVault? = nil) throws {
        self.management = management
        let identity = try management.withAuthority(identityProvider)
        var runtime = runtime
        runtime.identity = identity.pairingIdentity
        let server = try DeviceLANServer(management: management, runtime: runtime, identity: identity,
            store: store ?? DeviceStateStore(root: DeviceStateStore.defaultRoot()),
            homeAssistantVault: homeAssistantVault ?? .init(), genericConnectionVault: genericConnectionVault ?? .init())
        self.runtime = server.runtime
        self.activePackage = server.activePackage
        self.screenSet = server.screenSet
        self.settingsSnapshot = server.settingsSnapshot
        self.server = server
        retainedSceneEpoch = server.retainedSceneActivityEpoch()
        server.onChange = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        server.onManagementSuspended = { [weak self] in self?.suspendManagement() }
    }

    private var isRuntimeRetired: Bool { lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return runtimeRetired }

    /// Terminal reset retirement is separate from ordinary backgrounding/management revocation.
    @MainActor public func retireForReset() {
        lifecycleLock.lock()
        guard !runtimeRetired else { lifecycleLock.unlock(); return }
        runtimeRetired = true; managementSuspended = true; retainedSceneEpoch = nil; retainedScenePaused = true
        recoveryTimer?.cancel(); recoveryTimer = nil
        lifecycleLock.unlock()
        server?.retireForReset()
        foreground = false; temporaryActivation?.suspendForReset(); temporaryActivation = nil
        runtimeLifetime.retire()
    }

    private func suspendManagement() {
        lifecycleLock.lock()
        guard !managementSuspended else { lifecycleLock.unlock(); return }
        managementSuspended = true; retainedSceneEpoch = nil; retainedScenePaused = true
        recoveryTimer?.cancel(); recoveryTimer = nil
        lifecycleLock.unlock()
        server?.suspendManagement()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRuntimeRetired else { return }
            self.errorMessage = "Local management is unavailable. Restart to check recovery."
            self.refresh()
        }
    }

    public func start() {
        guard let epoch = currentActivityEpoch() else { return }
        recoveryQueue.async { [weak self] in self?.startForActivity(epoch) }
    }
    private func currentActivityEpoch() -> UUID? {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !runtimeRetired, !managementSuspended, !retainedScenePaused else { return nil }
        return retainedSceneEpoch
    }
    private func startForActivity(_ epoch: UUID) {
        guard isCurrentRetainedActivity(epoch), isRetainedSceneActivityAllowed() else { return }
        // Validation may perform filesystem work. Only the recovery queue calls here.
        do { try management.validate() }
        catch { if isCurrentRetainedActivity(epoch) { suspendManagement() }; return }
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !runtimeRetired, !managementSuspended, !retainedScenePaused,
            retainedSceneEpoch == epoch, recoveryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: recoveryQueue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in self?.ensureListener(epoch: epoch) }
        recoveryTimer = timer
        timer.resume()
    }

    /// Re-advertise without a synchronous MainActor validation or listener wait.
    public func resume() {
        guard let epoch = currentActivityEpoch() else { return }
        recoveryQueue.async { [weak self] in self?.resumeForActivity(epoch) }
    }
    private func resumeForActivity(_ epoch: UUID) {
        guard isCurrentRetainedActivity(epoch), isRetainedSceneActivityAllowed() else { return }
        startForActivity(epoch)
        guard isCurrentRetainedActivity(epoch), isRetainedSceneActivityAllowed() else { return }
        server?.stop()
        ensureListener(epoch: epoch)
    }
    private func ensureListener(epoch: UUID) {
        guard isCurrentRetainedActivity(epoch), isRetainedSceneActivityAllowed(), let server else { return }
        let result = Result { try server.start(retainedSceneEpoch: epoch) }
        if case .failure(let error) = result, error is DeviceManagementAuthority.Failure {
            if isCurrentRetainedActivity(epoch) { suspendManagement() }; return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentRetainedActivity(epoch), self.isRetainedSceneActivityAllowed() else { return }
            switch result {
            case .success:
                if self.errorMessage == self.listenerError { self.errorMessage = nil }
                self.listenerError = nil
            case .failure(let error):
                self.listenerError = String(describing: error)
                self.errorMessage = self.listenerError
            }
            self.refresh()
        }
    }

    deinit {
        recoveryTimer?.cancel()
        server?.stop()
    }

    public func confirm(expectedSessionNonceHex: String? = nil) {
        guard isRetainedSceneActivityAllowed() else { return }
        do {
            try server?.confirmLocally(expectedSessionNonceHex: expectedSessionNonceHex)
            refresh()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func cancelPairing(expectedSessionNonceHex: String? = nil) {
        guard isRetainedSceneActivityAllowed() else { return }
        do {
            try server?.cancelPairing(expectedSessionNonceHex: expectedSessionNonceHex)
            errorMessage = nil; refresh()
        } catch { errorMessage = "Local management is unavailable." }
    }

    @MainActor public func advanceScreen(by offset: Int) {
        guard isRetainedSceneActivityAllowed() else { return }
        guard let set = screenSet, let index = set.screens.firstIndex(where: { $0.revision.dashboardId == set.selectedDashboardId }) else { return }
        guard let next = ScreenCarousel.index(from: index, offset: offset, count: set.screens.count) else { return }
        selectScreen(set.screens[next].revision.dashboardId)
    }

    @MainActor public func selectScreen(_ dashboardId: String) {
        guard isRetainedSceneActivityAllowed() else { return }
        temporaryActivation?.manualSelection()
        do {
            try server?.selectScreen(dashboardId)
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = "Could not switch screens. Try again."
        }
    }

    @discardableResult public func saveSettings(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot {
        guard isRetainedSceneActivityAllowed() else { throw TransferFailure.interrupted }
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        let snapshot = try server.updateSettingsLocally(update)
        refresh()
        return snapshot
    }

    public func markSettingsApplied(revision: String) {
        guard isRetainedSceneActivityAllowed() else { return }
        guard settingsSnapshot?.revision == revision, settingsSnapshot?.isApplied == false else { return }
        do { try server?.markSettingsApplied(revision: revision); refresh() }
        catch { errorMessage = "Local management is unavailable." }
    }

    public func markSettingsUnapplied(revision: String) {
        guard isRetainedSceneActivityAllowed() else { return }
        guard settingsSnapshot?.revision == revision, settingsSnapshot?.isApplied == true else { return }
        do { try server?.markSettingsUnapplied(revision: revision); refresh() }
        catch { errorMessage = "Local management is unavailable." }
    }

    public func disconnect(keepScreens: Bool) throws {
        guard isRetainedSceneActivityAllowed() else { throw TransferFailure.interrupted }
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        try server.disconnect(keepScreens: keepScreens)
        refresh()
    }

    public func removeScreen(_ dashboardId: String) throws {
        guard isRetainedSceneActivityAllowed() else { throw TransferFailure.interrupted }
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        try server.removeScreen(dashboardId)
        refresh()
    }

    public func removeAllScreens() throws {
        guard isRetainedSceneActivityAllowed() else { throw TransferFailure.interrupted }
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        try server.removeAllScreens()
        refresh()
    }

    @MainActor public func unlink() {
        guard isRetainedSceneActivityAllowed() else { return }
        do {
            try management.withAuthority {
                try ScreenPreferenceStore.shared.erase()
                try GoogleCalendarDeviceService.shared.erase()
            }
            try server?.unlink()
        }
        catch { errorMessage = "Could not remove saved device data. Unlock the device and try disconnecting again."; return }
        refresh()
    }

    public func refresh() {
        guard isRetainedSceneActivityAllowed() else { return }
        if let server {
            runtime = server.runtime
            completedPairingSessionNonceHex = server.completedPairingSessionNonceHex
            let pairingRequest = server.pendingPairingRequest
            pendingPairingRequest = pairingRequest
            pendingPairingSessionNonceHex = pairingRequest?.sessionNonceHex
            // `server.pairingCode` is the LAN pairing state of record; the
            // runtime session may outlive it and must not resurrect the code.
            pairingCode = pairingRequest?.code
            awaitingControllerConfirm = server.awaitingControllerConfirm
            port = server.port
            activePackage = server.activePackage
            screenSet = server.screenSet
            settingsSnapshot = server.settingsSnapshot
            genericConnectionGeneration = server.genericConnectionGeneration
            Task { @MainActor [weak self] in
                guard let self, !self.isRuntimeRetired else { return }; self.temporaryActivation?.update(active: self.foreground)
            }
        }
    }
}
#endif
