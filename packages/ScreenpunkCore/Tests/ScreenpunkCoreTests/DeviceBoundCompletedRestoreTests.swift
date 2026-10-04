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

final class DeviceBoundCompletedRestoreTests:XCTestCase {
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
        let url=URL(fileURLWithPath:String(cString:p)).appendingPathComponent("bound-completed-restore-"+UUID().uuidString)
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
    private func ready(_ input:DeviceProvisioningPlanRequest?=nil,prewarm:[DeviceProvisioningPackageInput]=[],predecessor:Bool=false,structuralBoundary:@escaping(DeviceStructuralStore.Boundary)throws->Void={_ in},boundary:@escaping(DeviceLocalProvisioningIntentStore.Boundary)throws->Void={_ in},grantBoundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in})throws->Ready {
        let f=try fixture(input ?? request(),boundary:grantBoundary,prewarm:prewarm,predecessor:predecessor,journalBoundary:boundary),root=try directory(),store=structural(root,boundary:structuralBoundary);try store.initializeExplicit()
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
    private struct Resolver:DestinationResolver {func addresses(for host:String)throws->[String]{["93.184.216.34"]}}
    private final class Driver:DeviceImmutableGenericAdmissionDriver,@unchecked Sendable {
        let mutex=NSLock();var revoked=false;var mode=1;var validations=0
        var hook:(()throws->Void)?;var cancellation:[@Sendable ()->Void]=[]
        final class Reservation:DeviceImmutableGenericReservation,@unchecked Sendable {
            let driver:Driver;init(_ driver:Driver){self.driver=driver}
            func check()throws{driver.mutex.lock();let revoked=driver.revoked;driver.mutex.unlock();if revoked{throw ConnectionFailure.permissionRequired}}
            func finish(){}
        }
        func reserve(scope:DeviceImmutableGenericScope,validateResources:()throws->Void,onCancel:@escaping @Sendable ()->Void)throws->any DeviceImmutableGenericReservation {
            try DeviceLocalResourceRegistry.requireIdle()
            validations += 1;try hook?()
            if mode == 1 {try validateResources()}
            if mode == 2 {try? validateResources();try? validateResources()}
            if mode == 3 {try? validateResources()}
            mutex.lock();cancellation.append(onCancel);mutex.unlock()
            return Reservation(self)
        }
        func revoke(){mutex.lock();revoked=true;let callbacks=cancellation;mutex.unlock();for callback in callbacks{callback()}}
    }
    private final class HTTP:HTTPTransport,@unchecked Sendable {
        var calls=0;var headers:[String:String]=[:];var hook:(()async throws->Void)?
        func send(_ request:AuthorizedHTTPRequest)async throws->HTTPTransportResponse {
            calls += 1;headers=request.headers;try await hook?();return .init(status:200,body:Data("approved response".utf8))
        }
    }
    private struct Socket:WebSocketTransport {
        func connect(_ request:AuthorizedWebSocketRequest)async throws->any WebSocketSession {throw ConnectionFailure.permissionRequired}
    }
    private func denied(_ body:()async throws->Void,file:StaticString=#filePath,line:UInt=#line)async {
        do{try await body();XCTFail("Expected refusal",file:file,line:line)}catch{}
    }
    private final class FakeSession:WebSocketSession,@unchecked Sendable {
        private let mutex=NSLock();private var closeCount=0;private var callback:(()async throws->Void)?
        var closes:Int{mutex.lock();defer{mutex.unlock()};return closeCount}
        var hook:(()async throws->Void)?{get{mutex.lock();defer{mutex.unlock()};return callback}set{mutex.lock();callback=newValue;mutex.unlock()}}
        func receive()async throws->Data{let callback=hook;try await callback?();return Data("message".utf8)}
        func send(_ bytes:Data)async throws{}
        private func recordClose(){mutex.lock();closeCount += 1;mutex.unlock()}
        func close()async{recordClose()}
    }
    private struct FakeSockets:WebSocketTransport {
        let session:FakeSession
        func connect(_ request:AuthorizedWebSocketRequest)async throws->any WebSocketSession{session}
    }
    private actor Pause {
        private var entered=false
        private var observer:CheckedContinuation<Void,Never>?
        private var release:CheckedContinuation<Void,Never>?
        func wait()async{entered=true;observer?.resume();observer=nil;await withCheckedContinuation{release=$0}}
        func awaitEntry()async{if entered{return};await withCheckedContinuation{observer=$0}}
        func resume(){release?.resume();release=nil}
    }
    private func cancelled(_ body:()async throws->Void,file:StaticString=#filePath,line:UInt=#line)async {
        do{try await body();XCTFail("Canceled caller returned a result",file:file,line:line)}
        catch is CancellationError {} catch {XCTFail("Expected cancellation",file:file,line:line)}
    }
    private func gate(_ r:Ready)->DeviceLocalResourceGate {
        .init(packageStore:r.f.p,grantStore:r.f.g,structuralStore:r.store)
    }
    private func restored(_ r:Ready)throws->DeviceBoundRestoredRuntimeBinding {
        try DeviceLocalCompleteSetRestoreCoordinator(packageStore:r.f.p,grantStore:r.f.g,structuralStore:r.store).restoreLatestBoundCompletedExact(journal:r.f.j)
    }
    func testReconstructedEmptyCompletedCurrentRestoresWithoutCapacityOrLegacyConversion()throws {
        let r=try ready();try completeFirst(r);let beforeJ=try files(r.f.jr),beforeG=try files(r.f.gr),beforeP=try files(r.f.pr),beforeS=try files(r.root),adds=r.f.b.adds
        let j=journal(r.f.jr),g=grantStore(r.f.gr,r.f.b),p=packageStore(r.f.pr),store=structural(r.root)
        let result=try DeviceLocalCompleteSetRestoreCoordinator(packageStore:p,grantStore:g,structuralStore:store).restoreLatestBoundCompletedExact(journal:j)
        XCTAssertEqual(result.envelopeBytes,r.ack.envelopeBytes);XCTAssertEqual(result.operationID,r.ack.operationID);XCTAssertEqual(r.f.b.adds,adds)
        XCTAssertEqual(try files(r.f.jr),beforeJ);XCTAssertEqual(try files(r.f.gr),beforeG);XCTAssertEqual(try files(r.f.pr),beforeP);XCTAssertEqual(try files(r.root),beforeS)
        XCTAssertThrowsError(try j.stageExact(DeviceProvisioningPlanner.qualify(next(r.ack))))
        XCTAssertThrowsError(try g.prepareExact(freshV1()))
        XCTAssertThrowsError(try DeviceLocalCompleteSetRestoreCoordinator(packageStore:p,grantStore:g,structuralStore:store).restoreLatestTerminalExact())
    }
    func testPendingSuccessorAndUncommittedInitializedEmptyNeverBootstrapOldRuntime()throws {
        let r=try ready();try completeFirst(r);_ = try r.f.j.stageExact(DeviceProvisioningPlanner.qualify(next(r.ack)))
        let before=try files(r.f.gr),adds=r.f.b.adds
        XCTAssertThrowsError(try restored(r));XCTAssertEqual(try files(r.f.gr),before);XCTAssertEqual(r.f.b.adds,adds)
        let root=try directory(),j=journal(root);try j.initializeExplicit()
        XCTAssertThrowsError(try DeviceLocalCompleteSetRestoreCoordinator(packageStore:r.f.p,grantStore:r.f.g,structuralStore:r.store).restoreLatestBoundCompletedExact(journal:j))
    }
    func testOriginalSameTipEpochAndProofReplacementRejectBeforeRestoreEffects()throws {
        for replace in [false,true] {
            let r=try ready();try completeFirst(r);let g=gate(r),original=try g.inspectBoundCompletedCurrentExact(journal:r.f.j)
            if replace {
                let proof=r.f.jr.appendingPathComponent("operations/"+r.f.r.operationID.uuidString.lowercased()+".completion-confirm.json")
                try Data(contentsOf:proof).write(to:proof,options:.atomic)
            } else {_ = try journal(r.f.jr).recommitExact(r.f.plan)}
            let before=try files(r.f.gr),adds=r.f.b.adds
            XCTAssertThrowsError(try g.restoreBoundCompletedCurrentExact(original,journal:r.f.j));XCTAssertEqual(try files(r.f.gr),before);XCTAssertEqual(r.f.b.adds,adds)
        }
    }
    func testMissingCurrentStructuralEnvelopeAndJournalOrphanArePreservedBlocked()throws {
        for missing in [false,true] {
            let r=try ready();try completeFirst(r)
            if missing {try FileManager.default.removeItem(at:r.root.appendingPathComponent("structural-envelope.json"))}
            else {try Data("orphan".utf8).write(to:r.f.jr.appendingPathComponent("head.json.stage"))}
            let before=try files(r.f.jr),grant=try files(r.f.gr)
            XCTAssertThrowsError(try restored(r));XCTAssertEqual(try files(r.f.jr),before);XCTAssertEqual(try files(r.f.gr),grant)
        }
    }
    func testJournalAndGrantBindingSyncFaultsNeedExplicitNewDiscovery()throws {
        for journalFailure in [true,false] {
            var armed=false,hit=false
            let r=try ready(boundary:{point in if journalFailure,armed,!hit,point == .afterFileSync(.binding){hit=true;throw Injected.fault}},grantBoundary:{point in if !journalFailure,armed,!hit,point == .afterFileSync(.binding){hit=true;throw Injected.fault}})
            try completeFirst(r);let g=gate(r),original=try g.inspectBoundCompletedCurrentExact(journal:r.f.j);armed=true
            XCTAssertThrowsError(try g.restoreBoundCompletedCurrentExact(original,journal:r.f.j));XCTAssertTrue(hit)
            XCTAssertThrowsError(try g.restoreBoundCompletedCurrentExact(original,journal:r.f.j));armed=false
            let fresh=try g.inspectBoundCompletedCurrentExact(journal:r.f.j),result=try g.restoreBoundCompletedCurrentExact(fresh,journal:r.f.j)
            try g.verifyBoundRestoredRuntimeBinding(result);XCTAssertEqual(r.f.b.adds,1)
        }
    }
    func testStructuralFaultSuppressionAndExplicitFreshRetryPreserveOriginalIDs()throws {
        var armed=false,hit=false
        let r=try ready(structuralBoundary:{point in if armed,!hit,point == .afterFileSync(.envelope){hit=true;throw Injected.fault}})
        try completeFirst(r);let g=gate(r),original=try g.inspectBoundCompletedCurrentExact(journal:r.f.j);armed=true
        XCTAssertThrowsError(try g.restoreBoundCompletedCurrentExact(original,journal:r.f.j));XCTAssertTrue(hit)
        XCTAssertThrowsError(try g.restoreBoundCompletedCurrentExact(original,journal:r.f.j));armed=false
        let result=try restored(r);XCTAssertEqual(result.operationID,r.ack.operationID);XCTAssertEqual(result.envelopeBytes,r.ack.envelopeBytes)
        XCTAssertThrowsError(try r.f.j.stageExact(DeviceProvisioningPlanner.qualify(next(r.ack))))
    }
    func testEmptyCompletedSetHasNoGenericEntryAndNoDefaultAdmission()async throws {
        let r=try ready();try completeFirst(r);let result=try restored(r),driver=Driver(),http=HTTP()
        await denied{_ = try await self.gate(r).makeGenericRuntimeExact(binding:result,entryID:self.id(400),admission:driver,http:http,webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}
        XCTAssertEqual(driver.validations,0);XCTAssertEqual(http.calls,0)
    }
    #if canImport(CryptoKit)
    private func nonempty(_ secret:Data=Data("PRIVATE_CANARY_001".utf8),count:Int=1,offset:Int=0,ws:Bool=false)throws->DeviceProvisioningPlanRequest {
        func hash(_ d:Data)->String{SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()}
        var packages:[DeviceProvisioningPackageInput]=[],entries:[DeviceGrantEntryInput]=[],installed:[DeviceStructuralEntry]=[],expectations:[DeviceGrantEntryExpectation]=[]
        for n in offset..<(offset+count) {
            let bytes=Data("<html></html>".utf8)
            var manifest=DashboardManifest(schemaVersion:1,dashboardId:id(100+n).uuidString.lowercased(),name:"Fixture",revision:id(200+n).uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[.init(alias:"api",required:false,operations:[.init(name:"read",kind:ws ? "ws":"http")])],files:[.init(path:"index.html",bytes:bytes.count,sha256:hash(bytes))])
            manifest.digest=hash(try GrantPreparationCodec.encode(manifest))
            let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:"Fixture",digest:manifest.digest!,orientation:.portrait,width:390,height:844)
            let package=try DevicePackageQualifier.qualify(.init(manifest:GrantPreparationCodec.encode(manifest),files:[.init(path:"index.html",bytes:bytes)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
            let reference=try PackagePreparationCodec.expectedReference(.init(operationID:id(300+n),package:package),rootID:id(3)),entryID=id(400+n)
            packages.append(.supplied(entryID:entryID,operationID:id(300+n),package:package));expectations.append(.init(entryID:entryID,package:package))
            installed.append(.init(entryID:entryID,displayName:"Household",revision:revision,packageDirectory:reference.directory))
            let grant=ConnectionGrant(schemaVersion:1,id:id(500+n),alias:"api",origin:"https://example.com",transport:ws ? .ws:.http,authRef:"logical",lan:false,allowInsecureHTTP:false,operations:[.init(name:"read",kind:ws ? .ws:.http,method:.GET,path:"/states",idempotent:true,write:false)])
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
    private func completedNonempty(_ request:DeviceProvisioningPlanRequest?=nil)throws->Ready {
        let r=try ready(request ?? nonempty());try completeFirst(r);return r
    }
    func testGenuineSecondCompletedReconstructedSharedSetAndV1Ancestry()throws {
        for predecessor in [false,true] {
            let r=try ready(nonempty(count:2),predecessor:predecessor);try completeFirst(r)
            let input=try retainedNext(r.f,r.ack,count:1),plan=try DeviceProvisioningPlanner.qualify(input),pending=try r.f.j.stageExact(plan)
            let staged=try r.f.c.prepareSuccessorPrivateAttemptExact(input,plan:plan,journalReceipt:pending)
            let batch=try r.f.c.preparePackagesExact(plan:plan,journalReceipt:staged.journalReceipt,privateAnchor:staged.privateAnchor,packages:input.packages)
            let credentials=try r.f.c.completeCredentialsExact(batch),terminal=try r.f.c.closeGrantTerminalExact(credentials),ack=try r.coordinator.commitBoundTerminalExact(terminal,journal:r.f.j)
            _ = try r.coordinator.completeProvisioningExact(terminal,acknowledgment:ack,journal:r.f.j)
            let adds=r.f.b.adds,j=journal(r.f.jr),g=grantStore(r.f.gr,r.f.b),p=packageStore(r.f.pr),store=structural(r.root)
            let restored=try DeviceLocalCompleteSetRestoreCoordinator(packageStore:p,grantStore:g,structuralStore:store).restoreLatestBoundCompletedExact(journal:j)
            let gate=DeviceLocalResourceGate(packageStore:p,grantStore:g,structuralStore:store);try gate.verifyBoundRestoredRuntimeBinding(restored)
            XCTAssertEqual(restored.operationID,input.operationID);XCTAssertEqual(restored.generationID,input.snapshot.generationID);XCTAssertEqual(restored.envelopeBytes,ack.envelopeBytes);XCTAssertEqual(r.f.b.adds,adds)
            XCTAssertThrowsError(try g.prepareExact(freshV1()))
        }
    }
    func testDistinctCredentialRefsRestoreAndRecordedMissingReferenceBlocks()throws {
        let r=try completedNonempty(distinctCredentials()),adds=r.f.b.adds,result=try restored(r);try gate(r).verifyBoundRestoredRuntimeBinding(result)
        XCTAssertEqual(r.f.b.adds,adds)
        let key=try XCTUnwrap(r.f.b.values.keys.first(where:{$0.hasPrefix("credential.")}))
        let saved=r.f.b.values.removeValue(forKey:key)
        XCTAssertThrowsError(try gate(r).verifyBoundRestoredRuntimeBinding(result));XCTAssertEqual(r.f.b.adds,adds)
        r.f.b.values[key]=saved
    }
    func testMandatoryFakeAdmissionAndCallerCancellationSuppressLateCachedResponses()async throws {
        let r=try completedNonempty(),binding=try restored(r),driver=Driver(),http=HTTP(),adds=r.f.b.adds
        let api=try await gate(r).makeGenericRuntimeExact(binding:binding,entryID:id(400),admission:driver,http:http,webSocket:Socket(),resolver:Resolver(),clock:SystemClock())
        _ = try await api.requestRead(alias:"api",operation:"read",parameters:[:])
        let pause=Pause();http.hook={await pause.wait()}
        let pending=Task{try await api.requestRead(alias:"api",operation:"read",parameters:[:])}
        await pause.awaitEntry();pending.cancel();await pause.resume();await cancelled{_ = try await pending.value}
        XCTAssertEqual(http.calls,2);XCTAssertEqual(r.f.b.adds,adds);await api.cancel()
    }
    func testPreCanceledFactoryAndInvalidEntryDispatchNothing()async throws {
        let r=try completedNonempty(),binding=try restored(r),driver=Driver(),http=HTTP()
        let pending=Task{withUnsafeCurrentTask{$0?.cancel()};return try await self.gate(r).makeGenericRuntimeExact(binding:binding,entryID:self.id(400),admission:driver,http:http,webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}
        await cancelled{_ = try await pending.value};XCTAssertEqual(driver.validations,0);XCTAssertEqual(http.calls,0)
        await denied{_ = try await self.gate(r).makeGenericRuntimeExact(binding:binding,entryID:self.id(999),admission:driver,http:http,webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}
        XCTAssertEqual(driver.validations,0)
    }
    func testDriverSkippedDoubleAndSwallowedValidationCannotReturnRuntime()async throws {
        let r=try completedNonempty(),binding=try restored(r)
        for mode in [0,2] {let d=Driver();d.mode=mode;await denied{_ = try await self.gate(r).makeGenericRuntimeExact(binding:binding,entryID:self.id(400),admission:d,http:HTTP(),webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}}
        _ = try r.f.j.recommitExact(r.f.plan)
        let d=Driver();d.mode=3
        await denied{_ = try await self.gate(r).makeGenericRuntimeExact(binding:binding,entryID:self.id(400),admission:d,http:HTTP(),webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}
    }
    func testAllFourCheckpointChangesRefuseNewReservationsWithoutBackendEffects()async throws {
        for root in ["journal","grant","package","structural"] {
            let r=try completedNonempty(),binding=try restored(r),http=HTTP(),driver=Driver(),adds=r.f.b.adds
            let api=try await gate(r).makeGenericRuntimeExact(binding:binding,entryID:id(400),admission:driver,http:http,webSocket:Socket(),resolver:Resolver(),clock:SystemClock())
            switch root {
            case "journal":_ = try journal(r.f.jr).recommitExact(r.f.plan)
            case "grant":let path=r.f.gr.appendingPathComponent("root-binding.json");try Data(contentsOf:path).write(to:path,options:.atomic)
            case "package":
                guard case .supplied(_,let op,let package)=r.f.r.packages[0] else{throw Injected.fault}
                let reference=try PackagePreparationCodec.expectedReference(.init(operationID:op,package:package),rootID:id(3))
                _ = try packageStore(r.f.pr).resolveRetainedTerminalExact([reference])
            default:_ = try structural(r.root).recommitExact(operationID:r.ack.operationID)
            }
            await denied{_ = try await api.request(alias:"api",operation:"read",parameters:[:])}
            XCTAssertEqual(http.calls,0);XCTAssertEqual(r.f.b.adds,adds);await api.cancel()
        }
    }
    func testCanceledSocketReceiveDropsLateMessageAndPreservesImmutableCredentials()async throws {
        let r=try completedNonempty(nonempty(ws:true)),binding=try restored(r),session=FakeSession(),driver=Driver(),adds=r.f.b.adds
        let api=try await gate(r).makeGenericRuntimeExact(binding:binding,entryID:id(400),admission:driver,http:HTTP(),webSocket:FakeSockets(session:session),resolver:Resolver(),clock:SystemClock())
        let subscription=try await api.subscribe(alias:"api",operation:"read",parameters:[:]),pause=Pause();session.hook={await pause.wait()}
        let pending=Task{try await api.receive(id:subscription)}
        await pause.awaitEntry();pending.cancel();await pause.resume();await cancelled{_ = try await pending.value}
        XCTAssertGreaterThanOrEqual(session.closes,1);XCTAssertEqual(r.f.b.adds,adds);await api.cancel()
    }
    func testRuntimeRevocationRejectsCachedResponseAndPrivateTokenDescriptionsAreRedacted()async throws {
        let r=try completedNonempty(),binding=try restored(r),driver=Driver(),http=HTTP(),adds=r.f.b.adds
        XCTAssertFalse(String(describing:binding).contains("PRIVATE_CANARY_001"))
        let api=try await gate(r).makeGenericRuntimeExact(binding:binding,entryID:id(400),admission:driver,http:http,webSocket:Socket(),resolver:Resolver(),clock:SystemClock())
        _ = try await api.requestRead(alias:"api",operation:"read",parameters:[:]);driver.revoke()
        await denied{_ = try await api.requestRead(alias:"api",operation:"read",parameters:[:])}
        XCTAssertEqual(http.calls,1);XCTAssertEqual(r.f.b.adds,adds);await api.cancel()
    }
    #endif
}
