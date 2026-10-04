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

final class DeviceLocalCompleteSetRestoreTests: XCTestCase {
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
    private func group(_ r:DeviceLocalCompleteSetRequest)->DeviceRetainedGrantResolutionGroup {
        .init(reference:.init(identity:r.grantReceipt.identity,operationID:r.grantReceipt.operationID),expectedOwner:r.owner,
              packages:r.packages.map{.init(entryID:$0.entryID,reference:$0.receipt.reference)})
    }
    private func gate(_ f:Fixture)->DeviceLocalResourceGate { .init(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural) }
    private func restore(_ f:Fixture)->DeviceLocalCompleteSetRestoreCoordinator { .init(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural) }
    private func files(_ root:URL)throws->[String:Data] {
        let walk=try XCTUnwrap(FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey]));var files:[String:Data]=[:]
        for case let url as URL in walk { if try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true { files[url.path]=try Data(contentsOf:url) } };return files
    }
    private func operationNames(_ f:Fixture)throws->[String] { try FileManager.default.contentsOfDirectory(atPath:f.root.appendingPathComponent("structural/operations").path).sorted() }
    private func resolve(_ f:Fixture)throws->DeviceResolvedRetainedResources {
        try DeviceRetainedResourceResolver(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural).resolveTerminalExact(selected:group(f.request).reference,groups:[group(f.request)])
    }
    private func discover(_ f:Fixture)throws->DeviceStructuralStore.TerminalDiscovery { try gate(f).withReadScope{try $0.inspectLatestStructuralTerminalExact()} }
    func testFreshInstancesRestoreActualEmptyCommittedSetWithoutNewRecordsOrPrivateAdds()throws {
        let f=try fixtureEmpty(),ack=try f.commit.commitPreparedExact(f.request),before=try files(f.root),names=try operationNames(f),adds=f.backend.adds
        let packages=DevicePackagePreparationStore(root:f.root.appendingPathComponent("packages"),rootID:id(1),protectedScope:f.scope)
        let grants=DeviceGrantPreparationStore(root:f.root.appendingPathComponent("grants"),rootID:id(2),protectedScope:f.scope,backend:f.backend)
        let structural=DeviceStructuralStore(root:f.root.appendingPathComponent("structural"),rootID:id(5))
        let restored=try DeviceLocalCompleteSetRestoreCoordinator(packageStore:packages,grantStore:grants,structuralStore:structural).restoreLatestTerminalExact()
        XCTAssertEqual(restored.operationID,ack.operationID);XCTAssertEqual(restored.generationID,ack.generationID);XCTAssertEqual(restored.envelopeBytes,ack.envelopeBytes)
        XCTAssertEqual(try files(f.root),before);XCTAssertEqual(try operationNames(f),names);XCTAssertEqual(f.backend.adds,adds)
        XCTAssertEqual(try StructuralStoreCodec.envelope(restored.envelopeBytes).snapshot.grantSet,"opaque-legacy")
    }
    func testInitializedEmptyIsNotCommittedAndMissingBindingIsNotCreated()throws {
        let f=try fixtureEmpty(),before=try files(f.root)
        XCTAssertThrowsError(try restore(f).restoreLatestTerminalExact());XCTAssertEqual(try files(f.root),before)
        _ = try f.commit.commitPreparedExact(f.request)
        let binding=f.root.appendingPathComponent("structural/root-binding.json");try FileManager.default.removeItem(at:binding)
        XCTAssertThrowsError(try restore(f).restoreLatestTerminalExact());XCTAssertFalse(FileManager.default.fileExists(atPath:binding.path))
    }
    func testPendingAttemptAndOrphanResiduesBlockWithoutImplicitRepairOrDeletion()throws {
        for name in ["orphan","root-binding.json.pending","structural-envelope.json.pending","operations/orphan.json.pending"] {
            let f=try fixtureEmpty();_ = try f.commit.commitPreparedExact(f.request)
            let path=f.root.appendingPathComponent("structural/"+name);try Data("retained orphan".utf8).write(to:path)
            let before=try files(f.root);XCTAssertThrowsError(try restore(f).restoreLatestTerminalExact());XCTAssertEqual(try files(f.root),before)
        }
        let fault=Fault(),f=try fixtureEmpty(fault),first=try f.commit.commitPreparedExact(f.request),new=next(f.request,old:first,n:50)
        fault.target = .afterReplace(.intent);XCTAssertThrowsError(try f.commit.commitPreparedExact(new));let before=try files(f.root)
        XCTAssertThrowsError(try restore(f).restoreLatestTerminalExact());XCTAssertEqual(try files(f.root),before)
        XCTAssertNoThrow(try f.commit.commitPreparedExact(new)) // original exact command remains recoverable
    }
    func testOriginalDiscoveryRejectsSameTipRecommitAndCurrentProofBindingReplacementBeforeEffects()throws {
        for action in ["recommit","current","proof","binding"] {
            let f=try fixtureEmpty();_ = try f.commit.commitPreparedExact(f.request)
            let discovery=try discover(f),candidate=try DeviceLocalCompleteSetRestoreCodec.candidate(discovery.record),resources=try resolve(f)
            if action == "recommit" { _ = try f.structural.recommitExact(operationID:f.request.operationID) }
            else {
                let leaf=action == "current" ? "structural-envelope.json" : action == "binding" ? "root-binding.json" : "operations/"+f.request.operationID.uuidString.lowercased()+".json"
                let url=f.root.appendingPathComponent("structural/"+leaf);try Data(contentsOf:url).write(to:url,options:.atomic)
            }
            let before=try files(f.root)
            XCTAssertThrowsError(try gate(f).commitRecoveredExact(candidate.request,resources:resources,discovery:discovery));XCTAssertEqual(try files(f.root),before)
        }
    }
    func testNewerActualTipBetweenDiscoveryResolutionAndCommitCannotRestoreOlderTip()throws {
        let f=try fixtureEmpty(),first=try f.commit.commitPreparedExact(f.request)
        let discovery=try discover(f),candidate=try DeviceLocalCompleteSetRestoreCodec.candidate(discovery.record),resources=try resolve(f)
        // Same resource bundle remains valid: only the structural tip changes in this phase control.
        let newer=next(f.request,old:first,n:50),second=try f.commit.commitRecoveredExact(.init(structuralRootID:newer.structuralRootID,operationID:newer.operationID,expectedGenerationID:newer.expectedGenerationID,baseline:newer.baseline,snapshot:newer.snapshot,packages:[],owner:owner),resources:resources)
        let before=try files(f.root)
        XCTAssertThrowsError(try gate(f).commitRecoveredExact(candidate.request,resources:resources,discovery:discovery));XCTAssertEqual(try files(f.root),before)
        let restored=try restore(f).restoreLatestTerminalExact();XCTAssertEqual(restored.envelopeBytes,second.envelopeBytes);XCTAssertEqual(restored.operationID,newer.operationID)
    }
    func testUncertainSameTipReplayRequiresExplicitRediscoveryNotOldCheckpoint()throws {
        let fault=Fault(),f=try fixtureEmpty(fault);_ = try f.commit.commitPreparedExact(f.request)
        let discovery=try discover(f),candidate=try DeviceLocalCompleteSetRestoreCodec.candidate(discovery.record),resources=try resolve(f)
        fault.target = .afterReplace(.terminal);XCTAssertThrowsError(try f.structural.recommitExact(operationID:f.request.operationID));XCTAssertTrue(fault.hit)
        let before=try files(f.root);XCTAssertThrowsError(try gate(f).commitRecoveredExact(candidate.request,resources:resources,discovery:discovery));XCTAssertEqual(try files(f.root),before)
        XCTAssertNoThrow(try restore(f).restoreLatestTerminalExact())
    }
    func testMissingUncommittedLatestGrantMappingBlocksAndExplicitMappingRestoresSelected()throws {
        let f=try fixtureEmpty(),ack=try f.commit.commitPreparedExact(f.request)
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(90)),owner:owner,entries:[],credentials:[],retainedRevisions:[f.request.grantReceipt.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(91),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[]),receipt=try f.grants.prepareExact(request)
        let latest=DeviceRetainedGrantResolutionGroup(reference:.init(identity:receipt.identity,operationID:receipt.operationID),expectedOwner:owner,packages:[]),before=try files(f.root),adds=f.backend.adds
        XCTAssertThrowsError(try restore(f).restoreLatestTerminalExact());XCTAssertEqual(try files(f.root),before)
        let restored=try restore(f).restoreLatestTerminalExact(latestGroup:latest)
        XCTAssertEqual(restored.envelopeBytes,ack.envelopeBytes);XCTAssertEqual(try operationNames(f),[f.request.operationID.uuidString.lowercased()+".json"]);XCTAssertEqual(f.backend.adds,adds)
        XCTAssertThrowsError(try restore(f).restoreLatestTerminalExact(latestGroup:group(f.request))) // redundant selected mapping is not latest evidence
    }
    func testStrictReferencesRejectMalformedDuplicateUnknownNestedAndNoncanonicalCandidate()throws {
        let f=try fixtureEmpty();_ = try f.commit.commitPreparedExact(f.request)
        let record=try discover(f).record,envelope=try StructuralStoreCodec.envelope(record.candidate),text=String(decoding:envelope.intent,as:UTF8.self)
        for bytes in [Data([0xff]),Data("{} trailing".utf8),Data(repeating:32,count:32*1024+1),Data(text.replacingOccurrences(of:"\"schemaVersion\":1",with:"\"schemaVersion\":1,\"\\u0073chemaVersion\":1").utf8),Data(text.replacingOccurrences(of:"\"revisionID\":",with:"\"unknown\":1,\"revisionID\":").utf8)] {
            XCTAssertThrowsError(try DeviceLocalCompleteSetRestoreCodec.references(bytes))
        }
        let alternate=Data(text.replacingOccurrences(of:"\"schemaVersion\":1",with:"\"schemaVersion\":1.0").utf8)
        XCTAssertNoThrow(try DeviceLocalCompleteSetRestoreCodec.references(alternate))
        let changed=DeviceStructuralCommitEnvelope(operationID:envelope.operationID,expectedGenerationID:envelope.expectedGenerationID,snapshot:envelope.snapshot,intent:alternate,outcome:alternate)
        let bad=DeviceStructuralOperationRecord(rootID:record.rootID,operationID:record.operationID,expectedOld:record.expectedOld,candidate:try DeviceLocalCompleteSetBounds.encode(changed,maximum:128*1024),resourceAssertions:Data(),phase:.terminal,baselineIdentity:record.baselineIdentity,candidateIdentity:record.candidateIdentity)
        XCTAssertThrowsError(try DeviceLocalCompleteSetRestoreCodec.candidate(bad))
        let unequal=DeviceStructuralCommitEnvelope(operationID:envelope.operationID,expectedGenerationID:envelope.expectedGenerationID,snapshot:envelope.snapshot,intent:envelope.intent,outcome:Data("{}".utf8))
        let mismatch=DeviceStructuralOperationRecord(rootID:record.rootID,operationID:record.operationID,expectedOld:record.expectedOld,candidate:try DeviceLocalCompleteSetBounds.encode(unequal,maximum:128*1024),resourceAssertions:Data(),phase:.terminal,baselineIdentity:record.baselineIdentity,candidateIdentity:record.candidateIdentity)
        XCTAssertThrowsError(try DeviceLocalCompleteSetRestoreCodec.candidate(mismatch))
    }
    func testReadScopeCannotDispatchRestoreAndBackendReentryRejects()throws {
        let f=try fixtureEmpty();_ = try f.commit.commitPreparedExact(f.request)
        try gate(f).withReadScope{_ in XCTAssertThrowsError(try restore(f).restoreLatestTerminalExact())}
        var reads=0;f.backend.onRead={reads += 1;XCTAssertThrowsError(try self.restore(f).restoreLatestTerminalExact())}
        XCTAssertNoThrow(try restore(f).restoreLatestTerminalExact());XCTAssertGreaterThan(reads,0)
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
    func testFreshNonemptyRestorePreservesOrderedEntriesSelectionNamesAndExcludesSecrets()throws {
        let f=try populated(),ack=try f.commit.commitPreparedExact(f.request)
        let packages=DevicePackagePreparationStore(root:f.root.appendingPathComponent("packages"),rootID:id(1),protectedScope:f.scope),grants=DeviceGrantPreparationStore(root:f.root.appendingPathComponent("grants"),rootID:id(2),protectedScope:f.scope,backend:f.backend),structural=DeviceStructuralStore(root:f.root.appendingPathComponent("structural"),rootID:id(5))
        let restored=try DeviceLocalCompleteSetRestoreCoordinator(packageStore:packages,grantStore:grants,structuralStore:structural).restoreLatestTerminalExact()
        XCTAssertEqual(restored.envelopeBytes,ack.envelopeBytes)
        let snapshot=try StructuralStoreCodec.envelope(restored.envelopeBytes).snapshot
        XCTAssertEqual(snapshot.entries.map(\.entryID),[id(10),id(20)]);XCTAssertEqual(snapshot.entries.map(\.displayName),["Household 10","Household 20"]);XCTAssertEqual(snapshot.configuredEntryID,id(20))
        XCTAssertFalse(String(describing:restored).contains("PRIVATE_TRANSACTION_CANARY"));XCTAssertFalse(String(decoding:restored.envelopeBytes,as:UTF8.self).contains("PRIVATE_TRANSACTION_CANARY"))
    }
    func testStrictNestedPackageFieldsAndRevisionMismatchReject()throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let record=try discover(f).record,envelope=try StructuralStoreCodec.envelope(record.candidate),text=String(decoding:envelope.intent,as:UTF8.self)
        for changed in [text.replacingOccurrences(of:"\"contentID\":",with:"\"extra\":1,\"contentID\":"),text.replacingOccurrences(of:"\"directory\":",with:"\"directory\":\"duplicate\",\"\\u0064irectory\":")] {
            XCTAssertThrowsError(try DeviceLocalCompleteSetRestoreCodec.references(Data(changed.utf8)))
        }
    }
    #endif
}
