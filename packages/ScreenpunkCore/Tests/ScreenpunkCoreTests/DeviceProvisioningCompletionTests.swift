import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import ScreenpunkCore

final class DeviceProvisioningCompletionTests:XCTestCase {
    private final class Backend:DeviceGrantCredentialBackend,@unchecked Sendable {
        var values:[String:DeviceGrantCredentialValue]=[:],adds=0
        func inventory(service:String,maximum:Int,visit:(DeviceGrantCredentialItem)throws->Void)throws {for key in values.keys.sorted(){try visit(values[key]!.item)}}
        func read(service:String,account:String,maximumBytes:Int)throws->DeviceGrantCredentialValue? {guard let value=values[account] else{return nil};guard value.bytes.count <= maximumBytes else{throw DeviceGrantPreparationError.sizeLimit};return value}
        func add(service:String,account:String,bytes:Data)throws->DeviceGrantCredentialItem {guard values[account] == nil else{throw DeviceGrantPreparationError.conflict};adds += 1;let item=DeviceGrantCredentialItem(account:account,persistentReference:Data(UUID().uuidString.utf8),byteCount:bytes.count);values[account] = .init(item:item,bytes:bytes);return item}
    }
    private enum Injected:Error{case fault}
    private func id(_ n:Int)->UUID {UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",n))!}
    private var owner:PairingIdentity{.init(role:.controller,publicKey:[UInt8](repeating:7,count:32))}
    private var roots:DeviceProvisioningRoots{.init(journalID:id(1),structuralID:id(2),packageID:id(3),grantID:id(4))}
    private func directory()throws->URL {
        let p=try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil));defer{free(p)}
        let url=URL(fileURLWithPath:String(cString:p)).appendingPathComponent("provisioning-completion-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url
    }
    private func scope(_ root:URL)->DevicePackageProtectedScope {let p=root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-protected");return .init(legacyStateRoot:p.appendingPathComponent("state"),legacyArchiveRoot:p.appendingPathComponent("archive"),resetRoot:p.appendingPathComponent("reset"),cloudRoot:p.appendingPathComponent("cloud"),managementRoot:p.appendingPathComponent("management"),preferencesRoot:p.appendingPathComponent("preferences"),otherProtectedRoots:[])}
    private func grantStore(_ root:URL,_ backend:Backend,boundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in})->DeviceGrantPreparationStore {.init(root:root,rootID:id(4),protectedScope:scope(root),backend:backend,boundary:boundary)}
    private func journal(_ root:URL,boundary:@escaping(DeviceLocalProvisioningIntentStore.Boundary)throws->Void={_ in})->DeviceLocalProvisioningIntentStore {.init(root:root,rootID:id(1),protectedRoots:[root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-protected")],boundary:boundary)}
    private func request(generation:Int=7,revision:Int=5)throws->DeviceProvisioningPlanRequest {
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(revision)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        return .init(roots:roots,operationID:id(10),grantOperationID:id(6),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:"opaque"),snapshot:.init(generationID:id(generation),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:[],grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]))
    }
    private func files(_ root:URL)throws->[String:Data] {var result:[String:Data]=[:];for path in try FileManager.default.subpathsOfDirectory(atPath:root.path){var isDir:ObjCBool=false;let url=root.appendingPathComponent(path);if FileManager.default.fileExists(atPath:url.path,isDirectory:&isDir),!isDir.boolValue{result[path]=try Data(contentsOf:url)}};return result}
    private func packageStore(_ root:URL,boundary:@escaping(DevicePackagePreparationStore.Boundary)throws->Void={_ in})->DevicePackagePreparationStore {.init(root:root,rootID:id(3),protectedScope:scope(root),boundary:boundary)}
    private struct Fixture {
        let jr:URL,gr:URL,pr:URL,b:Backend,j:DeviceLocalProvisioningIntentStore,g:DeviceGrantPreparationStore,p:DevicePackagePreparationStore
        let r:DeviceProvisioningPlanRequest,plan:DeviceValidatedProvisioningPlan,c:DeviceBoundPackagePreparationCoordinator,completed:DeviceBoundCompletedCredentials
    }
    private func fixture(_ request:DeviceProvisioningPlanRequest,boundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in},prewarm:[DeviceProvisioningPackageInput]=[],predecessor:Bool=false,journalBoundary:@escaping(DeviceLocalProvisioningIntentStore.Boundary)throws->Void={_ in})throws->Fixture {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr,boundary:journalBoundary),g=grantStore(gr,b,boundary:boundary),p=packageStore(pr),plan=try DeviceProvisioningPlanner.qualify(request)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        if predecessor {_ = try g.prepareExact(freshV1())}
        for input in prewarm {guard case .supplied(_,let op,let value)=input else{throw Injected.fault};_ = try p.prepareExact(.init(operationID:op,package:value))}
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(request,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:request.packages),completed=try c.completeCredentialsExact(batch)
        return .init(jr:jr,gr:gr,pr:pr,b:b,j:j,g:g,p:p,r:request,plan:plan,c:c,completed:completed)
    }
    private func freshV1()throws->DeviceGrantPreparationRequest {
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(9000)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        return .init(operationID:id(9001),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
    }
    private func structural(_ root:URL,boundary:@escaping(DeviceStructuralStore.Boundary)throws->Void={_ in})->DeviceStructuralStore {.init(root:root,rootID:id(2),boundary:boundary)}
    private func commit(_ f:Fixture,_ store:DeviceStructuralStore)->DeviceLocalCompleteSetCommitCoordinator {.init(packageStore:f.p,grantStore:f.g,structuralStore:store)}
    private struct Ready {
        let f:Fixture,root:URL,store:DeviceStructuralStore,coordinator:DeviceLocalCompleteSetCommitCoordinator,terminal:DeviceBoundTerminalGrantReceipt,ack:DeviceLocalCompleteSetCommitAcknowledgment
    }
    private func ready(boundary:@escaping(DeviceLocalProvisioningIntentStore.Boundary)throws->Void={_ in})throws->Ready {
        let f=try fixture(request(),journalBoundary:boundary),root=try directory(),store=structural(root);try store.initializeExplicit()
        let coordinator=commit(f,store),terminal=try f.c.closeGrantTerminalExact(f.completed),ack=try coordinator.commitBoundTerminalExact(terminal,journal:f.j)
        return .init(f:f,root:root,store:store,coordinator:coordinator,terminal:terminal,ack:ack)
    }
    private func successor(_ ack:DeviceLocalCompleteSetCommitAcknowledgment,n:Int=20)throws->DeviceValidatedProvisioningPlan {
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(n+1)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        let r=DeviceProvisioningPlanRequest(roots:roots,operationID:id(n),grantOperationID:id(n+2),expectedGenerationID:ack.generationID,baseline:.expectedEnvelope(ack.envelopeBytes),snapshot:.init(generationID:id(n+3),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:[],grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]))
        return try DeviceProvisioningPlanner.qualify(r)
    }
    func testGenuineCompletionThenExplicitSuccessorAndHistoricalDiagnosticNeverQualifiesTip()throws {
        let r=try ready(),before=try files(r.f.jr),receipt=try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j)
        try r.f.j.verifyCompletion(receipt);XCTAssertNil(try r.f.j.inspectPendingExact())
        for (name,bytes) in before where name.hasPrefix("operations/") {XCTAssertEqual(try files(r.f.jr)[name],bytes)}
        let historical=try r.f.j.inspectRetainedCompletionExact(operationID:r.ack.operationID)
        XCTAssertEqual(historical.envelope,r.ack.envelopeBytes)
        let plan=try successor(r.ack),next=try r.f.j.stageExact(plan);try r.f.j.verify(next)
        XCTAssertEqual(try r.f.j.inspectPendingExact()?.operationID,plan.operationID)
        XCTAssertThrowsError(try r.f.j.verifyCompletion(receipt));XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack,n:30)))
        let current=try files(r.f.jr);_ = try r.f.j.inspectRetainedCompletionExact(operationID:r.ack.operationID)
        XCTAssertEqual(try files(r.f.jr),current);XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack,n:31)))
    }
    func testVisibleCompletionWithStaleOriginalStructuralCaptureNeverReleasesCapacity()throws {
        let r=try ready(),before=try files(r.f.jr),newAck=try r.coordinator.commitBoundTerminalExact(r.terminal,journal:r.f.j)
        XCTAssertThrowsError(try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j));XCTAssertEqual(try files(r.f.jr),before)
        XCTAssertThrowsError(try r.f.j.stageExact(successor(newAck)))
        let receipt=try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:newAck,journal:r.f.j);try r.f.j.verifyCompletion(receipt)
    }
    func testCompletionFaultMatrixOriginalLiveExactRetry()throws {
        var points:[DeviceLocalProvisioningIntentStore.Boundary]=[]
        for kind in [DeviceLocalProvisioningIntentStore.Kind.completion,.completionBinding,.completionHead,.completionConfirmation] {
            points += [.afterCreate(kind),.afterWrite(kind),.afterFileSync(kind),.beforeReplace(kind),.afterReplace(kind),.afterDirectorySync(kind)]
        }
        for point in points {
            var armed=false,hit=false
            let r=try ready(boundary:{if armed && $0 == point{armed=false;hit=true;throw Injected.fault}})
            armed=true;XCTAssertThrowsError(try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j));XCTAssertTrue(hit,String(describing:point))
            let preserved=try files(r.f.jr);XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack)));XCTAssertEqual(try files(r.f.jr),preserved)
            let completion=try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j);try r.f.j.verifyCompletion(completion)
            XCTAssertNoThrow(try r.f.j.stageExact(successor(r.ack)))
        }
    }
    func testRestartRequiresExplicitTerminalAndStructuralRecommit()throws {
        for point in [DeviceLocalProvisioningIntentStore.Boundary.afterReplace(.completionBinding),.afterReplace(.completion),.afterReplace(.completionHead),.afterReplace(.completionConfirmation)] {
            var armed=false
            let r=try ready(boundary:{if armed && $0 == point{armed=false;throw Injected.fault}});armed=true
            XCTAssertThrowsError(try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j))
            let j=journal(r.f.jr),g=grantStore(r.f.gr,r.f.b),p=packageStore(r.f.pr),resources=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
            XCTAssertThrowsError(try j.stageExact(successor(r.ack)))
            let terminal=try resources.recommitGrantTerminalExact(resources.inspectGrantTerminalRecoveryExact()),store=structural(r.root),coordinator=DeviceLocalCompleteSetCommitCoordinator(packageStore:p,grantStore:g,structuralStore:store)
            let newAck=try coordinator.commitBoundTerminalExact(terminal,journal:j)
            let completion=try coordinator.completeProvisioningExact(terminal,acknowledgment:newAck,journal:j);try j.verifyCompletion(completion)
            XCTAssertEqual(newAck.operationID,r.ack.operationID);XCTAssertEqual(newAck.envelopeBytes,r.ack.envelopeBytes)
        }
    }
    func testOriginalBindingSyncFailureNeedsExactCompletionRetry()throws {
        for point in [DeviceLocalProvisioningIntentStore.Boundary.afterFileSync(.binding),.afterFileSync(.genesis)] {
            var armed=false,hit=false
            let r=try ready(boundary:{if armed && $0 == point{armed=false;hit=true;throw Injected.fault}}),before=try files(r.f.jr)
            armed=true;XCTAssertThrowsError(try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j));XCTAssertTrue(hit)
            XCTAssertEqual(try files(r.f.jr),before);XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack)))
            let receipt=try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j);try r.f.j.verifyCompletion(receipt)
        }
    }
    func testOtherInstanceEpochInvalidationRefusesOldCompletionAndOriginalACK()throws {
        let r=try ready();let completion=try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j)
        let other=journal(r.f.jr);_ = try other.recommitExact(r.f.plan)
        let before=try files(r.f.jr);XCTAssertThrowsError(try r.f.j.verifyCompletion(completion))
        XCTAssertThrowsError(try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j));XCTAssertEqual(try files(r.f.jr),before)
        XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack)))
    }
    func testUnknownCompletionCreationRestartOrphanPreservedBlocked()throws {
        for point in [DeviceLocalProvisioningIntentStore.Boundary.afterCreate(.completion),.afterWrite(.completionHead)] {
            var armed=false
            let r=try ready(boundary:{if armed && $0 == point{armed=false;throw Injected.fault}});armed=true
            XCTAssertThrowsError(try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j));let before=try files(r.f.jr),j=journal(r.f.jr)
            XCTAssertThrowsError(try j.inspectLatestRetainedIntentExact());XCTAssertThrowsError(try j.recommitExact(r.f.plan));XCTAssertEqual(try files(r.f.jr),before)
            XCTAssertNoThrow(try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j))
        }
    }
    func testLateStructuralReplacementSuppressesPublicationAndSuccessor()throws {
        var target:URL?,armed=false,hit=false
        let r=try ready(boundary:{point in
            if armed && point == .afterDirectorySync(.completionConfirmation),let url=target {
                armed=false;hit=true;try Data(contentsOf:url).write(to:url,options:.atomic)
            }
        });target=r.root.appendingPathComponent("root-binding.json");armed=true
        XCTAssertThrowsError(try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j));XCTAssertTrue(hit)
        let before=try files(r.f.jr);XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack)))
        XCTAssertThrowsError(try journal(r.f.jr).stageExact(successor(r.ack)));XCTAssertEqual(try files(r.f.jr),before)
    }
    func testMissingReplacedProofAndHeadBlockSuccessorAndDiagnosticAcknowledgment()throws {
        for leaf in ["head.json",id(10).uuidString.lowercased()+".completion.json",id(10).uuidString.lowercased()+".completion-binding.json",id(10).uuidString.lowercased()+".completion-confirm.json"] {
            let r=try ready();_ = try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j)
            let url=leaf == "head.json" ? r.f.jr.appendingPathComponent(leaf):r.f.jr.appendingPathComponent("operations/"+leaf)
            try Data(contentsOf:url).write(to:url,options:.atomic);let before=try files(r.f.jr)
            XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack)));XCTAssertThrowsError(try journal(r.f.jr).inspectLatestRetainedIntentExact());XCTAssertEqual(try files(r.f.jr),before)
        }
    }
    func testReconstructedCompletedTipStillRequiresExactRequalification()throws {
        let r=try ready();_ = try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j)
        let j=journal(r.f.jr);XCTAssertThrowsError(try j.stageExact(successor(r.ack)))
        let g=grantStore(r.f.gr,r.f.b),p=packageStore(r.f.pr),resources=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let terminal=try resources.recommitGrantTerminalExact(resources.inspectGrantTerminalRecoveryExact()),coordinator=DeviceLocalCompleteSetCommitCoordinator(packageStore:p,grantStore:g,structuralStore:structural(r.root))
        let ack=try coordinator.commitBoundTerminalExact(terminal,journal:j),completion=try coordinator.completeProvisioningExact(terminal,acknowledgment:ack,journal:j)
        try j.verifyCompletion(completion);XCTAssertNoThrow(try j.stageExact(successor(ack)))
    }
    func testEmptyPackageEpochStaleBeforeCompletionLeavesJournalUnchanged()throws {
        let r=try ready(),before=try files(r.f.jr)
        _ = try r.f.p.resolveRetainedTerminalExact([])
        XCTAssertThrowsError(try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j))
        XCTAssertEqual(try files(r.f.jr),before);XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack)))
    }
    func testCompletionStrictUnknownDuplicateAndNestedFieldsReject()throws {
        for modification in [0,1,2,3] {
            let r=try ready();_ = try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j)
            let url=r.f.jr.appendingPathComponent("operations/"+r.ack.operationID.uuidString.lowercased()+".completion.json"),bytes=try Data(contentsOf:url)
            var text=String(decoding:bytes,as:UTF8.self)
            if modification == 0 {text="{\"future\":true,"+String(text.dropFirst())}
            else if modification == 1 {text="{\"schemaVersion\":2,"+String(text.dropFirst())}
            else if modification == 2 {text=text.replacingOccurrences(of:"\"intentID\":{",with:"\"intentID\":{\"future\":true,")}
            else {text = #"{"schema\u0056ersion":2,"# + String(text.dropFirst())}
            try Data(text.utf8).write(to:url)
            let before=try files(r.f.jr);XCTAssertThrowsError(try r.f.j.inspectRetainedCompletionExact(operationID:r.ack.operationID))
            XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack)));XCTAssertEqual(try files(r.f.jr),before)
        }
    }
    func testSuccessorFailureKeepsExactInputAndRejectsDifferentBytesForSameID()throws {
        var target:DeviceLocalProvisioningIntentStore.Boundary?,armed=false
        let r=try ready(boundary:{if armed && $0 == target{armed=false;throw Injected.fault}})
        _ = try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j)
        let plan=try successor(r.ack);target = .afterWrite(.intent);armed=true
        XCTAssertThrowsError(try r.f.j.stageExact(plan));let before=try files(r.f.jr)
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(21)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        let different=try DeviceProvisioningPlanner.qualify(.init(roots:roots,operationID:id(20),grantOperationID:id(22),expectedGenerationID:r.ack.generationID,baseline:.expectedEnvelope(r.ack.envelopeBytes),snapshot:.init(generationID:id(24),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:[],grantInput:input,qualifiedGrant:DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[])))
        XCTAssertThrowsError(try r.f.j.recommitExact(different));XCTAssertEqual(try files(r.f.jr),before)
        XCTAssertNoThrow(try r.f.j.recommitExact(plan))
    }
    func testOversizedAndInvalidUTF8CompletionMetadataFailClosed()throws {
        for oversized in [false,true] {
            let r=try ready();_ = try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j)
            let url=r.f.jr.appendingPathComponent("operations/"+r.ack.operationID.uuidString.lowercased()+".completion.json")
            let data=oversized ? Data(repeating:32,count:256*1024+1):Data([0xff,0xfe])
            try data.write(to:url);let before=try files(r.f.jr)
            XCTAssertThrowsError(try r.f.j.inspectLatestRetainedIntentExact());XCTAssertThrowsError(try r.f.j.stageExact(successor(r.ack)))
            XCTAssertEqual(try files(r.f.jr),before)
        }
    }
    // Decoder/inventory fixture ONLY. These recorded envelopes are not genuine structural ACKs,
    // package/grant receipts or 128 completed production pipelines. No capacity qualification minted.
    private func mechanicalAppend(_ r:Ready,start:Int,count:Int)throws {
        func encode(_ value:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
        func identity(_ url:URL)throws->[String:Any] {
            let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd >= 0 else{throw Injected.fault};defer{close(fd)}
            var value=stat();guard fstat(fd,&value) == 0 else{throw Injected.fault}
            return ["device":UInt64(value.st_dev),"inode":UInt64(value.st_ino)]
        }
        func node(_ url:URL)throws->[String:Any] {["identity":try identity(url),"bytes":try Data(contentsOf:url).base64EncodedString()]}
        func install(_ source:URL,_ destination:URL)throws {guard rename(source.path,destination.path) == 0 else{throw Injected.fault}}
        let root=r.f.jr,ops=root.appendingPathComponent("operations"),head=root.appendingPathComponent("head.json"),stage=root.appendingPathComponent("head.json.stage")
        var oldEnvelope=try r.f.j.inspectRetainedCompletionExact(operationID:r.ack.operationID).envelope
        if start > 0 {
            let prior=try JSONSerialization.jsonObject(with:Data(contentsOf:head)) as! [String:Any]
            let priorID=try XCTUnwrap(UUID(uuidString:prior["operationID"] as! String))
            oldEnvelope=try r.f.j.inspectRetainedCompletionExact(operationID:priorID).envelope
        }
        for n in start..<(start+count) {
            let previous=try StructuralStoreCodec.envelope(oldEnvelope),op=id(10000+n),revision=id(20000+n),grantOp=id(30000+n)
            let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:revision),owner:owner,entries:[],credentials:[],retainedRevisions:[])
            let plan=try DeviceProvisioningPlanner.qualify(.init(roots:roots,operationID:op,grantOperationID:grantOp,expectedGenerationID:previous.snapshot.generationID,baseline:.expectedEnvelope(oldEnvelope),snapshot:.init(generationID:id(40000+n),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:[],grantInput:input,qualifiedGrant:DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[])))
            let body=try ProvisioningIntentCodec.decode(plan.canonicalBytes),prefix=op.uuidString.lowercased()
            let intent=ops.appendingPathComponent(prefix+".intent.json"),binding=ops.appendingPathComponent(prefix+".binding.json"),confirmation=ops.appendingPathComponent(prefix+".confirm.json"),payload=ops.appendingPathComponent(prefix+".completion.json"),completionBinding=ops.appendingPathComponent(prefix+".completion-binding.json"),completionConfirmation=ops.appendingPathComponent(prefix+".completion-confirm.json")
            let oldHead=try node(head),oldObject=try JSONSerialization.jsonObject(with:Data(contentsOf:head)) as! [String:Any],genesis=oldObject["genesisID"]!
            try plan.canonicalBytes.write(to:intent)
            for url in [binding,confirmation,completionBinding,completionConfirmation] {try Data().write(to:url)}
            try encode(["schemaVersion":2,"genesisID":genesis,"operationID":op.uuidString,"intentID":identity(intent),"completed":false]).write(to:stage)
            let pending=try node(stage);try install(stage,head)
            try encode(["schemaVersion":2,"operationID":op.uuidString,"selfID":identity(binding),"intentID":identity(intent),"confirmationID":identity(confirmation),"intentByteCount":plan.canonicalBytes.count,"baseline":oldHead,"candidate":pending]).write(to:binding)
            try encode(["schemaVersion":1,"selfID":identity(confirmation),"attempt":node(binding),"head":pending]).write(to:confirmation)
            try encode(["schemaVersion":2,"operationID":op.uuidString,"structuralRootID":id(2).uuidString,"generationID":id(40000+n).uuidString,"intentID":identity(intent),"envelope":body.candidate.base64EncodedString()]).write(to:payload)
            try encode(["schemaVersion":2,"genesisID":genesis,"operationID":op.uuidString,"intentID":identity(intent),"completed":true,"completionID":identity(payload)]).write(to:stage)
            let completed=try node(stage)
            try encode(["schemaVersion":2,"operationID":op.uuidString,"selfID":identity(completionBinding),"completionID":identity(payload),"confirmationID":identity(completionConfirmation),"baseline":pending,"candidate":completed]).write(to:completionBinding)
            try install(stage,head)
            try encode(["schemaVersion":2,"selfID":identity(completionConfirmation),"binding":node(completionBinding),"head":completed]).write(to:completionConfirmation)
            oldEnvelope=body.candidate
        }
    }
    func testMechanicalRetainedChain128BoundAnd129RejectWithoutAuthority()throws {
        let r=try ready();_ = try r.coordinator.completeProvisioningExact(r.terminal,acknowledgment:r.ack,journal:r.f.j)
        try mechanicalAppend(r,start:0,count:127)
        let reader=journal(r.f.jr);XCTAssertNil(try reader.inspectPendingExact());XCTAssertEqual(try reader.inspectLatestRetainedIntentExact()?.operationID,id(10126))
        let before=try files(r.f.jr);XCTAssertThrowsError(try reader.stageExact(successor(r.ack)));XCTAssertEqual(try files(r.f.jr),before)
        try mechanicalAppend(r,start:127,count:1)
        let saturated=try files(r.f.jr);XCTAssertThrowsError(try reader.inspectLatestRetainedIntentExact());XCTAssertEqual(try files(r.f.jr),saturated)
    }

}
