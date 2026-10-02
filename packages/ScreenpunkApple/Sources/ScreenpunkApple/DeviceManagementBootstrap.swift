import SwiftUI
import ScreenpunkCore

/// Creates management hosts with captured admission. Cloud transition writers remain disabled.
@MainActor
public final class DeviceManagementBootstrap: ObservableObject {
    public enum State { case checking, localReady(DeviceLANHost), blocked(DeviceRetainedContentSnapshot) }
    @Published public private(set) var state: State = .checking
    private let authority: DeviceManagementAuthority
    private let retained: () -> DeviceRetainedContentSnapshot
    private let hostFactory: (DeviceManagementContext) throws -> DeviceLANHost

    public init(authority: DeviceManagementAuthority,
                retained: @escaping () -> DeviceRetainedContentSnapshot,
                hostFactory: @escaping (DeviceManagementContext) throws -> DeviceLANHost) {
        self.authority = authority; self.retained = retained; self.hostFactory = hostFactory
    }

    public convenience init() {
        let store = DeviceStateStore(root: DeviceStateStore.defaultRoot())
        self.init(authority: .init(journal: DeviceManagementTransitionStore(directory: DeviceManagementTransitionStore.defaultDirectory()),
                                  credentials: CloudInstallationCredentialStore()),
                  retained: { DeviceRetainedContentSnapshot.load(store: store) },
                  hostFactory: { try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: $0, store: store) })
    }

    public func start() {
        if case .localReady = state { return }
        state = .checking
        do {
            guard let lease = try authority.refresh() else { state = .blocked(retained()); return }
            let management = DeviceManagementContext(authority: authority, lease: lease)
            try management.validate()
            let host = try hostFactory(management)
            try management.validate()
            guard host.server != nil else { state = .blocked(retained()); return }
            state = .localReady(host)
        } catch { state = .blocked(retained()) }
    }
}
