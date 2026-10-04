import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Unmounted mechanics only. No production caller, package/grant verification, migration, or authority.
/// One unresolved + 128 terminal operations; no pruning. Restoring/changing filesystem identity requires
/// explicit reconciliation. Only this owned root/operations directories are synchronized, never ancestors.
/// A bounded scan visits at most 260 names (128 terminal + one unresolved, including staging twins).
/// Each reconstructed instance requires explicit latest-terminal synchronization before new prepare.
/// A process-wide root epoch invalidates all instances before attempts; identity/bytes also qualify the tip.
/// Initial intent precedes candidate effects. Prepared records retain baseline/candidate inodes; unrecorded
/// candidate staging is repairable only by the original live attempt, never adopted after restart.
/// Corrupt/partial staging blocks; records are never pruned to regain capacity. Inode checks are local replacement guards, not portable backup guarantees.
final class DeviceStructuralStore {
    enum Kind: Equatable { case binding, intent, envelope, terminal }
    enum Boundary: Equatable { case afterWrite(Kind), afterFileSync(Kind), beforeReplace(Kind), afterReplace(Kind), afterDirectorySync(Kind) }
    enum StagingIdentitySite: Equatable { case candidateCreated, replacementRetried(Kind) }
    enum Recovery: Equatable {
        case terminalNeedsDurability(DeviceStructuralOperationRecord)
        case oldObserved(DeviceStructuralOperationRecord)
        case candidateNeedsDurability(DeviceStructuralOperationRecord)
    }
    struct Receipt: Equatable { let record: DeviceStructuralOperationRecord }
    private typealias Identity = StructuralStoreIdentity
    private static let gateLock = NSLock()
    private static var epochs: [String: UInt64] = [:]
    private var qualification: (epoch: UInt64, current: Node, proof: Node)?
    // Only identities captured by this live attempt may repair an unrecorded candidate staging inode.
    private var stagedIdentities: [UUID: Identity] = [:]
    private func epoch(invalidate: Bool = false) -> UInt64 {
        Self.gateLock.lock(); defer { Self.gateLock.unlock() }
        let key = root.path + "|" + rootID.uuidString
        let value = (Self.epochs[key] ?? 0) + (invalidate ? 1 : 0)
        Self.epochs[key] = value; return value
    }
    private struct Binding: Codable, Equatable {
        let schemaVersion: Int; let rootID: UUID; let canonicalPath: String
        let directory: Identity; let lock: Identity; let operations: Identity
    }
    private struct Node: Equatable { let identity: Identity; let bytes: Data }
    private struct Context { let root: Int32; let lock: Int32; let operations: Int32; let binding: Binding; let requiresBinding: Bool }
    let root: URL
    let rootID: UUID
    private let mutex = NSLock()
    private var bindingQualified = false
    private let boundary: (Boundary) throws -> Void
    private let stagingIdentityProbe: (Int32, StagingIdentitySite) throws -> Void
    private let envelopeName = "structural-envelope.json"
    init(root: URL, rootID: UUID, stagingIdentityProbe: @escaping (Int32, StagingIdentitySite) throws -> Void = { _, _ in },
         boundary: @escaping (Boundary) throws -> Void = { _ in }) {
        self.root = root.standardizedFileURL; self.rootID = rootID; self.boundary = boundary
        self.stagingIdentityProbe = stagingIdentityProbe
    }

