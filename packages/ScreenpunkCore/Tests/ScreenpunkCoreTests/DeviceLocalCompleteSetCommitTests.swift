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

final class DeviceLocalCompleteSetCommitTests: XCTestCase {
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
            baseline:.initialExplicit(legacyGrantSet:"opaque-legacy"),snapshot:.init(generationID:id(7),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque-legacy"),packages:[],grantReceipt:receipt,grantRequest:grant,owner:owner),structural:structural)
    }
    private func next(_ r:DeviceLocalCompleteSetRequest, old:DeviceLocalCompleteSetCommitAcknowledgment, n:Int)->DeviceLocalCompleteSetRequest {
        var snapshot=r.snapshot;snapshot.generationID=id(n+1)
        return .init(structuralRootID:r.structuralRootID,operationID:id(n),expectedGenerationID:old.generationID,
            baseline:.expectedEnvelope(old.envelopeBytes),snapshot:snapshot,packages:r.packages,grantReceipt:r.grantReceipt,grantRequest:r.grantRequest,owner:r.owner)
    }
    private func envelope(_ f:Fixture)throws->Data? { let path=f.root.appendingPathComponent("structural/structural-envelope.json");return FileManager.default.fileExists(atPath:path.path) ? try Data(contentsOf:path):nil }
    func testEmptyCommitDuplicateAndNextPreserveExplicitLegacyAndCurrentTip()throws {
        let f=try fixtureEmpty(),adds=f.backend.adds
        let first=try f.commit.commitPreparedExact(f.request)
        XCTAssertEqual(first.operationID,f.request.operationID);XCTAssertEqual(try envelope(f),first.envelopeBytes)
        XCTAssertEqual(try StructuralStoreCodec.envelope(first.envelopeBytes).snapshot.grantSet,"opaque-legacy")
        let duplicate=try f.commit.commitPreparedExact(f.request);XCTAssertEqual(duplicate.envelopeBytes,first.envelopeBytes)
        let second=try f.commit.commitPreparedExact(next(f.request,old:first,n:50))
        XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request));XCTAssertEqual(try envelope(f),second.envelopeBytes)
        // Rejection of the older operation must not invalidate the qualified current tip.
        XCTAssertNoThrow(try f.commit.commitPreparedExact(next(f.request,old:second,n:60)))
        XCTAssertEqual(f.backend.adds,adds)
    }
    func testFaultMatrixExactOriginalRequestRetryAfterEveryDurabilityBoundary()throws {
        let cases:[DeviceStructuralStore.Boundary] = [.afterWrite(.intent),.afterFileSync(.intent),.beforeReplace(.intent),.afterReplace(.intent),.afterDirectorySync(.intent),.afterWrite(.envelope),.afterFileSync(.envelope),.beforeReplace(.envelope),.afterReplace(.envelope),.afterDirectorySync(.envelope),.afterWrite(.terminal),.afterFileSync(.terminal),.beforeReplace(.terminal),.afterReplace(.terminal),.afterDirectorySync(.terminal)]
        for point in cases {
            let fault=Fault(),f=try fixtureEmpty(fault);fault.target=point
            XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request),"boundary \(point)");XCTAssertTrue(fault.hit)
            let ack=try f.commit.commitPreparedExact(f.request)
            XCTAssertEqual(ack.operationID,f.request.operationID);XCTAssertEqual(try envelope(f),ack.envelopeBytes)
        }
    }
    func testChangedSameOperationIntentCannotRepairUncertainAttempt()throws {
        let fault=Fault(),f=try fixtureEmpty(fault);fault.target = .afterReplace(.envelope)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request))
        var snapshot=f.request.snapshot;snapshot.generationID=id(99)
        let before=try envelope(f)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(replacing(f.request,snapshot:snapshot)))
        XCTAssertEqual(try envelope(f),before);XCTAssertNoThrow(try f.commit.commitPreparedExact(f.request))
    }
    func testResourcesReverifiedBeforeRetryAndInvalidationPreservesStructuralEvidence()throws {
        let fault=Fault(),f=try fixtureEmpty(fault);fault.target = .afterReplace(.envelope)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request));let before=try envelope(f)
        let account=f.backend.values.keys.first!,original=f.backend.values[account]!
        f.backend.values[account] = .init(item:.init(account:account,persistentReference:Data("replacement".utf8),byteCount:original.bytes.count),bytes:original.bytes)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request));XCTAssertEqual(try envelope(f),before)
        f.backend.values[account]=original;XCTAssertNoThrow(try f.commit.commitPreparedExact(f.request))
    }
    func testStaleBaselineAndWrongRootRejectWithoutNewIntent()throws {
        let f=try fixtureEmpty(),first=try f.commit.commitPreparedExact(f.request)
        var snapshot=f.request.snapshot;snapshot.generationID=id(90)
        let stale=DeviceLocalCompleteSetRequest(structuralRootID:id(5),operationID:id(91),expectedGenerationID:nil,baseline:f.request.baseline,snapshot:snapshot,packages:[],grantReceipt:f.request.grantReceipt,grantRequest:f.request.grantRequest,owner:owner)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(stale));XCTAssertEqual(try envelope(f),first.envelopeBytes)
        let wrong=DeviceLocalCompleteSetRequest(structuralRootID:id(999),operationID:id(92),expectedGenerationID:first.generationID,baseline:.expectedEnvelope(first.envelopeBytes),snapshot:snapshot,packages:[],grantReceipt:f.request.grantReceipt,grantRequest:f.request.grantRequest,owner:owner)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(wrong));XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.root.appendingPathComponent("structural/operations").path).count,1)
    }
    func testSameByteEnvelopeReplacementBlocksDuplicate()throws {
        let f=try fixtureEmpty(),first=try f.commit.commitPreparedExact(f.request)
        try first.envelopeBytes.write(to:f.root.appendingPathComponent("structural/structural-envelope.json"),options:.atomic)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request))
    }
    func testReconstructedStructuralInstanceCanRetryWithLiveResourceReceiptsButNotNewIntent()throws {
        let fault=Fault(),f=try fixtureEmpty(fault);fault.target = .afterReplace(.terminal)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request))
        let store=DeviceStructuralStore(root:f.root.appendingPathComponent("structural"),rootID:id(5))
        let fresh=DeviceLocalCompleteSetCommitCoordinator(packageStore:f.packages,grantStore:f.grants,structuralStore:store)
        let visible=try XCTUnwrap(try envelope(f));var snapshot=f.request.snapshot;snapshot.generationID=id(79)
        let newer=DeviceLocalCompleteSetRequest(structuralRootID:id(5),operationID:id(78),expectedGenerationID:f.request.snapshot.generationID,
            baseline:.expectedEnvelope(visible),snapshot:snapshot,packages:[],grantReceipt:f.request.grantReceipt,grantRequest:f.request.grantRequest,owner:owner)
        XCTAssertThrowsError(try fresh.commitPreparedExact(newer));XCTAssertEqual(try envelope(f),visible)
        let exact=try fresh.commitPreparedExact(f.request);XCTAssertEqual(try envelope(f),exact.envelopeBytes)
        XCTAssertNoThrow(try fresh.commitPreparedExact(next(f.request,old:exact,n:70)))
    }
    func testReadScopeCannotDispatchWriteAndCallbacksRejectPromptly()throws {
        let fault=Fault(),f=try fixtureEmpty(fault)
        let gate=DeviceLocalResourceGate(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural)
        try gate.withReadScope {_ in XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request)) };XCTAssertNil(try envelope(f))
        var reads=0,hooks=0
        f.backend.onRead={ reads += 1;XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request)) }
        fault.hook={ hooks += 1;XCTAssertThrowsError(try f.structural.recommitExact(operationID:f.request.operationID));XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request)) }
        XCTAssertNoThrow(try f.commit.commitPreparedExact(f.request));XCTAssertGreaterThan(reads,0);XCTAssertGreaterThan(hooks,0)
    }
    func testOlderTerminalReplayRejectedWhileNewerAttemptPending()throws {
        let fault=Fault(),f=try fixtureEmpty(fault),first=try f.commit.commitPreparedExact(f.request)
        let request=next(f.request,old:first,n:80);fault.target = .afterReplace(.intent)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(request));let before=try envelope(f)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request));XCTAssertEqual(try envelope(f),before)
        XCTAssertNoThrow(try f.commit.commitPreparedExact(request))
    }
    func testOtherInstanceTerminalUncertaintyInvalidatesPreviouslyQualifiedTip()throws {
        let f=try fixtureEmpty(),first=try f.commit.commitPreparedExact(f.request)
        var injected=false
        let other=DeviceStructuralStore(root:f.root.appendingPathComponent("structural"),rootID:id(5),boundary:{ point in
            if point == .afterReplace(.terminal) && !injected { injected=true;throw Marker.injected }
        })
        let second=DeviceLocalCompleteSetCommitCoordinator(packageStore:f.packages,grantStore:f.grants,structuralStore:other)
        XCTAssertThrowsError(try second.commitPreparedExact(f.request));XCTAssertTrue(injected)
        let newer=next(f.request,old:first,n:85)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(newer));XCTAssertEqual(try envelope(f),first.envelopeBytes)
        XCTAssertNoThrow(try f.commit.commitPreparedExact(f.request));XCTAssertNoThrow(try f.commit.commitPreparedExact(newer))
    }
    func testMissingStructuralBindingNotCreatedAndBoundsFailBeforeEffects()throws {
        let f=try fixtureEmpty();try FileManager.default.removeItem(at:f.root.appendingPathComponent("structural/root-binding.json"))
        XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request));XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("structural/root-binding.json").path));XCTAssertNil(try envelope(f))
        XCTAssertThrowsError(try f.commit.commitPreparedExact(replacing(f.request,baseline:.expectedEnvelope(Data(repeating:1,count:128*1024+1)))))
    }
    #if canImport(CryptoKit)
    private func encode<T:Encodable>(_ value:T)throws->Data { let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(value) }
    private func hash(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    private func package(_ n:Int)throws->QualifiedDevicePackage {
        let file = Data("<html></html>".utf8)
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:id(n).uuidString.lowercased(),name:"Package",revision:id(n+100).uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",
            target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[.init(alias:"api",required:false,operations:[.init(name:"read",kind:"http")])],files:[.init(path:"index.html",bytes:file.count,sha256:hash(file))])
        manifest.digest=hash(try encode(manifest))
        let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        return try DevicePackageQualifier.qualify(.init(manifest:encode(manifest),files:[.init(path:"index.html",bytes:file)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
    }
    private func populated(_ secret:Data=Data("PRIVATE_TRANSACTION_CANARY".utf8))throws->Fixture {
        let empty = try fixtureEmpty(); var bindings:[DeviceLocalCompleteSetPackageBinding]=[],entries:[DeviceStructuralEntry]=[],expected:[DeviceGrantEntryExpectation]=[],grants:[DeviceGrantEntryInput]=[]
        for n in [10,20] {
            let package=try package(n),receipt=try empty.packages.prepareExact(.init(operationID:id(n+200),package:package))
            bindings.append(.init(entryID:id(n),receipt:receipt));entries.append(.init(entryID:id(n),displayName:"Household \(n)",revision:package.revision,packageDirectory:receipt.reference.directory));expected.append(.init(entryID:id(n),package:package))
            let grant=ConnectionGrant(schemaVersion:1,id:id(n+300),alias:"api",origin:"https://example.com",transport:.http,authRef:"shared-logical",lan:false,allowInsecureHTTP:false,operations:[.init(name:"read",kind:.http,method:.GET,path:"/states",idempotent:true,write:false)])
            let config=ConnectionProvisioning(dashboardId:package.revision.dashboardId,revision:package.revision.revision,provisioningId:"supplied-approval",entries:[.init(grant:grant,binding:.init(authRef:grant.authRef,placement:.bearer),secret:secret)])
            grants.append(.init(entryID:id(n),revision:package.revision,generic:config,homeAssistant:nil,publicReads:nil,credentialReferences:[.init(credentialRevisionID:id(400),kind:.generic,key:"shared-logical")]))
        }
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(401)),owner:owner,entries:grants,credentials:[.init(revisionID:id(400),bytes:secret)],retainedRevisions:[empty.request.grantRequest.input.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(402),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:expected),expectedEntries:expected)
        let receipt=try empty.grants.prepareExact(request)
        return .init(root:empty.root,packages:empty.packages,grants:empty.grants,backend:empty.backend,request:.init(structuralRootID:id(5),operationID:id(403),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:nil),snapshot:.init(generationID:id(404),entries:entries,configuredEntryID:id(20),contentOwner:owner,grantSet:nil),packages:bindings,grantReceipt:receipt,grantRequest:request,owner:owner),structural:empty.structural)
    }
    func testGenuineCompleteSharedGrantPackageCommitAndConfiguredSelection()throws {
        let f=try populated(),ack=try f.commit.commitPreparedExact(f.request)
        let snapshot=try StructuralStoreCodec.envelope(ack.envelopeBytes).snapshot
        XCTAssertEqual(snapshot.entries.map(\.entryID),[id(10),id(20)]);XCTAssertEqual(snapshot.configuredEntryID,id(20))
        XCTAssertFalse(String(decoding:ack.envelopeBytes,as:UTF8.self).contains("PRIVATE_TRANSACTION_CANARY"))
        let first=f.request.packages[0].receipt.reference
        let file=f.root.appendingPathComponent("packages/"+first.directory+"/index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path));try Data("changed".utf8).write(to:file)
        XCTAssertThrowsError(try f.commit.commitPreparedExact(f.request))
    }
    #endif
}
