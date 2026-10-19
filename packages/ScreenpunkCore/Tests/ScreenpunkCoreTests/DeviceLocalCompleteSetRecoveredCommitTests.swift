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

final class DeviceLocalCompleteSetRecoveredCommitTests: XCTestCase {
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
    private func next(_ r:DeviceLocalCompleteSetRequest, old:DeviceLocalCompleteSetCommitAcknowledgment, n:Int)->DeviceLocalCompleteSetRequest {
        var snapshot=r.snapshot;snapshot.generationID=id(n+1)
        return .init(structuralRootID:r.structuralRootID,operationID:id(n),expectedGenerationID:old.generationID,
            baseline:.expectedEnvelope(old.envelopeBytes),snapshot:snapshot,packages:r.packages,grantReceipt:r.grantReceipt,grantRequest:r.grantRequest,owner:r.owner)
    }
    private func envelope(_ f:Fixture)throws->Data? { let path=f.root.appendingPathComponent("structural/structural-envelope.json");return FileManager.default.fileExists(atPath:path.path) ? try Data(contentsOf:path):nil }
    private func recovered(_ r:DeviceLocalCompleteSetRequest)->DeviceLocalCompleteSetRecoveredRequest {
        .init(structuralRootID:r.structuralRootID,operationID:r.operationID,expectedGenerationID:r.expectedGenerationID,
            baseline:r.baseline,snapshot:r.snapshot,packages:r.packages.map{.init(entryID:$0.entryID,reference:$0.receipt.reference)},owner:r.owner)
    }
    private func group(_ r:DeviceLocalCompleteSetRequest)->DeviceRetainedGrantResolutionGroup {
        .init(reference:.init(identity:r.grantReceipt.identity,operationID:r.grantReceipt.operationID),expectedOwner:r.owner,
              packages:r.packages.map{.init(entryID:$0.entryID,reference:$0.receipt.reference)})
    }
    private func resolve(_ f:Fixture,groups:[DeviceRetainedGrantResolutionGroup]?=nil)throws->DeviceResolvedRetainedResources {
            let resolver=DeviceRetainedResourceResolver(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural)
        return try resolver.resolveTerminalExact(selected:group(f.request).reference,groups:groups ?? [group(f.request)])
    }
    private func structuralFiles(_ f:Fixture)throws->[String:Data] {
        let root=f.root.appendingPathComponent("structural"),walk=try XCTUnwrap(FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey]))
        var files:[String:Data]=[:]
        for case let url as URL in walk { if try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true { files[url.path]=try Data(contentsOf:url) } };return files
    }
    func testEmptyRecoveredCommitDuplicateNextAndOlderOperationRefusal()throws {
        let f=try fixtureEmpty(),bundle=try resolve(f),adds=f.backend.adds
        let first=try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle)
        XCTAssertEqual(try envelope(f),first.envelopeBytes)
        XCTAssertEqual(try StructuralStoreCodec.envelope(first.envelopeBytes).snapshot.grantSet,"opaque-legacy")
        XCTAssertEqual(try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle).envelopeBytes,first.envelopeBytes)
        let second=try f.commit.commitRecoveredExact(recovered(next(f.request,old:first,n:50)),resources:bundle)
        let before=try structuralFiles(f)
        XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle));XCTAssertEqual(try structuralFiles(f),before)
        XCTAssertNoThrow(try f.commit.commitRecoveredExact(recovered(next(f.request,old:second,n:60)),resources:bundle))
        XCTAssertEqual(f.backend.adds,adds)
    }
    func testEveryStructuralBoundaryRetriesOriginalRecoveredRequest()throws {
        let points:[DeviceStructuralStore.Boundary]=[.afterWrite(.intent),.afterFileSync(.intent),.beforeReplace(.intent),.afterReplace(.intent),.afterDirectorySync(.intent),.afterWrite(.envelope),.afterFileSync(.envelope),.beforeReplace(.envelope),.afterReplace(.envelope),.afterDirectorySync(.envelope),.afterWrite(.terminal),.afterFileSync(.terminal),.beforeReplace(.terminal),.afterReplace(.terminal),.afterDirectorySync(.terminal)]
        for point in points {
            let fault=Fault(),f=try fixtureEmpty(fault),bundle=try resolve(f);fault.target=point
            XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle));XCTAssertTrue(fault.hit)
            let ack=try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle);XCTAssertEqual(try envelope(f),ack.envelopeBytes)
        }
    }
    func testOlderOperationRejectedWhileNewerPendingAndChangedRetryRejected()throws {
        let fault=Fault(),f=try fixtureEmpty(fault),bundle=try resolve(f)
        let first=try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle),new=next(f.request,old:first,n:80)
        fault.target = .afterReplace(.envelope)
        XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(new),resources:bundle));let before=try structuralFiles(f)
        XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle))
        var snapshot=new.snapshot;snapshot.generationID=id(100)
        XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(replacing(new,snapshot:snapshot)),resources:bundle))
        XCTAssertEqual(try structuralFiles(f),before);XCTAssertNoThrow(try f.commit.commitRecoveredExact(recovered(new),resources:bundle))
    }
    func testSameTipRepairInvalidatesOriginalPackageAndGrantCheckpointsBeforeEffects()throws {
        for package in [true,false] {
            let f=try fixtureEmpty(),bundle=try resolve(f),before=try structuralFiles(f)
            if package { _ = try f.packages.resolveRetainedTerminalExact([]) }
            else { try f.grants.recommitExact(f.request.grantRequest) }
            XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle));XCTAssertEqual(try structuralFiles(f),before)
            let fresh=try resolve(f);XCTAssertNoThrow(try f.commit.commitRecoveredExact(recovered(f.request),resources:fresh))
        }
    }
    func testSameAndOtherInstanceLatestGrantMutationRejectBeforeStructuralEffects()throws {
        for other in [false,true] {
            let f=try fixtureEmpty(),bundle=try resolve(f),before=try structuralFiles(f)
            let store=other ? DeviceGrantPreparationStore(root:f.root.appendingPathComponent("grants"),rootID:id(2),protectedScope:f.scope,backend:f.backend):f.grants
            if other { _ = try DeviceRetainedResourceResolver(packageStore:f.packages,grantStore:store,structuralStore:f.structural).resolveTerminalExact(selected:group(f.request).reference,groups:[group(f.request)]) }
            let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(90)),owner:owner,entries:[],credentials:[],retainedRevisions:[f.request.grantReceipt.identity])
            let request=DeviceGrantPreparationRequest(operationID:id(91),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
            _ = try store.prepareExact(request)
            XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle));XCTAssertEqual(try structuralFiles(f),before)
        }
    }
    func testWrongOwnerRootSelectionCoverageAndBoundsDoNotCreateIntent()throws {
        let f=try fixtureEmpty(),bundle=try resolve(f),before=try structuralFiles(f)
        var snapshot=f.request.snapshot;snapshot.configuredEntryID=id(999)
        let requests=[recovered(replacing(f.request,owner:.init(role:.controller,publicKey:[UInt8](repeating:8,count:32)))),recovered(replacing(f.request,snapshot:snapshot)),recovered(replacing(f.request,baseline:.expectedEnvelope(Data(repeating:1,count:128*1024+1))))]
        for request in requests { XCTAssertThrowsError(try f.commit.commitRecoveredExact(request,resources:bundle)) }
        let r=recovered(f.request),missing=DeviceRetainedEntryPackageBinding(entryID:id(99),reference:.init(rootID:id(1),contentID:String(repeating:"a",count:64),preparationOperationID:id(100),directory:"missing"))
        for bindings in [[missing],Array(repeating:missing,count:13)] {
            XCTAssertThrowsError(try f.commit.commitRecoveredExact(.init(structuralRootID:r.structuralRootID,operationID:r.operationID,expectedGenerationID:nil,baseline:r.baseline,snapshot:r.snapshot,packages:bindings,owner:r.owner),resources:bundle))
        }
        XCTAssertThrowsError(try f.commit.commitRecoveredExact(.init(structuralRootID:id(999),operationID:r.operationID,expectedGenerationID:nil,baseline:r.baseline,snapshot:r.snapshot,packages:[],owner:r.owner),resources:bundle))
        XCTAssertEqual(try structuralFiles(f),before);XCTAssertNoThrow(try f.commit.commitRecoveredExact(r,resources:bundle))
    }
    func testSelectedOlderEmptyGrantWithActualLatestRemainsExplicit()throws {
        let f=try fixtureEmpty(),input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(90)),owner:owner,entries:[],credentials:[],retainedRevisions:[f.request.grantReceipt.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(91),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[]),receipt=try f.grants.prepareExact(request)
        let latest=DeviceRetainedGrantResolutionGroup(reference:.init(identity:receipt.identity,operationID:receipt.operationID),expectedOwner:owner,packages:[])
        let bundle=try resolve(f,groups:[latest,group(f.request)]),ack=try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle)
        let refs=try JSONDecoder().decode(DeviceLocalCompleteSetReferences.self,from:StructuralStoreCodec.envelope(ack.envelopeBytes).intent)
        XCTAssertEqual(refs.grants.identity,f.request.grantReceipt.identity);XCTAssertNotEqual(refs.grants.identity,receipt.identity)
    }
    func testReadScopeAndFaultBackendReentryCannotDispatchRecoveredWrites()throws {
        let fault=Fault(),f=try fixtureEmpty(fault),bundle=try resolve(f)
        let gate=DeviceLocalResourceGate(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural)
        try gate.withReadScope {_ in XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle)) }
        var reads=0,hooks=0
        f.backend.onRead={ reads += 1;XCTAssertThrowsError(try f.commit.commitRecoveredExact(self.recovered(f.request),resources:bundle)) }
        fault.hook={ hooks += 1;XCTAssertThrowsError(try f.commit.commitRecoveredExact(self.recovered(f.request),resources:bundle)) }
        XCTAssertNoThrow(try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle));XCTAssertGreaterThan(reads,0);XCTAssertGreaterThan(hooks,0)
    }
    func testFreshResolverAndStructuralInstanceCanRepairOriginalUncertainAttempt()throws {
        let fault=Fault(),f=try fixtureEmpty(fault),original=try resolve(f);fault.target = .afterReplace(.terminal)
        XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(f.request),resources:original))
        let structural=DeviceStructuralStore(root:f.root.appendingPathComponent("structural"),rootID:id(5))
        let packages=DevicePackagePreparationStore(root:f.root.appendingPathComponent("packages"),rootID:id(1),protectedScope:f.scope)
        let grants=DeviceGrantPreparationStore(root:f.root.appendingPathComponent("grants"),rootID:id(2),protectedScope:f.scope,backend:f.backend)
        let resolver=DeviceRetainedResourceResolver(packageStore:packages,grantStore:grants,structuralStore:structural)
        let bundle=try resolver.resolveTerminalExact(selected:group(f.request).reference,groups:[group(f.request)])
        let commit=DeviceLocalCompleteSetCommitCoordinator(packageStore:packages,grantStore:grants,structuralStore:structural)
        let before=try structuralFiles(f)
        XCTAssertThrowsError(try commit.commitRecoveredExact(recovered(f.request),resources:original));XCTAssertEqual(try structuralFiles(f),before)
        let ack=try commit.commitRecoveredExact(recovered(f.request),resources:bundle)
        XCTAssertEqual(try envelope(f),ack.envelopeBytes)
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
        return .init(root:empty.root,packages:empty.packages,grants:empty.grants,backend:empty.backend,request:.init(structuralRootID:id(5),operationID:id(403),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:nil),snapshot:.init(generationID:id(404),entries:entries,configuredEntryID:id(20),contentOwner:owner,grantSet:nil),packages:bindings,grantReceipt:receipt,grantRequest:request,owner:owner),structural:empty.structural,scope:empty.scope)
    }
    func testRecoveredNonemptySharedSecretsAndLatestOnlyPackagesNotPromoted()throws {
        let f=try populated(),bundle=try resolve(f),ack=try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle)
        let snapshot=try StructuralStoreCodec.envelope(ack.envelopeBytes).snapshot
        XCTAssertEqual(snapshot.entries.map(\.entryID),[id(10),id(20)]);XCTAssertEqual(snapshot.configuredEntryID,id(20))
        XCTAssertFalse(String(decoding:ack.envelopeBytes,as:UTF8.self).contains("PRIVATE_TRANSACTION_CANARY"))
        // Select the earlier genuine empty grant while the actual latest maps both packages.
        let old=DeviceRetainedGrantResolutionGroup(reference:.init(identity:.init(rootID:id(2),revisionID:id(3)),operationID:id(4)),expectedOwner:owner,packages:[])
        let resources=try DeviceRetainedResourceResolver(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural).resolveTerminalExact(selected:old.reference,groups:[old,group(f.request)])
        let empty=DeviceLocalCompleteSetRecoveredRequest(structuralRootID:id(5),operationID:id(500),expectedGenerationID:ack.generationID,baseline:.expectedEnvelope(ack.envelopeBytes),snapshot:.init(generationID:id(501),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:nil),packages:[],owner:owner)
        let second=try f.commit.commitRecoveredExact(empty,resources:resources)
        let refs=try JSONDecoder().decode(DeviceLocalCompleteSetReferences.self,from:StructuralStoreCodec.envelope(second.envelopeBytes).intent)
        XCTAssertTrue(refs.packages.isEmpty);XCTAssertEqual(refs.grants.identity,old.reference.identity)
        XCTAssertEqual(resources.packageReceipts.count,2)
    }
    func testSharedSelectedLatestPackagesAndSelectedGrantCoverageCannotBeSubstituted()throws {
        let f=try populated(),oldInput=f.request.grantRequest.input
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(900)),owner:owner,entries:oldInput.entries,credentials:oldInput.credentials,retainedRevisions:[.init(rootID:id(2),revisionID:id(3)),oldInput.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(901),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:f.request.grantRequest.expectedEntries),expectedEntries:f.request.grantRequest.expectedEntries)
        let receipt=try f.grants.prepareExact(request)
        let latest=DeviceRetainedGrantResolutionGroup(reference:.init(identity:receipt.identity,operationID:receipt.operationID),expectedOwner:owner,packages:group(f.request).packages)
        let bundle=try resolve(f,groups:[latest,group(f.request)])
        XCTAssertEqual(bundle.packageReceipts.count,2) // exact shared references across both groups
        let r=recovered(f.request),before=try structuralFiles(f)
        let empty=DeviceLocalCompleteSetRecoveredRequest(structuralRootID:r.structuralRootID,operationID:r.operationID,expectedGenerationID:nil,baseline:r.baseline,snapshot:.init(generationID:r.snapshot.generationID,entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:nil),packages:[],owner:owner)
        XCTAssertThrowsError(try f.commit.commitRecoveredExact(empty,resources:bundle));XCTAssertEqual(try structuralFiles(f),before)
        let ack=try f.commit.commitRecoveredExact(r,resources:bundle)
        let refs=try JSONDecoder().decode(DeviceLocalCompleteSetReferences.self,from:StructuralStoreCodec.envelope(ack.envelopeBytes).intent)
        XCTAssertEqual(refs.packages.count,2);XCTAssertEqual(refs.grants.identity,oldInput.identity)
    }
    func testSameAndOtherInstancePackageMutationRejectBeforeEffects()throws {
        for other in [false,true] {
            let f=try populated(),bundle=try resolve(f),before=try structuralFiles(f)
            let store=other ? DevicePackagePreparationStore(root:f.root.appendingPathComponent("packages"),rootID:id(1),protectedScope:f.scope):f.packages
            if other { _ = try store.resolveRetainedTerminalExact(f.request.packages.map{$0.receipt.reference}) }
            _ = try store.prepareExact(.init(operationID:id(999),package:package(99)))
            XCTAssertThrowsError(try f.commit.commitRecoveredExact(recovered(f.request),resources:bundle));XCTAssertEqual(try structuralFiles(f),before)
        }
    }
    func testExactSelectedReferencesCoverageAndFreshBytesAreMandatory()throws {
        let f=try populated(),bundle=try resolve(f),before=try structuralFiles(f),r=recovered(f.request)
        let a=r.packages[0],bad=DeviceRetainedEntryPackageBinding(entryID:a.entryID,reference:.init(rootID:id(999),contentID:a.reference.contentID,preparationOperationID:a.reference.preparationOperationID,directory:a.reference.directory))
        for bindings in [[a],[a,a],[bad,r.packages[1]]] {
            XCTAssertThrowsError(try f.commit.commitRecoveredExact(.init(structuralRootID:r.structuralRootID,operationID:r.operationID,expectedGenerationID:r.expectedGenerationID,baseline:r.baseline,snapshot:r.snapshot,packages:bindings,owner:r.owner),resources:bundle))
        }
        XCTAssertEqual(try structuralFiles(f),before)
        let file=f.root.appendingPathComponent("packages/"+a.reference.directory+"/index.html")
        try Data("changed".utf8).write(to:file)
        XCTAssertThrowsError(try f.commit.commitRecoveredExact(r,resources:bundle));XCTAssertEqual(try structuralFiles(f),before)
    }
    #endif
}