    /// Root already exists; its UUID and every content identity/selection are caller chosen.
    /// Absence is an explicit initialization precondition, not permission to migrate legacy content.
    func initializeExplicit() throws {
        try disk(create: true) { context in
            if let existing = try readFile(context.root, "root-binding.json", limit: 8192) {
                guard try decodeBinding(existing.bytes) == context.binding else { throw DeviceStructuralStoreError.unsafeBinding }
                try syncExisting(context.root, "root-binding.json", expected: existing)
                try sync(context.lock); try sync(context.operations); try sync(context.root)
                try check(context); bindingQualified = true; return
            }
            guard try readFile(context.root, envelopeName, limit: StructuralStoreCodec.envelopeLimit) == nil,
                  try names(context.operations).isEmpty else { throw DeviceStructuralStoreError.conflict }
            let bytes = try StructuralStoreCodec.encode(context.binding)
            try replace(context, parent: context.root, name: "root-binding.json", bytes: bytes, expected: nil, kind: .binding)
            try sync(context.operations); try sync(context.root); try check(context)
            bindingQualified = true
        }
    }
    func prepare(_ record: DeviceStructuralOperationRecord) throws {
        let encoded = try StructuralStoreCodec.encode(record)
        let checked = try StructuralStoreCodec.record(encoded)
        guard checked.phase == .unresolved, checked.baselineIdentity == nil, checked.candidateIdentity == nil, checked.rootID == rootID else { throw DeviceStructuralStoreError.invalidRecord }
        try disk { context in try prepareChecked(context,record:record) }
    }
    private func prepareChecked(_ context: Context, record: DeviceStructuralOperationRecord) throws {
            let inventory = try inventory(context)
            if inventory.records.isEmpty && !bindingQualified { throw DeviceStructuralStoreError.outcomeUncertain }
            if let prior = inventory.records.first(where: { $0.operationID == record.operationID }) {
                guard prior.sameIntent(as: record) else { throw DeviceStructuralStoreError.conflict }
                // Exact intent staging can be completed after a failed prepare without new IDs.
                if prior.phase != .terminal, try readFile(context.operations, filename(record.operationID), limit: StructuralStoreCodec.operationLimit) == nil {
                    try replace(context, parent: context.operations, name: filename(record.operationID), bytes: StructuralStoreCodec.encode(prior), expected: nil, kind: .intent)
                }
                return // Existence remains diagnostic, not a commit acknowledgement.
            }
            if let current = inventory.current {
                guard let qualified = qualification, qualified.epoch == epoch(), qualified.current == current,
                      let tip = inventory.records.first(where: { $0.phase == .terminal && $0.candidate == current.bytes }),
                      try readFile(context.operations, filename(tip.operationID), limit: StructuralStoreCodec.operationLimit) == qualified.proof else { throw DeviceStructuralStoreError.outcomeUncertain }
            }
            guard inventory.records.filter({ $0.phase == .terminal }).count < 128 else { throw DeviceStructuralStoreError.capacity }
            guard !inventory.records.contains(where: { $0.phase != .terminal }), inventory.current?.bytes == record.expectedOld else { throw DeviceStructuralStoreError.conflict }
            try replace(context, parent: context.operations, name: filename(record.operationID), bytes: StructuralStoreCodec.encode(record.binding(baseline: inventory.current?.identity)), expected: nil, kind: .intent)
    }
    /// Diagnostic only. Even exact terminal bytes need synchronization before a receipt is returned.
    func recover(operationID: UUID) throws -> Recovery { try recoverRead(operationID:operationID,resourcePermit:nil) }
    func recover(operationID: UUID, resourcePermit: DeviceLocalResourcePermit) throws -> Recovery {
        try recoverRead(operationID:operationID,resourcePermit:resourcePermit)
    }
    private func recoverRead(operationID: UUID, resourcePermit: DeviceLocalResourcePermit?) throws -> Recovery {
        try disk(resourcePermit:resourcePermit) { context in
            let state = try inventory(context)
            guard let record = state.records.first(where: { $0.operationID == operationID }) else { throw DeviceStructuralStoreError.conflict }
            if record.phase == .terminal { return .terminalNeedsDurability(record) }
            if state.current?.bytes == record.expectedOld { return .oldObserved(record) }
            if state.current?.bytes == record.candidate { return .candidateNeedsDurability(record) }
            throw DeviceStructuralStoreError.conflict
        }
    }
    func attempt(operationID: UUID) throws -> Receipt { try recommitExact(operationID: operationID) }
    /// Exact replay synchronizes current state and retained proof; an old operation never replaces the tip.
    func recommitExact(operationID: UUID) throws -> Receipt {
        try disk { context in try recommitChecked(context,operationID:operationID) }
    }
    private func recommitChecked(_ context: Context, operationID: UUID) throws -> Receipt {
            let attemptEpoch = epoch(invalidate: true)
            qualification = nil
            var state = try inventory(context)
            guard let record = state.records.first(where: { $0.operationID == operationID }) else { throw DeviceStructuralStoreError.conflict }
            let recordName = filename(operationID)
            if record.phase == .terminal {
                guard let current = state.current else { throw DeviceStructuralStoreError.conflict }
                try syncExisting(context.root, envelopeName, expected: current); try boundary(.afterFileSync(.envelope)); try sync(context.root)
                guard let proof = try readFile(context.operations, recordName, limit: StructuralStoreCodec.operationLimit) else { throw DeviceStructuralStoreError.conflict }
                try syncExisting(context.operations, recordName, expected: proof); try boundary(.afterReplace(.terminal)); try sync(context.operations)
                try boundary(.afterDirectorySync(.terminal))
                try check(context); state = try inventory(context)
                if current.bytes == record.candidate && state.records.allSatisfy({ $0.phase == .terminal }) { qualification = (attemptEpoch, current, proof) }
                return Receipt(record: record)
            }
            guard let intent = try readFile(context.operations, recordName, limit: StructuralStoreCodec.operationLimit) else {
                // A retained exact initial-intent stage may be completed, before candidate effects.
                try replace(context, parent: context.operations, name: recordName, bytes: StructuralStoreCodec.encode(record), expected: nil, kind: .intent)
                return try finish(context, record: record, epoch: attemptEpoch)
            }
            try syncExisting(context.operations, recordName, expected: intent); try sync(context.operations)
            if try StructuralStoreCodec.record(intent.bytes) != record {
                try replace(context, parent: context.operations, name: recordName, bytes: StructuralStoreCodec.encode(record), expected: intent, kind: .intent)
            }
            return try finish(context, record: record, epoch: attemptEpoch)
    }
    /// Exact live-receipt command only. A command token is gate-file constructed and never exposed
    /// through the read scope. Neither token possession nor diagnostic bytes establish qualification.
    struct QualifiedCurrentCapture {
        let envelopeBytes: Data
        let operationID: UUID
        fileprivate init(_ bytes: Data, operationID: UUID) { envelopeBytes = bytes; self.operationID = operationID }
    }
    private struct ExactCommand { let record: DeviceStructuralOperationRecord }
    func performExactAttempt(_ supplied: DeviceStructuralOperationRecord,
                             commandPermit: DeviceLocalStructuralCommandPermit) throws -> QualifiedCurrentCapture {
        guard supplied.candidate.count <= StructuralStoreCodec.envelopeLimit,
              (supplied.expectedOld?.count ?? 0) <= StructuralStoreCodec.envelopeLimit,
              supplied.resourceAssertions.count <= 8192 else { throw DeviceStructuralStoreError.invalidRecord }
        let record = try StructuralStoreCodec.record(StructuralStoreCodec.encode(supplied))
        guard record.rootID == rootID, record.phase == .unresolved,
              record.baselineIdentity == nil, record.candidateIdentity == nil else { throw DeviceStructuralStoreError.invalidRecord }
        try commandPermit.begin(ObjectIdentifier(self)); defer { commandPermit.end() }
        guard let context = borrowedResourceContext else { throw DeviceLocalResourceGateFailure.invalidScope }
        try check(context)
        do {
            let state = try inventory(context)
            let needsPrepare: Bool
            if let retained = state.records.first(where: { $0.operationID == record.operationID }) {
                guard retained.sameIntent(as: record) else { throw DeviceStructuralStoreError.conflict }
                needsPrepare = false
                // Terminal replay must be the actual tip, with no newer pending attempt. The generic
                // store's older receipt behavior is deliberately not sufficient for this coordinator.
                if retained.phase == .terminal {
                    guard state.records.allSatisfy({ $0.phase == .terminal }),
                          state.current?.bytes == retained.candidate,
                          state.current?.identity == retained.candidateIdentity else { throw DeviceStructuralStoreError.conflict }
                }
            } else {
                try requireQualifiedBaseline(context,state:state,expectedOld:record.expectedOld)
                needsPrepare = true
            }
            let command = ExactCommand(record:record) // Private, exact, constructed only AFTER checks.
            if needsPrepare { try prepareChecked(context,record:command.record) }
            _ = try recommitChecked(context,operationID:command.record.operationID)
            let final = try inventory(context)
            try requireQualifiedBaseline(context,state:final,expectedOld:command.record.candidate)
            guard final.records.allSatisfy({ $0.phase == .terminal }),
                  let terminal = final.records.first(where:{$0.operationID == command.record.operationID}),
                  terminal.phase == .terminal, terminal.sameIntent(as:command.record),
                  let current = final.current, current.bytes == command.record.candidate else { throw DeviceStructuralStoreError.conflict }
            try check(context)
            return QualifiedCurrentCapture(current.bytes,operationID:command.record.operationID)
        } catch { try check(context); throw error }
    }
    private func requireQualifiedBaseline(_ context: Context,
        state: (records: [DeviceStructuralOperationRecord], current: Node?), expectedOld: Data?) throws {
        guard state.current?.bytes == expectedOld,
              state.records.allSatisfy({$0.phase == .terminal}) else { throw DeviceStructuralStoreError.conflict }
        if let current = state.current {
            guard let qualified = qualification, qualified.epoch == epoch(), qualified.current == current,
                  let tip = state.records.first(where:{$0.phase == .terminal && $0.candidate == current.bytes}),
                  try readFile(context.operations,filename(tip.operationID),limit:StructuralStoreCodec.operationLimit) == qualified.proof else { throw DeviceStructuralStoreError.outcomeUncertain }
        } else {
            guard state.records.isEmpty, bindingQualified else { throw DeviceStructuralStoreError.outcomeUncertain }
        }
    }
    private func finish(_ context: Context, record initial: DeviceStructuralOperationRecord, epoch attemptEpoch: UInt64) throws -> Receipt {
        var record = initial
        let recordName = filename(record.operationID)
        if record.phase == .unresolved {
            let temporary = envelopeName + ".pending"
            var fd = openat(context.root, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_NONBLOCK, 0o600)
            // This scope owns either successful open, including a retry, before any throwing check/write.
            defer { if fd >= 0 { close(fd) } }
            if fd < 0 && errno == EEXIST {
                guard let retained = stagedIdentities[record.operationID],
                      let existing = try readFile(context.root, temporary, limit: StructuralStoreCodec.envelopeLimit),
                      existing.identity == retained, existing.bytes == record.candidate else { throw DeviceStructuralStoreError.conflict }
                fd = openat(context.root, temporary, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            } else {
                guard fd >= 0 else { throw failure() }
                try stagingIdentityProbe(fd, .candidateCreated)
                stagedIdentities[record.operationID] = try identity(fd, directory: false)
                try writeAll(fd, record.candidate)
            }
            guard fd >= 0 else { throw failure() }
            let candidateIdentity = try identity(fd, directory: false)
            try boundary(.afterWrite(.envelope)); try sync(fd); try boundary(.afterFileSync(.envelope)); try check(context)
            guard let staged = try readFile(context.root, temporary, limit: StructuralStoreCodec.envelopeLimit),
                  staged.identity == candidateIdentity, staged.bytes == record.candidate,
                  let prior = try readFile(context.operations, recordName, limit: StructuralStoreCodec.operationLimit) else { throw DeviceStructuralStoreError.conflict }
            record = record.binding(baseline: record.baselineIdentity, candidate: candidateIdentity)
            try replace(context, parent: context.operations, name: recordName, bytes: StructuralStoreCodec.encode(record), expected: prior, kind: .intent)
        }
        let state = try inventory(context)
        if state.current?.identity == record.candidateIdentity {
            guard let current = state.current else { throw DeviceStructuralStoreError.conflict }
            try syncExisting(context.root, envelopeName, expected: current); try boundary(.afterFileSync(.envelope)); try sync(context.root)
        } else {
            try installCandidate(context, record: record, expected: state.current)
        }
        guard let pending = try readFile(context.operations, recordName, limit: StructuralStoreCodec.operationLimit) else { throw DeviceStructuralStoreError.conflict }
        let terminal = record.terminal
        try replace(context, parent: context.operations, name: recordName, bytes: StructuralStoreCodec.encode(terminal), expected: pending, kind: .terminal)
        let final = try inventory(context)
        guard let current = final.current, let proof = try readFile(context.operations, recordName, limit: StructuralStoreCodec.operationLimit) else { throw DeviceStructuralStoreError.conflict }
        qualification = (attemptEpoch, current, proof)
        stagedIdentities.removeValue(forKey: record.operationID)
        return Receipt(record: terminal)
    }
    private func installCandidate(_ context: Context, record: DeviceStructuralOperationRecord, expected: Node?) throws {
        let temporary = envelopeName + ".pending"
        guard let staged = try readFile(context.root, temporary, limit: StructuralStoreCodec.envelopeLimit),
              staged.identity == record.candidateIdentity, staged.bytes == record.candidate else { throw DeviceStructuralStoreError.conflict }
        try syncExisting(context.root, temporary, expected: staged)
        try boundary(.beforeReplace(.envelope)); try check(context)
        guard try readFile(context.root, envelopeName, limit: StructuralStoreCodec.envelopeLimit) == expected,
              try readFile(context.root, temporary, limit: StructuralStoreCodec.envelopeLimit) == staged else { throw DeviceStructuralStoreError.conflict }
        guard renameat(context.root, temporary, context.root, envelopeName) == 0 else { throw failure() }
        try boundary(.afterReplace(.envelope)); try sync(context.root); try boundary(.afterDirectorySync(.envelope))
        guard try readFile(context.root, envelopeName, limit: StructuralStoreCodec.envelopeLimit) == staged else { throw DeviceStructuralStoreError.conflict }
        try check(context)
    }
    private func writeAll(_ fd: Int32, _ bytes: Data) throws {
        try bytes.withUnsafeBytes { data in
            var offset = 0
            while offset < data.count {
                let count = write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw failure() }
                guard count > 0 else { throw failure() }; offset += count
            }
        }
    }

