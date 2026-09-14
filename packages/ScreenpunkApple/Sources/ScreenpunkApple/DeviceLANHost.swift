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
    @Published public var screenSet: DeviceInstalledScreenSet?
    public let server: DeviceLANServer?

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
        do {
            try server?.start()
            port = server?.port ?? 0
            refresh()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func confirm() {
        do {
            try server?.confirmLocally()
            refresh()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func cancelPairing() {
        server?.cancelPairing()
        errorMessage = nil
        refresh()
    }

    public func advanceScreen(by offset: Int) {
        guard let set = screenSet, let index = set.screens.firstIndex(where: { $0.revision.dashboardId == set.selectedDashboardId }) else { return }
        guard let next = ScreenCarousel.index(from: index, offset: offset, count: set.screens.count) else { return }
        selectScreen(set.screens[next].revision.dashboardId)
    }

    public func selectScreen(_ dashboardId: String) {
        do {
            try server?.selectScreen(dashboardId)
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = "Could not switch screens. Try again."
        }
    }

    public func unlink() {
        server?.unlink()
        refresh()
    }

    public func refresh() {
        if let server {
            runtime = server.runtime
            // `server.pairingCode` is the LAN pairing state of record; the
            // runtime session may outlive it and must not resurrect the code.
            pairingCode = server.pairingCode
            awaitingControllerConfirm = server.awaitingControllerConfirm
            port = server.port
            activePackage = server.activePackage
            screenSet = server.screenSet
        }
    }
}
#endif
