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
    /// Persisted locator compatibility only. Never use this to admit a live caller
    /// path: plan(for:) remains confined to the current OS home. No old path is opened.
    public static func currentPath(forRecordedPath path: String) throws -> String {
        #if os(iOS)
        let system = NSHomeDirectory()
        guard valid(system), let raw = realpath(system, nil) else { throw Failure.invalidPath }
        defer { free(raw) }
        guard strnlen(raw, 4097) <= 4096 else { throw Failure.invalidPath }
        return try currentRecordedPath(path, systemHome: system, physicalHome: String(cString: raw))
        #else
        guard valid(path) else { throw Failure.invalidPath }
        return path
        #endif
    }
    public static func recordedPath(_ recorded: String, matchesCurrentPath current: String) -> Bool {
        #if os(iOS)
        guard let expected = try? plan(for: current),
              let actual = try? currentPath(forRecordedPath: recorded) else { return false }
        let path = expected.rootPath + (expected.components.isEmpty ? "" : "/" + expected.components.joined(separator: "/"))
        return actual.utf8.elementsEqual(path.utf8)
        #else
        return recorded.utf8.elementsEqual(current.utf8)
        #endif
    }
    static func recordedPaths(_ recorded: [String], matchCurrentPaths current: [String]) -> Bool {
        recorded.count == current.count && zip(recorded, current).allSatisfy { recordedPath($0, matchesCurrentPath: $1) }
    }
    /// Pure decoder seam for physical and Simulator OS-home fixtures. The old UUID
    /// is a locator component, never identity: every caller still checks its exact
    /// root ID, retained node identities and canonical record/digest bytes.
    static func currentRecordedPath(_ path: String, systemHome: String, physicalHome: String) throws -> String {
        if let current = try? confined(path: path, systemHome: systemHome, physicalHome: physicalHome) {
            return current.rootPath + (current.components.isEmpty ? "" : "/" + current.components.joined(separator: "/"))
        }
        guard valid(systemHome), valid(physicalHome) else { throw Failure.invalidPath }
        let relative: String
        let version = "screenpunk-app-home:v1/"
        if path.hasPrefix(version) {
            relative = String(path.dropFirst(version.count))
            guard valid("/" + relative) else { throw Failure.invalidPath }
        } else {
            guard valid(path) else { throw Failure.invalidPath }
            func containerParent(_ home: String) -> String? {
                let parts = home.split(separator: "/")
                guard parts.count >= 4, Array(parts.suffix(4).dropLast()) == ["Containers", "Data", "Application"],
                      let id = parts.last, let uuid = UUID(uuidString: String(id)), id.count == 36,
                      uuid.uuidString.lowercased() == id.lowercased() else { return nil }
                return "/" + parts.dropLast().joined(separator: "/")
            }
            let parents = Set([systemHome, physicalHome].compactMap(containerParent))
            guard let parent = parents.first(where: { path.hasPrefix($0 + "/") }) else { throw Failure.invalidPath }
            let tail = path.dropFirst(parent.count + 1), parts = tail.split(separator: "/")
            guard parts.count >= 2, let id = parts.first, id.count == 36,
                  let uuid = UUID(uuidString: String(id)), uuid.uuidString.lowercased() == id.lowercased() else { throw Failure.invalidPath }
            relative = parts.dropFirst().joined(separator: "/")
        }
        let result = physicalHome + "/" + relative
        _ = try confined(path: result, systemHome: systemHome, physicalHome: physicalHome)
        return result
    }
    private static func valid(_ path: String) -> Bool {
        var bytes = 0, components = 0, componentLength = 0
        var dotsOnly = true, invalid = false
        for byte in path.utf8 {
            // Preserve Character-based grammar for every non-ASCII spelling,
            // including combining marks attached to a slash or dot.
            if byte >= 0x80 { return validStringGrammar(path) }
            bytes += 1
            if bytes > 4096 { return validStringGrammar(path) }
            if bytes == 1 {
                if byte == 0x2f { components = 1; continue }
                invalid = true
            }
            if byte == 0 { invalid = true }
            if byte == 0x2f {
                if componentLength == 0 || (dotsOnly && componentLength <= 2) { invalid = true }
                components += 1; componentLength = 0; dotsOnly = true
            } else {
                componentLength += 1
                if byte != 0x2e { dotsOnly = false }
            }
        }
        // Delay grammar rejection until the complete spelling is known to be
        // ASCII. A later combining character must take the original fallback.
        return !invalid && bytes > 1 && components <= 128 && componentLength > 0
            && !(dotsOnly && componentLength <= 2)
    }
    private static func validStringGrammar(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096 && !path.utf8.contains(0) &&
        !path.hasSuffix("/") && !path.contains("//") && path.split(separator: "/").count <= 128 &&
        path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }
}