    private func filename(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }
    private func inventory(_ context: Context) throws -> (records: [DeviceStructuralOperationRecord], current: Node?) {
        try check(context)
        let files = try names(context.operations)
        // Staging records are retained and strictly checked too; a partial/corrupt staging file blocks.
        var finals: [UUID: DeviceStructuralOperationRecord] = [:]
        var staged: [UUID: DeviceStructuralOperationRecord] = [:]
        for name in files {
            let pending = name.hasSuffix(".json.pending")
            let base = pending ? String(name.dropLast(8)) : name
            guard base.hasSuffix(".json"), let id = UUID(uuidString: String(base.dropLast(5))), filename(id) == base,
                  let node = try readFile(context.operations, name, limit: StructuralStoreCodec.operationLimit) else { throw DeviceStructuralStoreError.conflict }
            let record = try StructuralStoreCodec.record(node.bytes)
            guard record.rootID == rootID, record.operationID == id else { throw DeviceStructuralStoreError.conflict }
            if pending { staged[id] = record } else { finals[id] = record }
        }
        for (id, record) in staged {
            if let final = finals[id] {
                guard final.sameIntent(as: record), final.baselineIdentity == record.baselineIdentity else { throw DeviceStructuralStoreError.conflict }
                if final.phase == .unresolved && record.phase == .prepared { finals[id] = record }
                else { guard final.candidateIdentity == record.candidateIdentity else { throw DeviceStructuralStoreError.conflict } }
            }
            else { guard record.phase != .terminal else { throw DeviceStructuralStoreError.conflict }; finals[id] = record }
        }
        let records = Array(finals.values)
        guard records.count <= 129 else { throw DeviceStructuralStoreError.capacity }
        guard records.filter({ $0.phase != .terminal }).count <= 1,
              records.filter({ $0.phase == .terminal }).count <= 128 else { throw DeviceStructuralStoreError.capacity }
        let current = try readFile(context.root, envelopeName, limit: StructuralStoreCodec.envelopeLimit)
        if let current { _ = try StructuralStoreCodec.envelope(current.bytes) }
        var remainder = records.filter { $0.phase == .terminal }
        var tip: Data? = nil
        var tipIdentity: Identity? = nil
        var generations = Set<UUID>()
        while !remainder.isEmpty {
            let successors = remainder.filter { $0.expectedOld == tip }
            guard successors.count == 1 else { throw DeviceStructuralStoreError.conflict }
            let next = successors[0]
            guard next.baselineIdentity == tipIdentity, let installed = next.candidateIdentity else { throw DeviceStructuralStoreError.conflict }
            let generation = try StructuralStoreCodec.envelope(next.candidate).snapshot.generationID
            guard generations.insert(generation).inserted else { throw DeviceStructuralStoreError.conflict }
            tip = next.candidate; tipIdentity = installed
            remainder.removeAll { $0.operationID == next.operationID }
        }
        if let pending = records.first(where: { $0.phase != .terminal }) {
            guard !generations.contains(try StructuralStoreCodec.envelope(pending.candidate).snapshot.generationID),
                  pending.expectedOld == tip, pending.baselineIdentity == tipIdentity,
                  (current?.bytes == tip && current?.identity == tipIdentity) || (pending.candidateIdentity != nil && current?.bytes == pending.candidate && current?.identity == pending.candidateIdentity) else { throw DeviceStructuralStoreError.conflict }
        } else { guard current?.bytes == tip, current?.identity == tipIdentity else { throw DeviceStructuralStoreError.conflict } }
        try check(context)
        return (records, current)
    }

