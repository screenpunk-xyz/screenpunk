import Foundation
import SwiftUI
import ScreenpunkCore

#if canImport(Network) && canImport(Security)
/// Owns the device TLS listener and publishes pairing/deploy state to SwiftUI.
public final class DeviceLANHost: ObservableObject {
    @Published public var runtime: DeviceRuntime
    @Published public var pairingCode: String?
    @Published public var port: UInt16 = 0
    @Published public var errorMessage: String?
    @Published public var activePackage: PackageAssetStore?
    public let server: DeviceLANServer?

    public init(runtime: DeviceRuntime) {
        if let identity = try? TLSIdentity.loadOrCreate(role: .device) {
            var runtime = runtime
            runtime.identity = identity.pairingIdentity
            self.runtime = runtime
            let server = DeviceLANServer(runtime: runtime, identity: identity)
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

    public func unlink() {
        server?.unlink()
        refresh()
    }

    public func refresh() {
        if let server {
            runtime = server.runtime
            pairingCode = server.pairingCode ?? server.runtime.pairingCode
            port = server.port
            activePackage = server.activePackage
        }
    }
}
#endif
