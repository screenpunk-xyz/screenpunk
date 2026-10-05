import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Unmounted retained provisioning journal. Fixed genuine structural/resource completion is separate
/// from runtime authority. No deletion, migration or external-effect authorization exists. Inode guards are local replacement detection, not portable restore guarantees.
/// One pending + at most 128 retained completions, no pruning; at most 1548 operation leaves.
/// Each intent remains <=1MiB and aggregate retained intents <=128MiB, streamed one record at a time.
/// Completion encoding (including base64 envelope expansion) is <=256KiB. Original v1 bytes remain
/// immutable; v2 successor attempts bind the exact qualified completed predecessor envelope/head.
/// Unknown partial creation is retained and blocks restart; only the creating live instance can repair it.
/// Fault seams run synchronously under internal locks, are nonreentrant, and cannot wait for other
/// store work. This adds no UI/notification callback and no physical or hostile same-UID guarantee.
final class DeviceLocalProvisioningIntentStore {
    enum Failure:Error {case unsafeRoot, conflict, uncertain, capacity, io(Int32)}
    enum Kind:Equatable {case binding,genesis,head,intent,attempt,confirmation,completion,completionBinding,completionHead,completionConfirmation,deliveryIntent,deliveryBinding,deliveryCommand,deliveryPlan,deliveryConfirmation,nativeJoinIntent,nativeJoinBinding,nativeJoinCandidate,nativeJoinConfirmation}
    enum Boundary:Equatable {case afterCreate(Kind),afterWrite(Kind),afterFileSync(Kind),beforeReplace(Kind),afterReplace(Kind),afterDirectorySync(Kind),beforeDeliveryScopeExit,beforeNativeJoinScopeExit}
    fileprivate struct ID:Codable,Equatable {let device:UInt64,inode:UInt64}
    fileprivate struct Node:Codable,Equatable {let identity:ID;let bytes:Data}
    private struct Binding:Codable,Equatable {
        let schemaVersion:Int,rootID:UUID,path:String,protectedPaths:[String]
        let directory:ID,lock:ID,operations:ID,selfID:ID,genesisID:ID,initialHeadID:ID
    }
    private struct Genesis:Codable,Equatable {let schemaVersion:Int;let binding:Node;let initialHeadID:ID}
    private struct Head:Codable,Equatable {
        let schemaVersion:Int,genesisID:ID,operationID:UUID?,intentID:ID?,completed:Bool?,completionID:ID?
        init(schemaVersion:Int,genesisID:ID,operationID:UUID?,intentID:ID?,completed:Bool?=nil,completionID:ID?=nil) {
            self.schemaVersion=schemaVersion;self.genesisID=genesisID;self.operationID=operationID;self.intentID=intentID;self.completed=completed;self.completionID=completionID
        }
    }
    private struct Completion:Codable {
        let schemaVersion:Int,operationID:UUID,structuralRootID:UUID,generationID:UUID,intentID:ID,envelope:Data
    }
    private struct CompletionBinding:Codable {
        let schemaVersion:Int,operationID:UUID,selfID:ID,completionID:ID,confirmationID:ID,baseline:Node,candidate:Node
    }
    private struct CompletionConfirmation:Codable {let schemaVersion:Int,selfID:ID,binding:Node,head:Node}
    private struct State {
        let operation:UUID?,intent:Data?,complete:Bool,nodes:[String:Node],completed:Bool,terminalCount:Int,intentBytes:Int
    }
    final class CompletionTransition {
        fileprivate let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,operationID:UUID,envelope:Data
        fileprivate let original:[String:Node],nodes:[String:Node]
        fileprivate init(_ issuer:ObjectIdentifier,_ rootID:UUID,_ epoch:UInt64,_ operationID:UUID,_ envelope:Data,_ original:[String:Node],_ nodes:[String:Node]) {
            self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;self.operationID=operationID;self.envelope=envelope;self.original=original;self.nodes=nodes
        }
    }
    final class CompletionReceipt {
        let operationID:UUID
        fileprivate let transition:CompletionTransition
        fileprivate init(_ transition:CompletionTransition){self.transition=transition;operationID=transition.operationID}
    }
    private struct CompletionLive {let plan:Data,envelope:Data,originalEpoch:UInt64,original:[String:Node];var activeEpoch:UInt64}
    private var completionLive:[UUID:CompletionLive]=[:]
    private var intentAntecedents:[UUID:[String:Node]]=[:]
    private var pendingCompletion:CompletionTransition?,qualifiedCompletion:CompletionTransition?
    private static let completionLimit=256*1024,terminalLimit=128,retainedIntentLimit=128*1024*1024
    private struct Attempt:Codable,Equatable {
        let schemaVersion:Int,operationID:UUID,selfID:ID,intentID:ID,confirmationID:ID,intentByteCount:Int
        let baseline:Node,candidate:Node
    }
    private struct Confirmation:Codable,Equatable {let schemaVersion:Int;let selfID:ID;let attempt:Node;let head:Node}
    final class Receipt {
        private let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,nodes:[String:Node]
        fileprivate init(_ issuer:ObjectIdentifier,_ rootID:UUID,_ epoch:UInt64,_ nodes:[String:Node]) {self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;self.nodes=nodes}
        fileprivate func matches(_ issuer:ObjectIdentifier,_ rootID:UUID,_ epoch:UInt64,_ nodes:[String:Node])->Bool{self.issuer == issuer && self.rootID == rootID && self.epoch == epoch && self.nodes == nodes}
    }
    /// Original current successor plus immediately preceding retained completion. Diagnosis is not
    /// capacity or structural authority; only this store constructs checked antecedent evidence.
    final class SuccessorPredecessorCheckpoint {
        let predecessorIntent:Data
        var successorGrantOperationID:UUID {get throws {try ProvisioningIntentCodec.decode(successorIntent).grantOperationID}}
        fileprivate let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,successorIntent:Data
        fileprivate let current:[String:Node],retained:[String:Node]
        fileprivate init(_ issuer:ObjectIdentifier,_ rootID:UUID,_ epoch:UInt64,_ successor:Data,_ predecessor:Data,_ current:[String:Node],_ retained:[String:Node]) {
            self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;successorIntent=successor;predecessorIntent=predecessor;self.current=current;self.retained=retained
        }
    }
    final class SuccessorTransition {
        let receipt:Receipt
        fileprivate let original:SuccessorPredecessorCheckpoint,epoch:UInt64
        fileprivate init(_ original:SuccessorPredecessorCheckpoint,_ epoch:UInt64,_ receipt:Receipt){self.original=original;self.epoch=epoch;self.receipt=receipt}
    }
    /// Completed-current diagnosis retains ORIGINAL nodes/epoch. It is not a structural ACK,
    /// grant receipt, capacity qualification or runtime admission capability.
    final class CompletedCurrentCheckpoint {
        let operationID:UUID,exactIntentBytes:Data,envelopeBytes:Data
        fileprivate let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,nodes:[String:Node]
        fileprivate init(_ issuer:ObjectIdentifier,_ rootID:UUID,_ epoch:UInt64,_ operation:UUID,_ intent:Data,_ envelope:Data,_ nodes:[String:Node]) {
            self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;operationID=operation;exactIntentBytes=intent;envelopeBytes=envelope;self.nodes=nodes
        }
    }
    final class CompletedRestoreTransition {
        fileprivate let original:CompletedCurrentCheckpoint,epoch:UInt64
        fileprivate init(_ original:CompletedCurrentCheckpoint,_ epoch:UInt64){self.original=original;self.epoch=epoch}
    }
    struct Diagnostic {let operationID:UUID;let exactIntentBytes:Data} // Not acknowledgment or secret identity proof.
    private static let epochLock=NSLock()
    private static var epochs:[String:UInt64]=[:]
    let root:URL,rootID:UUID
    private let validConstructorInput:Bool
    private let protectedPaths:[String],mutex=NSLock(),boundary:(Boundary)throws->Void
    private var qualifiedBinding=false
    private var bindingEpoch:UInt64?
    private var bindingEvidence:[String:Node]?
    private var live:[String:ID]=[:]
    // Original bounded NONSECRET method input, captured under the original disk lock before
    // invalidation/effects. Never reconstructed from visible bytes or a staging inode, and never
    // cleared to release capacity. Restart without persisted identity evidence remains blocked.
    private var liveInputs:[UUID:Data]=[:]
    private var attachmentInput:Data?
    private var attachmentQualified:DeliveryAttachmentReceipt?
    private var pendingAttachment:DeliveryAttachmentReceipt?

    private func requireSameLiveInput(_ plan:DeviceValidatedProvisioningPlan)throws {
        if let original=liveInputs[plan.operationID] {guard original == plan.canonicalBytes else{throw Failure.conflict}}
    }

