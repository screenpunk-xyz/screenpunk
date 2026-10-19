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

final class DeviceBoundSuccessorTests:XCTestCase {
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
        let url=URL(fileURLWithPath:String(cString:p)).appendingPathComponent("bound-successor-"+UUID().uuidString)
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
    private func ready(boundary:@escaping(DeviceLocalProvisioningIntentStore.Boundary)throws->Void={_ in},grantBoundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in})throws->Ready {
        let f=try fixture(request(),boundary:grantBoundary,journalBoundary:boundary),root=try directory(),store=structural(root);try store.initializeExplicit()
        let coordinator=commit(f,store),terminal=try f.c.closeGrantTerminalExact(f.completed),ack=try coordinator.commitBoundTerminalExact(terminal,journal:f.j)
        return .init(f:f,root:root,store:store,coordinator:coordinator,terminal:terminal,ack:ack)
    }
    private func next(_ ack:DeviceLocalCompleteSetCommitAcknowledgment,n:Int=20)throws->DeviceProvisioningPlanRequest {
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(n+1)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        return .init(roots:roots,operationID:id(n),grantOperationID:id(n+2),expectedGenerationID:ack.generationID,baseline:.expectedEnvelope(ack.envelopeBytes),snapshot:.init(generationID:id(n+3),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:[],grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]))
    }
    private func completeFirst(_ ready:Ready)throws {
        let receipt=try ready.coordinator.completeProvisioningExact(ready.terminal,acknowledgment:ready.ack,journal:ready.f.j)
        try ready.f.j.verifyCompletion(receipt)
    }
    func testGenuineSecondEmptyCompletePipelinePreservesFirstRetainedEvidence()throws {
        let r=try ready();try completeFirst(r)
        let firstJournal=try files(r.f.jr),firstGrants=try files(r.f.gr),input=try next(r.ack),plan=try DeviceProvisioningPlanner.qualify(input)
        let pending=try r.f.j.stageExact(plan)
        // Ordinary v1-style terminal qualification still cannot bypass the bound predecessor.
        XCTAssertThrowsError(try DeviceBoundGrantAttemptCoordinator(journal:r.f.j,grants:r.f.g).stageExact(input,plan:plan,journalReceipt:pending))
        let staged=try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:pending)
        XCTAssertEqual(r.f.b.adds,2) // private attempt for each complete set; zero credentials.
        let batch=try r.f.c.preparePackagesExact(plan:plan,journalReceipt:staged.journalReceipt,privateAnchor:staged.privateAnchor,packages:input.packages)
        let credentials=try r.f.c.completeCredentialsExact(batch),terminal=try r.f.c.closeGrantTerminalExact(credentials)
        let ack=try r.coordinator.commitBoundTerminalExact(terminal,journal:r.f.j)
        let completion=try r.coordinator.completeProvisioningExact(terminal,acknowledgment:ack,journal:r.f.j)
        try r.f.j.verifyCompletion(completion);XCTAssertEqual(ack.operationID,input.operationID)
        for (name,bytes) in firstJournal where name.hasPrefix("operations/") {XCTAssertEqual(try files(r.f.jr)[name],bytes)}
        for (name,bytes) in firstGrants where name.hasPrefix("operations/") {XCTAssertEqual(try files(r.f.gr)[name],bytes)}
        XCTAssertNil(try r.f.j.inspectPendingExact())
    }
    func testGenuineV1PredecessorThenTwoBoundCompletionsPreserveLegacyAncestry()throws {
        let f=try fixture(request(),predecessor:true),root=try directory(),store=structural(root);try store.initializeExplicit()
        let c=commit(f,store),first=try f.c.closeGrantTerminalExact(f.completed),ack=try c.commitBoundTerminalExact(first,journal:f.j)
        _ = try c.completeProvisioningExact(first,acknowledgment:ack,journal:f.j)
        let legacy=try files(f.gr).filter{$0.key.contains(id(9001).uuidString.lowercased())}
        let input=try next(ack),plan=try DeviceProvisioningPlanner.qualify(input),pending=try f.j.stageExact(plan)
        let staged=try f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:pending)
        let batch=try f.c.preparePackagesExact(plan:plan,journalReceipt:staged.journalReceipt,privateAnchor:staged.privateAnchor,packages:[])
        let credentials=try f.c.completeCredentialsExact(batch),second=try f.c.closeGrantTerminalExact(credentials),secondAck=try c.commitBoundTerminalExact(second,journal:f.j)
        _ = try c.completeProvisioningExact(second,acknowledgment:secondAck,journal:f.j)
        XCTAssertFalse(legacy.isEmpty)
        for (name,bytes) in legacy {XCTAssertEqual(try files(f.gr)[name],bytes)}
        XCTAssertThrowsError(try f.g.prepareExact(freshV1()));XCTAssertEqual(f.b.adds,3)
    }
    func testReconstructedSuccessorNeverRewindsCompletedJournalTip()throws {
        let r=try ready();try completeFirst(r)
        let input=try next(r.ack),plan=try DeviceProvisioningPlanner.qualify(input)
        _ = try r.f.j.stageExact(plan)
        let j=journal(r.f.jr),g=grantStore(r.f.gr,r.f.b),p=packageStore(r.f.pr)
        let receipt=try j.recommitExact(plan),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let before=try files(r.f.jr),staged=try c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:receipt)
        XCTAssertEqual(try files(r.f.jr),before);XCTAssertEqual(try j.inspectPendingExact()?.operationID,input.operationID)
        try j.verify(staged.journalReceipt)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:staged.journalReceipt,privateAnchor:staged.privateAnchor,packages:[])
        _ = try c.completeCredentialsExact(batch)
    }
    func testOriginalJournalAndGrantBindingSyncFailuresRequireExplicitCurrentReceiptRetry()throws {
        for journalFault in [true,false] {
            var armed=false,failed=false
            let r=try ready(boundary:{point in if journalFault,armed,!failed,point == .afterFileSync(.binding){failed=true;throw Injected.fault}},grantBoundary:{point in if !journalFault,armed,!failed,point == .afterFileSync(.binding){failed=true;throw Injected.fault}})
            try completeFirst(r);let input=try next(r.ack),plan=try DeviceProvisioningPlanner.qualify(input),receipt=try r.f.j.stageExact(plan)
            armed=true
            XCTAssertThrowsError(try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:receipt));XCTAssertTrue(failed);XCTAssertEqual(r.f.b.adds,1)
            XCTAssertThrowsError(try r.f.j.verify(receipt))
            armed=false
            let restarted=journal(r.f.jr),g=grantStore(r.f.gr,r.f.b),p=packageStore(r.f.pr),fresh=try restarted.recommitExact(plan)
            let c=DeviceBoundPackagePreparationCoordinator(journal:restarted,grants:g,packages:p),staged=try c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:fresh)
            try restarted.verify(staged.journalReceipt);XCTAssertEqual(r.f.b.adds,2)
        }
    }
    func testRecordedNewPrivateIdentityResumesAfterRestartWithoutRewindingJournal()throws {
        for fault in [DeviceGrantPreparationStore.Boundary.beforeReplace(.progress),.afterDirectorySync(.progress)] {
        var armed=false,failed=false
        let r=try ready(grantBoundary:{point in if armed,!failed,point == fault{failed=true;throw Injected.fault}})
        try completeFirst(r);let input=try next(r.ack),plan=try DeviceProvisioningPlanner.qualify(input),receipt=try r.f.j.stageExact(plan)
        armed=true
        XCTAssertThrowsError(try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:receipt));XCTAssertTrue(failed);XCTAssertEqual(r.f.b.adds,2)
        let j=journal(r.f.jr),g=grantStore(r.f.gr,r.f.b),p=packageStore(r.f.pr),fresh=try j.recommitExact(plan),before=try files(r.f.jr)
        let c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p),staged=try c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:fresh)
        XCTAssertEqual(try files(r.f.jr),before);XCTAssertEqual(r.f.b.adds,2)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:staged.journalReceipt,privateAnchor:staged.privateAnchor,packages:[])
        _ = try c.completeCredentialsExact(batch)
        }
    }
    func testUnrecordedPrivateAdditionRestartBlocksButOriginalLiveInputRepairs()throws {
        var armed=false,failed=false
        let r=try ready(grantBoundary:{point in if armed,!failed,case .afterPrivateAdd = point {failed=true;throw Injected.fault}})
        try completeFirst(r);let input=try next(r.ack),plan=try DeviceProvisioningPlanner.qualify(input),receipt=try r.f.j.stageExact(plan)
        armed=true
        XCTAssertThrowsError(try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:receipt));XCTAssertTrue(failed)
        let before=try files(r.f.gr),j=journal(r.f.jr),g=grantStore(r.f.gr,r.f.b),p=packageStore(r.f.pr),fresh=try j.recommitExact(plan)
        XCTAssertThrowsError(try DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p).prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:fresh));XCTAssertEqual(try files(r.f.gr),before)
        armed=false
        let liveReceipt=try r.f.j.recommitExact(plan),staged=try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:liveReceipt)
        try r.f.j.verify(staged.journalReceipt);XCTAssertEqual(r.f.b.adds,2)
    }
    func testUnrelatedPredecessorMetadataStageBlocksResumedSuccessorWithoutAdoption()throws {
        for suffix in [".binding",".head-binding",".confirmed"] {
            let r=try ready();try completeFirst(r)
            let input=try next(r.ack),plan=try DeviceProvisioningPlanner.qualify(input),receipt=try r.f.j.stageExact(plan)
            _ = try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:receipt)
            let path=r.f.gr.appendingPathComponent("operations/"+r.f.r.grantOperationID.uuidString.lowercased()+suffix)
            let stage=URL(fileURLWithPath:path.path+".pending")
            try Data(contentsOf:path).write(to:stage)
            let fresh=try r.f.j.recommitExact(plan),before=try files(r.f.gr),adds=r.f.b.adds
            XCTAssertThrowsError(try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:fresh),suffix)
            XCTAssertEqual(try files(r.f.gr),before);XCTAssertEqual(r.f.b.adds,adds)
            XCTAssertTrue(FileManager.default.fileExists(atPath:stage.path))
        }
    }
    func testStalePendingReceiptAndReplacedBoundPredecessorTerminalFailBeforeNewPrivateEffects()throws {
        let r=try ready();try completeFirst(r)
        let input=try next(r.ack),plan=try DeviceProvisioningPlanner.qualify(input),old=try r.f.j.stageExact(plan),fresh=try r.f.j.recommitExact(plan),before=try files(r.f.gr)
        XCTAssertThrowsError(try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:old));XCTAssertEqual(try files(r.f.gr),before);XCTAssertEqual(r.f.b.adds,1)
        let proof=r.f.gr.appendingPathComponent("operations/"+r.f.r.grantOperationID.uuidString.lowercased()+".terminal"),bytes=try Data(contentsOf:proof)
        try bytes.write(to:proof,options:.atomic)
        let evidence=try files(r.f.jr)
        XCTAssertThrowsError(try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:fresh));XCTAssertEqual(try files(r.f.jr),evidence);XCTAssertEqual(r.f.b.adds,1)
    }
    #if canImport(CryptoKit)
    private func nonempty(_ secret:Data=Data("PRIVATE_CANARY_001".utf8),count:Int=1,offset:Int=0)throws->DeviceProvisioningPlanRequest {
        func hash(_ d:Data)->String{SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()}
        var packages:[DeviceProvisioningPackageInput]=[],entries:[DeviceGrantEntryInput]=[],installed:[DeviceStructuralEntry]=[],expectations:[DeviceGrantEntryExpectation]=[]
        for n in offset..<(offset+count) {
            let bytes=Data("<html></html>".utf8)
            var manifest=DashboardManifest(schemaVersion:1,dashboardId:id(100+n).uuidString.lowercased(),name:"Fixture",revision:id(200+n).uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[.init(alias:"api",required:false,operations:[.init(name:"read",kind:"http")])],files:[.init(path:"index.html",bytes:bytes.count,sha256:hash(bytes))])
            manifest.digest=hash(try GrantPreparationCodec.encode(manifest))
            let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:"Fixture",digest:manifest.digest!,orientation:.portrait,width:390,height:844)
            let package=try DevicePackageQualifier.qualify(.init(manifest:GrantPreparationCodec.encode(manifest),files:[.init(path:"index.html",bytes:bytes)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
            let reference=try PackagePreparationCodec.expectedReference(.init(operationID:id(300+n),package:package),rootID:id(3)),entryID=id(400+n)
            packages.append(.supplied(entryID:entryID,operationID:id(300+n),package:package));expectations.append(.init(entryID:entryID,package:package))
            installed.append(.init(entryID:entryID,displayName:"Household",revision:revision,packageDirectory:reference.directory))
            let grant=ConnectionGrant(schemaVersion:1,id:id(500+n),alias:"api",origin:"https://example.com",transport:.http,authRef:"logical",lan:false,allowInsecureHTTP:false,operations:[.init(name:"read",kind:.http,method:.GET,path:"/states",idempotent:true,write:false)])
            let provisioning=ConnectionProvisioning(dashboardId:revision.dashboardId,revision:revision.revision,provisioningId:"explicit",entries:[.init(grant:grant,binding:.init(authRef:"logical",placement:.bearer),secret:secret)])
            entries.append(.init(entryID:entryID,revision:revision,generic:provisioning,homeAssistant:nil,publicReads:nil,credentialReferences:[.init(credentialRevisionID:id(600),kind:.generic,key:"logical")]))
        }
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(5)),owner:owner,entries:entries,credentials:[.init(revisionID:id(600),bytes:secret)],retainedRevisions:[])
        return .init(roots:roots,operationID:id(10),grantOperationID:id(6),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:"opaque"),snapshot:.init(generationID:id(7),entries:installed,configuredEntryID:installed.first?.entryID,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:packages,grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:expectations))
    }
    private func distinctCredentials()throws->DeviceProvisioningPlanRequest {
        let r=try nonempty(count:2)
        let entries=r.grantInput.entries.enumerated().map{n,e in DeviceGrantEntryInput(entryID:e.entryID,revision:e.revision,generic:e.generic,homeAssistant:e.homeAssistant,publicReads:e.publicReads,credentialReferences:[.init(credentialRevisionID:id(600+n),kind:.generic,key:"logical")])}
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:r.grantInput.identity,owner:r.owner,entries:entries,credentials:[.init(revisionID:id(600),bytes:r.grantInput.credentials[0].bytes),.init(revisionID:id(601),bytes:r.grantInput.credentials[0].bytes)],retainedRevisions:[])
        return .init(roots:r.roots,operationID:r.operationID,grantOperationID:r.grantOperationID,expectedGenerationID:r.expectedGenerationID,baseline:r.baseline,snapshot:r.snapshot,owner:r.owner,packages:r.packages,grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:DeviceGrantPreparationStore.boundExpectations(r.packages)))
    }
    private func retainedNext(_ f:Fixture,_ ack:DeviceLocalCompleteSetCommitAcknowledgment,count:Int,secret:Data?=nil)throws->DeviceProvisioningPlanRequest {
        let source=try secret.map{try nonempty($0,count:count)} ?? f.r
        let selected=Array(f.r.snapshot.entries.prefix(count))
        let references=try selected.map{entry -> DevicePreparedPackageReference in
            let index=f.r.snapshot.entries.firstIndex(where:{$0.entryID == entry.entryID})!
            guard case .supplied(_,let op,let package)=f.r.packages[index] else{throw Injected.fault}
            return try PackagePreparationCodec.expectedReference(.init(operationID:op,package:package),rootID:id(3))
        }
        let verified=try f.p.inspectRetainedTerminalExact(references)
        let packages=zip(selected,verified).map{DeviceProvisioningPackageInput.retained(entryID:$0.0.entryID,reference:$0.1.reference,verified:$0.1)}
        let entries=Array(source.grantInput.entries.prefix(count)),used=Set(entries.flatMap{$0.credentialReferences.map(\.credentialRevisionID)})
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(21)),owner:owner,entries:entries,credentials:source.grantInput.credentials.filter{used.contains($0.revisionID)},retainedRevisions:[])
        return .init(roots:roots,operationID:id(20),grantOperationID:id(22),expectedGenerationID:ack.generationID,baseline:.expectedEnvelope(ack.envelopeBytes),snapshot:.init(generationID:id(23),entries:selected,configuredEntryID:selected.first?.entryID,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:packages,grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:packages.map{value in
            switch value {case .retained(let entryID,_,let value):return .init(entryID:entryID,package:value.package);case .supplied(let entryID,_,let value):return .init(entryID:entryID,package:value)}
        }))
    }
    func testSecondRetainedHistoricalSelectionPreservesSharedCredentialAndActualLatestPackage()throws {
        let f=try fixture(nonempty(count:2)),root=try directory(),store=structural(root);try store.initializeExplicit()
        let c=commit(f,store),terminal=try f.c.closeGrantTerminalExact(f.completed),ack=try c.commitBoundTerminalExact(terminal,journal:f.j)
        _ = try c.completeProvisioningExact(terminal,acknowledgment:ack,journal:f.j)
        let oldPrivate=f.b.values,oldPackages=try files(f.pr),input=try retainedNext(f,ack,count:1),plan=try DeviceProvisioningPlanner.qualify(input),pending=try f.j.stageExact(plan)
        let staged=try f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:pending)
        let batch=try f.c.preparePackagesExact(plan:plan,journalReceipt:staged.journalReceipt,privateAnchor:staged.privateAnchor,packages:input.packages)
        let done=try f.c.completeCredentialsExact(batch),second=try f.c.closeGrantTerminalExact(done),secondAck=try c.commitBoundTerminalExact(second,journal:f.j)
        _ = try c.completeProvisioningExact(second,acknowledgment:secondAck,journal:f.j)
        XCTAssertEqual(f.b.adds,3) // first private + one shared credential + second private.
        for (key,value) in oldPrivate {XCTAssertEqual(f.b.values[key]?.bytes,value.bytes);XCTAssertEqual(f.b.values[key]?.item,value.item)}
        XCTAssertEqual(try files(f.pr),oldPackages)
        XCTAssertEqual(secondAck.operationID,input.operationID)
    }
    func testChangedSharedCredentialBytesRejectBeforeAnyRepairOrAddition()throws {
        let f=try fixture(nonempty()),root=try directory(),store=structural(root);try store.initializeExplicit()
        let c=commit(f,store),terminal=try f.c.closeGrantTerminalExact(f.completed),ack=try c.commitBoundTerminalExact(terminal,journal:f.j)
        _ = try c.completeProvisioningExact(terminal,acknowledgment:ack,journal:f.j)
        let input=try retainedNext(f,ack,count:1,secret:Data("PRIVATE_CANARY_002".utf8)),plan=try DeviceProvisioningPlanner.qualify(input),pending=try f.j.stageExact(plan)
        let beforeJ=try files(f.jr),beforeG=try files(f.gr),beforeP=try files(f.pr),adds=f.b.adds
        XCTAssertThrowsError(try f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:pending))
        XCTAssertEqual(try files(f.jr),beforeJ);XCTAssertEqual(try files(f.gr),beforeG);XCTAssertEqual(try files(f.pr),beforeP);XCTAssertEqual(f.b.adds,adds)
        try f.j.verify(pending)
    }
    func testSecondDistinctCredentialSetRetainsExactPrivateReferences()throws {
        let f=try fixture(distinctCredentials()),root=try directory(),store=structural(root);try store.initializeExplicit()
        let c=commit(f,store),terminal=try f.c.closeGrantTerminalExact(f.completed),ack=try c.commitBoundTerminalExact(terminal,journal:f.j)
        _ = try c.completeProvisioningExact(terminal,acknowledgment:ack,journal:f.j)
        let old=f.b.values,input=try retainedNext(f,ack,count:2),plan=try DeviceProvisioningPlanner.qualify(input),pending=try f.j.stageExact(plan)
        let staged=try f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:pending)
        let batch=try f.c.preparePackagesExact(plan:plan,journalReceipt:staged.journalReceipt,privateAnchor:staged.privateAnchor,packages:input.packages)
        let done=try f.c.completeCredentialsExact(batch),second=try f.c.closeGrantTerminalExact(done),secondAck=try c.commitBoundTerminalExact(second,journal:f.j)
        _ = try c.completeProvisioningExact(second,acknowledgment:secondAck,journal:f.j)
        XCTAssertEqual(f.b.adds,4) // two immutable credential revisions, two private attempts.
        for (key,value) in old {XCTAssertEqual(f.b.values[key]?.item,value.item);XCTAssertEqual(f.b.values[key]?.bytes,value.bytes)}
    }
    #endif
}
