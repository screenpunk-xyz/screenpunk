import XCTest
import Security
@_spi(NativeInstallation) @_spi(DeviceGrantTransport) import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple

final class NativeEnrollmentKeychainBackendTests: XCTestCase {
    final class API: NativeEnrollmentSecurityAPI {
        var queries: [[String: Any]] = [], adds: [[String: Any]] = []
        var result: (OSStatus, CFTypeRef?) = (errSecItemNotFound, nil)
        var responses: [(OSStatus, CFTypeRef?)] = []
        var addResult: (OSStatus, CFTypeRef?) = (errSecSuccess, Data("persistent-original".utf8) as CFData)
        func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
            queries.append(query as! [String: Any]); return responses.isEmpty ? result : responses.removeFirst()
        }
        func add(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) { adds.append(query as! [String: Any]); return addResult }
        func random48() throws -> Data { Data(repeating: 17, count: 48) }
    }
    private func item(service: String = NativeEnrollmentKeychainBackend.finalService, account: Any = "original", count: Int = 48) -> [String: Any] {
        [kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
         kSecValueData as String: Data(repeating: 7, count: count), kSecValuePersistentRef as String: Data("original-ref".utf8)]
    }
    func testDeniedNativeCredentialOperationsHaveFixedDiagnosticLabelsWithoutStatusOrMutation() throws {
        let cases: [(OSStatus, NativeEnrollmentKeychainBackend.FailureDiagnostic.Reason)] = [
            (errSecInteractionNotAllowed, .locked), (errSecMissingEntitlement, .entitlement),
            (errSecNotAvailable, .unavailable), (errSecAuthFailed, .authorization),
            (errSecParam, .invalidParameter), (errSecDecode, .malformedResult), (-1234567, .other)
        ]
        for (status, expected) in cases {
            let api = API(), backend = NativeEnrollmentKeychainBackend(api: api)
            api.result = (status, nil)
            XCTAssertThrowsError(try backend.enumerateBounded(maximum: 193)) { error in
                let diagnostic = NativeEnrollmentKeychainBackend.diagnostic(for: error)
                XCTAssertEqual(diagnostic?.domain, .nativeEnrollmentCredential)
                XCTAssertEqual(diagnostic?.reason, expected)
                XCTAssertFalse(diagnostic?.reason.rawValue.contains(String(status)) == true)
            }
            XCTAssertEqual(api.queries.count, 1)
            XCTAssertTrue(api.adds.isEmpty)
            let grant = NativeEnrollmentKeychainBackend.diagnostic(for: DeviceGrantCredentialTransportFailure.inaccessible(status))
            XCTAssertEqual(grant?.domain, .grantCredential)
            XCTAssertEqual(grant?.reason, expected)
        }
        XCTAssertEqual(NativeEnrollmentKeychainBackend.diagnostic(for: NativeEnrollmentKeychainBackend.Failure.malformedResult)?.reason, .malformedResult)
        XCTAssertEqual(NativeEnrollmentKeychainBackend.diagnostic(for: DeviceGrantCredentialTransportFailure.changedInventory)?.reason, .changedInventory)
        XCTAssertEqual(NativeEnrollmentKeychainBackend.diagnostic(for: DeviceGrantCredentialTransportFailure.duplicateItem)?.reason, .duplicate)
        XCTAssertNil(NativeEnrollmentKeychainBackend.diagnostic(for: NSError(domain: "private-token-message", code: 17)))
    }
    func testFixedAddOnlyAttributesAndNoDuplicateAdoption() throws {
        let api = API(), backend = NativeEnrollmentKeychainBackend(api: api)
        guard case .inserted = try backend.insertFinalOnly(account: Data("original".utf8), original48: Data(repeating: 1, count: 48)) else { return XCTFail() }
        XCTAssertEqual(api.adds.count, 1); XCTAssertTrue(api.queries.isEmpty)
        let q = try XCTUnwrap(api.adds.first)
        XCTAssertEqual(q[kSecAttrService as String] as? String, NativeEnrollmentKeychainBackend.finalService)
        XCTAssertEqual(q[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
        api.addResult = (errSecDuplicateItem, nil)
        guard case .duplicate = try backend.insertStageOnly(account: Data("stage-original".utf8), envelope: Data([1])) else { return XCTFail() }
        XCTAssertTrue(api.queries.isEmpty)
        XCTAssertEqual(api.adds.last?[kSecAttrService as String] as? String, NativeEnrollmentKeychainBackend.stageService)
    }
    func testNumericOverflowWitnessAndStrictAttributeTypes() throws {
        let api = API(), backend = NativeEnrollmentKeychainBackend(api: api)
        api.result = (errSecSuccess, [item()] as CFArray)
        let observed = try backend.enumerateBounded(maximum: 1)
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(api.queries.first?[kSecMatchLimit as String] as? Int, 1)
        XCTAssertEqual(String(describing: observed[0]), "NativeEnrollmentStoredCredential(redacted)")
        api.result = (errSecSuccess, [item(account: NSNumber(value: 123))] as CFArray)
        XCTAssertThrowsError(try backend.enumerateBounded(maximum: 193))
        api.result = (errSecSuccess, [item(service: "unrelated")] as CFArray)
        XCTAssertThrowsError(try backend.enumerateBounded(maximum: 193))
        api.result = (errSecSuccess, [item(count: 47)] as CFArray)
        XCTAssertThrowsError(try backend.enumerateBounded(maximum: 193))
    }
    func testFixedNonsyncOmissionAndPlatformQueryPolicy() throws {
        let api = API(), backend = NativeEnrollmentKeychainBackend(api: api)
        var omitted = item(); omitted.removeValue(forKey: kSecAttrSynchronizable as String)
        api.result = (errSecSuccess, [omitted] as CFArray)
        XCTAssertEqual(try backend.enumerateBounded(maximum: 1).count, 1)
        var wrong = item(); wrong[kSecAttrSynchronizable as String] = "false"
        api.result = (errSecSuccess, [wrong] as CFArray)
        XCTAssertThrowsError(try backend.enumerateBounded(maximum: 1))
        #if os(macOS)
        XCTAssertTrue(api.queries.allSatisfy { ($0[kSecUseDataProtectionKeychain as String] as? Bool) == true })
        #else
        XCTAssertTrue(api.queries.allSatisfy { $0[kSecUseDataProtectionKeychain as String] == nil })
        #endif
    }
    func testPhysicalNumericZeroNonsyncQualifiesBothNamespacesAndExactReferencesWithoutAdd() throws {
        let api = API(), backend = NativeEnrollmentKeychainBackend(api: api)
        var final = item(account: "native.original"), stage = item(service: NativeEnrollmentKeychainBackend.stageService, account: "stage.original", count: 512)
        // Actual iPad attrs-only probe: CFArray for numeric limits, CFNumber zero
        // for synchronizable. Payloads/references below are synthetic fixtures.
        let zero = NSNumber(value: 0)
        XCTAssertEqual(CFGetTypeID(zero), CFNumberGetTypeID())
        final[kSecAttrSynchronizable as String] = zero
        stage[kSecAttrSynchronizable as String] = zero
        stage[kSecValuePersistentRef as String] = Data("stage-ref".utf8)
        api.responses = [(errSecSuccess, [final] as CFArray), (errSecSuccess, [final] as CFArray),
            (errSecSuccess, [stage] as CFArray), (errSecSuccess, [stage] as CFArray)]
        let inventory = try backend.enumerateBounded(maximum: 193)
        XCTAssertEqual(inventory.count, 2)
        XCTAssertEqual(api.queries.map { $0[kSecMatchLimit as String] as? Int }, [193, 2, 192, 2])
        for (row, reference) in [(final, Data("original-ref".utf8)), (stage, Data("stage-ref".utf8))] {
            api.result = (errSecSuccess, [row] as CFArray)
            let observed = try XCTUnwrap(backend.readExactPersistentReference(reference))
            XCTAssertEqual(String(describing: observed), "NativeEnrollmentStoredCredential(redacted)")
        }
        XCTAssertTrue(api.responses.isEmpty)
        XCTAssertEqual(api.queries.count, 6)
        XCTAssertTrue(api.adds.isEmpty)
    }
    func testOnlyCanonicalFalseOrExactNumericZeroPassNonsyncPolicy() throws {
        let rejected: [Any] = [kCFBooleanTrue as Any, NSNumber(value: 1), NSNumber(value: -1),
            NSNumber(value: 0.5), NSNumber(value: Double.leastNonzeroMagnitude),
            NSNumber(value: Double.nan), NSNumber(value: Double.infinity), "0", "false", Data([0])]
        for sync in rejected {
            let api = API(), backend = NativeEnrollmentKeychainBackend(api: api)
            var row = item(); row[kSecAttrSynchronizable as String] = sync
            api.result = (errSecSuccess, [row] as CFArray)
            XCTAssertThrowsError(try backend.enumerateBounded(maximum: 193)) { error in
                XCTAssertEqual(error as? NativeEnrollmentKeychainBackend.Failure, .malformedResult)
            }
            XCTAssertThrowsError(try backend.readExactPersistentReference(Data("original-ref".utf8))) { error in
                XCTAssertEqual(error as? NativeEnrollmentKeychainBackend.Failure, .malformedResult)
            }
            XCTAssertEqual(api.queries.count, 2)
            XCTAssertTrue(api.adds.isEmpty)
        }
    }
    func testOverflowAndSynchronizableImpostorRejectBeforeAnyAdd() throws {
        let api = API(), backend = NativeEnrollmentKeychainBackend(api: api)
        api.result = (errSecSuccess, Array(repeating: item(), count: 194) as CFArray)
        XCTAssertThrowsError(try backend.enumerateBounded(maximum: 193))
        var impostor = item(); impostor[kSecAttrSynchronizable as String] = kCFBooleanTrue
        api.result = (errSecSuccess, [impostor] as CFArray)
        XCTAssertThrowsError(try backend.enumerateBounded(maximum: 193))
        api.result = (errSecSuccess, [item(account: String(repeating: "a", count: 129))] as CFArray)
        XCTAssertThrowsError(try backend.enumerateBounded(maximum: 193))
        XCTAssertTrue(api.adds.isEmpty)
    }
    func testDeniedIsNotAbsenceAndPersistentReferenceMustMatch() throws {
        let api = API(), backend = NativeEnrollmentKeychainBackend(api: api)
        api.result = (errSecInteractionNotAllowed, nil)
        XCTAssertThrowsError(try backend.enumerateBounded(maximum: 193))
        api.result = (errSecSuccess, [item()] as CFArray)
        XCTAssertThrowsError(try backend.readExactPersistentReference(Data("foreign-ref".utf8)))
        XCTAssertNotNil(try backend.readExactPersistentReference(Data("original-ref".utf8)))
        XCTAssertEqual(try backend.generateOriginal48().count, 48)
        XCTAssertThrowsError(try backend.insertFinalOnly(account: Data("original".utf8), original48: Data(count: 32)))
        XCTAssertThrowsError(try backend.insertStageOnly(account: Data("invalid/account".utf8), envelope: Data([1])))
    }
}
