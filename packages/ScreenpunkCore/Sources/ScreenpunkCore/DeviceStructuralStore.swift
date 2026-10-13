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
    enum Kind: Equatable { case binding, intent, envelope, terminal, nativeCommandIntent, nativeCommandBinding, nativeCommandCurrent, nativeCommandTerminal, nativeGenesisIntent, nativeGenesisBinding, nativeGenesis, nativeGenesisConfirmation }
    enum Boundary: Equatable { case afterCreate(Kind), afterWrite(Kind), afterFileSync(Kind), beforeReplace(Kind), afterReplace(Kind), afterDirectorySync(Kind), beforeNativeCommandScopeExit }
    enum StagingIdentitySite: Equatable { case candidateCreated, replacementRetried(Kind) }
    enum Recovery: Equatable {
        case terminalNeedsDurability(DeviceStructuralOperationRecord)
        case oldObserved(DeviceStructuralOperationRecord)
        case candidateNeedsDurability(DeviceStructuralOperationRecord)
    }
    struct Receipt: Equatable { let record: DeviceStructuralOperationRecord }
    fileprivate typealias Identity = StructuralStoreIdentity
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
        let envelopeBytes:Data
        let operationID:UUID
        fileprivate let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64
        fileprivate let currentIdentity:StructuralStoreIdentity,proofIdentity:StructuralStoreIdentity,bindingIdentity:StructuralStoreIdentity
        fileprivate let proofBytes:Data,bindingBytes:Data
        fileprivate init(_ bytes:Data,operationID:UUID,issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,
                         currentIdentity:StructuralStoreIdentity,proofIdentity:StructuralStoreIdentity,proofBytes:Data,
                         bindingIdentity:StructuralStoreIdentity,bindingBytes:Data) {
            envelopeBytes=bytes;self.operationID=operationID;self.issuer=issuer;self.rootID=rootID;self.epoch=epoch
            self.currentIdentity=currentIdentity;self.proofIdentity=proofIdentity;self.proofBytes=proofBytes
            self.bindingIdentity=bindingIdentity;self.bindingBytes=bindingBytes
        }
    }
    /// Verify the ORIGINAL final-lock capture. Diagnostic reads/current qualification cannot renew it.
    func verifyQualifiedCurrentCapture(_ original:QualifiedCurrentCapture,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit) { context in
            guard original.issuer == ObjectIdentifier(self),original.rootID == rootID,original.epoch == epoch() else { throw DeviceStructuralStoreError.conflict }
            let state=try inventory(context)
            try requireQualifiedBaseline(context,state:state,expectedOld:original.envelopeBytes)
            guard state.current == Node(identity:original.currentIdentity,bytes:original.envelopeBytes),
                  let proof=try readFile(context.operations,filename(original.operationID),limit:StructuralStoreCodec.operationLimit),
                  proof == Node(identity:original.proofIdentity,bytes:original.proofBytes),
                  let binding=try readFile(context.root,"root-binding.json",limit:8192),
                  binding == Node(identity:original.bindingIdentity,bytes:original.bindingBytes),
                  original.epoch == epoch() else { throw DeviceStructuralStoreError.conflict }
        }
    }
    /// Diagnostic only: original-lock capture, never durability acknowledgment or approval.
    /// File-private construction prevents caller-supplied bytes from manufacturing a checkpoint.
    final class TerminalDiscovery {
        let record:DeviceStructuralOperationRecord
        fileprivate let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64
        fileprivate let currentIdentity:StructuralStoreIdentity,proofIdentity:StructuralStoreIdentity,bindingIdentity:StructuralStoreIdentity
        fileprivate let currentBytes:Data,proofBytes:Data,bindingBytes:Data
        fileprivate init(_ issuer:ObjectIdentifier,_ rootID:UUID,_ epoch:UInt64,_ record:DeviceStructuralOperationRecord,
                         currentIdentity:StructuralStoreIdentity,currentBytes:Data,proofIdentity:StructuralStoreIdentity,proofBytes:Data,bindingIdentity:StructuralStoreIdentity,bindingBytes:Data) {
            self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;self.record=record
            self.currentIdentity=currentIdentity;self.currentBytes=currentBytes;self.proofIdentity=proofIdentity;self.proofBytes=proofBytes
            self.bindingIdentity=bindingIdentity;self.bindingBytes=bindingBytes
        }
    }
    func inspectLatestTerminalExact(resourcePermit:DeviceLocalResourcePermit)throws->TerminalDiscovery {
        try disk(resourcePermit:resourcePermit) { context in
            let before=epoch(),nodes=try terminalNodes(context)
            guard epoch() == before else { throw DeviceStructuralStoreError.conflict }
            return TerminalDiscovery(ObjectIdentifier(self),rootID,before,nodes.record,currentIdentity:nodes.current.identity,currentBytes:nodes.current.bytes,proofIdentity:nodes.proof.identity,proofBytes:nodes.proof.bytes,bindingIdentity:nodes.binding.identity,bindingBytes:nodes.binding.bytes)
        }
    }
    func verifyTerminalDiscovery(_ original:TerminalDiscovery,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit) { context in
            guard original.issuer == ObjectIdentifier(self),original.rootID == rootID,original.epoch == epoch() else { throw DeviceStructuralStoreError.conflict }
            let nodes=try terminalNodes(context)
            guard nodes.record == original.record,
                  nodes.current == Node(identity:original.currentIdentity,bytes:original.currentBytes),
                  nodes.proof == Node(identity:original.proofIdentity,bytes:original.proofBytes),
                  nodes.binding == Node(identity:original.bindingIdentity,bytes:original.bindingBytes),
                  original.epoch == epoch() else { throw DeviceStructuralStoreError.conflict }
        }
    }
    private func terminalNodes(_ context:Context)throws->(record:DeviceStructuralOperationRecord,current:Node,proof:Node,binding:Node) {
        // Terminal restoration cannot adopt initial empty state, staging remnants or unknown nodes.
        let allowed:Set<String>=["structural.lock","operations","root-binding.json",envelopeName]
        guard Set(try names(context.root)) == allowed,
              !(try names(context.operations)).contains(where:{$0.hasSuffix(".pending")}) else { throw DeviceStructuralStoreError.conflict }
        let state=try inventory(context)
        guard state.records.allSatisfy({$0.phase == .terminal}),let current=state.current,
              let tip=state.records.first(where:{$0.candidate == current.bytes && $0.candidateIdentity == current.identity}),
              let proof=try readFile(context.operations,filename(tip.operationID),limit:StructuralStoreCodec.operationLimit),
              try StructuralStoreCodec.record(proof.bytes) == tip,
              let binding=try readFile(context.root,"root-binding.json",limit:8192) else { throw DeviceStructuralStoreError.conflict }
        try check(context);return(tip,current,proof,binding)
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
        try requireNoNativeGenesis(context.root)
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
            guard let proof=try readFile(context.operations,filename(command.record.operationID),limit:StructuralStoreCodec.operationLimit),
                  let binding=try readFile(context.root,"root-binding.json",limit:8192),
                  let qualified=qualification,qualified.epoch == epoch(),qualified.current == current,qualified.proof == proof else { throw DeviceStructuralStoreError.outcomeUncertain }
            return QualifiedCurrentCapture(current.bytes,operationID:command.record.operationID,issuer:ObjectIdentifier(self),rootID:rootID,epoch:qualified.epoch,
                currentIdentity:current.identity,proofIdentity:proof.identity,proofBytes:proof.bytes,bindingIdentity:binding.identity,bindingBytes:binding.bytes)
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
        try requireNoNativeGenesis(context.root)
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


    // Native initialization is explicit, unmounted and not a delivery or Cloud authority ACK.
    private static let nativeGenesisNames:Set<String>=["native-genesis.intent","native-genesis.binding","native-genesis.json","native-genesis.confirm"]
    private struct NativeGenesisIntent:Codable {let schemaVersion:Int,rootID:UUID;let selfID:Identity,binding:NativeNode;let stateBytes:Data}
    private struct NativeGenesisBinding:Codable {let schemaVersion:Int,selfID:Identity;let intent:NativeNode;let stateID:Identity,confirmationID:Identity}
    private struct NativeGenesisConfirmation:Codable {let schemaVersion:Int,selfID:Identity;let binding:NativeNode;let stateID:Identity,stateDigest:String}
    fileprivate struct NativeNode:Codable,Equatable {let identity:Identity;let bytes:Data}
    private var nativeGenesisInput:Data?,nativeGenesisLive:[String:Identity]=[:]
    private var nativeGenesisQualified:NativeGenesisCheckpoint?
    final class NativeGenesisCheckpoint {
        let rootID:UUID,state:DeviceNativeStructuralState,stateBytes:Data
        fileprivate let issuer:ObjectIdentifier,epoch:UInt64,nodes:[String:NativeNode]
        fileprivate init(_ issuer:ObjectIdentifier,_ rootID:UUID,_ epoch:UInt64,_ state:DeviceNativeStructuralState,_ bytes:Data,_ nodes:[String:NativeNode]) {
            self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;self.state=state;stateBytes=bytes;self.nodes=nodes
        }
    }
    private func requireNoNativeGenesis(_ fd:Int32)throws {
        guard !(try names(fd)).contains(where:{Self.nativeGenesisNames.contains($0) || $0.hasSuffix(".stage") && Self.nativeGenesisNames.contains(String($0.dropLast(6)))}) else{throw DeviceStructuralStoreError.conflict}
    }
    private func nativeGenesisInventory(_ c:Context)throws->[String:NativeNode] {
        let base:Set<String>=["structural.lock","operations","root-binding.json"]
        let allowed=base.union(Self.nativeGenesisNames).union(Self.nativeGenesisNames.map{$0+".stage"}).union(nativeCommandScopeActive ? ["native-current.json", "native-current.json.stage"] : [])
        let operationsAllowed = nativeCommandScopeActive ? true : try names(c.operations).isEmpty
        guard Set(try names(c.root)).isSubset(of:allowed),operationsAllowed else{throw DeviceStructuralStoreError.conflict}
        var result:[String:NativeNode]=[:]
        for name in Self.nativeGenesisNames {
            let final=try readFile(c.root,name,limit:name == "native-genesis.confirm" ? 32768:16384)
            let staged=try readFile(c.root,name+".stage",limit:name == "native-genesis.confirm" ? 32768:16384)
            guard final == nil || staged == nil else{throw DeviceStructuralStoreError.conflict}
            if let n=final ?? staged {result[name] = .init(identity:n.identity,bytes:n.bytes)}
        }
        for (name,id) in nativeGenesisLive {guard result[String(name.dropLast(6))]?.identity == id else{throw DeviceStructuralStoreError.conflict}}
        return result
    }
    private func nativeGenesisEncode<T:Encodable>(_ value:T,limit:Int=16384)throws->Data {try DeviceLocalCompleteSetBounds.encode(value,maximum:limit)}
    private func nativeGenesisDecode<T:Decodable>(_ type:T.Type,_ bytes:Data,fields:Set<String>,limit:Int=16384)throws->T where T:Encodable {
        let o=try StructuralStoreCodec.object(bytes,limit:limit);try StructuralStoreCodec.keys(o,required:fields)
        for key in ["selfID","stateID","confirmationID"] where o[key] != nil {
            guard let id=o[key] as? [String:Any] else{throw DeviceStructuralStoreError.invalidRecord};try StructuralStoreCodec.keys(id,required:["device","inode"])
        }
        for key in ["intent","binding"] where o[key] != nil {
            guard let node=o[key] as? [String:Any],let id=node["identity"] as? [String:Any] else{throw DeviceStructuralStoreError.invalidRecord}
            try StructuralStoreCodec.keys(node,required:["identity","bytes"]);try StructuralStoreCodec.keys(id,required:["device","inode"])
        }
        let value=try JSONDecoder().decode(type,from:bytes)
        guard try nativeGenesisEncode(value,limit:limit) == bytes else{throw DeviceStructuralStoreError.invalidRecord};return value
    }
    private func nativeAllocate(_ c:Context,_ name:String,_ kind:Kind)throws->Identity {
        if let n=try readFile(c.root,name+".stage",limit:32768) {guard nativeGenesisLive[name+".stage"] == n.identity else{throw DeviceStructuralStoreError.conflict};return n.identity}
        guard try readFile(c.root,name,limit:32768) == nil else{throw DeviceStructuralStoreError.conflict}
        let fd=openat(c.root,name+".stage",O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_NONBLOCK,0o600)
        guard fd >= 0 else{throw failure()};defer{close(fd)}
        let id=try identity(fd,directory:false);nativeGenesisLive[name+".stage"]=id;try boundary(.afterCreate(kind));return id
    }
    private func nativeFill(_ c:Context,_ name:String,_ node:NativeNode,_ kind:Kind)throws {
        let fd=openat(c.root,name+".stage",O_RDWR|O_NOFOLLOW|O_NONBLOCK);guard fd >= 0 else{throw failure()};defer{close(fd)}
        guard try identity(fd,directory:false) == node.identity,ftruncate(fd,0) == 0 else{throw DeviceStructuralStoreError.conflict}
        try node.bytes.withUnsafeBytes {b in var offset=0;while offset < b.count {let n=write(fd,b.baseAddress!.advanced(by:offset),b.count-offset);if n < 0 && errno == EINTR{continue};guard n > 0 else{throw failure()};offset+=n}}
        try boundary(.afterWrite(kind));try sync(fd);try boundary(.afterFileSync(kind))
        guard try readFile(c.root,name+".stage",limit:32768) == Node(identity:node.identity,bytes:node.bytes) else{throw DeviceStructuralStoreError.conflict}
    }
    private func nativePromote(_ c:Context,_ name:String,_ node:NativeNode,_ kind:Kind)throws {
        if let existing=try readFile(c.root,name,limit:32768) {
            guard existing == Node(identity:node.identity,bytes:node.bytes),try readFile(c.root,name+".stage",limit:32768) == nil else{throw DeviceStructuralStoreError.conflict}
            try syncExisting(c.root,name,expected:existing);try boundary(.afterFileSync(kind))
        } else {
            let expected=Node(identity:node.identity,bytes:node.bytes)
            guard try readFile(c.root,name+".stage",limit:32768) == expected else{throw DeviceStructuralStoreError.conflict}
            try syncExisting(c.root,name+".stage",expected:expected);try boundary(.afterFileSync(kind));try boundary(.beforeReplace(kind));try check(c)
            guard renameat(c.root,name+".stage",c.root,name) == 0 else{throw failure()};try boundary(.afterReplace(kind))
        }
        try sync(c.root);try boundary(.afterDirectorySync(kind));try check(c)
    }
    private func checkedNativeGenesis(_ c:Context)throws->(DeviceNativeStructuralState,[String:NativeNode]) {
        let nodes=try nativeGenesisInventory(c)
        guard let intent=nodes["native-genesis.intent"],let binding=nodes["native-genesis.binding"],let state=nodes["native-genesis.json"],let proof=nodes["native-genesis.confirm"],
              let rootBinding=try readFile(c.root,"root-binding.json",limit:8192) else{throw DeviceStructuralStoreError.conflict}
        let i=try nativeGenesisDecode(NativeGenesisIntent.self,intent.bytes,fields:["schemaVersion","rootID","selfID","binding","stateBytes"])
        let b=try nativeGenesisDecode(NativeGenesisBinding.self,binding.bytes,fields:["schemaVersion","selfID","intent","stateID","confirmationID"])
        let f=try nativeGenesisDecode(NativeGenesisConfirmation.self,proof.bytes,fields:["schemaVersion","selfID","binding","stateID","stateDigest"],limit:32768)
        let parsed=try DeviceNativeStructuralStateCodec.decode(state.bytes)
        guard i.schemaVersion == 1,b.schemaVersion == 1,f.schemaVersion == 1,i.rootID == rootID,i.selfID == intent.identity,
              i.binding == NativeNode(identity:rootBinding.identity,bytes:rootBinding.bytes),b.selfID == binding.identity,b.intent == intent,b.stateID == state.identity,b.confirmationID == proof.identity,
              f.selfID == proof.identity,f.binding == binding,f.stateID == state.identity,try DeviceNativeDeliveryAttachmentCodec.hash(state.bytes).utf8.elementsEqual(f.stateDigest.utf8),
              state.bytes == i.stateBytes,parsed.entries.isEmpty,parsed.configuredEntryID == nil,try DeviceNativeStructuralStateCodec.encode(parsed) == state.bytes else{throw DeviceStructuralStoreError.conflict}
        var original=nodes;original["root-binding.json"]=i.binding;return(parsed,original)
    }
    /// Requalifies the exact recorded genesis after process restart. Existing command
    /// history is retained and checked reciprocally; this does not acknowledge its
    /// current content or grants and never converts a partial record into completion.
    func restoreNativeGenesisExplicit() throws -> NativeGenesisCheckpoint {
        let restored = try disk(allowNative: true) { c -> (NativeGenesisCheckpoint, UUID?) in
            nativeCommandScopeActive = true
            defer { nativeCommandScopeActive = false }
            let original = try checkedNativeGenesis(c)
            let files = try names(c.operations)
            var operation: UUID?
            if !files.isEmpty {
                let methods = files.filter { $0.hasSuffix(".native-intent.json") || $0.hasSuffix(".native-intent.json.stage") }
                guard methods.count == 1,
                      let name = methods.first,
                      let id = UUID(uuidString: String(name.prefix(36))) else { throw DeviceStructuralStoreError.conflict }
                let dispatch = try nativeDispatchPreflight(c, operation: id, candidate: nil, assertions: nil)
                guard dispatch.method != nil else { throw DeviceStructuralStoreError.outcomeUncertain }
                operation = id
            } else {
                guard try readFile(c.root, "native-current.json", limit: 131072) == nil,
                      try readFile(c.root, "native-current.json.stage", limit: 131072) == nil else { throw DeviceStructuralStoreError.conflict }
            }
            let now = epoch(invalidate: true)
            nativeGenesisQualified = nil; nativeCommandPending = nil; nativeCommandQualified = nil
            for (name, node) in original.1 {
                try syncExisting(c.root, name, expected: .init(identity: node.identity, bytes: node.bytes))
            }
            try sync(c.lock); try sync(c.operations); try sync(c.root); try check(c)
            let final = try checkedNativeGenesis(c)
            guard final.0 == original.0, final.1 == original.1, epoch() == now else { throw DeviceStructuralStoreError.conflict }
            if let operation { _ = try nativeDispatchPreflight(c, operation: operation, candidate: nil, assertions: nil) }
            return (NativeGenesisCheckpoint(ObjectIdentifier(self), rootID, now, final.0,
                try DeviceNativeStructuralStateCodec.encode(final.0), final.1), operation)
        }
        try DeviceLocalResourceRegistry.beginOrdinary()
        defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        guard restored.0.epoch == epoch() else { throw DeviceStructuralStoreError.conflict }
        nativeGenesisDispatchOperation = restored.1; nativeGenesisQualified = restored.0
        return restored.0
    }

    /// Exact explicitly supplied empty baseline only; does not install a committed delivery envelope.
    func initializeNativeGenesisExplicit(_ state:DeviceNativeStructuralState)throws->NativeGenesisCheckpoint {
        guard root.isFileURL,state.entries.isEmpty,state.configuredEntryID == nil else{throw DeviceStructuralStoreError.conflict}
        let bytes=try DeviceNativeStructuralStateCodec.encode(state)
        let result=try disk(allowNative:true){c in
            let nodes=try nativeGenesisInventory(c)
            if let input=nativeGenesisInput {guard input == bytes else{throw DeviceStructuralStoreError.conflict}}
            guard let rootBinding=try readFile(c.root,"root-binding.json",limit:8192) else{throw DeviceStructuralStoreError.unsafeBinding}
            let originalBinding=NativeNode(identity:rootBinding.identity,bytes:rootBinding.bytes)
            var intent:NativeNode
            if let n=nodes["native-genesis.intent"],!n.bytes.isEmpty {
                let i=try nativeGenesisDecode(NativeGenesisIntent.self,n.bytes,fields:["schemaVersion","rootID","selfID","binding","stateBytes"])
                guard i.schemaVersion == 1,i.rootID == rootID,i.selfID == n.identity,i.binding == originalBinding,i.stateBytes == bytes else{throw DeviceStructuralStoreError.conflict};intent=n
            } else {
                guard nodes.isEmpty || nativeGenesisInput == bytes,nodes.allSatisfy({nativeGenesisLive[$0.key+".stage"] == $0.value.identity && $0.value.bytes.isEmpty}) else{throw DeviceStructuralStoreError.conflict}
                intent=NativeNode(identity:Identity(device:0,inode:0),bytes:Data())
            }
            // Entire persisted or live-prefix identity graph is checked BEFORE epoch/sync/write.
            var reciprocal:NativeGenesisBinding?
            if let n=nodes["native-genesis.binding"],!n.bytes.isEmpty {
                let b=try nativeGenesisDecode(NativeGenesisBinding.self,n.bytes,fields:["schemaVersion","selfID","intent","stateID","confirmationID"])
                guard b.schemaVersion == 1,b.selfID == n.identity,b.intent == intent,nodes["native-genesis.json"]?.identity == b.stateID,nodes["native-genesis.confirm"]?.identity == b.confirmationID else{throw DeviceStructuralStoreError.conflict};reciprocal=b
                let expectedProof=try nativeGenesisEncode(NativeGenesisConfirmation(schemaVersion:1,selfID:b.confirmationID,binding:nodes["native-genesis.binding"]!,stateID:b.stateID,stateDigest:DeviceNativeDeliveryAttachmentCodec.hash(bytes)),limit:32768)
                for key in ["native-genesis.json","native-genesis.confirm"] {guard let n=nodes[key],n.bytes.isEmpty || key == "native-genesis.json" && n.bytes == bytes || key == "native-genesis.confirm" && n.bytes == expectedProof else{throw DeviceStructuralStoreError.conflict}}
            } else {
                for (key,node) in nodes where key != "native-genesis.intent" {guard nativeGenesisInput == bytes,nativeGenesisLive[key+".stage"] == node.identity,node.bytes.isEmpty else{throw DeviceStructuralStoreError.conflict}}
            }
            nativeGenesisInput=bytes;nativeGenesisQualified=nil;bindingQualified=false;let now=epoch(invalidate:true)
            if intent.bytes.isEmpty {
                let id=try nativeAllocate(c,"native-genesis.intent",.nativeGenesisIntent)
                intent=NativeNode(identity:id,bytes:try nativeGenesisEncode(NativeGenesisIntent(schemaVersion:1,rootID:rootID,selfID:id,binding:originalBinding,stateBytes:bytes)))
                try nativeFill(c,"native-genesis.intent",intent,.nativeGenesisIntent)
            }
            try nativePromote(c,"native-genesis.intent",intent,.nativeGenesisIntent)
            let binding:NativeNode
            if let b=reciprocal {binding=nodes["native-genesis.binding"]!;_ = b}
            else {
                let stateID=try nativeAllocate(c,"native-genesis.json",.nativeGenesis),proofID=try nativeAllocate(c,"native-genesis.confirm",.nativeGenesisConfirmation),bindingID=try nativeAllocate(c,"native-genesis.binding",.nativeGenesisBinding)
                binding=NativeNode(identity:bindingID,bytes:try nativeGenesisEncode(NativeGenesisBinding(schemaVersion:1,selfID:bindingID,intent:intent,stateID:stateID,confirmationID:proofID)))
                try nativeFill(c,"native-genesis.binding",binding,.nativeGenesisBinding)
            }
            try nativePromote(c,"native-genesis.binding",binding,.nativeGenesisBinding)
            let b=try nativeGenesisDecode(NativeGenesisBinding.self,binding.bytes,fields:["schemaVersion","selfID","intent","stateID","confirmationID"])
            let data=NativeNode(identity:b.stateID,bytes:bytes)
            let proof=NativeNode(identity:b.confirmationID,bytes:try nativeGenesisEncode(NativeGenesisConfirmation(schemaVersion:1,selfID:b.confirmationID,binding:binding,stateID:b.stateID,stateDigest:DeviceNativeDeliveryAttachmentCodec.hash(bytes)),limit:32768))
            for (name,n,kind) in [("native-genesis.json",data,Kind.nativeGenesis),("native-genesis.confirm",proof,Kind.nativeGenesisConfirmation)] {
                if try readFile(c.root,name,limit:32768) == nil {try nativeFill(c,name,n,kind)}
                try nativePromote(c,name,n,kind)
            }
            try syncExisting(c.root,"root-binding.json",expected:rootBinding);try sync(c.lock);try sync(c.operations);try sync(c.root);try check(c)
            let final=try checkedNativeGenesis(c);guard epoch() == now,final.0 == state else{throw DeviceStructuralStoreError.conflict}
            return NativeGenesisCheckpoint(ObjectIdentifier(self),rootID,now,state,bytes,final.1)
        }
        // Qualification occurs after disk scope exit; other instances invalidate this epoch globally.
        try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()}
        mutex.lock();defer{mutex.unlock()};guard result.epoch == epoch() else{throw DeviceStructuralStoreError.conflict}
        nativeGenesisQualified=result;return result
    }
    func verifyNativeGenesisExact(_ original:NativeGenesisCheckpoint,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(allowNative:true,resourcePermit:resourcePermit){c in
            guard original.issuer == ObjectIdentifier(self),original.rootID == rootID,original.epoch == epoch(),nativeGenesisQualified === original else{throw DeviceStructuralStoreError.conflict}
            let priorMode=nativeCommandScopeActive
            defer{nativeCommandScopeActive=priorMode}
            if let operation=nativeGenesisDispatchOperation {
                nativeCommandScopeActive=true
                _ = try nativeDispatchPreflight(c,operation:operation,candidate:nil,assertions:nil)
            }
            let current=try checkedNativeGenesis(c)
            guard current.0 == original.state,current.1 == original.nodes,epoch() == original.epoch else{throw DeviceStructuralStoreError.conflict}
        }
    }


    /// A common Local-first inventory can retain genuine enrollment genesis only
    /// when no native content command has ever occupied the structural store.
    func verifyNativeEmptyGenesisSourceExact(_ original: NativeGenesisCheckpoint, resourcePermit: DeviceLocalResourcePermit) throws {
        try verifyNativeGenesisExact(original, resourcePermit: resourcePermit)
        try disk(allowNative: true, resourcePermit: resourcePermit) { c in
            guard try names(c.operations).isEmpty,
                !(try names(c.root)).contains(where: { $0.hasPrefix("native-current.json") }) else { throw DeviceStructuralStoreError.conflict }
        }
    }

    // First native operation only. No Local envelope conversion or second-operation admission.
    private var nativeGenesisDispatchOperation: UUID?
    private var nativeCommandScopeActive = false
    private struct NativeCommandInput:Encodable {let candidate:Data,assertions:Data,intent:Data,outcome:Data}
    private var nativeCommandInput: Data?
    private var nativeCommandLive: [String: Identity] = [:]
    private var nativeCommandPending: NativeCommandCapture?
    private var nativeCommandQualified: NativeCommandCapture?
    final class NativeCommandCapture {
        let operationID: UUID, envelopeBytes: Data
        fileprivate let issuer: ObjectIdentifier, rootID: UUID, epoch: UInt64
        fileprivate let original: [String: NativeNode], nodes: [String: NativeNode]
        fileprivate init(_ issuer: ObjectIdentifier, _ rootID: UUID, _ epoch: UInt64,
                         _ op: UUID, _ envelope: Data, _ original: [String: NativeNode], _ nodes: [String: NativeNode]) {
            self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;operationID=op;envelopeBytes=envelope
            self.original=original;self.nodes=nodes
        }
    }
    private struct NativeDispatchState {
        let original: [String: NativeNode]
        let nodes: [String: NativeNode]
        let method: DeviceNativeStructuralMethod?
        let binding: DeviceNativeStructuralPreparedBinding?
    }
    private func nativeMarker(_ node: NativeNode) throws -> DeviceNativeStructuralMarker {
        .init(identity:node.identity,byteCount:node.bytes.count,digest:try DeviceNativeDeliveryAttachmentCodec.hash(node.bytes))
    }
    private func nativeDispatchNames(_ op: UUID) -> (method:String,binding:String,terminal:String) {
        let p=op.uuidString.lowercased();return(p+".native-intent.json",p+".native-binding.json",p+".native-terminal.json")
    }
    private func nativeDispatchRead(_ c: Context, operation: UUID) throws -> [String: NativeNode] {
        let n=nativeDispatchNames(operation),allowed:Set<String>=[n.method,n.binding,n.terminal]
        let files=try names(c.operations)
        guard files.count <= 6,Set(files).isSubset(of:allowed.union(allowed.map{$0+".stage"})) else {throw DeviceStructuralStoreError.conflict}
        var result:[String:NativeNode]=[:]
        for (parent,key,name,limit) in [(c.operations,"method",n.method,DeviceNativeStructuralCommandCodec.methodLimit),
            (c.operations,"binding",n.binding,32768),(c.operations,"terminal",n.terminal,32768),
            (c.root,"current","native-current.json",131072)] {
            let a=try readFile(parent,name,limit:limit),b=try readFile(parent,name+".stage",limit:limit)
            guard a == nil || b == nil else {throw DeviceStructuralStoreError.conflict}
            if let node=a ?? b {result[key] = .init(identity:node.identity,bytes:node.bytes)}
            if let live=nativeCommandLive[name+".stage"] {guard result[key]?.identity == live else {throw DeviceStructuralStoreError.conflict}}
        }
        return result
    }
    private func nativeDispatchOriginal(_ c: Context) throws -> (DeviceNativeStructuralState,[String:NativeNode]) {
        let checked=try checkedNativeGenesis(c)
        guard !(try names(c.root)).contains(where:{$0.hasSuffix(".stage") && Self.nativeGenesisNames.contains(String($0.dropLast(6))) }),
              let binding=try readFile(c.root,"root-binding.json",limit:8192) else {throw DeviceStructuralStoreError.conflict}
        var original=checked.1;original["root-binding.json"] = .init(identity:binding.identity,bytes:binding.bytes)
        return(checked.0,original)
    }
    private func nativeDispatchPreflight(_ c:Context, operation:UUID, candidate:Data?, assertions:Data?, intent:Data? = nil, outcome:Data? = nil) throws -> NativeDispatchState {
        try check(c)
        let old=try nativeDispatchOriginal(c),nodes=try nativeDispatchRead(c,operation:operation)
        var method:DeviceNativeStructuralMethod?,binding:DeviceNativeStructuralPreparedBinding?
        if let m=nodes["method"],!m.bytes.isEmpty {
            let parsed=try DeviceNativeStructuralCommandCodec.method(m.bytes)
            guard parsed.rootID == rootID,parsed.operationID == operation,parsed.selfID == m.identity,
                  parsed.genesisStateBytes == (try DeviceNativeStructuralStateCodec.encode(old.0)),
                  candidate.map({$0 == parsed.candidate}) ?? true,assertions.map({$0 == parsed.resourceAssertions}) ?? true,
                  intent.map({$0 == parsed.intent}) ?? true,outcome.map({$0 == parsed.outcome}) ?? true else {throw DeviceStructuralStoreError.conflict}
            for (name,node) in old.1 {guard try nativeMarker(node) == parsed.original[name] else {throw DeviceStructuralStoreError.conflict}}
            method=parsed
        } else if !nodes.isEmpty {
            let n=nativeDispatchNames(operation)
            guard nativeCommandInput != nil,let m=nodes["method"],nativeCommandLive[n.method+".stage"] == m.identity else {throw DeviceStructuralStoreError.conflict}
        }
        if let b=nodes["binding"],!b.bytes.isEmpty {
            guard let m=nodes["method"],method != nil else {throw DeviceStructuralStoreError.conflict}
            let parsed=try DeviceNativeStructuralCommandCodec.binding(b.bytes)
            guard parsed.rootID == rootID,parsed.operationID == operation,parsed.selfID == b.identity,
                  parsed.method == (try nativeMarker(m)),parsed.candidateID != parsed.terminalID,
                  nodes["current"]?.identity == parsed.candidateID,nodes["terminal"]?.identity == parsed.terminalID else {throw DeviceStructuralStoreError.conflict}
            binding=parsed
            guard let m=method else {throw DeviceStructuralStoreError.conflict}
            let expectedProof=try DeviceNativeStructuralCommandCodec.encode(DeviceNativeStructuralTerminalProof(schemaVersion:2,rootID:rootID,operationID:operation,selfID:parsed.terminalID,binding:try nativeMarker(b),candidate:try nativeMarker(.init(identity:parsed.candidateID,bytes:m.candidate))),limit:32768)
            for (key,expected) in [("current",m.candidate),("terminal",expectedProof)] {
                guard let node=nodes[key],node.bytes == expected || node.bytes.isEmpty else {throw DeviceStructuralStoreError.conflict}
                if key == "current",!node.bytes.isEmpty {_ = try DeviceNativeStructuralCommandCodec.envelope(node.bytes)}
                if key == "terminal",!node.bytes.isEmpty {_ = try DeviceNativeStructuralCommandCodec.terminal(node.bytes)}
            }
        } else {
            let n=nativeDispatchNames(operation)
            for (key,name) in [("binding",n.binding),("current","native-current.json"),("terminal",n.terminal)] {
                if let node=nodes[key] {guard nativeCommandInput != nil,nativeCommandLive[name+".stage"] == node.identity,node.bytes.isEmpty else {throw DeviceStructuralStoreError.conflict}}
            }
        }
        return .init(original:old.1,nodes:nodes,method:method,binding:binding)
    }
    private func nativeDispatchAllocate(_ c:Context,parent:Int32,name:String,kind:Kind) throws -> Identity {
        if let existing=try readFile(parent,name+".stage",limit:DeviceNativeStructuralCommandCodec.methodLimit) {
            guard nativeCommandLive[name+".stage"] == existing.identity else {throw DeviceStructuralStoreError.conflict};return existing.identity
        }
        guard try readFile(parent,name,limit:DeviceNativeStructuralCommandCodec.methodLimit) == nil else {throw DeviceStructuralStoreError.conflict}
        let fd=openat(parent,name+".stage",O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_NONBLOCK,0o600)
        guard fd >= 0 else {throw failure()};defer{close(fd)}
        let id=try identity(fd,directory:false);nativeCommandLive[name+".stage"]=id
        try boundary(.afterCreate(kind));return id
    }
    private func nativeDispatchFill(_ c:Context,parent:Int32,name:String,node:NativeNode,kind:Kind) throws {
        guard let existing=try readFile(parent,name+".stage",limit:DeviceNativeStructuralCommandCodec.methodLimit),existing.identity == node.identity,
              existing.bytes.isEmpty || existing.bytes == node.bytes else {throw DeviceStructuralStoreError.conflict}
        let fd=openat(parent,name+".stage",O_RDWR|O_NOFOLLOW|O_NONBLOCK);guard fd >= 0 else {throw failure()};defer{close(fd)}
        guard try identity(fd,directory:false) == node.identity else {throw DeviceStructuralStoreError.conflict}
        guard ftruncate(fd,0) == 0 else {throw failure()};try writeAll(fd,node.bytes);try boundary(.afterWrite(kind));try sync(fd);try boundary(.afterFileSync(kind));try check(c)
    }
    private func nativeDispatchPromote(_ c:Context,parent:Int32,name:String,node:NativeNode,kind:Kind) throws {
        let expected=Node(identity:node.identity,bytes:node.bytes)
        if let final=try readFile(parent,name,limit:DeviceNativeStructuralCommandCodec.methodLimit) {
            guard final == expected,try readFile(parent,name+".stage",limit:DeviceNativeStructuralCommandCodec.methodLimit) == nil else {throw DeviceStructuralStoreError.conflict}
        } else {
            guard try readFile(parent,name+".stage",limit:DeviceNativeStructuralCommandCodec.methodLimit) == expected else {throw DeviceStructuralStoreError.conflict}
            try syncExisting(parent,name+".stage",expected:expected);try boundary(.beforeReplace(kind));try check(c)
            guard try readFile(parent,name+".stage",limit:DeviceNativeStructuralCommandCodec.methodLimit) == expected,
                  try readFile(parent,name,limit:DeviceNativeStructuralCommandCodec.methodLimit) == nil else {throw DeviceStructuralStoreError.conflict}
            guard renameat(parent,name+".stage",parent,name) == 0 else {throw failure()};try boundary(.afterReplace(kind))
        }
        try syncExisting(parent,name,expected:expected);try boundary(.afterFileSync(kind));try sync(parent);try boundary(.afterDirectorySync(kind));try check(c)
    }
    private func nativeDispatchReservation(_ c:Context,operation:UUID,candidate:Data,assertions:Data,intent:Data,outcome:Data,original:[String:NativeNode]) throws -> [String:Int] {
        let id=Identity(device:UInt64.max,inode:UInt64.max);var markers:[String:DeviceNativeStructuralMarker]=[:]
        for (name,node) in original {markers[name]=try nativeMarker(node)}
        let method=try DeviceNativeStructuralCommandCodec.encode(DeviceNativeStructuralMethod(schemaVersion:2,rootID:rootID,operationID:operation,selfID:id,genesisStateBytes:original["native-genesis.json"]!.bytes,original:markers,candidate:candidate,resourceAssertions:assertions,intent:intent,outcome:outcome),limit:DeviceNativeStructuralCommandCodec.methodLimit)
        let b=try DeviceNativeStructuralCommandCodec.encode(DeviceNativeStructuralPreparedBinding(schemaVersion:2,rootID:rootID,operationID:operation,selfID:id,method:try nativeMarker(.init(identity:id,bytes:method)),candidateID:id,terminalID:id),limit:32768)
        let t=try DeviceNativeStructuralCommandCodec.encode(DeviceNativeStructuralTerminalProof(schemaVersion:2,rootID:rootID,operationID:operation,selfID:id,binding:try nativeMarker(.init(identity:id,bytes:b)),candidate:try nativeMarker(.init(identity:id,bytes:candidate))),limit:32768)
        var total=0
        for parent in [c.root,c.operations] {for name in try names(parent) where name != "operations" && name != "structural.lock" {
            guard let node=try readFile(parent,name,limit:DeviceNativeStructuralCommandCodec.methodLimit),total <= 128*1024*1024-node.bytes.count else {throw DeviceStructuralStoreError.capacity};total += node.bytes.count
        }}
        let additional=2*(method.count+b.count+t.count+candidate.count)
        guard total <= 128*1024*1024-additional else {throw DeviceStructuralStoreError.capacity}
        return["envelope":candidate.count,"method":method.count,"binding":b.count,"terminal":t.count,"reservedPublicBytes":total+additional]
    }
    func nativeDispatchReservationSizesForTesting(candidate:Data,assertions:Data,intent:Data,outcome:Data,operationID:UUID,resourcePermit:DeviceLocalResourcePermit) throws -> [String:Int] {
        try disk(allowNative:true,resourcePermit:resourcePermit){c in
            let state=try nativeDispatchPreflight(c,operation:operationID,candidate:candidate,assertions:assertions,intent:intent,outcome:outcome)
            return try nativeDispatchReservation(c,operation:operationID,candidate:candidate,assertions:assertions,intent:intent,outcome:outcome,original:state.original)
        }
    }
    func performNativeCommandExact(candidate:Data,assertions:Data,intent:Data,outcome:Data,baseline:NativeGenesisCheckpoint,
        commandPermit:DeviceNativeStructuralCommandPermit) throws -> NativeCommandCapture {
        guard candidate.count <= 131072,assertions.count <= 8192,intent.count <= 32768,outcome.count <= 32768 else {throw DeviceStructuralStoreError.tooLarge}
        let envelope=try DeviceNativeStructuralCommandCodec.envelope(candidate)
        let frame = NativeCommandInput(candidate:candidate,assertions:assertions,intent:intent,outcome:outcome)
        let input=try DeviceNativeStructuralCommandCodec.encode(frame,limit:384*1024)
        try commandPermit.begin(ObjectIdentifier(self));defer{commandPermit.end()}
        guard nativeCommandScopeActive,let c=borrowedResourceContext else {throw DeviceLocalResourceGateFailure.invalidScope}
        if let prior=nativeCommandInput {guard prior == input else {throw DeviceStructuralStoreError.conflict}}
        let state=try nativeDispatchPreflight(c,operation:envelope.operationID,candidate:candidate,assertions:assertions,intent:intent,outcome:outcome)
        guard baseline.issuer == ObjectIdentifier(self),baseline.rootID == rootID,baseline.nodes.allSatisfy({state.original[$0.key] == $0.value}),
              baseline.stateBytes == state.original["native-genesis.json"]?.bytes else {throw DeviceStructuralStoreError.conflict}
        if state.nodes.isEmpty {guard nativeGenesisQualified === baseline,baseline.epoch == epoch() else {throw DeviceStructuralStoreError.outcomeUncertain}}
        _ = try nativeDispatchReservation(c,operation:envelope.operationID,candidate:candidate,assertions:assertions,intent:intent,outcome:outcome,original:state.original)
        nativeCommandInput=input;nativeCommandPending=nil;nativeCommandQualified=nil;nativeGenesisQualified=nil;bindingQualified=false
        let attemptEpoch=epoch(invalidate:true),n=nativeDispatchNames(envelope.operationID)
        for (name,node) in state.original {try syncExisting(c.root,name,expected:.init(identity:node.identity,bytes:node.bytes))}
        try sync(c.lock);try sync(c.operations);try sync(c.root)
        guard try nativeDispatchOriginal(c).1 == state.original else {throw DeviceStructuralStoreError.conflict}
        let method:NativeNode
        if let m=state.nodes["method"],!m.bytes.isEmpty {method=m}
        else {
            let id=try nativeDispatchAllocate(c,parent:c.operations,name:n.method,kind:.nativeCommandIntent)
            var markers:[String:DeviceNativeStructuralMarker]=[:];for (name,node) in state.original {markers[name]=try nativeMarker(node)}
            method = .init(identity:id,bytes:try DeviceNativeStructuralCommandCodec.encode(DeviceNativeStructuralMethod(schemaVersion:2,rootID:rootID,operationID:envelope.operationID,selfID:id,genesisStateBytes:baseline.stateBytes,original:markers,candidate:candidate,resourceAssertions:assertions,intent:intent,outcome:outcome),limit:DeviceNativeStructuralCommandCodec.methodLimit))
            try nativeDispatchFill(c,parent:c.operations,name:n.method,node:method,kind:.nativeCommandIntent)
        }
        try nativeDispatchPromote(c,parent:c.operations,name:n.method,node:method,kind:.nativeCommandIntent)
        let binding:NativeNode
        if let b=state.nodes["binding"],!b.bytes.isEmpty {binding=b}
        else {
            let currentID=try nativeDispatchAllocate(c,parent:c.root,name:"native-current.json",kind:.nativeCommandCurrent),proofID=try nativeDispatchAllocate(c,parent:c.operations,name:n.terminal,kind:.nativeCommandTerminal),id=try nativeDispatchAllocate(c,parent:c.operations,name:n.binding,kind:.nativeCommandBinding)
            binding = .init(identity:id,bytes:try DeviceNativeStructuralCommandCodec.encode(DeviceNativeStructuralPreparedBinding(schemaVersion:2,rootID:rootID,operationID:envelope.operationID,selfID:id,method:try nativeMarker(method),candidateID:currentID,terminalID:proofID),limit:32768))
            try nativeDispatchFill(c,parent:c.operations,name:n.binding,node:binding,kind:.nativeCommandBinding)
        }
        try nativeDispatchPromote(c,parent:c.operations,name:n.binding,node:binding,kind:.nativeCommandBinding)
        let b=try DeviceNativeStructuralCommandCodec.binding(binding.bytes),current=NativeNode(identity:b.candidateID,bytes:candidate)
        if try readFile(c.root,"native-current.json",limit:131072) == nil {try nativeDispatchFill(c,parent:c.root,name:"native-current.json",node:current,kind:.nativeCommandCurrent)}
        try nativeDispatchPromote(c,parent:c.root,name:"native-current.json",node:current,kind:.nativeCommandCurrent)
        let proof=NativeNode(identity:b.terminalID,bytes:try DeviceNativeStructuralCommandCodec.encode(DeviceNativeStructuralTerminalProof(schemaVersion:2,rootID:rootID,operationID:envelope.operationID,selfID:b.terminalID,binding:try nativeMarker(binding),candidate:try nativeMarker(current)),limit:32768))
        if try readFile(c.operations,n.terminal,limit:32768) == nil {try nativeDispatchFill(c,parent:c.operations,name:n.terminal,node:proof,kind:.nativeCommandTerminal)}
        try nativeDispatchPromote(c,parent:c.operations,name:n.terminal,node:proof,kind:.nativeCommandTerminal)
        let final=try nativeDispatchPreflight(c,operation:envelope.operationID,candidate:candidate,assertions:assertions,intent:intent,outcome:outcome)
        guard final.original == state.original,final.nodes["current"] == current,final.nodes["terminal"] == proof,epoch() == attemptEpoch else {throw DeviceStructuralStoreError.conflict}
        let capture=NativeCommandCapture(ObjectIdentifier(self),rootID,attemptEpoch,envelope.operationID,candidate,state.original,final.nodes)
        nativeCommandPending=capture;return capture
    }
    /// Durable bytes discovery only. Recovery still verifies original method,
    /// resources, grants and terminal reciprocal proofs before publishing content.
    func inspectStoredNativeCandidateExact(operationID: UUID, resourcePermit: DeviceLocalResourcePermit) throws -> DeviceNativeStructuralState {
        try disk(allowNative: true, resourcePermit: resourcePermit) { context in
            let state = try nativeDispatchPreflight(context, operation: operationID, candidate: nil, assertions: nil)
            guard let method = state.method, state.binding != nil,
                  let current = state.nodes["current"],
                  current.bytes == method.candidate,
                  state.nodes["terminal"] != nil else { throw DeviceStructuralStoreError.conflict }
            let envelope = try DeviceNativeStructuralEnvelopeCodec.decode(method.candidate)
            guard envelope.operationID == operationID else { throw DeviceStructuralStoreError.conflict }
            return try DeviceNativeStructuralStateCodec.decode(envelope.snapshotBytes)
        }
    }
    func verifyNativeCommandCapture(_ original:NativeCommandCapture,resourcePermit:DeviceLocalResourcePermit) throws {
        try disk(allowNative:true,resourcePermit:resourcePermit){c in
            guard original.issuer == ObjectIdentifier(self),original.rootID == rootID,original.epoch == epoch(),
                  nativeCommandPending === original || nativeCommandQualified === original else {throw DeviceStructuralStoreError.conflict}
            let state=try nativeDispatchPreflight(c,operation:original.operationID,candidate:original.envelopeBytes,assertions:nil)
            guard state.original == original.original,state.nodes == original.nodes,
                  !(try names(c.root)).contains("native-current.json.stage"),!(try names(c.operations)).contains(where:{$0.hasSuffix(".stage")}) else {throw DeviceStructuralStoreError.conflict}
        }
    }
    func verifyNativeGenesisNodesForDispatch(_ original:NativeGenesisCheckpoint,resourcePermit:DeviceLocalResourcePermit) throws {
        try disk(allowNative:true,resourcePermit:resourcePermit){c in
            let state=try nativeDispatchOriginal(c)
            guard original.issuer == ObjectIdentifier(self),original.rootID == rootID,
                  state.0 == original.state,original.nodes.allSatisfy({state.1[$0.key] == $0.value}) else {throw DeviceStructuralStoreError.conflict}
        }
    }
    func publishNativeCommandExact(_ original:NativeCommandCapture,permit:DeviceNativeStructuralPublicationPermit) throws -> NativeCommandCapture {
        try permit.requireIdle();try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()}
        mutex.lock();defer{mutex.unlock()}
        guard nativeCommandPending === original,original.issuer == ObjectIdentifier(self),original.epoch == epoch() else {throw DeviceStructuralStoreError.conflict}
        nativeCommandQualified=original;return original
    }
    func discardNativeCommandExact(_ original:NativeCommandCapture) throws {
        try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()};mutex.lock();defer{mutex.unlock()}
        guard original.issuer == ObjectIdentifier(self),original.epoch == epoch() else {return}
        if nativeCommandPending === original {nativeCommandPending=nil}
        if nativeCommandQualified === original {nativeCommandQualified=nil}
    }
    func withNativeStructuralResourceGateScope(_ permit:DeviceLocalResourcePermit,_ body:()throws->Void) throws {
        try permit.beginAcquisition(resourceGateDescriptor);mutex.lock();defer{permit.invalidate();mutex.unlock()}
        try diskContext(create:false,releasePermit:permit){c in
            guard !nativeCommandScopeActive else {throw DeviceLocalResourceGateFailure.invalidScope}
            nativeCommandScopeActive=true;borrowedResourceContext=c
            defer{nativeCommandScopeActive=false;borrowedResourceContext=nil;permit.invalidate()}
            let before=epoch()
            do {
                try body();try boundary(.beforeNativeCommandScopeExit);try check(c)
                if let pending=nativeCommandPending,pending.epoch == epoch() {
                    let final=try nativeDispatchPreflight(c,operation:pending.operationID,candidate:pending.envelopeBytes,assertions:nil)
                    guard final.original == pending.original,final.nodes == pending.nodes else {throw DeviceStructuralStoreError.conflict}
                }
            }
            catch {if epoch() != before {nativeCommandPending=nil;nativeCommandQualified=nil};throw error}
        }
    }
    /// Strict original-genesis synchronization for restart. Never acknowledges current candidate/proof.
    func recommitNativeGenesisForDispatchExact(_ expected:DeviceNativeStructuralState,operationID:UUID) throws -> NativeGenesisCheckpoint {
        let bytes=try DeviceNativeStructuralStateCodec.encode(expected)
        let result=try disk(allowNative:true){c in
            nativeCommandScopeActive=true;defer{nativeCommandScopeActive=false}
            let state=try nativeDispatchPreflight(c,operation:operationID,candidate:nil,assertions:nil)
            guard state.original["native-genesis.json"]?.bytes == bytes,state.method != nil else {throw DeviceStructuralStoreError.conflict}
            let now=epoch(invalidate:true);nativeGenesisQualified=nil;nativeCommandPending=nil;nativeCommandQualified=nil;bindingQualified=false
            for (name,node) in state.original {try syncExisting(c.root,name,expected:.init(identity:node.identity,bytes:node.bytes))}
            try sync(c.lock);try sync(c.operations);try sync(c.root)
            let checked=try nativeDispatchPreflight(c,operation:operationID,candidate:nil,assertions:nil)
            guard checked.original == state.original,checked.nodes == state.nodes,epoch() == now else {throw DeviceStructuralStoreError.conflict}
            return NativeGenesisCheckpoint(ObjectIdentifier(self),rootID,now,expected,bytes,try checkedNativeGenesis(c).1)
        }
        try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()};mutex.lock();defer{mutex.unlock()}
        guard result.epoch == epoch() else {throw DeviceStructuralStoreError.conflict};nativeGenesisDispatchOperation=operationID;nativeGenesisQualified=result;return result
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
    private func disk<T>(create: Bool = false, allowNative: Bool = false, resourcePermit: DeviceLocalResourcePermit? = nil,
                         _ operation: (Context) throws -> T) throws -> T {
        if let permit = resourcePermit {
            guard !create else { throw DeviceLocalResourceGateFailure.invalidScope }
            try permit.beginRead(ObjectIdentifier(self)); defer { permit.endRead() }
            guard let context = borrowedResourceContext else { throw DeviceLocalResourceGateFailure.invalidScope }
            try check(context)
            if !allowNative { try requireNoNativeGenesis(context.root) }
            do { let result = try operation(context); try check(context); return result }
            catch { try check(context); throw error }
        }
        try DeviceLocalResourceRegistry.beginOrdinary(); defer { DeviceLocalResourceRegistry.endOrdinary() }
        mutex.lock(); defer { mutex.unlock() }
        return try diskContext(create:create,allowNative:allowNative,operation)
    }
    private func diskContext<T>(create: Bool, allowNative: Bool = true, releasePermit: DeviceLocalResourcePermit? = nil, _ operation: (Context) throws -> T) throws -> T {
        guard root.path.utf8.count <= 4096, root.resolvingSymlinksInPath().path == root.path else { throw DeviceStructuralStoreError.unsafeBinding }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard rootFD >= 0 else { throw failure() }; defer { close(rootFD) }
        if !allowNative { try requireNoNativeGenesis(rootFD) }
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
