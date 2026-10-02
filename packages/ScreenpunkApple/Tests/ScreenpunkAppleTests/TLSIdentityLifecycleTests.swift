import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple
#if canImport(Security)
import Security
#endif

/// No test in this suite calls Security.framework's Keychain operations.
final class TLSIdentityLifecycleTests: XCTestCase {
    func testLoadedIdentityIsReusedWithoutCreation() throws {
        let store = FakeIdentityStore(existing: "original-pin")
        XCTAssertEqual(try resolve(store), "original-pin")
        XCTAssertEqual(store.creations, 0)
        XCTAssertEqual(store.loadedRole, .controller)
        XCTAssertEqual(store.loadedTag, "fixture.identity.scope")
    }

    func testOnlyConfirmedMissingIdentityCreatesInTheSameScope() throws {
        let store = FakeIdentityStore(existing: nil)
        XCTAssertEqual(try resolve(store), "created-pin")
        XCTAssertEqual(store.creations, 1)
        XCTAssertEqual(store.createdRole, store.loadedRole)
        XCTAssertEqual(store.createdTag, store.loadedTag)
    }

    func testDeniedLockedCorruptAndOtherLoadFailuresNeverCreate() {
        for failure in [TLSIdentityLoadError.keychain(status: -25293), .keychain(status: -25308),
                        .keychain(status: -50), .corruptMaterial] {
            let store = FakeIdentityStore(existing: nil, failure: failure)
            XCTAssertThrowsError(try resolve(store)) { XCTAssertEqual($0 as? TLSIdentityLoadError, failure) }
            XCTAssertEqual(store.creations, 0)
        }
    }

    func testCreationFailurePropagatesWithoutASecondAttempt() {
        let store = FakeIdentityStore(existing: nil, creationFailure: .corruptMaterial)
        XCTAssertThrowsError(try resolve(store))
        XCTAssertEqual(store.creations, 1)
    }

#if canImport(Security)
    func testKeychainStatusClassificationAndExactPrivateKeyQuery() throws {
        XCTAssertFalse(try TLSIdentity.lookupFound(status: errSecItemNotFound))
        XCTAssertTrue(try TLSIdentity.lookupFound(status: errSecSuccess))
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecDecode, errSecParam, errSecNotAvailable] {
            XCTAssertThrowsError(try TLSIdentity.lookupFound(status: status)) {
                XCTAssertEqual($0 as? TLSIdentityLoadError, .keychain(status: status))
            }
        }
        let query = TLSIdentity.persistentKeyQuery(tag: "isolated.fixture.tag")
        XCTAssertEqual(query[kSecAttrApplicationTag as String] as? Data, Data("isolated.fixture.tag".utf8))
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassKey as String)
        XCTAssertEqual(query[kSecAttrKeyType as String] as? String, kSecAttrKeyTypeECSECPrimeRandom as String)
        XCTAssertEqual(query[kSecAttrKeyClass as String] as? String, kSecAttrKeyClassPrivate as String)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
        XCTAssertNil(query[kSecAttrAccessGroup as String], "Preserve existing default access-group scope")
    }
#endif

    private func resolve(_ store: FakeIdentityStore) throws -> String {
        try TLSIdentityLifecycle.loadOrCreate(role: .controller, tag: "fixture.identity.scope", store: store)
    }
}

private final class FakeIdentityStore: TLSIdentityStore {
    let existing: String?
    let failure: TLSIdentityLoadError?
    let creationFailure: TLSIdentityLoadError?
    var creations = 0
    var loadedRole: PairingRole?
    var loadedTag: String?
    var createdRole: PairingRole?
    var createdTag: String?
    init(existing: String?, failure: TLSIdentityLoadError? = nil, creationFailure: TLSIdentityLoadError? = nil) {
        self.existing = existing; self.failure = failure; self.creationFailure = creationFailure
    }
    func load(role: PairingRole, tag: String) throws -> String? {
        loadedRole = role; loadedTag = tag
        if let failure { throw failure }
        return existing
    }
    func create(role: PairingRole, tag: String) throws -> String {
        creations += 1; createdRole = role; createdTag = tag
        if let creationFailure { throw creationFailure }
        return "created-pin"
    }
}
