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

final class DeviceBoundCompleteSetCommitTests:XCTestCase {
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
        let url=URL(fileURLWithPath:String(cString:p)).appendingPathComponent("bound-complete-set-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url
    }
    private func scope(_ root:URL)->DevicePackageProtectedScope {let p=root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-protected");return .init(legacyStateRoot:p.appendingPathComponent("state"),legacyArchiveRoot:p.appendingPathComponent("archive"),resetRoot:p.appendingPathComponent("reset"),cloudRoot:p.appendingPathComponent("cloud"),managementRoot:p.appendingPathComponent("management"),preferencesRoot:p.appendingPathComponent("preferences"),otherProtectedRoots:[])}
    private func grantStore(_ root:URL,_ backend:Backend,boundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in})->DeviceGrantPreparationStore {.init(root:root,rootID:id(4),protectedScope:scope(root),backend:backend,boundary:boundary)}
    private func journal(_ root:URL)->DeviceLocalProvisioningIntentStore {.init(root:root,rootID:id(1),protectedRoots:[root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-protected")])}
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
    private func fixture(_ request:DeviceProvisioningPlanRequest,boundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in},prewarm:[DeviceProvisioningPackageInput]=[],predecessor:Bool=false)throws->Fixture {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b,boundary:boundary),p=packageStore(pr),plan=try DeviceProvisioningPlanner.qualify(request)
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
    func testEmptyCommitExactDuplicateRetainsJournalUnresolved()throws {
        let f=try fixture(request()),root=try directory(),store=structural(root);try store.initializeExplicit()
        let terminal=try f.c.closeGrantTerminalExact(f.completed),journalBefore=try files(f.jr),adds=f.b.adds
        let coordinator=commit(f,store),ack=try coordinator.commitBoundTerminalExact(terminal,journal:f.j)
        XCTAssertEqual(ack.operationID,f.r.operationID);XCTAssertEqual(ack.generationID,f.r.snapshot.generationID)
        let structuralBefore=try files(root),again=try coordinator.commitBoundTerminalExact(terminal,journal:f.j)
        XCTAssertEqual(again.envelopeBytes,ack.envelopeBytes);XCTAssertEqual(try files(root),structuralBefore)
        XCTAssertEqual(try files(f.jr),journalBefore);XCTAssertNotNil(try f.j.inspectPendingExact());XCTAssertEqual(f.b.adds,adds)
        XCTAssertThrowsError(try f.g.prepareExact(freshV1()))
    }
    func testStructuralFaultMatrixExactRetryWithoutResourceRenewal()throws {
        var points:[DeviceStructuralStore.Boundary]=[]
        for kind in [DeviceStructuralStore.Kind.intent,.envelope,.terminal] {points += [.afterWrite(kind),.afterFileSync(kind),.beforeReplace(kind),.afterReplace(kind),.afterDirectorySync(kind)]}
        for point in points {
            var armed=false,hit=false
            let f=try fixture(request()),root=try directory(),store=structural(root,boundary:{if armed && $0 == point{armed=false;hit=true;throw Injected.fault}});try store.initializeExplicit()
            let terminal=try f.c.closeGrantTerminalExact(f.completed),before=try files(f.jr),coordinator=commit(f,store)
            armed=true;XCTAssertThrowsError(try coordinator.commitBoundTerminalExact(terminal,journal:f.j));XCTAssertTrue(hit)
            let ack=try coordinator.commitBoundTerminalExact(terminal,journal:f.j)
            XCTAssertEqual(ack.generationID,f.r.snapshot.generationID);XCTAssertEqual(try files(f.jr),before)
        }
    }
    func testReconstructedTerminalExplicitRecoveryThenStructuralCommit()throws {
        let f=try fixture(request());_ = try f.c.closeGrantTerminalExact(f.completed)
        let j=journal(f.jr),g=grantStore(f.gr,f.b),p=packageStore(f.pr),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let recovery=try c.inspectGrantTerminalRecoveryExact(),terminal=try c.recommitGrantTerminalExact(recovery),store=structural(try directory());try store.initializeExplicit()
        let coordinator=DeviceLocalCompleteSetCommitCoordinator(packageStore:p,grantStore:g,structuralStore:store)
        XCTAssertEqual(try coordinator.commitBoundTerminalExact(terminal,journal:j).generationID,f.r.snapshot.generationID)
    }
    func testStructuralRestartPendingCandidateTerminalAndSuccessfulExactRetry()throws {
        let points:[DeviceStructuralStore.Boundary?]=[.afterReplace(.intent),.afterReplace(.envelope),.afterReplace(.terminal),nil]
        for point in points {
            let f=try fixture(request()),root=try directory();var armed=false,hit=false
            let original=structural(root,boundary:{if armed,let point,$0 == point{armed=false;hit=true;throw Injected.fault}});try original.initializeExplicit()
            let terminal=try f.c.closeGrantTerminalExact(f.completed),journalBefore=try files(f.jr)
            armed=point != nil
            if point != nil {XCTAssertThrowsError(try commit(f,original).commitBoundTerminalExact(terminal,journal:f.j));XCTAssertTrue(hit)}
            else {_ = try commit(f,original).commitBoundTerminalExact(terminal,journal:f.j)}
            let retainedNames=Set(try files(root).keys)
            let j=journal(f.jr),g=grantStore(f.gr,f.b),p=packageStore(f.pr),resources=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
            let recovery=try resources.inspectGrantTerminalRecoveryExact(),reconstructed=try resources.recommitGrantTerminalExact(recovery)
            let newStore=structural(root),coordinator=DeviceLocalCompleteSetCommitCoordinator(packageStore:p,grantStore:g,structuralStore:newStore)
            let ack=try coordinator.commitBoundTerminalExact(reconstructed,journal:j)
            XCTAssertEqual(ack.operationID,f.r.operationID);XCTAssertEqual(ack.generationID,f.r.snapshot.generationID)
            XCTAssertEqual(try files(f.jr),journalBefore);XCTAssertNotNil(try j.inspectPendingExact())
            // Exact recovery retains one operation, regardless of its pending/terminal phase.
            let operations=try files(root).keys.filter{$0.hasPrefix("operations/") && $0.hasSuffix(".json")}
            XCTAssertEqual(operations.count,1)
            if point == nil {XCTAssertEqual(Set(try files(root).keys),retainedNames)}
            XCTAssertEqual(try coordinator.commitBoundTerminalExact(reconstructed,journal:j).envelopeBytes,ack.envelopeBytes)
        }
    }
    func testStaleJournalAndGrantEpochRejectBeforeStructuralEffects()throws {
        for other in [false,true] {for resource in [0,1] {
            let f=try fixture(request()),root=try directory(),store=structural(root);try store.initializeExplicit()
            let terminal=try f.c.closeGrantTerminalExact(f.completed),before=try files(root)
            if resource == 0 {_ = try (other ? journal(f.jr):f.j).recommitExact(f.plan)}
            else {let c=other ? DeviceBoundPackagePreparationCoordinator(journal:journal(f.jr),grants:grantStore(f.gr,f.b),packages:packageStore(f.pr)):f.c;_ = try c.recommitGrantTerminalExact(c.inspectGrantTerminalRecoveryExact())}
            XCTAssertThrowsError(try commit(f,store).commitBoundTerminalExact(terminal,journal:f.j));XCTAssertEqual(try files(root),before)
        }}
    }
    func testOriginalBindingReplacementRejectsBeforeStructuralEffects()throws {
        for resource in [0,1,2] {
            let f=try fixture(request()),root=try directory(),store=structural(root);try store.initializeExplicit()
            let terminal=try f.c.closeGrantTerminalExact(f.completed),before=try files(root),url=[f.jr,f.pr,f.gr][resource].appendingPathComponent("root-binding.json")
            let bytes=try Data(contentsOf:url);try bytes.write(to:url,options:.atomic)
            XCTAssertThrowsError(try commit(f,store).commitBoundTerminalExact(terminal,journal:f.j));XCTAssertEqual(try files(root),before)
        }
    }
    func testWrongStructuralRootAndJournalIssuerRejectWithoutEffects()throws {
        let f=try fixture(request()),root=try directory(),wrong=DeviceStructuralStore(root:root,rootID:id(990));try wrong.initializeExplicit()
        let terminal=try f.c.closeGrantTerminalExact(f.completed),before=try files(root)
        XCTAssertThrowsError(try commit(f,wrong).commitBoundTerminalExact(terminal,journal:f.j));XCTAssertEqual(try files(root),before)
        let good=structural(try directory());try good.initializeExplicit()
        XCTAssertThrowsError(try commit(f,good).commitBoundTerminalExact(terminal,journal:journal(f.jr)))
    }
    func testOlderOperationAndNewerPendingRejectWithoutChangingStructuralEvidence()throws {
        for completed in [false,true] {
            let f=try fixture(request()),root=try directory(),store=structural(root);try store.initializeExplicit()
            let terminal=try f.c.closeGrantTerminalExact(f.completed),coordinator=commit(f,store),ack=try coordinator.commitBoundTerminalExact(terminal,journal:f.j)
            let prior=try StructuralStoreCodec.envelope(ack.envelopeBytes)
            let snapshot=DeviceStructuralSnapshot(generationID:id(800),entries:prior.snapshot.entries,configuredEntryID:prior.snapshot.configuredEntryID,contentOwner:prior.snapshot.contentOwner,grantSet:prior.snapshot.grantSet)
            let next=DeviceStructuralCommitEnvelope(operationID:id(801),expectedGenerationID:ack.generationID,snapshot:snapshot,intent:prior.intent,outcome:prior.outcome)
            let record=DeviceStructuralOperationRecord(rootID:id(2),operationID:id(801),expectedOld:ack.envelopeBytes,candidate:try StructuralStoreCodec.encode(next),resourceAssertions:Data())
            // Mechanical-store fixture only: no authority is attributed to the subsequent envelope.
            try store.prepare(record);if completed {_ = try store.recommitExact(operationID:id(801))}
            let before=try files(root)
            XCTAssertThrowsError(try coordinator.commitBoundTerminalExact(terminal,journal:f.j));XCTAssertEqual(try files(root),before)
        }
    }
    func testGenuineV1PredecessorThenV2StructuralCommitAndLegacyStillBlocked()throws {
        let f=try fixture(request(),predecessor:true),store=structural(try directory());try store.initializeExplicit()
        let terminal=try f.c.closeGrantTerminalExact(f.completed)
        XCTAssertEqual(try commit(f,store).commitBoundTerminalExact(terminal,journal:f.j).generationID,f.r.snapshot.generationID)
        let grantBefore=try files(f.gr),historical=try f.g.recommitExact(freshV1())
        XCTAssertThrowsError(try f.g.verify(historical));XCTAssertEqual(try files(f.gr),grantBefore)
        let c=DeviceBoundPackagePreparationCoordinator(journal:journal(f.jr),grants:grantStore(f.gr,f.b),packages:packageStore(f.pr))
        let recovered=try c.recommitGrantTerminalExact(c.inspectGrantTerminalRecoveryExact())
        let freshCommit=DeviceLocalCompleteSetCommitCoordinator(packageStore:packageStore(f.pr),grantStore:grantStore(f.gr,f.b),structuralStore:store)
        // Receipts bind issuers. A new unrelated instance cannot borrow the recovered qualification.
        XCTAssertThrowsError(try freshCommit.commitBoundTerminalExact(recovered,journal:f.j))
    }
    func testPostDispatchResourceReplacementSuppressesAcknowledgment()throws {
        let f=try fixture(request()),root=try directory();var armed=false,hit=false
        let store=structural(root,boundary:{point in
            if armed && point == .afterDirectorySync(.terminal) {
                armed=false;hit=true
                let url=f.jr.appendingPathComponent("root-binding.json"),bytes=try Data(contentsOf:url)
                try bytes.write(to:url,options:.atomic)
            }
        });try store.initializeExplicit()
        let terminal=try f.c.closeGrantTerminalExact(f.completed);armed=true
        XCTAssertThrowsError(try commit(f,store).commitBoundTerminalExact(terminal,journal:f.j));XCTAssertTrue(hit)
        // Structural bytes may be durable while resource evidence is stale: no ACK is issued.
        XCTAssertNotNil(try store.recover(operationID:f.r.operationID))
        XCTAssertThrowsError(try commit(f,store).commitBoundTerminalExact(terminal,journal:f.j))
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
    func testSharedDistinctAndPackageCheckpointStaleness()throws {
        for r in [try nonempty(count:2),try distinctCredentials()] {
            let f=try fixture(r),store=structural(try directory());try store.initializeExplicit();let terminal=try f.c.closeGrantTerminalExact(f.completed)
            let ack=try commit(f,store).commitBoundTerminalExact(terminal,journal:f.j);XCTAssertEqual(ack.generationID,r.snapshot.generationID)
            let bindings=try f.c.inspectGrantTerminalRecoveryExact().packages
            _ = try f.p.resolveRetainedTerminalExact(bindings.map(\.reference))
            XCTAssertThrowsError(try commit(f,store).commitBoundTerminalExact(terminal,journal:f.j))
        }
    }
    #endif
}
