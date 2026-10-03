import Foundation
import Darwin
import CryptoKit
import ScreenpunkCore

public enum CloudWorkspaceSetupOperationStoreError: Error, Equatable, Sendable {
    case invalidConfiguration, unsafeBinding, legacyEvidence, corrupt, conflict, outcomeUncertain
    case io(operation: String, code: Int32)
}

/// Unmounted, nonsecret persistence only. This is not Cloud enrollment or management authority.
/// Cooperating processes use flock; arbitrary external writers and rollback across restart are not excluded.
public final class CloudWorkspaceSetupOperationStore: @unchecked Sendable {
    enum Boundary: CaseIterable { case afterDirectoryCreation, afterEmptyProtection, beforeMetadataSync, afterMetadataSync, beforeMetadataRename, afterMetadataRename, beforeMetadataDirectorySync, afterMetadataDirectorySync, afterRootScratchCreation, afterAttemptScratchCreation, afterAckScratchCreation, afterMetadataWrite, afterRootBinding, beforeAttempt, afterAttempt, afterCandidateCreation, afterCandidateSync, afterPreparedAttempt, afterCandidateReplace, afterCandidateDirectorySync, afterAck, afterFinalSync }
    private enum Method: String, Codable { case save, beginSuccessor }
    private struct Identity: Codable, Equatable { let device: UInt64, inode: UInt64; init(_ value: stat) { device = UInt64(value.st_dev); inode = UInt64(value.st_ino) } }
    private struct FileValue: Codable, Equatable { let bytes: Data; let identity: Identity }
    private struct RootBinding: Codable, Equatable { let version: Int; let root: Identity; let lock: Identity }
    private struct Attempt: Codable, Equatable {
        let version: Int; let root: RootBinding; let method: Method; let target: Data; let baseline: FileValue?; let baselineAck: FileValue
        let prepared: Identity?
        func preparing(_ identity: Identity) -> Self { .init(version: version, root: root, method: method, target: target, baseline: baseline, baselineAck: baselineAck, prepared: identity) }
    }
    private struct Ack: Codable, Equatable { let version: Int; let root: RootBinding; let attemptDigest: String?; let candidate: FileValue? }
    private final class Shared {
        let lock = NSRecursiveLock(); var active = false
        var method: Method?; var bytes: Data?; var attempt: Attempt?; var root: RootBinding?
        var retained: [Int32] = []
        var rootDescriptors: [Int32] = []
        var scratch: [String: (Identity, Data)] = [:]
        var createdDirectories: [Directory] = []
        deinit { (retained + rootDescriptors).forEach { close($0) } }
        func retain(_ descriptor: Int32) throws {
            let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw CloudWorkspaceSetupOperationStoreError.io(operation: "retain", code: errno) }
            retained.append(copy)
        }
        func clear() { method = nil; bytes = nil; attempt = nil; scratch = [:]; retained.forEach { close($0) }; retained = [] }
    }
    private static let registryLock = NSLock()
    private static var registry: [String: Shared] = [:]
    private static func shared(_ key: String) -> Shared {
        registryLock.lock(); defer { registryLock.unlock() }
        if let value = registry[key] { return value }; let value = Shared(); registry[key] = value; return value
    }
    private static let rootName = "workspace-root.json", attemptName = "workspace-attempt.json", ackName = "workspace-ack.json"
    private static let candidateName = "workspace-operation.json", lockName = "workspace.lock"
    private static let names = [rootName, attemptName, ackName, candidateName]
    public let directory: URL
    public let legacyJournal: URL
    private let state: Shared
    private let boundary: (Boundary) throws -> Void
    private let directorySyncObserved: (String) -> Void
    private let metadataBoundary: (String, Boundary) throws -> Void
    public convenience init(directory: URL, legacyJournal: URL) throws { try self.init(directory: directory, legacyJournal: legacyJournal, boundary: { _ in }) }
    init(directory: URL, legacyJournal: URL, boundary: @escaping (Boundary) throws -> Void, testOnlyProcessID: UUID? = nil, directorySyncObserved: @escaping (String) -> Void = { _ in }, metadataBoundary: @escaping (String, Boundary) throws -> Void = { _, _ in }) throws {
        self.directory = ScreenPreferenceAtomicWriter.canonicalRoot(directory)
        self.legacyJournal = ScreenPreferenceAtomicWriter.canonicalRoot(legacyJournal)
        guard directory.isFileURL, legacyJournal.isFileURL, self.directory.path != "/",
              !self.directory.path.utf8.contains(0), !self.legacyJournal.path.utf8.contains(0),
              self.directory.deletingLastPathComponent() == self.legacyJournal.deletingLastPathComponent().deletingLastPathComponent(),
              self.directory.lastPathComponent == "xyz.screenpunk.cloud-operations",
              self.legacyJournal.lastPathComponent == "native-workspace-setup.json",
              self.legacyJournal.deletingLastPathComponent().lastPathComponent == "xyz.screenpunk.device" else { throw CloudWorkspaceSetupOperationStoreError.invalidConfiguration }
        self.boundary = boundary; self.directorySyncObserved = directorySyncObserved; self.metadataBoundary = metadataBoundary; state = Self.shared(self.directory.path + (testOnlyProcessID.map { "#" + $0.uuidString } ?? ""))
    }
    private func exclusive<T>(_ body: () throws -> T) throws -> T {
        state.lock.lock(); defer { state.lock.unlock() }
        guard !state.active else { throw CloudWorkspaceSetupOperationStoreError.conflict }
        state.active = true; defer { state.active = false }
        try checkLegacy(); return try body()
    }
    public func load() throws -> CloudWorkspaceSetupOperationRecord? {
        try exclusive {
            guard state.method == nil else { throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain }
            return try withDisk(create: false) { disk in
                guard let disk else { return nil }
                return try acknowledged(disk)
            }
        }
    }
    /// Inspection cannot acknowledge an uncertain commit.
    public func diagnosticReadback() throws -> CloudWorkspaceSetupOperationRecord? {
        try exclusive { try withDisk(create: false) { disk in
            guard let disk, let value = try disk.read(Self.candidateName, limit: 16 * 1024) else { return nil }
            return try Self.record(value.bytes)
        } }
    }
    public func save(_ record: CloudWorkspaceSetupOperationRecord) throws { try persist(record, method: .save) }
    public func beginSuccessor(_ record: CloudWorkspaceSetupOperationRecord) throws { try persist(record, method: .beginSuccessor) }
    /// Recommits only the exact retained/persisted method and target. Never chooses an operation UUID.
    @discardableResult public func retryPendingWrite() throws -> CloudWorkspaceSetupOperationRecord? {
        try exclusive {
            if let bytes = state.bytes, let method = state.method { return try perform(Self.record(bytes), method: method) }
            return try withDisk(create: false) { disk in
                guard let disk else { throw CloudWorkspaceSetupOperationStoreError.conflict }
                let root = try binding(disk)
                guard let raw = try disk.read(Self.attemptName, limit: 64 * 1024) else {
                    // Only incomplete first-root initialization has no operation attempt.
                    try disk.rejectScratch()
                    guard try disk.read(Self.candidateName, limit: 16 * 1024) == nil,
                          try disk.read(Self.ackName, limit: 64 * 1024) == nil else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                    try disk.syncFile(Self.rootName); try disk.sync()
                    try disk.replace(Self.ackName, bytes: Self.encode(Ack(version: 1, root: root, attemptDigest: nil, candidate: nil)))
                    try disk.syncFile(Self.ackName); try disk.sync(); return nil
                }
                let attempt = try Self.attempt(raw.bytes)
                guard attempt.root == root else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
                try disk.rejectScratch(allowCandidate: attempt.prepared)
                state.method = attempt.method; state.bytes = attempt.target; state.attempt = attempt; state.root = root
                try state.retain(disk.descriptor); try state.retain(disk.lock)
                return try commit(disk, attempt: attempt)
            }
        }
    }
    private func persist(_ record: CloudWorkspaceSetupOperationRecord, method: Method) throws {
        try exclusive {
            let bytes = try record.encoded()
            if let previous = state.bytes {
                guard previous == bytes, state.method == method else { throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain }
            }
            _ = try perform(record, method: method)
        }
    }
    private func perform(_ record: CloudWorkspaceSetupOperationRecord, method: Method) throws -> CloudWorkspaceSetupOperationRecord {
        let bytes = try record.encoded()
        // Validate the transition against acknowledged predecessor evidence before retaining a new attempt.
        // This readback may re-sync the predecessor, but creates no new operation evidence.
        if state.method == nil {
            try withDisk(create: false) { disk in
                let current = try disk.map { try acknowledged($0) } ?? nil
                if let current { guard current.permits(record, beginningSuccessor: method == .beginSuccessor) else { throw CloudWorkspaceSetupOperationStoreError.conflict } }
                else { guard method == .save, record.receipt == nil else { throw CloudWorkspaceSetupOperationStoreError.conflict } }
            }
            // Retain exact new method/bytes before any directory/lock creation or new operation write.
            state.method = method; state.bytes = bytes
        }
        return try withDisk(create: true) { disk in
            guard let disk else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            try state.retain(disk.descriptor); try state.retain(disk.lock)
            let root = try initializeBinding(disk)
            if let retained = state.attempt {
                guard retained.root == root, retained.method == method, retained.target == bytes else { throw CloudWorkspaceSetupOperationStoreError.conflict }
                return try commit(disk, attempt: retained)
            }
            let current = try acknowledged(disk)
            if let current {
                guard current.permits(record, beginningSuccessor: method == .beginSuccessor) else { throw CloudWorkspaceSetupOperationStoreError.conflict }
            } else { guard method == .save, record.receipt == nil else { throw CloudWorkspaceSetupOperationStoreError.conflict } }
            let baseline = try disk.read(Self.candidateName, limit: 16 * 1024)
            if baseline != nil { try disk.retainFile(Self.candidateName, in: state) }
            guard let baselineAck = try disk.read(Self.ackName, limit: 64 * 1024) else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
            try disk.retainFile(Self.ackName, in: state)
            let attempt = Attempt(version: 1, root: root, method: method, target: bytes, baseline: baseline, baselineAck: baselineAck, prepared: nil)
            _ = try Self.encode(attempt) // Bound complete attempted evidence before any new intent side effect.
            state.attempt = attempt
            try boundary(.beforeAttempt)
            try disk.replace(Self.attemptName, bytes: Self.encode(attempt)); try disk.syncFile(Self.attemptName); try disk.sync()
            try boundary(.afterAttempt)
            return try commit(disk, attempt: attempt)
        }
    }
    private func commit(_ disk: Disk, attempt original: Attempt) throws -> CloudWorkspaceSetupOperationRecord {
        var attempt = original
        guard try binding(disk) == attempt.root else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
        // A visible attempt is diagnostic until this exact commit synchronizes it.
        if let raw = try disk.read(Self.attemptName, limit: 64 * 1024) {
            let visible = try Self.attempt(raw.bytes)
            if visible != attempt {
                // The predecessor may remain when replacement of the new intent failed.
                let sameUnpreparedIntent = visible.root == attempt.root && visible.method == attempt.method && visible.target == attempt.target && visible.baseline == attempt.baseline && visible.baselineAck == attempt.baselineAck && visible.prepared == nil
                var predecessor = false
                if visible.root == attempt.root, let baseline = attempt.baseline,
                   visible.target == baseline.bytes, visible.prepared == baseline.identity,
                   let ackBytes = try disk.read(Self.ackName, limit: 64 * 1024)?.bytes {
                    let ack: Ack = try Self.decode(ackBytes, keys: ["version", "root", "attemptDigest", "candidate"], optional: ["attemptDigest", "candidate"])
                    predecessor = ack.version == 1 && ack.root == attempt.root && ack.candidate == baseline
                        && ack.attemptDigest == Self.digest(raw.bytes)
                }
                guard sameUnpreparedIntent || predecessor else { throw CloudWorkspaceSetupOperationStoreError.conflict }
            }
        }
        let current = try disk.read(Self.candidateName, limit: 16 * 1024)
        guard let observedAck = try disk.read(Self.ackName, limit: 64 * 1024) else { throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain }
        var targetAckMatches = false
        if let prepared = attempt.prepared, let current, current.identity == prepared, current.bytes == attempt.target {
            let expected = Ack(version: 1, root: attempt.root, attemptDigest: Self.digest(try Self.encode(attempt)), candidate: current)
            targetAckMatches = observedAck.bytes == (try Self.encode(expected))
        }
        guard observedAck == attempt.baselineAck || targetAckMatches else { throw CloudWorkspaceSetupOperationStoreError.conflict }
        let installed = current.map { $0.bytes == attempt.target && $0.identity == attempt.prepared } ?? false
        guard current == attempt.baseline || installed else { throw CloudWorkspaceSetupOperationStoreError.conflict }
        try disk.replace(Self.attemptName, bytes: Self.encode(attempt)); try disk.syncFile(Self.attemptName); try disk.sync()
        if !installed {
            let pending = Self.candidateName + ".pending"
            if let existing = try disk.read(pending, limit: 16 * 1024) {
                guard existing.identity == attempt.prepared || (state.scratch[pending]?.0 == existing.identity && state.scratch[pending]?.1 == attempt.target) else { throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain }
                try disk.remove(pending); try disk.sync()
            }
            let file = try disk.createEmpty(pending, expected: attempt.target)
            defer { close(file) }
            var metadata = stat(); guard fstat(file, &metadata) == 0 else { throw disk.error("statCandidate") }
            try state.retain(file)
            // Retain scratch identity before any failure; only the later synced attempt exports it across restart.
            state.attempt = attempt.preparing(Identity(metadata))
            try boundary(.afterCandidateCreation)
            try disk.write(file, bytes: attempt.target); try disk.sync(file)
            try boundary(.afterCandidateSync)
            attempt = attempt.preparing(Identity(metadata)); state.attempt = attempt
            try disk.replace(Self.attemptName, bytes: Self.encode(attempt)); try disk.syncFile(Self.attemptName); try disk.sync()
            try boundary(.afterPreparedAttempt)
            guard try disk.read(Self.candidateName, limit: 16 * 1024) == attempt.baseline else { throw CloudWorkspaceSetupOperationStoreError.conflict }
            guard try disk.read(pending, limit: 16 * 1024) == FileValue(bytes: attempt.target, identity: Identity(metadata)) else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            try disk.rename(pending, Self.candidateName)
            try boundary(.afterCandidateReplace)
        }
        try disk.syncFile(Self.candidateName); try disk.sync(); try boundary(.afterCandidateDirectorySync)
        guard let candidate = try disk.read(Self.candidateName, limit: 16 * 1024), candidate.bytes == attempt.target, candidate.identity == attempt.prepared else { throw CloudWorkspaceSetupOperationStoreError.conflict }
        let ack = Ack(version: 1, root: attempt.root, attemptDigest: Self.digest(try Self.encode(attempt)), candidate: candidate)
        try disk.replace(Self.ackName, bytes: Self.encode(ack)); try boundary(.afterAck)
        try disk.syncFile(Self.rootName); try disk.syncFile(Self.attemptName); try disk.syncFile(Self.ackName); try disk.sync()
        guard try acknowledged(disk, allowRetained: true) == Self.record(attempt.target) else { throw CloudWorkspaceSetupOperationStoreError.conflict }
        try boundary(.afterFinalSync)
        state.clear(); return try Self.record(attempt.target)
    }
    private func initializeBinding(_ disk: Disk) throws -> RootBinding {
        if try disk.read(Self.rootName, limit: 4096) != nil {
            let existing = try binding(disk)
            if state.root == existing, state.attempt == nil, try disk.read(Self.ackName, limit: 64 * 1024) == nil {
                guard try disk.read(Self.attemptName, limit: 64 * 1024) == nil, try disk.read(Self.candidateName, limit: 16 * 1024) == nil else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                try disk.syncFile(Self.rootName); try disk.sync()
                try disk.replace(Self.ackName, bytes: Self.encode(Ack(version: 1, root: existing, attemptDigest: nil, candidate: nil)))
                try disk.syncFile(Self.ackName); try disk.sync()
            }
            return existing
        }
        guard try disk.read(Self.attemptName, limit: 64 * 1024) == nil, try disk.read(Self.ackName, limit: 64 * 1024) == nil,
              try disk.read(Self.candidateName, limit: 16 * 1024) == nil else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
        let value = state.root ?? RootBinding(version: 1, root: disk.identity, lock: disk.lockIdentity)
        guard value.root == disk.identity, value.lock == disk.lockIdentity else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
        state.root = value
        if state.rootDescriptors.isEmpty {
            for descriptor in [disk.descriptor, disk.lock] { let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0); guard copy >= 0 else { throw disk.error("retainRoot") }; state.rootDescriptors.append(copy) }
        }
        try disk.replace(Self.rootName, bytes: Self.encode(value)); try disk.syncFile(Self.rootName); try disk.sync()
        try boundary(.afterRootBinding)
        try disk.replace(Self.ackName, bytes: Self.encode(Ack(version: 1, root: value, attemptDigest: nil, candidate: nil))); try disk.syncFile(Self.ackName); try disk.sync()
        return value
    }
    private func binding(_ disk: Disk) throws -> RootBinding {
        guard let bytes = try disk.read(Self.rootName, limit: 4096)?.bytes else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
        let value: RootBinding = try Self.decode(bytes, keys: ["version", "root", "lock"])
        guard value.version == 1, value.root == disk.identity, value.lock == disk.lockIdentity else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
        if state.root == nil {
            state.root = value
            for descriptor in [disk.descriptor, disk.lock] {
                let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                guard copy >= 0 else { throw disk.error("retainRoot") }; state.rootDescriptors.append(copy)
            }
        } else { guard state.root == value else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding } }
        return value
    }
    private func acknowledged(_ disk: Disk, allowRetained: Bool = false) throws -> CloudWorkspaceSetupOperationRecord? {
        try disk.rejectScratch()
        let root = try binding(disk)
        guard let raw = try disk.read(Self.ackName, limit: 64 * 1024) else { throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain }
        let ack: Ack = try Self.decode(raw.bytes, keys: ["version", "root", "attemptDigest", "candidate"], optional: ["attemptDigest", "candidate"])
        guard ack.version == 1, ack.root == root else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
        let rootSnapshot = try disk.read(Self.rootName, limit: 4096)
        let attemptSnapshot = try disk.read(Self.attemptName, limit: 64 * 1024)
        let candidate = try disk.read(Self.candidateName, limit: 16 * 1024)
        guard candidate == ack.candidate else { throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain }
        if let attemptRaw = attemptSnapshot {
            let attempt = try Self.attempt(attemptRaw.bytes)
            guard attempt.root == root, Self.digest(attemptRaw.bytes) == ack.attemptDigest,
                  candidate?.bytes == attempt.target, candidate?.identity == attempt.prepared else { throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain }
        } else { guard ack.attemptDigest == nil, candidate == nil else { throw CloudWorkspaceSetupOperationStoreError.corrupt } }
        // Conservatively recommit synchronization of visible acknowledged evidence on restart.
        for name in [Self.rootName, Self.attemptName, Self.candidateName, Self.ackName] { if try disk.read(name, limit: 64 * 1024) != nil { try disk.syncFile(name) } }
        try disk.sync()
        guard try disk.read(Self.ackName, limit: 64 * 1024) == raw, try disk.read(Self.candidateName, limit: 16 * 1024) == candidate,
              try disk.read(Self.rootName, limit: 4096) == rootSnapshot, try disk.read(Self.attemptName, limit: 64 * 1024) == attemptSnapshot else { throw CloudWorkspaceSetupOperationStoreError.conflict }
        return try candidate.map { try Self.record($0.bytes) }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let bytes = try encoder.encode(value); guard bytes.count <= 64 * 1024 else { throw CloudWorkspaceSetupOperationStoreError.corrupt }; return bytes }
    private static func decode<T: Decodable>(_ bytes: Data, keys: Set<String>, optional: Set<String> = []) throws -> T {
        do {
            try WorkspaceStoreStrictJSON.validate(bytes)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys).isSubset(of: keys), keys.subtracting(optional).isSubset(of: Set(object.keys)) else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
            func exact(_ value: Any?, _ expected: Set<String>) throws {
                guard let object = value as? [String: Any], Set(object.keys) == expected else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
            }
            if let root = object["root"] as? [String: Any], root["version"] != nil {
                try exact(root, ["version", "root", "lock"])
                try exact(root["root"], ["device", "inode"]); try exact(root["lock"], ["device", "inode"])
            } else if object["root"] != nil { try exact(object["root"], ["device", "inode"]) }
            if object["lock"] != nil { try exact(object["lock"], ["device", "inode"]) }
            for name in ["baseline", "baselineAck", "candidate"] {
                if let value = object[name] as? [String: Any] { try exact(value, ["bytes", "identity"]); try exact(value["identity"], ["device", "inode"]) }
                else if object[name] != nil { throw CloudWorkspaceSetupOperationStoreError.corrupt }
            }
            if object["prepared"] != nil { try exact(object["prepared"], ["device", "inode"]) }
            return try JSONDecoder().decode(T.self, from: bytes)
        } catch { throw CloudWorkspaceSetupOperationStoreError.corrupt }
    }
    private static func record(_ bytes: Data) throws -> CloudWorkspaceSetupOperationRecord { do { return try .decode(bytes) } catch { throw CloudWorkspaceSetupOperationStoreError.corrupt } }
    private static func attempt(_ bytes: Data) throws -> Attempt {
        let value: Attempt = try decode(bytes, keys: ["version", "root", "method", "target", "baseline", "baselineAck", "prepared"], optional: ["baseline", "prepared"])
        guard value.version == 1 else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
        let target = try record(value.target)
        let baselineAck: Ack = try decode(value.baselineAck.bytes, keys: ["version", "root", "attemptDigest", "candidate"], optional: ["attemptDigest", "candidate"])
        guard baselineAck.version == 1, baselineAck.root == value.root, baselineAck.candidate == value.baseline,
              (value.baseline != nil || baselineAck.attemptDigest == nil) else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
        if let baseline = value.baseline { guard try record(baseline.bytes).permits(target, beginningSuccessor: value.method == .beginSuccessor) else { throw CloudWorkspaceSetupOperationStoreError.corrupt } }
        else { guard value.method == .save, target.receipt == nil else { throw CloudWorkspaceSetupOperationStoreError.corrupt } }
        return value
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func checkLegacy() throws {
        do {
            if let parent = try Directory.open(legacyJournal.deletingLastPathComponent(), create: false, privateRoot: false) {
                var value = stat()
                if fstatat(parent.descriptor, legacyJournal.lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0 { throw CloudWorkspaceSetupOperationStoreError.legacyEvidence }
                guard errno == ENOENT else { throw CloudWorkspaceSetupOperationStoreError.legacyEvidence }
            }
        } catch { throw CloudWorkspaceSetupOperationStoreError.legacyEvidence }
    }
    private func withDisk<T>(create: Bool, _ operation: (Disk?) throws -> T) throws -> T {
        guard let directory = try Directory.open(directory, create: create, shared: state, boundary: boundary, syncObserved: directorySyncObserved) else {
            guard state.root == nil, state.attempt == nil else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            return try operation(nil)
        }
        let disk = try Disk(directory: directory, create: create, shared: state, boundary: boundary, metadataBoundary: metadataBoundary)
        defer { flock(disk.lock, LOCK_UN) }
        if let expected = state.root { guard expected.root == disk.identity, expected.lock == disk.lockIdentity else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding } }
        return try operation(disk)
    }
    private final class Directory {
        let descriptor: Int32, identity: Identity, parent: Directory?, name: String?
        init(_ descriptor: Int32, parent: Directory? = nil, name: String? = nil) throws {
            self.descriptor = descriptor; self.parent = parent; self.name = name
            var value = stat(); guard fstat(descriptor, &value) == 0 else { close(descriptor); throw CloudWorkspaceSetupOperationStoreError.io(operation: "statDirectory", code: errno) }
            identity = Identity(value)
        }
        deinit { close(descriptor) }
        func verify() throws {
            if let parent, let name {
                try parent.verify(); var value = stat()
                guard fstatat(parent.descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
                      Identity(value) == identity, value.st_mode & S_IFMT == S_IFDIR else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            }
        }
        func sync() throws { try verify(); guard fsync(descriptor) == 0 else { throw CloudWorkspaceSetupOperationStoreError.io(operation: "syncDirectory", code: errno) }; try verify() }
        var path: String { guard let parent, let name else { return "/" }; return (parent.path == "/" ? "" : parent.path) + "/" + name }
        static func open(_ url: URL, create: Bool, privateRoot: Bool = true, shared: Shared? = nil,
                         boundary: (Boundary) throws -> Void = { _ in }, syncObserved: (String) -> Void = { _ in }) throws -> Directory? {
            func finishCreated() throws {
                while let created = shared?.createdDirectories.first {
                    try created.verify(); syncObserved(created.path); try created.sync()
                    if let parent = created.parent { syncObserved(parent.path); try parent.sync() }
                    shared?.createdDirectories.removeFirst()
                }
            }
            try finishCreated()
            let descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw CloudWorkspaceSetupOperationStoreError.io(operation: "openRoot", code: errno) }
            var current = try Directory(descriptor)
            for name in url.path.split(separator: "/").map(String.init) {
                try current.verify()
                var descriptor = openat(current.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                var created = false
                if descriptor < 0, errno == ENOENT {
                    guard create else { return nil }
                    if mkdirat(current.descriptor, name, 0o700) == 0 { created = true }
                    else if errno != EEXIST { throw CloudWorkspaceSetupOperationStoreError.io(operation: "createDirectory", code: errno) }
                    descriptor = openat(current.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                }
                guard descriptor >= 0 else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
                let child = try Directory(descriptor, parent: current, name: name)
                if created {
                    guard let shared else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
                    // Retain the exact child and parent chain before any post-creation failure.
                    shared.createdDirectories.append(child)
                    try boundary(.afterDirectoryCreation); try finishCreated()
                }
                current = child
            }
            try current.verify(); var metadata = stat()
            guard fstat(current.descriptor, &metadata) == 0, metadata.st_uid == geteuid(), (!privateRoot || metadata.st_mode & 0o077 == 0) else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            return current
        }
    }
    private final class Disk {
        let directory: Directory, lock: Int32, lockIdentity: Identity
        let shared: Shared, boundary: (Boundary) throws -> Void
        let metadataBoundary: (String, Boundary) throws -> Void
        var descriptor: Int32 { directory.descriptor }; var identity: Identity { directory.identity }
        init(directory: Directory, create: Bool, shared: Shared, boundary: @escaping (Boundary) throws -> Void, metadataBoundary: @escaping (String, Boundary) throws -> Void) throws {
            self.directory = directory; self.shared = shared; self.boundary = boundary; self.metadataBoundary = metadataBoundary
            let lock = openat(directory.descriptor, lockName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | (create ? O_CREAT : 0), 0o600)
            guard lock >= 0 else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            var value = stat()
            guard fstat(lock, &value) == 0, Self.valid(value) else { close(lock); throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            self.lock = lock; lockIdentity = Identity(value)
            guard flock(lock, LOCK_EX) == 0 else { close(lock); throw CloudWorkspaceSetupOperationStoreError.io(operation: "lock", code: errno) }
            try sync(lock); try directory.sync()
        }
        deinit { close(lock) }
        func error(_ operation: String) -> CloudWorkspaceSetupOperationStoreError { .io(operation: operation, code: errno) }
        static func valid(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1 && value.st_mode & 0o777 == 0o600 }
        func verify() throws {
            try directory.verify(); var value = stat()
            guard fstatat(descriptor, lockName, &value, AT_SYMLINK_NOFOLLOW) == 0, Self.valid(value), Identity(value) == lockIdentity else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
        }
        func read(_ name: String, limit: Int) throws -> FileValue? {
            try verify()
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if file < 0 { guard errno == ENOENT else { throw error("read") }; return nil }
            defer { close(file) }
            var value = stat()
            guard fstat(file, &value) == 0, Self.valid(value), value.st_size >= 0, value.st_size <= limit else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw error("read") }; if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count)); guard data.count <= limit else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
            }
            var observed = stat()
            guard fstatat(descriptor, name, &observed, AT_SYMLINK_NOFOLLOW) == 0, Self.valid(observed), Identity(observed) == Identity(value), observed.st_size == data.count else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            return FileValue(bytes: data, identity: Identity(value))
        }
        func retainFile(_ name: String, in shared: Shared) throws {
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard file >= 0 else { throw error("retainFile") }; defer { close(file) }; try shared.retain(file)
        }
        func rejectScratch(allowCandidate: Identity? = nil) throws {
            for name in names {
                var value = stat()
                if fstatat(descriptor, name + ".pending", &value, AT_SYMLINK_NOFOLLOW) == 0 {
                    if name == candidateName, let allowCandidate, Self.valid(value), Identity(value) == allowCandidate { continue }
                    throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain
                }
                guard errno == ENOENT else { throw error("inspectScratch") }
            }
        }
        func sync(_ file: Int32) throws { guard fsync(file) == 0 else { throw error("syncFile") } }
        func sync() throws { try verify(); try directory.sync() }
        func syncFile(_ name: String) throws {
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard file >= 0 else { throw error("openSync") }; defer { close(file) }
            var value = stat(); guard fstat(file, &value) == 0, Self.valid(value) else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            try sync(file); try verify()
        }
        func createEmpty(_ name: String, expected: Data) throws -> Int32 {
            try verify()
            let file = openat(descriptor, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard file >= 0 else { throw error("create") }
            do {
                var before = stat(); guard fstat(file, &before) == 0, Self.valid(before), before.st_size == 0 else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
                // Retain the empty inode before protection assignment or any injected failure.
                shared.scratch[name] = (Identity(before), expected); try shared.retain(file)
                #if os(iOS)
                let path = URL(fileURLWithPath: pathOfRoot()).appendingPathComponent(name).path
                let required = FileProtectionType.completeUntilFirstUserAuthentication
                try FileManager.default.setAttributes([.protectionKey: required], ofItemAtPath: path)
                var after = stat(); guard fstatat(descriptor, name, &after, AT_SYMLINK_NOFOLLOW) == 0, Identity(before) == Identity(after), after.st_size == 0 else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let observed = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? (attributes[.protectionKey] as? String)
                #if targetEnvironment(simulator)
                let simulator = true
                #else
                let simulator = false
                #endif
                // Same Simulator-only observability policy as the qualified preference writer.
                guard ScreenPreferenceAtomicWriter.protectionReadbackMatches(observed, required: required.rawValue, simulator: simulator) else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
                #endif
                try boundary(.afterEmptyProtection)
                return file
            } catch { close(file); throw error }
        }
        func pathOfRoot() -> String {
            func path(_ value: Directory) -> String { guard let parent = value.parent, let name = value.name else { return "/" }; return (path(parent) == "/" ? "" : path(parent)) + "/" + name }
            return path(directory)
        }
        func write(_ file: Int32, bytes: Data) throws {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(file, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                    if count < 0 { if errno == EINTR { continue }; throw error("write") }
                    guard count > 0 else { throw CloudWorkspaceSetupOperationStoreError.io(operation: "write", code: EIO) }; offset += count
                }
            }
        }
        func rename(_ source: String, _ target: String) throws {
            try verify(); guard renameat(descriptor, source, descriptor, target) == 0 else { throw error("replace") }; try verify()
        }
        func remove(_ name: String) throws { try verify(); guard unlinkat(descriptor, name, 0) == 0 else { throw error("remove") }; try verify() }
        func replace(_ name: String, bytes: Data) throws {
            let pending = name + ".pending"
            // Only exact in-process scratch evidence may be rebuilt. Restart scratch is never promoted.
            if let existing = try read(pending, limit: 64 * 1024) {
                guard let known = shared.scratch[pending], known.0 == existing.identity, known.1 == bytes else { throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain }
                try remove(pending); try sync()
            }
            let file = try createEmpty(pending, expected: bytes); defer { close(file) }
            if name == rootName { try boundary(.afterRootScratchCreation) }
            else if name == attemptName { try boundary(.afterAttemptScratchCreation) }
            else if name == ackName { try boundary(.afterAckScratchCreation) }
            func hit(_ point: Boundary) throws { try boundary(point); try metadataBoundary(name, point) }
            try write(file, bytes: bytes); try hit(.afterMetadataWrite)
            try hit(.beforeMetadataSync); try sync(file); try hit(.afterMetadataSync)
            try hit(.beforeMetadataRename)
            guard let expected = shared.scratch[pending], try read(pending, limit: 64 * 1024) == FileValue(bytes: bytes, identity: expected.0) else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            try rename(pending, name)
            guard try read(name, limit: 64 * 1024) == FileValue(bytes: bytes, identity: expected.0) else { throw CloudWorkspaceSetupOperationStoreError.unsafeBinding }
            try hit(.afterMetadataRename)
            try hit(.beforeMetadataDirectorySync); try sync(); try hit(.afterMetadataDirectorySync)
            shared.scratch.removeValue(forKey: pending)
        }
    }
}

