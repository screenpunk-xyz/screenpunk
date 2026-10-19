import Foundation
import Security
import ScreenpunkController
import ScreenpunkCore

enum WorkbenchSecretError: Error {
    case invalidBinding, keychain(OSStatus)
}

/// Only designated Workbench connection credentials use this service/account
/// namespace. An inaccessible item is an error, never an absent credential.
final class WorkbenchKeychainSecrets: WorkbenchSecretProvider {
    private let ownerPin: () -> String?
    private let service = "xyz.screenpunk.workbench.connection.v1"

    init(ownerPin: @escaping () -> String?) { self.ownerPin = ownerPin }

    /// The host binds each staged credential to its controller, device and
    /// fresh credential slot. No portable file contains the bytes.
    static func reference(ownerPin: String, deviceId: String, credentialId: UUID) -> String {
        WorkbenchSecretReference.make(ownerPin: ownerPin, deviceId: deviceId, credentialId: credentialId)
    }

    private static func fingerprint(_ text: String) -> String {
        String(DeploymentDigest.sha256Hex(Data(text.utf8)).prefix(32))
    }

    private func account(_ authRef: String) throws -> String {
        if authRef.hasPrefix("ha-"),
           UUID(uuidString: String(authRef.dropFirst(3))) != nil,
           authRef.utf8.count <= 128, let current = ownerPin() {
            return "home-assistant:" + Self.fingerprint(current) + ":" + authRef
        }
        let parts = authRef.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "w1", let current = ownerPin(),
              parts[1] == Substring(Self.fingerprint(current)),
              parts[2].utf8.count == 32,
              parts[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              UUID(uuidString: String(parts[3])) != nil,
              authRef.utf8.count <= 128 else { throw WorkbenchSecretError.invalidBinding }
        return authRef
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func install(_ secret: Data, for authRef: String) throws {
        let key = try account(authRef)
        guard (1...8192).contains(secret.count) else { throw WorkbenchSecretError.invalidBinding }
        var attributes = query(key)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
            guard update == errSecSuccess else { throw WorkbenchSecretError.keychain(update) }
        } else if status != errSecSuccess { throw WorkbenchSecretError.keychain(status) }
    }

    func load(authRef: String) throws -> Data {
        let key = try account(authRef)
        var attributes = query(key)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        guard status == errSecSuccess else { throw WorkbenchSecretError.keychain(status) }
        guard let secret = item as? Data, (1...8192).contains(secret.count) else {
            throw WorkbenchSecretError.invalidBinding
        }
        return secret
    }

    func remove(authRef: String) throws {
        let status = SecItemDelete(query(try account(authRef)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WorkbenchSecretError.keychain(status) }
    }
}
