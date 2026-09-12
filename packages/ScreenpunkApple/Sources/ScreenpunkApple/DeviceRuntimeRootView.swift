import SwiftUI
import ScreenpunkCore

/// iOS device: advertise over TLS 1.3, pair with one owner, then show the deployed dashboard.
public struct DeviceRuntimeRootView: View {
    @State private var fallback: DeviceRuntime
    @State private var confirmError: String?
#if canImport(Network) && canImport(Security)
    @StateObject private var host: DeviceLANHost
#endif

    public init(runtime: DeviceRuntime) {
        _fallback = State(initialValue: runtime)
#if canImport(Network) && canImport(Security)
        _host = StateObject(wrappedValue: DeviceLANHost(runtime: runtime))
#endif
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
#if canImport(Network) && canImport(Security)
            lanBody
                .onAppear { host.start() }
#else
            localBody
#endif
        }
    }

#if canImport(Network) && canImport(Security)
    private var lanBody: some View {
        Group {
            if let revision = host.runtime.activeRevision {
                deployedDashboard(revision: revision) {
                    host.unlink()
                }
            } else if let code = host.pairingCode {
                PairingCodeView(code: code) { host.confirm() }
                    .padding(24)
            } else {
                UnpairedHostView(detail: host.port == 0 ? nil : "TLS 1.3 · port \(host.port)")
            }
        }
        .overlay(alignment: .bottom) {
            if let confirmError = host.errorMessage {
                Text(confirmError)
                    .font(.footnote)
                    .padding()
            }
        }
    }

#endif

    private var localBody: some View {
        Group {
            if let revision = fallback.activeRevision {
                deployedDashboard(revision: revision) {
                    fallback.unlink()
                }
            } else if let code = fallback.pairingCode {
                PairingCodeView(code: code) {
                    do {
                        try fallback.confirmPairing(
                            code: code,
                            presentedOwner: fallback.pairing.session?.candidateOwner
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
    private func deployedDashboard(revision: String, onUnlink: @escaping () -> Void) -> some View {
        if revision == StoredRevision.offlineFixture.revision,
           let store = try? PackageAssetStore.bundledOfflineFixture()
        {
            DashboardRuntimeView(store: store, onUnlink: onUnlink)
                .ignoresSafeArea()
        } else {
            UnpairedHostView()
        }
    }
}
