import SwiftUI
import ScreenpunkCore

/// iOS device: advertise, pair with one owner, then show the deployed dashboard.
public struct DeviceRuntimeRootView: View {
    @State private var runtime: DeviceRuntime
    @State private var confirmError: String?

    public init(runtime: DeviceRuntime) {
        _runtime = State(initialValue: runtime)
    }

    public static func unpairedLoopback() -> DeviceRuntimeRootView {
        let identity = PairingIdentityFactory.make(role: .device)
        let profile = DeviceProfile(deviceId: "phone-local", name: "This iPhone")
        let ad = AdvertisedDevice(
            deviceId: profile.deviceId,
            host: "127.0.0.1",
            port: 7843,
            source: .advertised
        )
        var runtime = DeviceRuntime(identity: identity, profile: profile, advertisement: ad)
        runtime.advertise(on: LoopbackDiscovery.shared)
        return DeviceRuntimeRootView(runtime: runtime)
    }

    public var body: some View {
        Group {
            if let revision = runtime.activeRevision {
                deployedDashboard(revision: revision)
            } else if let code = runtime.pairingCode {
                PairingCodeView(code: code) {
                    do {
                        try runtime.confirmPairing(
                            code: code,
                            presentedOwner: runtime.pairing.session?.candidateOwner
                                ?? PairingIdentityFactory.make(role: .controller),
                            clock: FixedClock(Date())
                        )
                        confirmError = nil
                    } catch {
                        confirmError = String(describing: error)
                    }
                }
                .padding(24)
            } else {
                UnpairedHostView()
            }
        }
        .overlay(alignment: .bottom) {
            if let confirmError {
                Text(confirmError)
                    .font(.footnote)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private func deployedDashboard(revision: String) -> some View {
        if revision == StoredRevision.offlineFixture.revision,
           let store = try? PackageAssetStore.bundledOfflineFixture()
        {
            DashboardRuntimeView(store: store) {
                runtime.unlink()
            }
            .ignoresSafeArea()
        } else {
            UnpairedHostView()
        }
    }
}
