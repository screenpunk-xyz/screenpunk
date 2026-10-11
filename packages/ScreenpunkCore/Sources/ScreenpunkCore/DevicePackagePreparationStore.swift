import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Constructible only after an exact synchronized attempt. Not Codable, membership, grants or approval.
/// One repair attempt's nonsecret snapshot only, not admission or generic retained-receipt authority.
/// No public/memberwise construction, serialization, FD or mutable qualification accessor.
final class DevicePackageResolutionCheckpoint {
    fileprivate let issuer: ObjectIdentifier
    fileprivate let rootID: UUID
    fileprivate let epoch: UInt64
    fileprivate let tipIdentity: PreparationIdentity?
    fileprivate let tipBytes: Data?
    fileprivate let bindingIdentity: PreparationIdentity
    fileprivate let bindingBytes: Data
    fileprivate init(issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,tipIdentity:PreparationIdentity?,tipBytes:Data?,
                     bindingIdentity:PreparationIdentity,bindingBytes:Data) {
        self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;self.tipIdentity=tipIdentity;self.tipBytes=tipBytes
        self.bindingIdentity=bindingIdentity;self.bindingBytes=bindingBytes
    }
}
final class DevicePackageTerminalResolution {
    let receipts: [DevicePreparedPackageReceipt]
    let checkpoint: DevicePackageResolutionCheckpoint
    fileprivate init(_ receipts:[DevicePreparedPackageReceipt],checkpoint:DevicePackageResolutionCheckpoint) {
        self.receipts=receipts;self.checkpoint=checkpoint
    }
}
final class DevicePreparedPackageReceipt {
    let reference: DevicePreparedPackageReference
    fileprivate let issuer: ObjectIdentifier
    fileprivate let recordBytes: Data
    fileprivate let recordIdentity: PreparationIdentity
    fileprivate init(reference: DevicePreparedPackageReference, issuer: ObjectIdentifier, recordBytes: Data, recordIdentity: PreparationIdentity) {
        self.reference = reference; self.issuer = issuer; self.recordBytes = recordBytes; self.recordIdentity = recordIdentity
    }
}
final class DeviceVerifiedPreparedPackage {
    let reference: DevicePreparedPackageReference
    let package: QualifiedDevicePackage
    fileprivate init(reference: DevicePreparedPackageReference, package: QualifiedDevicePackage) { self.reference = reference; self.package = package }
}