private enum WorkspaceStoreStrictJSON {
    static func validate(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
        var parser = Parser(bytes: Array(data)); try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
    }
    private struct Parser {
        let bytes: [UInt8]; var index = 0; var nodes = 4096
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) throws { guard index < bytes.count, bytes[index] == byte else { throw CloudWorkspaceSetupOperationStoreError.corrupt }; index += 1 }
        mutating func string() throws -> String {
            let start = index; try take(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    let data = Data(bytes[start..<index]); let decoded = try JSONDecoder().decode(String.self, from: data)
                    // JSONDecoder substitutes lone surrogates on some SDKs: verify escape pairing ourselves.
                    return decoded
                }
                guard byte >= 32 else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                if byte == 92 {
                    guard index < bytes.count else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                    let escaped = bytes[index]; index += 1
                    if escaped == 117 {
                        let code = try hex()
                        if (0xD800...0xDBFF).contains(code) { try take(92); try take(117); let low = try hex(); guard (0xDC00...0xDFFF).contains(low) else { throw CloudWorkspaceSetupOperationStoreError.corrupt } }
                        else if (0xDC00...0xDFFF).contains(code) { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                    } else if ![34,92,47,98,102,110,114,116].contains(escaped) { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                }
            }
            throw CloudWorkspaceSetupOperationStoreError.corrupt
        }
        mutating func hex() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard index < bytes.count, let digit = Int(String(UnicodeScalar(bytes[index])), radix: 16) else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                value = value * 16 + digit; index += 1
            }
            return value
        }
        mutating func value(depth: Int) throws {
            space(); nodes -= 1
            guard depth < 24, nodes >= 0, index < bytes.count else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
            if bytes[index] == 123 {
                index += 1; space(); var keys = Set<Data>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    space(); let key = try string()
                    guard keys.insert(Data(key.utf8)).inserted else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                    space(); try take(58); try value(depth: depth + 1); space()
                    guard index < bytes.count else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                    if bytes[index] == 125 { index += 1; return }; try take(44)
                }
            } else if bytes[index] == 91 {
                index += 1; space(); if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true { try value(depth: depth + 1); space(); guard index < bytes.count else { throw CloudWorkspaceSetupOperationStoreError.corrupt }; if bytes[index] == 93 { index += 1; return }; try take(44) }
            } else if bytes[index] == 34 { _ = try string() }
            else {
                let start = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw CloudWorkspaceSetupOperationStoreError.corrupt }
                // Foundation validates primitive spelling after structural preflight.
            }
        }
    }
}
