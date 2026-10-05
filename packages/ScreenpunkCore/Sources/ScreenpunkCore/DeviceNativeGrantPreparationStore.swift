import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Native schema3 private-item-only mechanics. This store is unmounted and has no credential,
/// terminal, head, runtime, admission, journal-capacity-release or legacy conversion API.
/// Synchronous injected backend/fault seams retain the nonreentrant active-operation contract.
/// No UI, notifications, async waits or arbitrary mutation callbacks may run under these locks.
final class DeviceNativeGrantPreparationStore {
    enum Kind: Equatable { case rootBinding, genesis, intent, binding, privateItem, record, confirmation }
    enum Boundary: Equatable {
        case afterCreate(Kind), afterWrite(Kind), afterFileSync(Kind)
        case beforeReplace(Kind), afterReplace(Kind), afterDirectorySync(Kind), beforeScopeExit
    }
    fileprivate struct ID: Codable, Equatable { let device: UInt64; let inode: UInt64 }
    fileprivate struct Node: Codable, Equatable { let id: ID; let bytes: Data }
    private struct RootBinding: Codable {
        let schemaVersion: Int
        let domain: String
        let rootID: UUID
        let rootPath: String
        let protectedPaths: [String]
        let root: ID
        let lock: ID
        let operations: ID
        let selfID: ID
        let genesisID: ID
    }
    private struct Genesis: Codable { let schemaVersion: Int; let selfID: ID; let binding: Node }
    private struct Intent: Codable {
        let schemaVersion: Int
        let rootID: UUID
        let operationID: UUID
        let revisionID: UUID
        let nativeIntent: Data
        let privateAttemptByteCount: Int
        let credentials: [Credential]
    }
    private struct Credential: Codable { let revisionID: UUID; let byteCount: Int }
    private struct AttemptBinding: Codable {
        let schemaVersion: Int
        let rootID: UUID
        let operationID: UUID
        let selfID: ID
        let intent: Node
        let recordID: ID
        let confirmationID: ID
        let rootBinding: Node
        let genesis: Node
    }
    private struct Record: Codable {
        let schemaVersion: Int
        let rootID: UUID
        let operationID: UUID
        let selfID: ID
        let binding: Node
        let privateAttempt: DeviceGrantCredentialItem
    }
    private struct Confirmation: Codable {
        let schemaVersion: Int
        let selfID: ID
        let binding: Node
        let record: Node
    }
    final class PendingPrivateAttempt: GrantSecretRedacted {
        let operationID: UUID
        fileprivate let issuer: ObjectIdentifier
        fileprivate let epoch: UInt64
        fileprivate let rootBinding: Node
        fileprivate let genesis: Node
        fileprivate let record: Node
        fileprivate let confirmation: Node
        fileprivate let privateItem: DeviceGrantCredentialItem
        fileprivate init(_ issuer: ObjectIdentifier, _ epoch: UInt64, _ operationID: UUID,
            _ rootBinding: Node, _ genesis: Node, _ record: Node, _ confirmation: Node,
            _ privateItem: DeviceGrantCredentialItem) {
            self.issuer = issuer; self.epoch = epoch; self.operationID = operationID
            self.rootBinding = rootBinding; self.genesis = genesis; self.record = record
            self.confirmation = confirmation; self.privateItem = privateItem
        }
    }
    final class PrivateAttemptReceipt: GrantSecretRedacted {
        let operationID: UUID
        fileprivate let transition: PendingPrivateAttempt
        fileprivate init(_ transition: PendingPrivateAttempt) { self.transition = transition; operationID = transition.operationID }
    }
    private struct PrivateFrame: Codable, GrantSecretRedacted {
        let schemaVersion: Int
        let rootID: UUID
        let operationID: UUID
        let input: DeviceNativeGrantRevisionInput
        let completeSetIntent: Data
    }
    final class RecoveryCheckpoint: GrantSecretRedacted {
        let operationID: UUID
        let plan: DeviceValidatedNativeProvisioningPlan
        fileprivate let issuer: ObjectIdentifier
        fileprivate let epoch: UInt64
        fileprivate let rootBinding: Node
        fileprivate let genesis: Node
        fileprivate let nodes: [String: Node]
        fileprivate let item: DeviceGrantCredentialItem
        fileprivate let privateBytes: Data
        fileprivate init(_ issuer: ObjectIdentifier, _ epoch: UInt64, _ plan: DeviceValidatedNativeProvisioningPlan,
            _ rootBinding: Node, _ genesis: Node, _ nodes: [String: Node], _ item: DeviceGrantCredentialItem,
            _ privateBytes: Data, operationID: UUID) {
            self.issuer = issuer; self.epoch = epoch; self.plan = plan; self.rootBinding = rootBinding
            self.genesis = genesis; self.nodes = nodes; self.item = item; self.privateBytes = privateBytes
            self.operationID = operationID
        }
    }
    private var pending: PendingPrivateAttempt?
    private var qualified: PendingPrivateAttempt?
    private struct Context {
        let root: Int32
        let lock: Int32
        let operations: Int32
        let rootID: ID
        let lockID: ID
        let operationsID: ID
    }
    let root: URL
    let rootID: UUID
    private let protectedPaths: [String]
    private let validConfiguration: Bool
    private let backend: any DeviceGrantCredentialBackend
    private let fault: (Boundary) throws -> Void
    private let mutex = NSLock()
    private var borrowed: Context?
    private var bindingQualified = false
    private var captured: [String: ID] = [:]
    private var setupRoot: ID?, setupLock: ID?, setupOperations: ID?
    private var exactInput: (operation: UUID, bytes: Data)?
    private var capturedPrivateItem: DeviceGrantCredentialItem?
    private static let epochsLock = NSLock()
    private static var epochs: [String: UInt64] = [:]

