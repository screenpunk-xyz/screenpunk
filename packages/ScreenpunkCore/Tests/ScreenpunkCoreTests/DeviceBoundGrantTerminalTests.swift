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

final class DeviceBoundGrantTerminalTests:XCTestCase {
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
        let url=URL(fileURLWithPath:String(cString:p)).appendingPathComponent("bound-credential-"+UUID().uuidString)
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
    private func fixture(_ request:DeviceProvisioningPlanRequest,boundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in},prewarm:[DeviceProvisioningPackageInput]=[])throws->Fixture {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b,boundary:boundary),p=packageStore(pr),plan=try DeviceProvisioningPlanner.qualify(request)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        for input in prewarm {guard case .supplied(_,let op,let value)=input else{throw Injected.fault};_ = try p.prepareExact(.init(operationID:op,package:value))}
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(request,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:request.packages),completed=try c.completeCredentialsExact(batch)
        return .init(jr:jr,gr:gr,pr:pr,b:b,j:j,g:g,p:p,r:request,plan:plan,c:c,completed:completed)
    }
    private func freshV1()throws->DeviceGrantPreparationRequest {
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(9000)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        return .init(operationID:id(9001),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
    }
    func testEmptyTerminalIsDistinctAndLeavesJournalPendingAndV1Blocked()throws {
        let f=try fixture(request()),before=try files(f.jr),receipt=try f.c.closeGrantTerminalExact(f.completed)
        try f.c.verifyGrantTerminalExact(receipt);XCTAssertEqual(try files(f.jr),before);XCTAssertNotNil(try f.j.inspectPendingExact());XCTAssertEqual(f.b.adds,1)
        XCTAssertThrowsError(try f.g.prepareExact(freshV1())){XCTAssertEqual($0 as? DeviceGrantPreparationError,.repairRequired)}
        XCTAssertThrowsError(try f.c.closeGrantTerminalExact(f.completed))
        let recovery=try f.c.inspectGrantTerminalRecoveryExact(),again=try f.c.recommitGrantTerminalExact(recovery)
        try f.c.verifyGrantTerminalExact(again);XCTAssertThrowsError(try f.c.verifyGrantTerminalExact(receipt));XCTAssertEqual(f.b.adds,1)
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
    func testSharedAndDistinctCredentialsCloseWithoutFurtherPrivateAdds()throws {
        for r in [try nonempty(count:2),try distinctCredentials()] {
            let f=try fixture(r),adds=f.b.adds,pkgBefore=try files(f.pr),receipt=try f.c.closeGrantTerminalExact(f.completed)
            try f.c.verifyGrantTerminalExact(receipt);XCTAssertEqual(f.b.adds,adds);XCTAssertEqual(try files(f.pr),pkgBefore)
            let s=DeviceStructuralStore(root:try directory(),rootID:id(2));try s.initializeExplicit()
            let ref=DeviceRetainedGrantReference(identity:r.grantInput.identity,operationID:r.grantOperationID)
            let mapped=try f.c.inspectGrantTerminalRecoveryExact().packages
            XCTAssertThrowsError(try DeviceRetainedResourceResolver(packageStore:f.p,grantStore:f.g,structuralStore:s).resolveTerminalExact(selected:ref,groups:[.init(reference:ref,expectedOwner:owner,packages:mapped)]))
            XCTAssertThrowsError(try f.g.prepareExact(freshV1()));XCTAssertEqual(f.b.adds,adds)
        }
    }
    func testTerminalHeadProofFaultMatrixExactLiveRecovery()throws {
        var points:[DeviceGrantPreparationStore.Boundary]=[]
        for kind in [DeviceGrantPreparationStore.Kind.terminalBinding,.terminal,.headBinding,.head,.confirmation] {
            points += [.afterWrite(kind),.afterFileSync(kind),.beforeReplace(kind),.afterReplace(kind),.afterDirectorySync(kind)]
        }
        points += [.afterFileSync(.binding),.afterDirectorySync(.binding)]
        for point in points {
            var armed=false,hit=false
            let f=try fixture(nonempty(),boundary:{if armed && $0 == point{armed=false;hit=true;throw Injected.fault}})
            armed=true;XCTAssertThrowsError(try f.c.closeGrantTerminalExact(f.completed),String(describing:point));XCTAssertTrue(hit,String(describing:point))
            let recovery=try f.c.inspectGrantTerminalRecoveryExact(),receipt=try f.c.recommitGrantTerminalExact(recovery)
            try f.c.verifyGrantTerminalExact(receipt);XCTAssertEqual(f.b.adds,2)
        }
    }
    func testReconstructedRecordedTerminalAndHeadPhasesRequireExactSynchronization()throws {
        for point in [DeviceGrantPreparationStore.Boundary.afterReplace(.terminalBinding),.afterReplace(.terminal),.afterReplace(.headBinding),.afterReplace(.head),.afterReplace(.confirmation)] {
            var armed=false
            let f=try fixture(nonempty(),boundary:{if armed && $0 == point{armed=false;throw Injected.fault}})
            armed=true;XCTAssertThrowsError(try f.c.closeGrantTerminalExact(f.completed));XCTAssertFalse(armed)
            let j=journal(f.jr),g=grantStore(f.gr,f.b),p=packageStore(f.pr),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
            let original=try c.inspectGrantTerminalRecoveryExact(),receipt=try c.recommitGrantTerminalExact(original)
            try c.verifyGrantTerminalExact(receipt);XCTAssertEqual(f.b.adds,2)
        }
    }
    func testUnknownTerminalAndHeadRestartOrphansPreserveEvidence()throws {
        for point in [DeviceGrantPreparationStore.Boundary.afterWrite(.terminal),.afterWrite(.head)] {
            var armed=false
            let f=try fixture(nonempty(),boundary:{if armed && $0 == point{armed=false;throw Injected.fault}})
            armed=true;XCTAssertThrowsError(try f.c.closeGrantTerminalExact(f.completed));let before=try files(f.gr)
            let c=DeviceBoundPackagePreparationCoordinator(journal:journal(f.jr),grants:grantStore(f.gr,f.b),packages:packageStore(f.pr))
            XCTAssertThrowsError(try c.inspectGrantTerminalRecoveryExact());XCTAssertEqual(try files(f.gr),before);XCTAssertEqual(f.b.adds,2)
            let recovery=try f.c.inspectGrantTerminalRecoveryExact();_ = try f.c.recommitGrantTerminalExact(recovery)
        }
    }
    func testCapturedProofAndBindingSameByteReplacementAndAbsenceRejectBeforeEffects()throws {
        for name in ["root-binding.json","head.json","operations/"+id(6).uuidString.lowercased()+".binding","operations/"+id(6).uuidString.lowercased()+".head-binding","operations/"+id(6).uuidString.lowercased()+".confirmed"] {
            let f=try fixture(nonempty());_ = try f.c.closeGrantTerminalExact(f.completed)
            let recovery=try f.c.inspectGrantTerminalRecoveryExact(),path=f.gr.appendingPathComponent(name),temp=path.appendingPathExtension("replacement")
            try Data(contentsOf:path).write(to:temp);try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:temp,to:path)
            let before=try files(f.gr);XCTAssertThrowsError(try f.c.recommitGrantTerminalExact(recovery));XCTAssertEqual(try files(f.gr),before);XCTAssertEqual(f.b.adds,2)
        }
        let f=try fixture(nonempty()),recovery=try f.c.inspectGrantTerminalRecoveryExact()
        try Data("unexpected".utf8).write(to:f.gr.appendingPathComponent("head.json.pending"))
        let before=try files(f.gr);XCTAssertThrowsError(try f.c.recommitGrantTerminalExact(recovery));XCTAssertEqual(try files(f.gr),before)
    }
    func testRecordedPrivateAndCredentialMissingReferenceOrChangedBytesReject()throws {
        for key in [GrantPreparationCodec.attemptAccount(id(6)),GrantPreparationCodec.credentialAccount(id(600))] {
            for mode in 0..<3 {
                let f=try fixture(nonempty());_ = try f.c.closeGrantTerminalExact(f.completed)
                let recovery=try f.c.inspectGrantTerminalRecoveryExact(),old=try XCTUnwrap(f.b.values.removeValue(forKey:key))
                if mode == 1 {f.b.values[key] = .init(item:.init(account:key,persistentReference:Data("other-ref".utf8),byteCount:old.item.byteCount),bytes:old.bytes)}
                if mode == 2 {f.b.values[key] = .init(item:old.item,bytes:Data(repeating:65,count:old.bytes.count))}
                let before=try files(f.gr);XCTAssertThrowsError(try f.c.recommitGrantTerminalExact(recovery));XCTAssertEqual(try files(f.gr),before);XCTAssertEqual(f.b.adds,2)
            }
        }
    }
    func testOriginalRecoveryEpochSameAndOtherInstanceChangesReject()throws {
        for other in [false,true] {
            let f=try fixture(nonempty());_ = try f.c.closeGrantTerminalExact(f.completed)
            let original=try f.c.inspectGrantTerminalRecoveryExact()
            let c=other ? DeviceBoundPackagePreparationCoordinator(journal:journal(f.jr),grants:grantStore(f.gr,f.b),packages:packageStore(f.pr)):f.c
            _ = try c.recommitGrantTerminalExact(c.inspectGrantTerminalRecoveryExact())
            let before=try files(f.gr);XCTAssertThrowsError(try f.c.recommitGrantTerminalExact(original));XCTAssertEqual(try files(f.gr),before)
        }
    }
    func testHistoricalSelectedPackagesActualLatestAndNestedEntryGuards()throws {
        let r=try nonempty(count:2),extra=try nonempty(offset:10);var armed=false,j:DeviceLocalProvisioningIntentStore?
        let f=try fixture(r,boundary:{_ in if armed{armed=false;XCTAssertThrowsError(try j?.inspectPendingExact())}},prewarm:r.packages+extra.packages);j=f.j
        armed=true;let receipt=try f.c.closeGrantTerminalExact(f.completed);XCTAssertFalse(armed);try f.c.verifyGrantTerminalExact(receipt)
        let c=DeviceBoundPackagePreparationCoordinator(journal:journal(f.jr),grants:grantStore(f.gr,f.b),packages:packageStore(f.pr))
        let recovered=try c.recommitGrantTerminalExact(c.inspectGrantTerminalRecoveryExact());try c.verifyGrantTerminalExact(recovered)
        XCTAssertEqual(f.b.adds,2)
    }
    #endif
}
