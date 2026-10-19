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

final class DeviceBoundGrantAttemptTests:XCTestCase {
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
        let url=URL(fileURLWithPath:String(cString:p)).appendingPathComponent("bound-grant-"+UUID().uuidString)
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
    func testEmptyPrivateAttemptDoesNotCompleteOrAdvanceHeadAndV1CannotFinish()throws {
        let jr=try directory(),gr=try directory(),backend=Backend(),j=journal(jr),g=grantStore(gr,backend),r=try request(),plan=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(plan),before=try files(jr)
        let command=DeviceBoundGrantAttemptCoordinator(journal:j,grants:g)
        _ = try command.stageExact(r,plan:plan,journalReceipt:receipt)
        XCTAssertEqual(backend.adds,1);XCTAssertEqual(try files(jr),before)
        XCTAssertNil(try? Data(contentsOf:gr.appendingPathComponent("head.json")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:gr.appendingPathComponent("operations").path),[id(6).uuidString.lowercased()+".json"])
        let state=try files(gr);XCTAssertThrowsError(try g.recommitExact(v1(r)));XCTAssertEqual(try files(gr),state)
        XCTAssertThrowsError(try g.prepareExact(v1(r)));XCTAssertEqual(backend.adds,1)
        let recovered=try g.recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:[])
        let repairedJournal=try j.recommitExact(recovered.plan)
        _ = try command.recommitRecoveredExact(recovered,journalReceipt:repairedJournal)
        XCTAssertEqual(backend.adds,1)
        XCTAssertEqual(Mirror(reflecting:recovered).children.count,0)
    }
    func testRecordedReferenceRestartRecoveryAndMissingReferenceRefusal()throws {
        let jr=try directory(),gr=try directory(),backend=Backend(),j=journal(jr),g=grantStore(gr,backend),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();_ = try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:p,journalReceipt:j.stageExact(p))
        let restarted=grantStore(gr,backend),newJournal=journal(jr),recovery=try restarted.recoverBoundPrivateAttempt(XCTUnwrap(newJournal.inspectPendingExact()),packages:[])
        _ = try DeviceBoundGrantAttemptCoordinator(journal:newJournal,grants:restarted).recommitRecoveredExact(recovery,journalReceipt:newJournal.recommitExact(recovery.plan))
        let item=try XCTUnwrap(backend.values.removeValue(forKey:GrantPreparationCodec.attemptAccount(id(6))))
        XCTAssertThrowsError(try grantStore(gr,backend).recoverBoundPrivateAttempt(XCTUnwrap(newJournal.inspectPendingExact()),packages:[]))
        backend.values[item.item.account]=item
    }
    func testCapturedRecoveryEpochCannotRefreshAfterSameInstanceRetry()throws {
        let jr=try directory(),gr=try directory(),backend=Backend(),j=journal(jr),g=grantStore(gr,backend),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p),command=DeviceBoundGrantAttemptCoordinator(journal:j,grants:g)
        _ = try command.stageExact(r,plan:p,journalReceipt:receipt)
        let recovery=try g.recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:[])
        _ = try command.stageExact(r,plan:p,journalReceipt:receipt)
        let before=try files(gr)
        XCTAssertThrowsError(try command.recommitRecoveredExact(recovery,journalReceipt:receipt));XCTAssertEqual(try files(gr),before)
    }
    func testJournalEpochAndSameBytesReplacementRejectBeforeGrantEffects()throws {
        for replace in [false,true] {
            let jr=try directory(),gr=try directory(),backend=Backend(),j=journal(jr),g=grantStore(gr,backend),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
            try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p),before=try files(gr)
            if replace {let path=jr.appendingPathComponent("head.json"),temp=path.appendingPathExtension("replacement");try Data(contentsOf:path).write(to:temp);try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:temp,to:path)}else{_ = try j.recommitExact(p)}
            XCTAssertThrowsError(try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:p,journalReceipt:receipt));XCTAssertEqual(try files(gr),before);XCTAssertEqual(backend.adds,0)
        }
    }
    func testPrivateAddUncertainOriginalLiveRepairOnlyAndChangedIntentRefusal()throws {
        let jr=try directory(),gr=try directory(),backend=Backend(),j=journal(jr);var fail=true
        let g=grantStore(gr,backend,boundary:{if case .afterPrivateAdd = $0,fail{fail=false;throw Injected.fault}}),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p),command=DeviceBoundGrantAttemptCoordinator(journal:j,grants:g)
        XCTAssertThrowsError(try command.stageExact(r,plan:p,journalReceipt:receipt));XCTAssertEqual(backend.adds,1)
        XCTAssertThrowsError(try grantStore(gr,backend).recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:[]))
        let before=try files(gr);XCTAssertThrowsError(try command.stageExact(request(generation:8),plan:p,journalReceipt:receipt));XCTAssertEqual(try files(gr),before)
        XCTAssertThrowsError(try g.recommitExact(v1(r)));_ = try command.stageExact(r,plan:p,journalReceipt:receipt);XCTAssertEqual(backend.adds,1)
    }
    func testIntentAndProgressFaultMatrixExactRetry()throws {
        for kind in [DeviceGrantPreparationStore.Kind.intent,.progress] {
            for point in [DeviceGrantPreparationStore.Boundary.afterWrite(kind),.afterFileSync(kind),.beforeReplace(kind),.afterReplace(kind),.afterDirectorySync(kind)] {
                let jr=try directory(),gr=try directory(),backend=Backend(),j=journal(jr);var target:DeviceGrantPreparationStore.Boundary?=point
                let g=grantStore(gr,backend,boundary:{if target == $0{target=nil;throw Injected.fault}}),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
                try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p),command=DeviceBoundGrantAttemptCoordinator(journal:j,grants:g)
                XCTAssertThrowsError(try command.stageExact(r,plan:p,journalReceipt:receipt),String(describing:point));XCTAssertNil(target)
                _ = try command.stageExact(r,plan:p,journalReceipt:receipt)
                XCTAssertEqual(backend.adds,1);XCTAssertFalse(try files(gr).keys.contains(where:{$0.contains("terminal") || $0.contains("head")}))
            }
        }
    }
    func testStrictV2UnionAndExactV1EncodingCompatibility()throws {
        let r=try request(),p=try DeviceProvisioningPlanner.qualify(r),old=try GrantPreparationCodec.attempt(v1(r),rootID:id(4)),v2=try DeviceProvisioningPrivateAttemptV2.encoded(v1(r),intent:p.canonicalBytes)
        XCTAssertEqual(try GrantPreparationCodec.decodeStoredAttempt(old).version,1)
        XCTAssertEqual(try GrantPreparationCodec.decodeStoredAttempt(v2).version,2)
        XCTAssertThrowsError(try GrantPreparationCodec.decodeAttempt(v2))
        let text=String(decoding:v2,as:UTF8.self)
        for prefix in ["{\"unknown\":1,","{\"schemaVersion\":2,"]{XCTAssertThrowsError(try GrantPreparationCodec.decodeStoredAttempt(Data((prefix+text.dropFirst()).utf8)))}
        XCTAssertThrowsError(try GrantPreparationCodec.decodeStoredAttempt(Data(repeating:32,count:GrantPreparationCodec.intentLimit+1)))
        XCTAssertThrowsError(try GrantPreparationCodec.decodeStoredAttempt(Data((text+"x").utf8)))
        XCTAssertThrowsError(try GrantPreparationCodec.decodeStoredAttempt(Data(text.replacingOccurrences(of:"\"input\":{",with:"\"input\":{\"schemaVersion\":1,").utf8)))
        XCTAssertThrowsError(try GrantPreparationCodec.decodeStoredAttempt(Data(text.replacingOccurrences(of:"\"input\":{",with:"\"input\":{\"\\u0073chemaVersion\":1,").utf8)))
    }
    func testBackendAndFaultNestedEntriesFailPromptlyAndCleanup()throws {
        let jr=try directory(),gr=try directory(),backend=Backend(),j=journal(jr);var hook=false
        let g=grantStore(gr,backend,boundary:{_ in if hook{hook=false;XCTAssertThrowsError(try j.inspectPendingExact())}}),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p);hook=true
        _ = try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:p,journalReceipt:receipt)
        XCTAssertFalse(hook);XCTAssertNoThrow(try j.verify(receipt))
    }
    func testUninitializedRootsDoNotCreateFiles()throws {
        let jr=try directory(),gr=try directory(),backend=Backend(),j=journal(jr),g=grantStore(gr,backend),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();let receipt=try j.stageExact(p)
        XCTAssertThrowsError(try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:p,journalReceipt:receipt));XCTAssertTrue(try files(gr).isEmpty);XCTAssertEqual(backend.adds,0)
    }
    #if canImport(CryptoKit)
    private func nonempty(_ secret:Data=Data("PRIVATE_CANARY_001".utf8),count:Int=1)throws->DeviceProvisioningPlanRequest {
        func hash(_ d:Data)->String{SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()}
        var packages:[DeviceProvisioningPackageInput]=[],entries:[DeviceGrantEntryInput]=[],installed:[DeviceStructuralEntry]=[],expectations:[DeviceGrantEntryExpectation]=[]
        for n in 0..<count {
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
    func testNonemptySharedCredentialsStayPrivateAndNeverAddedIndividually()throws {
        let r=try nonempty(count:2),p=try DeviceProvisioningPlanner.qualify(r),jr=try directory(),gr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b)
        try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p)
        _ = try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:p,journalReceipt:receipt)
        XCTAssertEqual(b.adds,1);XCTAssertFalse(b.values.keys.contains(where:{$0.hasPrefix("credential.")}))
        let secret=r.grantInput.credentials[0].bytes
        for data in try files(gr).values{let text=String(decoding:data,as:UTF8.self);XCTAssertFalse(text.contains(String(decoding:secret,as:UTF8.self)));XCTAssertFalse(text.contains(secret.base64EncodedString()))}
        let recovered=try grantStore(gr,b).recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:r.packages)
        XCTAssertEqual(recovered.plan.canonicalBytes,p.canonicalBytes)
        XCTAssertThrowsError(try grantStore(gr,b).recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:[]))
    }
    func testSameLengthSecretChangeWithEqualPublicPlanRejectedBeforeEpochAndEffects()throws {
        let r=try nonempty(),changed=try nonempty(Data("PRIVATE_CANARY_002".utf8)),p=try DeviceProvisioningPlanner.qualify(r)
        XCTAssertEqual(r.qualifiedGrant.publicMetadataBytes,changed.qualifiedGrant.publicMetadataBytes)
        XCTAssertEqual(p.canonicalBytes,try DeviceProvisioningPlanner.qualify(changed).canonicalBytes)
        let jr=try directory(),gr=try directory(),b=Backend(),j=journal(jr);var fail=true
        let g=grantStore(gr,b,boundary:{if $0 == .afterReplace(.intent),fail{fail=false;throw Injected.fault}})
        try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p),command=DeviceBoundGrantAttemptCoordinator(journal:j,grants:g)
        XCTAssertThrowsError(try command.stageExact(r,plan:p,journalReceipt:receipt));let before=try files(gr)
        XCTAssertThrowsError(try command.stageExact(changed,plan:p,journalReceipt:receipt));XCTAssertEqual(try files(gr),before);XCTAssertEqual(b.adds,0)
        _ = try command.stageExact(r,plan:p,journalReceipt:receipt);XCTAssertEqual(b.adds,1)
        let recovery=try g.recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:r.packages)
        XCTAssertThrowsError(try command.stageExact(changed,plan:p,journalReceipt:receipt))
        _ = try command.recommitRecoveredExact(recovery,journalReceipt:receipt) // rejected change did not invalidate original checkpoint.
    }
    #endif
    func testMixedV1TerminalHistoryPreservedAndSecondIntentCannotReplacePending()throws {
        let jr=try directory(),gr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),r=try request()
        try j.initializeExplicit();try g.initializeExplicit()
        let oldInput=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(50)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        let old=DeviceGrantPreparationRequest(operationID:id(51),input:oldInput,qualified:try DeviceGrantRevisionQualifier.qualify(oldInput,expectedEntries:[]),expectedEntries:[])
        let terminal=try g.prepareExact(old),history=try files(gr),p=try DeviceProvisioningPlanner.qualify(r),receipt=try j.stageExact(p)
        _ = try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:p,journalReceipt:receipt)
        for (key,data) in history{XCTAssertEqual(try files(gr)[key],data)}
        XCTAssertThrowsError(try g.verify(terminal)) // pending newest does not qualify old history for runtime.
        let changed=try request(revision:55),different=try DeviceProvisioningPlanner.qualify(changed),before=try files(gr)
        XCTAssertThrowsError(try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(changed,plan:different,journalReceipt:receipt));XCTAssertEqual(try files(gr),before)
        let recovery=try grantStore(gr,b).recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:[])
        XCTAssertEqual(recovery.plan.canonicalBytes,p.canonicalBytes)
    }

    func testRecordedStagedProgressRestartRepairsOnlyOriginalCapturedCheckpoint()throws {
        let jr=try directory(),gr=try directory(),b=Backend(),j=journal(jr);var fail=true
        let g=grantStore(gr,b,boundary:{if $0 == .afterFileSync(.progress),fail{fail=false;throw Injected.fault}}),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p)
        XCTAssertThrowsError(try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:p,journalReceipt:receipt))
        XCTAssertEqual(b.adds,1)
        let restarted=grantStore(gr,b),recovered=try restarted.recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:[])
        _ = try DeviceBoundGrantAttemptCoordinator(journal:j,grants:restarted).recommitRecoveredExact(recovered,journalReceipt:j.recommitExact(recovered.plan))
        XCTAssertEqual(b.adds,1);XCTAssertFalse(try files(gr).keys.contains(where:{$0.hasSuffix("pending") || $0.contains("terminal")}))
    }
    func testRecoveryRecordReplacementRejectsCapturedCheckpointAndPreservesEvidence()throws {
        let jr=try directory(),gr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p),command=DeviceBoundGrantAttemptCoordinator(journal:j,grants:g)
        _ = try command.stageExact(r,plan:p,journalReceipt:receipt)
        let recovery=try g.recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:[])
        let path=gr.appendingPathComponent("operations/"+id(6).uuidString.lowercased()+".json"),temp=path.appendingPathExtension("external")
        try Data(contentsOf:path).write(to:temp);try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:temp,to:path)
        let before=try files(gr)
        XCTAssertThrowsError(try command.recommitRecoveredExact(recovery,journalReceipt:receipt));XCTAssertEqual(try files(gr),before);XCTAssertEqual(b.adds,1)
    }
    func testTerminalCapacityReservationBeforePrivateOrJournalEffects()throws {
        let jr=try directory(),gr=try directory(),b=Backend(),j=journal(jr),g=grantStore(gr,b)
        try j.initializeExplicit();try g.initializeExplicit()
        for n in 0..<128 {
            let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(2000+n)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
            _ = try g.prepareExact(.init(operationID:id(1000+n),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[]))
        }
        let r=try request(),p=try DeviceProvisioningPlanner.qualify(r),receipt=try j.stageExact(p),before=try files(gr),journalBefore=try files(jr)
        XCTAssertThrowsError(try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:p,journalReceipt:receipt))
        XCTAssertEqual(b.adds,128);XCTAssertEqual(try files(gr),before);XCTAssertEqual(try files(jr),journalBefore)
    }

    func testLiveAndReconstructedBindingSyncFailureIssuesNoAcknowledgmentAndExplicitRetry()throws {
        for reconstruct in [false,true] {
            let jr=try directory(),gr=try directory(),b=Backend(),j=journal(jr);var target:DeviceGrantPreparationStore.Boundary?,hit=false
            let initial=grantStore(gr,b,boundary:{if target == $0{target=nil;hit=true;throw Injected.fault}}),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
            try j.initializeExplicit();try initial.initializeExplicit();let journalReceipt=try j.stageExact(p)
            let active:DeviceGrantPreparationStore,recovery:DeviceBoundGrantRecoveryPlan?
            if reconstruct {
                _ = try DeviceBoundGrantAttemptCoordinator(journal:j,grants:initial).stageExact(r,plan:p,journalReceipt:journalReceipt)
                active=grantStore(gr,b,boundary:{if target == $0{target=nil;hit=true;throw Injected.fault}})
                recovery=try active.recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:[])
            } else {active=initial;recovery=nil}
            let receipt=try j.recommitExact(p),command=DeviceBoundGrantAttemptCoordinator(journal:j,grants:active)
            target = .afterFileSync(.binding)
            if let recovery {XCTAssertThrowsError(try command.recommitRecoveredExact(recovery,journalReceipt:receipt))}
            else{XCTAssertThrowsError(try command.stageExact(r,plan:p,journalReceipt:receipt))}
            XCTAssertTrue(hit,"binding sync must be reached before private acknowledgment; reconstructed=\(reconstruct)")
            if let recovery {XCTAssertThrowsError(try command.recommitRecoveredExact(recovery,journalReceipt:receipt))} // original epoch is not silently renewed.
            let fresh=try active.recoverBoundPrivateAttempt(XCTUnwrap(j.inspectPendingExact()),packages:[])
            _ = try command.recommitRecoveredExact(fresh,journalReceipt:j.recommitExact(fresh.plan))
            XCTAssertEqual(b.adds,1)
        }
    }

    func testOriginalBindingReplacementDuringSyncCannotIssuePrivateAcknowledgment()throws {
        let jr=try directory(),gr=try directory(),b=Backend(),j=journal(jr);var replace=false
        let g=grantStore(gr,b,boundary:{if $0 == .afterFileSync(.binding),replace {
            replace=false
            let path=gr.appendingPathComponent("root-binding.json"),temp=path.appendingPathExtension("external")
            try Data(contentsOf:path).write(to:temp);try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:temp,to:path)
        }}),r=try request(),p=try DeviceProvisioningPlanner.qualify(r)
        try j.initializeExplicit();try g.initializeExplicit();let receipt=try j.stageExact(p);replace=true
        XCTAssertThrowsError(try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(r,plan:p,journalReceipt:receipt))
        XCTAssertFalse(replace);XCTAssertEqual(b.adds,1);XCTAssertFalse(try files(gr).keys.contains(where:{$0.contains("head") || $0.contains("terminal")}))
    }

}
