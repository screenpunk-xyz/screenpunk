import Foundation
import ScreenpunkCore

/// One serialized Local-reset owner. Cloud transition writers remain disabled.
@MainActor final class DeviceLocalResetLifecycle {
    enum Failure: Error { case busy, binding, validationRejected, recoveryBlocked }
    let scope: DeviceLocalResetScope
    private(set) var authority: DeviceManagementAuthority
    private(set) var resetCompleted = false
    private let authorityFactory: () -> DeviceManagementAuthority
    private let cleanup: DeviceLocalResetCleanup
    private let provider: DeviceLocalResetWriterProvider
    private var domains: DeviceLocalResetWriterDomains
    private var coordinator: DeviceLocalResetCoordinator?
    private var host: DeviceLANHost?
    private var hostContext: DeviceManagementContext?
    private var busy = false
    private var retiredResetID: UUID?
    private var progress: (() -> Void)?
    private var completionFinalized = false
    private var writersFenced = false
    private static var productionOwner: DeviceLocalResetLifecycle?

    init(scope: DeviceLocalResetCleanupScope, authorityFactory: @escaping () -> DeviceManagementAuthority,
         provider: DeviceLocalResetWriterProvider, cleanup: DeviceLocalResetCleanup) throws {
        self.scope = scope.authorityScope; self.authorityFactory = authorityFactory
        authority = authorityFactory(); self.provider = provider; self.cleanup = cleanup
        domains = try .init(scope: scope.authorityScope, provider: provider)
    }
    static func production() throws -> DeviceLocalResetLifecycle {
        if let productionOwner { return productionOwner }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = DeviceLocalResetStore.defaultDirectory()
        let base = try DeviceLocalResetScope(deviceRoot: DeviceStateStore.defaultRoot(), preferencesRoot: support.appendingPathComponent("xyz.screenpunk.preferences"), managementDirectory: DeviceManagementTransitionStore.defaultDirectory(), resetDirectory: directory, credentialItems: DeviceLocalResetScope.allowedCredentialItems)
        let configured = try DeviceLocalResetCleanupScope(v3: base, anchor: support)
        let evidence = DeviceLocalResetEvidenceAdapter(scope: configured.authorityScope, store: .init(directory: directory))
        let journal = DeviceManagementTransitionStore(directory: base.managementDirectory)
        let credentials = CloudInstallationCredentialStore()
        let owner = try DeviceLocalResetLifecycle(scope: configured, authorityFactory: { .init(journal: journal, credentials: credentials, reset: evidence) }, provider: .production, cleanup: .init(scope: configured))
        productionOwner = owner; return owner
    }
    func admittedHost() -> (DeviceLANHost, DeviceManagementContext)? {
        guard let host, let context = hostContext else { return nil }
        if !host.lifetime.isRetired, (try? context.validate()) != nil { return (host, context) }
        host.retireForReset(); self.host = nil; hostContext = nil
        return nil
    }
    func attach(_ host: DeviceLANHost, context: DeviceManagementContext) throws {
        try context.validate()
        guard context.belongs(to: authority) else { throw Failure.binding }
        guard !busy, self.host == nil || self.host === host,
              let root = host.server?.store?.root,
              try DeviceLocalResetScope.canonical(root) == scope.deviceRoot else { throw Failure.binding }
        self.host = host; hostContext = context
    }
    private func prepareCoordinator() throws -> DeviceLocalResetCoordinator {
        if let coordinator { return coordinator }
        let created = try DeviceLocalResetCoordinator(scope: scope, authority: authority, retireWriters: { [weak self] record in
            guard let self else { throw Failure.recoveryBlocked }
            return try self.retire(record)
        }, receiptCleanup: { [weak self] permit in
            guard let self, self.retiredResetID == permit.resetID,
                  self.host == nil || self.host?.lifetime.isRetired == true else { throw Failure.recoveryBlocked }
            try permit.withStep(scopeDigest: self.scope.digest) {
                try DeviceLocalResetLegacyCloudGuard.requireAbsent(deviceRoot: self.scope.deviceRoot)
            }
            return try self.cleanup.execute(permit)
        })
        coordinator = created; return created
    }
    private func retire(_ record: DeviceLocalResetRecord) throws -> DeviceLocalResetWriterRetirement {
        host?.retireForReset(); progress?()
        writersFenced = true
        let evidence = try domains.retireForReset()
        guard evidence.scopeDigest == scope.digest, host == nil || host?.lifetime.isRetired == true else { throw Failure.binding }
        retiredResetID = record.resetID; return evidence
    }
    /// Unknown outcomes retire concrete writer instances without asserting cleanup eligibility.
    private func fenceUnknown() {
        host?.retireForReset()
        domains.calendar.suspendForReset(); domains.preferences.suspendForReset()
        writersFenced = true
        progress?()
    }
    func recover(progress: @escaping () -> Void) async throws {
        guard !busy else { throw Failure.busy }; busy = true; self.progress = progress
        defer { busy = false; self.progress = nil }
        do {
            let driver = try prepareCoordinator()
            if case .completed = driver.state, driver.reopeningCapability != nil { } else { try await driver.recover() }
            try finish(driver)
        } catch { fenceUnknown(); throw error }
    }
    func begin(context: DeviceManagementContext, resetID: UUID, progress: @escaping () -> Void) async throws {
        guard !busy else { throw Failure.busy }
        do { try context.validate() } catch {
            switch try? authority.resetRecoverySnapshot() {
            case .absent?, .completed?: throw Failure.validationRejected
            default: fenceUnknown(); throw error
            }
        }
        busy = true; self.progress = progress
        defer { busy = false; self.progress = nil }
        resetCompleted = false
        do {
            let driver = try prepareCoordinator()
            try await driver.begin(context: context, resetID: resetID)
            try finish(driver)
        } catch {
            if case .failed(nil, .intent) = coordinator?.state,
               (try? authority.resetRecoverySnapshot()) == .absent { throw Failure.validationRejected }
            fenceUnknown(); throw error
        }
    }
    private func finish(_ driver: DeviceLocalResetCoordinator) throws {
        guard case .completed = driver.state else {
            guard !writersFenced else { throw Failure.recoveryBlocked }
            return
        }
        if !completionFinalized {
            if let capability = driver.reopeningCapability { try domains.open(capability) }
            else if writersFenced { throw Failure.recoveryBlocked }
            writersFenced = false
            completionFinalized = true; resetCompleted = true
            authority = authorityFactory(); host = nil; hostContext = nil
        }
    }
    /// Rotation occurs after completion, before constructing a replacement host; failed host
    /// construction retries only admission and never consumes the reopening capability again.
    func prepareNextReset() throws {
        guard completionFinalized, !busy else { return }
        guard !writersFenced else { throw Failure.recoveryBlocked }
        domains = try .init(scope: scope, provider: provider)
        coordinator = nil; retiredResetID = nil; completionFinalized = false
    }
}
