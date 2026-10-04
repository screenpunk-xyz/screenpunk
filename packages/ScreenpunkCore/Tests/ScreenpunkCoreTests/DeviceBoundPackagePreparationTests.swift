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

final class DeviceBoundPackagePreparationTests:XCTestCase {
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
        let url=URL(fileURLWithPath:String(cString:p)).appendingPathComponent("bound-package-"+UUID().uuidString)
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
    func testEmptyBatchOnlySynchronizesAndDoesNotCompleteGrant()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try request(),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt)
        let c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p),before=try files(gr)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:[])
        XCTAssertTrue(batch.packages.isEmpty);try c.verifyPreparedSet(batch);XCTAssertEqual(b.adds,1);XCTAssertEqual(try files(gr),before)
        _ = try p.resolveRetainedTerminalExact([]);XCTAssertThrowsError(try c.verifyPreparedSet(batch))
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
    func testTwoPackagesSharePrivateCredentialAndCompleteBatchCheckpoint()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try nonempty(count:2),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),before=try files(gr)
        let c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages)
        XCTAssertEqual(batch.packages.count,2);try c.verifyPreparedSet(batch);XCTAssertEqual(b.adds,1);XCTAssertEqual(try files(gr),before)
        let again=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages)
        XCTAssertThrowsError(try c.verifyPreparedSet(batch));try c.verifyPreparedSet(again)
    }
    func testInvalidCoverageBeforeEffectsPreservesOriginalAnchor()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try nonempty(count:2),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),before=try files(pr)
        let c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        for inputs in [Array(r.packages.prefix(1)),[r.packages[0],r.packages[0]],Array(repeating:r.packages[0],count:13)] {
            XCTAssertThrowsError(try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:inputs));XCTAssertEqual(try files(pr),before)
        }
        _ = try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages);XCTAssertEqual(b.adds,1)
    }
    func testSecondPackageInterruptedThenRestartKeepsHistoricalFirst()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),r=try nonempty(count:2),plan=try DeviceProvisioningPlanner.qualify(r)
        var installs=0
        let p=packageStore(pr,boundary:{if $0 == .afterReplace(.install){installs += 1;if installs == 2{throw Injected.fault}}})
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt)
        XCTAssertThrowsError(try DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p).preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages))
        let j2=journal(jr),g2=grantStore(gr,b),p2=packageStore(pr)
        let recovery=try g2.recoverBoundPrivateAttempt(XCTUnwrap(j2.inspectPendingExact()),packages:r.packages)
        let receipt2=try j2.recommitExact(recovery.plan),anchor2=try DeviceBoundGrantAttemptCoordinator(journal:j2,grants:g2).recommitRecoveredExact(recovery,journalReceipt:receipt2)
        let c=DeviceBoundPackagePreparationCoordinator(journal:j2,grants:g2,packages:p2)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt2,privateAnchor:anchor2,packages:r.packages)
        XCTAssertEqual(batch.packages.count,2);try c.verifyPreparedSet(batch);XCTAssertEqual(b.adds,1)
    }
    func testBindingSynchronizationFailureExactRetryAndReentry()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
        var armed=false,seen=false
        let p=packageStore(pr,boundary:{if armed && $0 == .afterFileSync(.binding){armed=false;seen=true;XCTAssertThrowsError(try j.inspectPendingExact());throw Injected.fault}})
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        armed=true;XCTAssertThrowsError(try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages));XCTAssertTrue(seen)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages);try c.verifyPreparedSet(batch);XCTAssertEqual(b.adds,1)
    }
    func testRecordedFaultMatrixLiveExactRetryWithoutGrantEffects()throws {
        let points:[DevicePackagePreparationStore.Boundary]=[.afterWrite(.intent),.afterFileSync(.intent),.afterReplace(.intent),.afterDirectorySync(.intent),.afterWrite(.file),.afterFileSync(.file),.afterReplace(.install),.afterFileSync(.terminal),.afterReplace(.terminal),.afterDirectorySync(.terminal)]
        for point in points {
            let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
            var armed=false,hit=false
            let p=packageStore(pr,boundary:{if armed && $0 == point{armed=false;hit=true;throw Injected.fault}})
            try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
            let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p),before=try files(gr)
            armed=true;XCTAssertThrowsError(try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages),String(describing:point));XCTAssertTrue(hit,String(describing:point))
            let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages);try c.verifyPreparedSet(batch)
            XCTAssertEqual(b.adds,1);XCTAssertEqual(try files(gr),before)
        }
    }
    func testUnmappedPendingAndRestartOrphanRejectWithoutEffects()throws {
        for unmapped in [false,true] {
            let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),r=try nonempty(count:unmapped ? 2:1),plan=try DeviceProvisioningPlanner.qualify(r)
            var armed=false
            let p=packageStore(pr,boundary:{if armed && $0 == .afterCreate(.directory){armed=false;throw Injected.fault}})
            try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
            let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt)
            guard case .supplied(_,let op,let package)=r.packages[0] else{return XCTFail()}
            armed=true;XCTAssertThrowsError(try p.prepareExact(.init(operationID:unmapped ? id(999):op,package:package)))
            let before=try files(pr),restart=packageStore(pr)
            XCTAssertThrowsError(try DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:restart).preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages))
            XCTAssertEqual(try files(pr),before);XCTAssertEqual(b.adds,1)
        }
    }
    func testHistoricalSelectedRetainedWithUnselectedActualLatest()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try nonempty(count:2),all=try nonempty(count:3),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        var retained:[DeviceProvisioningPackageInput]=[]
        for input in all.packages {
            guard case .supplied(let entry,let op,let value)=input else{return XCTFail()}
            let receipt=try p.prepareExact(.init(operationID:op,package:value))
            if retained.count < 2 {retained.append(.retained(entryID:entry,reference:receipt.reference,verified:try p.verify(receipt)))}
        }
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let before=try files(pr),batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:retained)
        XCTAssertEqual(batch.packages.count,2);try c.verifyPreparedSet(batch);XCTAssertEqual(try files(pr),before)
        guard case .supplied(_,let op,let value)=all.packages[2] else{return XCTFail()}
        _ = try p.recommitExact(.init(operationID:op,package:value));XCTAssertThrowsError(try c.verifyPreparedSet(batch));XCTAssertEqual(b.adds,1)
    }
    func testOriginalCapturedBindingReplacementRejectsBeforeContentEffects()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),r=try nonempty(),plan=try DeviceProvisioningPlanner.qualify(r)
        var armed=false
        let p=packageStore(pr,boundary:{if armed && $0 == .afterFileSync(.binding){armed=false
            let path=pr.appendingPathComponent("root-binding.json"),temp=path.appendingPathExtension("replacement")
            try Data(contentsOf:path).write(to:temp);try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:temp,to:path)
        }})
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt)
        armed=true
        XCTAssertThrowsError(try DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p).preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages))
        XCTAssertFalse(armed);XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:pr.appendingPathComponent("operations").path).isEmpty);XCTAssertEqual(b.adds,1)
    }
    func testWholeBatchCapacityReservedBeforeFirstAbsentPackage()throws {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),p=packageStore(pr),r=try nonempty(count:2,offset:200),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        for n in 0..<127 {
            guard case .supplied(_,let op,let value)=try nonempty(offset:n).packages[0] else{return XCTFail()}
            _ = try p.prepareExact(.init(operationID:op,package:value))
        }
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:plan,journalReceipt:receipt),before=try files(pr)
        XCTAssertThrowsError(try DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p).preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:r.packages))
        XCTAssertEqual(try files(pr),before);XCTAssertEqual(b.adds,1)
    }
    #endif
}
