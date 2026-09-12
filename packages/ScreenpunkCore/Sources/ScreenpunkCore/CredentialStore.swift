import Foundation

/// Native secret storage. Implementations must not write secrets to packages, logs, or MCP.
public protocol CredentialStore: Sendable {
    func secret(for authRef: String) throws -> Data?
    func put(_ secret: Data, for authRef: String) throws
    func delete(_ authRef: String) throws
    func deleteAll() throws
}

public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    public init() {}

    public func secret(for authRef: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[authRef]
    }

    public func put(_ secret: Data, for authRef: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[authRef] = secret
    }

    public func delete(_ authRef: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: authRef)
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeAll()
    }

    public var debugDescription: String {
        "MemoryCredentialStore(count: redacted)"
    }
}