/// Unmounted owned-root mechanics only; no production default/caller, grant, reset, migration or pruning.
/// SHA256/framed identity includes ORIGINAL manifest bytes and exact sorted asset inventory. A leaf name
/// alone is never provenance: receipts bind root UUID, operation, content and checked inode evidence.
/// One unresolved/128 terminal records, <=260 metadata names, <=256 root names; each record <=4MiB.
/// Content <=50MiB; <=2001 files, <=4096 directories, path depth32; bounded descriptor traversal only.
/// Creation-to-persisted-inode crashes preserve orphans and BLOCK reconstruction. Matching bytes are not
/// adopted or deleted. Live captured identity may repair its exact attempt; universal recovery is not claimed.
/// fsync covers owned files/directories only, not ancestors. Inodes are local replacement guards, not
/// portable restore identity. Same-UID malicious modification and physical storage guarantees are outside
/// this synchronization contract. No authority is derived from readable metadata or a diagnostic result.
final class DevicePackagePreparationStore {
    enum Kind: Equatable { case binding, intent, progress, file, directory, install, terminal }
    enum Boundary: Equatable {
        case afterCreate(Kind), afterWrite(Kind), afterFileSync(Kind), beforeReplace(Kind), afterReplace(Kind), afterDirectorySync(Kind)
    }
    enum Diagnosis: Equatable { case intent, prepared, terminalNeedsDurability }
    private struct Node: Equatable { let identity: PreparationIdentity; let bytes: Data }
    private struct Binding: Codable, Equatable {
        let schemaVersion: Int; let rootID: UUID; let rootPath: String; let protectedPaths: [String]
        let rootIdentity: PreparationIdentity; let lockIdentity: PreparationIdentity; let operationsIdentity: PreparationIdentity
    }
    private struct Context { let root: Int32; let lock: Int32; let operations: Int32; let binding: Binding }
    private struct Entry { let record: PreparationRecord; let final: Node?; let staged: Node? }
    private struct Inventory { let entries: [Entry]; var tip: Entry? { entries.last }; var hasStages: Bool { entries.contains { $0.staged != nil } } }
    let root: URL
    let rootID: UUID
    private let scope: DevicePackageProtectedScope
    private let boundary: (Boundary) throws -> Void
    private let mutex = NSLock()
    private var bindingQualified = false
    private var setupRoot: PreparationIdentity?
    private var setupLock: PreparationIdentity?
    private var setupOperations: PreparationIdentity?
    private var captured: [String: PreparationIdentity] = [:]
    private var qualification: (epoch: UInt64, tip: Node)?
    private static let gateLock = NSLock()
    private static var epochs: [String: UInt64] = [:]
    init(root: URL, rootID: UUID, protectedScope: DevicePackageProtectedScope, boundary: @escaping (Boundary) throws -> Void = { _ in }) {
        self.root = root; self.rootID = rootID; scope = protectedScope; self.boundary = boundary
    }
    private func epoch(invalidate: Bool = false) -> UInt64 {
        Self.gateLock.lock(); defer { Self.gateLock.unlock() }
        let key = root.path + "|" + rootID.uuidString
        let value = (Self.epochs[key] ?? 0) + (invalidate ? 1 : 0)
        Self.epochs[key] = value; return value
    }
    /// Root must already exist. Unknown preexisting setup/content is never silently initialized.
    func makeIndependentStore(root: URL, rootID: UUID) -> DevicePackagePreparationStore {
        .init(root: root, rootID: rootID, protectedScope: scope)
    }
    func initializeExplicit() throws {
        try disk(create: true) { context in
            let binding = try PackagePreparationCodec.encode(context.binding)
            if let existing = try readFile(context.root, "root-binding.json", limit: PackagePreparationCodec.metadataLimit) {
                guard existing.bytes == binding else { throw DevicePackagePreparationError.unsafeBinding }
                if let staged = try readFile(context.root, "root-binding.json.pending", limit: PackagePreparationCodec.metadataLimit) {
                    guard staged.bytes == binding else { throw DevicePackagePreparationError.conflict }
                    try replace(context, parent: context.root, name: "root-binding.json", bytes: binding, expected: existing, kind: .binding)
                } else { try syncExisting(context.root, "root-binding.json", expected: existing) }
            } else {
                guard try names(context.operations, maximum: 260).isEmpty else { throw DevicePackagePreparationError.conflict }
                try replace(context, parent: context.root, name: "root-binding.json", bytes: binding, expected: nil, kind: .binding)
            }
            try sync(context.lock); try sync(context.operations); try sync(context.root)
            try check(context); _ = try inventory(context)
            bindingQualified = true
        }
    }
    /// Initial preparation only. A retained attempt must be repaired with explicit recommitExact.
    func prepareExact(_ request: DevicePackagePreparationRequest) throws -> DevicePreparedPackageReceipt {
        try disk { context in
            guard bindingQualified else { throw DevicePackagePreparationError.repairRequired }
            let state = try inventory(context)
            guard !state.entries.contains(where: { $0.record.plan.operationID == request.operationID }) else { throw DevicePackagePreparationError.repairRequired }
            guard state.entries.count < 128 else { throw DevicePackagePreparationError.capacity }
            guard !state.hasStages, state.entries.allSatisfy({ $0.record.phase == .terminal }) else { throw DevicePackagePreparationError.repairRequired }
            if let tip = state.tip?.final { try requireQualification(tip) }
            let plan = try PackagePreparationCodec.makePlan(request, rootID: rootID, ordinal: state.entries.count + 1)
            guard !state.entries.contains(where: { $0.record.plan.contentID == plan.contentID }) else { throw DevicePackagePreparationError.conflict }
            let record = PreparationRecord(plan: plan)
            let bytes = try PackagePreparationCodec.encode(record) // Exact intent bound BEFORE package effects.
            let attemptEpoch = epoch(invalidate: true); qualification = nil
            try replace(context, parent: context.operations, name: filename(request.operationID), bytes: bytes, expected: nil, kind: .intent)
            return try finish(context, record: record, request: request, attemptEpoch: attemptEpoch)
        }
    }
    func diagnose(operationID: UUID) throws -> Diagnosis {
        try disk { context in
            guard let entry = try inventory(context).entries.first(where: { $0.record.plan.operationID == operationID }) else { throw DevicePackagePreparationError.conflict }
            switch entry.record.phase { case .intent: return .intent; case .prepared: return .prepared; case .terminal: return .terminalNeedsDurability }
        }
    }
    func recommitExact(_ request: DevicePackagePreparationRequest) throws -> DevicePreparedPackageReceipt {
        try disk { context in
            let attemptEpoch = epoch(invalidate: true); qualification = nil
            let state = try inventory(context)
            guard let entry = state.entries.first(where: { $0.record.plan.operationID == request.operationID }),
                  try PackagePreparationCodec.encode(PackagePreparationCodec.makePlan(request, rootID: rootID, ordinal: entry.record.plan.ordinal)) == PackagePreparationCodec.encode(entry.record.plan) else { throw DevicePackagePreparationError.conflict }
            let name = filename(request.operationID)
            if let staged = entry.staged {
                try replace(context, parent: context.operations, name: name, bytes: staged.bytes, expected: entry.final, kind: entry.record.phase == .terminal ? .terminal : .progress)
            } else if let final = entry.final { try syncExisting(context.operations, name, expected: final); try sync(context.operations) }
            else { throw DevicePackagePreparationError.conflict }
            if entry.record.phase == .terminal {
                _ = try checkedPackage(context, record: entry.record, directory: entry.record.plan.leaf, synchronize: true)
                try boundary(.afterFileSync(.install)); try sync(context.root)
                guard let proof = try readFile(context.operations, name, limit: PackagePreparationCodec.metadataLimit) else { throw DevicePackagePreparationError.conflict }
                try syncExisting(context.operations, name, expected: proof)
                try boundary(.afterReplace(.terminal)); try sync(context.operations); try boundary(.afterDirectorySync(.terminal))
                return try receipt(context, record: entry.record, attemptEpoch: attemptEpoch)
            }
            return try finish(context, record: entry.record, request: request, attemptEpoch: attemptEpoch)
        }
    }
    private struct BoundItem {
        let entryID:UUID,reference:DevicePreparedPackageReference,request:DevicePackagePreparationRequest
        let retained:Bool
    }
    /// Pure observations under the shared gate, not acknowledgment. Refresh retained package bytes
    /// from their actual recorded inode inventory before private grant requalification.
    func inspectBoundPackages(_ inputs:[DeviceProvisioningPackageInput],plan:DeviceValidatedProvisioningPlan,
                              resourcePermit:DeviceLocalResourcePermit)throws->[DeviceProvisioningPackageInput] {
        guard inputs.count <= 12 else{throw DevicePackagePreparationError.sizeLimit}
        return try disk(resourcePermit:resourcePermit){c in
            let items=try boundItems(inputs,plan:plan,context:c,state:inventory(c))
            return items.map{item in
                if item.retained {return .retained(entryID:item.entryID,reference:item.reference,
                    verified:DeviceVerifiedPreparedPackage(reference:item.reference,package:item.request.package))}
                return .supplied(entryID:item.entryID,operationID:item.request.operationID,package:item.request.package)
            }
        }
    }
    private func boundItems(_ inputs:[DeviceProvisioningPackageInput],plan:DeviceValidatedProvisioningPlan,
                            context c:Context,state:Inventory)throws->[BoundItem] {
        guard inputs.count <= 12 else{throw DevicePackagePreparationError.sizeLimit}
        let body=try ProvisioningIntentCodec.decode(plan.canonicalBytes),envelope=try StructuralStoreCodec.envelope(body.candidate)
        let refs=try DeviceLocalCompleteSetRestoreCodec.references(envelope.intent)
        guard body.roots.packageID == rootID,body.roots == plan.roots,body.operationID == plan.operationID else {
            throw DevicePackagePreparationError.conflict
        }
        let bindings = refs.packages.map { ref in
            NativeReference(entryID: ref.entryID, reference: .init(rootID: ref.rootID, contentID: ref.contentID,
                preparationOperationID: ref.preparationOperationID, directory: ref.directory))
        }
        return try matchBoundItems(inputs, references: bindings, context: c, state: state)
    }
    private struct NativeReference { let entryID: UUID; let reference: DevicePreparedPackageReference }
    private func matchBoundItems(_ inputs: [DeviceProvisioningPackageInput], references: [NativeReference],
                                context c: Context, state: Inventory) throws -> [BoundItem] {
        guard inputs.count <= 12, references.count <= 12, inputs.count == references.count,
              Set(references.map(\.entryID)).count == references.count,
              references.allSatisfy({ $0.reference.rootID == rootID }) else {
            throw DevicePackagePreparationError.conflict
        }
        var supplied:[UUID:DeviceProvisioningPackageInput]=[:]
        for input in inputs {
            let id:UUID
            switch input{case .supplied(let value,_,_):id=value;case .retained(let value,_,_):id=value}
            guard supplied.updateValue(input,forKey:id) == nil else{throw DevicePackagePreparationError.conflict}
        }
        var items:[BoundItem]=[],newCount=0,operations=Set<UUID>(),contentIDs=Set<Data>()
        for binding in references {
            let ref = binding.reference
            guard let input=supplied[binding.entryID],operations.insert(ref.preparationOperationID).inserted,
                  contentIDs.insert(Data(ref.contentID.utf8)).inserted else{throw DevicePackagePreparationError.conflict}
            let reference = ref
            let existing=state.entries.first{$0.record.plan.operationID == ref.preparationOperationID}
            let package:QualifiedDevicePackage,retained:Bool
            switch input {
            case .supplied(_,let op,let value):
                guard op == ref.preparationOperationID else{throw DevicePackagePreparationError.conflict};package=value;retained=false
            case .retained(_,let given,let value):
                guard DeviceProvisioningPlanner.exactReference(given,reference),DeviceProvisioningPlanner.exactReference(value.reference,reference),
                      let entry=existing,entry.record.phase == .terminal else{throw DevicePackagePreparationError.conflict}
                package=try checkedPackage(c,record:entry.record,directory:entry.record.plan.leaf,synchronize:false);retained=true
            }
            let request=DevicePackagePreparationRequest(operationID:ref.preparationOperationID,package:package)
            let ordinal=existing?.record.plan.ordinal ?? (state.entries.count+newCount+1)
            let expected=try PackagePreparationCodec.makePlan(request,rootID:rootID,ordinal:ordinal)
            guard DeviceProvisioningPlanner.exactReference(expected.reference,reference) else{throw DevicePackagePreparationError.conflict}
            if let existing {
                guard try PackagePreparationCodec.encode(expected) == PackagePreparationCodec.encode(existing.record.plan) else{throw DevicePackagePreparationError.conflict}
            } else {
                guard !retained,!state.entries.contains(where:{$0.record.plan.contentID.utf8.elementsEqual(expected.contentID.utf8)}) else{throw DevicePackagePreparationError.conflict}
                _ = try PackagePreparationCodec.encode(PreparationRecord(plan:expected));newCount += 1
            }
            items.append(.init(entryID:binding.entryID,reference:reference,request:request,retained:retained))
        }
        // Reserve the WHOLE batch before any shared epoch or filesystem effects. No pruning.
        guard state.entries.count <= 128,newCount <= 128-state.entries.count else{throw DevicePackagePreparationError.capacity}
        let repairs=state.entries.filter{$0.record.phase != .terminal || $0.staged != nil}
        guard repairs.count <= 1,repairs.allSatisfy({entry in items.contains{$0.request.operationID == entry.record.plan.operationID && !$0.retained}}) else{throw DevicePackagePreparationError.repairRequired}
        for repair in repairs {
            guard let item=items.first(where:{$0.request.operationID == repair.record.plan.operationID}) else{throw DevicePackagePreparationError.conflict}
            try validatePendingResources(c,record:repair.record,request:item.request)
        }
        return items
    }
    /// Read-only bounded partial-content preflight. A live captured identity can qualify an exact
    /// unfinished creation; restart never adopts a same-byte unrecorded file/directory.
    private func validatePendingResources(_ c:Context,record initial:PreparationRecord,request:DevicePackagePreparationRequest)throws {
        if initial.phase == .terminal {return} // inventory already verified exact installed inventory.
        if initial.phase == .intent {
            if let id=try directoryIdentity(c.root,initial.plan.stage) {
                guard captured[captureKey(request.operationID,"")] == id else{throw DevicePackagePreparationError.repairRequired}
                let stage=try directory(c.root,initial.plan.stage,expected:id,create:false);defer{close(stage)}
                guard try names(stage,maximum:1).isEmpty else{throw DevicePackagePreparationError.conflict}
            }
            return
        }
        if try directoryIdentity(c.root,initial.plan.leaf) != nil {
            _ = try checkedPackage(c,record:initial,directory:initial.plan.leaf,synchronize:false);return
        }
        guard let id=initial.directoryIdentity else{throw DevicePackagePreparationError.conflict}
        let stage=try directory(c.root,initial.plan.stage,expected:id,create:false);defer{close(stage)}
        var record=initial,missing=Set<String>(),existing:[String]=[""]
        func missingAncestor(_ path:String)->Bool{missing.contains{path.utf8.starts(with:($0+"/").utf8)}}
        for (index,path) in record.plan.directories.enumerated() {
            let key=captureKey(request.operationID,path+"/"),expected=record.directoryIdentities[index] ?? captured[key]
            if missingAncestor(path) {guard expected == nil else{throw DevicePackagePreparationError.conflict};missing.insert(path);continue}
            let parent=try parent(stage,path:path,record:record);defer{close(parent)}
            let leaf=String(path.split(separator:"/").last!)
            if let found=try directoryIdentity(parent,leaf) {
                guard expected == found else{throw DevicePackagePreparationError.repairRequired};record.directoryIdentities[index]=found;existing.append(path)
            } else {guard expected == nil else{throw DevicePackagePreparationError.conflict};missing.insert(path)}
        }
        var content=Dictionary(uniqueKeysWithValues:request.package.files.map{($0.path,$0.bytes)})
        content["manifest.json"]=request.package.originalManifestBytes
        for (index,file) in record.plan.files.enumerated() {
            let expected=record.fileIdentities[index] ?? captured[captureKey(request.operationID,file.path)]
            if missingAncestor(file.path) {guard expected == nil else{throw DevicePackagePreparationError.conflict};continue}
            let parent=try parent(stage,path:file.path,record:record);defer{close(parent)}
            let leaf=String(file.path.split(separator:"/").last!)
            if let node=try readFile(parent,leaf,limit:file.bytes) {
                guard node.identity == expected,let bytes=content[file.path],bytes.starts(with:node.bytes) else{throw DevicePackagePreparationError.repairRequired}
            } else {guard expected == nil else{throw DevicePackagePreparationError.conflict}}
        }
        let paths=record.plan.files.map(\.path)+record.plan.directories
        for path in existing {
            let fd=path.isEmpty ? dup(stage):try openDirectory(stage,path:path,record:record)
            guard fd >= 0 else{throw failure()};defer{close(fd)}
            let prefix=path.isEmpty ? "":path+"/"
            let allowed=Set(paths.filter{$0.hasPrefix(prefix)}.compactMap{String($0.dropFirst(prefix.count)).split(separator:"/").first.map(String.init)})
            guard Set(try names(fd,maximum:6097)).isSubset(of:allowed) else{throw DevicePackagePreparationError.conflict}
        }
    }
    /// Nonauthorizing original read evidence for one explicit native recovery. No synchronization,
    /// receipt issuance, epoch renewal or public construction; retained Data shares bounded nodes.
    final class NativeBatchOriginal {
        fileprivate let issuer: ObjectIdentifier, rootID: UUID, epoch: UInt64
        fileprivate let bindingBytes: Data, bindingID: PreparationIdentity
        fileprivate let bytes: [String: Data], identities: [String: PreparationIdentity]
        let inputs: [DeviceProvisioningPackageInput]
        fileprivate init(_ issuer: ObjectIdentifier, _ rootID: UUID, _ epoch: UInt64, _ binding: Data,
                         _ bindingID: PreparationIdentity, _ bytes: [String: Data],
                         _ identities: [String: PreparationIdentity], _ inputs: [DeviceProvisioningPackageInput]) {
            self.issuer = issuer; self.rootID = rootID; self.epoch = epoch
            bindingBytes = binding; self.bindingID = bindingID; self.bytes = bytes
            self.identities = identities; self.inputs = inputs
        }
    }
    private func nativeReferences(_ plan: DeviceValidatedNativeProvisioningPlan) throws -> [NativeReference] {
        guard plan.intentBytes.count <= 32768, plan.candidateBytes.count <= 128 * 1024 else {
            throw DevicePackagePreparationError.sizeLimit
        }
        let body = try DeviceNativeProvisioningIntentCodec.decode(plan.intentBytes)
        let envelope = try DeviceNativeStructuralEnvelopeCodec.decode(plan.candidateBytes)
        let state = try DeviceNativeStructuralStateCodec.decode(envelope.snapshotBytes)
        guard body.roots == plan.roots, body.roots.packageID == rootID,
              body.nativeOperationID == plan.nativeOperationID, envelope.operationID == plan.nativeOperationID,
              envelope.expectedGenerationID == body.expectedGenerationID,
              state.generationID == body.desiredGenerationID,
              body.candidateByteCount == plan.candidateBytes.count,
              body.candidateDigest.utf8.elementsEqual(try DeviceNativeDeliveryAttachmentCodec.hash(plan.candidateBytes).utf8),
              state.entries.count == body.packages.count else { throw DevicePackagePreparationError.conflict }
        for (entry, package) in zip(state.entries, body.packages) {
            guard entry.entryID == package.entryID,
                  DeviceProvisioningPlanner.exactReference(entry.preparedPackage, package.reference) else {
                throw DevicePackagePreparationError.conflict
            }
        }
        return body.packages.map { .init(entryID: $0.entryID, reference: $0.reference) }
    }
    private func freshInputs(_ items: [BoundItem]) -> [DeviceProvisioningPackageInput] {
        items.map { item in
            if item.retained { return .retained(entryID: item.entryID, reference: item.reference,
                verified: DeviceVerifiedPreparedPackage(reference: item.reference, package: item.request.package)) }
            return .supplied(entryID: item.entryID, operationID: item.request.operationID, package: item.request.package)
        }
    }
    func inspectNativeBoundPackages(_ inputs: [DeviceProvisioningPackageInput], plan: DeviceValidatedNativeProvisioningPlan,
                                    resourcePermit: DeviceLocalResourcePermit) throws -> [DeviceProvisioningPackageInput] {
        guard inputs.count <= 12 else { throw DevicePackagePreparationError.sizeLimit }
        let references = try nativeReferences(plan)
        return try disk(resourcePermit: resourcePermit) { c in
            try freshInputs(matchBoundItems(inputs, references: references, context: c, state: inventory(c)))
        }
    }
    /// Before private frame recovery a caller has only an explicit schema2 candidate, not a plan.
    /// This reads a bounded matching package inventory; the grant's private frame later binds it
    /// to the genuine exact intent. Candidate bytes alone confer no operation authority.
    func captureNativeBatchOriginal(_ inputs: [DeviceProvisioningPackageInput],
        candidate: DeviceNativeStructuralState, resourcePermit: DeviceLocalResourcePermit) throws -> NativeBatchOriginal {
        guard inputs.count <= 12, candidate.entries.count <= 12 else { throw DevicePackagePreparationError.sizeLimit }
        _ = try DeviceNativeStructuralStateCodec.encode(candidate)
        let references = candidate.entries.map { NativeReference(entryID: $0.entryID, reference: $0.preparedPackage) }
        guard references.allSatisfy({ $0.reference.rootID == rootID }) else { throw DevicePackagePreparationError.conflict }
        return try disk(resourcePermit: resourcePermit) { c in
            let before = epoch(), state = try inventory(c)
            let items = try matchBoundItems(inputs, references: references, context: c, state: state)
            guard let binding = try readFile(c.root, "root-binding.json", limit: PackagePreparationCodec.metadataLimit) else {
                throw DevicePackagePreparationError.unsafeBinding
            }
            var bytes: [String: Data] = [:], identities: [String: PreparationIdentity] = [:]
            for name in try names(c.operations, maximum: 260) {
                guard let node = try readFile(c.operations, name, limit: PackagePreparationCodec.metadataLimit) else {
                    throw DevicePackagePreparationError.conflict
                }
                bytes[name] = node.bytes; identities[name] = node.identity
            }
            guard before == epoch() else { throw DevicePackagePreparationError.conflict }
            return NativeBatchOriginal(ObjectIdentifier(self), rootID, before, binding.bytes, binding.identity,
                                       bytes, identities, freshInputs(items))
        }
    }
    private func checkNativeBatchOriginal(_ c: Context, _ original: NativeBatchOriginal) throws {
        guard original.issuer == ObjectIdentifier(self), original.rootID == rootID,
              original.epoch == epoch(),
              try readFile(c.root, "root-binding.json", limit: PackagePreparationCodec.metadataLimit) ==
                Node(identity: original.bindingID, bytes: original.bindingBytes),
              Set(try names(c.operations, maximum: 260)) == Set(original.bytes.keys) else {
            throw DevicePackagePreparationError.conflict
        }
        _ = try inventory(c)
        for (name, bytes) in original.bytes {
            guard let identity = original.identities[name],
                  try readFile(c.operations, name, limit: PackagePreparationCodec.metadataLimit) ==
                    Node(identity: identity, bytes: bytes) else { throw DevicePackagePreparationError.conflict }
        }
        guard original.epoch == epoch() else { throw DevicePackagePreparationError.conflict }
    }
    func verifyNativeBatchOriginal(_ original: NativeBatchOriginal, resourcePermit: DeviceLocalResourcePermit) throws {
        try disk(resourcePermit: resourcePermit) { c in try checkNativeBatchOriginal(c, original) }
    }
    /// Fixed native command only. Reference matching and all capacity/pending branches precede
    /// invalidation/effects; neither a Local plan nor a mutable alias is synthesized.
    func performNativeBoundPackagesExact(_ inputs: [DeviceProvisioningPackageInput], plan: DeviceValidatedNativeProvisioningPlan,
        commandPermit: DeviceNativePackageCommandPermit) throws -> DevicePackageTerminalResolution {
        guard inputs.count <= 12 else { throw DevicePackagePreparationError.sizeLimit }
        let references = try nativeReferences(plan)
        try commandPermit.begin(ObjectIdentifier(self)); defer { commandPermit.end() }
        guard let c = borrowedResourceContext else { throw DeviceLocalResourceGateFailure.invalidScope }
        let state = try inventory(c)
        let items = try matchBoundItems(inputs, references: references, context: c, state: state)
        return try finishBoundItems(c, state: state, items: items)
    }
    /// Gate-private fixed batch dispatch only. No borrowed ordinary mutation API or arbitrary closure.
    func performBoundPackagesExact(_ inputs:[DeviceProvisioningPackageInput],plan:DeviceValidatedProvisioningPlan,
                                  commandPermit:DeviceBoundPackageCommandPermit)throws->DevicePackageTerminalResolution {
        guard inputs.count <= 12 else{throw DevicePackagePreparationError.sizeLimit}
        try commandPermit.begin(ObjectIdentifier(self));defer{commandPermit.end()}
        guard let c=borrowedResourceContext else{throw DeviceLocalResourceGateFailure.invalidScope}
        let state=try inventory(c),items=try boundItems(inputs,plan:plan,context:c,state:state)
        return try finishBoundItems(c, state: state, items: items)
    }
    /// Fixed mixed preparation consumes only the private factory-issued command.
    /// The incoming root is separate from all retained graph roots.
    func performMixedIncomingPackagesExact(_ command: DeviceMixedPreparedCloudCommand,
        commandPermit: DeviceNativePackageCommandPermit) throws -> DevicePackageTerminalResolution {
        try commandPermit.begin(ObjectIdentifier(self)); defer { commandPermit.end() }
        guard let context = borrowedResourceContext, command.packageInputs.count <= 12 else { throw DeviceLocalResourceGateFailure.invalidScope }
        let items = try command.packageInputs.map { input -> BoundItem in
            guard case .supplied(let id, let operationID, let package) = input,
                  let candidate = command.candidate.entries.first(where: { $0.entryID == id }),
                  case .cloud(let entry, _) = candidate,
                  entry.preparedPackage.rootID == rootID,
                  entry.preparedPackage.preparationOperationID == operationID else { throw DevicePackagePreparationError.conflict }
            let request = DevicePackagePreparationRequest(operationID: operationID, package: package)
            let plan = try PackagePreparationCodec.makePlan(request, rootID: rootID, ordinal: 1)
            guard plan.reference == entry.preparedPackage else { throw DevicePackagePreparationError.conflict }
            return BoundItem(entryID: id, reference: entry.preparedPackage, request: request, retained: false)
        }
        guard Set(items.map(\.entryID)).count == items.count, Set(items.map { $0.request.operationID }).count == items.count else { throw DevicePackagePreparationError.conflict }
        return try finishBoundItems(context, state: inventory(context), items: items)
    }
    private func finishBoundItems(_ c: Context, state: Inventory, items: [BoundItem]) throws -> DevicePackageTerminalResolution {
        guard let binding=try readFile(c.root,"root-binding.json",limit:PackagePreparationCodec.metadataLimit),
              binding.bytes == (try PackagePreparationCodec.encode(c.binding)) else{throw DevicePackagePreparationError.unsafeBinding}
        let attemptEpoch=epoch(invalidate:true);qualification=nil;bindingQualified=false
        var completed=false
        defer{if !completed{qualification=nil;bindingQualified=false}}
        // Freshly synchronize the checked owned binding before dependent content effects, including
        // reconstructed stores. Visible setup alone never qualifies an initialized root.
        try syncExisting(c.root,"root-binding.json",expected:binding);try boundary(.afterFileSync(.binding))
        try sync(c.lock);try sync(c.operations);try sync(c.root);try boundary(.afterDirectorySync(.binding));try check(c)
        guard try readFile(c.root,"root-binding.json",limit:PackagePreparationCodec.metadataLimit) == binding,epoch() == attemptEpoch else{throw DevicePackagePreparationError.conflict}
        if let pending=state.entries.first(where:{$0.record.phase != .terminal || $0.staged != nil}) {
            guard let item=items.first(where:{$0.request.operationID == pending.record.plan.operationID}) else{throw DevicePackagePreparationError.conflict}
            if let staged=pending.staged {try replace(c,parent:c.operations,name:filename(item.request.operationID),bytes:staged.bytes,expected:pending.final,kind:pending.record.phase == .terminal ? .terminal:.progress)}
            else if let final=pending.final {try syncExisting(c.operations,filename(item.request.operationID),expected:final);try sync(c.operations)}
            if pending.record.phase != .terminal {_ = try finish(c,record:pending.record,request:item.request,attemptEpoch:attemptEpoch)}
        }
        // Absent packages follow explicit candidate order; historical terminal records are retained.
        var ordinal=state.entries.count
        for item in items where !state.entries.contains(where:{$0.record.plan.operationID == item.request.operationID}) {
            ordinal += 1
            let record=PreparationRecord(plan:try PackagePreparationCodec.makePlan(item.request,rootID:rootID,ordinal:ordinal))
            try replace(c,parent:c.operations,name:filename(item.request.operationID),bytes:PackagePreparationCodec.encode(record),expected:nil,kind:.intent)
            _ = try finish(c,record:record,request:item.request,attemptEpoch:attemptEpoch)
        }
        let after=try inventory(c),selected=try resolutionEntries(items.map(\.reference),state:after)
        // Actual latest is appended by this shared helper even when none of the selected packages is
        // latest. Old receipt records are never promoted to current tip qualification.
        let result=try resolveTerminalSelection(c,state:after,selected:selected,attemptEpoch:attemptEpoch,binding:binding)
        bindingQualified=true;completed=true;return result
    }
    /// Bounded byte/inode preflight only, never acknowledgment or qualification. Used so invalid grant
    /// mappings can reject BEFORE the resolver performs synchronization in either resource domain.
    func inspectRetainedTerminalExact(_ references: [DevicePreparedPackageReference]) throws -> [DeviceVerifiedPreparedPackage] {
        try validateResolutionReferences(references)
        return try disk { context in
            let state = try inventory(context)
            let selected = try resolutionEntries(references,state:state)
            return try selected.map { entry in
                .init(reference:entry.record.plan.reference,
                      package:try checkedPackage(context,record:entry.record,directory:entry.record.plan.leaf,synchronize:false))
            }
        }
    }
    func inspectRetainedTerminalExact(_ references: [DevicePreparedPackageReference], resourcePermit: DeviceLocalResourcePermit) throws -> [DeviceVerifiedPreparedPackage] {
        try validateResolutionReferences(references)
        return try disk(resourcePermit: resourcePermit) { context in
            let selected = try resolutionEntries(references, state: inventory(context))
            return try selected.map { entry in .init(reference: entry.record.plan.reference,
                package: try checkedPackage(context, record: entry.record, directory: entry.record.plan.leaf, synchronize: false)) }
        }
    }
    /// Terminal-only exact durability repair. Never adopts a leaf, unknown orphan or replacement.
    /// Selected retained packages synchronize first; actual latest synchronizes/qualifies last.
    func resolveRetainedTerminalExact(_ references: [DevicePreparedPackageReference]) throws -> DevicePackageTerminalResolution {
        try validateResolutionReferences(references)
        return try disk { context in
            let state = try inventory(context)
            let selected = try resolutionEntries(references,state:state)
            let attemptEpoch = epoch(invalidate:true); qualification = nil; bindingQualified = false
            var completed = false
            defer { if !completed { qualification = nil; bindingQualified = false } }
            guard let binding = try readFile(context.root,"root-binding.json",limit:PackagePreparationCodec.metadataLimit),
                  binding.bytes == (try PackagePreparationCodec.encode(context.binding)) else { throw DevicePackagePreparationError.unsafeBinding }
            let result=try resolveTerminalSelection(context,state:state,selected:selected,attemptEpoch:attemptEpoch,binding:binding)
            bindingQualified=true;completed=true
            return result
        }
    }
    /// Fixed read preflight for the native credential command. Validates all original and
    /// terminal branches without synchronization, renewal, callbacks or mutation dispatch.
    func verifyNativeTerminalBatchOriginal(_ original: NativeBatchOriginal,
        references: [DevicePreparedPackageReference], resourcePermit: DeviceLocalResourcePermit) throws {
        try validateResolutionReferences(references)
        try disk(resourcePermit: resourcePermit) { c in
            try checkNativeBatchOriginal(c, original)
            let state = try inventory(c), selected = try resolutionEntries(references, state: state)
            for entry in selected {
                _ = try checkedPackage(c, record: entry.record, directory: entry.record.plan.leaf, synchronize: false)
            }
            try checkNativeBatchOriginal(c, original)
        }
    }
    /// Exact original-to-new terminal repair. The earlier captured inventory is checked under
    /// this same disk lock before any epoch/sync. No absent/pending package is created or adopted.
    func resolveRetainedTerminalExact(_ references: [DevicePreparedPackageReference],
        original: NativeBatchOriginal) throws -> DevicePackageTerminalResolution {
        try validateResolutionReferences(references)
        return try disk { context in
            try checkNativeBatchOriginal(context, original)
            let state = try inventory(context)
            let selected = try resolutionEntries(references, state: state)
            guard let binding = try readFile(context.root, "root-binding.json", limit: PackagePreparationCodec.metadataLimit),
                  binding.bytes == (try PackagePreparationCodec.encode(context.binding)) else {
                throw DevicePackagePreparationError.unsafeBinding
            }
            // All mappings, stages, terminal branches and original evidence precede invalidation.
            try checkNativeBatchOriginal(context, original)
            let attemptEpoch = epoch(invalidate: true); qualification = nil; bindingQualified = false
            var completed = false
            defer { if !completed { qualification = nil; bindingQualified = false } }
            let result = try resolveTerminalSelection(context, state: state, selected: selected,
                attemptEpoch: attemptEpoch, binding: binding)
            bindingQualified = true; completed = true
            return result
        }
    }
    /// Same selected-first/actual-latest-last synchronization used by the ordinary resolver and fixed
    /// batch. Caller owns qualification failure cleanup and supplies its ORIGINAL checked binding.
    private func resolveTerminalSelection(_ context:Context,state:Inventory,selected:[Entry],attemptEpoch:UInt64,binding:Node)throws->DevicePackageTerminalResolution {
        try syncExisting(context.root,"root-binding.json",expected:binding); try boundary(.afterFileSync(.binding))
        try sync(context.lock); try sync(context.operations); try sync(context.root)
        try boundary(.afterDirectorySync(.binding)); try check(context)
        var ordered = selected.filter { $0.record.plan.operationID != state.tip?.record.plan.operationID }
        if let tip = state.tip { ordered.append(tip) }
        for entry in ordered {
            guard let proof = entry.final else { throw DevicePackagePreparationError.conflict }
            _ = try checkedPackage(context,record:entry.record,directory:entry.record.plan.leaf,synchronize:true)
            try boundary(.afterFileSync(.install)); try sync(context.root)
            try syncExisting(context.operations,filename(entry.record.plan.operationID),expected:proof)
            try boundary(.afterReplace(.terminal)); try sync(context.operations); try boundary(.afterDirectorySync(.terminal))
    }
        let after = try inventory(context)
        guard after.entries.count == state.entries.count, after.tip?.final == state.tip?.final,
              !after.hasStages, epoch() == attemptEpoch else { throw DevicePackagePreparationError.repairRequired }
        if let tip = after.tip, let final = tip.final { qualification = (attemptEpoch,final) }
        let receipts = try selected.map { try receipt(context,record:$0.record,attemptEpoch:attemptEpoch) }
        let final = try inventory(context)
        guard final.tip?.final == after.tip?.final, !final.hasStages, epoch() == attemptEpoch,
              try readFile(context.root,"root-binding.json",limit:PackagePreparationCodec.metadataLimit) == binding else { throw DevicePackagePreparationError.repairRequired }
        let checkpoint = DevicePackageResolutionCheckpoint(issuer:ObjectIdentifier(self),rootID:rootID,epoch:attemptEpoch,
            tipIdentity:final.tip?.final?.identity,tipBytes:final.tip?.final?.bytes,bindingIdentity:binding.identity,bindingBytes:binding.bytes)
        return DevicePackageTerminalResolution(receipts,checkpoint:checkpoint)
    }
    /// Requires the ORIGINAL repair snapshot. Never reconstructs it from current qualification.
    func verifyResolutionCheckpoint(_ checkpoint:DevicePackageResolutionCheckpoint, resourcePermit:DeviceLocalResourcePermit) throws {
        try disk(resourcePermit:resourcePermit) { context in
            guard checkpoint.issuer == ObjectIdentifier(self),checkpoint.rootID == rootID,
                  checkpoint.epoch == epoch(),bindingQualified else { throw DevicePackagePreparationError.repairRequired }
            let state = try inventory(context)
            guard !state.hasStages,state.entries.allSatisfy({$0.record.phase == .terminal}),
                  state.tip?.final?.identity == checkpoint.tipIdentity,state.tip?.final?.bytes == checkpoint.tipBytes,
                  try readFile(context.root,"root-binding.json",limit:PackagePreparationCodec.metadataLimit) == Node(identity:checkpoint.bindingIdentity,bytes:checkpoint.bindingBytes) else { throw DevicePackagePreparationError.conflict }
            if let tip = state.tip?.final { try requireQualification(tip) }
            else { guard state.entries.isEmpty,checkpoint.tipIdentity == nil,checkpoint.tipBytes == nil else { throw DevicePackagePreparationError.conflict } }
            guard checkpoint.epoch == epoch() else { throw DevicePackagePreparationError.repairRequired }
        }
    }
    private func validateResolutionReferences(_ references: [DevicePreparedPackageReference]) throws {
        guard references.count <= 24 else { throw DevicePackagePreparationError.sizeLimit }
        var operations = Set<UUID>()
        for ref in references {
            guard ref.rootID == rootID, operations.insert(ref.preparationOperationID).inserted,
                  ref.contentID.utf8.count == 64, ref.directory.utf8.count <= 256 else { throw DevicePackagePreparationError.conflict }
        }
    }
    private func resolutionEntries(_ references: [DevicePreparedPackageReference], state: Inventory) throws -> [Entry] {
        guard !state.hasStages, state.entries.allSatisfy({$0.record.phase == .terminal}) else { throw DevicePackagePreparationError.repairRequired }
        return try references.map { ref in
            guard let entry = state.entries.first(where:{$0.record.plan.operationID == ref.preparationOperationID}),
                  entry.record.plan.rootID == ref.rootID,
                  entry.record.plan.contentID.utf8.elementsEqual(ref.contentID.utf8),
                  entry.record.plan.leaf.utf8.elementsEqual(ref.directory.utf8) else { throw DevicePackagePreparationError.conflict }
            return entry
        }
    }
    /// Never synchronizes/acknowledges a visible terminal. Requires private issued proof and current gate.
    func verify(_ receipt: DevicePreparedPackageReceipt) throws -> DeviceVerifiedPreparedPackage {
        try verifyRead(receipt,resourcePermit:nil)
    }
    func verify(_ receipt: DevicePreparedPackageReceipt, resourcePermit: DeviceLocalResourcePermit) throws -> DeviceVerifiedPreparedPackage {
        try verifyRead(receipt,resourcePermit:resourcePermit)
    }
    private func verifyRead(_ receipt: DevicePreparedPackageReceipt, resourcePermit: DeviceLocalResourcePermit?) throws -> DeviceVerifiedPreparedPackage {
        try disk(resourcePermit:resourcePermit) { context in
            let state = try inventory(context)
            guard receipt.issuer == ObjectIdentifier(self), !state.hasStages,
                  state.entries.allSatisfy({ $0.record.phase == .terminal }), let tip = state.tip?.final else { throw DevicePackagePreparationError.repairRequired }
            try requireQualification(tip)
            guard let entry = state.entries.first(where: { $0.record.plan.reference == receipt.reference }),
                  entry.final == Node(identity: receipt.recordIdentity, bytes: receipt.recordBytes) else { throw DevicePackagePreparationError.conflict }
            let package = try checkedPackage(context, record: entry.record, directory: entry.record.plan.leaf, synchronize: false)
            try check(context); let after = try inventory(context)
            guard after.tip?.final == tip else { throw DevicePackagePreparationError.conflict }
            try requireQualification(tip)
            return .init(reference: receipt.reference, package: package)
        }
    }
    private func requireQualification(_ tip: Node) throws {
        guard let qualified = qualification, qualified.epoch == epoch(), qualified.tip == tip else { throw DevicePackagePreparationError.repairRequired }
    }
    private func receipt(_ context: Context, record: PreparationRecord, attemptEpoch: UInt64) throws -> DevicePreparedPackageReceipt {
        let state = try inventory(context)
        guard let entry = state.entries.first(where: { $0.record.plan.operationID == record.plan.operationID }),
              entry.record == record, entry.record.phase == .terminal, entry.staged == nil, let final = entry.final else { throw DevicePackagePreparationError.conflict }
        if state.tip?.record.plan.operationID == record.plan.operationID, !state.hasStages,
           state.entries.allSatisfy({ $0.record.phase == .terminal }) { qualification = (attemptEpoch, final) }
        return .init(reference: record.plan.reference, issuer: ObjectIdentifier(self), recordBytes: final.bytes, recordIdentity: final.identity)
    }
    private func finish(_ context: Context, record initial: PreparationRecord, request: DevicePackagePreparationRequest, attemptEpoch: UInt64) throws -> DevicePreparedPackageReceipt {
        var record = initial
        let name = filename(request.operationID)
        guard try PackagePreparationCodec.encode(record.plan) == PackagePreparationCodec.encode(PackagePreparationCodec.makePlan(request, rootID: rootID, ordinal: record.plan.ordinal)) else { throw DevicePackagePreparationError.conflict }
        if record.phase == .intent {
            let key = captureKey(request.operationID, "")
            let stage = try directory(context.root, record.plan.stage, expected: captured[key], create: captured[key] == nil, onCreate: { captured[key] = $0 })
            defer { close(stage) }
            let identity = try identity(stage, directory: true)
            try boundary(.afterCreate(.directory)); try check(context)
            record.directoryIdentity = identity; record.phase = .prepared
            try persist(context, record: record, name: name, kind: .progress)
        }
        // Rename uncertainty: the exact recorded inode may already be installed. Never recreate it.
        if let final = try directoryIdentity(context.root, record.plan.leaf) {
            guard final == record.directoryIdentity, try directoryIdentity(context.root, record.plan.stage) == nil else { throw DevicePackagePreparationError.conflict }
            _ = try checkedPackage(context, record: record, directory: record.plan.leaf, synchronize: true)
            try sync(context.root)
        } else {
            guard let stageIdentity = record.directoryIdentity else { throw DevicePackagePreparationError.conflict }
            let stage = try directory(context.root, record.plan.stage, expected: stageIdentity, create: false)
            defer { close(stage) }
            for (index, path) in record.plan.directories.enumerated() {
                let parent = try parent(stage, path: path, record: record); defer { close(parent) }
                let leaf = path.split(separator: "/").last.map(String.init)!
                let key = captureKey(request.operationID, path + "/")
                let child = try directory(parent, leaf, expected: record.directoryIdentities[index] ?? captured[key],
                    create: record.directoryIdentities[index] == nil && captured[key] == nil, onCreate: { captured[key] = $0 })
                defer { close(child) }
                let found = try identity(child, directory: true)
                if record.directoryIdentities[index] == nil {
                    try boundary(.afterCreate(.directory)); record.directoryIdentities[index] = found
                    try persist(context, record: record, name: name, kind: .progress)
                }
            }
            var content = Dictionary(uniqueKeysWithValues: request.package.files.map { ($0.path, $0.bytes) })
            content["manifest.json"] = request.package.originalManifestBytes
            for (index, file) in record.plan.files.enumerated() {
                let parent = try parent(stage, path: file.path, record: record); defer { close(parent) }
                let leaf = file.path.split(separator: "/").last.map(String.init)!
                let key = captureKey(request.operationID, file.path)
                var fd: Int32 = -1
                defer { if fd >= 0 { close(fd) } }
                if let expected = record.fileIdentities[index] ?? captured[key] {
                    fd = openat(parent, leaf, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
                    guard fd >= 0 else { throw failure() }
                    guard try identity(fd, directory: false) == expected else { throw DevicePackagePreparationError.conflict }
                } else {
                    fd = openat(parent, leaf, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
                    guard fd >= 0 else { throw failure() }
                    // Ownership encloses every throwing identity check and write below.
                }
                let found = try identity(fd, directory: false)
                captured[key] = found
                if record.fileIdentities[index] == nil {
                    try boundary(.afterCreate(.file)); record.fileIdentities[index] = found
                    try persist(context, record: record, name: name, kind: .progress)
                }
                guard let bytes = content[file.path], bytes.count == file.bytes, try PackagePreparationCodec.hash(bytes) == file.sha256 else { throw DevicePackagePreparationError.conflict }
                guard let existing = try readFile(parent, leaf, limit: file.bytes), existing.identity == found,
                      bytes.starts(with: existing.bytes), existing.bytes.count <= bytes.count else { throw DevicePackagePreparationError.conflict }
                guard lseek(fd, off_t(existing.bytes.count), SEEK_SET) >= 0 else { throw failure() }
                try writeAll(fd, bytes, offset: existing.bytes.count); try boundary(.afterWrite(.file)); try check(context)
                try sync(fd); try boundary(.afterFileSync(.file))
                guard try readFile(parent, leaf, limit: file.bytes) == Node(identity: found, bytes: bytes) else { throw DevicePackagePreparationError.conflict }
            }
            // Verify exact inventory and bytes before dependent rename, then synchronize owned subtree.
            _ = try checkedPackage(context, record: record, directory: record.plan.stage, synchronize: true)
            try boundary(.beforeReplace(.install)); try check(context)
            guard try directoryIdentity(context.root, record.plan.stage) == stageIdentity,
                  try directoryIdentity(context.root, record.plan.leaf) == nil else { throw DevicePackagePreparationError.conflict }
            guard renameat(context.root, record.plan.stage, context.root, record.plan.leaf) == 0 else { throw failure() }
            try boundary(.afterReplace(.install)); try sync(context.root); try boundary(.afterDirectorySync(.install))
            guard try directoryIdentity(context.root, record.plan.leaf) == stageIdentity else { throw DevicePackagePreparationError.conflict }
        }
        record.phase = .terminal
        try persist(context, record: record, name: name, kind: .terminal)
        try check(context)
        return try receipt(context, record: record, attemptEpoch: attemptEpoch)
    }
    private func persist(_ context: Context, record: PreparationRecord, name: String, kind: Kind) throws {
        let bytes = try PackagePreparationCodec.encode(record)
        _ = try PackagePreparationCodec.record(bytes)
        let old = try readFile(context.operations, name, limit: PackagePreparationCodec.metadataLimit)
        try replace(context, parent: context.operations, name: name, bytes: bytes, expected: old, kind: kind)
    }
    private func filename(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }
    private func captureKey(_ id: UUID, _ path: String) -> String { id.uuidString + ":" + path }
    private func inventory(_ context: Context) throws -> Inventory {
        try check(context)
        guard try readFile(context.root, "root-binding.json.pending", limit: PackagePreparationCodec.metadataLimit) == nil else { throw DevicePackagePreparationError.repairRequired }
        var finals: [UUID: (PreparationRecord, Node)] = [:]; var stages: [UUID: (PreparationRecord, Node)] = [:]
        for name in try names(context.operations, maximum: 260) {
            let staged = name.hasSuffix(".json.pending"); let base = staged ? String(name.dropLast(8)) : name
            guard base.hasSuffix(".json"), let id = UUID(uuidString: String(base.dropLast(5))), base == filename(id),
                  let node = try readFile(context.operations, name, limit: PackagePreparationCodec.metadataLimit) else { throw DevicePackagePreparationError.conflict }
            let record = try PackagePreparationCodec.record(node.bytes)
            guard record.plan.operationID == id, record.plan.rootID == rootID else { throw DevicePackagePreparationError.conflict }
            if staged { stages[id] = (record, node) } else { finals[id] = (record, node) }
        }
        var entries: [Entry] = []
        for id in Set(finals.keys).union(stages.keys) {
            let final = finals[id]; let staged = stages[id]
            if let final, let staged { guard staged.0.progresses(final.0) else { throw DevicePackagePreparationError.conflict } }
            guard let record = staged?.0 ?? final?.0 else { throw DevicePackagePreparationError.conflict }
            if final == nil { guard record.phase == .intent else { throw DevicePackagePreparationError.conflict } }
            entries.append(.init(record: record, final: final?.1, staged: staged?.1))
        }
        guard entries.count <= 129, entries.filter({ $0.record.phase != .terminal }).count <= 1,
              entries.filter({ $0.record.phase == .terminal }).count <= 128 else { throw DevicePackagePreparationError.capacity }
        entries.sort { $0.record.plan.ordinal < $1.record.plan.ordinal }
        guard entries.enumerated().allSatisfy({ $0.element.record.plan.ordinal == $0.offset + 1 }),
              Set(entries.map { $0.record.plan.contentID }).count == entries.count,
              entries.dropLast().allSatisfy({ $0.record.phase == .terminal }) else { throw DevicePackagePreparationError.conflict }
        var allowed: Set<String> = ["root-binding.json", "root-binding.json.pending", "preparation.lock", "operations"]
        for entry in entries {
            let record = entry.record
            let staged = try directoryIdentity(context.root, record.plan.stage)
            let final = try directoryIdentity(context.root, record.plan.leaf)
            if record.phase == .terminal {
                guard staged == nil, final == record.directoryIdentity else { throw DevicePackagePreparationError.conflict }
                _ = try checkedPackage(context, record: record, directory: record.plan.leaf, synchronize: false)
            } else if record.phase == .prepared {
                guard (staged == record.directoryIdentity && final == nil) || (final == record.directoryIdentity && staged == nil) else { throw DevicePackagePreparationError.conflict }
            } else { guard final == nil else { throw DevicePackagePreparationError.conflict } }
            allowed.insert(record.plan.stage); allowed.insert(record.plan.leaf)
        }
        guard Set(try names(context.root, maximum: 256)).isSubset(of: allowed) else { throw DevicePackagePreparationError.conflict }
        try check(context); return .init(entries: entries)
    }
    private func checkedPackage(_ context: Context, record: PreparationRecord, directory name: String, synchronize: Bool) throws -> QualifiedDevicePackage {
        guard let expectedRoot = record.directoryIdentity, record.fileIdentities.allSatisfy({ $0 != nil }), record.directoryIdentities.allSatisfy({ $0 != nil }) else { throw DevicePackagePreparationError.conflict }
        let package = try directory(context.root, name, expected: expectedRoot, create: false); defer { close(package) }
        let allPaths = record.plan.files.map(\.path) + record.plan.directories
        for path in [""] + record.plan.directories {
            let fd = path.isEmpty ? dup(package) : try openDirectory(package, path: path, record: record)
            guard fd >= 0 else { throw failure() }; defer { close(fd) }
            let prefix = path.isEmpty ? "" : path + "/"
            let children = Set(allPaths.filter { $0.hasPrefix(prefix) }.compactMap { value -> String? in
                let remainder = String(value.dropFirst(prefix.count)); return remainder.split(separator: "/").first.map(String.init)
            })
            guard Set(try names(fd, maximum: 6097)) == children else { throw DevicePackagePreparationError.conflict }
        }
        var files: [DevicePackageFile] = []; var manifest: Data?
        for (index, file) in record.plan.files.enumerated() {
            let parent = try parent(package, path: file.path, record: record); defer { close(parent) }
            let leaf = file.path.split(separator: "/").last.map(String.init)!
            guard let node = try readFile(parent, leaf, limit: file.bytes), node.identity == record.fileIdentities[index],
                  node.bytes.count == file.bytes, try PackagePreparationCodec.hash(node.bytes) == file.sha256 else { throw DevicePackagePreparationError.conflict }
            if synchronize { try syncExisting(parent, leaf, expected: node) }
            if file.path == "manifest.json" { manifest = node.bytes } else { files.append(.init(path: file.path, bytes: node.bytes)) }
        }
        guard let manifest else { throw DevicePackagePreparationError.conflict }
        let revision = record.plan.revision
        let expected = DevicePackageExpectation(revision: revision,
            target: .init(deviceId: record.plan.profileID, name: "Byte verification only", orientation: revision.orientation, width: revision.width, height: revision.height), profileID: record.plan.profileID)
        let qualified = try DevicePackageQualifier.qualify(.init(manifest: manifest, files: files), expected: expected)
        // The profile above checks declared viewport bytes, not real device identity/admission.
        if synchronize {
            for path in record.plan.directories.reversed() {
                let fd = try openDirectory(package, path: path, record: record); defer { close(fd) }; try sync(fd)
            }
            try sync(package); try boundary(.afterDirectorySync(.directory))
        }
        guard try directoryIdentity(context.root, name) == expectedRoot else { throw DevicePackagePreparationError.conflict }
        try check(context); return qualified
    }
    private func parent(_ package: Int32, path: String, record: PreparationRecord) throws -> Int32 {
        let parts = path.split(separator: "/").dropLast()
        return try openDirectory(package, path: parts.joined(separator: "/"), record: record)
    }
    private func openDirectory(_ base: Int32, path: String, record: PreparationRecord) throws -> Int32 {
        var fd = dup(base); guard fd >= 0 else { throw failure() }
        do {
            var prefix = ""
            for part in path.split(separator: "/") {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                guard let index = record.plan.directories.firstIndex(of: prefix), let expected = record.directoryIdentities[index] else { throw DevicePackagePreparationError.conflict }
                let child = try directory(fd, String(part), expected: expected, create: false)
                close(fd); fd = child
            }
            return fd
        } catch { close(fd); throw error }
    }
    private func directory(_ parent: Int32, _ name: String, expected: PreparationIdentity?, create: Bool,
                           onCreate: (PreparationIdentity) -> Void = { _ in }) throws -> Int32 {
        if create {
            guard mkdirat(parent, name, 0o700) == 0 else { throw failure() }
        } else { guard expected != nil else { throw DevicePackagePreparationError.conflict } }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }
        do {
            let found = try identity(fd, directory: true)
            if let expected { guard found == expected else { throw DevicePackagePreparationError.conflict } }
            if create { onCreate(found) }
            return fd
        } catch { close(fd); throw error }
    }
    private func directoryIdentity(_ parent: Int32, _ name: String) throws -> PreparationIdentity? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw failure() }; defer { close(fd) }
        return try identity(fd, directory: true)
    }
    private func protectedPaths() throws -> [String] {
        guard root.isFileURL, root.path != "/", root.path.utf8.count <= 4096,
              scope.otherProtectedRoots.count <= 32 else { throw DevicePackagePreparationError.unsafeBinding }
        var result: [String] = []
        for url in scope.roots {
            let path = url.path
            guard url.isFileURL, !path.isEmpty, path.utf8.count <= 4096 else { throw DevicePackagePreparationError.unsafeBinding }
            let protected = try absoluteDirectory(path, allowMissing: true)
            if protected >= 0 { close(protected) }
            guard path != "/", root.path != path, !root.path.hasPrefix(path + "/"), !path.hasPrefix(root.path + "/") else { throw DevicePackagePreparationError.scopeOverlap }
            result.append(path)
        }
        return result
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
        let paths = try protectedPaths()
        let rootFD = try absoluteDirectory(root.path); defer { close(rootFD) }
        let rootIdentity = try identity(rootFD, directory: true)
        let bindingExists = try readFile(rootFD, "root-binding.json", limit: PackagePreparationCodec.metadataLimit) != nil
        if create && !bindingExists {
            let names = try names(rootFD, maximum: 256)
            if !names.isEmpty {
                guard setupRoot == rootIdentity, Set(names).isSubset(of: ["preparation.lock", "operations", "root-binding.json.pending"]) else { throw DevicePackagePreparationError.conflict }
            }
            setupRoot = rootIdentity
        }
        let lockFD = openat(rootFD, "preparation.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | (create && !bindingExists ? O_CREAT | O_EXCL : 0), 0o600)
        let lock: Int32
        if lockFD < 0 && create && !bindingExists && errno == EEXIST && setupLock != nil {
            lock = openat(rootFD, "preparation.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK)
        } else { lock = lockFD }
        guard lock >= 0 else { throw failure() }; defer { close(lock) }
        let lockIdentity = try identity(lock, directory: false)
        if create && !bindingExists {
            if let expected = setupLock { guard expected == lockIdentity else { throw DevicePackagePreparationError.conflict } }
            setupLock = lockIdentity
        }
        guard flock(lock, LOCK_EX) == 0 else { throw failure() }; defer { releasePermit?.invalidate(); flock(lock, LOCK_UN) }
        if create && !bindingExists {
            if mkdirat(rootFD, "operations", 0o700) != 0 { guard errno == EEXIST && setupOperations != nil else { throw failure() } }
        }
        let ops = openat(rootFD, "operations", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard ops >= 0 else { throw failure() }; defer { close(ops) }
        let opsIdentity = try identity(ops, directory: true)
        if create && !bindingExists {
            if let expected = setupOperations { guard expected == opsIdentity else { throw DevicePackagePreparationError.conflict } }
            setupOperations = opsIdentity
        }
        let binding = Binding(schemaVersion: 1, rootID: rootID, rootPath: root.path, protectedPaths: paths,
            rootIdentity: rootIdentity, lockIdentity: lockIdentity, operationsIdentity: opsIdentity)
        let context = Context(root: rootFD, lock: lock, operations: ops, binding: binding)
        if !create || bindingExists {
            guard let existing = try readFile(rootFD, "root-binding.json", limit: PackagePreparationCodec.metadataLimit), existing.bytes == (try PackagePreparationCodec.encode(binding)) else { throw DevicePackagePreparationError.unsafeBinding }
        }
        try check(context, allowMissingBinding: create && !bindingExists)
        return try operation(context)
    }
    private func check(_ context: Context, allowMissingBinding: Bool = false) throws {
        guard try protectedPaths() == context.binding.protectedPaths else { throw DevicePackagePreparationError.unsafeBinding }
        let fd = try absoluteDirectory(root.path); defer { close(fd) }
        guard try identity(fd, directory: true) == context.binding.rootIdentity,
              try identity(context.root, directory: true) == context.binding.rootIdentity,
              try identity(context.lock, directory: false) == context.binding.lockIdentity,
              try directoryIdentity(context.root, "operations") == context.binding.operationsIdentity else { throw DevicePackagePreparationError.unsafeBinding }
        guard let lock = try readFile(context.root, "preparation.lock", limit: 0), lock.identity == context.binding.lockIdentity else { throw DevicePackagePreparationError.unsafeBinding }
        if let binding = try readFile(context.root, "root-binding.json", limit: PackagePreparationCodec.metadataLimit) {
            guard binding.bytes == (try PackagePreparationCodec.encode(context.binding)) else { throw DevicePackagePreparationError.unsafeBinding }
        } else if !allowMissingBinding { throw DevicePackagePreparationError.unsafeBinding }
    }
    private func absoluteDirectory(_ path: String, allowMissing: Bool = false) throws -> Int32 {
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), path.utf8.count <= 4096, parts.count <= 64,
              !parts.contains(where: { $0 == "." || $0 == ".." }), !path.contains("//") else { throw DevicePackagePreparationError.unsafeBinding }
        let traversal: DeviceFilesystemTraversal
        do { traversal = try .plan(for: path) } catch { throw DevicePackagePreparationError.unsafeBinding }
        var fd = open(traversal.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure() }
        for part in traversal.components {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            if next < 0 {
                let error = errno; close(fd)
                if allowMissing && error == ENOENT { return -1 }
                throw DevicePackagePreparationError.io(error)
            }
            close(fd); fd = next
        }
        return fd
    }
    private func identity(_ fd: Int32, directory: Bool) throws -> PreparationIdentity {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw failure() }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw DevicePackagePreparationError.unsafeBinding }
        return .init(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }
    private func names(_ fd: Int32, maximum: Int) throws -> [String] {
        let duplicate = dup(fd); guard duplicate >= 0 else { throw failure() }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw failure() }; defer { closedir(stream) }
        rewinddir(stream); var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw failure() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            result.append(name); guard result.count <= maximum else { throw DevicePackagePreparationError.capacity }
        }
        return result
    }
    private func readFile(_ parent: Int32, _ name: String, limit: Int) throws -> Node? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw failure() }; defer { close(fd) }
        let found = try identity(fd, directory: false)
        var info = stat(); guard fstat(fd, &info) == 0 else { throw failure() }
        guard info.st_size >= 0, info.st_size <= limit else { throw DevicePackagePreparationError.sizeLimit }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw failure() }
            if count == 0 { break }
            guard count <= limit - bytes.count else { throw DevicePackagePreparationError.sizeLimit }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count == info.st_size, try identity(fd, directory: false) == found else { throw DevicePackagePreparationError.conflict }
        let current = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard current >= 0 else { throw failure() }; defer { close(current) }
        guard try identity(current, directory: false) == found else { throw DevicePackagePreparationError.conflict }
        return .init(identity: found, bytes: bytes)
    }
    private func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw failure() } }
    private func syncExisting(_ parent: Int32, _ name: String, expected: Node) throws {
        guard try readFile(parent, name, limit: PackagePreparationCodec.metadataLimit > expected.bytes.count ? PackagePreparationCodec.metadataLimit : expected.bytes.count) == expected else { throw DevicePackagePreparationError.conflict }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        guard try identity(fd, directory: false) == expected.identity else { throw DevicePackagePreparationError.conflict }
        try sync(fd)
        guard try readFile(parent, name, limit: max(PackagePreparationCodec.metadataLimit, expected.bytes.count)) == expected else { throw DevicePackagePreparationError.conflict }
    }
    private func writeAll(_ fd: Int32, _ bytes: Data, offset: Int = 0) throws {
        try bytes.withUnsafeBytes { raw in
            var position = offset
            while position < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: position), raw.count - position)
                if count < 0 { if errno == EINTR { continue }; throw failure() }
                guard count > 0 else { throw failure() }; position += count
            }
        }
    }
    private func replace(_ context: Context, parent: Int32, name: String, bytes: Data, expected: Node?, kind: Kind) throws {
        let temporary = name + ".pending"
        var fd = openat(parent, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_NONBLOCK, 0o600)
        defer { if fd >= 0 { close(fd) } }
        // Metadata staging is exact retry evidence, not installed package provenance.
        // Its inode may be freshly observed across restart; package inode bindings remain persistent.
        if fd < 0 && errno == EEXIST {
            guard let prior = try readFile(parent, temporary, limit: PackagePreparationCodec.metadataLimit), prior.bytes == bytes else { throw DevicePackagePreparationError.conflict }
            fd = openat(parent, temporary, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0, try identity(fd, directory: false) == prior.identity else { throw DevicePackagePreparationError.conflict }
        } else { guard fd >= 0 else { throw failure() }; try writeAll(fd, bytes) }
        let stagedIdentity = try identity(fd, directory: false)
        do {
            try boundary(.afterWrite(kind)); try check(context, allowMissingBinding: kind == .binding)
            try sync(fd); try boundary(.afterFileSync(kind)); try check(context, allowMissingBinding: kind == .binding)
            try boundary(.beforeReplace(kind))
            guard try readFile(parent, name, limit: PackagePreparationCodec.metadataLimit) == expected,
                  try readFile(parent, temporary, limit: PackagePreparationCodec.metadataLimit) == Node(identity: stagedIdentity, bytes: bytes) else { throw DevicePackagePreparationError.conflict }
            guard renameat(parent, temporary, parent, name) == 0 else { throw failure() }
            try boundary(.afterReplace(kind)); try sync(parent); try boundary(.afterDirectorySync(kind))
            guard try readFile(parent, name, limit: PackagePreparationCodec.metadataLimit) == Node(identity: stagedIdentity, bytes: bytes) else { throw DevicePackagePreparationError.conflict }
            try check(context)
        } catch let error as DevicePackagePreparationError {
            if error == .conflict || error == .unsafeBinding { throw error }; throw DevicePackagePreparationError.outcomeUncertain
        } catch { throw DevicePackagePreparationError.outcomeUncertain }
    }
    private func failure() -> DevicePackagePreparationError { .io(errno) }
}
