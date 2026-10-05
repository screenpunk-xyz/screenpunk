import Foundation
import Security
@_spi(NativeInstallation) @_spi(DeviceGrantTransport) import ScreenpunkCore

/// Add-only fixed installation namespaces. No update, deletion or secret getter.
@_spi(NativeInstallation) public final class NativeEnrollmentKeychainBackend: NativeEnrollmentCredentialStorage {
    static let finalService = "xyz.screenpunk.installation.cloud"
    static let stageService = "xyz.screenpunk.installation.cloud.enrollment-stage.v1"
    enum Failure: Error, Equatable { case invalidInput, malformedResult, inaccessible(Int32), randomFailure }
    private let api: any NativeEnrollmentSecurityAPI
    /// Actual add-only grant transport for the explicit dedicated native root.
    public static func grantTransport(rootID: UUID) -> any DeviceGrantCredentialTransport {
        DeviceGrantKeychainBackend(rootID: rootID, api: DeviceGrantSystemSecurityAPI())
    }
    public convenience init() { self.init(api: NativeEnrollmentSystemSecurityAPI()) }
    init(api: any NativeEnrollmentSecurityAPI) { self.api = api }
    private func base(service: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        #endif
        if let service { q[kSecAttrService as String] = service }
        return q
    }
    public func enumerateBounded(maximum: Int) throws -> [NativeEnrollmentStoredCredential] {
        guard (1...193).contains(maximum) else { throw Failure.invalidInput }
        var result: [NativeEnrollmentStoredCredential] = []
        for service in [Self.finalService, Self.stageService] {
            let remaining = maximum - result.count
            if remaining == 0 { return result } // Full numeric limit is the overflow witness.
            var q = base(service: service)
            q[kSecMatchLimit as String] = NSNumber(value: remaining)
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            q[kSecReturnAttributes as String] = kCFBooleanTrue
            q[kSecReturnData as String] = kCFBooleanTrue // Any-sync query cannot request persistent refs.
            let (status, raw) = api.copyMatching(q as CFDictionary)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw Failure.inaccessible(status) }
            let values = try array(raw, maximum: remaining)
            for value in values {
                let baseline = try row(value as AnyObject, expectedService: service)
                var exact = base(service: service)
                exact[kSecAttrAccount as String] = String(decoding: baseline.account, as: UTF8.self)
                exact[kSecMatchLimit as String] = NSNumber(value: 2); returns(&exact)
                let (lookupStatus, lookupRaw) = api.copyMatching(exact as CFDictionary)
                guard lookupStatus == errSecSuccess else { throw Failure.inaccessible(lookupStatus) }
                let lookup = try array(lookupRaw, maximum: 2)
                guard lookup.count == 1, try row(lookup[0] as AnyObject, expectedService: service) == baseline else { throw Failure.malformedResult }
                result.append(try item(lookup[0] as AnyObject, expectedService: service))
            }
        }
        return result
    }
    public func generateOriginal48() throws -> Data {
        let bytes = try api.random48()
        guard bytes.count == 48 else { throw Failure.randomFailure }; return bytes
    }
    public func readExactPersistentReference(_ reference: Data) throws -> NativeEnrollmentStoredCredential? {
        guard (1...1024).contains(reference.count) else { throw Failure.invalidInput }
        var q = base(); q.removeValue(forKey: kSecAttrSynchronizable as String); q[kSecValuePersistentRef as String] = reference
        q[kSecMatchLimit as String] = NSNumber(value: 2); returns(&q)
        let (status, raw) = api.copyMatching(q as CFDictionary)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.inaccessible(status) }
        let values = try array(raw, maximum: 2)
        guard values.count == 1 else { throw Failure.malformedResult }
        return try item(values[0] as AnyObject, expectedReference: reference)
    }
    public func insertStageOnly(account: Data, envelope: Data) throws -> NativeEnrollmentCredentialInsert {
        guard (1...4096).contains(envelope.count) else { throw Failure.invalidInput }
        return try insert(service: Self.stageService, account: account, payload: envelope)
    }
    public func insertFinalOnly(account: Data, original48: Data) throws -> NativeEnrollmentCredentialInsert {
        guard original48.count == 48 else { throw Failure.invalidInput }
        return try insert(service: Self.finalService, account: account, payload: original48)
    }
    private func insert(service: String, account: Data, payload: Data) throws -> NativeEnrollmentCredentialInsert {
        try validateAccount(account)
        var q = base(service: service)
        q[kSecAttrAccount as String] = String(decoding: account, as: UTF8.self)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecValueData as String] = payload
        q[kSecReturnPersistentRef as String] = kCFBooleanTrue
        let (status, raw) = api.add(q as CFDictionary)
        if status == errSecDuplicateItem { return .duplicate } // Never read/adopt an unrelated duplicate.
        guard status == errSecSuccess else { throw Failure.inaccessible(status) }
        let ref = try boundedData(raw, maximum: 1024)
        guard !ref.isEmpty else { throw Failure.malformedResult }
        return .inserted(ref)
    }
    private func returns(_ q: inout [String: Any]) {
        q[kSecReturnAttributes as String] = kCFBooleanTrue
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecReturnPersistentRef as String] = kCFBooleanTrue
    }
    private struct Row: Equatable { let service: String, account: Data, payload: Data }
    private func dictionary(_ value: CFTypeRef) throws -> CFDictionary {
        guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { throw Failure.malformedResult }
        let dictionary = unsafeBitCast(value, to: CFDictionary.self)
        guard CFDictionaryGetCount(dictionary) <= 32 else { throw Failure.malformedResult }; return dictionary
    }
    private func value(_ dictionary: CFDictionary, _ key: CFString) -> CFTypeRef? {
        guard let pointer = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
    private func array(_ value: CFTypeRef?, maximum: Int) throws -> [AnyObject] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { throw Failure.malformedResult }
        let array = unsafeBitCast(value, to: CFArray.self), count = CFArrayGetCount(array)
        guard count <= maximum else { throw Failure.malformedResult }
        return try (0..<count).map { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { throw Failure.malformedResult }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        }
    }
    private func text(_ d: CFDictionary, _ key: CFString) throws -> String {
        guard let value = self.value(d, key), CFGetTypeID(value) == CFStringGetTypeID() else { throw Failure.malformedResult }
        let string = unsafeBitCast(value, to: CFString.self), count = CFStringGetLength(string)
        guard count <= 128 else { throw Failure.malformedResult }
        var bytes: [UInt8] = []
        for index in 0..<count {
            let code = CFStringGetCharacterAtIndex(string, index)
            guard code > 0 && code < 128 else { throw Failure.malformedResult }; bytes.append(UInt8(code))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    private func boundedData(_ value: CFTypeRef?, maximum: Int) throws -> Data {
        guard let value, CFGetTypeID(value) == CFDataGetTypeID() else { throw Failure.malformedResult }
        let data = unsafeBitCast(value, to: CFData.self), count = CFDataGetLength(data)
        guard count <= maximum else { throw Failure.malformedResult }
        if count == 0 { return Data() }
        guard let pointer = CFDataGetBytePtr(data) else { throw Failure.malformedResult }
        return Data(bytes: pointer, count: count)
    }
    private func bytes(_ d: CFDictionary, _ key: CFString) throws -> Data {
        try boundedData(value(d, key), maximum: CFEqual(key, kSecValuePersistentRef) ? 1024 : 4096)
    }
    private func nonsynchronizable(_ d: CFDictionary) throws -> Bool {
        guard let value = self.value(d, kSecAttrSynchronizable) else { return true }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure.malformedResult }
        return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }
    private func row(_ value: CFTypeRef, expectedService: String? = nil) throws -> Row {
        let d = try dictionary(value)
        let service = try text(d, kSecAttrService), account = Data(try text(d, kSecAttrAccount).utf8), payload = try bytes(d, kSecValueData)
        guard [Self.finalService, Self.stageService].contains(service), expectedService == nil || expectedService == service,
            try text(d, kSecAttrAccessible) == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
            try nonsynchronizable(d),
            service == Self.stageService ? (1...4096).contains(payload.count) : [32, 48].contains(payload.count) else { throw Failure.malformedResult }
        try validateAccount(account)
        return Row(service: service, account: account, payload: payload)
    }
    private func item(_ value: CFTypeRef, expectedService: String? = nil, expectedReference: Data? = nil) throws -> NativeEnrollmentStoredCredential {
        let d = try dictionary(value), observed = try row(value, expectedService: expectedService), ref = try bytes(d, kSecValuePersistentRef)
        guard expectedReference == nil || expectedReference == ref, (1...1024).contains(ref.count) else { throw Failure.malformedResult }
        return .init(service: Data(observed.service.utf8), account: observed.account, persistentReference: ref, payload: observed.payload, accessible: true)
    }
    private func validateAccount(_ account: Data) throws {
        guard (1...128).contains(account.count), account.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else { throw Failure.invalidInput }
    }
}

protocol NativeEnrollmentSecurityAPI {
    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?)
    func add(_ query: CFDictionary) -> (OSStatus, CFTypeRef?)
    func random48() throws -> Data
}
private struct NativeEnrollmentSystemSecurityAPI: NativeEnrollmentSecurityAPI {
    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) { var value: CFTypeRef?; let status = SecItemCopyMatching(query, &value); return (status, value) }
    func add(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) { var value: CFTypeRef?; let status = SecItemAdd(query, &value); return (status, value) }
    func random48() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 48)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NativeEnrollmentKeychainBackend.Failure.randomFailure }
        return Data(bytes)
    }
}