/// Comparison policy only, never store or installation authority. A historical
/// mount number remains original proof data; only an explicitly linked current
/// iOS app-home node may match it by inode and exact protocol location.
/// Recorded-to-recorded and live-to-live comparisons must still remain exact.
struct DevicePersistedFilesystemContext {
    private struct CurrentHome {
        let systemPath: String, physicalPath: String, device: UInt64
    }
    private let rootPath: String
    private let home: CurrentHome?
    private enum Failure: Error { case invalidCurrentHome }

    /// Production obtains its home exclusively from the current OS process.
    /// Non-iOS retains the existing exact durable device+inode semantics.
    static func capture(currentRoot: URL, heldRoot: Int32, plannedPublicationRoot: URL? = nil) throws -> Self {
        guard currentRoot.isFileURL else { throw Failure.invalidCurrentHome }
        #if os(iOS)
        let system = NSHomeDirectory()
        guard let raw = realpath(system, nil) else { throw Failure.invalidCurrentHome }
        defer { free(raw) }
        guard strnlen(raw, 4097) <= 4096 else { throw Failure.invalidCurrentHome }
        return try captureCurrentHome(currentRoot: currentRoot, heldRoot: heldRoot,
            systemHome: system, physicalHome: String(cString: raw), plannedPublicationRoot: plannedPublicationRoot)
        #else
        let plan = try DeviceFilesystemTraversal.plan(for: currentRoot.path)
        let pinned = try publicationPath(plannedPublicationRoot, currentRoot: currentRoot,
            currentPlan: plan, plan: { try DeviceFilesystemTraversal.plan(for: $0) })
        return .init(rootPath: pinned, home: nil)
        #endif
    }

    /// Module-internal synthetic filesystem fixture only. It validates actual
    /// no-follow descriptors below the supplied synthetic home; no global policy
    /// or public/SPI authority constructor can select this production behavior.
    static func syntheticCurrentAppHomeForTesting(currentRoot: URL, heldRoot: Int32,
        systemHome: String, physicalHome: String, plannedPublicationRoot: URL? = nil) throws -> Self {
        try captureCurrentHome(currentRoot: currentRoot, heldRoot: heldRoot,
            systemHome: systemHome, physicalHome: physicalHome, plannedPublicationRoot: plannedPublicationRoot)
    }

    /// Call for every raw current root/lock/operations/file identity. A current
    /// node cannot cross away from the device of the verified current OS home.
    func acceptsCurrentDevice(_ observedDevice: UInt64) -> Bool {
        home.map { observedDevice == $0.device } ?? true
    }

    /// Explicit durable-to-physical edge only, after exact UUID/type/nlink/name,
    /// canonical bytes and protocol location checks. Never use for proof equality
    /// or before/after reads, checkpoints, syncs or other captured live identities.
    func matchesDurableIdentity(recordedDevice: UInt64, recordedInode: UInt64,
        observedDevice: UInt64, observedInode: UInt64) -> Bool {
        guard acceptsCurrentDevice(observedDevice), recordedInode == observedInode else { return false }
        return home != nil || recordedDevice == observedDevice
    }

    /// Lexical planning within the acquisition that captured this context. The
    /// caller must still open every current component without following links.
    /// Historical locator relocation is never applied to a live path.
    func planCurrentPath(_ path: String) throws -> DeviceFilesystemTraversal {
        guard let home else { return try DeviceFilesystemTraversal.plan(for: path) }
        return try DeviceFilesystemTraversal.confined(path: path,
            systemHome: home.systemPath, physicalHome: home.physicalPath)
    }

    /// Comparison only: reuse this acquisition's OS-home spellings, never a
    /// previous filesystem result. The current side remains a confined live path.
    func recordedPath(_ recorded: String, matchesCurrentPath current: String) -> Bool {
        guard let home else { return recorded.utf8.elementsEqual(current.utf8) }
        guard let expected = try? planCurrentPath(current),
            let actual = try? DeviceFilesystemTraversal.currentRecordedPath(recorded,
                systemHome: home.systemPath, physicalHome: home.physicalPath) else { return false }
        let path = expected.rootPath + (expected.components.isEmpty ? "" : "/" + expected.components.joined(separator: "/"))
        return actual.utf8.elementsEqual(path.utf8)
    }

