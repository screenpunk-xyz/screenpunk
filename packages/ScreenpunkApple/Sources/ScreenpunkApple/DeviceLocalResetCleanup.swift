import Foundation
import ScreenpunkCore

/// Explicit v2 configuration only; never upgrades or rewrites v1 records.
struct DeviceLocalResetCleanupScope {
    let authorityScope: DeviceLocalResetScope
    let plan: DeviceLocalFilesystemCleanupPlan
    init(base: DeviceLocalResetScope, anchor: URL, maximumDepth: Int = 32, maximumEntries: Int = 10_000) throws {
        guard Set(base.credentialItems) == Set(DeviceLocalResetScope.allowedCredentialItems) else { throw DeviceLocalResetScope.Failure.invalidCredentialBinding }
        try base.validateCurrentPaths()
        plan = try .init(anchor: try DeviceLocalResetScope.canonical(anchor), roots: [
            .init(directory: base.deviceRoot, mode: .directoryContents),
            .init(directory: base.preferencesRoot, mode: .namedFiles(["preferences-v1.json"]))],
            protectedRoots: [base.managementDirectory, base.resetDirectory], maximumDepth: maximumDepth, maximumEntries: maximumEntries)
        authorityScope = try .init(v2: base, cleanupMetadata: plan.canonicalMetadata)
    }
}
protocol DeviceLocalResetCredentialCleanup {
    func delete(_ item: DeviceLocalResetScope.CredentialItem) throws
    func isAbsent(_ item: DeviceLocalResetScope.CredentialItem) throws -> Bool
}
struct DeviceLocalResetKeychainCleanup: DeviceLocalResetCredentialCleanup {
    func delete(_ item: DeviceLocalResetScope.CredentialItem) throws { try KeychainCredentialStore(service: item.service).delete(item.account) }
    func isAbsent(_ item: DeviceLocalResetScope.CredentialItem) throws -> Bool { try KeychainCredentialStore(service: item.service).secret(for: item.account) == nil }
}

/// No public raw execution API. Unknown legacy preference temporary files remain untouched.
@MainActor final class DeviceLocalResetCleanup {
    enum Failure: Error { case credentialStillPresent }
    private let scope: DeviceLocalResetCleanupScope
    private let credentials: any DeviceLocalResetCredentialCleanup
    init(scope: DeviceLocalResetCleanupScope, credentials: any DeviceLocalResetCredentialCleanup = DeviceLocalResetKeychainCleanup()) {
        self.scope = scope; self.credentials = credentials
    }
    func execute(_ permit: DeviceLocalResetCleanupPermit) throws {
        try scope.authorityScope.validateCurrentPaths()
        try DeviceLocalFilesystemCleanup(plan: scope.plan).execute(withDestructiveStep: { operation in
            try permit.withStep(scopeDigest: scope.authorityScope.digest, operation: operation)
        })
        for item in scope.authorityScope.credentialItems {
            try permit.withStep(scopeDigest: scope.authorityScope.digest) {
                try credentials.delete(item)
                guard try credentials.isAbsent(item) else { throw Failure.credentialStillPresent }
            }
        }
    }
}
