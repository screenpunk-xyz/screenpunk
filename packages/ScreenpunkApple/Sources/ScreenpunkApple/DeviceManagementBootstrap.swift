import SwiftUI
import ScreenpunkCore

/// Startup admission only. Cloud transition writers remain disabled; this does
/// not enforce authority on later listener/request/reset operations.
@MainActor
public final class DeviceManagementBootstrap: ObservableObject {
    public enum State { case checking, localReady(DeviceLANHost), blocked(DeviceRetainedContentSnapshot) }
    @Published public private(set) var state: State = .checking
    private let authority: DeviceManagementAuthority
    private let retained: () -> DeviceRetainedContentSnapshot
    private let hostFactory: () throws -> DeviceLANHost

    public init(authority: DeviceManagementAuthority,
                retained: @escaping () -> DeviceRetainedContentSnapshot,
                hostFactory: @escaping () throws -> DeviceLANHost) {
        self.authority = authority; self.retained = retained; self.hostFactory = hostFactory
    }

    public convenience init() {
        let store = DeviceStateStore(root: DeviceStateStore.defaultRoot())
        self.init(authority: .init(journal: DeviceManagementTransitionStore(directory: DeviceManagementTransitionStore.defaultDirectory()),
                                  credentials: CloudInstallationCredentialStore()),
                  retained: { DeviceRetainedContentSnapshot.load(store: store) },
                  hostFactory: { DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), store: store) })
    }

    public func start() {
        if case .localReady = state { return }
        state = .checking
        do {
            guard let lease = try authority.refresh() else { state = .blocked(retained()); return }
            var host: DeviceLANHost?
            try authority.withLocalAuthority(lease) { host = try hostFactory() }
            guard let host, host.server != nil else { state = .blocked(retained()); return }
            state = .localReady(host)
        } catch { state = .blocked(retained()) }
    }
}