    func recordedPaths(_ recorded: [String], matchCurrentPaths current: [String]) -> Bool {
        recorded.count == current.count && zip(recorded, current).allSatisfy { recordedPath($0, matchesCurrentPath: $1) }
    }

    /// Matches only the pinned store root (or its explicit publication target).
    /// Callers cannot reuse a context held for one root to select another path.
    func matchesRecordedRootPath(_ recordedPath: String) -> Bool {
        guard let home else { return recordedPath.utf8.elementsEqual(rootPath.utf8) }
        guard let expected = try? DeviceFilesystemTraversal.confined(path: rootPath,
                systemHome: home.systemPath, physicalHome: home.physicalPath),
            let recorded = try? DeviceFilesystemTraversal.currentRecordedPath(recordedPath,
                systemHome: home.systemPath, physicalHome: home.physicalPath) else { return false }
        let current = expected.rootPath + (expected.components.isEmpty ? "" : "/" + expected.components.joined(separator: "/"))
        return recorded.utf8.elementsEqual(current.utf8)
    }

    /// The only existing alternate-location protocol is an authority-owned
    /// staging directory renamed under the SAME held parent anchor (Apple
    /// prepareOwnedRootForPromotion). Pin that sibling target at capture; never
    /// open it or allow a free target parameter during later comparison.
    private static func publicationPath(_ publication: URL?, currentRoot: URL,
        currentPlan: DeviceFilesystemTraversal, plan: (String) throws -> DeviceFilesystemTraversal) throws -> String {
        guard let publication else { return currentRoot.path }
        guard publication.isFileURL else { throw Failure.invalidCurrentHome }
        let target = try plan(publication.path)
        guard !currentPlan.components.isEmpty, !target.components.isEmpty,
            target.rootPath == currentPlan.rootPath,
            target.components.dropLast().elementsEqual(currentPlan.components.dropLast()) else { throw Failure.invalidCurrentHome }
        return publication.path
    }

    private static func captureCurrentHome(currentRoot: URL, heldRoot: Int32,
        systemHome: String, physicalHome: String, plannedPublicationRoot: URL?) throws -> Self {
        guard currentRoot.isFileURL else { throw Failure.invalidCurrentHome }
        let plan = try DeviceFilesystemTraversal.confined(path: currentRoot.path,
            systemHome: systemHome, physicalHome: physicalHome)
        let pinned = try publicationPath(plannedPublicationRoot, currentRoot: currentRoot, currentPlan: plan,
            plan: { try DeviceFilesystemTraversal.confined(path: $0, systemHome: systemHome, physicalHome: physicalHome) })
        let anchor = open(plan.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard anchor >= 0 else { throw Failure.invalidCurrentHome }
        defer { close(anchor) }
        var originalHome = stat(), namedHome = stat()
        guard fstat(anchor, &originalHome) == 0, originalHome.st_mode & S_IFMT == S_IFDIR,
            lstat(plan.rootPath, &namedHome) == 0, namedHome.st_mode & S_IFMT == S_IFDIR,
            originalHome.st_dev == namedHome.st_dev, originalHome.st_ino == namedHome.st_ino else { throw Failure.invalidCurrentHome }
        var walking = dup(anchor)
        guard walking >= 0 else { throw Failure.invalidCurrentHome }
        defer { close(walking) }
        for component in plan.components {
            var named = stat()
            guard fstatat(walking, component, &named, AT_SYMLINK_NOFOLLOW) == 0,
                named.st_mode & S_IFMT == S_IFDIR, named.st_dev == originalHome.st_dev else { throw Failure.invalidCurrentHome }
            let next = openat(walking, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard next >= 0 else { throw Failure.invalidCurrentHome }
            var opened = stat()
            guard fstat(next, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
                opened.st_dev == originalHome.st_dev, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                close(next); throw Failure.invalidCurrentHome
            }
            close(walking); walking = next
        }
        var reached = stat(), held = stat(), finalHome = stat()
        guard fstat(walking, &reached) == 0, fstat(heldRoot, &held) == 0,
            held.st_mode & S_IFMT == S_IFDIR, reached.st_dev == originalHome.st_dev,
            held.st_dev == reached.st_dev, held.st_ino == reached.st_ino,
            lstat(plan.rootPath, &finalHome) == 0, finalHome.st_mode & S_IFMT == S_IFDIR,
            finalHome.st_dev == originalHome.st_dev, finalHome.st_ino == originalHome.st_ino else { throw Failure.invalidCurrentHome }
        return .init(rootPath: pinned,
            home: .init(systemPath: systemHome, physicalPath: physicalHome, device: UInt64(truncatingIfNeeded: originalHome.st_dev)))
    }
}
