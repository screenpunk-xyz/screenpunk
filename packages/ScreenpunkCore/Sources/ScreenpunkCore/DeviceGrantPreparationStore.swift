import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Nonsecret exact repair snapshot only. Fields/constructor remain in this store file; not authority.
final class DeviceGrantResolutionCheckpoint {
    fileprivate let issuer:ObjectIdentifier
    fileprivate let rootID:UUID
    fileprivate let epoch:UInt64
    fileprivate let tipIdentity:GrantDiskIdentity
    fileprivate let tipBytes:Data
    fileprivate let headIdentity:GrantDiskIdentity
    fileprivate let headBytes:Data
    fileprivate let bindingIdentity:GrantDiskIdentity
    fileprivate let bindingBytes:Data
    fileprivate init(issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,tipIdentity:GrantDiskIdentity,tipBytes:Data,
                     headIdentity:GrantDiskIdentity,headBytes:Data,bindingIdentity:GrantDiskIdentity,bindingBytes:Data) {
        self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;self.tipIdentity=tipIdentity;self.tipBytes=tipBytes
        self.headIdentity=headIdentity;self.headBytes=headBytes;self.bindingIdentity=bindingIdentity;self.bindingBytes=bindingBytes
    }
}
final class DeviceGrantTerminalResolution {
    let receipts:[DevicePreparedGrantReceipt]
    let checkpoint:DeviceGrantResolutionCheckpoint
    fileprivate init(_ receipts:[DevicePreparedGrantReceipt],checkpoint:DeviceGrantResolutionCheckpoint) {
        self.receipts=receipts;self.checkpoint=checkpoint
    }
}
final class DevicePreparedGrantReceipt: GrantSecretRedacted {
    let operationID: UUID
    let identity: DeviceGrantRevisionIdentity
    fileprivate let issuer: ObjectIdentifier
    fileprivate let privateBytes: Data
    fileprivate let terminal: GrantDiskIdentity
    fileprivate init(operationID: UUID, identity: DeviceGrantRevisionIdentity, issuer: ObjectIdentifier, privateBytes: Data, terminal: GrantDiskIdentity) {
        self.operationID = operationID; self.identity = identity; self.issuer = issuer; self.privateBytes = privateBytes; self.terminal = terminal
    }
}
/// Private-attempt-only evidence. Neither a completed grant receipt nor runtime authority.
final class DeviceBoundGrantPrivateAttempt:GrantSecretRedacted {
    let operationID:UUID
    fileprivate let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,recordIdentity:GrantDiskIdentity,recordBytes:Data
    fileprivate let item:DeviceGrantCredentialItem,privateBytes:Data,bindingIdentity:GrantDiskIdentity,bindingBytes:Data
    fileprivate let staged:Bool
    fileprivate init(issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,node:GrantHeadEvidence,item:DeviceGrantCredentialItem,bytes:Data,binding:GrantHeadEvidence,operationID:UUID,staged:Bool=false) {
        self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;recordIdentity=node.identity;recordBytes=node.bytes
        self.item=item;privateBytes=bytes;bindingIdentity=binding.identity;bindingBytes=binding.bytes;self.operationID=operationID;self.staged=staged
    }
}
/// Credential progress only: original private anchor -> exact final record/epoch. No terminal authority.
final class DeviceBoundGrantCredentialTransition:GrantSecretRedacted {
    fileprivate let original:DeviceBoundGrantPrivateAttempt,epoch:UInt64,node:GrantHeadEvidence
    fileprivate init(original:DeviceBoundGrantPrivateAttempt,epoch:UInt64,node:GrantHeadEvidence) {
        self.original=original;self.epoch=epoch;self.node=node
    }
}
/// Finite original absent/present evidence, not a sync acknowledgment.
fileprivate struct BoundGrantNodeEvidence:Equatable {
    let root:Bool,name:String,node:GrantHeadEvidence?
}
final class DeviceBoundGrantTerminalRecovery:GrantSecretRedacted {
    let operationID:UUID
    let packages:[DeviceRetainedEntryPackageBinding]
    fileprivate let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,item:DeviceGrantCredentialItem,privateBytes:Data,intent:Data
    fileprivate let nodes:[BoundGrantNodeEvidence],previousHead:GrantHeadEvidence?
    fileprivate init(operationID:UUID,packages:[DeviceRetainedEntryPackageBinding],issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,
                     item:DeviceGrantCredentialItem,privateBytes:Data,intent:Data,nodes:[BoundGrantNodeEvidence],previousHead:GrantHeadEvidence?) {
        self.operationID=operationID;self.packages=packages;self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;self.item=item
        self.privateBytes=privateBytes;self.intent=intent;self.nodes=nodes;self.previousHead=previousHead
    }
}
final class DeviceBoundGrantTerminalTransition:GrantSecretRedacted {
    fileprivate let original:DeviceBoundGrantTerminalRecovery,epoch:UInt64,nodes:[BoundGrantNodeEvidence]
    fileprivate init(original:DeviceBoundGrantTerminalRecovery,epoch:UInt64,nodes:[BoundGrantNodeEvidence]){self.original=original;self.epoch=epoch;self.nodes=nodes}
}
final class DeviceBoundGrantRecoveryPlan:GrantSecretRedacted {
    let plan:DeviceValidatedProvisioningPlan
    fileprivate let checkpoint:DeviceBoundGrantPrivateAttempt,request:DeviceGrantPreparationRequest
    fileprivate init(plan:DeviceValidatedProvisioningPlan,checkpoint:DeviceBoundGrantPrivateAttempt,request:DeviceGrantPreparationRequest) {
        self.plan=plan;self.checkpoint=checkpoint;self.request=request
    }
}
struct DeviceVerifiedGrantPreparation {
    let identity: DeviceGrantRevisionIdentity
    let publicMetadataBytes: Data
}
/// Unmounted mechanics with injected backend ONLY. No Keychain implementation, runtime grants, migration,
/// production default, reset expansion or pruning. Backend acknowledgment is not a physical durability
/// guarantee. Backend must supply immutable bytes/stable identities; same-UID hostile backend mutation is
/// outside that contract. Private addition without a durable reference binding blocks reconstruction.
/// Public filesystem metadata projects no secret-bearing input fields or secret hashes. Backend
/// persistent references must be opaque nonsecret identifiers, not private credential payloads.
/// Exact journal staging may be re-observed across restart; installed terminal/head identities never
/// are adopted by matching bytes alone. Unknown unbound private/staged additions remain blocked. Owned-directory fsync never walks ancestors.
final class DeviceGrantPreparationStore {
    enum Kind: Equatable { case binding, intent, progress, terminalBinding, terminal, headBinding, head, confirmation }
    enum Boundary: Equatable {
        case afterWrite(Kind), afterFileSync(Kind), beforeReplace(Kind), afterReplace(Kind), afterDirectorySync(Kind)
        case afterPrivateAdd(String)
    }
    enum Diagnosis: Equatable { case awaitingPrivateIdentity, partial, terminalNeedsDurability }
    private struct Node: Equatable { let identity: GrantDiskIdentity; let bytes: Data }
    private struct Binding: Codable {
        let schemaVersion: Int; let rootID: UUID; let rootPath: String; let protectedPaths: [String]
        let rootIdentity: GrantDiskIdentity; let lockIdentity: GrantDiskIdentity; let operationsIdentity: GrantDiskIdentity
    }
    private struct Context { let root: Int32; let lock: Int32; let operations: Int32; let binding: Binding }
    private struct Entry {
        let record: GrantPreparationRecord; let final: Node?; let staged: Node?
        let terminal: Node?; let terminalStage: Node?; let terminalBinding: GrantTerminalBinding?
        let headBinding: GrantHeadBinding?; let confirmation: GrantHeadConfirmation?
        var complete: Bool { terminal != nil && confirmation != nil }
    }
    private struct Inventory { let entries: [Entry]; let items: [String: DeviceGrantCredentialItem]; let hasStages: Bool; let head: Node?; var tip: Entry? { entries.last } }
    private let root: URL; private let rootID: UUID; private let scope: DevicePackageProtectedScope
    private let backend: any DeviceGrantCredentialBackend
    private let boundary: (Boundary) throws -> Void
    private let mutex = NSLock()
    private var bindingQualified = false
    private var setupRoot: GrantDiskIdentity?, setupLock: GrantDiskIdentity?, setupOperations: GrantDiskIdentity?
    private var captured: [String: DeviceGrantCredentialItem] = [:]
    private var liveAttempts: [UUID: Data] = [:]
    private var terminalStages: [UUID: GrantDiskIdentity] = [:]
    private var headStages: [UUID: GrantDiskIdentity] = [:]
    private var qualification: (epoch: UInt64, tip: Node, head: Node)?
    private var boundTerminalQualification:DeviceBoundGrantTerminalTransition?
    private static let gateLock = NSLock(); private static var epochs: [String: UInt64] = [:]
    private var service: String { GrantPreparationCodec.service(rootID) }
    init(root: URL, rootID: UUID, protectedScope: DevicePackageProtectedScope, backend: any DeviceGrantCredentialBackend, boundary: @escaping (Boundary) throws -> Void = { _ in }) {
        self.root = root; self.rootID = rootID; scope = protectedScope; self.backend = backend; self.boundary = boundary
    }
    private func epoch(invalidate: Bool = false) -> UInt64 {
        Self.gateLock.lock(); defer { Self.gateLock.unlock() }
        let key = root.path + "|" + rootID.uuidString
        let value = (Self.epochs[key] ?? 0) + (invalidate ? 1 : 0); Self.epochs[key] = value; return value
    }
    func initializeExplicit() throws {
        try disk(create: true) { context in
            let bytes = try GrantPreparationCodec.encode(context.binding)
            let existing = try readFile(context.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit)
            if let existing {
                guard existing.bytes == bytes else { throw DeviceGrantPreparationError.unsafeBinding }
                if let staged = try readFile(context.root,"root-binding.json.pending",limit:GrantPreparationCodec.recordLimit) {
                    guard staged.bytes == bytes else { throw DeviceGrantPreparationError.conflict }
                    try replace(context,parent:context.root,name:"root-binding.json",bytes:bytes,expected:existing,kind:.binding)
                } else { try syncExisting(context.root,"root-binding.json",expected:existing) }
            } else {
                guard try names(context.operations,maximum:129*10).isEmpty else { throw DeviceGrantPreparationError.conflict }
                var count = 0
                try backend.inventory(service:service,maximum:1) { _ in count += 1; throw DeviceGrantPreparationError.conflict }
                guard count == 0 else { throw DeviceGrantPreparationError.conflict }
                try replace(context,parent:context.root,name:"root-binding.json",bytes:bytes,expected:nil,kind:.binding)
            }
            try sync(context.lock); try sync(context.operations); try sync(context.root); try check(context)
            _ = try inventory(context); bindingQualified = true
        }
    }
    func prepareExact(_ request: DeviceGrantPreparationRequest) throws -> DevicePreparedGrantReceipt {
        let attempted = try GrantPreparationCodec.attempt(request,rootID:rootID)
        return try disk { context in
            guard bindingQualified else { throw DeviceGrantPreparationError.repairRequired }
            let state = try inventory(context)
            guard state.entries.count < 128 else { throw DeviceGrantPreparationError.capacity }
            guard !state.hasStages, state.entries.allSatisfy(\.complete) else { throw DeviceGrantPreparationError.repairRequired }
            if let tip = state.tip?.terminal { try requireQualification(tip,head:state.head) }
            guard !state.entries.contains(where: { $0.record.operationID == request.operationID || $0.record.revisionID == request.input.identity.revisionID }) else { throw DeviceGrantPreparationError.conflict }
            let bindings = try request.input.credentials.sorted { $0.revisionID.uuidString < $1.revisionID.uuidString }.map { credential -> GrantCredentialBinding in
                let account = GrantPreparationCodec.credentialAccount(credential.revisionID)
                if let item = state.items[account] {
                    try GrantPreparationCodec.validate(item,account:account,count:credential.bytes.count)
                    guard try readPrivate(item).bytes == credential.bytes else { throw DeviceGrantPreparationError.conflict }
                    return .init(revisionID:credential.revisionID,byteCount:credential.bytes.count,item:item)
                }
                return .init(revisionID:credential.revisionID,byteCount:credential.bytes.count,item:nil)
            }
            let record = GrantPreparationRecord(rootID:rootID,operationID:request.operationID,revisionID:request.input.identity.revisionID,
                ordinal:state.entries.count+1,publicMetadata:request.qualified.publicMetadataBytes,privateAttemptBytes:attempted.count,
                previousHead:state.head.map { .init(bytes:$0.bytes,identity:$0.identity) },credentials:bindings)
            try reserve(record,state:state)
            let attemptEpoch = epoch(invalidate:true); qualification = nil; liveAttempts[request.operationID] = attempted
            try replace(context,parent:context.operations,name:name(request.operationID),bytes:GrantPreparationCodec.encode(record),expected:nil,kind:.intent)
            return try finish(context,record:record,attempted:attempted,attemptEpoch:attemptEpoch)
        }
    }
    func recommitExact(_ request: DeviceGrantPreparationRequest) throws -> DevicePreparedGrantReceipt {
        let attempted = try GrantPreparationCodec.attempt(request,rootID:rootID)
        return try disk { context in
            guard bindingQualified else { throw DeviceGrantPreparationError.repairRequired }
            if let live=liveAttempts[request.operationID] { _ = try GrantPreparationCodec.decodeAttempt(live) }
            let state = try inventory(context)
            if let item=state.entries.first(where:{$0.record.operationID == request.operationID})?.record.privateAttempt {
                _ = try GrantPreparationCodec.decodeAttempt(readPrivate(item).bytes)
            }
            let attemptEpoch = epoch(invalidate:true); qualification = nil
            guard let entry = state.entries.first(where: { $0.record.operationID == request.operationID }),
                  entry.record.revisionID == request.input.identity.revisionID,
                  entry.record.publicMetadata == request.qualified.publicMetadataBytes, entry.record.privateAttemptBytes == attempted.count else { throw DeviceGrantPreparationError.conflict }
            if let persisted = entry.record.privateAttempt { guard try readPrivate(persisted).bytes == attempted else { throw DeviceGrantPreparationError.conflict } }
            else { guard liveAttempts[request.operationID] == attempted else { throw DeviceGrantPreparationError.repairRequired } }
            if let staged = entry.staged {
                try replace(context,parent:context.operations,name:name(request.operationID),bytes:staged.bytes,expected:entry.final,kind:.progress)
            } else if let final = entry.final { try syncExisting(context.operations,name(request.operationID),expected:final); try sync(context.operations) }
            return try finish(context,record:entry.record,attempted:attempted,attemptEpoch:attemptEpoch)
        }
    }
    /// Exact private-only dispatch, reachable only from the fixed two-root gate command.
    final class SuccessorPredecessor {
        fileprivate let original:DeviceBoundGrantTerminalRecovery
        fileprivate let pendingOperation:UUID?,pendingNode:GrantHeadEvidence?,pendingItem:DeviceGrantCredentialItem?
        fileprivate init(_ original:DeviceBoundGrantTerminalRecovery,pendingOperation:UUID?=nil,pendingNode:GrantHeadEvidence?=nil,pendingItem:DeviceGrantCredentialItem?=nil){self.original=original;self.pendingOperation=pendingOperation;self.pendingNode=pendingNode;self.pendingItem=pendingItem}
        var packages:[DeviceRetainedEntryPackageBinding]{original.packages}
    }
    private func successorBaseline(_ c:Context,_ state:Inventory,operationID:UUID)throws->(Inventory,Entry?) {
        if state.tip?.record.operationID == operationID {
            guard let pending=state.tip,!pending.complete,state.entries.count >= 2 else{throw DeviceGrantPreparationError.conflict}
            // Only this original current private record may have an exact progress stage. Projecting
            // the predecessor must not erase the existing all-writer unrelated-stage barrier.
            let allowed=operationID.uuidString.lowercased()+".json.pending"
            guard try names(c.operations,maximum:129*10).allSatisfy({!$0.hasSuffix(".pending") || $0 == allowed}),
                  try readFile(c.root,"head.json.pending",limit:4096) == nil else{throw DeviceGrantPreparationError.repairRequired}
            let old=Inventory(entries:Array(state.entries.dropLast()),items:state.items,hasStages:false,head:state.head)
            guard old.entries.allSatisfy({$0.complete && $0.staged == nil && $0.terminalStage == nil}),old.tip?.terminal != nil,
                  pending.record.previousHead == state.head.map({.init(bytes:$0.bytes,identity:$0.identity)}) else{throw DeviceGrantPreparationError.conflict}
            return (old,pending)
        }
        guard !state.hasStages,state.entries.allSatisfy(\.complete) else{throw DeviceGrantPreparationError.repairRequired}
        return (state,nil)
    }
    func captureSuccessorPredecessorExact(_ journal:DeviceLocalProvisioningIntentStore.SuccessorPredecessorCheckpoint,
                                         resourcePermit:DeviceLocalResourcePermit)throws->SuccessorPredecessor {
        let operation=try journal.successorGrantOperationID
        return try disk(resourcePermit:resourcePermit){c in
            let state=try inventory(c), (baseline,pending)=try successorBaseline(c,state,operationID:operation)
            let original=try captureBoundTerminal(c,state:baseline,intent:journal.predecessorIntent)
            guard baseline.tip?.terminal != nil else{throw DeviceGrantPreparationError.repairRequired}
            if let pending {
                guard pending.record.privateAttempt != nil || liveAttempts[operation] != nil,let node=pending.staged ?? pending.final else{throw DeviceGrantPreparationError.repairRequired}
                return .init(original,pendingOperation:operation,pendingNode:.init(bytes:node.bytes,identity:node.identity),pendingItem:pending.record.privateAttempt)
            }
            return .init(original)
        }
    }
    private func verifySuccessorPredecessor(_ original:SuccessorPredecessor,_ c:Context,_ state:Inventory)throws {
        let baseline:Inventory
        if let operation=original.pendingOperation {
            let (old,pending)=try successorBaseline(c,state,operationID:operation)
            guard let pending,let node=pending.staged ?? pending.final,original.pendingNode == GrantHeadEvidence(bytes:node.bytes,identity:node.identity),pending.record.privateAttempt == original.pendingItem else{throw DeviceGrantPreparationError.conflict}
            baseline=old
        } else {baseline=state}
        try verifyTerminalRecovery(original.original,c,baseline)
    }
    func qualifySuccessorPredecessorExact(_ original:SuccessorPredecessor,packages:[DeviceProvisioningPackageInput])throws->DeviceValidatedProvisioningPlan {
        try disk{c in try verifySuccessorPredecessor(original,c,inventory(c));let result=try terminalPlan(original.original,packages:packages);try verifySuccessorPredecessor(original,c,inventory(c));return result}
    }
    private func successorRecord(_ request:DeviceGrantPreparationRequest,bytes:Data,state:Inventory)throws->GrantPreparationRecord {
        guard !state.hasStages,state.entries.allSatisfy(\.complete),state.entries.count < 128,
              !state.entries.contains(where:{$0.record.operationID == request.operationID || $0.record.revisionID == request.input.identity.revisionID}) else{throw DeviceGrantPreparationError.repairRequired}
        let credentials=try request.input.credentials.sorted{$0.revisionID.uuidString < $1.revisionID.uuidString}.map{secret -> GrantCredentialBinding in
            let account=GrantPreparationCodec.credentialAccount(secret.revisionID)
            if let item=state.items[account] {try GrantPreparationCodec.validate(item,account:account,count:secret.bytes.count);guard try readPrivate(item).bytes == secret.bytes else{throw DeviceGrantPreparationError.conflict};return .init(revisionID:secret.revisionID,byteCount:secret.bytes.count,item:item)}
            return .init(revisionID:secret.revisionID,byteCount:secret.bytes.count,item:nil)
        }
        let record=GrantPreparationRecord(rootID:rootID,operationID:request.operationID,revisionID:request.input.identity.revisionID,ordinal:state.entries.count+1,
            publicMetadata:request.qualified.publicMetadataBytes,privateAttemptBytes:bytes.count,previousHead:state.head.map{.init(bytes:$0.bytes,identity:$0.identity)},credentials:credentials)
        try reserve(record,state:state);return record
    }
    func preflightSuccessorExact(_ original:SuccessorPredecessor,request:DeviceGrantPreparationRequest,plan:DeviceValidatedProvisioningPlan,
                                previousPackages:[DeviceProvisioningPackageInput],resourcePermit:DeviceLocalResourcePermit)throws {
        let bytes=try DeviceProvisioningPrivateAttemptV2.encoded(request,intent:plan.canonicalBytes)
        try disk(resourcePermit:resourcePermit){c in
            let state=try inventory(c);try verifySuccessorPredecessor(original,c,state)
            let prior=try terminalPlan(original.original,packages:previousPackages)
            guard prior.roots == plan.roots,try GrantPreparationCodec.decodeStoredAttempt(original.original.privateBytes).input.owner == request.input.owner else{throw DeviceGrantPreparationError.conflict}
            if let input=liveAttempts[request.operationID] {guard input == bytes else{throw DeviceGrantPreparationError.conflict}}
            if let operation=original.pendingOperation {
                guard operation == request.operationID,let entry=state.tip,entry.record.revisionID == request.input.identity.revisionID,
                      entry.record.publicMetadata == request.qualified.publicMetadataBytes,entry.record.privateAttemptBytes == bytes.count else{throw DeviceGrantPreparationError.conflict}
                if let item=entry.record.privateAttempt {guard try readPrivate(item).bytes == bytes else{throw DeviceGrantPreparationError.conflict}}
                else {guard liveAttempts[operation] == bytes else{throw DeviceGrantPreparationError.repairRequired}}
            } else {_ = try successorRecord(request,bytes:bytes,state:state)}
        }
    }
    func performSuccessorPrivateAttemptExact(_ original:SuccessorPredecessor,request:DeviceGrantPreparationRequest,plan:DeviceValidatedProvisioningPlan,
        previousPackages:[DeviceProvisioningPackageInput],commandPermit:DeviceBoundGrantCommandPermit)throws->DeviceBoundGrantPrivateAttempt {
        try performPrivateAttempt(request,plan:plan,recovery:nil,predecessor:original,previousPackages:previousPackages,commandPermit:commandPermit)
    }
    func performBoundPrivateAttempt(_ request:DeviceGrantPreparationRequest,plan:DeviceValidatedProvisioningPlan,
                                    recovery:DeviceBoundGrantRecoveryPlan?,commandPermit:DeviceBoundGrantCommandPermit)throws->DeviceBoundGrantPrivateAttempt {
        try performPrivateAttempt(request,plan:plan,recovery:recovery,predecessor:nil,previousPackages:[],commandPermit:commandPermit)
    }
    private func performPrivateAttempt(_ request:DeviceGrantPreparationRequest,plan:DeviceValidatedProvisioningPlan,
        recovery:DeviceBoundGrantRecoveryPlan?,predecessor:SuccessorPredecessor?,previousPackages:[DeviceProvisioningPackageInput],
        commandPermit:DeviceBoundGrantCommandPermit)throws->DeviceBoundGrantPrivateAttempt {
        let bytes=try DeviceProvisioningPrivateAttemptV2.encoded(request,intent:plan.canonicalBytes)
        let frame=try GrantPreparationCodec.decodeStoredAttempt(bytes)
        guard frame.rootID == rootID else{throw DeviceGrantPreparationError.conflict}
        try commandPermit.begin(ObjectIdentifier(self));defer{commandPermit.end()}
        guard let c=borrowedResourceContext else{throw DeviceLocalResourceGateFailure.invalidScope}
        try check(c)
        let state=try inventory(c)
        if let original=liveAttempts[request.operationID] {guard original == bytes else{throw DeviceGrantPreparationError.conflict}}
        if let recovery {try verifyBoundCheckpoint(recovery.checkpoint,context:c,state:state);guard recovery.plan.canonicalBytes == plan.canonicalBytes else{throw DeviceGrantPreparationError.conflict}}
        if let predecessor {try verifySuccessorPredecessor(predecessor,c,state)}
        var record:GrantPreparationRecord
        if let entry=state.entries.first(where:{$0.record.operationID == request.operationID}) {
            guard state.tip?.record.operationID == request.operationID,!entry.complete,
                  entry.record.revisionID == request.input.identity.revisionID,entry.record.publicMetadata == request.qualified.publicMetadataBytes,
                  entry.record.privateAttemptBytes == bytes.count else{throw DeviceGrantPreparationError.conflict}
            if let item=entry.record.privateAttempt {guard try readPrivate(item).bytes == bytes else{throw DeviceGrantPreparationError.conflict}}
            else{guard liveAttempts[request.operationID] == bytes else{throw DeviceGrantPreparationError.repairRequired}}
            record=entry.record
        } else {
            guard (bindingQualified || predecessor != nil),!state.hasStages,state.entries.allSatisfy(\.complete),state.entries.count < 128,
                  !state.entries.contains(where:{$0.record.revisionID == request.input.identity.revisionID}) else{throw DeviceGrantPreparationError.repairRequired}
            if let predecessor {
                try verifySuccessorPredecessor(predecessor,c,state)
                let prior=try terminalPlan(predecessor.original,packages:previousPackages)
                guard prior.roots == plan.roots,try GrantPreparationCodec.decodeStoredAttempt(predecessor.original.privateBytes).input.owner == request.input.owner else{throw DeviceGrantPreparationError.conflict}
            } else if let tip=state.tip?.terminal {try requireQualification(tip,head:state.head)}
            let credentials=try request.input.credentials.sorted{$0.revisionID.uuidString < $1.revisionID.uuidString}.map{secret -> GrantCredentialBinding in
                let account=GrantPreparationCodec.credentialAccount(secret.revisionID)
                if let item=state.items[account] {try GrantPreparationCodec.validate(item,account:account,count:secret.bytes.count);guard try readPrivate(item).bytes == secret.bytes else{throw DeviceGrantPreparationError.conflict};return .init(revisionID:secret.revisionID,byteCount:secret.bytes.count,item:item)}
                return .init(revisionID:secret.revisionID,byteCount:secret.bytes.count,item:nil)
            }
            record = .init(rootID:rootID,operationID:request.operationID,revisionID:request.input.identity.revisionID,ordinal:state.entries.count+1,
                           publicMetadata:request.qualified.publicMetadataBytes,privateAttemptBytes:bytes.count,
                           previousHead:state.head.map{.init(bytes:$0.bytes,identity:$0.identity)},credentials:credentials)
            try reserve(record,state:state)
        }
        // Invalid/stale/input/capacity checks precede changing qualification. Capture the ORIGINAL
        // checked binding under this lock; visible binding bytes alone are not a sync acknowledgment.
        guard let originalBinding=try readFile(c.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit),
              originalBinding.bytes == (try GrantPreparationCodec.encode(c.binding)) else{throw DeviceGrantPreparationError.unsafeBinding}
        // Exact live input is established before invalidation and the first public/private effect.
        liveAttempts[request.operationID]=bytes
        bindingQualified=false
        var completed=false
        defer{if !completed{bindingQualified=false}}
        let currentEpoch=epoch(invalidate:true);qualification=nil
        if predecessor != nil {boundTerminalQualification=nil}
        if let predecessor {
            // Exact original predecessor nodes, including explicit absences, precede the new intent.
            // This private branch never manufactures legacy terminal qualification.
            for evidence in predecessor.original.nodes {
                if let node=evidence.node {try syncExisting(evidence.root ? c.root:c.operations,evidence.name,expected:Node(identity:node.identity,bytes:node.bytes))}
            }
            try boundary(.afterFileSync(.binding));try sync(c.lock);try sync(c.operations);try sync(c.root);try boundary(.afterDirectorySync(.binding));try check(c)
            guard epoch() == currentEpoch,try terminalNodes(c,operationID:predecessor.original.operationID) == predecessor.original.nodes,
                  try readPrivate(predecessor.original.item).bytes == predecessor.original.privateBytes else{throw DeviceGrantPreparationError.conflict}
        }
        let entry=state.entries.first(where:{$0.record.operationID == request.operationID})
        if let entry,let staged=entry.staged {try replace(c,parent:c.operations,name:name(request.operationID),bytes:staged.bytes,expected:entry.final,kind:.progress)}
        else if let entry,let final=entry.final {try syncExisting(c.operations,name(request.operationID),expected:final);try sync(c.operations)}
        else {try replace(c,parent:c.operations,name:name(request.operationID),bytes:GrantPreparationCodec.encode(record),expected:nil,kind:.intent)}
        if record.privateAttempt == nil {
            record.privateAttempt=try addExact(account:GrantPreparationCodec.attemptAccount(request.operationID),bytes:bytes)
            try persist(c,record)
        }
        guard let item=record.privateAttempt,try readPrivate(item).bytes == bytes else{throw DeviceGrantPreparationError.conflict}
        try verifyResources(record)
        let finalState=try inventory(c)
        guard let final=finalState.tip,final.record.operationID == request.operationID,final.staged == nil,let node=final.final,
              node.bytes == (try GrantPreparationCodec.encode(record)),epoch() == currentEpoch else{throw DeviceGrantPreparationError.conflict}
        try syncExisting(c.operations,name(request.operationID),expected:node)
        // Exact restart repair synchronizes only owned nodes, never ancestors, head or terminal.
        try syncExisting(c.root,"root-binding.json",expected:originalBinding);try boundary(.afterFileSync(.binding))
        try sync(c.lock);try sync(c.operations);try sync(c.root);try boundary(.afterDirectorySync(.binding));try check(c)
        guard try readFile(c.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit) == originalBinding,
              try readFile(c.operations,name(request.operationID),limit:GrantPreparationCodec.recordLimit) == node,
              epoch() == currentEpoch else{throw DeviceGrantPreparationError.conflict}
        if let predecessor {
            guard try terminalNodes(c,operationID:predecessor.original.operationID) == predecessor.original.nodes,
                  try readPrivate(predecessor.original.item).bytes == predecessor.original.privateBytes,
                  let retained=finalState.entries.first(where:{$0.record.operationID == predecessor.original.operationID}),retained.complete else{throw DeviceGrantPreparationError.conflict}
            try verifyResources(retained.record)
        }
        bindingQualified=true;completed=true
        return .init(issuer:ObjectIdentifier(self),rootID:rootID,epoch:currentEpoch,node:.init(bytes:node.bytes,identity:node.identity),item:item,bytes:bytes,
                     binding:.init(bytes:originalBinding.bytes,identity:originalBinding.identity),operationID:request.operationID)
    }
    func verifyBoundPrivateAttempt(_ receipt:DeviceBoundGrantPrivateAttempt,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit){c in try verifyBoundCheckpoint(receipt,context:c,state:inventory(c))}
    }
    /// Read-only exact private binding for the fixed package command. The recorded secret input stays
    /// in this file; fresh supplied/retained genuine packages constrain its complete declarations.
    func verifyBoundPrivateAttempt(_ receipt:DeviceBoundGrantPrivateAttempt,plan:DeviceValidatedProvisioningPlan,
                                  packages:[DeviceProvisioningPackageInput],resourcePermit:DeviceLocalResourcePermit)throws {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        let intent=try ProvisioningIntentCodec.decode(plan.canonicalBytes)
        try disk(resourcePermit:resourcePermit){c in
            try verifyBoundCheckpoint(receipt,context:c,state:inventory(c))
            let frame=try GrantPreparationCodec.decodeStoredAttempt(receipt.privateBytes)
            guard frame.version == 2,frame.completeSetIntent == plan.canonicalBytes,
                  intent.roots == plan.roots,intent.operationID == plan.operationID else{throw DeviceGrantPreparationError.conflict}
            let candidate=try StructuralStoreCodec.envelope(intent.candidate),expected=try Self.boundExpectations(packages)
            let qualified=try DeviceGrantRevisionQualifier.qualify(frame.input,expectedEntries:expected)
            let privateRequest=DeviceGrantPreparationRequest(operationID:frame.operationID,input:frame.input,qualified:qualified,expectedEntries:expected)
            let original=DeviceProvisioningPlanRequest(roots:intent.roots,operationID:intent.operationID,grantOperationID:intent.grantOperationID,
                expectedGenerationID:candidate.expectedGenerationID,baseline:intent.expectedOld.map{.expectedEnvelope($0)} ?? .initialExplicit(legacyGrantSet:candidate.snapshot.grantSet),
                snapshot:candidate.snapshot,owner:frame.input.owner,packages:packages,grantInput:frame.input,qualifiedGrant:qualified)
            guard try DeviceProvisioningPlanner.qualify(original).canonicalBytes == plan.canonicalBytes,
                  try DeviceProvisioningPrivateAttemptV2.encoded(privateRequest,intent:plan.canonicalBytes) == receipt.privateBytes else{throw DeviceGrantPreparationError.conflict}
            try verifyBoundCheckpoint(receipt,context:c,state:inventory(c))
        }
    }
    /// Fixed credential-only dispatch. V2 remains unresolved; no terminal/head or private addition.
    func performBoundCredentialCompletion(_ original:DeviceBoundGrantPrivateAttempt,
        plan:DeviceValidatedProvisioningPlan,packages:[DeviceProvisioningPackageInput],
        commandPermit:DeviceBoundCredentialCommandPermit)throws->DeviceBoundGrantCredentialTransition {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        try commandPermit.begin(ObjectIdentifier(self));defer{commandPermit.end()}
        guard let c=borrowedResourceContext else{throw DeviceLocalResourceGateFailure.invalidScope}
        let state=try inventory(c);try verifyBoundCheckpoint(original,context:c,state:state)
        let frame=try GrantPreparationCodec.decodeStoredAttempt(original.privateBytes)
        guard frame.version == 2,frame.completeSetIntent == plan.canonicalBytes,
              frame.input.credentials.count <= 396,let entry=state.tip,entry.staged == nil else{throw DeviceGrantPreparationError.conflict}
        let expected=try Self.boundExpectations(packages)
        let qualified=try DeviceGrantRevisionQualifier.qualify(frame.input,expectedEntries:expected)
        let request=DeviceGrantPreparationRequest(operationID:frame.operationID,input:frame.input,qualified:qualified,expectedEntries:expected)
        guard try DeviceProvisioningPrivateAttemptV2.encoded(request,intent:plan.canonicalBytes) == original.privateBytes,
              qualified.publicMetadataBytes == entry.record.publicMetadata else{throw DeviceGrantPreparationError.conflict}
        var record=entry.record
        let secrets=Dictionary(uniqueKeysWithValues:frame.input.credentials.map{($0.revisionID,$0.bytes)})
        guard record.credentials.count == secrets.count else{throw DeviceGrantPreparationError.conflict}
        // Inventory already reserves every planned credential and private byte across retained records.
        // Check ALL existing identities/bytes before changing epoch or adding the first missing item.
        for binding in record.credentials {
            guard let bytes=secrets[binding.revisionID],bytes.count == binding.byteCount else{throw DeviceGrantPreparationError.conflict}
            if let item=binding.item {guard try readPrivate(item).bytes == bytes else{throw DeviceGrantPreparationError.conflict}}
            else if let item=state.items[binding.account] {
                guard captured[binding.account] == item,try readPrivate(item).bytes == bytes else{throw DeviceGrantPreparationError.conflict}
            }
        }
        guard let binding=try readFile(c.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit),
              binding.identity == original.bindingIdentity,binding.bytes == original.bindingBytes else{throw DeviceGrantPreparationError.conflict}
        let attemptEpoch=epoch(invalidate:true);qualification=nil;bindingQualified=false
        var completed=false;defer{if !completed{bindingQualified=false}}
        for index in record.credentials.indices {
            if record.credentials[index].item == nil {
                let value=record.credentials[index]
                guard let bytes=secrets[value.revisionID] else{throw DeviceGrantPreparationError.conflict}
                record.credentials[index].item=try addExact(account:value.account,bytes:bytes)
                try persist(c,record) // durable reference BEFORE the next add
            }
        }
        try verifyResources(record)
        guard let node=try readFile(c.operations,name(record.operationID),limit:GrantPreparationCodec.recordLimit),
              node.bytes == (try GrantPreparationCodec.encode(record)) else{throw DeviceGrantPreparationError.conflict}
        try syncExisting(c.operations,name(record.operationID),expected:node);try sync(c.operations)
        try syncExisting(c.root,"root-binding.json",expected:binding);try boundary(.afterFileSync(.binding))
        try sync(c.lock);try sync(c.operations);try sync(c.root);try boundary(.afterDirectorySync(.binding));try check(c)
        let after=try inventory(c)
        guard let latest=after.tip,latest.record.operationID == record.operationID,latest.final == node,
              latest.staged == nil,!latest.complete,latest.record.credentials.allSatisfy({$0.item != nil}),
              epoch() == attemptEpoch,try readFile(c.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit) == binding else{throw DeviceGrantPreparationError.conflict}
        bindingQualified=true;completed=true
        return .init(original:original,epoch:attemptEpoch,node:.init(bytes:node.bytes,identity:node.identity))
    }
    func verifyBoundCredentialTransition(_ transition:DeviceBoundGrantCredentialTransition,
        plan:DeviceValidatedProvisioningPlan,packages:[DeviceProvisioningPackageInput],resourcePermit:DeviceLocalResourcePermit)throws {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        try disk(resourcePermit:resourcePermit){c in
            let original=transition.original,state=try inventory(c)
            guard original.issuer == ObjectIdentifier(self),original.rootID == rootID,transition.epoch == epoch(),bindingQualified,
                  let entry=state.tip,entry.record.operationID == original.operationID,!entry.complete,entry.staged == nil,
                  entry.final == Node(identity:transition.node.identity,bytes:transition.node.bytes),
                  entry.record.privateAttempt == original.item,try readPrivate(original.item).bytes == original.privateBytes,
                  entry.record.credentials.allSatisfy({$0.item != nil}),
                  try readFile(c.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit) == Node(identity:original.bindingIdentity,bytes:original.bindingBytes) else{throw DeviceGrantPreparationError.conflict}
            let frame=try GrantPreparationCodec.decodeStoredAttempt(original.privateBytes)
            guard frame.version == 2,frame.completeSetIntent == plan.canonicalBytes else{throw DeviceGrantPreparationError.conflict}
            let expected=try Self.boundExpectations(packages),qualified=try DeviceGrantRevisionQualifier.qualify(frame.input,expectedEntries:expected)
            let request=DeviceGrantPreparationRequest(operationID:frame.operationID,input:frame.input,qualified:qualified,expectedEntries:expected)
            guard try DeviceProvisioningPrivateAttemptV2.encoded(request,intent:plan.canonicalBytes) == original.privateBytes,
                  qualified.publicMetadataBytes == entry.record.publicMetadata else{throw DeviceGrantPreparationError.conflict}
            try verifyResources(entry.record)
        }
    }
    /// Read-only capture of actual latest, including explicit absences. No new qualification.
    func inspectBoundTerminalRecovery(_ diagnostic:DeviceLocalProvisioningIntentStore.Diagnostic)throws->DeviceBoundGrantTerminalRecovery {
        let intent=try ProvisioningIntentCodec.decode(diagnostic.exactIntentBytes)
        guard intent.roots.grantID == rootID,intent.operationID == diagnostic.operationID else{throw DeviceGrantPreparationError.conflict}
        return try disk{c in
            let state=try inventory(c)
            guard state.tip?.record.operationID == intent.grantOperationID else{throw DeviceGrantPreparationError.conflict}
            return try captureBoundTerminal(c,state:state,intent:diagnostic.exactIntentBytes)
        }
    }
    func inspectBoundCompletedTerminalRecovery(_ journal:DeviceLocalProvisioningIntentStore.CompletedCurrentCheckpoint,
        resourcePermit:DeviceLocalResourcePermit)throws->DeviceBoundGrantTerminalRecovery {
        let body=try ProvisioningIntentCodec.decode(journal.exactIntentBytes)
        guard body.operationID == journal.operationID,body.candidate == journal.envelopeBytes,body.roots.grantID == rootID else{throw DeviceGrantPreparationError.conflict}
        return try disk(resourcePermit:resourcePermit){c in
            let state=try inventory(c)
            guard !state.hasStages,state.entries.allSatisfy(\.complete),state.tip?.record.operationID == body.grantOperationID else{throw DeviceGrantPreparationError.repairRequired}
            return try captureBoundTerminal(c,state:state,intent:journal.exactIntentBytes)
        }
    }
    func captureBoundTerminal(_ completed:DeviceBoundGrantCredentialTransition,plan:DeviceValidatedProvisioningPlan,
                              resourcePermit:DeviceLocalResourcePermit)throws->DeviceBoundGrantTerminalRecovery {
        try disk(resourcePermit:resourcePermit){c in
            let state=try inventory(c)
            guard completed.original.issuer == ObjectIdentifier(self),completed.epoch == epoch(),
                  state.tip?.final == Node(identity:completed.node.identity,bytes:completed.node.bytes),
                  state.tip?.record.privateAttempt == completed.original.item,
                  try readPrivate(completed.original.item).bytes == completed.original.privateBytes else{throw DeviceGrantPreparationError.conflict}
            return try captureBoundTerminal(c,state:state,intent:plan.canonicalBytes)
        }
    }
    private func terminalNodes(_ c:Context,operationID:UUID)throws->[BoundGrantNodeEvidence] {
        let base=operationID.uuidString.lowercased()
        let names=[(true,"root-binding.json",GrantPreparationCodec.recordLimit),(true,"head.json",4096),(true,"head.json.pending",4096)] +
            [".json",".json.pending",".terminal",".terminal.pending",".binding",".binding.pending",".head-binding",".head-binding.pending",".confirmed",".confirmed.pending"].map{(false,base+$0,$0.hasPrefix(".head-binding") ? 8192:($0.hasPrefix(".json") || $0.hasPrefix(".terminal") ? GrantPreparationCodec.recordLimit:4096))}
        return try names.map{root,name,limit in
            let node=try readFile(root ? c.root:c.operations,name,limit:limit)
            return .init(root:root,name:name,node:node.map{.init(bytes:$0.bytes,identity:$0.identity)})
        }
    }
    private func captureBoundTerminal(_ c:Context,state:Inventory,intent:Data)throws->DeviceBoundGrantTerminalRecovery {
        let before=epoch(),body=try ProvisioningIntentCodec.decode(intent),candidate=try StructuralStoreCodec.envelope(body.candidate)
        let refs=try DeviceLocalCompleteSetRestoreCodec.references(candidate.intent)
        guard refs.packages.count <= 12,body.roots.grantID == rootID,let tip=state.tip,
              tip.record.operationID == body.grantOperationID,tip.record.credentials.allSatisfy({$0.item != nil}),
              let item=tip.record.privateAttempt else{throw DeviceGrantPreparationError.repairRequired}
        let bytes=try readPrivate(item).bytes,frame=try GrantPreparationCodec.decodeStoredAttempt(bytes)
        guard frame.version == 2,frame.completeSetIntent == intent,frame.operationID == tip.record.operationID,
              frame.input.identity == refs.grants.identity,refs.grants.preparationOperationID == frame.operationID else{throw DeviceGrantPreparationError.conflict}
        try verifyResources(tip.record)
        let nodes=try terminalNodes(c,operationID:tip.record.operationID)
        guard epoch() == before,let binding=nodes.first(where:{$0.root && $0.name == "root-binding.json"})?.node,
              binding.bytes == (try GrantPreparationCodec.encode(c.binding)) else{throw DeviceGrantPreparationError.conflict}
        let packages=refs.packages.map{DeviceRetainedEntryPackageBinding(entryID:$0.entryID,reference:.init(rootID:$0.rootID,contentID:$0.contentID,preparationOperationID:$0.preparationOperationID,directory:$0.directory))}
        return .init(operationID:tip.record.operationID,packages:packages,issuer:ObjectIdentifier(self),rootID:rootID,epoch:before,
            item:item,privateBytes:bytes,intent:intent,nodes:nodes,previousHead:tip.record.previousHead)
    }
    private func verifyTerminalRecovery(_ recovery:DeviceBoundGrantTerminalRecovery,_ c:Context,_ state:Inventory)throws {
        guard recovery.issuer == ObjectIdentifier(self),recovery.rootID == rootID,recovery.epoch == epoch(),
              let tip=state.tip,tip.record.operationID == recovery.operationID,tip.record.previousHead == recovery.previousHead,
              tip.record.privateAttempt == recovery.item,tip.record.credentials.allSatisfy({$0.item != nil}),
              try readPrivate(recovery.item).bytes == recovery.privateBytes,
              try terminalNodes(c,operationID:recovery.operationID) == recovery.nodes else{throw DeviceGrantPreparationError.conflict}
        try verifyResources(tip.record)
    }
    private func terminalPlan(_ recovery:DeviceBoundGrantTerminalRecovery,packages:[DeviceProvisioningPackageInput])throws->DeviceValidatedProvisioningPlan {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        let frame=try GrantPreparationCodec.decodeStoredAttempt(recovery.privateBytes),body=try ProvisioningIntentCodec.decode(recovery.intent)
        guard frame.version == 2,frame.completeSetIntent == recovery.intent else{throw DeviceGrantPreparationError.conflict}
        let candidate=try StructuralStoreCodec.envelope(body.candidate),expected=try Self.boundExpectations(packages)
        let qualified=try DeviceGrantRevisionQualifier.qualify(frame.input,expectedEntries:expected)
        let request=DeviceGrantPreparationRequest(operationID:frame.operationID,input:frame.input,qualified:qualified,expectedEntries:expected)
        let original=DeviceProvisioningPlanRequest(roots:body.roots,operationID:body.operationID,grantOperationID:body.grantOperationID,
            expectedGenerationID:candidate.expectedGenerationID,baseline:body.expectedOld.map{.expectedEnvelope($0)} ?? .initialExplicit(legacyGrantSet:candidate.snapshot.grantSet),
            snapshot:candidate.snapshot,owner:frame.input.owner,packages:packages,grantInput:frame.input,qualifiedGrant:qualified)
        let plan=try DeviceProvisioningPlanner.qualify(original)
        guard plan.canonicalBytes == recovery.intent,try DeviceProvisioningPrivateAttemptV2.encoded(request,intent:plan.canonicalBytes) == recovery.privateBytes else{throw DeviceGrantPreparationError.conflict}
        return plan
    }
    /// Original completed v2 recovery only; no synchronization, qualification or checkpoint refresh.
    func verifyBoundCompletedRecovery(_ original:DeviceBoundGrantTerminalRecovery,plan:DeviceValidatedProvisioningPlan,
        packages:[DeviceProvisioningPackageInput],resourcePermit:DeviceLocalResourcePermit)throws {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        try disk(resourcePermit:resourcePermit){c in
            let state=try inventory(c)
            guard !state.hasStages,state.entries.allSatisfy(\.complete) else{throw DeviceGrantPreparationError.repairRequired}
            try verifyTerminalRecovery(original,c,state)
            guard try terminalPlan(original,packages:packages).canonicalBytes == plan.canonicalBytes else{throw DeviceGrantPreparationError.conflict}
            try verifyTerminalRecovery(original,c,inventory(c))
        }
    }
    func qualifyBoundTerminalRecovery(_ recovery:DeviceBoundGrantTerminalRecovery,packages:[DeviceProvisioningPackageInput])throws->DeviceValidatedProvisioningPlan {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        return try disk{c in
            try verifyTerminalRecovery(recovery,c,inventory(c));let plan=try terminalPlan(recovery,packages:packages)
            try verifyTerminalRecovery(recovery,c,inventory(c));return plan
        }
    }
    /// Existing nodes are never refreshed after effects. Only exact planned promotion/replacement
    /// is allowed; persisted prepared inode identities follow their rename into installed nodes.
    private func terminalContinuity(_ original:DeviceBoundGrantTerminalRecovery,_ final:[BoundGrantNodeEvidence])throws {
        let base=original.operationID.uuidString.lowercased()
        func old(_ root:Bool,_ name:String)->GrantHeadEvidence?{original.nodes.first{$0.root == root && $0.name == name}?.node}
        func now(_ root:Bool,_ name:String)->GrantHeadEvidence?{final.first{$0.root == root && $0.name == name}?.node}
        guard old(true,"root-binding.json") == now(true,"root-binding.json") else{throw DeviceGrantPreparationError.conflict}
        for suffix in [".json",".terminal",".binding",".head-binding",".confirmed"] {
            let installed=old(false,base+suffix),prepared=old(false,base+suffix+".pending")
            if suffix == ".json",let prepared {guard now(false,base+suffix) == prepared else{throw DeviceGrantPreparationError.conflict}}
            else if let installed {guard now(false,base+suffix) == installed else{throw DeviceGrantPreparationError.conflict}}
            else if let prepared {guard now(false,base+suffix) == prepared else{throw DeviceGrantPreparationError.conflict}}
            guard now(false,base+suffix+".pending") == nil else{throw DeviceGrantPreparationError.conflict}
        }
        if let prepared=old(true,"head.json.pending") {guard now(true,"head.json") == prepared else{throw DeviceGrantPreparationError.conflict}}
        else if let installed=old(true,"head.json"),installed != original.previousHead {
            guard now(true,"head.json") == installed else{throw DeviceGrantPreparationError.conflict}
        }
        guard now(true,"head.json.pending") == nil else{throw DeviceGrantPreparationError.conflict}
    }
    func performBoundTerminal(_ recovery:DeviceBoundGrantTerminalRecovery,plan:DeviceValidatedProvisioningPlan,
                             packages:[DeviceProvisioningPackageInput],commandPermit:DeviceBoundTerminalCommandPermit)throws->DeviceBoundGrantTerminalTransition {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        try commandPermit.begin(ObjectIdentifier(self));defer{commandPermit.end()}
        guard let c=borrowedResourceContext else{throw DeviceLocalResourceGateFailure.invalidScope}
        let state=try inventory(c);try verifyTerminalRecovery(recovery,c,state)
        guard try terminalPlan(recovery,packages:packages).canonicalBytes == plan.canonicalBytes,let entry=state.tip,
              let binding=recovery.nodes.first(where:{$0.root && $0.name == "root-binding.json"})?.node else{throw DeviceGrantPreparationError.conflict}
        let attemptEpoch=epoch(invalidate:true);qualification=nil;boundTerminalQualification=nil;bindingQualified=false
        var completed=false;defer{if !completed{bindingQualified=false;boundTerminalQualification=nil}}
        if let staged=entry.staged {try replace(c,parent:c.operations,name:name(entry.record.operationID),bytes:staged.bytes,expected:entry.final,kind:.progress)}
        let terminal=try terminalize(c,record:entry.record);try commitHead(c,record:entry.record,terminal:terminal)
        let observed=try terminalNodes(c,operationID:recovery.operationID)
        try terminalContinuity(recovery,observed)
        for evidence in observed {
            if let node=evidence.node {try syncExisting(evidence.root ? c.root:c.operations,evidence.name,expected:Node(identity:node.identity,bytes:node.bytes))}
        }
        try boundary(.afterFileSync(.binding));try sync(c.lock);try sync(c.operations);try sync(c.root);try boundary(.afterDirectorySync(.binding));try check(c)
        let after=try inventory(c)
        guard !after.hasStages,after.entries.allSatisfy(\.complete),let tip=after.tip,tip.record.operationID == recovery.operationID,
              tip.terminal == terminal,tip.record.previousHead == recovery.previousHead,
              try terminalNodes(c,operationID:recovery.operationID) == observed,epoch() == attemptEpoch,
              try readFile(c.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit) == Node(identity:binding.identity,bytes:binding.bytes) else{throw DeviceGrantPreparationError.conflict}
        try verifyResources(tip.record)
        let transition=DeviceBoundGrantTerminalTransition(original:recovery,epoch:attemptEpoch,nodes:observed)
        boundTerminalQualification=transition;bindingQualified=true;completed=true;return transition
    }
    func verifyBoundTerminal(_ transition:DeviceBoundGrantTerminalTransition,plan:DeviceValidatedProvisioningPlan,
                             packages:[DeviceProvisioningPackageInput],resourcePermit:DeviceLocalResourcePermit)throws {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        try disk(resourcePermit:resourcePermit){c in
            let state=try inventory(c),original=transition.original
            guard boundTerminalQualification === transition,bindingQualified,transition.epoch == epoch(),original.issuer == ObjectIdentifier(self),
                  original.rootID == rootID,!state.hasStages,state.entries.allSatisfy(\.complete),let tip=state.tip,
                  tip.record.operationID == original.operationID,tip.record.previousHead == original.previousHead,
                  tip.record.privateAttempt == original.item,try readPrivate(original.item).bytes == original.privateBytes,
                  try terminalNodes(c,operationID:original.operationID) == transition.nodes,
                  try terminalPlan(original,packages:packages).canonicalBytes == plan.canonicalBytes else{throw DeviceGrantPreparationError.conflict}
            try verifyResources(tip.record)
        }
    }
    private func verifyBoundCheckpoint(_ receipt:DeviceBoundGrantPrivateAttempt,context c:Context,state:Inventory)throws {
        guard receipt.issuer == ObjectIdentifier(self),receipt.rootID == rootID,receipt.epoch == epoch(),
              let entry=state.tip,entry.record.operationID == receipt.operationID,!entry.complete,(entry.staged != nil) == receipt.staged,
              let node=entry.staged ?? entry.final,node.identity == receipt.recordIdentity,node.bytes == receipt.recordBytes,
              entry.record.privateAttempt == receipt.item,try readPrivate(receipt.item).bytes == receipt.privateBytes,
              let binding=try readFile(c.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit),binding.identity == receipt.bindingIdentity,binding.bytes == receipt.bindingBytes else{throw DeviceGrantPreparationError.conflict}
        let frame=try GrantPreparationCodec.decodeStoredAttempt(receipt.privateBytes)
        guard frame.version == 2 else{throw DeviceGrantPreparationError.conflict}
    }
    /// Read-only private reconstruction. Only a recorded persistent reference can supply the frame;
    /// missing/unbound private additions remain evidence-preserving blocked across restart.
    func recoverBoundPrivateAttempt(_ diagnostic:DeviceLocalProvisioningIntentStore.Diagnostic,
                                    packages:[DeviceProvisioningPackageInput])throws->DeviceBoundGrantRecoveryPlan {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        let intent=try ProvisioningIntentCodec.decode(diagnostic.exactIntentBytes)
        return try disk{c in
            let before=epoch(),state=try inventory(c)
            guard intent.roots.grantID == rootID,intent.operationID == diagnostic.operationID,
                  let entry=state.tip,entry.record.operationID == intent.grantOperationID,!entry.complete,
                  let node=entry.staged ?? entry.final,let item=entry.record.privateAttempt else{throw DeviceGrantPreparationError.repairRequired}
            let bytes=try readPrivate(item).bytes,frame=try GrantPreparationCodec.decodeStoredAttempt(bytes)
            guard frame.version == 2,frame.completeSetIntent == diagnostic.exactIntentBytes else{throw DeviceGrantPreparationError.conflict}
            let candidate=try StructuralStoreCodec.envelope(intent.candidate)
            let expected=try Self.boundExpectations(packages)
            let qualified=try DeviceGrantRevisionQualifier.qualify(frame.input,expectedEntries:expected)
            let request=DeviceGrantPreparationRequest(operationID:frame.operationID,input:frame.input,qualified:qualified,expectedEntries:expected)
            let original=DeviceProvisioningPlanRequest(roots:intent.roots,operationID:intent.operationID,grantOperationID:intent.grantOperationID,
                expectedGenerationID:candidate.expectedGenerationID,baseline:intent.expectedOld.map{.expectedEnvelope($0)} ?? .initialExplicit(legacyGrantSet:candidate.snapshot.grantSet),
                snapshot:candidate.snapshot,owner:frame.input.owner,packages:packages,grantInput:frame.input,qualifiedGrant:qualified)
            let plan=try DeviceProvisioningPlanner.qualify(original)
            guard plan.canonicalBytes == diagnostic.exactIntentBytes,try DeviceProvisioningPrivateAttemptV2.encoded(request,intent:plan.canonicalBytes) == bytes,
                  let binding=try readFile(c.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit),epoch() == before else{throw DeviceGrantPreparationError.conflict}
            let checkpoint=DeviceBoundGrantPrivateAttempt(issuer:ObjectIdentifier(self),rootID:rootID,epoch:before,node:.init(bytes:node.bytes,identity:node.identity),item:item,bytes:bytes,
                binding:.init(bytes:binding.bytes,identity:binding.identity),operationID:frame.operationID,staged:entry.staged != nil)
            return .init(plan:plan,checkpoint:checkpoint,request:request)
        }
    }
    func performRecoveredBoundPrivateAttempt(_ recovery:DeviceBoundGrantRecoveryPlan,commandPermit:DeviceBoundGrantCommandPermit)throws->DeviceBoundGrantPrivateAttempt {
        try performBoundPrivateAttempt(recovery.request,plan:recovery.plan,recovery:recovery,commandPermit:commandPermit)
    }
    static func boundExpectations(_ packages:[DeviceProvisioningPackageInput])throws->[DeviceGrantEntryExpectation] {
        guard packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        return packages.map{item in switch item {
        case .supplied(let entry,_,let package):return .init(entryID:entry,package:package)
        case .retained(let entry,_,let verified):return .init(entryID:entry,package:verified.package) // Planner validates exact reference.
        }}
    }
    /// No effects: actual selected/latest mapping set, owners, full inventory and private canonical
    /// attempts are checked before either resource domain is allowed to synchronize.
    func validateRetainedTerminalExact(selected: DeviceRetainedGrantReference,
                                      evidence: [DeviceRetainedGrantPackageEvidence]) throws {
        try disk { context in _ = try resolutionEntries(context,selected:selected,evidence:evidence) }
    }
    /// Terminal-only reconstruction from already recorded persistent references. No add/update/delete.
    func resolveRetainedTerminalExact(selected: DeviceRetainedGrantReference,
                                     evidence: [DeviceRetainedGrantPackageEvidence]) throws -> DeviceGrantTerminalResolution {
        try disk { context in
            let checked = try resolutionEntries(context,selected:selected,evidence:evidence)
            let attemptEpoch = epoch(invalidate:true); qualification = nil; bindingQualified = false
            var completed = false
            defer { if !completed { qualification = nil; bindingQualified = false } }
            guard let binding = try readFile(context.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit),
                  binding.bytes == (try GrantPreparationCodec.encode(context.binding)) else { throw DeviceGrantPreparationError.unsafeBinding }
            try syncExisting(context.root,"root-binding.json",expected:binding); try boundary(.afterFileSync(.binding))
            try sync(context.lock); try sync(context.operations); try sync(context.root)
            try boundary(.afterDirectorySync(.binding)); try check(context)
            var receipts: [DevicePreparedGrantReceipt] = []
            for item in checked { // selected (if older), then actual latest, never caller-picked tip.
                let entry = item.entry
                guard let terminal = entry.terminal else { throw DeviceGrantPreparationError.conflict }
                for suffix in [".json",".terminal",".binding",".head-binding",".confirmed"] {
                    let filename = entry.record.operationID.uuidString.lowercased()+suffix
                    guard let node = try readFile(context.operations,filename,limit:GrantPreparationCodec.recordLimit) else { throw DeviceGrantPreparationError.conflict }
                    try syncExisting(context.operations,filename,expected:node)
                }
                try boundary(.afterReplace(.terminal)); try sync(context.operations); try boundary(.afterDirectorySync(.terminal))
                let state = try inventory(context)
                if state.tip?.record.operationID == entry.record.operationID {
                    try commitHead(context,record:entry.record,terminal:terminal)
                    let final = try inventory(context)
                    guard !final.hasStages, final.entries.allSatisfy(\.complete), final.tip?.terminal == terminal,
                          let head = final.head, epoch() == attemptEpoch else { throw DeviceGrantPreparationError.repairRequired }
                    qualification = (attemptEpoch,terminal,head)
                }
                receipts.append(.init(operationID:entry.record.operationID,identity:.init(rootID:rootID,revisionID:entry.record.revisionID),
                    issuer:ObjectIdentifier(self),privateBytes:item.bytes,terminal:terminal.identity))
            }
            let final = try inventory(context)
            guard !final.hasStages,final.entries.allSatisfy(\.complete),let tip = final.tip?.terminal,let head = final.head,
                  epoch() == attemptEpoch,try readFile(context.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit) == binding else { throw DeviceGrantPreparationError.repairRequired }
            try requireQualification(tip,head:head)
            let checkpoint = DeviceGrantResolutionCheckpoint(issuer:ObjectIdentifier(self),rootID:rootID,epoch:attemptEpoch,
                tipIdentity:tip.identity,tipBytes:tip.bytes,headIdentity:head.identity,headBytes:head.bytes,
                bindingIdentity:binding.identity,bindingBytes:binding.bytes)
            bindingQualified = true; completed = true
            return DeviceGrantTerminalResolution(receipts,checkpoint:checkpoint)
        }
    }
    func verifyResolutionCheckpoint(_ checkpoint:DeviceGrantResolutionCheckpoint,resourcePermit:DeviceLocalResourcePermit) throws {
        try disk(resourcePermit:resourcePermit) { context in
            guard checkpoint.issuer == ObjectIdentifier(self),checkpoint.rootID == rootID,
                  checkpoint.epoch == epoch(),bindingQualified else { throw DeviceGrantPreparationError.repairRequired }
            let state = try inventory(context)
            guard !state.hasStages,state.entries.allSatisfy(\.complete),
                  state.tip?.terminal == Node(identity:checkpoint.tipIdentity,bytes:checkpoint.tipBytes),
                  state.head == Node(identity:checkpoint.headIdentity,bytes:checkpoint.headBytes),
                  try readFile(context.root,"root-binding.json",limit:GrantPreparationCodec.recordLimit) == Node(identity:checkpoint.bindingIdentity,bytes:checkpoint.bindingBytes) else { throw DeviceGrantPreparationError.conflict }
            try requireQualification(Node(identity:checkpoint.tipIdentity,bytes:checkpoint.tipBytes),head:state.head)
            guard checkpoint.epoch == epoch() else { throw DeviceGrantPreparationError.repairRequired }
        }
    }
    private func resolutionEntries(_ context: Context, selected: DeviceRetainedGrantReference,
        evidence: [DeviceRetainedGrantPackageEvidence]) throws -> [(entry: Entry, bytes: Data)] {
        guard selected.identity.rootID == rootID, (1...2).contains(evidence.count),
              evidence.allSatisfy({$0.reference.identity.rootID == rootID && $0.expectations.count <= 12}),
              Set(evidence.map{$0.reference.operationID}).count == evidence.count else { throw DeviceGrantPreparationError.conflict }
        let state = try inventory(context)
        guard !state.hasStages, state.entries.allSatisfy(\.complete), let tip = state.tip,
              let chosen = state.entries.first(where:{$0.record.operationID == selected.operationID}),
              chosen.record.revisionID == selected.identity.revisionID else { throw DeviceGrantPreparationError.repairRequired }
        let required = Set([selected.operationID,tip.record.operationID])
        guard Set(evidence.map{$0.reference.operationID}) == required else { throw DeviceGrantPreparationError.conflict }
        let ordered = chosen.record.operationID == tip.record.operationID ? [tip] : [chosen,tip]
        return try ordered.map { entry in
            guard let binding = evidence.first(where:{$0.reference.operationID == entry.record.operationID}),
                  binding.reference.identity.revisionID == entry.record.revisionID,
                  let persisted = entry.record.privateAttempt else { throw DeviceGrantPreparationError.conflict }
            let bytes = try readPrivate(persisted).bytes
            try qualifyRecovered(bytes,reference:binding.reference,expectedOwner:binding.owner,expectedEntries:binding.expectations,publicMetadata:entry.record.publicMetadata)
            return (entry,bytes)
        }
    }
    /// Private receipt bytes remain inside this store. Genuine expectations are reconstructed by the
    /// resolver/gated reads; this does not repair, renew qualification, add secrets or expose input.
    func verifyRecovered(_ receipt: DevicePreparedGrantReceipt, expectedEntries: [DeviceGrantEntryExpectation],
                         expectedOwner: PairingIdentity, resourcePermit: DeviceLocalResourcePermit? = nil) throws -> DeviceVerifiedGrantPreparation {
        guard expectedEntries.count <= 12 else { throw DeviceGrantPreparationError.sizeLimit }
        let body = try GrantPreparationCodec.decodeAttempt(receipt.privateBytes)
        let qualified = try DeviceGrantRevisionQualifier.qualify(body.input,expectedEntries:expectedEntries)
        try qualifyRecovered(receipt.privateBytes,reference:.init(identity:receipt.identity,operationID:receipt.operationID),
            expectedOwner:expectedOwner,expectedEntries:expectedEntries,publicMetadata:qualified.publicMetadataBytes)
        let observed = try verifyRead(receipt,resourcePermit:resourcePermit)
        guard observed.publicMetadataBytes == qualified.publicMetadataBytes else { throw DeviceGrantPreparationError.conflict }
        return observed
    }
    /// Strict v2 only, one Generic entry working set. No v1 receipt/qualification conversion,
    /// secret getter, backend mutation or production admission. Original transition stays mandatory.
    func makeBoundGenericSeed(_ transition:DeviceBoundGrantTerminalTransition,plan:DeviceValidatedProvisioningPlan,
        packages:[DeviceProvisioningPackageInput],owner:PairingIdentity,entryID:UUID,resourcePermit:DeviceLocalResourcePermit)throws->DeviceImmutableGenericSeed {
        try Task.checkCancellation()
        try verifyBoundTerminal(transition,plan:plan,packages:packages,resourcePermit:resourcePermit)
        let seed=try disk(resourcePermit:resourcePermit){c -> DeviceImmutableGenericSeed in
            guard transition.epoch == epoch(),boundTerminalQualification === transition else{throw DeviceGrantPreparationError.conflict}
            let frame=try GrantPreparationCodec.decodeStoredAttempt(transition.original.privateBytes)
            guard frame.version == 2,frame.completeSetIntent == plan.canonicalBytes,owner.isWellFormed,owner.role == .controller,
                  frame.input.owner == owner,let entry=frame.input.entries.first(where:{$0.entryID == entryID}),let generic=entry.generic else{throw ConnectionFailure.permissionRequired}
            try generic.validate();guard generic.entries.count <= 32 else{throw DeviceGrantPreparationError.sizeLimit}
            var bytes=0
            for item in generic.entries {let count=item.secret?.count ?? 0;guard count <= 8192,bytes <= 256*1024-count else{throw DeviceGrantPreparationError.sizeLimit};bytes += count}
            try Task.checkCancellation();return .init(generic)
        }
        try verifyBoundTerminal(transition,plan:plan,packages:packages,resourcePermit:resourcePermit)
        try Task.checkCancellation();return seed
    }
    /// One selected entry only, privately decoded and freshly requalified. No immutable backend mutation.
    func makeGenericSeed(_ receipt:DevicePreparedGrantReceipt,expectedEntries:[DeviceGrantEntryExpectation],
                         expectedOwner:PairingIdentity,entryID:UUID,resourcePermit:DeviceLocalResourcePermit)throws->DeviceImmutableGenericSeed {
        try Task.checkCancellation()
        _ = try verifyRecovered(receipt,expectedEntries:expectedEntries,expectedOwner:expectedOwner,resourcePermit:resourcePermit)
        let body=try GrantPreparationCodec.decodeAttempt(receipt.privateBytes)
        guard let entry=body.input.entries.first(where:{$0.entryID == entryID}),let generic=entry.generic else { throw ConnectionFailure.permissionRequired }
        try generic.validate()
        guard generic.entries.count <= 32 else { throw DeviceGrantPreparationError.sizeLimit }
        var bytes=0
        for item in generic.entries {let count=item.secret?.count ?? 0;guard count <= 8192,bytes <= 256*1024-count else {throw DeviceGrantPreparationError.sizeLimit};bytes += count}
        try Task.checkCancellation();return DeviceImmutableGenericSeed(generic)
    }
    private func qualifyRecovered(_ bytes: Data, reference: DeviceRetainedGrantReference, expectedOwner: PairingIdentity,
                                  expectedEntries: [DeviceGrantEntryExpectation], publicMetadata: Data) throws {
        let body = try GrantPreparationCodec.decodeAttempt(bytes)
        guard body.rootID == rootID, body.operationID == reference.operationID, body.input.identity == reference.identity,
              expectedOwner.role == .controller, expectedOwner.isWellFormed,
              body.input.owner.role == .controller, body.input.owner.isWellFormed,
              body.input.owner.publicKey == expectedOwner.publicKey else { throw DeviceGrantPreparationError.conflict }
        let qualified = try DeviceGrantRevisionQualifier.qualify(body.input,expectedEntries:expectedEntries)
        let request = DeviceGrantPreparationRequest(operationID:body.operationID,input:body.input,qualified:qualified,expectedEntries:expectedEntries)
        guard try GrantPreparationCodec.attempt(request,rootID:rootID) == bytes,
              qualified.publicMetadataBytes == publicMetadata else { throw DeviceGrantPreparationError.conflict }
    }
    func diagnose(operationID: UUID) throws -> Diagnosis {
        try disk { context in
            guard let entry = try inventory(context).entries.first(where: { $0.record.operationID == operationID }) else { throw DeviceGrantPreparationError.conflict }
            if entry.complete { return .terminalNeedsDurability }
            return entry.record.privateAttempt == nil ? .awaitingPrivateIdentity : .partial
        }
    }
    func verify(_ receipt: DevicePreparedGrantReceipt) throws -> DeviceVerifiedGrantPreparation { try verifyRead(receipt,resourcePermit:nil) }
    private func verifyRead(_ receipt: DevicePreparedGrantReceipt, resourcePermit: DeviceLocalResourcePermit?) throws -> DeviceVerifiedGrantPreparation {
        try disk(resourcePermit:resourcePermit) { context in
            guard receipt.issuer == ObjectIdentifier(self), receipt.identity.rootID == rootID else { throw DeviceGrantPreparationError.conflict }
            let state = try inventory(context)
            guard !state.hasStages, state.entries.allSatisfy(\.complete), let tip = state.tip?.terminal else { throw DeviceGrantPreparationError.repairRequired }
            try requireQualification(tip,head:state.head)
            guard let entry = state.entries.first(where: { $0.record.operationID == receipt.operationID }),
                  entry.record.revisionID == receipt.identity.revisionID, entry.terminal?.identity == receipt.terminal,
                  let attempt = entry.record.privateAttempt, try readPrivate(attempt).bytes == receipt.privateBytes else { throw DeviceGrantPreparationError.conflict }
            try verifyResources(entry.record)
            let after = try inventory(context); guard after.tip?.terminal == tip, after.head == state.head else { throw DeviceGrantPreparationError.conflict }; try requireQualification(tip,head:after.head)
            return .init(identity:receipt.identity,publicMetadataBytes:entry.record.publicMetadata)
        }
    }
    /// Read-only exact request binding. Newly verified package expectations replace caller expectations.
    /// No private bytes escape; this does not synchronize, recommit, or renew qualification.
    func verify(_ receipt: DevicePreparedGrantReceipt, exactRequest request: DeviceGrantPreparationRequest,
                expectedEntries: [DeviceGrantEntryExpectation]) throws -> DeviceVerifiedGrantPreparation {
        try verifyExactRead(receipt,exactRequest:request,expectedEntries:expectedEntries,resourcePermit:nil)
    }
    func verify(_ receipt: DevicePreparedGrantReceipt, exactRequest request: DeviceGrantPreparationRequest,
                expectedEntries: [DeviceGrantEntryExpectation], resourcePermit: DeviceLocalResourcePermit) throws -> DeviceVerifiedGrantPreparation {
        try verifyExactRead(receipt,exactRequest:request,expectedEntries:expectedEntries,resourcePermit:resourcePermit)
    }
    private func verifyExactRead(_ receipt: DevicePreparedGrantReceipt, exactRequest request: DeviceGrantPreparationRequest,
                                expectedEntries: [DeviceGrantEntryExpectation], resourcePermit: DeviceLocalResourcePermit?) throws -> DeviceVerifiedGrantPreparation {
        let fresh = try DeviceGrantRevisionQualifier.qualify(request.input, expectedEntries: expectedEntries)
        guard fresh.exactlyMatches(request.qualified), receipt.operationID == request.operationID,
              receipt.identity == request.input.identity, receipt.identity.rootID == rootID else { throw DeviceGrantPreparationError.conflict }
        let rebound = DeviceGrantPreparationRequest(operationID: request.operationID, input: request.input,
            qualified: fresh, expectedEntries: expectedEntries)
        let attempted = try GrantPreparationCodec.attempt(rebound, rootID: rootID)
        guard attempted == receipt.privateBytes else { throw DeviceGrantPreparationError.conflict }
        let observed = try verifyRead(receipt,resourcePermit:resourcePermit)
        guard observed.publicMetadataBytes == fresh.publicMetadataBytes else { throw DeviceGrantPreparationError.conflict }
        return observed
    }
    private func requireQualification(_ tip: Node, head: Node?) throws {
        guard let qualified = qualification, qualified.epoch == epoch(), qualified.tip == tip, qualified.head == head else { throw DeviceGrantPreparationError.repairRequired }
    }
    private func finish(_ context: Context, record original: GrantPreparationRecord, attempted: Data, attemptEpoch: UInt64) throws -> DevicePreparedGrantReceipt {
        var record = original
        let privateAccount = GrantPreparationCodec.attemptAccount(record.operationID)
        if record.privateAttempt == nil {
            guard liveAttempts[record.operationID] == attempted else { throw DeviceGrantPreparationError.repairRequired }
            record.privateAttempt = try addExact(account:privateAccount,bytes:attempted)
            try persist(context,record)
        }
        guard let attempt = record.privateAttempt, try readPrivate(attempt).bytes == attempted else { throw DeviceGrantPreparationError.conflict }
        let body = try GrantPreparationCodec.decodeAttempt(attempted)
        let secrets = Dictionary(uniqueKeysWithValues:body.input.credentials.map { ($0.revisionID,$0.bytes) })
        for index in record.credentials.indices {
            let binding = record.credentials[index]
            guard let bytes = secrets[binding.revisionID], bytes.count == binding.byteCount else { throw DeviceGrantPreparationError.conflict }
            if binding.item == nil {
                record.credentials[index].item = try addExact(account:binding.account,bytes:bytes)
                try persist(context,record)
            } else { guard try readPrivate(binding.item!).bytes == bytes else { throw DeviceGrantPreparationError.conflict } }
        }
        try verifyResources(record)
        let terminal = try terminalize(context,record:record)
        let observed = try inventory(context)
        if observed.tip?.record.operationID == record.operationID { try commitHead(context,record:record,terminal:terminal) }
        else {
            guard let retained = observed.entries.first(where: { $0.record.operationID == record.operationID }), retained.complete else { throw DeviceGrantPreparationError.conflict }
            for suffix in [".binding",".head-binding",".confirmed"] {
                guard let node = try readFile(context.operations,record.operationID.uuidString.lowercased()+suffix,limit:8192) else { throw DeviceGrantPreparationError.conflict }
                try syncExisting(context.operations,record.operationID.uuidString.lowercased()+suffix,expected:node)
            }
            try sync(context.operations)
        }
        let state = try inventory(context)
        guard let current = state.entries.first(where: { $0.record.operationID == record.operationID }), current.terminal == terminal else { throw DeviceGrantPreparationError.conflict }
        if state.tip?.record.operationID == record.operationID {
            guard !state.hasStages, state.entries.allSatisfy(\.complete), let head = state.head, epoch() == attemptEpoch else { throw DeviceGrantPreparationError.repairRequired }
            qualification = (attemptEpoch,terminal,head)
        }
        liveAttempts.removeValue(forKey:record.operationID)
        return .init(operationID:record.operationID,identity:.init(rootID:rootID,revisionID:record.revisionID),issuer:ObjectIdentifier(self),privateBytes:attempted,terminal:terminal.identity)
    }
    private func addExact(account: String, bytes: Data) throws -> DeviceGrantCredentialItem {
        if let value = try backend.read(service:service,account:account,maximumBytes:bytes.count) {
            guard let owned = captured[account], value.item == owned, value.bytes == bytes else { throw DeviceGrantPreparationError.conflict }
            return owned
        }
        let item = try backend.add(service:service,account:account,bytes:bytes)
        try GrantPreparationCodec.validate(item,account:account,count:bytes.count)
        captured[account] = item // Capture BEFORE throwing fault; never infer identity from same bytes.
        try boundary(.afterPrivateAdd(account))
        guard try readPrivate(item).bytes == bytes else { throw DeviceGrantPreparationError.conflict }; return item
    }
    private func readPrivate(_ item: DeviceGrantCredentialItem) throws -> DeviceGrantCredentialValue {
        guard let value = try backend.read(service:service,account:item.account,maximumBytes:item.byteCount), value.item == item,
              value.bytes.count == item.byteCount else { throw DeviceGrantPreparationError.conflict }; return value
    }
    private func persist(_ context: Context, _ record: GrantPreparationRecord) throws {
        let old = try readFile(context.operations,name(record.operationID),limit:GrantPreparationCodec.recordLimit)
        try replace(context,parent:context.operations,name:name(record.operationID),bytes:GrantPreparationCodec.encode(record),expected:old,kind:.progress)
    }
    private func terminalize(_ context: Context, record: GrantPreparationRecord) throws -> Node {
        let id = record.operationID, base = id.uuidString.lowercased()
        let bytes = try GrantPreparationCodec.encode(record)
        if let final = try readFile(context.operations,base+".terminal",limit:GrantPreparationCodec.recordLimit) {
            guard let binding = try readFile(context.operations,base+".binding",limit:4096),
                  try GrantPreparationCodec.decodeTerminal(binding.bytes).terminalIdentity == final.identity, final.bytes == bytes else { throw DeviceGrantPreparationError.conflict }
            try syncExisting(context.operations,base+".terminal",expected:final)
            try boundary(.afterFileSync(.terminal)); try sync(context.operations); try boundary(.afterDirectorySync(.terminal)); try check(context)
            return final
        }
        let stagedName = base+".terminal.pending"
        var staged = try readFile(context.operations,stagedName,limit:GrantPreparationCodec.recordLimit)
        let existingBinding = try readFile(context.operations,base+".binding",limit:4096)
        if staged == nil {
            guard existingBinding == nil else { throw DeviceGrantPreparationError.conflict }
            let fd = openat(context.operations,stagedName,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_NONBLOCK,0o600)
            guard fd >= 0 else { throw failure() }; defer { close(fd) }
            let found = try identity(fd,directory:false); terminalStages[id] = found
            try writeAll(fd,bytes); try boundary(.afterWrite(.terminal)); try sync(fd); try boundary(.afterFileSync(.terminal)); try sync(context.operations)
            staged = try readFile(context.operations,stagedName,limit:GrantPreparationCodec.recordLimit)
        }
        guard let staged, staged.bytes == bytes else { throw DeviceGrantPreparationError.conflict }
        if let binding = existingBinding { guard try GrantPreparationCodec.decodeTerminal(binding.bytes).terminalIdentity == staged.identity else { throw DeviceGrantPreparationError.conflict }; try syncExisting(context.operations,base+".binding",expected:binding) }
        else {
            if let pending = try readFile(context.operations,base+".binding.pending",limit:4096) { guard try GrantPreparationCodec.decodeTerminal(pending.bytes).terminalIdentity == staged.identity else { throw DeviceGrantPreparationError.conflict } } else { guard terminalStages[id] == staged.identity else { throw DeviceGrantPreparationError.repairRequired } }
            let binding = GrantTerminalBinding(schemaVersion:1,operationID:id,terminalIdentity:staged.identity)
            try replace(context,parent:context.operations,name:base+".binding",bytes:GrantPreparationCodec.encode(binding,limit:4096),expected:nil,kind:.terminalBinding)
        }
        try boundary(.beforeReplace(.terminal)); try check(context)
        guard try readFile(context.operations,stagedName,limit:GrantPreparationCodec.recordLimit) == staged else { throw DeviceGrantPreparationError.conflict }
        guard try readFile(context.operations,base+".terminal",limit:GrantPreparationCodec.recordLimit) == nil else { throw DeviceGrantPreparationError.conflict }
        guard renameat(context.operations,stagedName,context.operations,base+".terminal") == 0 else { throw failure() }
        try boundary(.afterReplace(.terminal)); try sync(context.operations); try boundary(.afterDirectorySync(.terminal)); try check(context)
        guard let final = try readFile(context.operations,base+".terminal",limit:GrantPreparationCodec.recordLimit), final == staged else { throw DeviceGrantPreparationError.conflict }; return final
    }
    private func verifyResources(_ record: GrantPreparationRecord) throws {
        guard let item = record.privateAttempt else { throw DeviceGrantPreparationError.repairRequired }
        let body = try GrantPreparationCodec.decodeStoredAttempt(readPrivate(item).bytes)
        guard body.operationID == record.operationID, body.rootID == rootID, body.input.identity.revisionID == record.revisionID,
              try GrantPreparationCodec.projection(body.input) == record.publicMetadata else { throw DeviceGrantPreparationError.conflict }
        guard Set(body.input.credentials.map(\.revisionID)).count == body.input.credentials.count,
              Set(body.input.credentials.map(\.revisionID)) == Set(record.credentials.map(\.revisionID)) else { throw DeviceGrantPreparationError.conflict }
        let secrets = Dictionary(uniqueKeysWithValues:body.input.credentials.map { ($0.revisionID,$0.bytes) })
        for binding in record.credentials {
            if let item = binding.item { guard let bytes = secrets[binding.revisionID], bytes.count == binding.byteCount, try readPrivate(item).bytes == bytes else { throw DeviceGrantPreparationError.conflict } }
        }
    }
    private func reserve(_ record: GrantPreparationRecord, state: Inventory) throws {
        var intents = record.privateAttemptBytes, credentials: [UUID:Int] = [:]
        for entry in state.entries {
            guard entry.record.privateAttemptBytes <= GrantPreparationCodec.intentTotalLimit-intents else { throw DeviceGrantPreparationError.capacity }; intents += entry.record.privateAttemptBytes
            for binding in entry.record.credentials {
                if let old = credentials[binding.revisionID], old != binding.byteCount { throw DeviceGrantPreparationError.conflict }; credentials[binding.revisionID] = binding.byteCount
            }
        }
        for binding in record.credentials {
            if let old = credentials[binding.revisionID], old != binding.byteCount { throw DeviceGrantPreparationError.conflict }; credentials[binding.revisionID] = binding.byteCount
        }
        guard credentials.count <= 4096 else { throw DeviceGrantPreparationError.capacity }
        var total = 0
        for bytes in credentials.values { guard bytes <= GrantPreparationCodec.credentialTotalLimit-total else { throw DeviceGrantPreparationError.capacity }; total += bytes }
    }
    private func name(_ id: UUID) -> String { id.uuidString.lowercased()+".json" }
    private func commitHead(_ context: Context, record: GrantPreparationRecord, terminal: Node) throws {
        let base = record.operationID.uuidString.lowercased()
        let bytes = try GrantPreparationCodec.encode(GrantHead(schemaVersion:1,rootID:rootID,operationID:record.operationID,ordinal:record.ordinal,terminalIdentity:terminal.identity),limit:4096)
        let old = record.previousHead.map { Node(identity:$0.identity,bytes:$0.bytes) }
        let bindingName = base+".head-binding", confirmationName = base+".confirmed"
        var head = try readFile(context.root,"head.json",limit:4096)
        let bindingNode = try readFile(context.operations,bindingName,limit:8192)
        let pendingBinding = try readFile(context.operations,bindingName+".pending",limit:8192)
        var binding = try (bindingNode ?? pendingBinding).map { try GrantPreparationCodec.decodeHeadBinding($0.bytes) }
        if let binding {
            let candidate = Node(identity:binding.candidate.identity,bytes:binding.candidate.bytes)
            guard binding.operationID == record.operationID, candidate.bytes == bytes, head == old || head == candidate else { throw DeviceGrantPreparationError.conflict }
            if bindingNode == nil {
                try replace(context,parent:context.operations,name:bindingName,bytes:GrantPreparationCodec.encode(binding,limit:8192),expected:nil,kind:.headBinding)
            } else { try syncExisting(context.operations,bindingName,expected:bindingNode!); try sync(context.operations) }
        } else {
            guard head == old else { throw DeviceGrantPreparationError.conflict }
            var staged = try readFile(context.root,"head.json.pending",limit:4096)
            if staged == nil {
                let fd = openat(context.root,"head.json.pending",O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_NONBLOCK,0o600)
                guard fd >= 0 else { throw failure() }; defer { close(fd) }
                headStages[record.operationID] = try identity(fd,directory:false)
                try writeAll(fd,bytes); try boundary(.afterWrite(.head)); try sync(fd); try boundary(.afterFileSync(.head)); try sync(context.root)
                staged = try readFile(context.root,"head.json.pending",limit:4096)
            }
            guard let staged, staged.bytes == bytes, headStages[record.operationID] == staged.identity else { throw DeviceGrantPreparationError.repairRequired }
            binding = .init(schemaVersion:1,operationID:record.operationID,candidate:.init(bytes:bytes,identity:staged.identity))
            try replace(context,parent:context.operations,name:bindingName,bytes:GrantPreparationCodec.encode(binding!,limit:8192),expected:nil,kind:.headBinding)
        }
        let candidate = Node(identity:binding!.candidate.identity,bytes:bytes)
        if head != candidate {
            guard head == old, try readFile(context.root,"head.json.pending",limit:4096) == candidate else { throw DeviceGrantPreparationError.conflict }
            try boundary(.beforeReplace(.head)); try check(context)
            guard try readFile(context.root,"head.json",limit:4096) == old else { throw DeviceGrantPreparationError.conflict }
            guard renameat(context.root,"head.json.pending",context.root,"head.json") == 0 else { throw failure() }
            try boundary(.afterReplace(.head)); head = candidate
        }
        try syncExisting(context.root,"head.json",expected:candidate); try sync(context.root); try boundary(.afterDirectorySync(.head)); try check(context)
        let confirmation = GrantHeadConfirmation(schemaVersion:1,operationID:record.operationID,headIdentity:candidate.identity)
        let confirmationBytes = try GrantPreparationCodec.encode(confirmation,limit:4096)
        if let existing = try readFile(context.operations,confirmationName,limit:4096) {
            guard existing.bytes == confirmationBytes else { throw DeviceGrantPreparationError.conflict }
            try syncExisting(context.operations,confirmationName,expected:existing); try sync(context.operations); try boundary(.afterDirectorySync(.confirmation))
        } else {
            try replace(context,parent:context.operations,name:confirmationName,bytes:confirmationBytes,expected:nil,kind:.confirmation)
        }
        guard try readFile(context.root,"head.json",limit:4096) == candidate else { throw DeviceGrantPreparationError.conflict }
    }
    private func inventory(_ context: Context) throws -> Inventory {
        let rootNames = try names(context.root,maximum:16)
        guard Set(rootNames).isSubset(of:["root-binding.json","preparation.lock","operations","head.json","head.json.pending"]) else { throw DeviceGrantPreparationError.conflict }
        let files = try names(context.operations,maximum:129*10)
        let suffixes = [".json.pending",".terminal.pending",".binding.pending",".head-binding.pending",".confirmed.pending",".json",".terminal",".binding",".head-binding",".confirmed"]
        var groups: [UUID:Set<String>] = [:]
        for file in files {
            guard let suffix = suffixes.first(where:{file.hasSuffix($0)}), let id = UUID(uuidString:String(file.dropLast(suffix.count))), file == id.uuidString.lowercased()+suffix else { throw DeviceGrantPreparationError.invalidRecord }
            groups[id,default:[]].insert(suffix); guard groups.count <= 129 else { throw DeviceGrantPreparationError.capacity }
        }
        var entries: [Entry] = [], hasStages = false
        for (id,suffixes) in groups {
            let base = id.uuidString.lowercased()
            func node(_ suffix: String, limit: Int = GrantPreparationCodec.recordLimit) throws -> Node? { try readFile(context.operations,base+suffix,limit:limit) }
            let final = try node(".json"), staged = try node(".json.pending")
            guard let effective = staged ?? final else { throw DeviceGrantPreparationError.invalidRecord }
            let record = try GrantPreparationCodec.decodeRecord(effective.bytes)
            guard record.rootID == rootID, record.operationID == id else { throw DeviceGrantPreparationError.conflict }
            if let final, let staged { guard try GrantPreparationCodec.decodeRecord(staged.bytes).progresses(GrantPreparationCodec.decodeRecord(final.bytes)) else { throw DeviceGrantPreparationError.conflict } }
            if suffixes.contains(where:{$0.hasSuffix(".pending")}) { hasStages = true }
            func metadata(_ suffix: String, limit: Int) throws -> Node? {
                let final = try node(suffix,limit:limit), pending = try node(suffix+".pending",limit:limit)
                if let final, let pending { guard final.bytes == pending.bytes else { throw DeviceGrantPreparationError.conflict } }
                return pending ?? final
            }
            let terminal = try node(".terminal"), terminalStage = try node(".terminal.pending")
            let terminalBinding = try metadata(".binding",limit:4096).map { try GrantPreparationCodec.decodeTerminal($0.bytes) }
            if let bound = terminalBinding { guard bound.operationID == id else { throw DeviceGrantPreparationError.conflict } }
            if let terminal {
                guard terminalBinding?.terminalIdentity == terminal.identity, terminal.bytes == effective.bytes,
                      record.privateAttempt != nil, record.credentials.allSatisfy({$0.item != nil}), terminalStage == nil else { throw DeviceGrantPreparationError.conflict }
            } else if let terminalStage {
                guard terminalStage.bytes == effective.bytes,
                      terminalBinding?.terminalIdentity == terminalStage.identity || (terminalBinding == nil && terminalStages[id] == terminalStage.identity) else { throw DeviceGrantPreparationError.repairRequired }
            } else if terminalBinding != nil { throw DeviceGrantPreparationError.conflict }
            let headBinding = try metadata(".head-binding",limit:8192).map { try GrantPreparationCodec.decodeHeadBinding($0.bytes) }
            let confirmation = try metadata(".confirmed",limit:4096).map { try GrantPreparationCodec.decodeConfirmation($0.bytes) }
            if let bound = headBinding {
                let head = try GrantPreparationCodec.decodeHead(bound.candidate.bytes)
                guard let terminal, bound.operationID == id, head.rootID == rootID, head.operationID == id,
                      head.ordinal == record.ordinal, head.terminalIdentity == terminal.identity else { throw DeviceGrantPreparationError.conflict }
            }
            if let confirmation { guard let headBinding, confirmation.operationID == id, confirmation.headIdentity == headBinding.candidate.identity else { throw DeviceGrantPreparationError.conflict } }
            if let item=record.privateAttempt {
                let attempt=try GrantPreparationCodec.decodeStoredAttempt(readPrivate(item).bytes)
                if attempt.version == 2,terminal != nil || terminalStage != nil || terminalBinding != nil || headBinding != nil || confirmation != nil {
                    guard record.credentials.allSatisfy({$0.item != nil}),attempt.completeSetIntent != nil else{throw DeviceGrantPreparationError.conflict}
                }
                try verifyResources(record)
            }
            entries.append(.init(record:record,final:final,staged:staged,terminal:terminal,terminalStage:terminalStage,terminalBinding:terminalBinding,headBinding:headBinding,confirmation:confirmation))
        }
        entries.sort { $0.record.ordinal < $1.record.ordinal }
        var revisions = Set<UUID>()
        for (index,entry) in entries.enumerated() {
            guard entry.record.ordinal == index+1, revisions.insert(entry.record.revisionID).inserted,
                  index == entries.count-1 || entry.complete else { throw DeviceGrantPreparationError.conflict }
            if index == 0 { guard entry.record.previousHead == nil else { throw DeviceGrantPreparationError.conflict } }
            else { guard entry.record.previousHead == entries[index-1].headBinding?.candidate else { throw DeviceGrantPreparationError.conflict } }
        }
        var retainedIntentBytes = 0, retainedCredentials: [UUID:Int] = [:]
        for entry in entries {
            guard entry.record.privateAttemptBytes <= GrantPreparationCodec.intentTotalLimit-retainedIntentBytes else { throw DeviceGrantPreparationError.capacity }; retainedIntentBytes += entry.record.privateAttemptBytes
            for binding in entry.record.credentials {
                if let old = retainedCredentials[binding.revisionID], old != binding.byteCount { throw DeviceGrantPreparationError.conflict }; retainedCredentials[binding.revisionID] = binding.byteCount
            }
        }
        guard retainedCredentials.count <= 4096 else { throw DeviceGrantPreparationError.capacity }
        var retainedCredentialBytes = 0
        for bytes in retainedCredentials.values { guard bytes <= GrantPreparationCodec.credentialTotalLimit-retainedCredentialBytes else { throw DeviceGrantPreparationError.capacity }; retainedCredentialBytes += bytes }
        guard entries.filter(\.complete).count <= 128 else { throw DeviceGrantPreparationError.capacity }
        let head = try readFile(context.root,"head.json",limit:4096), headStage = try readFile(context.root,"head.json.pending",limit:4096)
        if let latest = entries.last {
            let old = latest.record.previousHead.map { Node(identity:$0.identity,bytes:$0.bytes) }
            let candidate = latest.headBinding.map { Node(identity:$0.candidate.identity,bytes:$0.candidate.bytes) }
            if latest.confirmation != nil { guard let candidate, head == candidate, headStage == nil else { throw DeviceGrantPreparationError.conflict } }
            else {
                guard head == old || (candidate != nil && head == candidate) else { throw DeviceGrantPreparationError.conflict }
                if let headStage {
                    guard candidate == headStage || (candidate == nil && headStages[latest.record.operationID] == headStage.identity) else { throw DeviceGrantPreparationError.repairRequired }
                    hasStages = true
                } else if candidate != nil && head != candidate { throw DeviceGrantPreparationError.conflict }
            }
        } else { guard head == nil, headStage == nil else { throw DeviceGrantPreparationError.conflict } }
        var expected: [String:DeviceGrantCredentialItem] = [:], planned: [String:Int] = [:]
        for entry in entries {
            if let item = entry.record.privateAttempt { expected[item.account] = item }
            else { planned[GrantPreparationCodec.attemptAccount(entry.record.operationID)] = entry.record.privateAttemptBytes }
            for credential in entry.record.credentials {
                if let item = credential.item { if let previous = expected[item.account], previous != item { throw DeviceGrantPreparationError.conflict }; expected[item.account] = item }
                else { planned[credential.account] = credential.byteCount }
            }
        }
        var items: [String:DeviceGrantCredentialItem] = [:], count = 0
        try backend.inventory(service:service,maximum:GrantPreparationCodec.itemLimit) { item in
            count += 1; guard count <= GrantPreparationCodec.itemLimit, items[item.account] == nil else { throw DeviceGrantPreparationError.capacity }
            if let expectedItem = expected[item.account] { guard expectedItem == item else { throw DeviceGrantPreparationError.conflict } }
            else { guard let plannedCount = planned[item.account], captured[item.account] == item else { throw DeviceGrantPreparationError.conflict }; try GrantPreparationCodec.validate(item,account:item.account,count:plannedCount) }
            items[item.account] = item
        }
        guard expected.allSatisfy({items[$0.key] == $0.value}) else { throw DeviceGrantPreparationError.conflict }
        return .init(entries:entries,items:items,hasStages:hasStages,head:head)
    }
    private func directoryIdentity(_ parent: Int32, _ name: String) throws -> GrantDiskIdentity? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw failure() }; defer { close(fd) }
        return try identity(fd, directory: true)
    }
    private func protectedPaths() throws -> [String] {
        guard root.isFileURL, root.path != "/", root.path.utf8.count <= 4096,
              scope.otherProtectedRoots.count <= 32 else { throw DeviceGrantPreparationError.unsafeBinding }
        var result: [String] = []
        for url in scope.roots {
            let path = url.path
            guard url.isFileURL, !path.isEmpty, path.utf8.count <= 4096 else { throw DeviceGrantPreparationError.unsafeBinding }
            let protected = try absoluteDirectory(path, allowMissing: true)
            if protected >= 0 { close(protected) }
            guard path != "/", root.path != path, !root.path.hasPrefix(path + "/"), !path.hasPrefix(root.path + "/") else { throw DeviceGrantPreparationError.scopeOverlap }
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
        let bindingExists = try readFile(rootFD, "root-binding.json", limit: GrantPreparationCodec.recordLimit) != nil
        if create && !bindingExists {
            let names = try names(rootFD, maximum: 256)
            if !names.isEmpty {
                guard setupRoot == rootIdentity, Set(names).isSubset(of: ["preparation.lock", "operations", "root-binding.json.pending"]) else { throw DeviceGrantPreparationError.conflict }
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
            if let expected = setupLock { guard expected == lockIdentity else { throw DeviceGrantPreparationError.conflict } }
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
            if let expected = setupOperations { guard expected == opsIdentity else { throw DeviceGrantPreparationError.conflict } }
            setupOperations = opsIdentity
        }
        let binding = Binding(schemaVersion: 1, rootID: rootID, rootPath: root.path, protectedPaths: paths,
            rootIdentity: rootIdentity, lockIdentity: lockIdentity, operationsIdentity: opsIdentity)
        let context = Context(root: rootFD, lock: lock, operations: ops, binding: binding)
        if !create || bindingExists {
            guard let existing = try readFile(rootFD, "root-binding.json", limit: GrantPreparationCodec.recordLimit), existing.bytes == (try GrantPreparationCodec.encode(binding)) else { throw DeviceGrantPreparationError.unsafeBinding }
        }
        try check(context, allowMissingBinding: create && !bindingExists)
        return try operation(context)
    }
    private func check(_ context: Context, allowMissingBinding: Bool = false) throws {
        guard try protectedPaths() == context.binding.protectedPaths else { throw DeviceGrantPreparationError.unsafeBinding }
        let fd = try absoluteDirectory(root.path); defer { close(fd) }
        guard try identity(fd, directory: true) == context.binding.rootIdentity,
              try identity(context.root, directory: true) == context.binding.rootIdentity,
              try identity(context.lock, directory: false) == context.binding.lockIdentity,
              try directoryIdentity(context.root, "operations") == context.binding.operationsIdentity else { throw DeviceGrantPreparationError.unsafeBinding }
        guard let lock = try readFile(context.root, "preparation.lock", limit: 0), lock.identity == context.binding.lockIdentity else { throw DeviceGrantPreparationError.unsafeBinding }
        if let binding = try readFile(context.root, "root-binding.json", limit: GrantPreparationCodec.recordLimit) {
            guard binding.bytes == (try GrantPreparationCodec.encode(context.binding)) else { throw DeviceGrantPreparationError.unsafeBinding }
        } else if !allowMissingBinding { throw DeviceGrantPreparationError.unsafeBinding }
    }
    private func absoluteDirectory(_ path: String, allowMissing: Bool = false) throws -> Int32 {
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), path.utf8.count <= 4096, parts.count <= 64,
              !parts.contains(where: { $0 == "." || $0 == ".." }), !path.contains("//") else { throw DeviceGrantPreparationError.unsafeBinding }
        let traversal: DeviceFilesystemTraversal
        do { traversal = try .plan(for: path) } catch { throw DeviceGrantPreparationError.unsafeBinding }
        var fd = open(traversal.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure() }
        for part in traversal.components {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            if next < 0 {
                let error = errno; close(fd)
                if allowMissing && error == ENOENT { return -1 }
                throw DeviceGrantPreparationError.io(error)
            }
            close(fd); fd = next
        }
        return fd
    }
    private func identity(_ fd: Int32, directory: Bool) throws -> GrantDiskIdentity {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw failure() }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw DeviceGrantPreparationError.unsafeBinding }
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
            result.append(name); guard result.count <= maximum else { throw DeviceGrantPreparationError.capacity }
        }
        return result
    }
    private func readFile(_ parent: Int32, _ name: String, limit: Int) throws -> Node? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw failure() }; defer { close(fd) }
        let found = try identity(fd, directory: false)
        var info = stat(); guard fstat(fd, &info) == 0 else { throw failure() }
        guard info.st_size >= 0, info.st_size <= limit else { throw DeviceGrantPreparationError.sizeLimit }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw failure() }
            if count == 0 { break }
            guard count <= limit - bytes.count else { throw DeviceGrantPreparationError.sizeLimit }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count == info.st_size, try identity(fd, directory: false) == found else { throw DeviceGrantPreparationError.conflict }
        let current = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard current >= 0 else { throw failure() }; defer { close(current) }
        guard try identity(current, directory: false) == found else { throw DeviceGrantPreparationError.conflict }
        return .init(identity: found, bytes: bytes)
    }
    private func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw failure() } }
    private func syncExisting(_ parent: Int32, _ name: String, expected: Node) throws {
        guard try readFile(parent, name, limit: GrantPreparationCodec.recordLimit > expected.bytes.count ? GrantPreparationCodec.recordLimit : expected.bytes.count) == expected else { throw DeviceGrantPreparationError.conflict }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        guard try identity(fd, directory: false) == expected.identity else { throw DeviceGrantPreparationError.conflict }
        try sync(fd)
        guard try readFile(parent, name, limit: max(GrantPreparationCodec.recordLimit, expected.bytes.count)) == expected else { throw DeviceGrantPreparationError.conflict }
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
            guard let prior = try readFile(parent, temporary, limit: GrantPreparationCodec.recordLimit), prior.bytes == bytes else { throw DeviceGrantPreparationError.conflict }
            fd = openat(parent, temporary, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0, try identity(fd, directory: false) == prior.identity else { throw DeviceGrantPreparationError.conflict }
        } else { guard fd >= 0 else { throw failure() }; try writeAll(fd, bytes) }
        let stagedIdentity = try identity(fd, directory: false)
        do {
            try boundary(.afterWrite(kind)); try check(context, allowMissingBinding: kind == .binding)
            try sync(fd); try boundary(.afterFileSync(kind)); try check(context, allowMissingBinding: kind == .binding)
            try boundary(.beforeReplace(kind))
            guard try readFile(parent, name, limit: GrantPreparationCodec.recordLimit) == expected,
                  try readFile(parent, temporary, limit: GrantPreparationCodec.recordLimit) == Node(identity: stagedIdentity, bytes: bytes) else { throw DeviceGrantPreparationError.conflict }
            guard renameat(parent, temporary, parent, name) == 0 else { throw failure() }
            try boundary(.afterReplace(kind)); try sync(parent); try boundary(.afterDirectorySync(kind))
            guard try readFile(parent, name, limit: GrantPreparationCodec.recordLimit) == Node(identity: stagedIdentity, bytes: bytes) else { throw DeviceGrantPreparationError.conflict }
            try check(context)
        } catch let error as DeviceGrantPreparationError {
            if error == .conflict || error == .unsafeBinding { throw error }; throw DeviceGrantPreparationError.outcomeUncertain
        } catch { throw DeviceGrantPreparationError.outcomeUncertain }
    }
    private func failure() -> DeviceGrantPreparationError { .io(errno) }
}

/// Private one-use working set; no receipt input/HA token/general secret accessor escapes this file.
final class DeviceImmutableGenericSeed:GrantSecretRedacted,@unchecked Sendable {
    private let mutex=NSLock()
    private var provisioning:ConnectionProvisioning?
    fileprivate init(_ provisioning:ConnectionProvisioning) {self.provisioning=provisioning}
    private func take()throws->ConnectionProvisioning {
        mutex.lock();defer{mutex.unlock()}
        guard let value=provisioning else {throw ConnectionFailure.permissionRequired};provisioning=nil;return value
    }
    func instantiate(authorization:DeviceImmutableGenericAuthorization,http:any HTTPTransport,webSocket:any WebSocketTransport,
                     resolver:any DestinationResolver,clock:any PairingClock)async throws->any DeviceImmutableGenericOperations {
        try Task.checkCancellation();let value=try take()
        return try await DeviceImmutableGenericFacade.install(value,authorization:authorization,http:http,webSocket:webSocket,resolver:resolver,clock:clock)
    }
}
