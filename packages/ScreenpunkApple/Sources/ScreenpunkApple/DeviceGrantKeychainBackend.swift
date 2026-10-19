import Foundation
import Security
import LocalAuthentication
@_spi(DeviceGrantTransport) import ScreenpunkCore

/// Injected calls only. There is no update/delete operation or implicit production constructor.
protocol DeviceGrantSecurityAPI: Sendable {
    func copy(_ query: [String:Any]) -> DeviceGrantSecurityResult
    func add(_ attributes: [String:Any]) -> DeviceGrantSecurityResult
}
struct DeviceGrantSecurityResult: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let status: OSStatus
    let value: CFTypeRef?
    var description: String { "Grant Security result (redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self,children:[:]) }
}
/// Available for a future explicitly reviewed caller; no instance or live call is made by this slice.
struct DeviceGrantSystemSecurityAPI: DeviceGrantSecurityAPI {
    func copy(_ query: [String:Any]) -> DeviceGrantSecurityResult {
        var value: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary,&value)
        return .init(status:status,value:value)
    }
    func add(_ attributes: [String:Any]) -> DeviceGrantSecurityResult {
        var value: CFTypeRef?; let status = SecItemAdd(attributes as CFDictionary,&value)
        return .init(status:status,value:value)
    }
}
/// Unmounted, exact-root grant namespace only. No legacy vault, Cloud installation, enrollment stage,
/// reset, pruning, production default or authority operation. SecItem acknowledgment does not prove
/// physical durability. Stable reference/relaunch/replacement behavior needs disposable-app qualification.
/// Numeric row limits bound our inventory/copies, not Security.framework's internal allocation.
/// No new mutex/flock; external visitors are called outside any adapter lock and may reenter.
final class DeviceGrantKeychainBackend: DeviceGrantCredentialTransport, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let rootID: UUID
    private let namespace: DeviceGrantCredentialNamespace
    private let api: any DeviceGrantSecurityAPI
    private struct Row: Equatable { let account: String; let byteCount: Int; let descriptor: Data }
    private struct PrivateRead { let observation: DeviceGrantCredentialObservation; let bytes: Data }
    init(rootID: UUID, api: any DeviceGrantSecurityAPI) { self.rootID = rootID; namespace = .init(rootID:rootID); self.api = api }
    var description: String { "Unmounted immutable grant backend (redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self,children:[:]) }

    func inventory(maximum: Int, visit: (DeviceGrantCredentialObservation) throws -> Void) throws {
        guard (1...DeviceGrantCredentialTransportBounds.itemLimit).contains(maximum) else { throw DeviceGrantCredentialTransportFailure.capacity }
        let rows = try snapshot(maximum:maximum)
        var observations: [DeviceGrantCredentialObservation] = [], references = Set<Data>()
        // snapshot checks the CFArray bound before constructing our collections. No private data queried.
        for row in rows {
            let observation = try reference(row)
            guard references.insert(observation.persistentReference).inserted else { throw DeviceGrantCredentialTransportFailure.changedInventory }
            observations.append(observation)
        }
        for observation in observations { try visit(observation) }
        guard try snapshot(maximum:maximum) == rows else { throw DeviceGrantCredentialTransportFailure.changedInventory }
        for (row,observation) in zip(rows,observations) {
            guard try reference(row) == observation else { throw DeviceGrantCredentialTransportFailure.changedInventory }
        }
    }
    func read(account: String, maximumBytes: Int) throws -> DeviceGrantCredentialTransportSecret? {
        guard let value = try readPrivate(account:account,maximumBytes:maximumBytes) else { return nil }
        return try .init(observation:value.observation,bytes:value.bytes)
    }
    func add(account: String, bytes: Data) throws -> DeviceGrantCredentialObservation {
        let parsed = try DeviceGrantCredentialAccount(validating:account)
        guard (1...parsed.byteLimit).contains(bytes.count) else { throw DeviceGrantCredentialTransportFailure.sizeLimit }
        guard try snapshot(maximum:1,account:account).isEmpty else { throw DeviceGrantCredentialTransportFailure.duplicateItem }
        var attributes = base(account:account)
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrGeneric as String] = descriptor(parsed,count:bytes.count)
        attributes[kSecValueData as String] = bytes
        attributes[kSecReturnPersistentRef as String] = true
        let result = api.add(attributes)
        if result.status == errSecDuplicateItem { throw DeviceGrantCredentialTransportFailure.duplicateItem }
        guard result.status == errSecSuccess else { throw DeviceGrantCredentialTransportFailure.inaccessible(result.status) }
        // The new identity comes from SecItemAdd, NEVER from a later same-byte account lookup.
        let addedReference = try data(result.value,maximum:DeviceGrantCredentialTransportBounds.persistentReferenceLimit,nonempty:true)
        let observed = try readPrivate(account:account,maximumBytes:bytes.count)
        guard let observed, observed.observation.persistentReference == addedReference, observed.bytes == bytes else { throw DeviceGrantCredentialTransportFailure.changedInventory }
        return observed.observation
    }
    private func readPrivate(account: String, maximumBytes: Int) throws -> PrivateRead? {
        let parsed = try DeviceGrantCredentialAccount(validating:account)
        guard (1...parsed.byteLimit).contains(maximumBytes) else { throw DeviceGrantCredentialTransportFailure.sizeLimit }
        let rows = try snapshot(maximum:1,account:account)
        guard let row = rows.first else { return nil }
        guard row.byteCount <= maximumBytes else { throw DeviceGrantCredentialTransportFailure.sizeLimit }
        let observation = try reference(row)
        // Persistent-reference lookup has no synchronizable query key. Returned attributes are checked.
        var query = base()
        query.removeValue(forKey:kSecAttrService as String)
        query[kSecValuePersistentRef as String] = observation.persistentReference
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecReturnData as String] = true
        let result = api.copy(query)
        guard result.status == errSecSuccess else { throw DeviceGrantCredentialTransportFailure.inaccessible(result.status) }
        let dictionary = try dictionary(result.value)
        guard try decodeRow(dictionary,allowPrivateData:true) == row,
              try data(value(dictionary,kSecValuePersistentRef),maximum:DeviceGrantCredentialTransportBounds.persistentReferenceLimit,nonempty:true) == observation.persistentReference else { throw DeviceGrantCredentialTransportFailure.changedInventory }
        let bytes = try data(value(dictionary,kSecValueData),maximum:maximumBytes,nonempty:true)
        guard bytes.count == row.byteCount, try snapshot(maximum:1,account:account) == rows,
              try reference(row) == observation else { throw DeviceGrantCredentialTransportFailure.changedInventory }
        return .init(observation:observation,bytes:bytes)
    }
    /// Includes synchronizable impostors, which fail policy validation instead of being filtered away.
    /// Apple's synchronizable queries support attributes/data, not persistent references: two phases.
    private func snapshot(maximum: Int, account: String? = nil) throws -> [Row] {
        var query = base(account:account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecMatchLimit as String] = NSNumber(value:maximum+1)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = false
        let result = api.copy(query)
        if result.status == errSecItemNotFound { return [] }
        guard result.status == errSecSuccess else { throw DeviceGrantCredentialTransportFailure.inaccessible(result.status) }
        let array = try array(result.value,maximum:maximum)
        guard CFArrayGetCount(array) > 0 else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        var rows: [Row] = [], seen = Set<String>()
        for index in 0..<CFArrayGetCount(array) {
            let row = try decodeRow(dictionary(element(array,index)),allowPrivateData:false)
            if let account { guard row.account.utf8.elementsEqual(account.utf8) else { throw DeviceGrantCredentialTransportFailure.changedInventory } }
            guard seen.insert(row.account).inserted else { throw DeviceGrantCredentialTransportFailure.changedInventory }; rows.append(row)
        }
        return rows.sorted { $0.account < $1.account }
    }
    private func reference(_ expected: Row) throws -> DeviceGrantCredentialObservation {
        var query = base(account:expected.account) // Omitted synchronizable key means nonsynchronized.
        query[kSecMatchLimit as String] = NSNumber(value:2)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecReturnData as String] = false
        let result = api.copy(query)
        guard result.status == errSecSuccess else { throw DeviceGrantCredentialTransportFailure.inaccessible(result.status) }
        let array = try array(result.value,maximum:1)
        guard CFArrayGetCount(array) == 1 else { throw DeviceGrantCredentialTransportFailure.changedInventory }
        let dictionary = try dictionary(element(array,0))
        guard try decodeRow(dictionary,allowPrivateData:false) == expected else { throw DeviceGrantCredentialTransportFailure.changedInventory }
        return try .init(account:expected.account,
            persistentReference:data(value(dictionary,kSecValuePersistentRef),maximum:DeviceGrantCredentialTransportBounds.persistentReferenceLimit,nonempty:true),byteCount:expected.byteCount)
    }
    private func base(account: String? = nil) -> [String:Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        var query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:namespace.service,kSecUseAuthenticationContext as String:context]
        if let account { query[kSecAttrAccount as String] = account }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
    /// Exactly 42 bytes: SPGR/version/kind/root UUID/account UUID/UInt32 big-endian byte count.
    private func descriptor(_ account: DeviceGrantCredentialAccount, count: Int) -> Data {
        var bytes = Data([83,80,71,82,1,account.kind.rawValue])
        var root = rootID.uuid, id = account.id.uuid
        withUnsafeBytes(of:&root) { bytes.append(contentsOf:$0) }; withUnsafeBytes(of:&id) { bytes.append(contentsOf:$0) }
        let count = UInt32(count); bytes.append(contentsOf:[UInt8(truncatingIfNeeded:count >> 24),UInt8(truncatingIfNeeded:count >> 16),UInt8(truncatingIfNeeded:count >> 8),UInt8(truncatingIfNeeded:count)])
        return bytes
    }
    private func decodeRow(_ dictionary: CFDictionary, allowPrivateData: Bool) throws -> Row {
        if !allowPrivateData, value(dictionary,kSecValueData) != nil { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        if let suppliedClass = value(dictionary,kSecClass) {
            guard try string(suppliedClass,maximum:16).utf8.elementsEqual((kSecClassGenericPassword as String).utf8) else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        }
        guard try string(value(dictionary,kSecAttrService),maximum:128).utf8.elementsEqual(namespace.service.utf8),
              try string(value(dictionary,kSecAttrAccessible),maximum:128).utf8.elementsEqual((kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String).utf8),
              try !boolean(value(dictionary,kSecAttrSynchronizable),defaultValue:false) else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        let account = try string(value(dictionary,kSecAttrAccount),maximum:47), parsed = try DeviceGrantCredentialAccount(validating:account)
        let metadata = try data(value(dictionary,kSecAttrGeneric),maximum:42,nonempty:true)
        guard metadata.count == 42 else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        let count = metadata.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= parsed.byteLimit, metadata == descriptor(parsed,count:Int(count)) else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        return .init(account:account,byteCount:Int(count),descriptor:metadata)
    }
    private func element(_ array: CFArray, _ index: Int) -> CFTypeRef? {
        guard let pointer = CFArrayGetValueAtIndex(array,index) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
    private func value(_ dictionary: CFDictionary, _ key: CFString) -> CFTypeRef? {
        guard let pointer = CFDictionaryGetValue(dictionary,Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
    private func array(_ value: CFTypeRef?, maximum: Int) throws -> CFArray {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        let array = unsafeBitCast(value,to:CFArray.self)
        guard CFArrayGetCount(array) <= maximum else { throw DeviceGrantCredentialTransportFailure.capacity }; return array
    }
    private func dictionary(_ value: CFTypeRef?) throws -> CFDictionary {
        guard let value, CFGetTypeID(value) == CFDictionaryGetTypeID() else { throw DeviceGrantCredentialTransportFailure.invalidObservation }; return unsafeBitCast(value,to:CFDictionary.self)
    }
    private func string(_ value: CFTypeRef?, maximum: Int) throws -> String {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        let string = unsafeBitCast(value,to:CFString.self), count = CFStringGetLength(string)
        guard count <= maximum else { throw DeviceGrantCredentialTransportFailure.sizeLimit }
        var bytes: [UInt8] = []
        for index in 0..<count { let code = CFStringGetCharacterAtIndex(string,index); guard code > 0 && code < 128 else { throw DeviceGrantCredentialTransportFailure.invalidObservation }; bytes.append(UInt8(code)) }
        return String(decoding:bytes,as:UTF8.self)
    }
    private func boolean(_ value: CFTypeRef?, defaultValue: Bool) throws -> Bool {
        guard let value else { return defaultValue }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw DeviceGrantCredentialTransportFailure.invalidObservation }; return CFBooleanGetValue(unsafeBitCast(value,to:CFBoolean.self))
    }
    private func data(_ value: CFTypeRef?, maximum: Int, nonempty: Bool) throws -> Data {
        guard let value, CFGetTypeID(value) == CFDataGetTypeID() else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        let data = unsafeBitCast(value,to:CFData.self), count = CFDataGetLength(data)
        guard count <= maximum else { throw DeviceGrantCredentialTransportFailure.sizeLimit }
        guard !nonempty || count > 0 else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        if count == 0 { return Data() }
        guard let bytes = CFDataGetBytePtr(data) else { throw DeviceGrantCredentialTransportFailure.invalidObservation }; return Data(bytes:bytes,count:count)
    }
}
