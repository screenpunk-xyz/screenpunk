import XCTest
import Security
import LocalAuthentication
@_spi(DeviceGrantTransport) import ScreenpunkCore
@testable import ScreenpunkApple

final class DeviceGrantKeychainBackendTests: XCTestCase {
    private enum Marker: Error { case visitor }
    private final class API: DeviceGrantSecurityAPI, @unchecked Sendable {
        var items: [String:[String:Any]] = [:]
        var copies: [[String:Any]] = [], adds: [[String:Any]] = []
        var overrideCopy: (([String:Any]) -> DeviceGrantSecurityResult?)?
        var afterAdd: (([String:Any]) -> DeviceGrantSecurityResult?)?
        func copy(_ query: [String:Any]) -> DeviceGrantSecurityResult {
            copies.append(query)
            if let result = overrideCopy?(query) { return result }
            if let ref = query[kSecValuePersistentRef as String] as? Data {
                guard let row = items.values.first(where: { ($0[kSecValuePersistentRef as String] as? Data) == ref }) else { return .init(status:errSecItemNotFound,value:nil) }
                return .init(status:errSecSuccess,value:row as NSDictionary)
            }
            let service = query[kSecAttrService as String] as? String
            let account = query[kSecAttrAccount as String] as? String
            let anySync = query[kSecAttrSynchronizable as String] != nil
            let limit = (query[kSecMatchLimit as String] as? NSNumber)?.intValue ?? 1
            var rows = items.values.filter { row in
                (row[kSecAttrService as String] as? String) == service && (account == nil || (row[kSecAttrAccount as String] as? String) == account) && (anySync || (row[kSecAttrSynchronizable as String] as? Bool) != true)
            }.sorted { ($0[kSecAttrAccount as String] as! String) < ($1[kSecAttrAccount as String] as! String) }
            rows = Array(rows.prefix(limit))
            guard !rows.isEmpty else { return .init(status:errSecItemNotFound,value:nil) }
            let refs = (query[kSecReturnPersistentRef as String] as? Bool) == true
            let result = rows.map { row -> [String:Any] in
                var result = row; result.removeValue(forKey:kSecValueData as String)
                if !refs { result.removeValue(forKey:kSecValuePersistentRef as String) }; return result
            }
            return .init(status:errSecSuccess,value:result as NSArray)
        }
        func add(_ attributes: [String:Any]) -> DeviceGrantSecurityResult {
            adds.append(attributes)
            let account = attributes[kSecAttrAccount as String] as! String
            guard items[account] == nil else { return .init(status:errSecDuplicateItem,value:nil) }
            var row = attributes
            row.removeValue(forKey:kSecUseAuthenticationContext as String)
            row.removeValue(forKey:kSecReturnPersistentRef as String)
            let ref = Data("reference-\(adds.count)".utf8)
            row[kSecValuePersistentRef as String] = ref; items[account] = row
            if let result = afterAdd?(attributes) { return result }
            return .init(status:errSecSuccess,value:ref as NSData)
        }
    }
    private let root = UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    private func account(_ n: Int = 2) -> String { "credential.00000000-0000-0000-0000-\(String(format:"%012d",n))" }
    private func fixture() throws -> (API,DeviceGrantKeychainBackend,String) {
        let api = API(), backend = DeviceGrantKeychainBackend(rootID:root,api:api), name = account()
        _ = try backend.add(account:name,bytes:Data("secret-canary".utf8)); return (api,backend,name)
    }
    func testAddReadExactDescriptorPolicyAndRedaction() throws {
        let (api,backend,name) = try fixture(), attributes = try XCTUnwrap(api.adds.first)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String,"xyz.screenpunk.device.grant-revisions.v1.\(root.uuidString.lowercased())")
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String,name)
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool,false)
        XCTAssertTrue(try XCTUnwrap(attributes[kSecUseAuthenticationContext as String] as? LAContext).interactionNotAllowed)
        #if os(macOS)
        XCTAssertEqual(attributes[kSecUseDataProtectionKeychain as String] as? Bool,true)
        #endif
        let descriptor = try XCTUnwrap(attributes[kSecAttrGeneric as String] as? Data)
        XCTAssertEqual(descriptor.count,42); XCTAssertEqual(Array(descriptor.prefix(6)),[83,80,71,82,1,1])
        XCTAssertFalse(descriptor.contains(Data("secret-canary".utf8)))
        let secret = try XCTUnwrap(backend.read(account:name,maximumBytes:8192))
        XCTAssertEqual(secret.observation.byteCount,13); XCTAssertEqual(Mirror(reflecting:secret).children.count,0)
        XCTAssertFalse(String(reflecting:secret).contains("secret-canary"))
        XCTAssertEqual(Mirror(reflecting:backend).children.count,0)
        XCTAssertEqual(Mirror(reflecting:DeviceGrantSecurityResult(status:0,value:Data("secret-canary".utf8) as NSData)).children.count,0)
    }
    func testBoundedAttributesOnlyInventoryAndVisitorReentry() throws {
        let (api,backend,name) = try fixture(); var count = 0
        try backend.inventory(maximum:4225) { observation in
            count += 1; XCTAssertEqual(observation.account,name)
            XCTAssertNotNil(try backend.read(account:name,maximumBytes:8192))
        }
        XCTAssertEqual(count,1)
        let anyQueries = api.copies.filter { $0[kSecAttrSynchronizable as String] != nil }
        XCTAssertTrue(anyQueries.contains { ($0[kSecMatchLimit as String] as? NSNumber)?.intValue == 4226 })
        XCTAssertTrue(anyQueries.allSatisfy { $0[kSecReturnPersistentRef as String] == nil && ($0[kSecReturnData as String] as? Bool) == false })
        XCTAssertThrowsError(try backend.inventory(maximum:1) { _ in throw Marker.visitor }) { XCTAssertTrue($0 is Marker) }
        let calls = api.copies.count
        XCTAssertThrowsError(try backend.inventory(maximum:4226) { _ in }); XCTAssertEqual(api.copies.count,calls)
    }
    func testMalformedRowsAndSynchronizableImpostorAreRetained() throws {
        let changes: [(inout [String:Any]) -> Void] = [
            { $0[kSecAttrSynchronizable as String] = true },
            { $0[kSecAttrGeneric as String] = Data(repeating:0,count:42) },
            { $0[kSecAttrService as String] = "XYZ.screenpunk.device.grant-revisions.v1" },
            { $0[kSecAttrAccessible as String] = kSecAttrAccessibleAlways },
            { $0[kSecAttrAccount as String] = "credential.BAD" },
            { $0[kSecValuePersistentRef as String] = Data(repeating:1,count:4097) }
        ]
        for change in changes {
            let (api,backend,name) = try fixture(); var row = api.items[name]!; change(&row); api.items[name] = row
            if (row[kSecAttrService as String] as? String) != (api.adds[0][kSecAttrService as String] as? String) || (row[kSecAttrAccount as String] as? String) != name {
                var malformed = row; malformed.removeValue(forKey:kSecValueData as String); malformed.removeValue(forKey:kSecValuePersistentRef as String)
                api.overrideCopy = { _ in .init(status:errSecSuccess,value:[malformed] as NSArray) }
            }
            XCTAssertThrowsError(try backend.read(account:name,maximumBytes:8192)); XCTAssertEqual(api.items.count,1); XCTAssertEqual(api.adds.count,1)
        }
    }
    func testBoundsRejectBeforeEffectsAndReturnedArraySentinel() throws {
        let api = API(), backend = DeviceGrantKeychainBackend(rootID:root,api:api)
        for name in [account().uppercased(), account()+"\0", "other.00000000-0000-0000-0000-000000000002"] {
            XCTAssertThrowsError(try backend.add(account:name,bytes:Data([1])))
        }
        XCTAssertThrowsError(try backend.add(account:account(),bytes:Data(repeating:1,count:8193)))
        XCTAssertThrowsError(try backend.read(account:account(),maximumBytes:8193)); XCTAssertTrue(api.adds.isEmpty); XCTAssertTrue(api.copies.isEmpty)
        api.overrideCopy = { _ in .init(status:errSecSuccess,value:[NSDictionary(),NSDictionary()] as NSArray) }
        var called = false; XCTAssertThrowsError(try backend.inventory(maximum:1) { _ in called = true }); XCTAssertFalse(called)
    }
    func testPartialAddAndDuplicateNeverAdoptOrOverwrite() throws {
        for status in [errSecSuccess,errSecInteractionNotAllowed] {
            let api = API(), backend = DeviceGrantKeychainBackend(rootID:root,api:api)
            api.afterAdd = { _ in .init(status:status,value:nil) }
            XCTAssertThrowsError(try backend.add(account:account(),bytes:Data([1])))
            XCTAssertEqual(api.items.count,1)
            XCTAssertThrowsError(try backend.add(account:account(),bytes:Data([1])))
            XCTAssertEqual(api.adds.count,1)
        }
    }
    func testDirectAddReferenceCannotBeReplacedBySameByteLookup() throws {
        let api = API(), backend = DeviceGrantKeychainBackend(rootID:root,api:api)
        api.afterAdd = { [self] _ in
            api.items[account()]![kSecValuePersistentRef as String] = Data("replacement".utf8)
            return .init(status:errSecSuccess,value:Data("original".utf8) as NSData)
        }
        XCTAssertThrowsError(try backend.add(account:account(),bytes:Data([1]))); XCTAssertEqual(api.items.count,1)
    }
    func testInventoryVisitorReplacementAndPrivateCountMismatchFailClosed() throws {
        let (api,backend,name) = try fixture()
        XCTAssertThrowsError(try backend.inventory(maximum:1) { _ in api.items[name]![kSecValuePersistentRef as String] = Data("replacement".utf8) })
        api.items[name]![kSecValueData as String] = Data(repeating:1,count:8193)
        XCTAssertThrowsError(try backend.read(account:name,maximumBytes:8192))
        api.items[name]![kSecValueData as String] = Data([1])
        XCTAssertThrowsError(try backend.read(account:name,maximumBytes:8192))
    }
    func testMalformedFrameworkShapesAndInaccessibleAreNotAbsence() throws {
        let (api,backend,name) = try fixture()
        for result in [DeviceGrantSecurityResult(status:errSecSuccess,value:Data() as NSData), .init(status:errSecSuccess,value:["bad"] as NSArray), .init(status:errSecInteractionNotAllowed,value:nil)] {
            api.overrideCopy = { _ in result }; XCTAssertThrowsError(try backend.read(account:name,maximumBytes:8192))
        }
    }
    func testEmptySuccessfulInventoryIsMalformedAndNotFoundIsAbsence() throws {
        let api = API(), backend = DeviceGrantKeychainBackend(rootID:root,api:api)
        XCTAssertNil(try backend.read(account:account(),maximumBytes:8192))
        try backend.inventory(maximum:1) {_ in XCTFail("Not-found inventory must be empty")}
        api.overrideCopy = {_ in .init(status:errSecSuccess,value:[] as NSArray)}
        XCTAssertThrowsError(try backend.read(account:account(),maximumBytes:8192))
        XCTAssertThrowsError(try backend.inventory(maximum:1) {_ in})
    }
    func testCompleteInventoryRejectsSharedPersistentReference() throws {
        let (api,backend,first) = try fixture(), second = account(3)
        _ = try backend.add(account:second,bytes:Data([1]))
        var count = 0; try backend.inventory(maximum:2) {_ in count += 1}; XCTAssertEqual(count,2)
        api.items[second]![kSecValuePersistentRef as String] = api.items[first]![kSecValuePersistentRef as String]
        XCTAssertThrowsError(try backend.inventory(maximum:2) {_ in})
        XCTAssertEqual(api.items.count,2)
    }

}
