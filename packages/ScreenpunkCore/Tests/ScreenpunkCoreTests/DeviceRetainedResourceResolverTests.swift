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

final class DeviceRetainedResourceResolverTests: XCTestCase {
    private final class Backend: DeviceGrantCredentialBackend, @unchecked Sendable {
        var values: [String:DeviceGrantCredentialValue] = [:], adds = 0
        var onRead: (() throws -> Void)?
        func inventory(service:String,maximum:Int,visit:(DeviceGrantCredentialItem)throws->Void)throws { for key in values.keys.sorted() { try visit(values[key]!.item) } }
        func read(service:String,account:String,maximumBytes:Int)throws->DeviceGrantCredentialValue? { try onRead?(); return values[account] }
        func add(service:String,account:String,bytes:Data)throws->DeviceGrantCredentialItem {
            guard values[account] == nil else { throw DeviceGrantPreparationError.conflict }; adds += 1
            let item = DeviceGrantCredentialItem(account:account,persistentReference:Data("ref-\(adds)".utf8),byteCount:bytes.count)
            values[account] = .init(item:item,bytes:bytes); return item
        }
    }
    private final class ReproductionBox<T>: @unchecked Sendable {
        private let mutex=NSLock();private var storage:T
        init(_ value:T) {storage=value}
        var value:T {get{mutex.lock();defer{mutex.unlock()};return storage}set{mutex.lock();defer{mutex.unlock()};storage=newValue}}
    }
    private func id(_ n:Int)->UUID { UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",n))! }
    private var owner:PairingIdentity { .init(role:.controller,publicKey:[UInt8](repeating:7,count:32)) }
    private func environment()throws->(URL,DevicePackageProtectedScope) {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil)); defer { free(physical) }
        let root = URL(fileURLWithPath:String(cString:physical),isDirectory:true).appendingPathComponent("complete-set-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        for name in ["structural","packages","grants","legacy","archive","reset","cloud","management","preferences"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:false) }
        return (root,.init(legacyStateRoot:root.appendingPathComponent("legacy"),legacyArchiveRoot:root.appendingPathComponent("archive"),resetRoot:root.appendingPathComponent("reset"),cloudRoot:root.appendingPathComponent("cloud"),managementRoot:root.appendingPathComponent("management"),preferencesRoot:root.appendingPathComponent("preferences"),otherProtectedRoots:[]))
    }
    private struct Fixture {
        let root:URL; let packages:DevicePackagePreparationStore; let grants:DeviceGrantPreparationStore; let backend:Backend
        let request:DeviceLocalCompleteSetRequest
        let structural:DeviceStructuralStore
        let scope:DevicePackageProtectedScope
        var commit:DeviceLocalCompleteSetCommitCoordinator { .init(packageStore:packages,grantStore:grants,structuralStore:structural) }
        var coordinator:DeviceLocalCompleteSetCoordinator { .init(packageStore:packages,grantStore:grants) }
    }
    private func replacing(_ r:DeviceLocalCompleteSetRequest,snapshot:DeviceStructuralSnapshot?=nil,baseline:DeviceLocalCompleteSetBaseline?=nil,
                           expected:UUID??=nil,packages:[DeviceLocalCompleteSetPackageBinding]?=nil,grant:DeviceGrantPreparationRequest?=nil,
                           owner:PairingIdentity?=nil)->DeviceLocalCompleteSetRequest {
        .init(structuralRootID:r.structuralRootID,operationID:r.operationID,expectedGenerationID:expected ?? r.expectedGenerationID,
            baseline:baseline ?? r.baseline,snapshot:snapshot ?? r.snapshot,packages:packages ?? r.packages,
            grantReceipt:r.grantReceipt,grantRequest:grant ?? r.grantRequest,owner:owner ?? r.owner)
    }
    private enum Marker:Error { case injected }
    private final class Fault { var target:DeviceStructuralStore.Boundary?;var hit=false;var hook:(()throws->Void)? }
    private func fixtureEmpty(_ fault:Fault = Fault())throws->Fixture {
        let env = try environment(), backend = Backend()
        let packages = DevicePackagePreparationStore(root:env.0.appendingPathComponent("packages"),rootID:id(1),protectedScope:env.1)
        let grants = DeviceGrantPreparationStore(root:env.0.appendingPathComponent("grants"),rootID:id(2),protectedScope:env.1,backend:backend)
        let structural=DeviceStructuralStore(root:env.0.appendingPathComponent("structural"),rootID:id(5),boundary:{ point in
            try fault.hook?()
            if fault.target == point { fault.target=nil;fault.hit=true;throw Marker.injected }
        })
        try packages.initializeExplicit(); try grants.initializeExplicit();try structural.initializeExplicit()
        let input = DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(3)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        let grant = DeviceGrantPreparationRequest(operationID:id(4),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
        let receipt = try grants.prepareExact(grant)
        return .init(root:env.0,packages:packages,grants:grants,backend:backend,request:.init(structuralRootID:id(5),operationID:id(6),expectedGenerationID:nil,
            baseline:.initialExplicit(legacyGrantSet:"opaque-legacy"),snapshot:.init(generationID:id(7),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque-legacy"),packages:[],grantReceipt:receipt,grantRequest:grant,owner:owner),structural:structural,scope:env.1)
    }
    private func selected(_ r:DeviceLocalCompleteSetRequest)->DeviceRetainedGrantReference { .init(identity:r.grantReceipt.identity,operationID:r.grantReceipt.operationID) }
    private func group(_ r:DeviceLocalCompleteSetRequest)->DeviceRetainedGrantResolutionGroup {
        .init(reference:selected(r),expectedOwner:r.owner,packages:r.packages.map{.init(entryID:$0.entryID,reference:$0.receipt.reference)})
    }
    private func fresh(_ f:Fixture,packageBoundary:@escaping (DevicePackagePreparationStore.Boundary)throws->Void={_ in},grantBoundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in})->(DeviceRetainedResourceResolver,DevicePackagePreparationStore,DeviceGrantPreparationStore) {
        let packages=DevicePackagePreparationStore(root:f.root.appendingPathComponent("packages"),rootID:id(1),protectedScope:f.scope,boundary:packageBoundary)
        let grants=DeviceGrantPreparationStore(root:f.root.appendingPathComponent("grants"),rootID:id(2),protectedScope:f.scope,backend:f.backend,boundary:grantBoundary)
        return (.init(packageStore:packages,grantStore:grants,structuralStore:f.structural),packages,grants)
    }
    private func files(_ root:URL)throws->[String:Data] {
        let walk=try XCTUnwrap(FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey]))
        var result:[String:Data]=[:]
        for case let url as URL in walk { if try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true { result[url.path]=try Data(contentsOf:url) } }
        return result
    }
    func testFreshEmptyCompleteRevisionReconstructedWithoutPrivateAddsOrExposure()throws {
        let f=try fixtureEmpty(),adds=f.backend.adds,before=try files(f.root),fresh=fresh(f)
        let resolved=try fresh.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)])
        XCTAssertEqual(resolved.selected,selected(f.request));XCTAssertTrue(resolved.packageReceipts.isEmpty);XCTAssertEqual(resolved.grantReceipts.count,1)
        XCTAssertEqual(f.backend.adds,adds);XCTAssertEqual(try files(f.root),before)
        XCTAssertNoThrow(try fresh.2.verifyRecovered(resolved.grantReceipts[0],expectedEntries:[],expectedOwner:owner))
        XCTAssertThrowsError(try f.grants.verify(f.request.grantReceipt)) // prior instance epoch invalidated
        XCTAssertFalse(String(describing:resolved.grantReceipts[0]).contains("input"))
    }
    func testInvalidMissingExtraDuplicateOwnerAndBoundsBeforeAnySynchronization()throws {
        let f=try fixtureEmpty();var syncs=0
        let stores=fresh(f,packageBoundary:{_ in syncs += 1},grantBoundary:{_ in syncs += 1}),before=try files(f.root)
        let valid=group(f.request),extra=DeviceRetainedGrantResolutionGroup(reference:.init(identity:.init(rootID:id(2),revisionID:id(88)),operationID:id(89)),expectedOwner:owner,packages:[])
        for groups in [[],[valid,valid],[valid,extra],[valid,extra,valid]] { XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:groups)) }
        let wrong=DeviceRetainedGrantResolutionGroup(reference:valid.reference,expectedOwner:.init(role:.controller,publicKey:[UInt8](repeating:8,count:32)),packages:[])
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[wrong]))
        let unused=DeviceRetainedGrantResolutionGroup(reference:valid.reference,expectedOwner:owner,packages:[.init(entryID:id(90),reference:.init(rootID:id(1),contentID:String(repeating:"a",count:64),preparationOperationID:id(91),directory:"missing"))])
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[unused]))
        let oversized=DeviceRetainedGrantResolutionGroup(reference:valid.reference,expectedOwner:owner,packages:Array(repeating:unused.packages[0],count:13))
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[oversized]))
        XCTAssertEqual(syncs,0);XCTAssertEqual(try files(f.root),before)
        XCTAssertNoThrow(try f.grants.verify(f.request.grantReceipt)) // rejected input did not invalidate epoch
    }
    func testActualLatestCannotBeOmittedOrChosenByCaller()throws {
        let f=try fixtureEmpty(),input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(80)),owner:owner,entries:[],credentials:[],retainedRevisions:[f.request.grantReceipt.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(81),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
        let latest=try f.grants.prepareExact(request),old=group(f.request),new=DeviceRetainedGrantResolutionGroup(reference:.init(identity:latest.identity,operationID:latest.operationID),expectedOwner:owner,packages:[])
        var syncs=0;let stores=fresh(f,packageBoundary:{_ in syncs += 1},grantBoundary:{_ in syncs += 1})
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:old.reference,groups:[old]));XCTAssertEqual(syncs,0)
        let resolved=try stores.0.resolveTerminalExact(selected:old.reference,groups:[new,old])
        XCTAssertEqual(resolved.grantReceipts.map(\.operationID),[old.reference.operationID,new.reference.operationID])
        for receipt in resolved.grantReceipts { XCTAssertNoThrow(try stores.2.verifyRecovered(receipt,expectedEntries:[],expectedOwner:owner)) }
    }
    func testMissingPrivateItemUnknownOrphanAndUnrelatedHistoryBlock()throws {
        let f=try fixtureEmpty(),key=f.backend.values.keys.first!,saved=f.backend.values[key]!,stores=fresh(f)
        f.backend.values.removeValue(forKey:key);XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]));f.backend.values[key]=saved
        let orphan=DeviceGrantCredentialItem(account:"credential."+id(89).uuidString.lowercased(),persistentReference:Data("orphan".utf8),byteCount:1)
        f.backend.values[orphan.account] = .init(item:orphan,bytes:Data([7]));XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]));XCTAssertNotNil(f.backend.values[orphan.account])
        f.backend.values.removeValue(forKey:orphan.account)
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(80)),owner:owner,entries:[],credentials:[],retainedRevisions:[f.request.grantReceipt.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(81),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[]),latest=try f.grants.prepareExact(request)
        f.backend.values.removeValue(forKey:key) // unrelated older retained intent, latest remains selected
        let group=DeviceRetainedGrantResolutionGroup(reference:.init(identity:latest.identity,operationID:latest.operationID),expectedOwner:owner,packages:[])
        XCTAssertThrowsError(try fresh(f).0.resolveTerminalExact(selected:group.reference,groups:[group]))
    }
    func testPrivateStrictDecoderControlsAndNoncanonicalAttemptRejected()throws {
        let f=try fixtureEmpty(),key=f.backend.values.keys.first!,saved=f.backend.values[key]!
        let original=String(decoding:saved.bytes,as:UTF8.self)
        for bytes in [Data([0xff]),Data("{} trailing".utf8),Data("{\"a\":1,\"\\u0061\":2}".utf8),Data("{\"a\":\"\\ud800\"}".utf8),Data(repeating:32,count:4*1024*1024+1)] { XCTAssertThrowsError(try GrantPreparationCodec.decodeAttempt(bytes)) }
        // Same typed input/public projection, but noncanonical schema number. Preserve every
        // recorded inode and update count metadata in-place so exact canonical equality is tested.
        let changed=Data(original.replacingOccurrences(of:"\"schemaVersion\":1",with:"\"schemaVersion\":1.0",options:[],range:original.range(of:"\"schemaVersion\":1")).utf8)
        XCTAssertNotEqual(changed,saved.bytes)
        XCTAssertNoThrow(try GrantPreparationCodec.decodeAttempt(changed))
        f.backend.values[key] = .init(item:.init(account:key,persistentReference:saved.item.persistentReference,byteCount:changed.count),bytes:changed)
        for suffix in [".json",".terminal"] {
            let path=f.root.appendingPathComponent("grants/operations/"+id(4).uuidString.lowercased()+suffix)
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
            object["privateAttemptBytes"]=changed.count
            var item=try XCTUnwrap(object["privateAttempt"] as? [String:Any]);item["byteCount"]=changed.count;object["privateAttempt"]=item
            // In-place write deliberately preserves recorded terminal identity for this fake-backend control.
            let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
            let handle=try FileHandle(forWritingTo:path);try handle.truncate(atOffset:0);try handle.write(contentsOf:data);try handle.close()
        }
        XCTAssertThrowsError(try fresh(f).0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]))
    }
    private func assertCaptured(_ bundle:DeviceResolvedRetainedResources,_ f:Fixture,
        _ packages:DevicePackagePreparationStore,_ grants:DeviceGrantPreparationStore)throws {
        let gate=DeviceLocalResourceGate(packageStore:packages,grantStore:grants,structuralStore:f.structural)
        try gate.withReadScope { scope in try scope.verifyResolutionCheckpoints(packages:bundle.packageCheckpoint,grants:bundle.grantCheckpoint) }
    }
    func testSameInstanceGrantLatestUpdateRejectsCapturedCheckpointButPreservesReceiptSemantics()throws {
        let f=try fixtureEmpty(),stores=fresh(f),bundle=try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)])
        try assertCaptured(bundle,f,stores.1,stores.2)
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(998)),owner:owner,
            entries:[],credentials:[],retainedRevisions:[f.request.grantReceipt.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(999),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
        _=try stores.2.prepareExact(request)
        XCTAssertNoThrow(try stores.2.verifyRecovered(bundle.grantReceipts[0],expectedEntries:[],expectedOwner:owner))
        XCTAssertThrowsError(try assertCaptured(bundle,f,stores.1,stores.2))
    }
    func testExplicitEmptyPackageTipAndSameTipRepairEpochRemainBound()throws {
        let f=try fixtureEmpty(),stores=fresh(f),bundle=try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)])
        try assertCaptured(bundle,f,stores.1,stores.2)
        _=try stores.1.resolveRetainedTerminalExact([]) // identical explicit empty tip, newer repair epoch
        XCTAssertThrowsError(try assertCaptured(bundle,f,stores.1,stores.2))
        let freshBundle=try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)])
        try assertCaptured(freshBundle,f,stores.1,stores.2)
        _=try stores.2.recommitExact(f.request.grantRequest) // identical grant tip, new epoch
        XCTAssertNoThrow(try stores.2.verifyRecovered(freshBundle.grantReceipts[0],expectedEntries:[],expectedOwner:owner))
        XCTAssertThrowsError(try assertCaptured(freshBundle,f,stores.1,stores.2))
    }
    func testBindingFileAndDirectorySyncFailuresDoNotQualifyAndRequireExactRetry()throws {
        for packageFailure in [true,false] {
            for fileFailure in [true,false] {
                let f=try fixtureEmpty();var fail=true,hits=0
                let stores=fresh(f,packageBoundary:{ point in
                    if packageFailure && point == (fileFailure ? .afterFileSync(.binding):.afterDirectorySync(.binding)) && fail {fail=false;hits += 1;throw Marker.injected}
                },grantBoundary:{ point in
                    if !packageFailure && point == (fileFailure ? .afterFileSync(.binding):.afterDirectorySync(.binding)) && fail {fail=false;hits += 1;throw Marker.injected}
                })
                XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]));XCTAssertEqual(hits,1)
                let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(898)),owner:owner,entries:[],credentials:[],retainedRevisions:[f.request.grantReceipt.identity])
                let request=DeviceGrantPreparationRequest(operationID:id(899),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
                if !packageFailure {XCTAssertThrowsError(try stores.2.prepareExact(request))}
                #if canImport(CryptoKit)
                if packageFailure {XCTAssertThrowsError(try stores.1.prepareExact(.init(operationID:id(897),package:package(99))))}
                #endif
                let repaired=try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)])
                try assertCaptured(repaired,f,stores.1,stores.2)
            }
        }
    }
    func testMissingFinalGateParticipantBlocksBundleAfterResourceRepair()throws {
        let f=try fixtureEmpty(),stores=fresh(f)
        try FileManager.default.removeItem(at:f.root.appendingPathComponent("structural/root-binding.json"))
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("structural/root-binding.json").path))
    }
    func testTerminalSyncUncertaintyRequiresExactResolutionAndInvalidatesPreviousReceipts()throws {
        let f=try fixtureEmpty();var fail=true
        let stores=fresh(f,grantBoundary:{ point in if point == .afterDirectorySync(.confirmation) && fail {fail=false;throw Marker.injected} })
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]));XCTAssertThrowsError(try f.grants.verify(f.request.grantReceipt))
        let resolved=try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)])
        XCTAssertNoThrow(try stores.2.verifyRecovered(resolved.grantReceipts[0],expectedEntries:[],expectedOwner:owner))
    }
    func testMissingAndSameByteReplacedHeadOrTerminalBlockWithoutAdoption()throws {
        for name in ["head.json","operations/"+id(4).uuidString.lowercased()+".terminal"] {
            let f=try fixtureEmpty(),path=f.root.appendingPathComponent("grants/"+name),bytes=try Data(contentsOf:path)
            try bytes.write(to:path,options:.atomic)
            XCTAssertThrowsError(try fresh(f).0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]))
        }
        let f=try fixtureEmpty();try FileManager.default.removeItem(at:f.root.appendingPathComponent("grants/head.json"))
        XCTAssertThrowsError(try fresh(f).0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]))
    }
    func testUnknownStagingAndPackageOrphansRemainBlockedAndPreserved()throws {
        for relative in ["grants/operations/"+id(4).uuidString.lowercased()+".json.pending","packages/root-binding.json.pending","packages/unknown-orphan"] {
            let f=try fixtureEmpty(),path=f.root.appendingPathComponent(relative)
            try Data("unowned evidence".utf8).write(to:path)
            XCTAssertThrowsError(try fresh(f).0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]))
            XCTAssertEqual(try Data(contentsOf:path),Data("unowned evidence".utf8))
        }
    }
    func testFinalReadGateMandatoryAndCallbackReentryDoesNotGainRepair()throws {
        let f=try fixtureEmpty(),stores=fresh(f);var called=0
        f.backend.onRead={ called += 1;XCTAssertThrowsError(try stores.1.resolveRetainedTerminalExact([])) }
        XCTAssertNoThrow(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]));XCTAssertGreaterThan(called,0)
        let gate=DeviceLocalResourceGate(packageStore:stores.1,grantStore:stores.2,structuralStore:f.structural)
        try gate.withReadScope {_ in XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)])) }
    }
    #if canImport(CryptoKit)
    private func encode<T:Encodable>(_ value:T)throws->Data { let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(value) }
    private func hash(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    private func package(_ n:Int,alias:String="api",name:String="Package")throws->QualifiedDevicePackage {
        let file = Data("<html></html>".utf8)
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:id(n).uuidString.lowercased(),name:name,revision:id(n+100).uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",
            target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[.init(alias:alias,required:false,operations:[.init(name:"read",kind:"http")])],files:[.init(path:"index.html",bytes:file.count,sha256:hash(file))])
        manifest.digest=hash(try encode(manifest))
        let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        return try DevicePackageQualifier.qualify(.init(manifest:encode(manifest),files:[.init(path:"index.html",bytes:file)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
    }
    private func populated(_ secret:Data=Data("PRIVATE_TRANSACTION_CANARY".utf8),alias:String="api",name:String="Package")throws->Fixture {
        let empty = try fixtureEmpty(); var bindings:[DeviceLocalCompleteSetPackageBinding]=[],entries:[DeviceStructuralEntry]=[],expected:[DeviceGrantEntryExpectation]=[],grants:[DeviceGrantEntryInput]=[]
        for n in [10,20] {
            let package=try package(n,alias:alias,name:name),receipt=try empty.packages.prepareExact(.init(operationID:id(n+200),package:package))
            bindings.append(.init(entryID:id(n),receipt:receipt));entries.append(.init(entryID:id(n),displayName:"Household \(n)",revision:package.revision,packageDirectory:receipt.reference.directory));expected.append(.init(entryID:id(n),package:package))
            let grant=ConnectionGrant(schemaVersion:1,id:id(n+300),alias:alias,origin:"https://example.com",transport:.http,authRef:"shared-logical",lan:false,allowInsecureHTTP:false,operations:[.init(name:"read",kind:.http,method:.GET,path:"/states",idempotent:true,write:false)])
            let config=ConnectionProvisioning(dashboardId:package.revision.dashboardId,revision:package.revision.revision,provisioningId:"supplied-approval",entries:[.init(grant:grant,binding:.init(authRef:grant.authRef,placement:.bearer),secret:secret)])
            grants.append(.init(entryID:id(n),revision:package.revision,generic:config,homeAssistant:nil,publicReads:nil,credentialReferences:[.init(credentialRevisionID:id(400),kind:.generic,key:"shared-logical")]))
        }
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(401)),owner:owner,entries:grants,credentials:[.init(revisionID:id(400),bytes:secret)],retainedRevisions:[empty.request.grantRequest.input.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(402),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:expected),expectedEntries:expected)
        let receipt=try empty.grants.prepareExact(request)
        return .init(root:empty.root,packages:empty.packages,grants:empty.grants,backend:empty.backend,request:.init(structuralRootID:id(5),operationID:id(403),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:nil),snapshot:.init(generationID:id(404),entries:entries,configuredEntryID:id(20),contentOwner:owner,grantSet:nil),packages:bindings,grantReceipt:receipt,grantRequest:request,owner:owner),structural:empty.structural,scope:empty.scope)
    }
    private func interleavedPackageResult(mutate:Bool)throws -> Result<DeviceResolvedRetainedResources,Error> {
        let f=try populated(),ready=ReproductionBox(false),paused=ReproductionBox(false)
        let entered=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
        let result=ReproductionBox<Result<DeviceResolvedRetainedResources,Error>?>(nil)
        let stores=fresh(f,packageBoundary:{ point in
            if point == .afterDirectorySync(.terminal) {ready.value=true}
        })
        let extra=try package(99)
        f.backend.onRead={
            if ready.value && !paused.value {
                paused.value=true;entered.signal()
                guard resume.wait(timeout:.now()+5) == .success else {throw Marker.injected}
            }
        }
        DispatchQueue.global().async {
            do {result.value = .success(try stores.0.resolveTerminalExact(selected:self.selected(f.request),groups:[self.group(f.request)]))}
            catch {result.value = .failure(error)}
            done.signal()
        }
        guard entered.wait(timeout:.now()+5) == .success else {
            resume.signal();_ = done.wait(timeout:.now()+5);XCTFail("phase pause not reached");throw Marker.injected
        }
        var mutation:DevicePreparedPackageReceipt?
        do {if mutate {mutation=try stores.1.prepareExact(.init(operationID:id(990),package:extra))}}
        catch {resume.signal();_ = done.wait(timeout:.now()+5);throw error}
        resume.signal();XCTAssertEqual(done.wait(timeout:.now()+5),.success)
        if mutate {XCTAssertNotNil(mutation)}
        return try XCTUnwrap(result.value)
    }
    func testConcurrentSameInstancePackageMutationRejectsCapturedResolution()throws {
        switch try interleavedPackageResult(mutate:true) {
        case .success:XCTFail("Old attempt checkpoint must reject interleaved SAME-instance newer tip")
        case .failure(let error):XCTAssertTrue(error is DevicePackagePreparationError)
        }
    }
    func testConcurrentPhasePauseWithoutMutationIsValidControl()throws {
        switch try interleavedPackageResult(mutate:false) {
        case .success(let bundle):XCTAssertEqual(bundle.packageReceipts.count,2)
        case .failure(let error):XCTFail("Unexpected control failure: \(error)")
        }
    }
    func testCanonicalUnicodeRevisionNameDoesNotMatchDifferentExactManifestBytes()throws {
        let f=try populated(name:"é"),valid=group(f.request)
        XCTAssertNoThrow(try fresh(f).0.resolveTerminalExact(selected:valid.reference,groups:[valid]))
        let key=GrantPreparationCodec.attemptAccount(f.request.grantRequest.operationID),saved=try XCTUnwrap(f.backend.values[key])
        let body=try GrantPreparationCodec.decodeAttempt(saved.bytes)
        let entries=body.input.entries.map { entry -> DeviceGrantEntryInput in
            let config=entry.generic!;var revision=entry.revision;revision.name="e\u{301}"
            return .init(entryID:entry.entryID,revision:revision,generic:config,homeAssistant:entry.homeAssistant,publicReads:entry.publicReads,credentialReferences:entry.credentialReferences)
        }
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:body.input.identity,owner:body.input.owner,entries:entries,credentials:body.input.credentials,retainedRevisions:body.input.retainedRevisions)
        let changed=try GrantPreparationCodec.encode(GrantPrivateAttempt(schemaVersion:1,rootID:body.rootID,operationID:body.operationID,input:input),limit:GrantPreparationCodec.intentLimit)
        let projection=try GrantPreparationCodec.projection(input)
        f.backend.values[key] = .init(item:.init(account:key,persistentReference:saved.item.persistentReference,byteCount:changed.count),bytes:changed)
        for suffix in [".json",".terminal"] {
            let path=f.root.appendingPathComponent("grants/operations/"+body.operationID.uuidString.lowercased()+suffix)
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
            object["privateAttemptBytes"]=changed.count;object["publicMetadata"]=projection.base64EncodedString()
            var item=try XCTUnwrap(object["privateAttempt"] as? [String:Any]);item["byteCount"]=changed.count;object["privateAttempt"]=item
            let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes]),handle=try FileHandle(forWritingTo:path)
            try handle.truncate(atOffset:0);try handle.write(contentsOf:data);try handle.close()
        }
        var syncs=0;let stores=fresh(f,packageBoundary:{_ in syncs += 1},grantBoundary:{_ in syncs += 1})
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:valid.reference,groups:[valid]));XCTAssertEqual(syncs,0)
    }
    func testGenuinePackagesLatestMappingsAndOriginalManifestRetained()throws {
        let f=try populated(),stores=fresh(f),adds=f.backend.adds,before=try files(f.root)
        let older=DeviceRetainedGrantResolutionGroup(reference:.init(identity:.init(rootID:id(2),revisionID:id(3)),operationID:id(4)),expectedOwner:owner,packages:[])
        var called=0;let invalid=fresh(f,packageBoundary:{_ in called += 1},grantBoundary:{_ in called += 1})
        XCTAssertThrowsError(try invalid.0.resolveTerminalExact(selected:older.reference,groups:[older]));XCTAssertEqual(called,0)
        let unused=DeviceRetainedGrantResolutionGroup(reference:older.reference,expectedOwner:owner,packages:[group(f.request).packages[0]])
        XCTAssertThrowsError(try invalid.0.resolveTerminalExact(selected:older.reference,groups:[group(f.request),unused]));XCTAssertEqual(called,0)
        let resolved=try stores.0.resolveTerminalExact(selected:older.reference,groups:[group(f.request),older])
        XCTAssertEqual(resolved.packageReceipts.count,2);XCTAssertEqual(resolved.grantReceipts.count,2);XCTAssertEqual(f.backend.adds,adds)
        XCTAssertEqual(try files(f.root),before)
        for receipt in resolved.packageReceipts { XCTAssertNoThrow(try stores.1.verify(receipt)) }
        XCTAssertFalse(try files(f.root).values.contains(where:{String(decoding:$0,as:UTF8.self).contains("PRIVATE_TRANSACTION_CANARY")}))
    }
    func testExplicitSharedPackageAndCredentialMappingsAcrossSelectedLatestGroups()throws {
        let f=try populated(),original=f.request.grantRequest
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(800)),owner:owner,
            entries:original.input.entries,credentials:original.input.credentials,retainedRevisions:[original.input.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(801),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:original.expectedEntries),expectedEntries:original.expectedEntries)
        let latest=try f.grants.prepareExact(request),older=group(f.request)
        let current=DeviceRetainedGrantResolutionGroup(reference:.init(identity:latest.identity,operationID:latest.operationID),expectedOwner:owner,packages:older.packages)
        let adds=f.backend.adds,resolved=try fresh(f).0.resolveTerminalExact(selected:older.reference,groups:[current,older])
        XCTAssertEqual(resolved.packageReceipts.count,2);XCTAssertEqual(resolved.grantReceipts.count,2);XCTAssertEqual(f.backend.adds,adds)
    }
    func testReferenceMismatchConflictingMappingAndUnrelatedPackageDamageBlockBeforeSync()throws {
        let f=try populated(),valid=group(f.request);var syncs=0
        let stores=fresh(f,packageBoundary:{_ in syncs += 1},grantBoundary:{_ in syncs += 1})
        let ref=valid.packages[0].reference
        for changed in [DevicePreparedPackageReference(rootID:id(999),contentID:ref.contentID,preparationOperationID:ref.preparationOperationID,directory:ref.directory),.init(rootID:ref.rootID,contentID:String(repeating:"0",count:64),preparationOperationID:ref.preparationOperationID,directory:ref.directory),.init(rootID:ref.rootID,contentID:ref.contentID,preparationOperationID:ref.preparationOperationID,directory:ref.directory+"é")] {
            let group=DeviceRetainedGrantResolutionGroup(reference:valid.reference,expectedOwner:owner,packages:[.init(entryID:valid.packages[0].entryID,reference:changed),valid.packages[1]])
            XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:valid.reference,groups:[group]))
        }
        let duplicated=DeviceRetainedGrantResolutionGroup(reference:valid.reference,expectedOwner:owner,packages:[valid.packages[0],valid.packages[0]])
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:valid.reference,groups:[duplicated]));XCTAssertEqual(syncs,0)
        let extra=try f.packages.prepareExact(.init(operationID:id(900),package:package(99)))
        let path=f.root.appendingPathComponent("packages/"+extra.reference.directory+"/index.html"),bytes=try Data(contentsOf:path)
        try bytes.write(to:path,options:.atomic) // unrelated retained package replacement
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:valid.reference,groups:[valid]));XCTAssertEqual(syncs,0)
    }
    func testPackageSyncFaultNoBundleAndEpochReverification()throws {
        let f=try populated();var failed=false
        let stores=fresh(f,packageBoundary:{ point in if point == .afterDirectorySync(.directory) && !failed {failed=true;throw Marker.injected} })
        XCTAssertThrowsError(try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)]));XCTAssertTrue(failed)
        XCTAssertThrowsError(try f.packages.verify(f.request.packages[0].receipt))
        let resolved=try stores.0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)])
        for receipt in resolved.packageReceipts { XCTAssertNoThrow(try stores.1.verify(receipt)) }
        _=try fresh(f).0.resolveTerminalExact(selected:selected(f.request),groups:[group(f.request)])
        XCTAssertThrowsError(try stores.1.verify(resolved.packageReceipts[0]));XCTAssertThrowsError(try stores.2.verifyRecovered(resolved.grantReceipts[0],expectedEntries:f.request.grantRequest.expectedEntries,expectedOwner:owner))
    }
    #endif
}
