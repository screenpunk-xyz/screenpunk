import Foundation
import Security
import ScreenpunkCore

public enum CloudInstallationCredentialError: Error, Equatable, Sendable {
    case invalidReference, malformedSecret, inaccessible(status: Int32), mismatchedWrite, unconfirmedWrite, randomGenerationFailed
}

enum CloudInstallationCredentialInsert { case inserted, alreadyExists }
protocol CloudInstallationCredentialBackend: Sendable {
    func read(reference: String) throws -> Data?
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert
    func references() throws -> Set<String>
}

/// Dedicated installation secrets only. There is intentionally no update or erase operation.
public struct CloudInstallationCredentialStore: Sendable {
    public static let service = "xyz.screenpunk.installation.cloud"
    private let backend: any CloudInstallationCredentialBackend
    private let random: @Sendable () throws -> Data
    public init() { self.init(backend: CloudInstallationKeychainBackend(), random: Self.randomSecret) }
    init(backend: any CloudInstallationCredentialBackend, random: @escaping @Sendable () throws -> Data) {
        self.backend = backend; self.random = random
    }
    public func secret(for reference: String) throws -> Data? {
        try Self.validate(reference)
        return try backend.read(reference: reference).map(Self.validateSecret)
    }
    public func references() throws -> Set<String> {
        let references = try backend.references()
        for reference in references { try Self.validate(reference) }
        return references
    }
    /// Complete service inventory. Only declared formats are accepted; no secret escapes this classifier.
    func inventory(history: DeviceManagementFormatHistory?) throws -> [String: CloudInstallationCredentialFormat] {
        let observed = try references()
        let bindings = history?.credentials ?? []
        guard observed == Set(bindings.map(\.credentialReference)) else { throw CloudInstallationCredentialError.invalidReference }
        var result: [String: CloudInstallationCredentialFormat] = [:]
        for binding in bindings {
            guard let bytes = try backend.read(reference: binding.credentialReference),
                  bytes.count == (binding.format == .legacyLocal32 ? 32 : 48) else { throw CloudInstallationCredentialError.malformedSecret }
            result[binding.credentialReference] = binding.format
        }
        guard try references() == observed else { throw CloudInstallationCredentialError.invalidReference }
        return result
    }
    /// Load an existing immutable key, or create it once and verify the same reference.
    /// A nonduplicate write error is recoverable only if exact attempted bytes can be read back.
    func stage(reference: String) throws -> Data {
        if let existing = try secret(for: reference) { return existing }
        let attempted = try Self.validateSecret(random())
        let result: CloudInstallationCredentialInsert
        do { result = try backend.insert(attempted, reference: reference) }
        catch {
            guard let readback = try secret(for: reference) else {
                throw (error as? CloudInstallationCredentialError) ?? .unconfirmedWrite
            }
            guard readback == attempted else { throw CloudInstallationCredentialError.mismatchedWrite }
            return readback
        }
        guard let readback = try secret(for: reference) else { throw CloudInstallationCredentialError.unconfirmedWrite }
        if case .inserted = result, readback != attempted { throw CloudInstallationCredentialError.mismatchedWrite }
        return readback
    }
    private static func validate(_ reference: String) throws {
        guard !reference.isEmpty, reference.utf8.count <= 128,
              reference.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) })
        else { throw CloudInstallationCredentialError.invalidReference }
    }
    private static func validateSecret(_ secret: Data) throws -> Data {
        guard secret.count == 32 else { throw CloudInstallationCredentialError.malformedSecret }
        return secret
    }
    private static func randomSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CloudInstallationCredentialError.randomGenerationFailed }
        return Data(bytes)
    }
}

private struct CloudInstallationKeychainBackend: CloudInstallationCredentialBackend {
    private func query(reference: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: CloudInstallationCredentialStore.service,
                                  kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        if let reference { query[kSecAttrAccount as String] = reference }
        return query
    }
    func read(reference: String) throws -> Data? {
        var query = query(reference: reference)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CloudInstallationCredentialError.inaccessible(status: status) }
        guard let values = result as? [Data], values.count == 1 else { throw CloudInstallationCredentialError.malformedSecret }
        return values[0]
    }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert {
        var query = query(reference: reference)
        query[kSecValueData as String] = secret
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return .alreadyExists }
        guard status == errSecSuccess else { throw CloudInstallationCredentialError.inaccessible(status: status) }
        return .inserted
    }
    func references() throws -> Set<String> {
        var query = query()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = false
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CloudInstallationCredentialError.inaccessible(status: status) }
        guard let values = result as? [[String: Any]] else { throw CloudInstallationCredentialError.malformedSecret }
        var references = Set<String>()
        for value in values {
            guard let reference = value[kSecAttrAccount as String] as? String, references.insert(reference).inserted else { throw CloudInstallationCredentialError.invalidReference }
        }
        return references
    }
}
