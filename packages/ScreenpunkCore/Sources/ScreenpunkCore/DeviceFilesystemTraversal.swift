import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Filesystem traversal policy, never store/installation authority. On iOS the
/// OS-provided app home is the root; global ancestors are outside the sandbox.
@_spi(NativeFilesystem) public struct DeviceFilesystemTraversal {
    enum Failure: Error { case invalidPath, unavailable(Int32) }
    public let rootPath: String
    public let components: [String]
    public static func plan(for path: String) throws -> Self {
        #if os(iOS)
        let supplied = NSHomeDirectory()
        guard valid(supplied) else { throw Failure.invalidPath }
        guard let physical = realpath(supplied, nil) else { throw Failure.unavailable(errno) }
        defer { free(physical) }
        guard strnlen(physical, 4097) <= 4096 else { throw Failure.invalidPath }
        return try confined(path: path, systemHome: supplied, physicalHome: String(cString: physical))
        #else
        guard valid(path) else { throw Failure.invalidPath }
        return .init(rootPath: "/", components: path.split(separator: "/").map(String.init))
        #endif
    }
    /// Internal synthetic-container control. Only production's exact OS root and
    /// its physical spelling are accepted; caller components are never resolved.
    static func confined(path: String, systemHome: String, physicalHome: String) throws -> Self {
        guard valid(path), valid(systemHome), valid(physicalHome) else { throw Failure.invalidPath }
        let root: String
        if path == physicalHome || path.hasPrefix(physicalHome + "/") { root = physicalHome }
        else if path == systemHome || path.hasPrefix(systemHome + "/") { root = systemHome }
        else { throw Failure.invalidPath }
        let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
        return .init(rootPath: physicalHome, components: relative.split(separator: "/").map(String.init))
    }
    private static func valid(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096 && !path.utf8.contains(0) &&
        !path.hasSuffix("/") && !path.contains("//") && path.split(separator: "/").count <= 128 &&
        path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }
}