    // Fixed same-reservation native join. Never terminal, capacity release, effects or admission.
    private static let nativeJoinNames:Set<String>=["native-join.intent","native-join.binding","native-join.candidate","native-join.confirm"]
    fileprivate struct NativeFingerprint:Codable,Equatable {let identity:ID,byteCount:Int,digest:String}
    private struct NativeJoinBinding:Codable {
        let schemaVersion:Int,rootID:UUID,operationID:UUID,selfID:ID
        let intent:Node,candidateID:ID,confirmationID:ID
        let original:[String:NativeFingerprint]
    }
    private struct NativeJoinConfirmation:Codable {let schemaVersion:Int,selfID:ID,binding:Node,candidate:NativeFingerprint}
    final class NativeJoinOriginal {
        fileprivate let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,nodes:[String:Node],join:[String:Node]
        fileprivate let intent:Data,candidate:Data
        fileprivate init(_ issuer:ObjectIdentifier,_ rootID:UUID,_ epoch:UInt64,_ nodes:[String:Node],_ join:[String:Node],_ plan:DeviceValidatedNativeProvisioningPlan) {
            self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;self.nodes=nodes;self.join=join;intent=plan.intentBytes;candidate=plan.candidateBytes
        }
    }
    final class NativeJoinTransition {
        let nativeOperationID:UUID
        fileprivate let original:NativeJoinOriginal,epoch:UInt64,nodes:[String:Node]
        fileprivate init(_ original:NativeJoinOriginal,_ epoch:UInt64,_ operationID:UUID,_ nodes:[String:Node]){self.original=original;self.epoch=epoch;nativeOperationID=operationID;self.nodes=nodes}
    }
    final class NativeJoinReceipt {
        let nativeOperationID:UUID
        fileprivate let transition:NativeJoinTransition
        fileprivate init(_ transition:NativeJoinTransition){self.transition=transition;nativeOperationID=transition.nativeOperationID}
    }
    /// Original joined receipt captured under the existing lock. This nonsecret checkpoint
    /// cannot establish original private input, authorize admission or renew a changed epoch.
    final class NativePrivatePrerequisite {
        fileprivate let issuer: ObjectIdentifier
        fileprivate let receipt: NativeJoinReceipt
        fileprivate let intent: Data
        fileprivate let candidate: Data
        fileprivate init(_ issuer: ObjectIdentifier, _ receipt: NativeJoinReceipt, _ plan: DeviceValidatedNativeProvisioningPlan) {
            self.issuer = issuer; self.receipt = receipt; intent = plan.intentBytes; candidate = plan.candidateBytes
        }
    }
    func captureNativePrivatePrerequisiteExact(_ receipt: NativeJoinReceipt,
        plan: DeviceValidatedNativeProvisioningPlan, resourcePermit: DeviceLocalResourcePermit) throws -> NativePrivatePrerequisite {
        try verifyNativeJoinExact(receipt, plan: plan, resourcePermit: resourcePermit)
        return .init(ObjectIdentifier(self), receipt, plan)
    }
    func verifyNativePrivatePrerequisiteExact(_ original: NativePrivatePrerequisite,
        plan: DeviceValidatedNativeProvisioningPlan, resourcePermit: DeviceLocalResourcePermit) throws {
        guard original.issuer == ObjectIdentifier(self), original.intent == plan.intentBytes,
              original.candidate == plan.candidateBytes else { throw Failure.conflict }
        try verifyNativeJoinExact(original.receipt, plan: plan, resourcePermit: resourcePermit)
    }
    private var nativeJoinInput:Data?,nativeJoinQualified:NativeJoinTransition?,nativeJoinPending:NativeJoinTransition?
    private func nativeJoinLeaves(_ c:Context)throws->[String] {try list(c.root,limit:28).filter{Self.nativeJoinNames.contains($0) || $0.hasSuffix(".stage") && Self.nativeJoinNames.contains(String($0.dropLast(6)))}}
    private func requireNoNativeJoin(_ c:Context)throws {
        guard nativeJoinInput == nil,nativeJoinPending == nil,nativeJoinQualified == nil,try nativeJoinLeaves(c).isEmpty else{throw Failure.conflict}
    }
    private func nativeJoinExactInput(_ plan:DeviceValidatedNativeProvisioningPlan)throws->Data {
        guard plan.roots.journalID == rootID,plan.intentBytes.count <= 32768,plan.candidateBytes.count <= 128*1024 else{throw Failure.conflict}
        var bytes=Data();bytes.append(plan.intentBytes);bytes.append(0);bytes.append(plan.candidateBytes);return bytes
    }
    private func fingerprint(_ node:Node)throws->NativeFingerprint {.init(identity:node.identity,byteCount:node.bytes.count,digest:try DeviceNativeDeliveryAttachmentCodec.hash(node.bytes))}
    private func nativeJoinNodes(_ c:Context)throws->[String:Node] {
        var result:[String:Node]=[:]
        for name in Self.nativeJoinNames {if let n=try either(c.root,name,limit:name == "native-join.candidate" ? 128*1024:name == "native-join.confirm" ? 65536:32768){result[name]=n}}
        for name in Self.nativeJoinNames {if let id=live[name+".stage"] {guard result[name]?.identity == id else{throw Failure.conflict}}}
        return result
    }
    private func decodeNativeJoinBinding(_ bytes:Data)throws->NativeJoinBinding {
        let o=try shape(bytes,["schemaVersion","rootID","operationID","selfID","intent","candidateID","confirmationID","original"])
        try ids(o,["selfID","candidateID","confirmationID"]);try node(o,"intent")
        guard let original=o["original"] as? [String:Any],Set(original.keys) == Self.deliveryNames.union(["rootBinding","genesis","head"]) else{throw Failure.conflict}
        for value in original.values {guard let f=value as? [String:Any] else{throw Failure.conflict};try StructuralStoreCodec.keys(f,required:["identity","byteCount","digest"]);try ids(f,["identity"])}
        let b=try canonical(NativeJoinBinding.self,bytes)
        guard b.schemaVersion == 1,b.rootID == rootID,b.intent.bytes.count <= 32768 else{throw Failure.conflict}
        for f in b.original.values {guard (0...65536).contains(f.byteCount) else{throw Failure.conflict};_ = try DeviceNativeDeliveryAttachmentCodec.hashText(f.digest)}
        return b
    }
    private func decodeNativeJoinConfirmation(_ bytes:Data)throws->NativeJoinConfirmation {
        let o=try shape(bytes,["schemaVersion","selfID","binding","candidate"]);try ids(o,["selfID"]);try node(o,"binding")
        guard let candidate=o["candidate"] as? [String:Any] else{throw Failure.conflict};try StructuralStoreCodec.keys(candidate,required:["identity","byteCount","digest"]);try ids(candidate,["identity"])
        let f=try canonical(NativeJoinConfirmation.self,bytes)
        guard f.schemaVersion == 1,(1...128*1024).contains(f.candidate.byteCount) else{throw Failure.conflict};_ = try DeviceNativeDeliveryAttachmentCodec.hashText(f.candidate.digest);return f
    }
    private func nativeJoinPreflight(_ c:Context,_ plan:DeviceValidatedNativeProvisioningPlan,_ original:[String:Node])throws->[String:Node] {
        let exact=try nativeJoinExactInput(plan)
        if let old=nativeJoinInput {guard old == exact else{throw Failure.conflict}}
        let body=try DeviceNativeProvisioningIntentCodec.decode(plan.intentBytes)
        let envelope=try DeviceNativeStructuralEnvelopeCodec.decode(plan.candidateBytes)
        guard body.nativeOperationID == plan.nativeOperationID,body.roots == plan.roots,
              body.association == plan.delivery.association,envelope.operationID == plan.nativeOperationID,
              envelope.expectedGenerationID == body.expectedGenerationID,body.desiredGenerationID == (try DeviceNativeStructuralStateCodec.decode(envelope.snapshotBytes)).generationID,
              body.candidateByteCount == plan.candidateBytes.count,try DeviceNativeDeliveryAttachmentCodec.hash(plan.candidateBytes).utf8.elementsEqual(body.candidateDigest.utf8),
              original["delivery.command"]?.bytes == plan.delivery.commandBytes,original["delivery.plan"]?.bytes == plan.delivery.planBytes else{throw Failure.conflict}
        let join=try nativeJoinNodes(c)
        if let intent=join["native-join.intent"] {guard intent.bytes == plan.intentBytes || intent.bytes.isEmpty && live["native-join.intent.stage"] == intent.identity && nativeJoinInput == exact else{throw Failure.conflict}}
        if let binding=join["native-join.binding"],!binding.bytes.isEmpty {
            let b=try decodeNativeJoinBinding(binding.bytes)
            guard b.operationID == plan.nativeOperationID,b.selfID == binding.identity,b.intent == join["native-join.intent"],b.intent.bytes == plan.intentBytes,
                  join["native-join.candidate"]?.identity == b.candidateID,join["native-join.confirm"]?.identity == b.confirmationID else{throw Failure.conflict}
            for (key,node) in original {guard b.original[key] == (try fingerprint(node)) else{throw Failure.conflict}}
            guard let candidate=join["native-join.candidate"],candidate.bytes.isEmpty || candidate.bytes == plan.candidateBytes else{throw Failure.conflict}
            let expected=try encode(NativeJoinConfirmation(schemaVersion:1,selfID:b.confirmationID,binding:binding,candidate:NativeFingerprint(identity:b.candidateID,byteCount:plan.candidateBytes.count,digest:body.candidateDigest)))
            guard let proof=join["native-join.confirm"],proof.bytes.isEmpty || proof.bytes == expected else{throw Failure.conflict}
        } else {
            // Until the reciprocal inode graph is durable, only the original live prefix can repair.
            // A visible same-byte intent is NOT portable restart provenance.
            if !join.isEmpty {guard nativeJoinInput == exact,let intent=join["native-join.intent"],live["native-join.intent.stage"] == intent.identity else{throw Failure.conflict}}
            for (name,node) in join where name != "native-join.intent" {guard nativeJoinInput == exact,live[name+".stage"] == node.identity,node.bytes.isEmpty,try read(c.root,name,limit:128*1024) == nil else{throw Failure.conflict}}
        }
        // Reserve ALL actual new encoded bytes including binding/proof BEFORE effects.
        let dummy=ID(device:UInt64.max,inode:UInt64.max)
        var refs:[String:NativeFingerprint]=[:];for(key,node)in original{refs[key]=try fingerprint(node)}
        let sample=Node(identity:dummy,bytes:try encode(NativeJoinBinding(schemaVersion:1,rootID:rootID,operationID:plan.nativeOperationID,selfID:dummy,intent:Node(identity:dummy,bytes:plan.intentBytes),candidateID:dummy,confirmationID:dummy,original:refs)))
        guard sample.bytes.count <= 32768 else{throw Failure.capacity}
        let confirmation=try encode(NativeJoinConfirmation(schemaVersion:1,selfID:dummy,binding:sample,candidate:NativeFingerprint(identity:dummy,byteCount:plan.candidateBytes.count,digest:body.candidateDigest)))
        let bytes=plan.intentBytes.count+plan.candidateBytes.count+sample.bytes.count+confirmation.count+Self.deliveryNames.reduce(0){$0+(original[$1]?.bytes.count ?? 0)}
        let state=try inventory(c,allowDeliveryAttachment:true)
        guard state.terminalCount < Self.terminalLimit,state.operation == nil || state.completed,state.intentBytes <= Self.retainedIntentLimit-bytes else{throw Failure.capacity}
        return join
    }
    /// A captured prerequisite is diagnostic/attempt evidence, NOT an acknowledgment. On retry the
    /// genuine full plan is requalified by the fixed gate; persisted nodes never prove secret identity.
    func captureNativeJoinOriginal(_ plan:DeviceValidatedNativeProvisioningPlan,attachment:DeliveryAttachmentReceipt?,resourcePermit:DeviceLocalResourcePermit)throws->NativeJoinOriginal {
        try disk(resourcePermit:resourcePermit){c in
            let before=epoch(),intent=try decodeDeliveryIntent(require(c.root,"delivery.intent",limit:32768).bytes)
            let original=try checkedDeliveryNodes(c,intent)
            let join=try nativeJoinPreflight(c,plan,original)
            if join.isEmpty {guard let receipt=attachment,receipt.issuer == ObjectIdentifier(self),receipt.rootID == rootID,receipt.epoch == before,receipt.nodes == original,attachmentQualified === receipt else{throw Failure.uncertain}}
            guard epoch() == before else{throw Failure.uncertain}
            return .init(ObjectIdentifier(self),rootID,before,original,join,plan)
        }
    }
    private func verifyNativeJoinOriginal(_ c:Context,_ original:NativeJoinOriginal,_ plan:DeviceValidatedNativeProvisioningPlan)throws {
        guard original.issuer == ObjectIdentifier(self),original.rootID == rootID,original.epoch == epoch(),original.intent == plan.intentBytes,original.candidate == plan.candidateBytes else{throw Failure.uncertain}
        let delivery=try decodeDeliveryIntent(require(c.root,"delivery.intent",limit:32768).bytes)
        guard try checkedDeliveryNodes(c,delivery) == original.nodes,try nativeJoinPreflight(c,plan,original.nodes) == original.join else{throw Failure.conflict}
    }
    func performNativeJoinExact(_ plan:DeviceValidatedNativeProvisioningPlan,original:NativeJoinOriginal,commandPermit:DeviceNativeProvisioningCommandPermit)throws->NativeJoinTransition {
        try commandPermit.begin(ObjectIdentifier(self));defer{commandPermit.end()}
        guard let c=borrowedResourceContext else{throw Failure.uncertain}
        try verifyNativeJoinOriginal(c,original,plan)
        nativeJoinInput=try nativeJoinExactInput(plan);nativeJoinQualified=nil;nativeJoinPending=nil;attachmentQualified=nil;pendingAttachment=nil;qualifiedBinding=false;bindingEpoch=nil;bindingEvidence=nil;qualifiedCompletion=nil;pendingCompletion=nil
        let now=epoch(true)
        let intent:Node
        if let n=original.join["native-join.intent"],!n.bytes.isEmpty {intent=n}
        else {let id=try allocate(c.root,"native-join.intent.stage",kind:.nativeJoinIntent);intent=Node(identity:id,bytes:plan.intentBytes);try fill(c.root,"native-join.intent.stage",intent,kind:.nativeJoinIntent)}
        try promote(c,parent:c.root,name:"native-join.intent",expected:intent,kind:.nativeJoinIntent)
        let binding:Node
        if let n=original.join["native-join.binding"],!n.bytes.isEmpty {binding=n}
        else {
            let candidateID=try allocate(c.root,"native-join.candidate.stage",kind:.nativeJoinCandidate),confirmationID=try allocate(c.root,"native-join.confirm.stage",kind:.nativeJoinConfirmation),id=try allocate(c.root,"native-join.binding.stage",kind:.nativeJoinBinding)
            var refs:[String:NativeFingerprint]=[:];for(key,node)in original.nodes{refs[key]=try fingerprint(node)}
            binding=Node(identity:id,bytes:try encode(NativeJoinBinding(schemaVersion:1,rootID:rootID,operationID:plan.nativeOperationID,selfID:id,intent:intent,candidateID:candidateID,confirmationID:confirmationID,original:refs)))
            try fill(c.root,"native-join.binding.stage",binding,kind:.nativeJoinBinding)
        }
        try promote(c,parent:c.root,name:"native-join.binding",expected:binding,kind:.nativeJoinBinding)
        let b=try decodeNativeJoinBinding(binding.bytes),candidate=Node(identity:b.candidateID,bytes:plan.candidateBytes)
        let proof=Node(identity:b.confirmationID,bytes:try encode(NativeJoinConfirmation(schemaVersion:1,selfID:b.confirmationID,binding:binding,candidate:try fingerprint(candidate))))
        for(name,node,kind)in[("native-join.candidate",candidate,Kind.nativeJoinCandidate),("native-join.confirm",proof,Kind.nativeJoinConfirmation)] {
            if try read(c.root,name,limit:128*1024) == nil {try fill(c.root,name+".stage",node,kind:kind)}
            try promote(c,parent:c.root,name:name,expected:node,kind:kind)
        }
        for(key,node)in original.nodes {
            let name=key == "rootBinding" ? "root-binding.json":key == "genesis" ? "genesis.json":key == "head" ? "head.json":key
            try syncExisting(c.root,name,node,kind:key == "rootBinding" ? .binding:key == "genesis" ? .genesis:key == "head" ? .head:.deliveryConfirmation)
        }
        try sync(c.lock);try sync(c.ops);try sync(c.root);try check(c)
        let joined=try nativeJoinPreflight(c,plan,original.nodes)
        guard Set(try nativeJoinLeaves(c)) == Self.nativeJoinNames,epoch() == now,try checkedDeliveryNodes(c,decodeDeliveryIntent(require(c.root,"delivery.intent",limit:32768).bytes)) == original.nodes else{throw Failure.uncertain}
        let transition=NativeJoinTransition(original,now,plan.nativeOperationID,joined);nativeJoinPending=transition
        do {try boundary(.beforeNativeJoinScopeExit)} catch {
            nativeJoinPending=nil;nativeJoinQualified=nil;throw error
        }
        return transition
    }
    func verifyNativeJoinTransition(_ transition:NativeJoinTransition,plan:DeviceValidatedNativeProvisioningPlan,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit){c in
            guard transition.original.issuer == ObjectIdentifier(self),transition.original.rootID == rootID,transition.epoch == epoch(),transition.original.intent == plan.intentBytes,transition.original.candidate == plan.candidateBytes,
                  try nativeJoinPreflight(c,plan,transition.original.nodes) == transition.nodes,
                  try checkedDeliveryNodes(c,decodeDeliveryIntent(require(c.root,"delivery.intent",limit:32768).bytes)) == transition.original.nodes,epoch() == transition.epoch else{throw Failure.uncertain}
        }
    }
    func publishNativeJoinExact(_ transition:NativeJoinTransition,publicationPermit:DeviceNativeProvisioningPublicationPermit)throws->NativeJoinReceipt {
        try publicationPermit.validate(transition);try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()}
        mutex.lock();defer{mutex.unlock()}
        guard nativeJoinPending === transition,transition.epoch == epoch() else{nativeJoinQualified=nil;throw Failure.uncertain}
        nativeJoinQualified=transition;nativeJoinPending=nil;return .init(transition)
    }
    /// Fixed coordinator failure cleanup only; retains reservation/bytes/latch. Does not read disk,
    /// acknowledge, repair, release capacity or invalidate an unrelated newer attempt.
    func discardNativeJoinPublication(_ transition:NativeJoinTransition)throws {
        try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()}
        mutex.lock();defer{mutex.unlock()}
        if nativeJoinPending === transition {nativeJoinPending=nil}
        if nativeJoinQualified === transition {nativeJoinQualified=nil}
    }
    func verifyNativeJoinExact(_ receipt:NativeJoinReceipt,plan:DeviceValidatedNativeProvisioningPlan,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit){_ in guard nativeJoinQualified === receipt.transition else{throw Failure.uncertain}}
        try verifyNativeJoinTransition(receipt.transition,plan:plan,resourcePermit:resourcePermit)
    }

    private struct Context {let root:Int32,lock:Int32,ops:Int32;let directory:ID,lockID:ID,opsID:ID}
    init(root:URL,rootID:UUID,protectedRoots:[URL],boundary:@escaping(Boundary)throws->Void={_ in}) {
        self.root=root;self.rootID=rootID;self.boundary=boundary
        // Count/kind bounds precede traversal, mapping or copied path inventory. Invalid construction
        // retains no supplied protected-path inventory and paths() rejects it before disk effects.
        let valid=root.isFileURL && protectedRoots.count <= 32 && protectedRoots.allSatisfy(\.isFileURL)
        validConstructorInput=valid;protectedPaths=valid ? protectedRoots.map(\.path):[]
    }
    private func epoch(_ invalidate:Bool=false)->UInt64 {
        Self.epochLock.lock();defer{Self.epochLock.unlock()}
        let key=root.path+"|"+rootID.uuidString,value=(Self.epochs[key] ?? 0)+(invalidate ? 1:0)
        Self.epochs[key]=value;return value
    }
    /// Explicit caller binding only. All root-level files are synchronized; ancestors are untouched.
    func initializeExplicit()throws {
        try disk(create:true){c in
            try requireNoDeliveryReservation(c)
            qualifiedBinding=false;bindingEpoch=nil;bindingEvidence=nil;let initialEpoch=epoch(true)
            let names=try list(c.root,limit:28)
            let allowed:Set<String>=["provisioning.lock","operations","root-binding.json","root-binding.json.stage","genesis.json","genesis.json.stage","head.json","head.json.stage","delivery.intent","delivery.intent.stage","delivery.binding","delivery.binding.stage","delivery.command","delivery.command.stage","delivery.plan","delivery.plan.stage","delivery.confirm","delivery.confirm.stage","native-join.intent","native-join.intent.stage","native-join.binding","native-join.binding.stage","native-join.candidate","native-join.candidate.stage","native-join.confirm","native-join.confirm.stage"]
            guard Set(names).isSubset(of:allowed) else{throw Failure.conflict}
            let binding:Node
            if let existing=try either(c.root,"root-binding.json",limit:16384), !isLiveEmpty(existing,"root-binding.json.stage") {
                let b=try decodeBinding(existing.bytes)
                try checkBinding(c,b,node:existing)
                binding=existing
            } else {
                // Any unknown partial root setup is evidence, not initialization permission.
                guard try list(c.ops,limit:4).isEmpty else{throw Failure.conflict}
                let bID=try allocate(c.root,"root-binding.json.stage",kind:.binding)
                let gID=try allocate(c.root,"genesis.json.stage",kind:.genesis)
                let hID=try allocate(c.root,"head.json.stage",kind:.head)
                let b=Binding(schemaVersion:1,rootID:rootID,path:root.path,protectedPaths:protectedPaths,directory:c.directory,lock:c.lockID,operations:c.opsID,selfID:bID,genesisID:gID,initialHeadID:hID)
                binding=Node(identity:bID,bytes:try encode(b))
                try fill(c.root,"root-binding.json.stage",binding,kind:.binding)
                let genesis=Node(identity:gID,bytes:try encode(Genesis(schemaVersion:1,binding:binding,initialHeadID:hID)))
                try fill(c.root,"genesis.json.stage",genesis,kind:.genesis)
                try fill(c.root,"head.json.stage",Node(identity:hID,bytes:try encode(Head(schemaVersion:1,genesisID:gID,operationID:nil,intentID:nil))),kind:.head)
            }
            let b=try decodeBinding(binding.bytes)
            var genesis=try requireEither(c.root,"genesis.json",limit:32768)
            if genesis.bytes.isEmpty {
                guard genesis.identity == b.genesisID,try read(c.root,"genesis.json",limit:32768) == nil else{throw Failure.conflict}
                genesis=Node(identity:genesis.identity,bytes:try encode(Genesis(schemaVersion:1,binding:binding,initialHeadID:b.initialHeadID)))
                try fill(c.root,"genesis.json.stage",genesis,kind:.genesis)
            }
            let g=try decodeGenesis(genesis.bytes)
            guard genesis.identity == b.genesisID,g.binding == binding,g.initialHeadID == b.initialHeadID else{throw Failure.conflict}
            try promote(c,parent:c.root,name:"root-binding.json",expected:binding,kind:.binding)
            try promote(c,parent:c.root,name:"genesis.json",expected:genesis,kind:.genesis)
            if try list(c.ops,limit:1548).isEmpty {
                var h=try requireEither(c.root,"head.json",limit:8192)
                if h.bytes.isEmpty {
                    guard h.identity == b.initialHeadID,try read(c.root,"head.json",limit:8192) == nil else{throw Failure.conflict}
                    h=Node(identity:h.identity,bytes:try encode(Head(schemaVersion:1,genesisID:b.genesisID,operationID:nil,intentID:nil)))
                    try fill(c.root,"head.json.stage",h,kind:.head)
                }
                guard h.identity == b.initialHeadID,try decodeHead(h.bytes) == Head(schemaVersion:1,genesisID:b.genesisID,operationID:nil,intentID:nil) else{throw Failure.conflict}
                try promote(c,parent:c.root,name:"head.json",expected:h,kind:.head)
            } else { _ = try inventory(c) }
            try syncExisting(c.root,"root-binding.json",binding,kind:.binding)
            try syncExisting(c.root,"genesis.json",genesis,kind:.genesis)
            try sync(c.lock);try sync(c.ops);try sync(c.root);try check(c)
            guard epoch() == initialEpoch else{throw Failure.uncertain}
            bindingEvidence=["binding":binding,"genesis":genesis,"head":try require(c.root,"head.json",limit:8192)]
            bindingEpoch=initialEpoch;qualifiedBinding=true
        }
    }
    func stageExact(_ plan:DeviceValidatedProvisioningPlan)throws->Receipt {
        let body = try checked(plan)
        return try disk{c in
            try requireNoDeliveryReservation(c) // Outside the legacy recovery catch; cannot be swallowed.
            try requireSameLiveInput(plan)
            let state=try inventory(c)
            if state.operation == nil {
                guard qualifiedBinding,bindingEpoch == epoch(),bindingEvidence == state.nodes else{throw Failure.uncertain}
            } else {
                guard state.completed,state.operation != plan.operationID,let q=qualifiedCompletion,q.epoch == epoch(),q.nodes == state.nodes else{throw Failure.uncertain}
                guard let previousIntent=state.intent else{throw Failure.conflict}
                let previous=try ProvisioningIntentCodec.decode(previousIntent)
                guard previous.roots == body.roots,body.expectedOld == q.envelope else{throw Failure.conflict}
            }
            guard state.terminalCount < Self.terminalLimit,state.intentBytes <= Self.retainedIntentLimit-plan.canonicalBytes.count else{throw Failure.capacity}
            intentAntecedents[plan.operationID]=state.nodes
            return try finish(c,plan:plan)
        }
    }
    /// Requires the original genuinely validated plan. Restored public bytes alone are not private proof.
    func recommitExact(_ plan:DeviceValidatedProvisioningPlan)throws->Receipt {
        _ = try checked(plan)
        return try disk{c in
            try requireNoDeliveryReservation(c) // Outside the legacy recovery catch; cannot be swallowed.
            try requireSameLiveInput(plan)
            do {
                let state=try inventory(c)
                guard state.operation == nil || state.operation == plan.operationID || state.completed && liveInputs[plan.operationID] != nil else{throw Failure.capacity}
                if state.operation == plan.operationID,let bytes=state.intent {guard bytes == plan.canonicalBytes else{throw Failure.conflict}}
            } catch {
                let prefix=plan.operationID.uuidString.lowercased()
                let files=try list(c.ops,limit:1548)
                let own=files.filter{$0.hasPrefix(prefix)}
                guard !own.isEmpty,liveInputs[plan.operationID] == plan.canonicalBytes,own.allSatisfy({name in
                    guard let n=try? read(c.ops,name,limit:ProvisioningIntentCodec.limit) else{return false}
                    let staged=name.hasSuffix(".stage") ? name:name+".stage"
                    return live[staged] == n.identity
                }) else{throw error}
                if let original=intentAntecedents[plan.operationID] {
                    guard try require(c.root,"root-binding.json",limit:16384) == original["binding"],try require(c.root,"genesis.json",limit:32768) == original["genesis"] else{throw error}
                    if try either(c.ops,prefix+".binding.json",limit:32768) == nil {guard try require(c.root,"head.json",limit:8192) == original["head"] else{throw error}}
                }
            }
            return try finish(c,plan:plan)
        }
    }
    func inspectPendingExact()throws->Diagnostic? {
        try disk{c in let s=try inventory(c);guard !s.completed,let id=s.operation,let bytes=s.intent else{return nil};return Diagnostic(operationID:id,exactIntentBytes:bytes)}
    }
    /// Current retained intent only. Diagnostic data is neither structural acknowledgment nor capacity.
    func inspectLatestRetainedIntentExact()throws->Diagnostic? {
        try disk{c in let s=try inventory(c);guard let id=s.operation,let bytes=s.intent else{return nil};return .init(operationID:id,exactIntentBytes:bytes)}
    }
    func verify(_ receipt:Receipt)throws {
        try disk{c in
            let before=epoch(),s=try inventory(c)
            guard s.complete,receipt.matches(ObjectIdentifier(self),rootID,before,s.nodes),epoch() == before else{throw Failure.uncertain}
        }
    }
    private func checked(_ plan:DeviceValidatedProvisioningPlan)throws->ProvisioningIntentBody {
        let b=try ProvisioningIntentCodec.decode(plan.canonicalBytes)
        guard b.roots.journalID == rootID,b.roots == plan.roots,b.operationID == plan.operationID else{throw Failure.conflict};return b
    }
    private func finish(_ c:Context,plan:DeviceValidatedProvisioningPlan)throws->Receipt {
        try requireNoDeliveryReservation(c)
        try requireSameLiveInput(plan)
        if liveInputs[plan.operationID] == nil {
            guard liveInputs.count < Self.terminalLimit+1,liveInputs.values.reduce(0,{$0+$1.count}) <= Self.retainedIntentLimit-plan.canonicalBytes.count else{throw Failure.capacity}
            liveInputs[plan.operationID]=plan.canonicalBytes
        }
        for id in Array(completionLive.keys) where id != plan.operationID {completionLive.removeValue(forKey:id)}
        qualifiedBinding=false;bindingEpoch=nil;bindingEvidence=nil;qualifiedCompletion=nil;pendingCompletion=nil;let attemptEpoch=epoch(true)
        guard try read(c.root,"root-binding.json.stage",limit:16384) == nil,try read(c.root,"genesis.json.stage",limit:32768) == nil else{throw Failure.conflict}
        let bNode=try require(c.root,"root-binding.json",limit:16384),gNode=try require(c.root,"genesis.json",limit:32768)
        let b=try decodeBinding(bNode.bytes);try checkBinding(c,b,node:bNode)
        guard try decodeGenesis(gNode.bytes).binding == bNode else{throw Failure.conflict}
        // Binding durability is repaired before any new intent effects, including fresh instances.
        try syncExisting(c.root,"root-binding.json",bNode,kind:.binding);try syncExisting(c.root,"genesis.json",gNode,kind:.genesis)
        try sync(c.lock);try sync(c.ops);try sync(c.root);try check(c);qualifiedBinding=true
        let base=plan.operationID.uuidString.lowercased(),intentName=base+".intent.json",attemptName=base+".binding.json",confirmationName=base+".confirm.json"
        let attemptNode:Node
        if let existing=try either(c.ops,attemptName,limit:32768), !isLiveEmpty(existing,attemptName+".stage") {
            let a=try decodeAttempt(existing.bytes)
            guard a.operationID == plan.operationID,a.selfID == existing.identity,a.intentByteCount == plan.canonicalBytes.count else{throw Failure.conflict}
            attemptNode=existing
        } else {
            let head=try require(c.root,"head.json",limit:8192)
            let predecessor=try decodeHead(head.bytes)
            guard predecessor.operationID == nil && head.identity == b.initialHeadID || predecessor.schemaVersion == 2 && predecessor.completed == true else{throw Failure.conflict}
            let iID=try allocate(c.ops,intentName+".stage",kind:.intent)
            try fill(c.ops,intentName+".stage",Node(identity:iID,bytes:plan.canonicalBytes),kind:.intent)
            let hID=try allocate(c.root,"head.json.stage",kind:.head)
            let candidate=Node(identity:hID,bytes:try encode(Head(schemaVersion:predecessor.operationID == nil ? 1:2,genesisID:b.genesisID,operationID:plan.operationID,intentID:iID,completed:predecessor.operationID == nil ? nil:false)))
            try fill(c.root,"head.json.stage",candidate,kind:.head)
            let fID=try allocate(c.ops,confirmationName+".stage",kind:.confirmation)
            let aID=try allocate(c.ops,attemptName+".stage",kind:.attempt)
            attemptNode=Node(identity:aID,bytes:try encode(Attempt(schemaVersion:predecessor.operationID == nil ? 1:2,operationID:plan.operationID,selfID:aID,intentID:iID,confirmationID:fID,intentByteCount:plan.canonicalBytes.count,baseline:head,candidate:candidate)))
            try fill(c.ops,attemptName+".stage",attemptNode,kind:.attempt)
        }
        let a=try decodeAttempt(attemptNode.bytes)
        let intent=try requireEither(c.ops,intentName,limit:ProvisioningIntentCodec.limit)
        guard intent.identity == a.intentID,intent.bytes == plan.canonicalBytes else{throw Failure.conflict}
        try promote(c,parent:c.ops,name:attemptName,expected:attemptNode,kind:.attempt)
        try promote(c,parent:c.ops,name:intentName,expected:intent,kind:.intent)
        let current=try require(c.root,"head.json",limit:8192)
        if current == a.baseline {
            guard try require(c.root,"head.json.stage",limit:8192) == a.candidate else{throw Failure.conflict}
            try syncExisting(c.root,"head.json.stage",a.candidate,kind:.head)
            try boundary(.beforeReplace(.head));try check(c)
            guard try require(c.root,"head.json",limit:8192) == a.baseline else{throw Failure.conflict}
            guard renameat(c.root,"head.json.stage",c.root,"head.json") == 0 else{throw failure()}
            try boundary(.afterReplace(.head))
        } else {
            let observed=try decodeHead(current.bytes)
            guard current == a.candidate || observed.schemaVersion == 2 && observed.completed == true && observed.operationID == plan.operationID else{throw Failure.conflict}
        }
        let installed=try require(c.root,"head.json",limit:8192)
        try syncExisting(c.root,"head.json",installed,kind:.head);try sync(c.root);try boundary(.afterDirectorySync(.head))
        let confirmation:Node
        if let existing=try either(c.ops,confirmationName,limit:65536), !(existing.bytes.isEmpty && existing.identity == a.confirmationID) {
            let f=try decodeConfirmation(existing.bytes)
            guard f.selfID == a.confirmationID,f.selfID == existing.identity,f.attempt == attemptNode,f.head == a.candidate else{throw Failure.conflict};confirmation=existing
        } else {
            let captured=try require(c.ops,confirmationName+".stage",limit:65536)
            let id=captured.identity
            guard id == a.confirmationID else{throw Failure.conflict}
            confirmation=Node(identity:id,bytes:try encode(Confirmation(schemaVersion:1,selfID:id,attempt:attemptNode,head:a.candidate)))
            try fill(c.ops,confirmationName+".stage",confirmation,kind:.confirmation)
        }
        try promote(c,parent:c.ops,name:confirmationName,expected:confirmation,kind:.confirmation)
        try check(c)
        let state=try inventory(c)
        guard state.complete,state.intent == plan.canonicalBytes,epoch() == attemptEpoch else{throw Failure.uncertain}
        intentAntecedents.removeValue(forKey:plan.operationID)
        return Receipt(ObjectIdentifier(self),rootID,attemptEpoch,state.nodes)
    }
    private struct RetainedOperation {let baseline:Node,pending:Node,completedHead:Node?,completed:Bool}
    private func inventory(_ c:Context,allowDeliveryAttachment:Bool=false)throws->State {
        try check(c)
        if !allowDeliveryAttachment {try requireNoNativeJoin(c)
            guard try deliveryLeaves(c).isEmpty else{throw Failure.conflict}}
        guard try read(c.root,"root-binding.json.stage",limit:16384) == nil,try read(c.root,"genesis.json.stage",limit:32768) == nil else{throw Failure.conflict}
        let binding=try require(c.root,"root-binding.json",limit:16384),genesis=try require(c.root,"genesis.json",limit:32768)
        let b=try decodeBinding(binding.bytes),g=try decodeGenesis(genesis.bytes);try checkBinding(c,b,node:binding)
        guard genesis.identity == b.genesisID,g.binding == binding,g.initialHeadID == b.initialHeadID else{throw Failure.conflict}
        let names=try list(c.ops,limit:1548),head=try require(c.root,"head.json",limit:8192),h=try decodeHead(head.bytes)
        guard h.genesisID == b.genesisID else{throw Failure.conflict}
        var nodes=["binding":binding,"genesis":genesis,"head":head]
        if names.isEmpty {
            guard head.identity == b.initialHeadID,h.operationID == nil,h.intentID == nil,try read(c.root,"head.json.stage",limit:8192) == nil else{throw Failure.conflict}
            return State(operation:nil,intent:nil,complete:false,nodes:nodes,completed:false,terminalCount:0,intentBytes:0)
        }
        let suffixes:Set<String>=[".intent.json",".binding.json",".confirm.json",".completion.json",".completion-binding.json",".completion-confirm.json"]
        var ids=Set<UUID>()
        for name in names {
            let prefix=String(name.prefix(36)),suffix=String(name.dropFirst(36)),plain=suffix.hasSuffix(".stage") ? String(suffix.dropLast(6)):suffix
            guard let id=UUID(uuidString:prefix),prefix == id.uuidString.lowercased(),suffixes.contains(plain) else{throw Failure.conflict};ids.insert(id)
        }
        guard ids.count <= Self.terminalLimit+1 else{throw Failure.capacity}
        var pending:[UUID]=[]
        for id in ids {if try read(c.ops,id.uuidString.lowercased()+".completion-confirm.json",limit:65536) == nil {pending.append(id)}}
        guard pending.count <= 1,let current=pending.first ?? h.operationID,ids.contains(current) else{throw Failure.conflict}
        var records:[UUID:RetainedOperation]=[:],total=0,terminals=0,currentIntent:Data?,currentComplete=false,currentCompleted=false
        for op in ids {
            let prefix=op.uuidString.lowercased(),attempt=try requireEither(c.ops,prefix+".binding.json",limit:32768),a=try decodeAttempt(attempt.bytes)
            let intent=try requireEither(c.ops,prefix+".intent.json",limit:ProvisioningIntentCodec.limit),body=try ProvisioningIntentCodec.decode(intent.bytes)
            guard a.selfID == attempt.identity,a.operationID == op,intent.identity == a.intentID,intent.bytes.count == a.intentByteCount,body.operationID == op,body.roots.journalID == rootID else{throw Failure.conflict}
            guard total <= Self.retainedIntentLimit-intent.bytes.count else{throw Failure.capacity};total += intent.bytes.count
            let pending=try decodeHead(a.candidate.bytes),baseline=try decodeHead(a.baseline.bytes)
            guard pending.genesisID == b.genesisID,pending.operationID == op,pending.intentID == a.intentID,pending.completed != true else{throw Failure.conflict}
            if a.schemaVersion == 1 {
                guard a.baseline.identity == b.initialHeadID,baseline == Head(schemaVersion:1,genesisID:b.genesisID,operationID:nil,intentID:nil),pending.schemaVersion == 1 else{throw Failure.conflict}
            } else {guard baseline.schemaVersion == 2,baseline.completed == true,pending.schemaVersion == 2 else{throw Failure.conflict}}
            let proofNode=try requireEither(c.ops,prefix+".confirm.json",limit:65536)
            guard proofNode.identity == a.confirmationID else{throw Failure.conflict}
            var originalComplete=false
            if !proofNode.bytes.isEmpty {
                let proof=try decodeConfirmation(proofNode.bytes)
                guard proof.selfID == proofNode.identity,proof.attempt == attempt,proof.head == a.candidate else{throw Failure.conflict}
                originalComplete=try read(c.ops,prefix+".confirm.json",limit:65536) != nil && read(c.ops,prefix+".binding.json",limit:32768) != nil && read(c.ops,prefix+".intent.json",limit:ProvisioningIntentCodec.limit) != nil
            }
            var completedHead:Node?,complete=false,localNodes=["attempt":attempt,"intent":intent,"confirmation":proofNode]
            let cbName=prefix+".completion-binding.json",completionName=prefix+".completion.json",cfName=prefix+".completion-confirm.json"
            let cbNode=try either(c.ops,cbName,limit:32768),completionNode=try either(c.ops,completionName,limit:Self.completionLimit),cfNode=try either(c.ops,cfName,limit:65536)
            if let cbNode,!cbNode.bytes.isEmpty {
                let cb=try decodeCompletionBinding(cbNode.bytes)
                guard originalComplete,cb.selfID == cbNode.identity,cb.operationID == op,cb.baseline == a.candidate,
                      let completionNode,completionNode.identity == cb.completionID else{throw Failure.conflict}
                let completion=try decodeCompletion(completionNode.bytes)
                guard completion.operationID == op,completion.intentID == a.intentID,completion.structuralRootID == body.roots.structuralID,completion.envelope == body.candidate else{throw Failure.conflict}
                let finished=try decodeHead(cb.candidate.bytes)
                guard finished.schemaVersion == 2,finished.genesisID == b.genesisID,finished.operationID == op,finished.intentID == a.intentID,finished.completed == true,finished.completionID == cb.completionID else{throw Failure.conflict}
                completedHead=cb.candidate;localNodes["completionBinding"]=cbNode;localNodes["completion"]=completionNode
                if let cfNode {
                    guard cfNode.identity == cb.confirmationID else{throw Failure.conflict};localNodes["completionConfirmation"]=cfNode
                    if !cfNode.bytes.isEmpty {
                        let cf=try decodeCompletionConfirmation(cfNode.bytes)
                        guard cf.selfID == cfNode.identity,cf.binding == cbNode,cf.head == cb.candidate else{throw Failure.conflict}
                        complete=try read(c.ops,cbName,limit:32768) != nil && read(c.ops,completionName,limit:Self.completionLimit) != nil && read(c.ops,cfName,limit:65536) != nil
                    }
                }
            } else if cbNode != nil || completionNode != nil || cfNode != nil {
                // Unknown partial creation is never adopted. Only exact captured live identities may
                // reach a fixed retry; none of these observations acknowledges completion.
                guard op == current,completionLive[op] != nil else{throw Failure.conflict}
                for (name,node) in [(cbName,cbNode),(completionName,completionNode),(cfName,cfNode)] {
                    if let node {guard live[name+".stage"] == node.identity else{throw Failure.conflict};localNodes[name]=node}
                }
            }
            if op != current {
                guard originalComplete,complete else{throw Failure.conflict}
                guard !names.contains(where:{$0.hasPrefix(prefix) && $0.hasSuffix(".stage")}) else{throw Failure.conflict}
            }
            if complete {terminals += 1}
            records[op]=RetainedOperation(baseline:a.baseline,pending:a.candidate,completedHead:completedHead,completed:complete)
            if op == current {
                guard head == a.baseline || head == a.candidate || head == completedHead else{throw Failure.conflict}
                if let staged=try read(c.root,"head.json.stage",limit:8192) {
                    guard staged == a.candidate || staged == completedHead || live["head.json.stage"] == staged.identity && completionLive[op] != nil else{throw Failure.conflict}
                    nodes["headStage"]=staged
                }
                currentIntent=intent.bytes;currentComplete=originalComplete;currentCompleted=complete && head == completedHead
                for (key,value) in localNodes {nodes[key]=value}
            }
        }
        var visited=Set<UUID>(),cursor=current
        while true {
            guard visited.insert(cursor).inserted,let record=records[cursor] else{throw Failure.conflict}
            let previous=try decodeHead(record.baseline.bytes)
            if previous.operationID == nil {guard record.baseline.identity == b.initialHeadID else{throw Failure.conflict};break}
            guard let id=previous.operationID,let predecessor=records[id],predecessor.completed,predecessor.completedHead == record.baseline else{throw Failure.conflict};cursor=id
        }
        guard visited.count == records.count,terminals <= Self.terminalLimit else{throw Failure.conflict}
        return State(operation:current,intent:currentIntent,complete:currentComplete,nodes:nodes,completed:currentCompleted,terminalCount:terminals,intentBytes:total)
    }
    /// Original antecedents remain fixed across a live failed attempt. Fresh explicit intent repair
    /// can supply a new genuine receipt; visible completion bytes never reconstruct this capability.
    func verifyCompletionAntecedent(_ receipt:Receipt,plan:DeviceValidatedProvisioningPlan,resourcePermit:DeviceLocalResourcePermit)throws {
        _ = try checked(plan)
        try disk(resourcePermit:resourcePermit){c in try completionAntecedent(receipt,plan:plan,c:c)}
    }
    private func completionAntecedent(_ receipt:Receipt,plan:DeviceValidatedProvisioningPlan,c:Context)throws {
        let state=try inventory(c),now=epoch()
        guard state.complete,state.operation == plan.operationID,state.intent == plan.canonicalBytes else{throw Failure.conflict}
        if receipt.matches(ObjectIdentifier(self),rootID,now,state.nodes) {return}
        guard let live=completionLive[plan.operationID],live.plan == plan.canonicalBytes,live.activeEpoch == now,
              receipt.matches(ObjectIdentifier(self),rootID,live.originalEpoch,live.original) else{throw Failure.uncertain}
        for key in ["binding","genesis","attempt","intent","confirmation"] {guard state.nodes[key] == live.original[key] else{throw Failure.conflict}}
    }
    func performCompletionExact(_ receipt:Receipt,plan:DeviceValidatedProvisioningPlan,envelope:Data,
        commandPermit:DeviceProvisioningCompletionCommandPermit)throws->CompletionTransition {
        guard envelope.count <= 128*1024,plan.canonicalBytes.count <= ProvisioningIntentCodec.limit else{throw Failure.capacity}
        let body=try checked(plan),candidate=try StructuralStoreCodec.envelope(envelope)
        guard envelope == body.candidate,candidate.operationID == plan.operationID else{throw Failure.conflict}
        try commandPermit.begin(ObjectIdentifier(self));defer{commandPermit.end()}
        guard let c=borrowedResourceContext else{throw DeviceLocalResourceGateFailure.invalidScope}
        try requireNoDeliveryReservation(c)
        try completionAntecedent(receipt,plan:plan,c:c)
        let state=try inventory(c)
        guard state.completed || state.terminalCount < Self.terminalLimit,let intent=state.nodes["intent"],let originalAttempt=state.nodes["attempt"] else{throw Failure.capacity}
        let a=try decodeAttempt(originalAttempt.bytes)
        let completionBytes=try completionEncode(Completion(schemaVersion:2,operationID:plan.operationID,structuralRootID:body.roots.structuralID,generationID:candidate.snapshot.generationID,intentID:intent.identity,envelope:envelope))
        // Exact preflight/latch precede epoch invalidation and all completion effects.
        if let previous=completionLive[plan.operationID] {guard previous.plan == plan.canonicalBytes,previous.envelope == envelope else{throw Failure.conflict}}
        if receipt.matches(ObjectIdentifier(self),rootID,epoch(),state.nodes) {
            completionLive[plan.operationID]=CompletionLive(plan:plan.canonicalBytes,envelope:envelope,originalEpoch:epoch(),original:state.nodes,activeEpoch:epoch())
        }
        guard var liveAttempt=completionLive[plan.operationID] else{throw Failure.conflict}
        qualifiedCompletion=nil;pendingCompletion=nil;qualifiedBinding=false;bindingEpoch=nil;bindingEvidence=nil
        let attemptEpoch=epoch(true);liveAttempt.activeEpoch=attemptEpoch;completionLive[plan.operationID]=liveAttempt
        let binding=try require(c.root,"root-binding.json",limit:16384),genesis=try require(c.root,"genesis.json",limit:32768)
        guard binding == liveAttempt.original["binding"],genesis == liveAttempt.original["genesis"] else{throw Failure.conflict}
        try syncExisting(c.root,"root-binding.json",binding,kind:.binding);try syncExisting(c.root,"genesis.json",genesis,kind:.genesis)
        try sync(c.lock);try sync(c.ops);try sync(c.root);try check(c)
        let prefix=plan.operationID.uuidString.lowercased(),payloadName=prefix+".completion.json",bindName=prefix+".completion-binding.json",confirmName=prefix+".completion-confirm.json"
        let bindNode:Node
        if let existing=try either(c.ops,bindName,limit:32768),!isLiveEmpty(existing,bindName+".stage") {bindNode=existing}
        else {
            let payloadID=try allocate(c.ops,payloadName+".stage",kind:.completion)
            try fill(c.ops,payloadName+".stage",Node(identity:payloadID,bytes:completionBytes),kind:.completion)
            let headID=try allocate(c.root,"head.json.stage",kind:.completionHead)
            let b=try decodeBinding(binding.bytes)
            let head=Node(identity:headID,bytes:try encode(Head(schemaVersion:2,genesisID:b.genesisID,operationID:plan.operationID,intentID:intent.identity,completed:true,completionID:payloadID)))
            try fill(c.root,"head.json.stage",head,kind:.completionHead)
            let confirmID=try allocate(c.ops,confirmName+".stage",kind:.completionConfirmation),bindID=try allocate(c.ops,bindName+".stage",kind:.completionBinding)
            bindNode=Node(identity:bindID,bytes:try encode(CompletionBinding(schemaVersion:2,operationID:plan.operationID,selfID:bindID,completionID:payloadID,confirmationID:confirmID,baseline:a.candidate,candidate:head)))
            try fill(c.ops,bindName+".stage",bindNode,kind:.completionBinding)
        }
        let cb=try decodeCompletionBinding(bindNode.bytes),payload=try requireEither(c.ops,payloadName,limit:Self.completionLimit)
        guard cb.selfID == bindNode.identity,cb.operationID == plan.operationID,cb.baseline == a.candidate,payload.identity == cb.completionID,payload.bytes == completionBytes else{throw Failure.conflict}
        try promote(c,parent:c.ops,name:bindName,expected:bindNode,kind:.completionBinding)
        try promote(c,parent:c.ops,name:payloadName,expected:payload,kind:.completion)
        let head=try require(c.root,"head.json",limit:8192)
        if head == cb.baseline {
            guard try require(c.root,"head.json.stage",limit:8192) == cb.candidate else{throw Failure.conflict}
            try syncExisting(c.root,"head.json.stage",cb.candidate,kind:.completionHead);try boundary(.beforeReplace(.completionHead));try check(c)
            guard try require(c.root,"head.json",limit:8192) == cb.baseline else{throw Failure.conflict}
            guard renameat(c.root,"head.json.stage",c.root,"head.json") == 0 else{throw failure()};try boundary(.afterReplace(.completionHead))
        } else {guard head == cb.candidate else{throw Failure.conflict}}
        try syncExisting(c.root,"head.json",cb.candidate,kind:.completionHead);try sync(c.root);try boundary(.afterDirectorySync(.completionHead))
        let proof:Node
        if let existing=try either(c.ops,confirmName,limit:65536),!existing.bytes.isEmpty {proof=existing}
        else {
            let staged=try require(c.ops,confirmName+".stage",limit:65536)
            guard staged.identity == cb.confirmationID else{throw Failure.conflict}
            proof=Node(identity:staged.identity,bytes:try encode(CompletionConfirmation(schemaVersion:2,selfID:staged.identity,binding:bindNode,head:cb.candidate)))
            try fill(c.ops,confirmName+".stage",proof,kind:.completionConfirmation)
        }
        let confirmation=try decodeCompletionConfirmation(proof.bytes)
        guard confirmation.selfID == cb.confirmationID,confirmation.binding == bindNode,confirmation.head == cb.candidate else{throw Failure.conflict}
        try promote(c,parent:c.ops,name:confirmName,expected:proof,kind:.completionConfirmation)
        try sync(c.lock);try sync(c.ops);try sync(c.root);try check(c)
        let final=try inventory(c)
        guard final.completed,final.operation == plan.operationID,final.intent == plan.canonicalBytes,epoch() == attemptEpoch else{throw Failure.uncertain}
        for key in ["binding","genesis","attempt","intent","confirmation"] {guard final.nodes[key] == liveAttempt.original[key] else{throw Failure.conflict}}
        let transition=CompletionTransition(ObjectIdentifier(self),rootID,attemptEpoch,plan.operationID,envelope,liveAttempt.original,final.nodes)
        pendingCompletion=transition;return transition
    }
    func verifyCompletionTransition(_ original:CompletionTransition,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit){c in
            let state=try inventory(c)
            guard pendingCompletion === original,original.issuer == ObjectIdentifier(self),original.rootID == rootID,
                  original.epoch == epoch(),state.completed,state.operation == original.operationID,state.nodes == original.nodes else{throw Failure.uncertain}
            for key in ["binding","genesis","attempt","intent","confirmation"] {guard state.nodes[key] == original.original[key] else{throw Failure.conflict}}
        }
    }
    /// Gate-file publication token is issued only AFTER every scope exit succeeds. No disk reads,
    /// callbacks or qualification recapture occur here. The successor rereads exact nodes/full chain.
    func publishCompletionExact(_ transition:CompletionTransition,permit:DeviceProvisioningCompletionPublicationPermit)throws->CompletionReceipt {
        try permit.requireIdle()
        try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()}
        mutex.lock();defer{mutex.unlock()}
        // Publication has no disk context. A genuine transition retains its original epoch/nodes;
        // native join start invalidates that epoch before effects. Never recapture disk proof here.
        guard nativeJoinInput == nil,nativeJoinPending == nil,nativeJoinQualified == nil,
              attachmentInput == nil,pendingAttachment == nil,attachmentQualified == nil else{throw Failure.conflict}
        guard pendingCompletion === transition,transition.issuer == ObjectIdentifier(self),transition.rootID == rootID,transition.epoch == epoch() else{throw Failure.uncertain}
        qualifiedCompletion=transition;return CompletionReceipt(transition)
    }
    struct CompletionDiagnostic {let operationID:UUID,envelope:Data} // Never acknowledgment/qualification.
    func inspectRetainedCompletionExact(operationID:UUID)throws->CompletionDiagnostic {
        try disk{c in
            _ = try inventory(c)
            let node=try require(c.ops,operationID.uuidString.lowercased()+".completion.json",limit:Self.completionLimit),completion=try decodeCompletion(node.bytes)
            guard completion.operationID == operationID else{throw Failure.conflict}
            return CompletionDiagnostic(operationID:operationID,envelope:completion.envelope)
        }
    }
    func verifyCompletion(_ receipt:CompletionReceipt)throws {
        try disk{c in
            let state=try inventory(c),t=receipt.transition
            guard qualifiedCompletion === t,t.issuer == ObjectIdentifier(self),t.rootID == rootID,t.epoch == epoch(),state.completed,state.operation == t.operationID,state.nodes == t.nodes else{throw Failure.uncertain}
        }
    }
    private var borrowedResourceContext:Context?
    var resourceGateDescriptor:DeviceLocalResourceDescriptor {get throws{try paths();return try .existing(instance:ObjectIdentifier(self),path:root.path,rootID:rootID)}}
    func withResourceGateScope(_ permit:DeviceLocalResourcePermit,_ body:()throws->Void)throws {
        try permit.beginAcquisition(resourceGateDescriptor)
        mutex.lock();defer{permit.invalidate();mutex.unlock()}
        try diskContext(create:false,releasePermit:permit){c in
            _ = try inventory(c)
            borrowedResourceContext=c
            defer{borrowedResourceContext=nil;permit.invalidate()}
            try body();try check(c)
        }
    }
    /// Initialized-root native reservation scope only. Existing legacy scope above remains strict.
    /// A read permit supplies no mutation capability. Only the fixed native coordinator can issue
    /// its separate command permit after checked attachment/join/original genesis validation.
    func withNativeResourceGateScope(_ permit:DeviceLocalResourcePermit,_ body:()throws->Void)throws {
        try permit.beginAcquisition(resourceGateDescriptor)
        mutex.lock();defer{permit.invalidate();mutex.unlock()}
        try diskContext(create:false,releasePermit:permit){c in
            _ = try inventory(c,allowDeliveryAttachment:true)
            borrowedResourceContext=c
            defer{borrowedResourceContext=nil;permit.invalidate()}
            try body();try check(c)
        }
    }
    func inspectCompletedCurrentExact(resourcePermit:DeviceLocalResourcePermit)throws->CompletedCurrentCheckpoint {
        try disk(resourcePermit:resourcePermit){c in
            let before=epoch(),state=try inventory(c)
            guard state.complete,state.completed,let operation=state.operation,let intent=state.intent,
                  state.nodes["headStage"] == nil,!((try list(c.ops,limit:1548)).contains{$0.hasSuffix(".stage")}),let payload=state.nodes["completion"] else{throw Failure.uncertain}
            let completion=try decodeCompletion(payload.bytes),body=try ProvisioningIntentCodec.decode(intent)
            guard completion.operationID == operation,body.operationID == operation,completion.envelope == body.candidate,
                  completion.structuralRootID == body.roots.structuralID,epoch() == before else{throw Failure.conflict}
            return .init(ObjectIdentifier(self),rootID,before,operation,intent,completion.envelope,state.nodes)
        }
    }
    private func verifyCompleted(_ original:CompletedCurrentCheckpoint,_ c:Context,at expectedEpoch:UInt64)throws {
        let state=try inventory(c)
        guard original.issuer == ObjectIdentifier(self),original.rootID == rootID,epoch() == expectedEpoch,
              state.complete,state.completed,state.operation == original.operationID,state.intent == original.exactIntentBytes,
              state.nodes == original.nodes,state.nodes["headStage"] == nil,!((try list(c.ops,limit:1548)).contains{$0.hasSuffix(".stage")}) else{throw Failure.uncertain}
        guard let payload=state.nodes["completion"],try decodeCompletion(payload.bytes).envelope == original.envelopeBytes else{throw Failure.conflict}
    }
    func verifyCompletedCurrentExact(_ original:CompletedCurrentCheckpoint,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit){c in try verifyCompleted(original,c,at:original.epoch)}
    }
    /// Fixed restore sync only. Never publishes qualifiedCompletion/pendingCompletion/capacity.
    /// Missing or replaced antecedents are not repaired by adopting newly observed identities.
    func repairCompletedCurrentExact(_ original:CompletedCurrentCheckpoint,commandPermit:DeviceBoundCompletedRestorePermit)throws->CompletedRestoreTransition {
        try commandPermit.begin(ObjectIdentifier(self));defer{commandPermit.end()}
        guard let c=borrowedResourceContext else{throw Failure.uncertain}
        try requireNoDeliveryReservation(c)
        try verifyCompleted(original,c,at:original.epoch)
        let now=epoch(true);qualifiedBinding=false;bindingEpoch=nil;bindingEvidence=nil;qualifiedCompletion=nil;pendingCompletion=nil
        let prefix=original.operationID.uuidString.lowercased()
        let roots:[(String,String,Kind)]=[("binding","root-binding.json",.binding),("genesis","genesis.json",.genesis),("head","head.json",.head)]
        let records:[(String,String,Kind)]=[("intent",".intent.json",.intent),("attempt",".binding.json",.attempt),("confirmation",".confirm.json",.confirmation),("completion",".completion.json",.completion),("completionBinding",".completion-binding.json",.completionBinding),("completionConfirmation",".completion-confirm.json",.completionConfirmation)]
        for (key,name,kind) in roots {guard let node=original.nodes[key] else{throw Failure.conflict};try syncExisting(c.root,name,node,kind:kind)}
        for (key,suffix,kind) in records {guard let node=original.nodes[key] else{throw Failure.conflict};try syncExisting(c.ops,prefix+suffix,node,kind:kind)}
        try sync(c.lock);try sync(c.ops);try sync(c.root);try boundary(.afterDirectorySync(.binding));try check(c)
        try verifyCompleted(original,c,at:now)
        return .init(original,now)
    }
    func verifyCompletedRestoreTransition(_ transition:CompletedRestoreTransition,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit){c in try verifyCompleted(transition.original,c,at:transition.epoch)}
    }
    private func predecessorNodes(_ c:Context,_ state:State)throws->[String:Node] {
        guard state.complete,!state.completed,let attempt=state.nodes["attempt"] else{throw Failure.conflict}
        let a=try decodeAttempt(attempt.bytes),head=try decodeHead(a.baseline.bytes)
        guard a.schemaVersion == 2,head.completed == true,let operation=head.operationID else{throw Failure.conflict}
        let prefix=operation.uuidString.lowercased()
        let specs:[(String,Int)]=[(".intent.json",ProvisioningIntentCodec.limit),(".binding.json",32768),(".confirm.json",65536),(".completion.json",Self.completionLimit),(".completion-binding.json",32768),(".completion-confirm.json",65536)]
        var nodes:[String:Node]=[:]
        for (suffix,limit) in specs {nodes[prefix+suffix]=try require(c.ops,prefix+suffix,limit:limit)}
        let proof=try decodeCompletionConfirmation(nodes[prefix+".completion-confirm.json"]!.bytes)
        guard proof.head == a.baseline else{throw Failure.conflict}
        return nodes
    }
    func captureSuccessorPredecessorExact(_ receipt:Receipt,plan:DeviceValidatedProvisioningPlan,resourcePermit:DeviceLocalResourcePermit)throws->SuccessorPredecessorCheckpoint {
        let body=try checked(plan)
        return try disk(resourcePermit:resourcePermit){c in
            let before=epoch(),state=try inventory(c)
            guard state.operation == plan.operationID,state.intent == plan.canonicalBytes,
                  receipt.matches(ObjectIdentifier(self),rootID,before,state.nodes) else{throw Failure.uncertain}
            let retained=try predecessorNodes(c,state)
            guard let intent=retained.first(where:{$0.key.hasSuffix(".intent.json")})?.value,
                  let payload=retained.first(where:{$0.key.hasSuffix(".completion.json")})?.value else{throw Failure.conflict}
            let previous=try ProvisioningIntentCodec.decode(intent.bytes),completion=try decodeCompletion(payload.bytes)
            guard previous.roots == body.roots,completion.operationID == previous.operationID,
                  completion.envelope == body.expectedOld,epoch() == before else{throw Failure.conflict}
            return .init(ObjectIdentifier(self),rootID,before,plan.canonicalBytes,intent.bytes,state.nodes,retained)
        }
    }
    private func verifySuccessor(_ original:SuccessorPredecessorCheckpoint,_ c:Context,at expectedEpoch:UInt64)throws->State {
        let state=try inventory(c)
        guard original.issuer == ObjectIdentifier(self),original.rootID == rootID,epoch() == expectedEpoch,
              state.intent == original.successorIntent,state.nodes == original.current,
              try predecessorNodes(c,state) == original.retained else{throw Failure.uncertain}
        return state
    }
    func verifySuccessorPredecessorExact(_ original:SuccessorPredecessorCheckpoint,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit){c in _ = try verifySuccessor(original,c,at:original.epoch)}
    }
    /// Exact owned-node synchronization only, no rewind/completion/capacity publication. Original
    /// nodes survive the intentional epoch transition; no newly observed inode is adopted.
    func repairSuccessorPredecessorExact(_ original:SuccessorPredecessorCheckpoint,commandPermit:DeviceBoundGrantCommandPermit)throws->SuccessorTransition {
        try commandPermit.begin(ObjectIdentifier(self));defer{commandPermit.end()}
        guard let c=borrowedResourceContext else{throw Failure.uncertain}
        try requireNoDeliveryReservation(c)
        _ = try verifySuccessor(original,c,at:original.epoch)
        let now=epoch(true);qualifiedBinding=false;bindingEpoch=nil;bindingEvidence=nil
        for (name,node) in original.retained {
            let kind:Kind=name.hasSuffix(".completion-confirm.json") ? .completionConfirmation:name.hasSuffix(".completion-binding.json") ? .completionBinding:name.hasSuffix(".completion.json") ? .completion:name.hasSuffix(".confirm.json") ? .confirmation:name.hasSuffix(".binding.json") ? .attempt:.intent
            try syncExisting(c.ops,name,node,kind:kind)
        }
        for (key,name) in [("binding","root-binding.json"),("genesis","genesis.json"),("head","head.json")] {
            guard let node=original.current[key] else{throw Failure.conflict};try syncExisting(c.root,name,node,kind:key == "binding" ? .binding:key == "genesis" ? .genesis:.head)
        }
        let operation=try ProvisioningIntentCodec.decode(original.successorIntent).operationID
        let prefix=operation.uuidString.lowercased()
        for (key,suffix) in [("intent",".intent.json"),("attempt",".binding.json"),("confirmation",".confirm.json")] {
            guard let node=original.current[key] else{throw Failure.conflict};try syncExisting(c.ops,prefix+suffix,node,kind:key == "intent" ? .intent:key == "attempt" ? .attempt:.confirmation)
        }
        try boundary(.afterFileSync(.binding));try sync(c.lock);try sync(c.ops);try sync(c.root);try boundary(.afterDirectorySync(.binding));try check(c)
        let state=try verifySuccessor(original,c,at:now)
        return .init(original,now,.init(ObjectIdentifier(self),rootID,now,state.nodes))
    }
    func verifySuccessorTransitionExact(_ transition:SuccessorTransition,resourcePermit:DeviceLocalResourcePermit)throws {
        try disk(resourcePermit:resourcePermit){c in _ = try verifySuccessor(transition.original,c,at:transition.epoch)}
    }
    func verifyExact(_ receipt:Receipt,plan:DeviceValidatedProvisioningPlan,resourcePermit:DeviceLocalResourcePermit)throws {
        _ = try checked(plan)
        try disk(resourcePermit:resourcePermit){c in
            let before=epoch(),s=try inventory(c)
            guard s.complete,s.operation == plan.operationID,s.intent == plan.canonicalBytes,
                  receipt.matches(ObjectIdentifier(self),rootID,before,s.nodes),epoch() == before else{throw Failure.uncertain}
        }
    }
    private func disk<T>(create:Bool=false,resourcePermit:DeviceLocalResourcePermit?=nil,_ body:(Context)throws->T)throws->T {
        if let permit=resourcePermit {
            guard !create else{throw DeviceLocalResourceGateFailure.invalidScope}
            try permit.beginRead(ObjectIdentifier(self));defer{permit.endRead()}
            guard let c=borrowedResourceContext else{throw DeviceLocalResourceGateFailure.invalidScope}
            try check(c);do{let result=try body(c);try check(c);return result}catch{try check(c);throw error}
        }
        try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()}
        try paths();mutex.lock();defer{mutex.unlock()}
        return try diskContext(create:create,body)
    }
    private func diskContext<T>(create:Bool,releasePermit:DeviceLocalResourcePermit?=nil,_ body:(Context)throws->T)throws->T {
        try paths()
        let r=try directory(root.path);defer{close(r)}
        let rID=try identity(r,directory:true)
        var lock=openat(r,"provisioning.lock",O_RDWR|O_NOFOLLOW|O_NONBLOCK)
        defer{if lock >= 0{close(lock)}}
        if lock < 0 && errno == ENOENT && create {
            // Setup is owned only by this live instance until reciprocal binding is persisted.
            guard try list(r,limit:10).isEmpty else{throw Failure.conflict}
            lock=openat(r,"provisioning.lock",O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_NONBLOCK,0o600)
            guard lock >= 0 else{throw failure()};live["provisioning.lock"]=try identity(lock,directory:false)
        }
        guard lock >= 0 else{throw failure()}
        let lID=try identity(lock,directory:false)
        guard flock(lock,LOCK_EX) == 0 else{throw failure()};defer{releasePermit?.invalidate();flock(lock,LOCK_UN)}
        var ops=openat(r,"operations",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK)
        defer{if ops >= 0{close(ops)}}
        if ops < 0 && errno == ENOENT && create {
            guard live["provisioning.lock"] == lID,mkdirat(r,"operations",0o700) == 0 else{throw Failure.conflict}
            ops=openat(r,"operations",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK)
            guard ops >= 0 else{throw failure()};live["operations"]=try identity(ops,directory:true)
        }
        guard ops >= 0 else{throw failure()}
        let c=Context(root:r,lock:lock,ops:ops,directory:rID,lockID:lID,opsID:try identity(ops,directory:true))
        if try read(r,"root-binding.json",limit:16384) == nil && read(r,"root-binding.json.stage",limit:16384) == nil {
            guard create,live["provisioning.lock"] == lID,live["operations"] == c.opsID else{throw Failure.conflict}
        }
        try check(c)
        do{let result=try body(c);try check(c);return result}catch{try check(c);throw error}
    }
    private func paths()throws {
        guard validConstructorInput else{throw Failure.unsafeRoot}
        func valid(_ path:String)->Bool{path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096 && !path.unicodeScalars.contains(where:{$0.value == 0}) && !path.hasSuffix("/") && !path.contains("//") && path.split(separator:"/").allSatisfy({$0 != "." && $0 != ".."})}
        guard protectedPaths.count <= 32,valid(root.path),protectedPaths.allSatisfy(valid),Set(protectedPaths.map{Data($0.utf8)}).count == protectedPaths.count else{throw Failure.unsafeRoot}
        for p in protectedPaths {guard !overlap(root.path,p) else{throw Failure.unsafeRoot};let fd=try directory(p,allowMissing:true);if fd >= 0{close(fd)}}
    }
    private func overlap(_ a:String,_ b:String)->Bool {let x=Data(a.utf8),y=Data(b.utf8);return x == y || x.starts(with:Data((b+"/").utf8)) || y.starts(with:Data((a+"/").utf8))}
    private func directory(_ path:String,allowMissing:Bool=false)throws->Int32 {
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK);guard fd >= 0 else{throw failure()}
        do {
            for component in path.split(separator:"/") {
                let next=openat(fd,String(component),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK)
                if next < 0 && errno == ENOENT && allowMissing {close(fd);return -1}
                guard next >= 0 else{throw failure()};close(fd);fd=next
                _ = try identity(fd,directory:true)
            }
            return fd
        } catch {close(fd);throw error}
    }
    private func identity(_ fd:Int32,directory:Bool)throws->ID {
        var s=stat();guard fstat(fd,&s) == 0 else{throw failure()}
        guard (s.st_mode & S_IFMT) == (directory ? S_IFDIR:S_IFREG),directory || s.st_nlink == 1 else{throw Failure.conflict}
        return ID(device:UInt64(s.st_dev),inode:UInt64(s.st_ino))
    }
    private func check(_ c:Context)throws {
        let fd=try directory(root.path);defer{close(fd)}
        guard try identity(fd,directory:true) == c.directory,try identity(c.root,directory:true) == c.directory else{throw Failure.conflict}
        let l=openat(c.root,"provisioning.lock",O_RDONLY|O_NOFOLLOW|O_NONBLOCK);guard l >= 0 else{throw failure()};defer{close(l)}
        let o=openat(c.root,"operations",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK);guard o >= 0 else{throw failure()};defer{close(o)}
        guard try identity(l,directory:false) == c.lockID,try identity(o,directory:true) == c.opsID else{throw Failure.conflict}
        let allowed:Set<String>=["provisioning.lock","operations","root-binding.json","root-binding.json.stage","genesis.json","genesis.json.stage","head.json","head.json.stage","delivery.intent","delivery.intent.stage","delivery.binding","delivery.binding.stage","delivery.command","delivery.command.stage","delivery.plan","delivery.plan.stage","delivery.confirm","delivery.confirm.stage","native-join.intent","native-join.intent.stage","native-join.binding","native-join.binding.stage","native-join.candidate","native-join.candidate.stage","native-join.confirm","native-join.confirm.stage"]
        guard Set(try list(c.root,limit:28)).isSubset(of:allowed) else{throw Failure.conflict}
    }
    private func checkBinding(_ c:Context,_ b:Binding,node:Node)throws {
        guard b.schemaVersion == 1,b.rootID == rootID,b.path.utf8.elementsEqual(root.path.utf8),b.protectedPaths.count == protectedPaths.count,
              zip(b.protectedPaths,protectedPaths).allSatisfy({$0.utf8.elementsEqual($1.utf8)}),b.directory == c.directory,b.lock == c.lockID,b.operations == c.opsID,b.selfID == node.identity else{throw Failure.conflict}
    }
    private func list(_ fd:Int32,limit:Int)throws->[String] {
        let copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK);guard copy >= 0 else{throw failure()}
        guard let dir=fdopendir(copy) else{close(copy);throw failure()};defer{closedir(dir)}
        var names:[String]=[]
        errno=0
        while let entry=readdir(dir) {
            let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:MemoryLayout.size(ofValue:entry.pointee.d_name)){String(cString:$0)}}
            if name == "." || name == ".." {continue};guard names.count < limit else{throw Failure.capacity};names.append(name)
        }
        guard errno == 0 else{throw failure()};return names
    }
    private func read(_ parent:Int32,_ name:String,limit:Int)throws->Node? {
        let fd=openat(parent,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        if fd < 0 && errno == ENOENT{return nil};guard fd >= 0 else{throw failure()};defer{close(fd)}
        let id=try identity(fd,directory:false);var s=stat();guard fstat(fd,&s) == 0,s.st_size >= 0,s.st_size <= limit else{throw Failure.conflict}
        var bytes=Data(count:Int(s.st_size));try bytes.withUnsafeMutableBytes{buf in
            var offset=0
            while offset < buf.count {let n=FoundationRead(fd,buf.baseAddress!.advanced(by:offset),buf.count-offset);if n < 0 && errno == EINTR{continue};guard n > 0 else{throw Failure.conflict};offset += n}
        }
        var extra:UInt8=0;guard FoundationRead(fd,&extra,1) == 0,try identity(fd,directory:false) == id else{throw Failure.conflict}
        return Node(identity:id,bytes:bytes)
    }
    private func require(_ parent:Int32,_ name:String,limit:Int)throws->Node {guard let n=try read(parent,name,limit:limit) else{throw Failure.conflict};return n}
    private func either(_ parent:Int32,_ name:String,limit:Int)throws->Node? {
        let final=try read(parent,name,limit:limit),stage=try read(parent,name+".stage",limit:limit)
        guard final == nil || stage == nil else{throw Failure.conflict};return final ?? stage
    }
    private func requireEither(_ parent:Int32,_ name:String,limit:Int)throws->Node {guard let n=try either(parent,name,limit:limit) else{throw Failure.conflict};return n}
    private func isLiveEmpty(_ node:Node,_ name:String)->Bool {node.bytes.isEmpty && live[name] == node.identity}
    private func allocate(_ parent:Int32,_ name:String,kind:Kind)throws->ID {
        let key=name // Every owned staging leaf is unique within this journal.
        if let node=try read(parent,name,limit:ProvisioningIntentCodec.limit) {guard live[key] == node.identity else{throw Failure.conflict};return node.identity}
        let fd=openat(parent,name,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_NONBLOCK,0o600);guard fd >= 0 else{throw failure()};defer{close(fd)}
        let id=try identity(fd,directory:false);live[key]=id;try boundary(.afterCreate(kind));return id
    }
    private func fill(_ parent:Int32,_ name:String,_ node:Node,kind:Kind)throws {
        let fd=openat(parent,name,O_RDWR|O_NOFOLLOW|O_NONBLOCK);guard fd >= 0 else{throw failure()};defer{close(fd)}
        guard try identity(fd,directory:false) == node.identity else{throw Failure.conflict}
        guard ftruncate(fd,0) == 0 else{throw failure()}
        try node.bytes.withUnsafeBytes{buf in var offset=0;while offset < buf.count {let n=write(fd,buf.baseAddress!.advanced(by:offset),buf.count-offset);if n < 0 && errno == EINTR{continue};guard n > 0 else{throw failure()};offset += n}}
        try boundary(.afterWrite(kind));try sync(fd);try boundary(.afterFileSync(kind))
        guard try read(parent,name,limit:ProvisioningIntentCodec.limit) == node else{throw Failure.conflict}
    }
    private func syncExisting(_ parent:Int32,_ name:String,_ node:Node,kind:Kind)throws {
        guard try require(parent,name,limit:ProvisioningIntentCodec.limit) == node else{throw Failure.conflict}
        let fd=openat(parent,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);guard fd >= 0 else{throw failure()};defer{close(fd)}
        guard try identity(fd,directory:false) == node.identity else{throw Failure.conflict};try sync(fd);try boundary(.afterFileSync(kind))
        guard try require(parent,name,limit:ProvisioningIntentCodec.limit) == node else{throw Failure.conflict}
    }
    private func promote(_ c:Context,parent:Int32,name:String,expected:Node,kind:Kind)throws {
        if let final=try read(parent,name,limit:ProvisioningIntentCodec.limit) {guard final == expected,try read(parent,name+".stage",limit:ProvisioningIntentCodec.limit) == nil else{throw Failure.conflict};try syncExisting(parent,name,expected,kind:kind)}
        else {
            guard try require(parent,name+".stage",limit:ProvisioningIntentCodec.limit) == expected else{throw Failure.conflict}
            try syncExisting(parent,name+".stage",expected,kind:kind);try boundary(.beforeReplace(kind));try check(c)
            guard try read(parent,name,limit:ProvisioningIntentCodec.limit) == nil,try require(parent,name+".stage",limit:ProvisioningIntentCodec.limit) == expected else{throw Failure.conflict}
            guard renameat(parent,name+".stage",parent,name) == 0 else{throw failure()};try boundary(.afterReplace(kind))
        }
        try sync(parent);try boundary(.afterDirectorySync(kind));try check(c)
    }
    private func sync(_ fd:Int32)throws {guard fsync(fd) == 0 else{throw failure()}}
    private func failure()->Failure{.io(errno)}
    private func encode<T:Encodable>(_ value:T)throws->Data{try DeviceLocalCompleteSetBounds.encode(value,maximum:65536)}
    private func shape(_ bytes:Data,_ fields:Set<String>)throws->[String:Any]{let o=try StructuralStoreCodec.object(bytes,limit:65536);try StructuralStoreCodec.keys(o,required:fields);return o}
    private func ids(_ object:[String:Any],_ names:[String])throws {for name in names {guard let id=object[name] as? [String:Any] else{throw Failure.conflict};try StructuralStoreCodec.keys(id,required:["device","inode"])}}
    private func node(_ object:[String:Any],_ name:String)throws {guard let n=object[name] as? [String:Any] else{throw Failure.conflict};try StructuralStoreCodec.keys(n,required:["identity","bytes"]);try ids(n,["identity"])}
    private func decodeBinding(_ bytes:Data)throws->Binding {let o=try shape(bytes,["schemaVersion","rootID","path","protectedPaths","directory","lock","operations","selfID","genesisID","initialHeadID"]);try ids(o,["directory","lock","operations","selfID","genesisID","initialHeadID"]);return try canonical(Binding.self,bytes)}
    private func decodeGenesis(_ bytes:Data)throws->Genesis {let o=try shape(bytes,["schemaVersion","binding","initialHeadID"]);try node(o,"binding");try ids(o,["initialHeadID"]);let g=try canonical(Genesis.self,bytes);guard g.schemaVersion == 1 else{throw Failure.conflict};return g}
    private func decodeHead(_ bytes:Data)throws->Head {let o=try StructuralStoreCodec.object(bytes,limit:8192);try StructuralStoreCodec.keys(o,required:["schemaVersion","genesisID"],optional:["operationID","intentID","completed","completionID"]);try ids(o,["genesisID"]);if o["intentID"] != nil{try ids(o,["intentID"])};if o["completionID"] != nil{try ids(o,["completionID"])}
        let h=try canonical(Head.self,bytes)
        guard (h.operationID == nil) == (h.intentID == nil) else{throw Failure.conflict}
        if h.schemaVersion == 1 {guard h.completed == nil,h.completionID == nil else{throw Failure.conflict}}
        else {guard h.schemaVersion == 2,h.operationID != nil,let completed=h.completed,completed == (h.completionID != nil) else{throw Failure.conflict}}
        return h}
    private func decodeAttempt(_ bytes:Data)throws->Attempt {let o=try shape(bytes,["schemaVersion","operationID","selfID","intentID","confirmationID","intentByteCount","baseline","candidate"]);try ids(o,["selfID","intentID","confirmationID"]);try node(o,"baseline");try node(o,"candidate");let a=try canonical(Attempt.self,bytes);guard [1,2].contains(a.schemaVersion),(1...ProvisioningIntentCodec.limit).contains(a.intentByteCount) else{throw Failure.conflict};return a}
    private func decodeConfirmation(_ bytes:Data)throws->Confirmation {let o=try shape(bytes,["schemaVersion","selfID","attempt","head"]);try ids(o,["selfID"]);try node(o,"attempt");try node(o,"head");let f=try canonical(Confirmation.self,bytes);guard f.schemaVersion == 1 else{throw Failure.conflict};return f}
    private func completionEncode<T:Encodable>(_ value:T)throws->Data {try DeviceLocalCompleteSetBounds.encode(value,maximum:Self.completionLimit)}
    private func decodeCompletion(_ bytes:Data)throws->Completion {
        let o=try StructuralStoreCodec.object(bytes,limit:Self.completionLimit)
        try StructuralStoreCodec.keys(o,required:["schemaVersion","operationID","structuralRootID","generationID","intentID","envelope"]);try ids(o,["intentID"])
        let value=try JSONDecoder().decode(Completion.self,from:bytes)
        guard value.schemaVersion == 2,value.envelope.count <= 128*1024,try completionEncode(value) == bytes else{throw Failure.conflict}
        let envelope=try StructuralStoreCodec.envelope(value.envelope)
        guard envelope.operationID == value.operationID,envelope.snapshot.generationID == value.generationID else{throw Failure.conflict};return value
    }
    private func decodeCompletionBinding(_ bytes:Data)throws->CompletionBinding {
        let o=try shape(bytes,["schemaVersion","operationID","selfID","completionID","confirmationID","baseline","candidate"])
        try ids(o,["selfID","completionID","confirmationID"]);try node(o,"baseline");try node(o,"candidate")
        let value=try canonical(CompletionBinding.self,bytes);guard value.schemaVersion == 2 else{throw Failure.conflict};return value
    }
    private func decodeCompletionConfirmation(_ bytes:Data)throws->CompletionConfirmation {
        let o=try shape(bytes,["schemaVersion","selfID","binding","head"]);try ids(o,["selfID"]);try node(o,"binding");try node(o,"head")
        let value=try canonical(CompletionConfirmation.self,bytes);guard value.schemaVersion == 2 else{throw Failure.conflict};return value
    }
    /// Pending immutable attachment only. No stage/release/terminal/native execution API.
    /// Its reservation occupies the same journal pending slot; all legacy inventory consumers block.
    private struct DeliveryIntent:Codable {
        let schemaVersion:Int,rootID:UUID,nativeOperationID:UUID
        let association:DeviceNativeDeliveryCommandBinding.Association
        let commandBytes:Int,commandHash:String
        let bindingID:ID,genesisID:ID,head:Node,bindingHash:String,genesisHash:String
    }
    private struct DeliveryBinding:Codable {
        let schemaVersion:Int,selfID:ID,intent:Node,commandID:ID,planID:ID,confirmationID:ID
    }
    private struct DeliveryConfirmation:Codable {let schemaVersion:Int,selfID:ID,binding:Node,command:Node,plan:Node}
    final class DeliveryAttachmentReceipt {
        let nativeOperationID:UUID,remoteOperationID:UUID
        fileprivate let issuer:ObjectIdentifier,rootID:UUID,epoch:UInt64,nodes:[String:Node]
        fileprivate init(_ issuer:ObjectIdentifier,_ rootID:UUID,_ epoch:UInt64,_ op:UUID,_ remote:UUID,_ nodes:[String:Node]) {
            self.issuer=issuer;self.rootID=rootID;self.epoch=epoch;nativeOperationID=op;remoteOperationID=remote;self.nodes=nodes
        }
    }
    struct DeliveryAttachmentDiagnostic {let nativeOperationID:UUID,remoteOperationID:UUID} // No ACK/authority.
    private static let deliveryNames:Set<String>=["delivery.intent","delivery.binding","delivery.command","delivery.plan","delivery.confirm"]
    private func deliveryLeaves(_ c:Context)throws->[String] {
        try list(c.root,limit:28).filter{Self.deliveryNames.contains($0) || Self.deliveryNames.contains(String($0.dropLast(6))) && $0.hasSuffix(".stage")}
    }
    private func deliveryInput(_ input:DeviceNativeDeliveryCommandBinding)throws->Data {
        guard input.journalRootID == rootID,input.commandBytes.count <= 16384,input.planBytes.count <= 65536 else{throw Failure.conflict}
        // Exact bounded raw-byte latch; not a persisted private credential or authority assertion.
        var b=Data();b.append(contentsOf:input.nativeOperationID.uuidString.utf8);b.append(input.commandBytes);b.append(0);b.append(input.planBytes)
        return b
    }
    func publishDeliveryAttachmentExact(_ input:DeviceNativeDeliveryCommandBinding)throws->DeliveryAttachmentReceipt {
        let exact=try deliveryInput(input)
        let pending=try disk{c in
            guard try deliveryLeaves(c).isEmpty else{throw Failure.conflict}
            let state=try inventory(c,allowDeliveryAttachment:true)
            guard state.terminalCount < Self.terminalLimit,state.operation == nil || state.completed else{throw Failure.capacity}
            if state.operation == nil {
                guard qualifiedBinding,bindingEpoch == epoch(),bindingEvidence == state.nodes else{throw Failure.uncertain}
            } else {guard let q=qualifiedCompletion,q.epoch == epoch(),q.nodes == state.nodes else{throw Failure.uncertain}}
            // Reserve against full original journal state before attachment creation.
            if let old=attachmentInput {guard old == exact else{throw Failure.conflict}}
            let intent=try makeDeliveryIntent(input,state)
            try deliveryRepresentationPreflight(intent)
            attachmentInput=exact
            return try finishDelivery(c,input,intent)
        }
        return try publishPendingAttachment(pending)
    }
    func recommitDeliveryAttachmentExact(_ input:DeviceNativeDeliveryCommandBinding)throws->DeliveryAttachmentReceipt {
        let exact=try deliveryInput(input)
        let pending=try disk{c in
            try requireNoNativeJoin(c)
            if let old=attachmentInput {guard old == exact else{throw Failure.conflict}}
            let state=try inventory(c,allowDeliveryAttachment:true)
            guard state.terminalCount < Self.terminalLimit,state.operation == nil || state.completed else{throw Failure.capacity}
            let intent:Node
            if let node=try either(c.root,"delivery.intent",limit:32768),!node.bytes.isEmpty {
                let recorded=try decodeDeliveryIntent(node.bytes)
                try matchDelivery(recorded,input,state)
                if let binding=try either(c.root,"delivery.binding",limit:32768),!binding.bytes.isEmpty {
                    guard try decodeDeliveryBinding(binding.bytes).intent == node else{throw Failure.conflict}
                } else {
                    // Before reciprocal binding exists, only the original live inode/input can repair.
                    guard attachmentInput == exact,live["delivery.intent.stage"] == node.identity else{throw Failure.conflict}
                }
                intent=node
            } else {
                guard attachmentInput == exact,let node=try read(c.root,"delivery.intent.stage",limit:32768),live["delivery.intent.stage"] == node.identity else{throw Failure.conflict}
                intent=Node(identity:node.identity,bytes:try makeDeliveryIntent(input,state))
            }
            try deliveryRepresentationPreflight(intent.bytes)
            try preflightDeliveryRetry(c,input,intent)
            attachmentInput=exact
            return try finishDelivery(c,input,intent.bytes,expectedIntent:intent.identity)
        }
        return try publishPendingAttachment(pending)
    }
    func inspectDeliveryAttachmentExact()throws->DeliveryAttachmentDiagnostic? {
        try disk{c in
            guard !(try deliveryLeaves(c)).isEmpty else{return nil}
            let n=try requireEither(c.root,"delivery.intent",limit:32768),d=try decodeDeliveryIntent(n.bytes)
            _ = try checkedDeliveryNodes(c,d)
            return .init(nativeOperationID:d.nativeOperationID,remoteOperationID:d.association.operationID)
        }
    }
    func verifyDeliveryAttachmentExact(_ receipt:DeliveryAttachmentReceipt)throws {
        try disk{c in
            let intent=try decodeDeliveryIntent(require(c.root,"delivery.intent",limit:32768).bytes)
            let nodes=try checkedDeliveryNodes(c,intent)
            guard receipt.issuer == ObjectIdentifier(self),receipt.rootID == rootID,receipt.epoch == epoch(),receipt.nodes == nodes,
                  attachmentQualified === receipt else{throw Failure.uncertain}
        }
    }
    private func requireNoDeliveryReservation(_ c:Context)throws {
        try requireNoNativeJoin(c)
        guard attachmentInput == nil,pendingAttachment == nil,attachmentQualified == nil,
              try deliveryLeaves(c).isEmpty else{throw Failure.conflict}
    }
    private func publishPendingAttachment(_ pending:DeliveryAttachmentReceipt)throws->DeliveryAttachmentReceipt {
        try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()}
        mutex.lock();defer{mutex.unlock()}
        guard pendingAttachment === pending,pending.issuer == ObjectIdentifier(self),pending.rootID == rootID,
              pending.epoch == epoch() else {
            if pendingAttachment === pending {pendingAttachment=nil}
            attachmentQualified=nil;throw Failure.uncertain
        }
        attachmentQualified=pending;pendingAttachment=nil;return pending
    }
    /// Full bounded original-node preflight: no epoch, sync, promotion or writes. Every expected
    /// raw/proof node is checked before retry effects. Only the creating live instance may repair
    /// a partial prefix on its captured inode; recorded empty raw/proof nodes may be filled after restart.
    private func preflightDeliveryRetry(_ c:Context,_ input:DeviceNativeDeliveryCommandBinding,_ intent:Node)throws {
        let leaves=try deliveryLeaves(c)
        guard !leaves.isEmpty else{throw Failure.conflict}
        var nodes:[String:Node]=[:]
        for name in Self.deliveryNames {
            if let node=try either(c.root,name,limit:name == "delivery.plan" ? 65536:32768) {nodes[name]=node}
        }
        guard nodes["delivery.intent"]?.identity == intent.identity,
              nodes["delivery.intent"]?.bytes == intent.bytes || nodes["delivery.intent"]?.bytes.isEmpty == true && live["delivery.intent.stage"] == intent.identity else{throw Failure.conflict}
        guard let binding=nodes["delivery.binding"],!binding.bytes.isEmpty else {
            // No reciprocal persisted identities yet: the exact live input and original captured
            // nodes are mandatory. Restart preserves these unknown creations rather than adopts them.
            guard attachmentInput == (try deliveryInput(input)),live["delivery.intent.stage"] == intent.identity else{throw Failure.conflict}
            // Captured absence is NOT permission to recreate a leaf whose original inode was
            // already observed by this live attempt. Check the COMPLETE expected live prefix,
            // including nodes currently missing, before allocate can run or epoch can advance.
            for name in Self.deliveryNames {
                if let original=live[name+".stage"] {
                    guard let node=nodes[name],node.identity == original else{throw Failure.conflict}
                }
            }
            for (name,node) in nodes where name != "delivery.intent" {
                guard live[name+".stage"] == node.identity,try read(c.root,name,limit:65536) == nil,node.bytes.isEmpty else{throw Failure.conflict}
            }
            return
        }
        let d=try decodeDeliveryBinding(binding.bytes)
        guard d.selfID == binding.identity,d.intent == intent else{throw Failure.conflict}
        for (name,id,bytes) in [("delivery.command",d.commandID,input.commandBytes),("delivery.plan",d.planID,input.planBytes)] {
            guard let node=nodes[name],node.identity == id else{throw Failure.conflict}
            if try read(c.root,name,limit:65536) != nil {guard node.bytes == bytes else{throw Failure.conflict}}
            else {guard node.bytes == bytes || node.bytes.isEmpty || live[name+".stage"] == id && bytes.starts(with:node.bytes) else{throw Failure.conflict}}
        }
        guard let confirmation=nodes["delivery.confirm"],confirmation.identity == d.confirmationID else{throw Failure.conflict}
        let proof=try DeviceNativeDeliveryAttachmentCodec.encode(DeliveryConfirmation(schemaVersion:1,selfID:d.confirmationID,binding:binding,command:Node(identity:d.commandID,bytes:Data()),plan:Node(identity:d.planID,bytes:Data())))
        if try read(c.root,"delivery.confirm",limit:32768) != nil {guard confirmation.bytes == proof else{throw Failure.conflict}}
        else {guard confirmation.bytes == proof || confirmation.bytes.isEmpty || live["delivery.confirm.stage"] == d.confirmationID && proof.starts(with:confirmation.bytes) else{throw Failure.conflict}}
    }
    private func makeDeliveryIntent(_ input:DeviceNativeDeliveryCommandBinding,_ s:State)throws->Data {
        guard let b=s.nodes["binding"],let g=s.nodes["genesis"],let h=s.nodes["head"] else{throw Failure.conflict}
        return try DeviceNativeDeliveryAttachmentCodec.encode(DeliveryIntent(schemaVersion:1,rootID:rootID,nativeOperationID:input.nativeOperationID,association:input.association,commandBytes:input.commandBytes.count,commandHash:DeviceNativeDeliveryAttachmentCodec.hash(input.commandBytes),bindingID:b.identity,genesisID:g.identity,head:h,bindingHash:DeviceNativeDeliveryAttachmentCodec.hash(b.bytes),genesisHash:DeviceNativeDeliveryAttachmentCodec.hash(g.bytes)))
    }
    private func matchDelivery(_ d:DeliveryIntent,_ input:DeviceNativeDeliveryCommandBinding,_ s:State)throws {
        guard d.rootID == rootID,d.nativeOperationID == input.nativeOperationID,d.association == input.association,
              d.commandBytes == input.commandBytes.count,try DeviceNativeDeliveryAttachmentCodec.hash(input.commandBytes).utf8.elementsEqual(d.commandHash.utf8),
              let b=s.nodes["binding"],let g=s.nodes["genesis"],s.nodes["head"] == d.head,b.identity == d.bindingID,g.identity == d.genesisID,
              try DeviceNativeDeliveryAttachmentCodec.hash(b.bytes).utf8.elementsEqual(d.bindingHash.utf8),
              try DeviceNativeDeliveryAttachmentCodec.hash(g.bytes).utf8.elementsEqual(d.genesisHash.utf8) else{throw Failure.conflict}
    }
    private func deliveryRepresentationPreflight(_ intent:Data)throws {
        let id=ID(device:UInt64.max,inode:UInt64.max)
        let n=Node(identity:id,bytes:intent)
        let binding=try DeviceNativeDeliveryAttachmentCodec.encode(DeliveryBinding(schemaVersion:1,selfID:id,intent:n,commandID:id,planID:id,confirmationID:id))
        _ = try DeviceNativeDeliveryAttachmentCodec.encode(DeliveryConfirmation(schemaVersion:1,selfID:id,binding:Node(identity:id,bytes:binding),command:Node(identity:id,bytes:Data()),plan:Node(identity:id,bytes:Data())))
    }
    private func finishDelivery(_ c:Context,_ input:DeviceNativeDeliveryCommandBinding,_ intentBytes:Data,expectedIntent:ID?=nil)throws->DeliveryAttachmentReceipt {
        let state=try inventory(c,allowDeliveryAttachment:true),decoded=try decodeDeliveryIntent(intentBytes)
        try matchDelivery(decoded,input,state)
        attachmentQualified=nil;pendingAttachment=nil;qualifiedBinding=false;bindingEpoch=nil;bindingEvidence=nil;qualifiedCompletion=nil;pendingCompletion=nil
        let originalEpoch=epoch(true)
        let intent:Node
        if let existing=try either(c.root,"delivery.intent",limit:32768),!existing.bytes.isEmpty {
            guard existing.bytes == intentBytes,expectedIntent == nil || existing.identity == expectedIntent else{throw Failure.conflict};intent=existing
        } else {
            let id=try allocate(c.root,"delivery.intent.stage",kind:.deliveryIntent)
            guard expectedIntent == nil || id == expectedIntent else{throw Failure.conflict}
            intent=Node(identity:id,bytes:intentBytes);try fill(c.root,"delivery.intent.stage",intent,kind:.deliveryIntent)
        }
        try promote(c,parent:c.root,name:"delivery.intent",expected:intent,kind:.deliveryIntent)
        let binding:Node
        if let existing=try either(c.root,"delivery.binding",limit:32768),!existing.bytes.isEmpty {binding=existing}
        else {
            let command=try allocate(c.root,"delivery.command.stage",kind:.deliveryCommand)
            let plan=try allocate(c.root,"delivery.plan.stage",kind:.deliveryPlan)
            let confirmation=try allocate(c.root,"delivery.confirm.stage",kind:.deliveryConfirmation)
            let id=try allocate(c.root,"delivery.binding.stage",kind:.deliveryBinding)
            binding=Node(identity:id,bytes:try DeviceNativeDeliveryAttachmentCodec.encode(DeliveryBinding(schemaVersion:1,selfID:id,intent:intent,commandID:command,planID:plan,confirmationID:confirmation)))
            try fill(c.root,"delivery.binding.stage",binding,kind:.deliveryBinding)
        }
        let d=try decodeDeliveryBinding(binding.bytes)
        guard d.selfID == binding.identity,d.intent == intent else{throw Failure.conflict}
        // Recorded raw inode bindings are durable BEFORE writes/promotions of raw content.
        try promote(c,parent:c.root,name:"delivery.binding",expected:binding,kind:.deliveryBinding)
        for (name,id,bytes,kind) in [("delivery.command",d.commandID,input.commandBytes,Kind.deliveryCommand),("delivery.plan",d.planID,input.planBytes,Kind.deliveryPlan)] {
            let expected=Node(identity:id,bytes:bytes)
            if let final=try read(c.root,name,limit:65536) {guard final == expected else{throw Failure.conflict}}
            else {
                let staged=try require(c.root,name+".stage",limit:65536)
                guard staged.identity == id else{throw Failure.conflict}
                if staged.bytes != bytes {
                    guard staged.bytes.isEmpty || live[name+".stage"] == id else{throw Failure.conflict}
                    try fill(c.root,name+".stage",expected,kind:kind)
                }
            }
            try promote(c,parent:c.root,name:name,expected:expected,kind:kind)
        }
        let proof=Node(identity:d.confirmationID,bytes:try DeviceNativeDeliveryAttachmentCodec.encode(DeliveryConfirmation(schemaVersion:1,selfID:d.confirmationID,binding:binding,command:Node(identity:d.commandID,bytes:Data()),plan:Node(identity:d.planID,bytes:Data()))))
        if let final=try read(c.root,"delivery.confirm",limit:32768) {guard final == proof else{throw Failure.conflict}}
        else {
            let staged=try require(c.root,"delivery.confirm.stage",limit:32768)
            guard staged.identity == d.confirmationID,staged.bytes.isEmpty || staged == proof || live["delivery.confirm.stage"] == d.confirmationID else{throw Failure.conflict}
            try fill(c.root,"delivery.confirm.stage",proof,kind:.deliveryConfirmation)
        }
        try promote(c,parent:c.root,name:"delivery.confirm",expected:proof,kind:.deliveryConfirmation)
        let b=try require(c.root,"root-binding.json",limit:16384),g=try require(c.root,"genesis.json",limit:32768)
        guard b.identity == decoded.bindingID,g.identity == decoded.genesisID,
              try DeviceNativeDeliveryAttachmentCodec.hash(b.bytes).utf8.elementsEqual(decoded.bindingHash.utf8),
              try DeviceNativeDeliveryAttachmentCodec.hash(g.bytes).utf8.elementsEqual(decoded.genesisHash.utf8),
              try require(c.root,"head.json",limit:8192) == decoded.head else{throw Failure.conflict}
        try syncExisting(c.root,"root-binding.json",b,kind:.binding);try syncExisting(c.root,"genesis.json",g,kind:.genesis)
        try sync(c.lock);try sync(c.ops);try sync(c.root);try check(c)
        let finalState=try inventory(c,allowDeliveryAttachment:true);try matchDelivery(decoded,input,finalState)
        let nodes=try checkedDeliveryNodes(c,decoded)
        guard epoch() == originalEpoch else{throw Failure.uncertain}
        let receipt=DeliveryAttachmentReceipt(ObjectIdentifier(self),rootID,originalEpoch,input.nativeOperationID,input.association.operationID,nodes)
        pendingAttachment=receipt
        // No qualification is published in this scope. Throwing body or post-body check leaves
        // only a pending object; no caller can obtain it and ordinary mutation remains fenced.
        try boundary(.beforeDeliveryScopeExit)
        return receipt
    }
    private func checkedDeliveryNodes(_ c:Context,_ intent:DeliveryIntent)throws->[String:Node] {
        let leaves=try deliveryLeaves(c)
        guard Set(leaves) == Self.deliveryNames else{throw Failure.conflict}
        var result:[String:Node]=[:]
        for name in Self.deliveryNames {result[name]=try require(c.root,name,limit:name == "delivery.plan" ? 65536:32768)}
        let binding=try decodeDeliveryBinding(result["delivery.binding"]!.bytes),proof=try decodeDeliveryConfirmation(result["delivery.confirm"]!.bytes)
        guard binding.selfID == result["delivery.binding"]!.identity,binding.intent == result["delivery.intent"],
              binding.commandID == result["delivery.command"]!.identity,binding.planID == result["delivery.plan"]!.identity,
              proof.selfID == result["delivery.confirm"]!.identity,binding.confirmationID == proof.selfID,proof.binding == result["delivery.binding"],
              proof.command == Node(identity:binding.commandID,bytes:Data()),proof.plan == Node(identity:binding.planID,bytes:Data()),
              result["delivery.command"]!.bytes.count == intent.commandBytes,result["delivery.plan"]!.bytes.count == intent.association.planByteLength,
              try DeviceNativeDeliveryAttachmentCodec.hash(result["delivery.command"]!.bytes).utf8.elementsEqual(intent.commandHash.utf8),
              try DeviceNativeDeliveryAttachmentCodec.hash(result["delivery.plan"]!.bytes).utf8.elementsEqual(intent.association.planDigest.utf8) else{throw Failure.conflict}
        let state=try inventory(c,allowDeliveryAttachment:true)
        guard state.nodes["head"] == intent.head,let b=state.nodes["binding"],let g=state.nodes["genesis"],b.identity == intent.bindingID,g.identity == intent.genesisID,
              try DeviceNativeDeliveryAttachmentCodec.hash(b.bytes).utf8.elementsEqual(intent.bindingHash.utf8),try DeviceNativeDeliveryAttachmentCodec.hash(g.bytes).utf8.elementsEqual(intent.genesisHash.utf8) else{throw Failure.conflict}
        result["rootBinding"]=b;result["genesis"]=g;result["head"]=intent.head;return result
    }
    private func decodeDeliveryIntent(_ bytes:Data)throws->DeliveryIntent {
        let o=try DeviceNativeDeliveryAttachmentCodec.object(bytes,limit:32768,keys:["schemaVersion","rootID","nativeOperationID","association","commandBytes","commandHash","bindingID","genesisID","head","bindingHash","genesisHash"])
        try ids(o,["bindingID","genesisID"]);try node(o,"head")
        guard let association=o["association"] as? [String:Any] else{throw Failure.conflict}
        try StructuralStoreCodec.keys(association,required:["operationID","planID","installationID","accountID","locationID","transitionID","planDigest","planByteLength"])
        let value=try JSONDecoder().decode(DeliveryIntent.self,from:bytes)
        guard value.schemaVersion == 1,(1...16384).contains(value.commandBytes),(1...65536).contains(value.association.planByteLength),try DeviceNativeDeliveryAttachmentCodec.encode(value) == bytes else{throw Failure.conflict}
        _ = try DeviceNativeDeliveryAttachmentCodec.hashText(value.commandHash);_ = try DeviceNativeDeliveryAttachmentCodec.hashText(value.bindingHash);_ = try DeviceNativeDeliveryAttachmentCodec.hashText(value.genesisHash);_ = try DeviceNativeDeliveryAttachmentCodec.hashText(value.association.planDigest)
        return value
    }
    private func decodeDeliveryBinding(_ bytes:Data)throws->DeliveryBinding {
        let o=try DeviceNativeDeliveryAttachmentCodec.object(bytes,limit:32768,keys:["schemaVersion","selfID","intent","commandID","planID","confirmationID"])
        try ids(o,["selfID","commandID","planID","confirmationID"]);try node(o,"intent")
        let value=try JSONDecoder().decode(DeliveryBinding.self,from:bytes)
        _ = try decodeDeliveryIntent(value.intent.bytes)
        guard value.schemaVersion == 1,try DeviceNativeDeliveryAttachmentCodec.encode(value) == bytes else{throw Failure.conflict};return value
    }
    private func decodeDeliveryConfirmation(_ bytes:Data)throws->DeliveryConfirmation {
        let o=try DeviceNativeDeliveryAttachmentCodec.object(bytes,limit:32768,keys:["schemaVersion","selfID","binding","command","plan"])
        try ids(o,["selfID"]);try node(o,"binding");try node(o,"command");try node(o,"plan")
        let value=try JSONDecoder().decode(DeliveryConfirmation.self,from:bytes)
        _ = try decodeDeliveryBinding(value.binding.bytes)
        guard value.schemaVersion == 1,value.command.bytes.isEmpty,value.plan.bytes.isEmpty,try DeviceNativeDeliveryAttachmentCodec.encode(value) == bytes else{throw Failure.conflict};return value
    }
    private func canonical<T:Decodable & Encodable>(_ type:T.Type,_ bytes:Data)throws->T {let value=try JSONDecoder().decode(type,from:bytes);guard try encode(value) == bytes else{throw Failure.conflict};return value}
}
private func FoundationRead(_ fd:Int32,_ buffer:UnsafeMutableRawPointer,_ count:Int)->Int {
#if canImport(Darwin)
    Darwin.read(fd,buffer,count)
#else
    Glibc.read(fd,buffer,count)
#endif
}
