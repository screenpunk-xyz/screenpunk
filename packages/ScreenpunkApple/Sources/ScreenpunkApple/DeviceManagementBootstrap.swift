import SwiftUI
import ScreenpunkCore

/// Serialized startup/recovery/reset; Cloud transition writers remain disabled.
@MainActor public final class DeviceManagementBootstrap: ObservableObject {
    public enum State { case checking, resetting, localReady(DeviceLANHost), blocked(DeviceRetainedContentSnapshot) }
    @Published public private(set) var state: State = .checking
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var rootGeneration = UUID()
    private var authority: DeviceManagementAuthority?
    /// Read-only access to the owner already retained by startup; never constructs one.
    @_spi(NativeInstallation) public var currentAuthority: DeviceManagementAuthority? { authority }
    private var lifecycle: DeviceLocalResetLifecycle?
    private var lifecycleFactory: (() throws -> DeviceLocalResetLifecycle)?
    private let retained: () -> DeviceRetainedContentSnapshot
    private let hostFactory: (DeviceManagementContext) throws -> DeviceLANHost
    private var context: DeviceManagementContext?
    private var task: Task<Void, Never>?
    private var needsHost = false
    struct PreparedOwner {
        let authority: DeviceManagementAuthority
        let constructLifecycle: @MainActor () throws -> DeviceLocalResetLifecycle
    }
    private var preparationFactory: (() throws -> PreparedOwner)?

