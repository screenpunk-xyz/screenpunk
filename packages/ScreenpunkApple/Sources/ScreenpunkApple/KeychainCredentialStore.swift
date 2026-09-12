import Foundation
import ScreenpunkCore
#if canImport(Security)
import Security
#endif

/// Device/Mac Keychain store. ThisDeviceOnly, not iCloud-synced.
public struct KeychainCredentialStore: CredentialStore, Sendable {
    public var service: String
    public var accessGroup: String?

    public init(service: String = "xyz.screenpunk.connections", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func secret(for authRef: String) throws -> Data? {
        #if canImport(Security)
        var query = baseQuery(account: authRef)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ConnectionFailure.permissionRequired
        }
        return data
        #else
        throw ConnectionFailure.permissionRequired
        #endif
    }

    public func put(_ secret: Data, for authRef: String) throws {
        #if canImport(Security)
        try delete(authRef)
        var query = baseQuery(account: authRef)
        query[kSecValueData as String] = secret
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ConnectionFailure.permissionRequired }
        #else
        throw ConnectionFailure.permissionRequired
        #endif
    }

    public func delete(_ authRef: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(account: authRef) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw ConnectionFailure.permissionRequired
        }
        #endif
    }

    public func deleteAll() throws {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw ConnectionFailure.permissionRequired
        }
        #endif
    }

    #if canImport(Security)
    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
    #endif
}
