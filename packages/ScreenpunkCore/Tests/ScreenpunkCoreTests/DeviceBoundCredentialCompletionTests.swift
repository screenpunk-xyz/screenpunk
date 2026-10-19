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

final class DeviceBoundCredentialCompletionTests:XCTestCase {
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
    private func v1(_ original:DeviceProvisioningPlanRequest)->DeviceGrantPreparationRequest {.init(operationID:original.grantOperationID,input:original.grantInput,qualified:original.qualifiedGrant,expectedEntries:[])}
    private func files(_ root:URL)throws->[String:Data] {var result:[String:Data]=[:];for path in try FileManager.default.subpathsOfDirectory(atPath:root.path){var isDir:ObjCBool=false;let url=root.appendingPathComponent(path);if FileManager.default.fileExists(atPath:url.path,isDirectory:&isDir),!isDir.boolValue{result[path]=try Data(contentsOf:url)}};return result}
    private func packageStore(_ root:URL,boundary:@escaping(DevicePackagePreparationStore.Boundary)throws->Void={_ in})->DevicePackagePreparationStore {.init(root:root,rootID:id(3),protectedScope:scope(root),boundary:boundary)}
    func testEmptyCredentialCompletionRemainsUnresolvedAndOldAnchorStale()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try request(),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:[]),done=try c.completeCredentialsExact(batch)
        try c.verifyCompletedCredentials(done);XCTAssertThrowsError(try c.verifyPreparedSet(batch));XCTAssertThrowsError(try c.completeCredentialsExact(batch))
        XCTAssertEqual(b.adds,1);XCTAssertFalse(try files(gr).keys.contains{$0.contains("terminal") || $0.contains("head")});XCTAssertNoThrow(try j.verify(receipt))
        XCTAssertThrowsError(try g.prepareExact(v1(r)));XCTAssertThrowsError(try g.recommitExact(v1(r)))
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
    func testSharedCredentialAddedOnceAndNeverTerminalized()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try nonempty(count:2),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages),before=try files(pr),done=try c.completeCredentialsExact(batch)
        try c.verifyCompletedCredentials(done);XCTAssertEqual(b.adds,2);XCTAssertEqual(try files(pr),before)
        XCTAssertEqual(try XCTUnwrap(b.values[GrantPreparationCodec.credentialAccount(id(600))]).bytes,r.grantInput.credentials[0].bytes)
        XCTAssertFalse(try files(gr).keys.contains{$0.contains("terminal") || $0.contains("head")})
        for bytes in try files(gr).values{XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("PRIVATE_CANARY_001"))}
        XCTAssertThrowsError(try g.recommitExact(v1(r)))
    }
    func testStalePackageAndJournalRejectBeforeCredentialAdd()throws {
        for changeJournal in [true,false] {
            let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
            try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
            let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
            let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages)
            if changeJournal {_ = try j.recommitExact(plan)}else{guard case .supplied(_,let op,let value)=r.packages[0] else{return XCTFail()};_ = try p.recommitExact(.init(operationID:op,package:value))}
            let before=try files(gr);XCTAssertThrowsError(try c.completeCredentialsExact(batch));XCTAssertEqual(b.adds,1);XCTAssertEqual(try files(gr),before)
        }
    }
    func testLostCredentialAddAcknowledgmentLiveRepairAndRestartOrphanRefusal()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr);var armed=false
        let g=grantStore(gr,b,boundary:{if case .afterPrivateAdd(let account)=$0,armed,account.hasPrefix("credential."){armed=false;throw Injected.fault}}),p=packageStore(pr),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages)
        armed=true;XCTAssertThrowsError(try c.completeCredentialsExact(batch));XCTAssertEqual(b.adds,2)
        XCTAssertThrowsError(try grantStore(gr,b).recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:r.packages))
        let recovery=try g.recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:r.packages),journalReceipt=try j.recommitExact(recovery.plan)
        let repaired=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).recommitRecoveredExact(recovery,journalReceipt:journalReceipt)
        let fresh=try c.preparePackagesExact(plan:plan,journalReceipt:journalReceipt,privateAnchor:repaired,packages:r.packages)
        let done=try c.completeCredentialsExact(fresh);try c.verifyCompletedCredentials(done);XCTAssertEqual(b.adds,2)
    }
    func testRecordedProgressRestartAndBindingFaultRequiresExplicitRecovery()throws {
        for point in [DeviceGrantPreparationStore.Boundary.afterReplace(.progress),.afterFileSync(.binding),.afterDirectorySync(.binding)] {
            let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr);var armed=false
            let g=grantStore(gr,b,boundary:{if armed && $0 == point{armed=false;XCTAssertThrowsError(try j.inspectPendingExact());throw Injected.fault}}),p=packageStore(pr),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
            try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
            let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
            let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages)
            armed=true;XCTAssertThrowsError(try c.completeCredentialsExact(batch));XCTAssertFalse(armed);XCTAssertThrowsError(try c.completeCredentialsExact(batch))
            let j2=journal(jr),g2=grantStore(gr,b),p2=packageStore(pr),recovery=try g2.recoverBoundPrivateAttempt(XCTUnwrap(j2.inspectPendingExact()),packages:r.packages)
            let receipt2=try j2.recommitExact(recovery.plan),anchor2=try DeviceBoundGrantAttemptCoordinator(journal:j2,grants:g2).recommitRecoveredExact(recovery,journalReceipt:receipt2)
            let c2=DeviceBoundPackagePreparationCoordinator(journal:j2,grants:g2,packages:p2),fresh=try c2.preparePackagesExact(plan:plan,journalReceipt:receipt2,privateAnchor:anchor2,packages:r.packages)
            let done=try c2.completeCredentialsExact(fresh);try c2.verifyCompletedCredentials(done);XCTAssertEqual(b.adds,2)
        }
    }
    func testChangedEqualPublicPrivateBytesAndUnknownInventoryRejectBeforeEffects()throws {
        for mutatePrivate in [true,false] {
            let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
            try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
            let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
            let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages)
            if mutatePrivate {
                let key=GrantPreparationCodec.attemptAccount(r.grantOperationID),original=try XCTUnwrap(b.values[key])
                let changed=try nonempty(Data("PRIVATE_CANARY_002".utf8));XCTAssertEqual(changed.qualifiedGrant.publicMetadataBytes,r.qualifiedGrant.publicMetadataBytes)
                let bytes=try DeviceProvisioningPrivateAttemptV2.encoded(.init(operationID:changed.grantOperationID,input:changed.grantInput,qualified:changed.qualifiedGrant,expectedEntries:DeviceGrantPreparationStore.boundExpectations(changed.packages)),intent:plan.canonicalBytes)
                XCTAssertEqual(bytes.count,original.bytes.count);b.values[key] = .init(item:original.item,bytes:bytes)
            } else {
                let key=GrantPreparationCodec.credentialAccount(id(999)),bytes=Data("unknown".utf8)
                b.values[key] = .init(item:.init(account:key,persistentReference:Data("unknown-ref".utf8),byteCount:bytes.count),bytes:bytes)
            }
            let before=try files(gr);XCTAssertThrowsError(try c.completeCredentialsExact(batch));XCTAssertEqual(b.adds,1);XCTAssertEqual(try files(gr),before)
        }
    }
    func testBindingReplacementDuringCompletionSuppressesAcknowledgment()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr);var armed=false
        let g=grantStore(gr,b,boundary:{if armed && $0 == .afterFileSync(.binding){armed=false
            let path=gr.appendingPathComponent("root-binding.json"),temp=path.appendingPathExtension("replacement")
            try Data(contentsOf:path).write(to:temp);try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:temp,to:path)
        }}),p=packageStore(pr),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages)
        armed=true;XCTAssertThrowsError(try c.completeCredentialsExact(batch));XCTAssertFalse(armed);XCTAssertEqual(b.adds,2)
        XCTAssertFalse(try files(gr).keys.contains{$0.contains("terminal") || $0.contains("head")})
    }
    private func distinctCredentials()throws->DeviceProvisioningPlanRequest {
        let r=try nonempty(count:2)
        let entries=r.grantInput.entries.enumerated().map{n,e in DeviceGrantEntryInput(entryID:e.entryID,revision:e.revision,generic:e.generic,homeAssistant:e.homeAssistant,publicReads:e.publicReads,credentialReferences:[.init(credentialRevisionID:id(600+n),kind:.generic,key:"logical")])}
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:r.grantInput.identity,owner:r.owner,entries:entries,credentials:[.init(revisionID:id(600),bytes:r.grantInput.credentials[0].bytes),.init(revisionID:id(601),bytes:r.grantInput.credentials[0].bytes)],retainedRevisions:[])
        return .init(roots:r.roots,operationID:r.operationID,grantOperationID:r.grantOperationID,expectedGenerationID:r.expectedGenerationID,baseline:r.baseline,snapshot:r.snapshot,owner:r.owner,packages:r.packages,grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:DeviceGrantPreparationStore.boundExpectations(r.packages)))
    }
    func testDistinctCredentialOrderFirstDurableReferenceThenRestartSecondAdd()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr);var armed=false
        let g=grantStore(gr,b,boundary:{if armed && $0 == .afterReplace(.progress){armed=false;throw Injected.fault}}),p=packageStore(pr),r=try distinctCredentials(),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages)
        armed=true;XCTAssertThrowsError(try c.completeCredentialsExact(batch));XCTAssertFalse(armed);XCTAssertEqual(b.adds,2)
        XCTAssertNotNil(b.values[GrantPreparationCodec.credentialAccount(id(600))]);XCTAssertNil(b.values[GrantPreparationCodec.credentialAccount(id(601))])
        let j2=journal(jr),g2=grantStore(gr,b),p2=packageStore(pr),recovery=try g2.recoverBoundPrivateAttempt(XCTUnwrap(j2.inspectPendingExact()),packages:r.packages)
        let receipt2=try j2.recommitExact(recovery.plan),anchor2=try DeviceBoundGrantAttemptCoordinator(journal:j2,grants:g2).recommitRecoveredExact(recovery,journalReceipt:receipt2),c2=DeviceBoundPackagePreparationCoordinator(journal:j2,grants:g2,packages:p2)
        let fresh=try c2.preparePackagesExact(plan:plan,journalReceipt:receipt2,privateAnchor:anchor2,packages:r.packages),done=try c2.completeCredentialsExact(fresh)
        try c2.verifyCompletedCredentials(done);XCTAssertEqual(b.adds,3);XCTAssertNotNil(b.values[GrantPreparationCodec.credentialAccount(id(601))])
    }
    func testRecordedCredentialMissingReplacedReferenceOrBytesReject()throws {
        for mode in 0..<3 {
            let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
            try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
            let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
            let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages),done=try c.completeCredentialsExact(batch)
            let key=GrantPreparationCodec.credentialAccount(id(600)),old=try XCTUnwrap(b.values.removeValue(forKey:key))
            if mode == 1 {b.values[key] = .init(item:.init(account:key,persistentReference:Data("replacement".utf8),byteCount:old.item.byteCount),bytes:old.bytes)}
            if mode == 2 {b.values[key] = .init(item:old.item,bytes:Data("PRIVATE_CANARY_002".utf8))}
            let before=try files(gr);XCTAssertThrowsError(try c.verifyCompletedCredentials(done));XCTAssertEqual(try files(gr),before);XCTAssertEqual(b.adds,2)
            XCTAssertThrowsError(try grantStore(gr,b).recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:r.packages))
        }
    }
    func testCompletedReceiptSameAndOtherInstanceEpochInvalidation()throws {
        for other in [false,true] {
            let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
            try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
            let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
            let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages),done=try c.completeCredentialsExact(batch)
            try c.verifyCompletedCredentials(done)
            let next=other ? grantStore(gr,b):g,recovery=try next.recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:r.packages)
            _ = try DeviceBoundGrantAttemptCoordinator(journal:j,grants:next).recommitRecoveredExact(recovery,journalReceipt:receipt)
            XCTAssertThrowsError(try c.verifyCompletedCredentials(done));XCTAssertEqual(b.adds,2)
        }
    }
    #endif
}