    public init(authority: DeviceManagementAuthority, retained: @escaping () -> DeviceRetainedContentSnapshot,
                hostFactory: @escaping (DeviceManagementContext) throws -> DeviceLANHost) {
        self.authority = authority; self.retained = retained; self.hostFactory = hostFactory
        lifecycle = nil; lifecycleFactory = nil
    }
    init(lifecycle: DeviceLocalResetLifecycle, retained: @escaping () -> DeviceRetainedContentSnapshot,
         hostFactory: @escaping (DeviceManagementContext) throws -> DeviceLANHost) {
        self.lifecycle = lifecycle; authority = lifecycle.authority; self.retained = retained
        self.hostFactory = hostFactory; lifecycleFactory = nil
    }
    init(authority: DeviceManagementAuthority, lifecycleFactory: @escaping () throws -> DeviceLocalResetLifecycle,
         retained: @escaping () -> DeviceRetainedContentSnapshot,
         hostFactory: @escaping (DeviceManagementContext) throws -> DeviceLANHost) {
        self.authority = authority; self.lifecycleFactory = lifecycleFactory; self.retained = retained; self.hostFactory = hostFactory
    }
    init(preparationFactory: @escaping () throws -> PreparedOwner,
                 retained: @escaping () -> DeviceRetainedContentSnapshot, hostFactory: @escaping (DeviceManagementContext) throws -> DeviceLANHost) {
        self.preparationFactory = preparationFactory; self.retained = retained; self.hostFactory = hostFactory
    }
    public convenience init() {
        let store = DeviceStateStore(root: DeviceStateStore.defaultRoot())
        self.init(preparationFactory: {
            let prepared = try DeviceLocalResetLifecycle.prepareProduction()
            return PreparedOwner(authority: prepared.authority, constructLifecycle: { try prepared.construct() })
        },
                  retained: { DeviceRetainedContentSnapshot.load(store: store) },
                  hostFactory: { try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: $0, store: store) })
    }
    public func start() {
        guard task == nil else { return }
        if authority == nil, let preparationFactory {
            do {
                let prepared = try preparationFactory()
                authority = prepared.authority; lifecycleFactory = { try prepared.constructLifecycle() }
            } catch {
                state = .blocked(.empty); statusMessage = "Device connection needs attention. Local management is blocked."; return
            }
        }
        if preparationFactory != nil {
            do {
                guard let authority else { throw DeviceManagementAuthority.Failure.staleLease }
                try authority.prepareProductionSupportAnchor()
            } catch {
                state = .blocked(.empty); statusMessage = "Device connection needs attention. Local management is blocked."; return
            }
        }
        guard checkManagedNamespace() else { return }
        if lifecycle == nil, let lifecycleFactory {
            do {
                let candidate = try lifecycleFactory()
                guard candidate.authority === authority else { throw DeviceLocalResetLifecycle.Failure.binding }
                lifecycle = candidate
            }
            catch {
                state = .blocked(.empty)
                statusMessage = "Saved reset configuration is unavailable. Local management is blocked."
                return
            }
        }
        if case .localReady(let host) = state, !host.lifetime.isRetired {
            do { guard let context else { throw DeviceManagementAuthority.Failure.staleLease }; try context.validate(); return } catch { host.retireForReset(); context = nil }
        }
        if let (host, management) = lifecycle?.admittedHost() {
            authority = lifecycle?.authority; context = management
            rootGeneration = UUID(); state = .localReady(host); statusMessage = nil
            return
        }
        if lifecycle == nil { admit(); return }
        task = Task { [weak self] in
            guard let self else { return }; defer { self.task = nil }
            self.state = .checking; self.statusMessage = nil
            do {
                if !self.needsHost, let lifecycle = self.lifecycle {
                    try await lifecycle.recover { [weak self] in self?.state = .resetting }
                    self.authority = lifecycle.authority; self.needsHost = lifecycle.resetCompleted
                }
                self.admit()
            } catch {
                self.state = .blocked(.empty)
                self.statusMessage = "Saved reset recovery could not finish, or its scope does not match. Local management is blocked."
            }
        }
    }
    public func retry() { start() }
    public func requestLocalReset() {
        guard task == nil, let lifecycle, let context, case .localReady(let oldHost) = state else { return }
        task = Task { [weak self] in
            guard let self else { return }; defer { self.task = nil }
            do {
                try await lifecycle.begin(context: context, resetID: UUID()) { [weak self] in self?.state = .resetting }
                self.context = nil; self.authority = lifecycle.authority; self.needsHost = true
                self.admit()
            } catch DeviceLocalResetLifecycle.Failure.validationRejected {
                oldHost.retireForReset()
                self.context = nil; self.state = .blocked(.empty)
                self.statusMessage = "Reset was not started because Local authority changed. Retry admission."
            } catch {
                self.context = nil; self.state = .blocked(.empty)
                self.statusMessage = "Reset could not finish. Saved data remains blocked until recovery succeeds."
            }
        }
    }
    private func checkManagedNamespace() -> Bool {
        do {
            guard let authority else { throw DeviceManagementAuthority.Failure.staleLease }
            try authority.requireLegacyNamespaceAbsent()
            return true
        } catch {
            if case .localReady(let host) = state { host.retireForReset() }
            context = nil; state = .blocked(.empty)
            statusMessage = "Device connection needs attention. Local management is blocked."
            return false
        }
    }
    private func admit() {
        guard checkManagedNamespace() else { return }
        state = .checking
        do {
            if let (host, management) = lifecycle?.admittedHost() {
                context = management; state = .localReady(host); statusMessage = nil; return
            }
            try lifecycle?.prepareNextReset()
            guard let authority, let lease = try authority.refresh() else {
                state = .blocked(authority?.resetRenderingAllowed() == true && !needsHost ? retained() : .empty); return
            }
            let management = DeviceManagementContext(authority: authority, lease: lease)
            try management.validate()
            let host = try hostFactory(management)
            do {
                try management.validate(); try lifecycle?.attach(host, context: management)
                guard host.server != nil else { throw DeviceLocalResetLifecycle.Failure.binding }
            } catch { host.retireForReset(); throw error }
            context = management; rootGeneration = UUID(); state = .localReady(host); statusMessage = nil
            needsHost = false
        } catch {
            state = .blocked(needsHost ? .empty : (authority?.resetRenderingAllowed() == true ? retained() : .empty))
            statusMessage = needsHost ? "Reset finished, but Local management could not start. Retry startup." : "Local management could not start."
        }
    }
}