    private var borrowedResourceContext: Context?
    var resourceGateDescriptor: DeviceLocalResourceDescriptor { get throws { try .existing(instance:ObjectIdentifier(self),path:root.path,rootID:rootID) } }
    func withResourceGateScope(_ permit: DeviceLocalResourcePermit, _ body: () throws -> Void) throws {
        try permit.beginAcquisition(resourceGateDescriptor)
        mutex.lock(); defer { permit.invalidate(); mutex.unlock() }
        try diskContext(create:false,releasePermit:permit) { context in
            borrowedResourceContext = context
            defer { borrowedResourceContext = nil; permit.invalidate() }
            try body()
            try check(context)
        }
    }
    private func disk<T>(create: Bool = false, resourcePermit: DeviceLocalResourcePermit? = nil,
                         _ operation: (Context) throws -> T) throws -> T {
        if let permit = resourcePermit {
            guard !create else { throw DeviceLocalResourceGateFailure.invalidScope }
            try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
            guard let context = borrowedResourceContext else { throw DeviceLocalResourceGateFailure.invalidScope }
            try check(context)
            do { let result = try operation(context); try check(context); return result }
            catch { try check(context); throw error }
        }
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try diskContext(create:create,operation)
    }
    private func diskContext<T>(create: Bool, releasePermit: DeviceLocalResourcePermit? = nil, _ operation: (Context) throws -> T) throws -> T {
        guard root.path.utf8.count <= 4096, root.resolvingSymlinksInPath().path == root.path else { throw DeviceStructuralStoreError.unsafeBinding }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard rootFD >= 0 else { throw failure() }; defer { close(rootFD) }
        let rootIdentity = try identity(rootFD, directory: true)
        let lockFD = openat(rootFD, "structural.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | (create ? O_CREAT : 0), 0o600)
        guard lockFD >= 0 else { throw failure() }; defer { close(lockFD) }
        let lockIdentity = try identity(lockFD, directory: false)
        guard flock(lockFD, LOCK_EX) == 0 else { throw failure() }; defer { releasePermit?.invalidate(); flock(lockFD, LOCK_UN) }
        if create {
            if mkdirat(rootFD, "operations", 0o700) != 0 && errno != EEXIST { throw failure() }
            try sync(lockFD); try sync(rootFD)
        }
        let operationsFD = openat(rootFD, "operations", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard operationsFD >= 0 else { throw failure() }; defer { close(operationsFD) }
        let binding = Binding(schemaVersion: 1, rootID: rootID, canonicalPath: root.path,
                              directory: rootIdentity, lock: lockIdentity, operations: try identity(operationsFD, directory: true))
        let context = Context(root: rootFD, lock: lockFD, operations: operationsFD, binding: binding, requiresBinding: !create)
        if !create {
            guard let persisted = try readFile(rootFD, "root-binding.json", limit: 8192), try decodeBinding(persisted.bytes) == binding else { throw DeviceStructuralStoreError.unsafeBinding }
        }
        try check(context)
        return try operation(context)
    }
    private func decodeBinding(_ bytes: Data) throws -> Binding {
        let object = try StructuralStoreCodec.object(bytes, limit: 8192)
        try StructuralStoreCodec.keys(object, required: ["schemaVersion","rootID","canonicalPath","directory","lock","operations"])
        for name in ["directory","lock","operations"] {
            guard let identity = object[name] as? [String: Any] else { throw DeviceStructuralStoreError.invalidRecord }
            try StructuralStoreCodec.keys(identity, required: ["device","inode"])
        }
        let binding = try JSONDecoder().decode(Binding.self, from: bytes)
        guard binding.schemaVersion == 1 else { throw DeviceStructuralStoreError.invalidRecord }
        return binding
    }
    private func identity(_ fd: Int32, directory: Bool) throws -> Identity {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw failure() }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw DeviceStructuralStoreError.unsafeBinding }
        return Identity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }
    private func check(_ context: Context) throws {
        guard root.resolvingSymlinksInPath().path == root.path else { throw DeviceStructuralStoreError.unsafeBinding }
        var info = stat(); guard lstat(root.path, &info) == 0, Identity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino)) == context.binding.directory,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw DeviceStructuralStoreError.unsafeBinding }
        guard try identity(context.root, directory: true) == context.binding.directory,
              try identity(context.lock, directory: false) == context.binding.lock,
              try identity(context.operations, directory: true) == context.binding.operations else { throw DeviceStructuralStoreError.unsafeBinding }
        for (name, expected, directory) in [("structural.lock",context.binding.lock,false),("operations",context.binding.operations,true)] {
            let fd = openat(context.root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw failure() }; defer { close(fd) }
            guard try identity(fd, directory: directory) == expected else { throw DeviceStructuralStoreError.unsafeBinding }
        }
        let persistedBinding = try readFile(context.root, "root-binding.json", limit: 8192)
        if context.requiresBinding && persistedBinding == nil { throw DeviceStructuralStoreError.unsafeBinding }
        if let persisted = persistedBinding {
            guard try decodeBinding(persisted.bytes) == context.binding else { throw DeviceStructuralStoreError.unsafeBinding }
        }
    }
    private func names(_ fd: Int32) throws -> [String] {
        let duplicate = dup(fd); guard duplicate >= 0 else { throw failure() }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw failure() }; defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw failure() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name); guard names.count <= 260 else { throw DeviceStructuralStoreError.capacity }
        }
        return names
    }
    private func readFile(_ parent: Int32, _ name: String, limit: Int) throws -> Node? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw failure() }; defer { close(fd) }
        let fileIdentity = try identity(fd, directory: false)
        var info = stat(); guard fstat(fd, &info) == 0 else { throw failure() }
        guard info.st_size >= 0, info.st_size <= limit else { throw DeviceStructuralStoreError.tooLarge }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let amount = read(fd, &buffer, buffer.count)
            if amount < 0 { if errno == EINTR { continue }; throw failure() }
            if amount == 0 { break }
            guard bytes.count + amount <= limit else { throw DeviceStructuralStoreError.tooLarge }
            bytes.append(contentsOf: buffer.prefix(amount))
        }
        guard try identity(fd, directory: false) == fileIdentity, bytes.count == info.st_size else { throw DeviceStructuralStoreError.conflict }
        return Node(identity: fileIdentity, bytes: bytes)
    }
    private func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw failure() } }
    private func syncExisting(_ parent: Int32, _ name: String, expected: Node) throws {
        guard try readFile(parent, name, limit: StructuralStoreCodec.operationLimit) == expected else { throw DeviceStructuralStoreError.conflict }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        guard try identity(fd, directory: false) == expected.identity else { throw DeviceStructuralStoreError.conflict }
        try sync(fd)
        guard try readFile(parent, name, limit: StructuralStoreCodec.operationLimit) == expected else { throw DeviceStructuralStoreError.conflict }
    }
    private func replace(_ context: Context, parent: Int32, name: String, bytes: Data, expected: Node?, kind: Kind) throws {
        let temporary = name + ".pending"
        var fd = openat(parent, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_NONBLOCK, 0o600)
        // Own the initial or retry descriptor before identity checks and writes can throw.
        defer { if fd >= 0 { close(fd) } }
        if fd < 0 && errno == EEXIST {
            guard let previous = try readFile(parent, temporary, limit: StructuralStoreCodec.operationLimit), previous.bytes == bytes else { throw DeviceStructuralStoreError.conflict }
            fd = openat(parent, temporary, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw DeviceStructuralStoreError.conflict }
            try stagingIdentityProbe(fd, .replacementRetried(kind))
            guard try identity(fd, directory: false) == previous.identity else { throw DeviceStructuralStoreError.conflict }
        } else {
            guard fd >= 0 else { throw failure() }
            try bytes.withUnsafeBytes { data in
                var offset = 0
                while offset < data.count {
                    let count = write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
                    if count < 0 { if errno == EINTR { continue }; throw failure() }
                    guard count > 0 else { throw failure() }; offset += count
                }
            }
        }
        let temporaryIdentity = try identity(fd, directory: false)
        do {
            try boundary(.afterWrite(kind)); try check(context)
            try sync(fd); try boundary(.afterFileSync(kind)); try check(context)
            try boundary(.beforeReplace(kind)); try check(context)
            guard try readFile(parent, name, limit: StructuralStoreCodec.operationLimit) == expected,
                  let staged = try readFile(parent, temporary, limit: StructuralStoreCodec.operationLimit),
                  staged.identity == temporaryIdentity, staged.bytes == bytes else { throw DeviceStructuralStoreError.conflict }
            guard renameat(parent, temporary, parent, name) == 0 else { throw failure() }
            try boundary(.afterReplace(kind)); try check(context)
            guard let installed = try readFile(parent, name, limit: StructuralStoreCodec.operationLimit), installed.identity == temporaryIdentity, installed.bytes == bytes else { throw DeviceStructuralStoreError.conflict }
            try sync(parent); try boundary(.afterDirectorySync(kind)); try check(context)
            guard let final = try readFile(parent, name, limit: StructuralStoreCodec.operationLimit), final.identity == temporaryIdentity, final.bytes == bytes else { throw DeviceStructuralStoreError.conflict }
        } catch let error as DeviceStructuralStoreError {
            if error == .unsafeBinding || error == .conflict { throw error }
            throw DeviceStructuralStoreError.outcomeUncertain
        } catch { throw DeviceStructuralStoreError.outcomeUncertain }
    }
    private func failure() -> DeviceStructuralStoreError { .io(errno) }
}
