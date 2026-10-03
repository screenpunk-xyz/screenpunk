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
        server.onChange = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        server.onManagementSuspended = { [weak self] in self?.suspendManagement() }
    }

    private var isRuntimeRetired: Bool { lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return runtimeRetired }

    /// Terminal reset retirement is separate from ordinary backgrounding/management revocation.
    @MainActor public func retireForReset() {
        lifecycleLock.lock()
        guard !runtimeRetired else { lifecycleLock.unlock(); return }
        runtimeRetired = true; managementSuspended = true
        recoveryTimer?.cancel(); recoveryTimer = nil
        lifecycleLock.unlock()
        server?.retireForReset()
        foreground = false; temporaryActivation?.suspendForReset(); temporaryActivation = nil
        runtimeLifetime.retire()
    }

    private func suspendManagement() {
        lifecycleLock.lock()
        guard !managementSuspended else { lifecycleLock.unlock(); return }
        managementSuspended = true
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
        guard !isRuntimeRetired else { return }
        do { try management.validate() } catch { suspendManagement(); return }
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !managementSuspended, recoveryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: recoveryQueue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in self?.ensureListener() }
        recoveryTimer = timer
        timer.resume()
    }

    /// iOS may suspend network services in the background. Re-advertise on
    /// foreground entry even when the old listener still claims to be ready.
    public func resume() {
        guard !isRuntimeRetired else { return }
        start()
        recoveryQueue.async { [weak self] in
            guard let self, !self.isRuntimeRetired else { return }
            self.server?.stop()
            self.ensureListener()
        }
    }

    private func ensureListener() {
        lifecycleLock.lock(); let suspended = managementSuspended; lifecycleLock.unlock()
        guard !suspended, let server else { return }
        let result = Result { try server.start() }
        if case .failure(let error) = result, error is DeviceManagementAuthority.Failure { suspendManagement(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRuntimeRetired else { return }
            self.lifecycleLock.lock(); let suspended = self.managementSuspended; self.lifecycleLock.unlock()
            guard !suspended else { self.refresh(); return }
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
        guard !isRuntimeRetired else { return }
        do {
            try server?.confirmLocally(expectedSessionNonceHex: expectedSessionNonceHex)
            refresh()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func cancelPairing(expectedSessionNonceHex: String? = nil) {
        guard !isRuntimeRetired else { return }
        do {
            try server?.cancelPairing(expectedSessionNonceHex: expectedSessionNonceHex)
            errorMessage = nil; refresh()
        } catch { errorMessage = "Local management is unavailable." }
    }

    @MainActor public func advanceScreen(by offset: Int) {
        guard !isRuntimeRetired else { return }
        guard let set = screenSet, let index = set.screens.firstIndex(where: { $0.revision.dashboardId == set.selectedDashboardId }) else { return }
        guard let next = ScreenCarousel.index(from: index, offset: offset, count: set.screens.count) else { return }
        selectScreen(set.screens[next].revision.dashboardId)
    }

    @MainActor public func selectScreen(_ dashboardId: String) {
        guard !isRuntimeRetired else { return }
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
        guard !isRuntimeRetired else { throw DeviceManagementAuthority.Failure.staleLease }
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        let snapshot = try server.updateSettingsLocally(update)
        refresh()
        return snapshot
    }

    public func markSettingsApplied(revision: String) {
        guard !isRuntimeRetired else { return }
        guard settingsSnapshot?.revision == revision, settingsSnapshot?.isApplied == false else { return }
        do { try server?.markSettingsApplied(revision: revision); refresh() }
        catch { errorMessage = "Local management is unavailable." }
    }

    public func markSettingsUnapplied(revision: String) {
        guard !isRuntimeRetired else { return }
        guard settingsSnapshot?.revision == revision, settingsSnapshot?.isApplied == true else { return }
        do { try server?.markSettingsUnapplied(revision: revision); refresh() }
        catch { errorMessage = "Local management is unavailable." }
    }

    public func disconnect(keepScreens: Bool) throws {
        guard !isRuntimeRetired else { throw DeviceManagementAuthority.Failure.staleLease }
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        try server.disconnect(keepScreens: keepScreens)
        refresh()
    }

    public func removeScreen(_ dashboardId: String) throws {
        guard !isRuntimeRetired else { throw DeviceManagementAuthority.Failure.staleLease }
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        try server.removeScreen(dashboardId)
        refresh()
    }

    public func removeAllScreens() throws {
        guard !isRuntimeRetired else { throw DeviceManagementAuthority.Failure.staleLease }
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        try server.removeAllScreens()
        refresh()
    }

    @MainActor public func unlink() {
        guard !isRuntimeRetired else { return }
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
        guard !isRuntimeRetired else { return }
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
