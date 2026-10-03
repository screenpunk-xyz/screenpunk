import Foundation

/// Transport observations are supplied data, never grant authority or physical durability proof.
/// This SPI does not expose the structural/preparation stores or qualified authority values.
@_spi(DeviceGrantTransport) public enum DeviceGrantCredentialTransportFailure: Error, Equatable, Sendable {
    case invalidAccount, invalidObservation, sizeLimit, capacity, namespaceMismatch, changedInventory, duplicateItem
    case inaccessible(Int32)
}
@_spi(DeviceGrantTransport) public enum DeviceGrantCredentialTransportBounds {
    public static let itemLimit = GrantPreparationCodec.itemLimit
    public static let privateIntentLimit = GrantPreparationCodec.intentLimit
    public static let credentialLimit = GrantPreparationCodec.credentialLimit
    public static let persistentReferenceLimit = 4096
}
@_spi(DeviceGrantTransport) public struct DeviceGrantCredentialAccount: Equatable, Sendable {
    public enum Kind: UInt8, Sendable { case attempt = 0, credential = 1 }
    public let kind: Kind
    public let id: UUID
    public var name: String { (kind == .attempt ? "attempt." : "credential.") + id.uuidString.lowercased() }
    public var byteLimit: Int { kind == .attempt ? DeviceGrantCredentialTransportBounds.privateIntentLimit : DeviceGrantCredentialTransportBounds.credentialLimit }
    public init(kind: Kind, id: UUID) { self.kind = kind; self.id = id }
    public init(validating name: String) throws {
        guard name.utf8.count <= 47 else { throw DeviceGrantCredentialTransportFailure.invalidAccount }
        let kind: Kind, prefix: String
        if name.hasPrefix("attempt.") { kind = .attempt; prefix = "attempt." }
        else if name.hasPrefix("credential.") { kind = .credential; prefix = "credential." }
        else { throw DeviceGrantCredentialTransportFailure.invalidAccount }
        guard let id = UUID(uuidString:String(name.dropFirst(prefix.count))) else { throw DeviceGrantCredentialTransportFailure.invalidAccount }
        self.init(kind:kind,id:id)
        guard self.name.utf8.elementsEqual(name.utf8) else { throw DeviceGrantCredentialTransportFailure.invalidAccount }
    }
}
@_spi(DeviceGrantTransport) public struct DeviceGrantCredentialNamespace: Sendable {
    public let rootID: UUID
    public var service: String { GrantPreparationCodec.service(rootID) }
    public init(rootID: UUID) { self.rootID = rootID }
}
@_spi(DeviceGrantTransport) public struct DeviceGrantCredentialObservation: Equatable, Sendable {
    public let account: String
    public let persistentReference: Data
    public let byteCount: Int
    public init(account: String, persistentReference: Data, byteCount: Int) throws {
        let parsed = try DeviceGrantCredentialAccount(validating:account)
        guard (1...parsed.byteLimit).contains(byteCount), !persistentReference.isEmpty,
              persistentReference.count <= DeviceGrantCredentialTransportBounds.persistentReferenceLimit else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        self.account = account; self.persistentReference = persistentReference; self.byteCount = byteCount
    }
}
/// No secret getter, Codable representation or hash. Only this file's internal backend conversion
/// can consume the private payload. Descriptions/reflection cannot expose private bytes.
@_spi(DeviceGrantTransport) public final class DeviceGrantCredentialTransportSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let observation: DeviceGrantCredentialObservation
    fileprivate let privateBytes: Data
    public init(observation: DeviceGrantCredentialObservation, bytes: Data) throws {
        guard bytes.count == observation.byteCount else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        self.observation = observation; privateBytes = bytes
    }
    public var description: String { "Grant credential transport payload (redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self,children:[:]) }
}
/// Visits are synchronous/nonconcurrent and must propagate visitor failures. No update/delete API.
/// Implementations bind one explicit root namespace and return immutable bytes/stable item identities.
/// This contract is unmounted; a future platform qualification must establish its actual behavior.
@_spi(DeviceGrantTransport) public protocol DeviceGrantCredentialTransport: Sendable {
    var rootID: UUID { get }
    func inventory(maximum: Int, visit: (DeviceGrantCredentialObservation) throws -> Void) throws
    func read(account: String, maximumBytes: Int) throws -> DeviceGrantCredentialTransportSecret?
    func add(account: String, bytes: Data) throws -> DeviceGrantCredentialObservation
}
/// Internal conversion only: no widening of existing store, input, receipt or authority interfaces.
/// Holds no mutex/flock and invokes visitors directly; reentry does not acquire a new adapter lock.
final class DeviceGrantCredentialTransportBackend: DeviceGrantCredentialBackend {
    private let namespace: DeviceGrantCredentialNamespace
    private let transport: any DeviceGrantCredentialTransport
    init(rootID: UUID, transport: any DeviceGrantCredentialTransport) throws {
        namespace = .init(rootID:rootID); self.transport = transport
        guard transport.rootID == rootID else { throw DeviceGrantCredentialTransportFailure.namespaceMismatch }
    }
    private func binding(_ service: String) throws {
        guard transport.rootID == namespace.rootID, service.utf8.elementsEqual(namespace.service.utf8) else { throw DeviceGrantCredentialTransportFailure.namespaceMismatch }
    }
    private func item(_ observation: DeviceGrantCredentialObservation) -> DeviceGrantCredentialItem {
        .init(account:observation.account,persistentReference:observation.persistentReference,byteCount:observation.byteCount)
    }
    func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {
        try binding(service)
        guard (1...DeviceGrantCredentialTransportBounds.itemLimit).contains(maximum) else { throw DeviceGrantCredentialTransportFailure.capacity }
        var count = 0, seen = Set<String>(), references = Set<Data>()
        try transport.inventory(maximum:maximum) { observation in
            count += 1
            guard count <= maximum else { throw DeviceGrantCredentialTransportFailure.capacity }
            guard seen.insert(observation.account).inserted, references.insert(observation.persistentReference).inserted else { throw DeviceGrantCredentialTransportFailure.changedInventory }
            try binding(service); try visit(item(observation))
        }
        try binding(service)
    }
    func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? {
        try binding(service); let parsed = try DeviceGrantCredentialAccount(validating:account)
        guard (1...parsed.byteLimit).contains(maximumBytes) else { throw DeviceGrantCredentialTransportFailure.sizeLimit }
        guard let value = try transport.read(account:account,maximumBytes:maximumBytes) else { try binding(service); return nil }
        try binding(service)
        guard value.observation.account.utf8.elementsEqual(account.utf8), value.observation.byteCount <= maximumBytes,
              value.privateBytes.count == value.observation.byteCount else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        return .init(item:item(value.observation),bytes:value.privateBytes)
    }
    func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem {
        try binding(service); let parsed = try DeviceGrantCredentialAccount(validating:account)
        guard (1...parsed.byteLimit).contains(bytes.count) else { throw DeviceGrantCredentialTransportFailure.sizeLimit }
        let result = try transport.add(account:account,bytes:bytes); try binding(service)
        guard result.account.utf8.elementsEqual(account.utf8), result.byteCount == bytes.count else { throw DeviceGrantCredentialTransportFailure.invalidObservation }
        return item(result)
    }
}
