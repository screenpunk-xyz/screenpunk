import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Unmounted intent-only journal. No operation completion, deletion, migration or external-effect
/// authorization exists. Inode guards are local replacement detection, not portable restore guarantees.
/// Unknown partial creation is retained and blocks restart; only the creating live instance can repair it.
/// Fault seams run synchronously under internal locks, are nonreentrant, and cannot wait for other
/// store work. This adds no UI/notification callback and no physical or hostile same-UID guarantee.
final class DeviceLocalProvisioningIntentStore {
    enum Failure:Error {case unsafeRoot, conflict, uncertain, capacity, io(Int32)}
    enum Kind:Equatable {case binding,genesis,head,intent,attempt,confirmation}
    enum Boundary:Equatable {case afterCreate(Kind),afterWrite(Kind),afterFileSync(Kind),beforeReplace(Kind),afterReplace(Kind),afterDirectorySync(Kind)}
    fileprivate struct ID:Codable,Equatable {let device:UInt64,inode:UInt64}
    fileprivate struct Node:Codable,Equatable {let identity:ID;let bytes:Data}
    private struct Binding:Codable,Equatable {
        let schemaVersion:Int,rootID:UUID,path:String,protectedPaths:[String]
        let directory:ID,lock:ID,operations:ID,selfID:ID,genesisID:ID,initialHeadID:ID
    }
    private struct Genesis:Codable,Equatable {let schemaVersion:Int;let binding:Node;let initialHeadID:ID}
    private struct Head:Codable,Equatable {let schemaVersion:Int;let genesisID:ID;let operationID:UUID?;let intentID:ID?}
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
    private var liveInput:(operationID:UUID,bytes:Data)?
    private func requireSameLiveInput(_ plan:DeviceValidatedProvisioningPlan)throws {
        if let original=liveInput {
            guard original.operationID == plan.operationID,original.bytes == plan.canonicalBytes else{throw Failure.conflict}
        }
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
            qualifiedBinding=false;bindingEpoch=nil;bindingEvidence=nil;let initialEpoch=epoch(true)
            let names=try list(c.root,limit:10)
            let allowed:Set<String>=["provisioning.lock","operations","root-binding.json","root-binding.json.stage","genesis.json","genesis.json.stage","head.json","head.json.stage"]
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
            if try list(c.ops,limit:8).isEmpty {
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
        _ = try checked(plan)
        return try disk{c in
            try requireSameLiveInput(plan)
            guard qualifiedBinding,bindingEpoch == epoch() else{throw Failure.uncertain}
            let state=try inventory(c)
            guard bindingEvidence == state.nodes else{throw Failure.uncertain}
            guard state.operation == nil else{throw Failure.capacity}
            return try finish(c,plan:plan)
        }
    }
    /// Requires the original genuinely validated plan. Restored public bytes alone are not private proof.
    func recommitExact(_ plan:DeviceValidatedProvisioningPlan)throws->Receipt {
        _ = try checked(plan)
        return try disk{c in
            try requireSameLiveInput(plan)
            do {
                let state=try inventory(c)
                guard state.operation == nil || state.operation == plan.operationID else{throw Failure.capacity}
                if let bytes=state.intent {guard bytes == plan.canonicalBytes else{throw Failure.conflict}}
            } catch {
                let prefix=plan.operationID.uuidString.lowercased()
                let files=try list(c.ops,limit:7)
                guard !files.isEmpty,files.allSatisfy({$0.hasPrefix(prefix)}),files.allSatisfy({name in
                    guard let n=try? read(c.ops,name,limit:ProvisioningIntentCodec.limit) else{return false}
                    return live[name] == n.identity
                }) else{throw error}
            }
            return try finish(c,plan:plan)
        }
    }
    func inspectPendingExact()throws->Diagnostic? {
        try disk{c in let s=try inventory(c);guard let id=s.operation,let bytes=s.intent else{return nil};return Diagnostic(operationID:id,exactIntentBytes:bytes)}
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
        try requireSameLiveInput(plan)
        if liveInput == nil { liveInput=(plan.operationID,plan.canonicalBytes) }
        qualifiedBinding=false;bindingEpoch=nil;bindingEvidence=nil;let attemptEpoch=epoch(true)
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
            guard head.identity == b.initialHeadID,try decodeHead(head.bytes).operationID == nil else{throw Failure.conflict}
            let iID=try allocate(c.ops,intentName+".stage",kind:.intent)
            try fill(c.ops,intentName+".stage",Node(identity:iID,bytes:plan.canonicalBytes),kind:.intent)
            let hID=try allocate(c.root,"head.json.stage",kind:.head)
            let candidate=Node(identity:hID,bytes:try encode(Head(schemaVersion:1,genesisID:b.genesisID,operationID:plan.operationID,intentID:iID)))
            try fill(c.root,"head.json.stage",candidate,kind:.head)
            let fID=try allocate(c.ops,confirmationName+".stage",kind:.confirmation)
            let aID=try allocate(c.ops,attemptName+".stage",kind:.attempt)
            attemptNode=Node(identity:aID,bytes:try encode(Attempt(schemaVersion:1,operationID:plan.operationID,selfID:aID,intentID:iID,confirmationID:fID,intentByteCount:plan.canonicalBytes.count,baseline:head,candidate:candidate)))
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
        } else {guard current == a.candidate else{throw Failure.conflict}}
        try syncExisting(c.root,"head.json",a.candidate,kind:.head);try sync(c.root);try boundary(.afterDirectorySync(.head))
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
        return Receipt(ObjectIdentifier(self),rootID,attemptEpoch,state.nodes)
    }
    private func inventory(_ c:Context)throws->(operation:UUID?,intent:Data?,complete:Bool,nodes:[String:Node]) {
        try check(c)
        guard try read(c.root,"root-binding.json.stage",limit:16384) == nil,try read(c.root,"genesis.json.stage",limit:32768) == nil else{throw Failure.conflict}
        let binding=try require(c.root,"root-binding.json",limit:16384),genesis=try require(c.root,"genesis.json",limit:32768)
        let b=try decodeBinding(binding.bytes),g=try decodeGenesis(genesis.bytes)
        try checkBinding(c,b,node:binding)
        guard genesis.identity == b.genesisID,g.binding == binding,g.initialHeadID == b.initialHeadID else{throw Failure.conflict}
        let files=try list(c.ops,limit:7)
        let head=try require(c.root,"head.json",limit:8192),h=try decodeHead(head.bytes)
        var nodes=["binding":binding,"genesis":genesis,"head":head]
        guard h.genesisID == b.genesisID else{throw Failure.conflict}
        if files.isEmpty {guard head.identity == b.initialHeadID,h.operationID == nil,h.intentID == nil,try read(c.root,"head.json.stage",limit:8192) == nil else{throw Failure.conflict};return(nil,nil,false,nodes)}
        var operation:UUID?
        for name in files {
            let prefix=String(name.prefix(36))
            guard let id=UUID(uuidString:prefix),prefix == id.uuidString.lowercased(),[".intent.json",".binding.json",".confirm.json",".intent.json.stage",".binding.json.stage",".confirm.json.stage"].contains(String(name.dropFirst(36))),operation == nil || operation == id else{throw Failure.conflict}
            operation=id
        }
        guard let op=operation else{throw Failure.conflict};let prefix=op.uuidString.lowercased()
        let attempt=try requireEither(c.ops,prefix+".binding.json",limit:32768),a=try decodeAttempt(attempt.bytes)
        guard a.selfID == attempt.identity,a.operationID == op else{throw Failure.conflict}
        let intent=try requireEither(c.ops,prefix+".intent.json",limit:ProvisioningIntentCodec.limit),body=try ProvisioningIntentCodec.decode(intent.bytes)
        guard intent.identity == a.intentID,intent.bytes.count == a.intentByteCount,body.operationID == op,body.roots.journalID == rootID,
              head == a.baseline || head == a.candidate else{throw Failure.conflict}
        guard a.baseline.identity == b.initialHeadID,try decodeHead(a.baseline.bytes) == Head(schemaVersion:1,genesisID:b.genesisID,operationID:nil,intentID:nil),try decodeHead(a.candidate.bytes) == Head(schemaVersion:1,genesisID:b.genesisID,operationID:op,intentID:a.intentID) else{throw Failure.conflict}
        if let stage=try read(c.root,"head.json.stage",limit:8192){guard stage == a.candidate else{throw Failure.conflict}}
        nodes["attempt"]=attempt;nodes["intent"]=intent
        var complete=false
        guard let f=try either(c.ops,prefix+".confirm.json",limit:65536),f.identity == a.confirmationID else{throw Failure.conflict}
        if !f.bytes.isEmpty {
            let proof=try decodeConfirmation(f.bytes)
            guard proof.selfID == a.confirmationID,proof.selfID == f.identity,proof.attempt == attempt,proof.head == a.candidate,head == a.candidate else{throw Failure.conflict}
            nodes["confirmation"]=f
            complete=try read(c.ops,prefix+".confirm.json",limit:65536) != nil && read(c.ops,prefix+".binding.json",limit:32768) != nil && read(c.ops,prefix+".intent.json",limit:ProvisioningIntentCodec.limit) != nil
        }
        return(op,intent.bytes,complete,nodes)
    }
    private func disk<T>(create:Bool=false,_ body:(Context)throws->T)throws->T {
        try DeviceLocalResourceRegistry.beginOrdinary();defer{DeviceLocalResourceRegistry.endOrdinary()}
        try paths();mutex.lock();defer{mutex.unlock()}
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
        guard flock(lock,LOCK_EX) == 0 else{throw failure()};defer{flock(lock,LOCK_UN)}
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
        let allowed:Set<String>=["provisioning.lock","operations","root-binding.json","root-binding.json.stage","genesis.json","genesis.json.stage","head.json","head.json.stage"]
        guard Set(try list(c.root,limit:10)).isSubset(of:allowed) else{throw Failure.conflict}
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
    private func decodeHead(_ bytes:Data)throws->Head {let o=try StructuralStoreCodec.object(bytes,limit:8192);try StructuralStoreCodec.keys(o,required:["schemaVersion","genesisID"],optional:["operationID","intentID"]);try ids(o,["genesisID"]);if o["intentID"] != nil{try ids(o,["intentID"])};let h=try canonical(Head.self,bytes);guard h.schemaVersion == 1,(h.operationID == nil) == (h.intentID == nil) else{throw Failure.conflict};return h}
    private func decodeAttempt(_ bytes:Data)throws->Attempt {let o=try shape(bytes,["schemaVersion","operationID","selfID","intentID","confirmationID","intentByteCount","baseline","candidate"]);try ids(o,["selfID","intentID","confirmationID"]);try node(o,"baseline");try node(o,"candidate");let a=try canonical(Attempt.self,bytes);guard a.schemaVersion == 1,(1...ProvisioningIntentCodec.limit).contains(a.intentByteCount) else{throw Failure.conflict};return a}
    private func decodeConfirmation(_ bytes:Data)throws->Confirmation {let o=try shape(bytes,["schemaVersion","selfID","attempt","head"]);try ids(o,["selfID"]);try node(o,"attempt");try node(o,"head");let f=try canonical(Confirmation.self,bytes);guard f.schemaVersion == 1 else{throw Failure.conflict};return f}
    private func canonical<T:Decodable & Encodable>(_ type:T.Type,_ bytes:Data)throws->T {let value=try JSONDecoder().decode(type,from:bytes);guard try encode(value) == bytes else{throw Failure.conflict};return value}
}
private func FoundationRead(_ fd:Int32,_ buffer:UnsafeMutableRawPointer,_ count:Int)->Int {
#if canImport(Darwin)
    Darwin.read(fd,buffer,count)
#else
    Glibc.read(fd,buffer,count)
#endif
}
