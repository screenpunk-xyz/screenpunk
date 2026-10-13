import Foundation
@_spi(NativeInstallation) import ScreenpunkCore

/// One serialized Local-reset owner. Cloud transition writers remain disabled.
@MainActor final class DeviceLocalResetLifecycle {
    enum Failure: Error { case busy, binding, validationRejected, recoveryBlocked }
    let scope: DeviceLocalResetScope
    private let ownedManifest: DeviceFactoryResetManifest?
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
    private var ownedCompletionReceipt: DeviceOwnedFactoryResetReceipt?
    private static var productionOwner: DeviceLocalResetLifecycle?
    private static var productionPreparation: ProductionPreparation?
    // Exact pending reset only: the coordinator retains the original retirement
    // callbacks across same-process recovery, so its writer bundle must stay paired.
    private struct PendingOwnedWriters {
        let scopeDigest: String
        let provider: DeviceLocalResetWriterProvider
        let domains: DeviceLocalResetWriterDomains
    }
    private static var pendingOwnedWriters: [UUID: PendingOwnedWriters] = [:]
    @MainActor struct ProductionPreparation {
        let authority: DeviceManagementAuthority
        fileprivate let configured: DeviceLocalResetCleanupScope
        fileprivate let authorityFactory: () -> DeviceManagementAuthority
        func construct() throws -> DeviceLocalResetLifecycle {
            if configured.ownedManifest == nil { try authority.requireLegacyNamespaceAbsent() }
            if let owner = DeviceLocalResetLifecycle.productionOwner {
                if configured.ownedManifest == nil { try owner.authority.requireLegacyNamespaceAbsent() }; return owner
            }
            var initial: DeviceManagementAuthority? = authority
            let owner = try DeviceLocalResetLifecycle(scope: configured, authorityFactory: {
                if let first = initial { initial = nil; return first }
                return authorityFactory()
            }, provider: .production, cleanup: .init(scope: configured))
            DeviceLocalResetLifecycle.productionOwner = owner
            return owner
        }
    }
    static func prepareProduction(concurrentControlQualified: Bool = false) throws -> ProductionPreparation {
        if let prepared = productionPreparation {
            if let owner = productionOwner { return .init(authority: owner.authority, configured: prepared.configured, authorityFactory: prepared.authorityFactory) }
            return prepared
        }
        // Pure configuration only: no writer domains, reset execution, host or TLS.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = DeviceLocalResetStore.defaultDirectory()
        let base = try DeviceLocalResetScope(deviceRoot: DeviceStateStore.defaultRoot(), preferencesRoot: support.appendingPathComponent("xyz.screenpunk.preferences"), managementDirectory: DeviceManagementTransitionStore.defaultDirectory(), resetDirectory: directory, credentialItems: DeviceLocalResetScope.allowedCredentialItems)
        let store = DeviceLocalResetStore(directory: directory)
        let configured = try restoredProductionScope(base: base, anchor: support, store: store)
        let evidence = DeviceLocalResetEvidenceAdapter(owned: configured.authorityScope, base: base, store: store)
        let journal = DeviceManagementTransitionStore(directory: base.managementDirectory)
        let credentials = CloudInstallationCredentialStore()
        let commandRoot = base.deviceRoot.appendingPathComponent("command-intents", isDirectory: true)
        let factory = { DeviceManagementAuthority(journal: journal, credentials: credentials, reset: evidence,
            commandIntents: DeviceCommandIntentCoordinator(root: commandRoot), concurrentControlQualified: concurrentControlQualified) }
        let prepared = ProductionPreparation(authority: factory(), configured: configured, authorityFactory: factory)
        productionPreparation = prepared
        return prepared
    }

