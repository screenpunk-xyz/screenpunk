import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif
@_spi(NativeFilesystem) @_spi(NativeInstallation) import ScreenpunkCore
#if canImport(Security)
import Security
#endif

/// Explicit v2 configuration only; never upgrades or rewrites v1 records.
struct DeviceLocalResetCleanupScope {
    let authorityScope: DeviceLocalResetScope
    let plan: DeviceLocalFilesystemCleanupPlan
    let ownedManifest: DeviceFactoryResetManifest?
    let emptyContainers: [DeviceLocalFilesystemCleanupPlan]
    init(base: DeviceLocalResetScope, anchor: URL, maximumDepth: Int = 32, maximumEntries: Int = 10_000) throws {
        guard Set(base.credentialItems) == Set(DeviceLocalResetScope.allowedCredentialItems) else { throw DeviceLocalResetScope.Failure.invalidCredentialBinding }
        try base.validateCurrentPaths()
        plan = try .init(anchor: try DeviceLocalResetScope.canonical(anchor), roots: [
            .init(directory: base.deviceRoot, mode: .directoryContents),
            .init(directory: base.preferencesRoot, mode: .namedFiles(["preferences-v1.json"]))],
            protectedRoots: [base.managementDirectory, base.resetDirectory], maximumDepth: maximumDepth, maximumEntries: maximumEntries)
        ownedManifest = nil; emptyContainers = []
        authorityScope = try .init(v2: base, cleanupMetadata: plan.canonicalMetadata)
    }
    /// Explicit opt-in only. V2 remains archive-only, with its original digest unchanged.
    init(v3 base: DeviceLocalResetScope, anchor: URL, maximumDepth: Int = 32, maximumEntries: Int = 10_000) throws {
        guard Set(base.credentialItems) == Set(DeviceLocalResetScope.allowedCredentialItems) else { throw DeviceLocalResetScope.Failure.invalidCredentialBinding }
        try base.validateCurrentPaths()
        plan = try .init(anchor: try DeviceLocalResetScope.canonical(anchor), roots: [
            .init(directory: base.deviceRoot, mode: .directoryContents),
            .init(directory: base.preferencesRoot, mode: .namedFiles([ScreenPreferenceAtomicWriter.archiveName, ScreenPreferenceAtomicWriter.pendingName]))],
            protectedRoots: [base.managementDirectory, base.resetDirectory], maximumDepth: maximumDepth, maximumEntries: maximumEntries)
        ownedManifest = nil; emptyContainers = []
        authorityScope = try .init(v3: base, cleanupMetadata: plan.canonicalMetadata)
    }
    init(v4 base: DeviceLocalResetScope, anchor: URL, manifest: DeviceFactoryResetManifest,
        maximumDepth: Int = 32, maximumEntries: Int = 100_000) throws {
        guard manifest.schemaVersion == 4, manifest.baseScopeDigest == base.digest else { throw DeviceLocalResetScope.Failure.invalidPath }
        try base.validateCurrentPaths()
        var roots: [DeviceLocalFilesystemCleanupPlan.Root] = [
            .init(directory: base.deviceRoot, mode: .directoryContents),
            .init(directory: base.preferencesRoot, mode: .namedFiles([ScreenPreferenceAtomicWriter.archiveName, ScreenPreferenceAtomicWriter.pendingName]))]
        roots += manifest.roots.map { .init(directory: URL(fileURLWithPath: $0.path, isDirectory: true),
            mode: .ownedDirectory(device: $0.device, inode: $0.inode)) }
        plan = try .init(anchor: try DeviceLocalResetScope.canonical(anchor), roots: roots,
            protectedRoots: [base.managementDirectory, base.resetDirectory], maximumDepth: maximumDepth, maximumEntries: maximumEntries)
        ownedManifest = manifest
        emptyContainers = try manifest.containers.map { container in
            try .init(anchor: DeviceLocalResetScope.canonical(anchor), roots: [
                .init(directory: URL(fileURLWithPath: container.path, isDirectory: true),
                    mode: .ownedEmptyDirectory(device: container.device, inode: container.inode))],
                protectedRoots: [base.managementDirectory, base.resetDirectory], maximumDepth: maximumDepth, maximumEntries: maximumEntries)
        }
        authorityScope = try .init(v4: base, cleanupMetadata: try DeviceFactoryResetManifest.cleanupMetadata(plan: plan, containers: emptyContainers), manifest: manifest)
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

@MainActor protocol DeviceOwnedResetCredentialCleanup {
    func deleteExact(_ item: DeviceFactoryResetManifest.Credential) throws
    func verifyOwnedServicesAbsent(_ services: Set<String>) throws
}
@MainActor struct DeviceOwnedResetKeychainCleanup: DeviceOwnedResetCredentialCleanup {
    func deleteExact(_ item: DeviceFactoryResetManifest.Credential) throws { try DeviceLocalResetCleanup.deleteExact(item) }
    func verifyOwnedServicesAbsent(_ services: Set<String>) throws { try DeviceLocalResetCleanup.verifyOwnedServicesAbsent(services) }
}

/// Proof of this adapter's synchronous, fully verified cleanup; constructor stays in this file.
@MainActor final class DeviceLocalResetCleanupReceipt {
    let scopeDigest: String
    let resetID: UUID
    let driverID: UUID
    fileprivate init(_ permit: DeviceLocalResetCleanupPermit) {
        scopeDigest = permit.scopeDigest; resetID = permit.resetID; driverID = permit.driverID
    }
}

/// No public raw execution API. Unknown legacy preference temporary files remain untouched.
@MainActor final class DeviceLocalResetCleanup {
    enum Failure: Error { case credentialStillPresent }
    private let scope: DeviceLocalResetCleanupScope
    private let credentials: any DeviceLocalResetCredentialCleanup
    private let ownedCredentials: any DeviceOwnedResetCredentialCleanup
    init(scope: DeviceLocalResetCleanupScope, credentials: any DeviceLocalResetCredentialCleanup = DeviceLocalResetKeychainCleanup(),
        ownedCredentials: (any DeviceOwnedResetCredentialCleanup)? = nil) {
        self.scope = scope; self.credentials = credentials; self.ownedCredentials = ownedCredentials ?? DeviceOwnedResetKeychainCleanup()
    }
    @discardableResult func execute(_ permit: DeviceLocalResetCleanupPermit) throws -> DeviceLocalResetCleanupReceipt {
        try scope.authorityScope.validateCurrentPaths()
        try DeviceLocalFilesystemCleanup(plan: scope.plan).execute(withDestructiveStep: { operation in
            try permit.withStep(scopeDigest: scope.authorityScope.digest) {
                try scope.ownedManifest?.validateContainerMembership(); try operation()
            }
        })
        for container in scope.emptyContainers {
            try DeviceLocalFilesystemCleanup(plan: container).execute(withDestructiveStep: { operation in
                try permit.withStep(scopeDigest: scope.authorityScope.digest) {
                    try scope.ownedManifest?.validateContainerMembership(); try operation()
                }
            })
        }
        if let manifest = scope.ownedManifest {
            for item in manifest.credentials {
                try permit.withStep(scopeDigest: scope.authorityScope.digest) { try ownedCredentials.deleteExact(item) }
            }
            try permit.withStep(scopeDigest: scope.authorityScope.digest) {
                try ownedCredentials.verifyOwnedServicesAbsent(Set(manifest.credentials.map(\.service)).union(scope.authorityScope.credentialItems.map(\.service)))
            }
        } else {
        for item in scope.authorityScope.credentialItems {
            try permit.withStep(scopeDigest: scope.authorityScope.digest) {
                try credentials.delete(item)
                guard try credentials.isAbsent(item) else { throw Failure.credentialStillPresent }
            }
        }
        }
        var receipt: DeviceLocalResetCleanupReceipt?
        try permit.withStep(scopeDigest: scope.authorityScope.digest) {
            try scope.authorityScope.validateCurrentPaths()
            if scope.ownedManifest != nil { try validateOwnedCompletion() }
            receipt = DeviceLocalResetCleanupReceipt(permit)
        }
        guard let receipt else { throw DeviceLocalResetCoordinator.Failure.invalidOperation }
        return receipt
    }
    /// Read-only completion proof before replacing the retired installation owner.
    func validateOwnedCompletion() throws {
        guard let manifest = scope.ownedManifest else { throw Failure.credentialStillPresent }
        for root in manifest.roots + manifest.containers {
            let traversal = try DeviceFilesystemTraversal.plan(for: root.path)
            var fd = open(traversal.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.credentialStillPresent }
            var absent = false
            for component in traversal.components {
                let child = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0 {
                    let missing = errno == ENOENT; close(fd)
                    guard missing else { throw Failure.credentialStillPresent }
                    absent = true; break
                }
                close(fd); fd = child
            }
            if !absent { close(fd); throw Failure.credentialStillPresent }
        }
        try ownedCredentials.verifyOwnedServicesAbsent(Set(manifest.credentials.map(\.service)).union(scope.authorityScope.credentialItems.map(\.service)))
    }

    fileprivate static func verifyOwnedServicesAbsent(_ services: Set<String>) throws {
        #if canImport(Security)
        for service in services.sorted() {
            // Inspection only. Unknown new accounts are preserved and block a
            // completion claim; they are never deleted by a service-wide query.
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecItemNotFound else { throw Failure.credentialStillPresent }
        }
        #else
        throw Failure.credentialStillPresent
        #endif
    }
    fileprivate static func deleteExact(_ item: DeviceFactoryResetManifest.Credential) throws {
        #if canImport(Security)
        let exact: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: item.persistentReference]
        var inspect = exact
        inspect[kSecReturnAttributes as String] = true; inspect[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(inspect as CFDictionary, &result)
        let account: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service, kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if status == errSecItemNotFound {
            guard SecItemCopyMatching(account as CFDictionary, &result) == errSecItemNotFound else { throw Failure.credentialStillPresent }
            return // Replay never substitutes or erases a replacement account item.
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
            attributes[kSecAttrService as String] as? String == item.service,
            attributes[kSecAttrAccount as String] as? String == item.account else { throw Failure.credentialStillPresent }
        // Bind the original value as well as its reference; Keychain can reuse a reference after replacement.
        var read = exact; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var payload: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &payload) == errSecSuccess,
            let data = payload as? Data, data.count == item.byteCount,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.valueSHA256 else { throw Failure.credentialStillPresent }
        let deletion = SecItemDelete(exact as CFDictionary)
        guard deletion == errSecSuccess || deletion == errSecItemNotFound else { throw Failure.credentialStillPresent }
        guard SecItemCopyMatching(inspect as CFDictionary, &result) == errSecItemNotFound,
            SecItemCopyMatching(account as CFDictionary, &result) == errSecItemNotFound else { throw Failure.credentialStillPresent }
        #else
        throw Failure.credentialStillPresent
        #endif
    }

}
