import XCTest
import Security
import CryptoKit
@testable import ScreenpunkApple

@MainActor final class DeviceOwnedResetCredentialCleanupTests: XCTestCase {
    private func add(service: String, account: String, value: UInt8 = 7) throws -> DeviceFactoryResetManifest.Credential {
        var reference: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false, kSecValueData as String: Data(repeating: value, count: 48),
            kSecReturnPersistentRef as String: true]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, &reference), errSecSuccess)
        return .init(service: service, account: account, persistentReference: try XCTUnwrap(reference as? Data), byteCount: 48, valueSHA256: SHA256.hash(data: Data(repeating: value, count: 48)).map({ String(format: "%02x", $0) }).joined())
    }
    private func remove(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(query as CFDictionary)
        XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound, "Owned fixture cleanup failed: \(service)/\(account), status \(status)")
    }
    func testExactDeletionAndRetryVerifyAbsence() throws {
        let service = "screenpunk.reset-test." + UUID().uuidString
        print("Owned reset Keychain fixture service: " + service)
        defer { remove(service: service, account: "owned") }
        let original = try add(service: service, account: "owned")
        let cleanup = DeviceOwnedResetKeychainCleanup()
        try cleanup.deleteExact(original); try cleanup.deleteExact(original)
        try cleanup.verifyOwnedServicesAbsent([service])
    }
    func testReplacedPersistentReferenceIsPreservedAndBlocksCompletion() throws {
        let service = "screenpunk.reset-test." + UUID().uuidString
        print("Owned reset Keychain fixture service: " + service)
        defer { remove(service: service, account: "owned") }
        let original = try add(service: service, account: "owned")
        remove(service: service, account: "owned")
        let replacement = try add(service: service, account: "owned", value: 9)
        print("Owned replacement reuses persistent reference: \(original.persistentReference == replacement.persistentReference)")
        let cleanup = DeviceOwnedResetKeychainCleanup()
        XCTAssertThrowsError(try cleanup.deleteExact(original))
        XCTAssertThrowsError(try cleanup.verifyOwnedServicesAbsent([service]))
        // The cleanup refuses to delete the replacement; its exact owner can.
        try cleanup.deleteExact(replacement)
        try cleanup.verifyOwnedServicesAbsent([service])
    }
    func testNewAccountInOwnedServiceIsPreservedAndBlocksCompletion() throws {
        let service = "screenpunk.reset-test." + UUID().uuidString
        print("Owned reset Keychain fixture service: " + service)
        defer { remove(service: service, account: "owned"); remove(service: service, account: "new") }
        let original = try add(service: service, account: "owned")
        let newAccount = try add(service: service, account: "new")
        let cleanup = DeviceOwnedResetKeychainCleanup()
        try cleanup.deleteExact(original)
        XCTAssertThrowsError(try cleanup.verifyOwnedServicesAbsent([service]))
        try cleanup.deleteExact(newAccount)
        try cleanup.verifyOwnedServicesAbsent([service])
    }
}
