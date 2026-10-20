import SwiftUI
import ScreenpunkCore

/// Serialized startup/recovery/reset; Cloud transition writers remain disabled.
@MainActor public final class DeviceManagementBootstrap: ObservableObject {
    public enum State { case checking, resetting, cloudReady, localReady(DeviceLANHost), blocked(DeviceRetainedContentSnapshot) }
    public struct StartupDiagnostic: Equatable {
        public enum Stage: String { case preparation, supportAnchor, namespace, resetConfiguration, resetRecovery, localHost }
        public let stage: Stage
        public let systemError: Int32?
        /// A retry rechecks the retained original owner; it does not clear data or
        /// promise to recover changed nodes or uncertain persistence.
        public let retryChecksOriginalStateOnly: Bool
    }
    @Published public private(set) var startupDiagnostic: StartupDiagnostic?
    @Published public private(set) var startupAttempt: UInt = 0
    @Published public private(set) var state: State = .checking
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var rootGeneration = UUID()
    @_spi(NativeInstallation) @Published public private(set) var cloudAuthorityGeneration: UUID?
    private var recordedNativeCloudStartup = false
    private var authority: DeviceManagementAuthority?
    /// Read-only access to the owner already retained by startup; never constructs one.
    @_spi(NativeInstallation) public var currentAuthority: DeviceManagementAuthority? { authority }
    @_spi(NativeInstallation) public var readyForRecordedNativeRestore: Bool {
        recordedNativeCloudStartup && cloudAuthorityGeneration != nil && authority != nil
    }
    /// Readiness to inspect a saved detachment only. Exact metadata, resources and
    /// the accepted Local context still have to qualify before a host can be admitted.
    @_spi(NativeInstallation) public var readyToValidateRecordedDetachedRestore: Bool {
        guard recordedNativeCloudStartup, task == nil, let authority,
            preparationFactory == nil || ownedRecoveryAuthority == ObjectIdentifier(authority) else { return false }
        switch state {
        case .cloudReady, .localReady: return true
        case .checking, .resetting, .blocked: return false
        }
    }
    @_spi(NativeInstallation) public func validateRecordedDetachedLocalStartup(commonRootID: UUID,
        retiredInstallationID: UUID) throws {
        guard readyToValidateRecordedDetachedRestore, let authority else { throw DeviceManagementAuthority.Failure.staleLease }
        try authority.validateRecordedDetachedLocalStartup(commonRootID: commonRootID, retiredInstallationID: retiredInstallationID)
    }
    /// Routing only. The app derives this choice from its validated marked intent;
    /// the native restorer must still qualify every root, journal and credential.
    @_spi(NativeInstallation) public func useRecordedNativeCloudStartup() {
        guard startupAttempt == 0, task == nil else { return }
        recordedNativeCloudStartup = true
    }
    /// Continues the same prepared owner after the app saved its genuine completed
    /// enrollment marker. Routing/readiness only; no installation is admitted here.
    @_spi(NativeInstallation) public func recordedNativeInstallationDidQualify(authority original: DeviceManagementAuthority) throws {
        guard authority === original, task == nil else { throw DeviceManagementAuthority.Failure.staleLease }
        try original.validateRecordedNativeStartup()
        recordedNativeCloudStartup = true
        if cloudAuthorityGeneration == nil { cloudAuthorityGeneration = UUID() }
    }
    private var lifecycle: DeviceLocalResetLifecycle?
    private var lifecycleFactory: (() throws -> DeviceLocalResetLifecycle)?
    private let retained: () -> DeviceRetainedContentSnapshot
    private let hostFactory: (DeviceManagementContext) throws -> DeviceLANHost
    private var context: DeviceManagementContext?
    private var task: Task<Void, Never>?
    private var needsHost = false
    private var ownedRecoveryAuthority: ObjectIdentifier?
    struct PreparedOwner {
        let authority: DeviceManagementAuthority
        let constructLifecycle: @MainActor () throws -> DeviceLocalResetLifecycle
    }
    private var preparationFactory: (() throws -> PreparedOwner)?
    private var ownedResetHandoff: @MainActor (DeviceOwnedFactoryResetReceipt) throws -> Void = {
        try DeviceLocalResetLifecycle.releaseCompletedOwnedProduction($0)
    }

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
                 ownedResetHandoff: @escaping @MainActor (DeviceOwnedFactoryResetReceipt) throws -> Void = { try DeviceLocalResetLifecycle.releaseCompletedOwnedProduction($0) },
                 retained: @escaping () -> DeviceRetainedContentSnapshot, hostFactory: @escaping (DeviceManagementContext) throws -> DeviceLANHost) {
        self.preparationFactory = preparationFactory; self.retained = retained; self.hostFactory = hostFactory
        self.ownedResetHandoff = ownedResetHandoff
    }
    public convenience init(concurrentControlQualified: Bool = false) {
        let store = DeviceStateStore(root: DeviceStateStore.defaultRoot())
        self.init(preparationFactory: {
            let prepared = try DeviceLocalResetLifecycle.prepareProduction(concurrentControlQualified: concurrentControlQualified)
            return PreparedOwner(authority: prepared.authority, constructLifecycle: { try prepared.construct() })
        },
                  retained: { DeviceRetainedContentSnapshot.load(store: store) },
                  hostFactory: { try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: $0, store: store) })
    }
    /// Installs the separately qualified common-control host. The caller attaches its sealed
    /// unified command receiver in prepare before publication or listener startup. A failed
    /// candidate is retired without changing the previously published host or root generation.
    /// Legacy structural admission is unavailable through this context.
    @_spi(NativeInstallation) public func installConcurrentHost(context: DeviceManagementContext,
        prepare: (DeviceLANHost) throws -> Void = { _ in }) throws -> DeviceLANHost {
        try context.validate()
        let host = try hostFactory(context)
        do {
            try context.validate()
            try prepare(host)
            try context.validate()
        } catch {
            host.retireForReset()
            throw error
        }
        if case .localReady(let old) = state { old.retireForReset() }
        self.context = context; state = .localReady(host); statusMessage = nil
        rootGeneration = UUID()
        return host
    }
    /// Only a receipt issued after the original owned cleanup can reopen startup.
    @_spi(NativeInstallation) public func completeOwnedFactoryReset(_ receipt: DeviceOwnedFactoryResetReceipt) async throws {
        guard preparationFactory != nil else { throw DeviceLocalResetLifecycle.Failure.binding }
        guard let originalAuthority = authority, receipt.belongs(to: originalAuthority) else { throw DeviceLocalResetLifecycle.Failure.binding }
        try receipt.validateCompletion()
        let pending = task
        pending?.cancel()
        if let pending { await pending.value }
        guard authority === originalAuthority, receipt.belongs(to: originalAuthority) else { throw DeviceLocalResetLifecycle.Failure.binding }
        try ownedResetHandoff(receipt)
        task = nil
        if case .localReady(let host) = state { host.retireForReset() }
        context = nil; lifecycle = nil; lifecycleFactory = nil; authority = nil
        cloudAuthorityGeneration = nil; recordedNativeCloudStartup = false
        ownedRecoveryAuthority = nil
        needsHost = false; startupDiagnostic = nil; state = .checking; statusMessage = nil
        rootGeneration = UUID()
        start()
    }
    public func start() {
        guard task == nil else { return }
        startupAttempt &+= 1
        startupDiagnostic = nil
        // A prepared native owner may already hold a Cloud generation. Repeating
        // support setup would revoke it; recheck the existing prepared nodes only.
        if recordedNativeCloudStartup, cloudAuthorityGeneration != nil, let authority {
            finishRecordedNativeStartup(authority)
            return
        }
        if authority == nil, let preparationFactory {
            do {
                let prepared = try preparationFactory()
                authority = prepared.authority; lifecycleFactory = { try prepared.constructLifecycle() }
            } catch {
                cloudAuthorityGeneration = nil
                recordDiagnostic(.preparation, error); state = recordedNativeCloudStartup ? .cloudReady : .blocked(.empty); statusMessage = "Device connection needs attention. Local management is blocked."; return
            }
        }
        if preparationFactory != nil {
            do {
                guard let authority else { throw DeviceManagementAuthority.Failure.staleLease }
                try authority.prepareProductionSupportAnchor()
            } catch {
                cloudAuthorityGeneration = nil
                recordDiagnostic(.supportAnchor, error); state = recordedNativeCloudStartup ? .cloudReady : .blocked(.empty); statusMessage = "Device connection needs attention. Local management is blocked."; return
            }
        }
        // Recover the original saved reset before partially removed installation
        // journals or inventories are asked to qualify ordinary startup.
        if preparationFactory != nil, let authority, ownedRecoveryAuthority != ObjectIdentifier(authority) {
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    if let preparation = try authority.recoverFactoryReset() {
                        self.cloudAuthorityGeneration = nil
                        if case .localReady(let host) = self.state { host.retireForReset() }
                        self.state = .resetting
                        let receipt = try await preparation.execute()
                        guard self.authority === authority, receipt.belongs(to: authority) else { throw DeviceLocalResetLifecycle.Failure.binding }
                        try receipt.validateCompletion()
                        try DeviceLocalResetLifecycle.releaseCompletedOwnedProduction(receipt)
                        self.context = nil; self.lifecycle = nil; self.lifecycleFactory = nil
                        self.authority = nil; self.ownedRecoveryAuthority = nil
                        self.recordedNativeCloudStartup = false
                        self.needsHost = false; self.state = .checking
                        self.rootGeneration = UUID()
                    } else {
                        self.ownedRecoveryAuthority = ObjectIdentifier(authority)
                    }
                    self.task = nil
                    self.cloudAuthorityGeneration = nil
                    self.start()
                } catch {
                    self.task = nil
                    self.recordDiagnostic(.resetRecovery, error)
                    self.state = .blocked(.empty)
                    self.statusMessage = "The original device reset needs recovery. Local management is blocked."
                }
            }
            return
        }
        if recordedNativeCloudStartup, let authority {
            finishRecordedNativeStartup(authority)
            return // Never run legacy absence admission against intended native roots.
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
                recordDiagnostic(.resetConfiguration, error)
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
                self.recordDiagnostic(.resetRecovery, error)
                self.statusMessage = "Saved reset recovery could not finish, or its scope does not match. Local management is blocked."
            }
        }
    }
    private func recordDiagnostic(_ stage: StartupDiagnostic.Stage, _ error: Error) {
        cloudAuthorityGeneration = nil
        let code: Int32?
        if let failure = error as? DeviceProductionSupportAnchorSetup.Failure, case .io(let value) = failure { code = value }
        else if let failure = error as? DeviceNativeManagedRootFailure, case .unavailable(let value) = failure { code = value }
        else { code = nil }
        startupDiagnostic = .init(stage: stage, systemError: code, retryChecksOriginalStateOnly: true)
    }
    private func finishRecordedNativeStartup(_ authority: DeviceManagementAuthority) {
        do {
            try authority.validateRecordedNativeStartup()
            if case .localReady = state { } else { state = .cloudReady }
            statusMessage = nil
            if cloudAuthorityGeneration == nil { cloudAuthorityGeneration = UUID() }
        } catch {
            cloudAuthorityGeneration = nil
            recordDiagnostic(.namespace, error)
            state = .cloudReady
            statusMessage = "The saved device connection needs attention. Open Cloud account to retry."
        }
    }
    public func retry() { start() }
    public var canResetBlockedLocalData: Bool {
        guard task == nil, lifecycle != nil, startupDiagnostic?.stage == .localHost,
              case .blocked = state, let authority, lifecycle?.authority === authority else { return false }
        return authority.blockedLocalResetEligible()
    }
    /// Call only after the UI's destructive scope confirmation. No new authority
    /// is constructed for a blocked device; early path/namespace failures refuse.
    public func requestBlockedLocalReset() {
        guard canResetBlockedLocalData, let lifecycle, let original = authority else { return }
        task = Task { [weak self] in
            guard let self else { return }; defer { self.task = nil }
            do {
                guard self.authority === original, lifecycle.authority === original,
                      original.blockedLocalResetEligible(), let lease = try original.refresh() else { throw DeviceManagementAuthority.Failure.staleLease }
                let management = DeviceManagementContext(authority: original, lease: lease)
                try management.validate()
                try await lifecycle.begin(context: management, resetID: UUID()) { [weak self] in self?.state = .resetting }
                self.context = nil; self.authority = lifecycle.authority; self.needsHost = true
                self.admit()
            } catch {
                self.context = nil; self.state = .blocked(.empty)
                self.recordDiagnostic(.resetRecovery, error)
                self.statusMessage = "Local reset could not finish. Saved data remains blocked until recovery succeeds."
            }
        }
    }
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
            recordDiagnostic(.namespace, error)
            statusMessage = "Device connection needs attention. Local management is blocked."
            return false
        }
    }
    private func admit() {
        // Recover the original saved reset before partially removed installation
        // journals or inventories are asked to qualify ordinary startup.
        if preparationFactory != nil, let authority, ownedRecoveryAuthority != ObjectIdentifier(authority) {
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    if let preparation = try authority.recoverFactoryReset() {
                        self.cloudAuthorityGeneration = nil
                        if case .localReady(let host) = self.state { host.retireForReset() }
                        self.state = .resetting
                        let receipt = try await preparation.execute()
                        guard self.authority === authority, receipt.belongs(to: authority) else { throw DeviceLocalResetLifecycle.Failure.binding }
                        try receipt.validateCompletion()
                        try DeviceLocalResetLifecycle.releaseCompletedOwnedProduction(receipt)
                        self.context = nil; self.lifecycle = nil; self.lifecycleFactory = nil
                        self.authority = nil; self.ownedRecoveryAuthority = nil
                        self.recordedNativeCloudStartup = false
                        self.needsHost = false; self.state = .checking
                        self.rootGeneration = UUID()
                    } else {
                        self.ownedRecoveryAuthority = ObjectIdentifier(authority)
                    }
                    self.task = nil
                    self.start()
                } catch {
                    self.task = nil
                    self.recordDiagnostic(.resetRecovery, error)
                    self.state = .blocked(.empty)
                    self.statusMessage = "The original device reset needs recovery. Local management is blocked."
                }
            }
            return
        }
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
            recordDiagnostic(.localHost, error)
            statusMessage = needsHost ? "Reset finished, but Local management could not start. Retry startup." : "Local management could not start."
        }
    }
}
