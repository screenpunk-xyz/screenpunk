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
    private let recoveryQueue = DispatchQueue(label: "xyz.screenpunk.lan.recovery")
    private var recoveryTimer: DispatchSourceTimer?
    private var listenerError: String?
    private var temporaryActivation: DeviceTemporaryActivationRuntime?
    private var foreground = false

    @MainActor public func setForeground(_ active: Bool) {
        foreground = active
        if temporaryActivation == nil, let server { temporaryActivation = DeviceTemporaryActivationRuntime(server: server) }
        temporaryActivation?.update(active: active)
    }

    /// `store` defaults to the per-user device home so pairing and the active
    /// package survive a relaunch. Tests pass a temporary store.
    public init(runtime: DeviceRuntime, store: DeviceStateStore? = nil) {
        if let identity = try? TLSIdentity.loadOrCreate(role: .device) {
            var runtime = runtime
            runtime.identity = identity.pairingIdentity
            let server = DeviceLANServer(
                runtime: runtime,
                identity: identity,
                store: store ?? DeviceStateStore(root: DeviceStateStore.defaultRoot())
            )
            self.runtime = server.runtime
            self.activePackage = server.activePackage
            self.screenSet = server.screenSet
            self.settingsSnapshot = server.settingsSnapshot
            self.server = server
            server.onChange = { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
        } else {
            self.runtime = runtime
            self.server = nil
            self.errorMessage = "tls-identity-failed"
        }
    }

    public func start() {
        guard recoveryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: recoveryQueue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in self?.ensureListener() }
        recoveryTimer = timer
        timer.resume()
    }

    /// iOS may suspend network services in the background. Re-advertise on
    /// foreground entry even when the old listener still claims to be ready.
    public func resume() {
        start()
        recoveryQueue.async { [weak self] in
            self?.server?.stop()
            self?.ensureListener()
        }
    }

    private func ensureListener() {
        guard let server else { return }
        let result = Result { try server.start() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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
        do {
            try server?.confirmLocally(expectedSessionNonceHex: expectedSessionNonceHex)
            refresh()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func cancelPairing(expectedSessionNonceHex: String? = nil) {
        server?.cancelPairing(expectedSessionNonceHex: expectedSessionNonceHex)
        errorMessage = nil
        refresh()
    }

    @MainActor public func advanceScreen(by offset: Int) {
        guard let set = screenSet, let index = set.screens.firstIndex(where: { $0.revision.dashboardId == set.selectedDashboardId }) else { return }
        guard let next = ScreenCarousel.index(from: index, offset: offset, count: set.screens.count) else { return }
        selectScreen(set.screens[next].revision.dashboardId)
    }

    @MainActor public func selectScreen(_ dashboardId: String) {
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
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        let snapshot = try server.updateSettingsLocally(update)
        refresh()
        return snapshot
    }

    public func markSettingsApplied(revision: String) {
        guard settingsSnapshot?.revision == revision, settingsSnapshot?.isApplied == false else { return }
        server?.markSettingsApplied(revision: revision)
        refresh()
    }

    public func markSettingsUnapplied(revision: String) {
        guard settingsSnapshot?.revision == revision, settingsSnapshot?.isApplied == true else { return }
        server?.markSettingsUnapplied(revision: revision)
        refresh()
    }

    public func disconnect(keepScreens: Bool) throws {
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        try server.disconnect(keepScreens: keepScreens)
        refresh()
    }

    public func removeScreen(_ dashboardId: String) throws {
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        try server.removeScreen(dashboardId)
        refresh()
    }

    public func removeAllScreens() throws {
        guard let server else { throw DeviceSettingsFailure.persistenceFailed }
        try server.removeAllScreens()
        refresh()
    }

    @MainActor public func unlink() {
        do {
            try ScreenPreferenceStore.shared.erase()
            try GoogleCalendarDeviceService.shared.erase()
        }
        catch { errorMessage = "Could not remove saved device data. Unlock the device and try disconnecting again."; return }
        server?.unlink()
        refresh()
    }

    public func refresh() {
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
                guard let self else { return }; self.temporaryActivation?.update(active: self.foreground)
            }
        }
    }
}
#endif