    /// Reconstructs only the exact sidecar selected by the original reset journal.
    /// A missing v4 sidecar cannot reinterpret a pending record as a Local reset.
    static func restoredProductionScope(base: DeviceLocalResetScope, anchor: URL,
        store: DeviceLocalResetStore) throws -> DeviceLocalResetCleanupScope {
        let legacy = try DeviceLocalResetCleanupScope(v3: base, anchor: anchor)
        guard let record = try store.load() else { return legacy }
        if record.scopeDigest == legacy.authorityScope.digest { return legacy }
        guard let manifest = try DeviceFactoryResetManifestStore(directory: base.resetDirectory).load(resetID: record.resetID),
            manifest.baseScopeDigest == base.digest else { throw Failure.recoveryBlocked }
        let restored = try DeviceLocalResetCleanupScope(v4: base, anchor: anchor, manifest: manifest)
        guard restored.authorityScope.digest == record.scopeDigest else { throw Failure.recoveryBlocked }
        return restored
    }

    init(scope: DeviceLocalResetCleanupScope, authorityFactory: @escaping () -> DeviceManagementAuthority,
         provider: DeviceLocalResetWriterProvider, cleanup: DeviceLocalResetCleanup) throws {
        self.scope = scope.authorityScope; self.ownedManifest = scope.ownedManifest; self.authorityFactory = authorityFactory
        authority = authorityFactory(); self.provider = provider; self.cleanup = cleanup
        if ownedManifest == nil { try authority.requireLegacyNamespaceAbsent() }
        if ownedManifest != nil, case .pending(let original) = try authority.resetRecoverySnapshot(),
           original.scopeDigest == self.scope.digest,
           let retained = Self.pendingOwnedWriters[original.resetID] {
            guard retained.scopeDigest == self.scope.digest, retained.provider === provider else { throw Failure.binding }
            domains = retained.domains
        } else {
            domains = try .init(scope: scope.authorityScope, provider: provider)
        }
    }
    static func production() throws -> DeviceLocalResetLifecycle { try prepareProduction().construct() }
    static func releaseCompletedOwnedProduction(_ receipt: DeviceOwnedFactoryResetReceipt) throws {
        guard productionOwner?.busy != true else { throw Failure.recoveryBlocked }
        if let owner = productionOwner {
            guard receipt.belongs(to: owner.authority) else { throw Failure.binding }
        }
        if let prepared = productionPreparation {
            guard receipt.belongs(to: prepared.authority) else { throw Failure.binding }
        }
        try receipt.consumeHandoff()
        productionOwner?.host?.retireForReset()
        productionOwner = nil; productionPreparation = nil
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
            if self.ownedManifest == nil {
                try permit.withStep(scopeDigest: self.scope.digest) {
                    try DeviceLocalResetLegacyCloudGuard.requireAbsent(deviceRoot: self.scope.deviceRoot)
                }
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
        if ownedManifest != nil {
            if let original = Self.pendingOwnedWriters[record.resetID] {
                guard original.scopeDigest == scope.digest, original.provider === provider, original.domains === domains else { throw Failure.binding }
            } else {
                Self.pendingOwnedWriters[record.resetID] = .init(scopeDigest: scope.digest, provider: provider, domains: domains)
            }
        }
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
        if ownedManifest == nil { try authority.requireLegacyNamespaceAbsent() }
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
        if ownedManifest == nil { try authority.requireLegacyNamespaceAbsent() }
        guard case .completed(let completed) = driver.state else {
            guard !writersFenced else { throw Failure.recoveryBlocked }
            return
        }
        if !completionFinalized {
            if ownedManifest != nil {
                // Consume the genuine completed capability once to install fresh
                // writer instances. Old calendar/preferences handles stay retired.
                guard let capability = driver.reopeningCapability else { throw Failure.recoveryBlocked }
                try domains.open(capability)
                if Self.pendingOwnedWriters[completed.resetID]?.domains === domains {
                    Self.pendingOwnedWriters.removeValue(forKey: completed.resetID)
                }
                writersFenced = false
                completionFinalized = true; resetCompleted = true
                host = nil; hostContext = nil
                return
            }
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
        try authority.requireLegacyNamespaceAbsent()
        guard completionFinalized, !busy else { return }
        guard !writersFenced else { throw Failure.recoveryBlocked }
        domains = try .init(scope: scope, provider: provider)
        coordinator = nil; retiredResetID = nil; completionFinalized = false
    }
}

/// Holds one original, durably identified reset. No public constructor or
/// caller-supplied path/credential list can mint this operation.
@_spi(NativeInstallation) @MainActor public final class DeviceOwnedFactoryResetPreparation {
    public let resetID: UUID
    public let scopeDigest: String
    private let lifecycle: DeviceLocalResetLifecycle
    private let context: DeviceManagementContext?
    init(resetID: UUID, lifecycle: DeviceLocalResetLifecycle, context: DeviceManagementContext?) {
        self.resetID = resetID; self.scopeDigest = lifecycle.scope.digest; self.lifecycle = lifecycle; self.context = context
    }
    public func execute() async throws -> DeviceOwnedFactoryResetReceipt {
        if let context { try await lifecycle.begin(context: context, resetID: resetID, progress: {}) }
        else { try await lifecycle.recover(progress: {}) }
        return try lifecycle.ownedFactoryResetReceipt(resetID: resetID)
    }
}

/// A completion assertion tied to the original owner and durable scope. The app
/// must validate it before replacing the device authority or its presentation.
@_spi(NativeInstallation) @MainActor public final class DeviceOwnedFactoryResetReceipt {
    public let resetID: UUID
    public let scopeDigest: String
    private let validate: () throws -> Void
    private let originalAuthority: DeviceManagementAuthority
    private var consumed = false
    fileprivate init(resetID: UUID, scopeDigest: String, authority: DeviceManagementAuthority, validate: @escaping () throws -> Void) {
        self.resetID = resetID; self.scopeDigest = scopeDigest; self.originalAuthority = authority; self.validate = validate
    }
    func belongs(to authority: DeviceManagementAuthority) -> Bool { originalAuthority === authority }
    public func validateCompletion() throws {
        guard !consumed else { throw DeviceLocalResetLifecycle.Failure.recoveryBlocked }
        try validate()
    }
    func consumeHandoff() throws {
        try validateCompletion()
        consumed = true
    }
}

extension DeviceLocalResetLifecycle {
    fileprivate func ownedFactoryResetReceipt(resetID: UUID) throws -> DeviceOwnedFactoryResetReceipt {
        if let existing = ownedCompletionReceipt {
            guard existing.resetID == resetID else { throw Failure.recoveryBlocked }
            return existing
        }
        guard case .completed(let record) = try authority.resetRecoverySnapshot(),
            record.resetID == resetID, record.scopeDigest == scope.digest, resetCompleted else { throw Failure.recoveryBlocked }
        try cleanup.validateOwnedCompletion()
        let validateOwner = try authority.ownedFactoryResetCompletionValidation(record)
        let original = authority; let completedCleanup = cleanup
        let receipt = DeviceOwnedFactoryResetReceipt(resetID: resetID, scopeDigest: scope.digest, authority: original) {
            guard case .completed(let completed) = try original.resetRecoverySnapshot(), completed == record else { throw Failure.recoveryBlocked }
            try validateOwner()
            try completedCleanup.validateOwnedCompletion()
        }
        ownedCompletionReceipt = receipt
        return receipt
    }
}

/// Historical completion identity for the exact pre-recorded App retirement
/// sidecar. It cannot authorize a host handoff or filesystem cleanup.
@_spi(NativeInstallation) @MainActor public final class DeviceOwnedFactoryResetCompletionIdentity {
    public let resetID: UUID
    public let scopeDigest: String
    private let validate: () throws -> Void
    init(resetID: UUID, scopeDigest: String, validate: @escaping () throws -> Void) {
        self.resetID = resetID; self.scopeDigest = scopeDigest; self.validate = validate
    }
    public func validateCompletion() throws { try validate() }
}
