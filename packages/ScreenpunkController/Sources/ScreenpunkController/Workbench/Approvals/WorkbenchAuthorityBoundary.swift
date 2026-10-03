import Foundation

/// The broker owns one instance for its selected workspace and native owner.
/// M3 mutations and M4 admission/first-send must use this same instance.
/// A serial per-user broker, not an IPC caller field, supplies it.
final class WorkbenchAuthorityBoundary {
    let lock = NSRecursiveLock()

    func withDevice<T>(_ deviceId: String, _ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    /// Host integration must wrap selection/open/relocate and operation drain
    /// in this boundary. The domain cannot intercept arbitrary WorkspaceStore
    /// callers, so deployment routes stay closed until that wiring exists.
    func withWorkspaceSelection<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