    init(root: URL, rootID: UUID, protectedPaths: [URL], backend: any DeviceGrantCredentialBackend,
         fault: @escaping (Boundary) throws -> Void = { _ in }) {
        self.root = root; self.rootID = rootID; self.backend = backend; self.fault = fault
        validConfiguration = root.isFileURL && root.path.utf8.count <= 4096 && protectedPaths.count <= 32
            && protectedPaths.allSatisfy({ $0.isFileURL && $0.path.utf8.count <= 4096 })
        self.protectedPaths = validConfiguration ? protectedPaths.map(\.path) : []
    }
    private func epoch(invalidate: Bool = false) -> UInt64 {
        Self.epochsLock.lock(); defer { Self.epochsLock.unlock() }
        let key = root.path + "|" + rootID.uuidString
        let old = Self.epochs[key] ?? 0
        let value = invalidate ? old + 1 : old
        Self.epochs[key] = value; return value
    }
    private func paths() throws -> [String] {
        func components(_ path: String) throws -> [String] {
            guard path.hasPrefix("/"), path.utf8.count <= 4096,
                  !path.utf8.contains(0) else { throw DeviceNativeGrantPreparationError.unsafeBinding }
            let result = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !result.isEmpty, result.count <= 32,
                  result.allSatisfy({ $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
                  "/" + result.joined(separator: "/") == path else { throw DeviceNativeGrantPreparationError.unsafeBinding }
            return result
        }
        guard validConfiguration else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        let result = try components(root.path)
        for protected in protectedPaths {
            _ = try components(protected)
            guard !DeviceLocalResourceDescriptor.pathsOverlap(root.path, protected) else {
                throw DeviceNativeGrantPreparationError.scopeOverlap
            }
        }
        return result
    }
    private func identity(_ fd: Int32, directory: Bool) throws -> ID {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        let kind = value.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(directory ? S_IFDIR : S_IFREG),
              directory || value.st_nlink == 1 else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        return .init(device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(truncatingIfNeeded: value.st_ino))
    }
    private func synchronize(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
    }
    private func names(_ fd: Int32, maximum: Int) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw DeviceNativeGrantPreparationError.io(errno) }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < maximum, name.utf8.count <= 255 else { throw DeviceNativeGrantPreparationError.capacity }
            result.append(name)
            errno = 0
        }
        guard errno == 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    private func read(_ parent: Int32, _ name: String, limit: Int) throws -> Node? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw DeviceNativeGrantPreparationError.io(errno)
        }
        defer { close(fd) }
        let id = try identity(fd, directory: false)
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_size >= 0, value.st_size <= limit else {
            throw DeviceNativeGrantPreparationError.sizeLimit
        }
        var bytes = Data(count: Int(value.st_size))
        var offset = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let count = systemRead(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
                offset += count
            }
        }
        var end = stat()
        guard fstat(fd, &end) == 0, end.st_size == value.st_size,
              try identity(fd, directory: false) == id else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        var extra: UInt8 = 0
        var trailing: Int
        repeat {
            trailing = withUnsafeMutablePointer(to: &extra) { systemRead(fd, UnsafeMutableRawPointer($0), 1) }
        } while trailing < 0 && errno == EINTR
        guard trailing == 0 else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        return .init(id: id, bytes: bytes)
    }
    private func systemRead(_ fd: Int32, _ pointer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, pointer, count)
        #else
        return Glibc.read(fd, pointer, count)
        #endif
    }
    private func systemWrite(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(fd, pointer, count)
        #else
        return Glibc.write(fd, pointer, count)
        #endif
    }
    private func check(_ context: Context) throws {
        guard try identity(context.root, directory: true) == context.rootID,
              try identity(context.lock, directory: false) == context.lockID,
              try identity(context.operations, directory: true) == context.operationsID else {
            throw DeviceNativeGrantPreparationError.unsafeBinding
        }
        let rootNames = try names(context.root, maximum: 6)
        let allowed: Set<String> = ["native-grant.lock", "operations", "root-binding.json", "root-binding.json.stage", "genesis.json", "genesis.json.stage"]
        guard Set(rootNames).isSubset(of: allowed) else { throw DeviceNativeGrantPreparationError.invalidRecord }
        // Verify the named nodes still designate the held descriptors, not replaced aliases.
        func named(_ parent: Int32, _ name: String, _ expected: ID, directory: Bool) throws {
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
            defer { close(fd) }
            guard try identity(fd, directory: directory) == expected else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        }
        try named(context.root, "native-grant.lock", context.lockID, directory: false)
        try named(context.root, "operations", context.operationsID, directory: true)
        let current = try openRoot()
        defer { close(current) }
        guard try identity(current, directory: true) == context.rootID else { throw DeviceNativeGrantPreparationError.unsafeBinding }
    }
    private func openRoot() throws -> Int32 {
        let components = try paths()
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard current >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        do {
            var ancestors: [ID] = [try identity(current, directory: true)]
            for component in components {
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard next >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
                close(current); current = next
                ancestors.append(try identity(current, directory: true))
            }
            let rootIdentity = try identity(current, directory: true)
            try checkPhysicalProtectedRoots(rootIdentity, rootAncestors: ancestors)
            return current
        } catch { close(current); throw error }
    }
    /// Descriptor-only bounded inspection handles existing case/Unicode filesystem aliases too.
    /// Missing protected descendants are allowed only when their existing prefix excludes root.
    /// No protected directory or ancestor is created, changed or synchronized.
    private func checkPhysicalProtectedRoots(_ rootIdentity: ID, rootAncestors: [ID]) throws {
        for path in protectedPaths {
            var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
            do {
                var missing = false
                for component in path.split(separator: "/", omittingEmptySubsequences: true) {
                    let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    if next < 0 {
                        if errno == ENOENT { missing = true; break }
                        throw DeviceNativeGrantPreparationError.io(errno)
                    }
                    close(descriptor); descriptor = next
                    guard try identity(descriptor, directory: true) != rootIdentity else {
                        throw DeviceNativeGrantPreparationError.scopeOverlap
                    }
                }
                if !missing {
                    let protectedIdentity = try identity(descriptor, directory: true)
                    guard !rootAncestors.contains(protectedIdentity) else { throw DeviceNativeGrantPreparationError.scopeOverlap }
                }
                close(descriptor)
            } catch { close(descriptor); throw error }
        }
    }
    private func backendInventory() throws -> [DeviceGrantCredentialItem] {
        var items: [DeviceGrantCredentialItem] = []
        var accounts = Set<String>(), references = Set<Data>(), privateBytes = 0, credentialBytes = 0
        let service = GrantPreparationCodec.service(rootID)
        try backend.inventory(service: service, maximum: NativeGrantPreparationCodec.itemLimit + 1) { item in
            guard items.count < NativeGrantPreparationCodec.itemLimit,
                  item.account.utf8.count <= 64, !item.account.utf8.contains(0),
                  !item.persistentReference.isEmpty, item.persistentReference.count <= 1024,
                  item.byteCount >= 0, accounts.insert(item.account).inserted,
                  references.insert(item.persistentReference).inserted else { throw DeviceNativeGrantPreparationError.invalidRecord }
            let prefix: String
            let maximum: Int
            if item.account.hasPrefix("attempt.") { prefix = "attempt."; maximum = NativeGrantPreparationCodec.privateLimit }
            else if item.account.hasPrefix("credential.") { prefix = "credential."; maximum = 8192 }
            else { throw DeviceNativeGrantPreparationError.invalidRecord }
            let suffix = String(item.account.dropFirst(prefix.count))
            guard let id = UUID(uuidString: suffix), suffix.utf8.elementsEqual(id.uuidString.lowercased().utf8),
                  item.byteCount <= maximum else { throw DeviceNativeGrantPreparationError.invalidRecord }
            if prefix == "attempt." {
                guard privateBytes <= NativeGrantPreparationCodec.privateTotalLimit - item.byteCount else { throw DeviceNativeGrantPreparationError.capacity }
                privateBytes += item.byteCount
            } else {
                guard credentialBytes <= NativeGrantPreparationCodec.credentialTotalLimit - item.byteCount else { throw DeviceNativeGrantPreparationError.capacity }
                credentialBytes += item.byteCount
            }
            items.append(item)
        }
        return items
    }

    private func allocate(_ parent: Int32, _ name: String, kind: Kind) throws -> ID {
        if let old = try read(parent, name, limit: NativeGrantPreparationCodec.confirmationLimit) {
            guard captured[name] == old.id else { throw DeviceNativeGrantPreparationError.repairRequired }
            return old.id
        }
        guard captured[name] == nil else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        defer { close(fd) }
        let id = try identity(fd, directory: false)
        captured[name] = id
        try fault(.afterCreate(kind))
        return id
    }
    private func fill(_ parent: Int32, _ name: String, id: ID, bytes: Data, kind: Kind) throws -> Node {
        let fd = openat(parent, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        defer { close(fd) }
        guard try identity(fd, directory: false) == id else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        guard ftruncate(fd, 0) == 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        var offset = 0
        try bytes.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let count = systemWrite(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
                offset += count
            }
        }
        try fault(.afterWrite(kind))
        try synchronize(fd); try fault(.afterFileSync(kind))
        guard try identity(fd, directory: false) == id,
              let node = try read(parent, name, limit: bytes.count), node.id == id, node.bytes == bytes else {
            throw DeviceNativeGrantPreparationError.unsafeBinding
        }
        return node
    }
    private func promote(_ parent: Int32, _ name: String, expected: Node, kind: Kind) throws {
        let staged = name + ".stage"
        let final = try read(parent, name, limit: NativeGrantPreparationCodec.confirmationLimit)
        if let final {
            guard final == expected, try read(parent, staged, limit: NativeGrantPreparationCodec.confirmationLimit) == nil else {
                throw DeviceNativeGrantPreparationError.unsafeBinding
            }
            try syncNode(parent, name, expected: expected)
        } else {
            guard try read(parent, staged, limit: NativeGrantPreparationCodec.confirmationLimit) == expected else {
                throw DeviceNativeGrantPreparationError.unsafeBinding
            }
            try syncNode(parent, staged, expected: expected)
            try fault(.afterFileSync(kind))
            try fault(.beforeReplace(kind))
            guard renameat(parent, staged, parent, name) == 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
            try fault(.afterReplace(kind))
        }
        try synchronize(parent); try fault(.afterDirectorySync(kind))
        guard try read(parent, name, limit: NativeGrantPreparationCodec.confirmationLimit) == expected else {
            throw DeviceNativeGrantPreparationError.unsafeBinding
        }
    }
    private func syncNode(_ parent: Int32, _ name: String, expected: Node) throws {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        defer { close(fd) }
        guard try identity(fd, directory: false) == expected.id,
              try read(parent, name, limit: expected.bytes.count) == expected else {
            throw DeviceNativeGrantPreparationError.unsafeBinding
        }
        try synchronize(fd)
    }
    private func originalLivePrefix(_ parent: Int32, present: [String], allowed: Set<String>) throws {
        guard Set(present).isSubset(of: allowed) else { throw DeviceNativeGrantPreparationError.invalidRecord }
        for (name, id) in captured where allowed.contains(name) {
            let direct = try read(parent, name, limit: NativeGrantPreparationCodec.confirmationLimit)
            let promoted = name.hasSuffix(".stage") ? try read(parent, String(name.dropLast(6)), limit: NativeGrantPreparationCodec.confirmationLimit) : nil
            guard (direct?.id == id && promoted == nil) || (direct == nil && promoted?.id == id) else {
                // A captured inode may have been deliberately renamed, but no missing inode
                // is recreated and no same-byte fresh inode is adopted.
                throw DeviceNativeGrantPreparationError.unsafeBinding
            }
        }
    }

    private func context<T>(create: Bool, _ body: (Context) throws -> T) throws -> T {
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let rootIdentity = try identity(rootFD, directory: true)
        let rootNames = try names(rootFD, maximum: 6)
        if create && rootNames.isEmpty {
            if let setupRoot { guard setupRoot == rootIdentity else { throw DeviceNativeGrantPreparationError.unsafeBinding } }
            else { setupRoot = rootIdentity }
        }
        let bindingExists = try read(rootFD, "root-binding.json", limit: 32768) != nil
        let bindingStaged = try read(rootFD, "root-binding.json.stage", limit: 32768) != nil
        if create && !bindingExists && !bindingStaged {
            guard setupRoot == rootIdentity else { throw DeviceNativeGrantPreparationError.repairRequired }
        }
        var lockFD = openat(rootFD, "native-grant.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if lockFD < 0 && errno == ENOENT && create && !bindingExists && !bindingStaged {
            guard setupLock == nil else { throw DeviceNativeGrantPreparationError.unsafeBinding }
            lockFD = openat(rootFD, "native-grant.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
            guard lockFD >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
            do { setupLock = try identity(lockFD, directory: false) }
            catch { close(lockFD); throw error }
        }
        guard lockFD >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        defer { close(lockFD) }
        let lockIdentity = try identity(lockFD, directory: false)
        if !bindingExists && !bindingStaged {
            guard setupLock == lockIdentity else { throw DeviceNativeGrantPreparationError.repairRequired }
        }
        guard flock(lockFD, LOCK_EX) == 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        defer { flock(lockFD, LOCK_UN) }
        var operationsFD = openat(rootFD, "operations", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if operationsFD < 0 && errno == ENOENT && create && !bindingExists && !bindingStaged {
            guard setupOperations == nil else { throw DeviceNativeGrantPreparationError.unsafeBinding }
            guard mkdirat(rootFD, "operations", mode_t(0o700)) == 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
            operationsFD = openat(rootFD, "operations", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard operationsFD >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
            do { setupOperations = try identity(operationsFD, directory: true) }
            catch { close(operationsFD); throw error }
        }
        guard operationsFD >= 0 else { throw DeviceNativeGrantPreparationError.io(errno) }
        defer { close(operationsFD) }
        let operationsIdentity = try identity(operationsFD, directory: true)
        if !bindingExists && !bindingStaged {
            guard setupOperations == operationsIdentity else { throw DeviceNativeGrantPreparationError.repairRequired }
        }
        let context = Context(root: rootFD, lock: lockFD, operations: operationsFD,
            rootID: rootIdentity, lockID: lockIdentity, operationsID: operationsIdentity)
        try check(context)
        let value = try body(context)
        try check(context)
        return value
    }
    private func disk<T>(create: Bool = false, permit: DeviceLocalResourcePermit? = nil,
                         _ body: (Context) throws -> T) throws -> T {
        if let permit {
            try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
            guard let borrowed else { throw DeviceLocalResourceGateFailure.invalidScope }
            try check(borrowed)
            let value = try body(borrowed)
            try check(borrowed)
            return value
        }
        try DeviceLocalResourceRegistry.beginOrdinary()
        defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try context(create: create, body)
    }
    var resourceGateDescriptor: DeviceLocalResourceDescriptor {
        get throws { try .existing(instance: ObjectIdentifier(self), path: root.path, rootID: rootID) }
    }
    func withResourceGateScope(_ permit: DeviceLocalResourcePermit, _ body: () throws -> Void) throws {
        try permit.beginAcquisition(resourceGateDescriptor)
        mutex.lock(); defer { permit.invalidate(); mutex.unlock() }
        let originalEpoch = epoch()
        do {
            try context(create: false) { context in
                _ = try checkedBinding(context)
                borrowed = context
                defer { borrowed = nil; permit.invalidate() }
                try body()
                try fault(.beforeScopeExit)
                _ = try checkedBinding(context)
            }
        } catch {
            if epoch() != originalEpoch { bindingQualified = false; pending = nil; qualified = nil }
            throw error
        }
    }
    private func checkedBinding(_ context: Context) throws -> (Node, Node) {
        guard let binding = try read(context.root, "root-binding.json", limit: 32768),
              let genesis = try read(context.root, "genesis.json", limit: 32768),
              try read(context.root, "root-binding.json.stage", limit: 32768) == nil,
              try read(context.root, "genesis.json.stage", limit: 32768) == nil else {
            throw DeviceNativeGrantPreparationError.repairRequired
        }
        let value: RootBinding = try strictDecode(binding.bytes, limit: 32768)
        let proof: Genesis = try strictDecode(genesis.bytes, limit: 32768)
        guard value.schemaVersion == 3, value.domain.utf8.elementsEqual("nativePrivateAttempt3".utf8),
              value.rootID == rootID, value.rootPath.utf8.elementsEqual(root.path.utf8),
              value.protectedPaths.count == protectedPaths.count,
              zip(value.protectedPaths, protectedPaths).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }),
              value.root == context.rootID, value.lock == context.lockID, value.operations == context.operationsID,
              value.selfID == binding.id, value.genesisID == genesis.id,
              proof.schemaVersion == 3, proof.selfID == genesis.id, proof.binding == binding else {
            throw DeviceNativeGrantPreparationError.unsafeBinding
        }
        return (binding, genesis)
    }
    private func strictDecode<T: Codable>(_ bytes: Data, limit: Int) throws -> T {
        guard bytes.count <= limit else { throw DeviceNativeGrantPreparationError.sizeLimit }
        try DeviceNativeGrantRevisionPreflight.validate(bytes)
        let value = try JSONDecoder().decode(T.self, from: bytes)
        guard try NativeGrantPreparationCodec.encode(value, limit: limit) == bytes else {
            // Exact canonical equality rejects unknown fields and normalized aliases too.
            throw DeviceNativeGrantPreparationError.invalidRecord
        }
        return value
    }

    /// Explicit empty namespace only. A preexisting root is supplied by the caller; ancestors
    /// are never created or synchronized. Diagnostic visibility is not initialization success.
    func initializeExplicit() throws {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        _ = try paths()
        guard try backendInventory().isEmpty else { throw DeviceNativeGrantPreparationError.conflict }
        // Root setup metadata must fit before creating even the owned lock/operations nodes.
        let sample = ID(device: UInt64.max, inode: UInt64.max)
        let sampleBinding = try NativeGrantPreparationCodec.encode(RootBinding(schemaVersion: 3,
            domain: "nativePrivateAttempt3", rootID: rootID, rootPath: root.path, protectedPaths: protectedPaths,
            root: sample, lock: sample, operations: sample, selfID: sample, genesisID: sample), limit: 32768)
        _ = try NativeGrantPreparationCodec.encode(Genesis(schemaVersion: 3, selfID: sample,
            binding: .init(id: sample, bytes: sampleBinding)), limit: 32768)
        do { try context(create: true) { context in
            guard try names(context.operations, maximum: 8).isEmpty else { throw DeviceNativeGrantPreparationError.conflict }
            let bindingFinal = try read(context.root, "root-binding.json", limit: 32768)
            let bindingStage = try read(context.root, "root-binding.json.stage", limit: 32768)
            let genesisFinal = try read(context.root, "genesis.json", limit: 32768)
            let genesisStage = try read(context.root, "genesis.json.stage", limit: 32768)
            guard bindingFinal == nil || bindingStage == nil, genesisFinal == nil || genesisStage == nil else {
                throw DeviceNativeGrantPreparationError.unsafeBinding
            }
            var binding: Node
            let genesisID: ID
            if let existing = bindingFinal ?? bindingStage, !existing.bytes.isEmpty {
                let value: RootBinding = try strictDecode(existing.bytes, limit: 32768)
                guard value.schemaVersion == 3, value.domain == "nativePrivateAttempt3", value.rootID == rootID,
                      value.rootPath.utf8.elementsEqual(root.path.utf8), value.root == context.rootID,
                      value.lock == context.lockID, value.operations == context.operationsID,
                      value.selfID == existing.id, value.protectedPaths.count == protectedPaths.count,
                      zip(value.protectedPaths, protectedPaths).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }),
                      let proof = genesisFinal ?? genesisStage, proof.id == value.genesisID else {
                    throw DeviceNativeGrantPreparationError.unsafeBinding
                }
                binding = existing; genesisID = value.genesisID
            } else {
                let present = try names(context.root, maximum: 6)
                try originalLivePrefix(context.root, present: present,
                    allowed: ["native-grant.lock", "operations", "root-binding.json.stage", "genesis.json.stage"])
                let bindingID = try allocate(context.root, "root-binding.json.stage", kind: .rootBinding)
                genesisID = try allocate(context.root, "genesis.json.stage", kind: .genesis)
                let value = RootBinding(schemaVersion: 3, domain: "nativePrivateAttempt3", rootID: rootID,
                    rootPath: root.path, protectedPaths: protectedPaths, root: context.rootID,
                    lock: context.lockID, operations: context.operationsID, selfID: bindingID, genesisID: genesisID)
                let bytes = try NativeGrantPreparationCodec.encode(value, limit: 32768)
                bindingQualified = false
                binding = try fill(context.root, "root-binding.json.stage", id: bindingID, bytes: bytes, kind: .rootBinding)
            }
            // Repair the recorded reciprocal binding BEFORE any dependent proof payload.
            bindingQualified = false
            let bindingPath = bindingFinal == nil ? "root-binding.json.stage" : "root-binding.json"
            try syncNode(context.root, bindingPath, expected: binding)
            try fault(.afterFileSync(.rootBinding))
            try synchronize(context.root); try fault(.afterDirectorySync(.rootBinding))
            // Recorded prepared proof identity permits exact initialization repair, not adoption.
            let proofBytes = try NativeGrantPreparationCodec.encode(Genesis(schemaVersion: 3, selfID: genesisID, binding: binding), limit: 32768)
            let proof: Node
            if let final = genesisFinal {
                guard final.id == genesisID, final.bytes == proofBytes else { throw DeviceNativeGrantPreparationError.unsafeBinding }
                proof = final
            } else {
                guard let stage = try read(context.root, "genesis.json.stage", limit: 32768), stage.id == genesisID,
                      stage.bytes.isEmpty || stage.bytes == proofBytes else { throw DeviceNativeGrantPreparationError.unsafeBinding }
                bindingQualified = false
                proof = try fill(context.root, "genesis.json.stage", id: genesisID, bytes: proofBytes, kind: .genesis)
            }
            bindingQualified = false
            try promote(context.root, "root-binding.json", expected: binding, kind: .rootBinding)
            try promote(context.root, "genesis.json", expected: proof, kind: .genesis)
            try syncNode(context.root, "root-binding.json", expected: binding)
            try syncNode(context.root, "genesis.json", expected: proof)
            try synchronize(context.lock); try synchronize(context.operations); try synchronize(context.root)
            _ = try checkedBinding(context)
            bindingQualified = true
        } } catch { bindingQualified = false; throw error }
    }

    private func operationNames(_ operation: UUID) -> Set<String> {
        let prefix = operation.uuidString.lowercased()
        var result = Set<String>()
        for kind in ["intent", "binding", "record", "confirm"] {
            let name = prefix + "." + kind + ".json"
            result.insert(name)
            result.insert(name + ".stage")
        }
        return result
    }
    private func operationName(_ operation: UUID, _ kind: String) -> String {
        operation.uuidString.lowercased() + "." + kind + ".json"
    }
    private func operationNode(_ context: Context, _ operation: UUID, _ kind: String, limit: Int) throws -> Node? {
        let name = operationName(operation, kind)
        let final = try read(context.operations, name, limit: limit)
        let stage = try read(context.operations, name + ".stage", limit: limit)
        guard final == nil || stage == nil else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        return final ?? stage
    }
    private func publicIntent(_ request: DeviceNativeGrantPreparationRequest, privateBytes: Data) throws -> Data {
        let credentials = request.input.credentials.sorted { $0.revisionID.uuidString < $1.revisionID.uuidString }
            .map { Credential(revisionID: $0.revisionID, byteCount: $0.bytes.count) }
        return try NativeGrantPreparationCodec.encode(Intent(schemaVersion: 3, rootID: rootID,
            operationID: request.operationID, revisionID: request.input.identity.revisionID,
            nativeIntent: request.plan.intentBytes, privateAttemptByteCount: privateBytes.count,
            credentials: credentials), limit: NativeGrantPreparationCodec.publicIntentLimit)
    }
    private func preflight(_ context: Context, request: DeviceNativeGrantPreparationRequest,
                           privateBytes: Data, intentBytes: Data) throws -> (Node, Node) {
        let originals = try checkedBinding(context)
        let present = try names(context.operations, maximum: 8)
        let allowed = operationNames(request.operationID)
        try originalLivePrefix(context.operations, present: present, allowed: allowed)
        if let exactInput {
            guard exactInput.operation == request.operationID, exactInput.bytes == privateBytes else {
                throw DeviceNativeGrantPreparationError.conflict
            }
        }
        let intent = try operationNode(context, request.operationID, "intent", limit: 32768)
        let binding = try operationNode(context, request.operationID, "binding", limit: 65536)
        let record = try operationNode(context, request.operationID, "record", limit: 65536)
        let confirmation = try operationNode(context, request.operationID, "confirm", limit: 131072)
        if let intent, !intent.bytes.isEmpty {
            guard intent.bytes == intentBytes else { throw DeviceNativeGrantPreparationError.conflict }
        } else if intent != nil {
            guard exactInput?.bytes == privateBytes else { throw DeviceNativeGrantPreparationError.repairRequired }
        }
        if let binding, !binding.bytes.isEmpty {
            let value: AttemptBinding = try strictDecode(binding.bytes, limit: 65536)
            guard value.schemaVersion == 3, value.rootID == rootID, value.operationID == request.operationID,
                  value.selfID == binding.id, value.intent == intent, value.rootBinding == originals.0,
                  value.genesis == originals.1, record?.id == value.recordID,
                  confirmation?.id == value.confirmationID else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        } else {
            if let intent { guard captured.values.contains(intent.id) else { throw DeviceNativeGrantPreparationError.repairRequired } }
            for node in [binding, record, confirmation].compactMap({ $0 }) {
                guard captured.values.contains(node.id) else { throw DeviceNativeGrantPreparationError.repairRequired }
            }
        }
        var expectedItem = capturedPrivateItem
        if let record, !record.bytes.isEmpty {
            let value: Record = try strictDecode(record.bytes, limit: 65536)
            guard value.schemaVersion == 3, value.rootID == rootID, value.operationID == request.operationID,
                  value.selfID == record.id, value.binding == binding else { throw DeviceNativeGrantPreparationError.unsafeBinding }
            expectedItem = value.privateAttempt
        }
        if let confirmation, !confirmation.bytes.isEmpty {
            let value: Confirmation = try strictDecode(confirmation.bytes, limit: 131072)
            guard value.schemaVersion == 3, value.selfID == confirmation.id,
                  value.binding == binding, value.record == record else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        }
        let items = try backendInventory()
        guard items.count <= 1 else { throw DeviceNativeGrantPreparationError.invalidRecord }
        if let item = items.first {
            guard expectedItem == item, item.account.utf8.elementsEqual(GrantPreparationCodec.attemptAccount(request.operationID).utf8),
                  item.byteCount == privateBytes.count,
                  let value = try backend.read(service: GrantPreparationCodec.service(rootID), account: item.account,
                                               maximumBytes: NativeGrantPreparationCodec.privateLimit),
                  value.item == item, value.bytes == privateBytes else { throw DeviceNativeGrantPreparationError.repairRequired }
        } else if expectedItem != nil { throw DeviceNativeGrantPreparationError.repairRequired }
        // Worst-case identity/ref sampling bounds all independent public leaves before allocation.
        let sample = ID(device: UInt64.max, inode: UInt64.max)
        let sampleIntent = Node(id: sample, bytes: intentBytes)
        let sampleBinding = try NativeGrantPreparationCodec.encode(AttemptBinding(schemaVersion: 3, rootID: rootID,
            operationID: request.operationID, selfID: sample, intent: sampleIntent, recordID: sample,
            confirmationID: sample, rootBinding: originals.0, genesis: originals.1), limit: 65536)
        let sampleItem = DeviceGrantCredentialItem(account: GrantPreparationCodec.attemptAccount(request.operationID),
            persistentReference: Data(repeating: 255, count: 1024), byteCount: privateBytes.count)
        let sampleRecord = try NativeGrantPreparationCodec.encode(Record(schemaVersion: 3, rootID: rootID,
            operationID: request.operationID, selfID: sample, binding: .init(id: sample, bytes: sampleBinding),
            privateAttempt: sampleItem), limit: 65536)
        let sampleConfirmation = try NativeGrantPreparationCodec.encode(Confirmation(schemaVersion: 3, selfID: sample,
            binding: .init(id: sample, bytes: sampleBinding), record: .init(id: sample, bytes: sampleRecord)), limit: 131072)
        let publicTotal = intentBytes.count + sampleBinding.count + sampleRecord.count + sampleConfirmation.count
            + originals.0.bytes.count + originals.1.bytes.count
        guard publicTotal <= NativeGrantPreparationCodec.privateTotalLimit,
              privateBytes.count <= NativeGrantPreparationCodec.privateTotalLimit else { throw DeviceNativeGrantPreparationError.capacity }
        return originals
    }

    /// Only the fixed gate command can dispatch effects. This method cannot be called with a
    /// read permit, and it never publishes an anchor before final whole-scope checks succeed.
    func performPrivateAttemptExact(_ request: DeviceNativeGrantPreparationRequest,
        commandPermit: DeviceNativeGrantPrivateCommandPermit) throws -> PendingPrivateAttempt {
        try commandPermit.begin(ObjectIdentifier(self)); defer { commandPermit.end() }
        guard let context = borrowed else { throw DeviceLocalResourceGateFailure.invalidScope }
        return try performPrivateAttempt(context, request: request)
    }
    private func performPrivateAttempt(_ context: Context, request: DeviceNativeGrantPreparationRequest) throws -> PendingPrivateAttempt {
        let privateBytes = try NativeGrantPreparationCodec.privateBytes(request, rootID: rootID)
        let intentBytes = try publicIntent(request, privateBytes: privateBytes)
        let original = try preflight(context, request: request, privateBytes: privateBytes, intentBytes: intentBytes)
        // Establish exact original secret-bearing input BEFORE epoch or first filesystem effect.
        if exactInput == nil { exactInput = (request.operationID, privateBytes) }
        bindingQualified = false; qualified = nil; pending = nil
        let attemptedEpoch = epoch(invalidate: true)
        let intentName = operationName(request.operationID, "intent")
        let bindingName = operationName(request.operationID, "binding")
        let recordName = operationName(request.operationID, "record")
        let confirmationName = operationName(request.operationID, "confirm")
        let intent: Node
        if let existing = try operationNode(context, request.operationID, "intent", limit: 32768), !existing.bytes.isEmpty {
            intent = existing
        } else {
            let id = try allocate(context.operations, intentName + ".stage", kind: .intent)
            intent = try fill(context.operations, intentName + ".stage", id: id, bytes: intentBytes, kind: .intent)
        }
        try promote(context.operations, intentName, expected: intent, kind: .intent)
        let binding: Node
        let recordID: ID
        let confirmationID: ID
        if let existing = try operationNode(context, request.operationID, "binding", limit: 65536), !existing.bytes.isEmpty {
            let value: AttemptBinding = try strictDecode(existing.bytes, limit: 65536)
            binding = existing; recordID = value.recordID; confirmationID = value.confirmationID
        } else {
            recordID = try allocate(context.operations, recordName + ".stage", kind: .record)
            confirmationID = try allocate(context.operations, confirmationName + ".stage", kind: .confirmation)
            let bindingID = try allocate(context.operations, bindingName + ".stage", kind: .binding)
            let bytes = try NativeGrantPreparationCodec.encode(AttemptBinding(schemaVersion: 3, rootID: rootID,
                operationID: request.operationID, selfID: bindingID, intent: intent, recordID: recordID,
                confirmationID: confirmationID, rootBinding: original.0, genesis: original.1), limit: 65536)
            binding = try fill(context.operations, bindingName + ".stage", id: bindingID, bytes: bytes, kind: .binding)
        }
        try promote(context.operations, bindingName, expected: binding, kind: .binding)
        let account = GrantPreparationCodec.attemptAccount(request.operationID)
        let existingRecord = try operationNode(context, request.operationID, "record", limit: 65536)
        let item: DeviceGrantCredentialItem
        if let existingRecord, !existingRecord.bytes.isEmpty {
            let value: Record = try strictDecode(existingRecord.bytes, limit: 65536)
            item = value.privateAttempt
        } else if let capturedPrivateItem {
            item = capturedPrivateItem
        } else {
            item = try backend.add(service: GrantPreparationCodec.service(rootID), account: account, bytes: privateBytes)
            capturedPrivateItem = item // Capture BEFORE the injected after-add boundary.
            try fault(.afterCreate(.privateItem))
        }
        guard item.account.utf8.elementsEqual(account.utf8), item.byteCount == privateBytes.count,
              !item.persistentReference.isEmpty, item.persistentReference.count <= 1024,
              let stored = try backend.read(service: GrantPreparationCodec.service(rootID), account: account,
                                            maximumBytes: NativeGrantPreparationCodec.privateLimit),
              stored.item == item, stored.bytes == privateBytes else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        let recordBytes = try NativeGrantPreparationCodec.encode(Record(schemaVersion: 3, rootID: rootID,
            operationID: request.operationID, selfID: recordID, binding: binding, privateAttempt: item), limit: 65536)
        let record: Node
        if let existingRecord, !existingRecord.bytes.isEmpty {
            guard existingRecord.id == recordID, existingRecord.bytes == recordBytes else { throw DeviceNativeGrantPreparationError.unsafeBinding }
            record = existingRecord
        } else {
            record = try fill(context.operations, recordName + ".stage", id: recordID, bytes: recordBytes, kind: .record)
        }
        try promote(context.operations, recordName, expected: record, kind: .record)
        let confirmationBytes = try NativeGrantPreparationCodec.encode(Confirmation(schemaVersion: 3,
            selfID: confirmationID, binding: binding, record: record), limit: 131072)
        let confirmation: Node
        if let existing = try operationNode(context, request.operationID, "confirm", limit: 131072), !existing.bytes.isEmpty {
            guard existing.id == confirmationID, existing.bytes == confirmationBytes else { throw DeviceNativeGrantPreparationError.unsafeBinding }
            confirmation = existing
        } else {
            confirmation = try fill(context.operations, confirmationName + ".stage", id: confirmationID,
                                    bytes: confirmationBytes, kind: .confirmation)
        }
        try promote(context.operations, confirmationName, expected: confirmation, kind: .confirmation)
        // Explicit synchronization repairs original binding durability; it never blesses fresh nodes.
        try syncNode(context.root, "root-binding.json", expected: original.0)
        try fault(.afterFileSync(.rootBinding))
        try syncNode(context.root, "genesis.json", expected: original.1)
        try fault(.afterFileSync(.genesis))
        try synchronize(context.lock); try synchronize(context.operations); try synchronize(context.root)
        let after = try preflight(context, request: request, privateBytes: privateBytes, intentBytes: intentBytes)
        guard original.0 == after.0, original.1 == after.1, epoch() == attemptedEpoch else {
            throw DeviceNativeGrantPreparationError.unsafeBinding
        }
        try check(context)
        bindingQualified = true
        let transition = PendingPrivateAttempt(ObjectIdentifier(self), attemptedEpoch, request.operationID,
            original.0, original.1, record, confirmation, item)
        pending = transition
        return transition
    }

    func verifyPendingExact(_ transition: PendingPrivateAttempt, request: DeviceNativeGrantPreparationRequest,
                            resourcePermit: DeviceLocalResourcePermit) throws {
        try disk(permit: resourcePermit) { context in
            guard transition.issuer == ObjectIdentifier(self), transition.operationID == request.operationID,
                  transition.epoch == epoch(), pending === transition || qualified === transition,
                  bindingQualified else { throw DeviceNativeGrantPreparationError.outcomeUncertain }
            let privateBytes = try NativeGrantPreparationCodec.privateBytes(request, rootID: rootID)
            let intentBytes = try publicIntent(request, privateBytes: privateBytes)
            let original = try preflight(context, request: request, privateBytes: privateBytes, intentBytes: intentBytes)
            guard original.0 == transition.rootBinding, original.1 == transition.genesis,
                  try operationNode(context, request.operationID, "record", limit: 65536) == transition.record,
                  try operationNode(context, request.operationID, "confirm", limit: 131072) == transition.confirmation,
                  transition.epoch == epoch() else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        }
    }
    func publishPrivateAttemptExact(_ transition: PendingPrivateAttempt,
                                   publicationPermit: DeviceNativeGrantPrivatePublicationPermit) throws -> PrivateAttemptReceipt {
        try publicationPermit.validate(transition)
        mutex.lock(); defer { mutex.unlock() }
        guard pending === transition, transition.issuer == ObjectIdentifier(self),
              transition.epoch == epoch(), bindingQualified else { throw DeviceNativeGrantPreparationError.outcomeUncertain }
        qualified = transition; pending = nil
        return .init(transition)
    }
    /// Test-only observation of an already genuine publication. This opaque token exposes
    /// no secret or construction capability and cannot qualify or renew an attempt.
    func capturePublishedCleanupTokenForTesting() throws -> PendingPrivateAttempt {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        guard let original = qualified, original.issuer == ObjectIdentifier(self),
              original.epoch == epoch(), bindingQualified else { throw DeviceNativeGrantPreparationError.outcomeUncertain }
        return original
    }
    func discardPrivatePublication(_ transition: PendingPrivateAttempt) throws {
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        guard transition.issuer == ObjectIdentifier(self), transition.epoch == epoch(),
              pending === transition || qualified === transition else { return }
        if pending === transition { pending = nil }
        if qualified === transition { qualified = nil }
        bindingQualified = false
    }
    func verifyPrivateAttemptExact(_ receipt: PrivateAttemptReceipt, request: DeviceNativeGrantPreparationRequest,
                                  resourcePermit: DeviceLocalResourcePermit) throws {
        try disk(permit: resourcePermit) { _ in
            guard qualified === receipt.transition else { throw DeviceNativeGrantPreparationError.outcomeUncertain }
        }
        try verifyPendingExact(receipt.transition, request: request, resourcePermit: resourcePermit)
    }

    private func decodePrivate(_ bytes: Data) throws -> PrivateFrame {
        guard bytes.count <= NativeGrantPreparationCodec.privateLimit else { throw DeviceNativeGrantPreparationError.sizeLimit }
        try DeviceNativeGrantRevisionPreflight.validate(bytes)
        guard let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(raw.keys) == Set(["schemaVersion", "rootID", "operationID", "input", "completeSetIntent"]),
              let input = raw["input"], let intent = raw["completeSetIntent"] as? String,
              intent.utf8.count <= ((32768 + 2) / 3) * 4 else { throw DeviceNativeGrantPreparationError.invalidRecord }
        _ = try DeviceNativeGrantRevisionPreflight.decode(JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
        let value: PrivateFrame = try strictDecode(bytes, limit: NativeGrantPreparationCodec.privateLimit)
        let body = try DeviceNativeProvisioningIntentCodec.decode(value.completeSetIntent)
        guard value.schemaVersion == 3, value.rootID == rootID, value.rootID == value.input.identity.rootID,
              body.roots.grantID == rootID, body.grantOperationID == value.operationID,
              body.grantIdentity == value.input.identity, body.privateAttemptByteCount == bytes.count,
              value.input.retainedRevisions.isEmpty,
              value.input.entries.map(\.entryID.uuidString) == value.input.entries.map(\.entryID.uuidString).sorted(),
              value.input.credentials.map(\.revisionID.uuidString) == value.input.credentials.map(\.revisionID.uuidString).sorted() else {
            throw DeviceNativeGrantPreparationError.invalidRecord
        }
        return value
    }
    private func recoveredRequest(_ bytes: Data, resources: DeviceNativeGrantRecoveryResources,
                                  expectedEntries: [DeviceGrantEntryExpectation]) throws -> DeviceNativeGrantPreparationRequest {
        guard resources.packages.count <= 12, expectedEntries.count <= 12 else { throw DeviceNativeGrantPreparationError.sizeLimit }
        let value = try decodePrivate(bytes)
        let fresh = try DeviceNativeGrantRevisionQualifier.qualify(value.input, expectedEntries: expectedEntries)
        let request = DeviceNativeProvisioningRequest(roots: resources.roots, delivery: resources.delivery,
            grantOperationID: value.operationID, baseline: resources.baseline, candidate: resources.candidate,
            packages: resources.packages, grantInput: value.input, qualifiedGrant: fresh)
        let plan = try DeviceNativeProvisioningPlanner.qualify(request)
        guard plan.intentBytes == value.completeSetIntent else { throw DeviceNativeGrantPreparationError.conflict }
        let result = DeviceNativeGrantPreparationRequest(operationID: value.operationID, input: value.input,
            qualified: fresh, expectedEntries: expectedEntries, plan: plan)
        guard try NativeGrantPreparationCodec.privateBytes(result, rootID: rootID) == bytes else {
            throw DeviceNativeGrantPreparationError.conflict
        }
        return result
    }
    /// Strict bounded diagnostic reconstruction; no synchronization, private getter or ACK.
    /// The ORIGINAL epoch/nodes/reference are retained before any outside journal/package repair.
    func inspectRecoveryExact(operationID: UUID, resources: DeviceNativeGrantRecoveryResources,
        expectedEntries: [DeviceGrantEntryExpectation]) throws -> RecoveryCheckpoint {
        try disk { context in
            let before = epoch(), original = try checkedBinding(context)
            guard let node = try operationNode(context, operationID, "record", limit: 65536), !node.bytes.isEmpty else {
                throw DeviceNativeGrantPreparationError.repairRequired
            }
            let record: Record = try strictDecode(node.bytes, limit: 65536)
            let item = record.privateAttempt
            guard record.schemaVersion == 3, record.selfID == node.id,
                  record.operationID == operationID, record.rootID == rootID,
                  item.account.utf8.elementsEqual(GrantPreparationCodec.attemptAccount(operationID).utf8),
                  !item.persistentReference.isEmpty, item.persistentReference.count <= 1024,
                  item.byteCount >= 0, item.byteCount <= NativeGrantPreparationCodec.privateLimit,
                  let stored = try backend.read(service: GrantPreparationCodec.service(rootID), account: item.account,
                    maximumBytes: NativeGrantPreparationCodec.privateLimit), stored.item == item else {
                throw DeviceNativeGrantPreparationError.repairRequired
            }
            let request = try recoveredRequest(stored.bytes, resources: resources, expectedEntries: expectedEntries)
            guard request.operationID == operationID else { throw DeviceNativeGrantPreparationError.conflict }
            _ = try preflight(context, request: request, privateBytes: stored.bytes, intentBytes: publicIntent(request, privateBytes: stored.bytes))
            var nodes: [String: Node] = [:]
            for name in try names(context.operations, maximum: 8) {
                guard let node = try read(context.operations, name, limit: 131072) else { throw DeviceNativeGrantPreparationError.unsafeBinding }
                nodes[name] = node
            }
            guard before == epoch() else { throw DeviceNativeGrantPreparationError.conflict }
            return .init(ObjectIdentifier(self), before, request.plan, original.0, original.1, nodes, item,
                         stored.bytes, operationID: operationID)
        }
    }
    private func verifyRecovery(_ context: Context, _ original: RecoveryCheckpoint,
        resources: DeviceNativeGrantRecoveryResources, expectedEntries: [DeviceGrantEntryExpectation]) throws -> DeviceNativeGrantPreparationRequest {
        guard original.issuer == ObjectIdentifier(self), original.epoch == epoch() else { throw DeviceNativeGrantPreparationError.conflict }
        let binding = try checkedBinding(context)
        guard binding.0 == original.rootBinding, binding.1 == original.genesis,
              Set(try names(context.operations, maximum: 8)) == Set(original.nodes.keys) else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        for (name, node) in original.nodes {
            guard try read(context.operations, name, limit: 131072) == node else { throw DeviceNativeGrantPreparationError.unsafeBinding }
        }
        guard let value = try backend.read(service: GrantPreparationCodec.service(rootID), account: original.item.account,
            maximumBytes: NativeGrantPreparationCodec.privateLimit), value.item == original.item,
              value.bytes == original.privateBytes else { throw DeviceNativeGrantPreparationError.repairRequired }
        let request = try recoveredRequest(value.bytes, resources: resources, expectedEntries: expectedEntries)
        guard request.plan.intentBytes == original.plan.intentBytes, request.plan.candidateBytes == original.plan.candidateBytes else {
            throw DeviceNativeGrantPreparationError.conflict
        }
        _ = try preflight(context, request: request, privateBytes: value.bytes, intentBytes: publicIntent(request, privateBytes: value.bytes))
        return request
    }
    func verifyRecoveryExact(_ original: RecoveryCheckpoint, resources: DeviceNativeGrantRecoveryResources,
        expectedEntries: [DeviceGrantEntryExpectation], resourcePermit: DeviceLocalResourcePermit) throws {
        try disk(permit: resourcePermit) { context in
            _ = try verifyRecovery(context, original, resources: resources, expectedEntries: expectedEntries)
        }
    }

    func performRecoveredPrivateAttemptExact(_ original: RecoveryCheckpoint,
        resources: DeviceNativeGrantRecoveryResources, expectedEntries: [DeviceGrantEntryExpectation],
        commandPermit: DeviceNativeGrantPrivateCommandPermit) throws -> PendingPrivateAttempt {
        try commandPermit.begin(ObjectIdentifier(self)); defer { commandPermit.end() }
        guard let context = borrowed else { throw DeviceLocalResourceGateFailure.invalidScope }
        let request = try verifyRecovery(context, original, resources: resources, expectedEntries: expectedEntries)
        // No checkpoint is recaptured after this intentional epoch transition.
        return try performPrivateAttempt(context, request: request)
    }
    func verifyRecoveredPendingExact(_ transition: PendingPrivateAttempt, original: RecoveryCheckpoint,
        resources: DeviceNativeGrantRecoveryResources, expectedEntries: [DeviceGrantEntryExpectation],
        resourcePermit: DeviceLocalResourcePermit) throws {
        let request = try recoveredRequest(original.privateBytes, resources: resources, expectedEntries: expectedEntries)
        guard transition.operationID == original.operationID else { throw DeviceNativeGrantPreparationError.conflict }
        try verifyPendingExact(transition, request: request, resourcePermit: resourcePermit)
    }

}
