import Foundation
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

final class DeviceNativeProvisioningIntentTests:XCTestCase {
    private enum Fault:Error {case injected}
    private final class Probe {
        var journal:DeviceLocalProvisioningIntentStore.Boundary?,structural:DeviceStructuralStore.Boundary?
        var events=0
        var journalAction:((DeviceLocalProvisioningIntentStore.Boundary)throws->Void)?
        func hit(_ site:DeviceLocalProvisioningIntentStore.Boundary)throws {events+=1;try journalAction?(site);if journal == site{journal=nil;throw Fault.injected}}
        func hit(_ site:DeviceStructuralStore.Boundary)throws {events+=1;if structural == site{structural=nil;throw Fault.injected}}
    }
    private func root()throws->URL {
        guard let physical=realpath(FileManager.default.temporaryDirectory.path,nil) else{throw Fault.injected};defer{free(physical)}
        let r=URL(fileURLWithPath:String(cString:physical)).appendingPathComponent("native-provisioning-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:r,withIntermediateDirectories:false)
        addTeardownBlock{try FileManager.default.removeItem(at:r)};return r
    }
    private func encode<T:Encodable>(_ item:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(item)}
    private func empty(_ owner:DeviceNativeInstallationContentOwner,generation:UUID=UUID())throws->DeviceNativeStructuralState {
        try .validating(generationID:generation,owner:.nativeInstallation(owner),entries:[],configuredEntryID:nil)
    }
    private var owner:DeviceNativeInstallationContentOwner {.init(installationID:UUID(),accountID:UUID(),locationID:UUID(),transitionID:UUID())}
    private func snapshot(_ r:URL)throws->[String:Data] {
        var result:[String:Data]=[:]
        for u in try FileManager.default.contentsOfDirectory(at:r,includingPropertiesForKeys:[.isRegularFileKey]) where try u.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {result[u.lastPathComponent]=try Data(contentsOf:u)}
        return result
    }
    #if canImport(CryptoKit)
    private func package(generic:Bool)throws->QualifiedDevicePackage {
        let html=Data("<html>native fixture</html>".utf8),dashboard=UUID(),revision=UUID()
        func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:dashboard.uuidString.lowercased(),name:"Explicit native fixture",revision:revision.uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:generic ? [.init(alias:"api",required:false,operations:[.init(name:"read",kind:"http")])]:[],files:[.init(path:"index.html",bytes:html.count,sha256:hash(html))])
        manifest.digest=hash(try encode(manifest))
        let stored=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        return try DevicePackageQualifier.qualify(.init(manifest:encode(manifest),files:[.init(path:"index.html",bytes:html)]),expected:.init(revision:stored,target:.init(deviceId:"fixture",name:"Fixture"),profileID:"profile"))
    }
    private struct Fixture {
        let journalRoot:URL,structuralRoot:URL,roots:DeviceProvisioningRoots
        let journal:DeviceLocalProvisioningIntentStore,structural:DeviceStructuralStore,probe:Probe
        let request:DeviceNativeProvisioningRequest,plan:DeviceValidatedNativeProvisioningPlan
        let attachment:DeviceLocalProvisioningIntentStore.DeliveryAttachmentReceipt
        var coordinator:DeviceNativeProvisioningCoordinator {.init(journal:journal,structural:structural)}
    }
    private func fixture(count:Int=1,generic:Bool=false)throws->Fixture {
        let j=try root(),s=try root(),roots=DeviceProvisioningRoots(journalID:UUID(),structuralID:UUID(),packageID:UUID(),grantID:UUID()),probe=Probe()
        let journal=DeviceLocalProvisioningIntentStore(root:j,rootID:roots.journalID,protectedRoots:[s],boundary:{try probe.hit($0)})
        let structural=DeviceStructuralStore(root:s,rootID:roots.structuralID,boundary:{try probe.hit($0)})
        try journal.initializeExplicit();try structural.initializeExplicit()
        let who=owner,initial=try empty(who),baseline=try structural.initializeNativeGenesisExplicit(initial),desired=UUID(),nativeOperation=UUID(),grantOperation=UUID()
        var entries:[DeviceNativeStructuralEntry]=[],inputs:[DeviceProvisioningPackageInput]=[],grantEntries:[DeviceGrantEntryInput]=[],expectations:[DeviceGrantEntryExpectation]=[]
        let secret=Data("NATIVE_PRIVATE_SECRET_CANARY".utf8),credential=UUID()
        for _ in 0..<count {
            let package=try package(generic:generic),entryID=UUID(),op=UUID()
            let reference=try PackagePreparationCodec.expectedReference(.init(operationID:op,package:package),rootID:roots.packageID)
            let descriptor=try DeviceDeliveryPackageCandidate.validating(packageProfile:DeviceDeliveryPackageCandidate.profile,publicationID:UUID(),projectID:UUID(),packageID:UUID(),dashboardID:UUID(uuidString:package.revision.dashboardId)!,revision:UUID(uuidString:package.revision.revision)!,manifestDigest:.validating(package.revision.digest),manifestSHA256:.validating(package.manifestSHA256),archiveSHA256:.validating(String(repeating:"d",count:64)),compressedBytes:10,expandedBytes:100,archiveEntries:2)
            entries.append(try .validating(entryID:entryID,displayName:"Explicit household name",package:descriptor,preparedPackage:reference))
            inputs.append(.supplied(entryID:entryID,operationID:op,package:package));expectations.append(.init(entryID:entryID,package:package))
            var provisioning:ConnectionProvisioning?,refs:[DeviceGrantCredentialReference]=[]
            if generic {
                let grant=ConnectionGrant(schemaVersion:1,id:UUID(),alias:"api",origin:"https://example.com",transport:.http,authRef:"shared-ref",lan:false,allowInsecureHTTP:false,operations:[.init(name:"read",kind:.http,method:.GET,path:"/data",idempotent:true,write:false)])
                provisioning = .init(dashboardId:package.revision.dashboardId,revision:package.revision.revision,provisioningId:"explicit-provisioning",entries:[.init(grant:grant,binding:.init(authRef:"shared-ref",placement:.bearer),secret:secret)])
                refs=[.init(credentialRevisionID:credential,kind:.generic,key:"shared-ref")]
            }
            grantEntries.append(.init(entryID:entryID,revision:package.revision,generic:provisioning,homeAssistant:nil,publicReads:nil,credentialReferences:refs))
        }
        let selected=entries.first!.entryID,candidate=try DeviceNativeStructuralState.validating(generationID:desired,owner:.nativeInstallation(who),entries:entries,configuredEntryID:selected)
        let set=try DeviceResultingSetCandidate.validating(entries:entries.map{.validating(entryID:$0.entryID,provenance:.cloud($0.package))},configuredEntryID:selected)
        let rawPlan=Data("exact raw native plan fixture".utf8)
        let association:[String:Any]=["schemaVersion":1,"operationId":UUID().uuidString.lowercased(),"planId":UUID().uuidString.lowercased(),"installationId":who.installationID.uuidString.lowercased(),"accountId":who.accountID.uuidString.lowercased(),"locationId":who.locationID.map { $0.uuidString.lowercased() } as Any? ?? NSNull(),"transitionId":who.transitionID.uuidString.lowercased(),"planDigest":try DeviceNativeDeliveryAttachmentCodec.hash(rawPlan),"planByteLength":rawPlan.count]
        var command=association;command["sequence"]="1";command["expectedInstalledSetGenerationId"]=initial.generationID.uuidString.lowercased();command["desiredSetGenerationId"]=desired.uuidString.lowercased();command["executionExpiresAt"]="2026-10-04T12:00:00Z";command["resultingSetDigest"]=try DeviceDeliveryCandidateCodec.resultingSetDigest(set)
        let wire=entries.map{e->[String:Any] in let p=e.package;return ["entryId":e.entryID.uuidString.lowercased(),"provenance":["kind":"cloud","package":["packageProfile":DeviceDeliveryPackageCandidate.profile,"publicationId":p.publicationID.uuidString.lowercased(),"projectId":p.projectID.uuidString.lowercased(),"packageId":p.packageID.uuidString.lowercased(),"dashboardId":p.dashboardID.uuidString.lowercased(),"revision":p.revision.uuidString.lowercased(),"manifestDigest":p.manifestDigest.text,"manifestSha256":p.manifestSHA256.text,"archiveSha256":p.archiveSHA256.text,"compressedBytes":p.compressedBytes,"expandedBytes":p.expandedBytes,"archiveEntries":p.archiveEntries]]]}
        command["resultingSet"]=["schemaVersion":1,"entries":wire,"configuredEntryId":selected.uuidString.lowercased()]
        let header=try JSONSerialization.data(withJSONObject:association).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let delivery=try DeviceNativeDeliveryCommandBinding.bind(command:JSONSerialization.data(withJSONObject:command),associationHeader:header,rawPlan:rawPlan,nativeOperationID:nativeOperation,journalRootID:roots.journalID)
        let input=DeviceNativeGrantRevisionInput(schemaVersion:2,identity:.init(rootID:roots.grantID,revisionID:UUID()),owner:who,entries:grantEntries,credentials:generic ? [.init(revisionID:credential,bytes:secret)]:[],retainedRevisions:[])
        let qualified=try DeviceNativeGrantRevisionQualifier.qualify(input,expectedEntries:expectations)
        let request=DeviceNativeProvisioningRequest(roots:roots,delivery:delivery,grantOperationID:grantOperation,baseline:baseline,candidate:candidate,packages:inputs,grantInput:input,qualifiedGrant:qualified)
        let plan=try DeviceNativeProvisioningPlanner.qualify(request),attachment=try journal.publishDeliveryAttachmentExact(delivery)
        return .init(journalRoot:j,structuralRoot:s,roots:roots,journal:journal,structural:structural,probe:probe,request:request,plan:plan,attachment:attachment)
    }
    func testExplicitEmptyGenesisIsNotAbsenceOrDeliveryAcknowledgment()throws {
        let r=try root(),store=DeviceStructuralStore(root:r,rootID:UUID()),state=try empty(owner)
        XCTAssertThrowsError(try store.initializeNativeGenesisExplicit(state))
        try store.initializeExplicit();let checkpoint=try store.initializeNativeGenesisExplicit(state)
        XCTAssertEqual(checkpoint.state,state);XCTAssertEqual(checkpoint.stateBytes,try DeviceNativeStructuralStateCodec.encode(state))
        XCTAssertFalse(FileManager.default.fileExists(atPath:r.appendingPathComponent("structural-envelope.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:r.appendingPathComponent("operations").path),[])
        XCTAssertThrowsError(try store.initializeExplicit())
    }
    func testGenuineNativePlanJoinsExactlyOneAttachmentWithoutExternalEffects()throws {
        let f=try fixture(),original=try snapshot(f.journalRoot),structural=try snapshot(f.structuralRoot)
        let receipt=try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment)
        try f.coordinator.verifyExact(receipt,plan:f.plan,baseline:f.request.baseline)
        for name in ["delivery.intent","delivery.binding","delivery.command","delivery.plan","delivery.confirm","head.json"] {XCTAssertEqual(try Data(contentsOf:f.journalRoot.appendingPathComponent(name)),original[name])}
        XCTAssertEqual(try snapshot(f.structuralRoot),structural)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.journalRoot.appendingPathComponent("operations").path),[])
        XCTAssertThrowsError(try f.journal.inspectPendingExact());XCTAssertThrowsError(try f.journal.recommitDeliveryAttachmentExact(f.request.delivery))
    }
    func testFixedNativeScopeEntersCurrentReservedAttachmentWhileLegacyScopeBlocks()throws {
        let f=try fixture()
        try f.journal.verifyDeliveryAttachmentExact(f.attachment)
        XCTAssertThrowsError(try f.journal.inspectPendingExact())
        let receipt=try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment)
        try f.coordinator.verifyExact(receipt,plan:f.plan,baseline:f.request.baseline)
        XCTAssertThrowsError(try f.journal.inspectLatestRetainedIntentExact())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.journalRoot.appendingPathComponent("operations").path),[])
    }
    func testMalformedPartialAndUnknownJoinPrefixesBlockBeforeEffects()throws {
        for (name,bytes) in [("native-join.intent",Data("{malformed".utf8)),("native-join.intent.stage",Data()),("native-join.binding.stage",Data()),("native-join.unknown",Data())] {
            let f=try fixture();try bytes.write(to:f.journalRoot.appendingPathComponent(name))
            let before=try snapshot(f.journalRoot),events=f.probe.events
            XCTAssertThrowsError(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment))
            XCTAssertEqual(before,try snapshot(f.journalRoot));XCTAssertEqual(events,f.probe.events)
        }
    }
    func testGenuineSharedNativePrivateInputIsSizedButNeverPersisted()throws {
        let f=try fixture(count:2,generic:true),body=try DeviceNativeProvisioningIntentCodec.decode(f.plan.intentBytes)
        XCTAssertEqual(body.packages.count,2);XCTAssertLessThanOrEqual(body.privateAttemptByteCount,4*1024*1024)
        _ = try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment)
        for data in try snapshot(f.journalRoot).values {
            let secret=Data("NATIVE_PRIVATE_SECRET_CANARY".utf8)
            XCTAssertNil(data.range(of:secret));XCTAssertNil(data.range(of:Data(secret.base64EncodedString().utf8)))
        }
    }
    func testNativeCandidateAndIntentStrictUnknownDuplicateAndMalformedControls()throws {
        let f=try fixture();let text=String(decoding:f.plan.intentBytes,as:UTF8.self)
        for bytes in [Data((text+"{}").utf8),Data(text.replacingOccurrences(of:"\"schemaVersion\":2",with:"\"schemaVersion\":2,\"schema\\u0056ersion\":2").utf8),Data(repeating:32,count:32769)] {XCTAssertThrowsError(try DeviceNativeProvisioningIntentCodec.decode(bytes))}
        var o=try XCTUnwrap(JSONSerialization.jsonObject(with:f.plan.intentBytes) as? [String:Any]);o["admitted"]=true
        XCTAssertThrowsError(try DeviceNativeProvisioningIntentCodec.decode(JSONSerialization.data(withJSONObject:o)))
        var e=try XCTUnwrap(JSONSerialization.jsonObject(with:f.plan.candidateBytes) as? [String:Any]);e["schemaVersion"]=1
        XCTAssertThrowsError(try DeviceNativeStructuralEnvelopeCodec.decode(JSONSerialization.data(withJSONObject:e)))
    }
    func testChangedOwnerAndPrivateInputRejectBeforeJournalEffects()throws {
        let f=try fixture(generic:true),before=try snapshot(f.journalRoot),events=f.probe.events
        let wrong=DeviceNativeGrantRevisionInput(schemaVersion:2,identity:f.request.grantInput.identity,owner:owner,entries:f.request.grantInput.entries,credentials:f.request.grantInput.credentials,retainedRevisions:[])
        let bad=DeviceNativeProvisioningRequest(roots:f.roots,delivery:f.request.delivery,grantOperationID:f.request.grantOperationID,baseline:f.request.baseline,candidate:f.request.candidate,packages:f.request.packages,grantInput:wrong,qualifiedGrant:f.request.qualifiedGrant)
        XCTAssertThrowsError(try f.coordinator.joinExact(bad,plan:f.plan,attachment:f.attachment));XCTAssertEqual(f.probe.events,events);XCTAssertEqual(try snapshot(f.journalRoot),before)
    }
    func testExactJoinRestartUsesOriginalRecordedInodesAndIDs()throws {
        let f=try fixture();_ = try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment)
        let j=DeviceLocalProvisioningIntentStore(root:f.journalRoot,rootID:f.roots.journalID,protectedRoots:[f.structuralRoot]),s=DeviceStructuralStore(root:f.structuralRoot,rootID:f.roots.structuralID)
        let baseline=try s.initializeNativeGenesisExplicit(f.request.baseline.state)
        let request=DeviceNativeProvisioningRequest(roots:f.roots,delivery:f.request.delivery,grantOperationID:f.request.grantOperationID,baseline:baseline,candidate:f.request.candidate,packages:f.request.packages,grantInput:f.request.grantInput,qualifiedGrant:f.request.qualifiedGrant)
        let plan=try DeviceNativeProvisioningPlanner.qualify(request),coordinator=DeviceNativeProvisioningCoordinator(journal:j,structural:s)
        let receipt=try coordinator.joinExact(request,plan:plan,attachment:nil)
        XCTAssertEqual(receipt.nativeOperationID,f.plan.nativeOperationID);try coordinator.verifyExact(receipt,plan:plan,baseline:baseline)
    }
    func testJoinFaultBoundariesRetainExactLiveRetryAndNoCapacityRelease()throws {
        let faults:[DeviceLocalProvisioningIntentStore.Boundary]=[.afterCreate(.nativeJoinIntent),.afterWrite(.nativeJoinIntent),.afterReplace(.nativeJoinIntent),.afterCreate(.nativeJoinCandidate),.afterWrite(.nativeJoinBinding),.afterReplace(.nativeJoinBinding),.afterWrite(.nativeJoinCandidate),.afterReplace(.nativeJoinCandidate),.afterReplace(.nativeJoinConfirmation),.beforeNativeJoinScopeExit]
        for fault in faults {
            let f=try fixture();f.probe.journal=fault
            XCTAssertThrowsError(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment))
            let receipt=try f.coordinator.joinExact(f.request,plan:f.plan,attachment:nil)
            try f.coordinator.verifyExact(receipt,plan:f.plan,baseline:f.request.baseline)
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.journalRoot.appendingPathComponent("delivery.completion").path))
        }
    }
    func testLateOriginalProofReplacementSuppressesScopeExitPublication()throws {
        let f=try fixture(),proof=f.structuralRoot.appendingPathComponent("native-genesis.confirm")
        f.probe.journalAction={site in
            if site == .beforeNativeJoinScopeExit {
                f.probe.journalAction=nil
                try Data(contentsOf:proof).write(to:proof,options:.atomic)
            }
        }
        XCTAssertThrowsError(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment))
        // No ACK/token escaped from the failed scope. The original baseline stays stale; visible
        // complete join bytes cannot bypass it or lazily publish a previously pending object.
        let before=try snapshot(f.journalRoot),events=f.probe.events
        XCTAssertThrowsError(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:nil))
        XCTAssertEqual(before,try snapshot(f.journalRoot));XCTAssertEqual(events,f.probe.events)
    }
    func testRestartBeforeReciprocalJoinBindingPreservesOrphanInsteadOfAdoption()throws {
        let f=try fixture();f.probe.journal = .afterCreate(.nativeJoinCandidate)
        XCTAssertThrowsError(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment));let before=try snapshot(f.journalRoot)
        let restarted=DeviceLocalProvisioningIntentStore(root:f.journalRoot,rootID:f.roots.journalID,protectedRoots:[f.structuralRoot])
        XCTAssertThrowsError(try DeviceNativeProvisioningCoordinator(journal:restarted,structural:f.structural).joinExact(f.request,plan:f.plan,attachment:nil))
        XCTAssertEqual(try snapshot(f.journalRoot),before)
        XCTAssertNoThrow(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:nil))
    }
    func testDeletedCapturedPrefixAndSameByteReplacementRejectWithoutEffects()throws {
        for replace in [false,true] {
            let f=try fixture();f.probe.journal = .afterCreate(.nativeJoinCandidate)
            XCTAssertThrowsError(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment))
            let path=f.journalRoot.appendingPathComponent("native-join.candidate.stage")
            if replace {try Data().write(to:path,options:.atomic)}else{try FileManager.default.removeItem(at:path)}
            let before=try snapshot(f.journalRoot),events=f.probe.events
            XCTAssertThrowsError(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:nil));XCTAssertEqual(f.probe.events,events);XCTAssertEqual(try snapshot(f.journalRoot),before)
        }
    }
    func testOriginalGenesisCheckpointSameTipRecommitInvalidatesBeforeJoinEffects()throws {
        let f=try fixture(),before=try snapshot(f.journalRoot)
        _ = try f.structural.initializeNativeGenesisExplicit(f.request.baseline.state)
        let events=f.probe.events
        XCTAssertThrowsError(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment));XCTAssertEqual(events,f.probe.events);XCTAssertEqual(try snapshot(f.journalRoot),before)
    }
    func testOriginalAttachmentReplacementAndExtraLeavesRejectBeforeEffects()throws {
        for name in ["delivery.plan","delivery.confirm","native-join.extra"] {
            let f=try fixture(),path=f.journalRoot.appendingPathComponent(name)
            if name == "native-join.extra" {try Data().write(to:path)}else{try Data(contentsOf:path).write(to:path,options:.atomic)}
            let before=try snapshot(f.journalRoot),events=f.probe.events
            XCTAssertThrowsError(try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment));XCTAssertEqual(events,f.probe.events);XCTAssertEqual(try snapshot(f.journalRoot),before)
        }
    }
    func testNativeGenesisFaultsAndChangedInputPreserveExactOriginalRetry()throws {
        for fault in [DeviceStructuralStore.Boundary.afterCreate(.nativeGenesisIntent),.afterWrite(.nativeGenesisIntent),.afterCreate(.nativeGenesis),.afterWrite(.nativeGenesisBinding),.afterReplace(.nativeGenesis),.afterReplace(.nativeGenesisConfirmation)] {
            let r=try root(),probe=Probe(),store=DeviceStructuralStore(root:r,rootID:UUID(),boundary:{try probe.hit($0)}),state=try empty(owner)
            try store.initializeExplicit();probe.structural=fault;XCTAssertThrowsError(try store.initializeNativeGenesisExplicit(state))
            let before=try snapshot(r),events=probe.events
            XCTAssertThrowsError(try store.initializeNativeGenesisExplicit(empty(state.owner)));XCTAssertEqual(probe.events,events);XCTAssertEqual(try snapshot(r),before)
            XCTAssertNoThrow(try store.initializeNativeGenesisExplicit(state));XCTAssertThrowsError(try store.initializeExplicit())
        }
    }
    func testMissingAndReplacedGenesisProofRejectReconstructedStore()throws {
        for replaced in [false,true] {
            let r=try root(),id=UUID(),state=try empty(owner),store=DeviceStructuralStore(root:r,rootID:id)
            try store.initializeExplicit();_ = try store.initializeNativeGenesisExplicit(state)
            let path=r.appendingPathComponent("native-genesis.confirm")
            if replaced{try Data(contentsOf:path).write(to:path,options:.atomic)}else{try FileManager.default.removeItem(at:path)}
            let before=try snapshot(r),restarted=DeviceStructuralStore(root:r,rootID:id)
            XCTAssertThrowsError(try restarted.initializeNativeGenesisExplicit(state));XCTAssertEqual(try snapshot(r),before)
        }
    }

    func testEqualPublicNativeIntentDoesNotProveOriginalSecretIdentity()throws {
        let f=try fixture(generic:true),old=f.request.grantInput
        let changed=Data(repeating:88,count:old.credentials[0].bytes.count)
        var generic=old.entries[0].generic!;generic.entries[0].secret=changed
        let entry=DeviceGrantEntryInput(entryID:old.entries[0].entryID,revision:old.entries[0].revision,generic:generic,homeAssistant:nil,publicReads:nil,credentialReferences:old.entries[0].credentialReferences)
        let input=DeviceNativeGrantRevisionInput(schemaVersion:2,identity:old.identity,owner:old.owner,entries:[entry],credentials:[.init(revisionID:old.credentials[0].revisionID,bytes:changed)],retainedRevisions:[])
        guard case .supplied(let id,_,let package)=f.request.packages[0] else{throw Fault.injected}
        let fresh=try DeviceNativeGrantRevisionQualifier.qualify(input,expectedEntries:[.init(entryID:id,package:package)])
        XCTAssertFalse(fresh.exactlyMatches(f.request.qualifiedGrant));XCTAssertEqual(fresh.publicMetadataBytes,f.request.qualifiedGrant.publicMetadataBytes)
        let request=DeviceNativeProvisioningRequest(roots:f.roots,delivery:f.request.delivery,grantOperationID:f.request.grantOperationID,baseline:f.request.baseline,candidate:f.request.candidate,packages:f.request.packages,grantInput:input,qualifiedGrant:fresh)
        let plan=try DeviceNativeProvisioningPlanner.qualify(request)
        // This legitimate same-length, equal-public intent is deliberately NOT a private proof.
        XCTAssertEqual(plan.intentBytes,f.plan.intentBytes);XCTAssertEqual(plan.candidateBytes,f.plan.candidateBytes)
    }
    func testChangedNativeCandidateSameOperationRejectsWithoutInvalidatingValidReceipt()throws {
        let f=try fixture(),receipt=try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment),old=f.request.candidate.entries[0]
        let changed=try DeviceNativeStructuralEntry.validating(entryID:old.entryID,displayName:"Different household name",package:old.package,preparedPackage:old.preparedPackage)
        let state=try DeviceNativeStructuralState.validating(generationID:f.request.candidate.generationID,owner:.nativeInstallation(f.request.candidate.owner),entries:[changed],configuredEntryID:changed.entryID)
        let request=DeviceNativeProvisioningRequest(roots:f.roots,delivery:f.request.delivery,grantOperationID:f.request.grantOperationID,baseline:f.request.baseline,candidate:state,packages:f.request.packages,grantInput:f.request.grantInput,qualifiedGrant:f.request.qualifiedGrant)
        let plan=try DeviceNativeProvisioningPlanner.qualify(request),before=try snapshot(f.journalRoot),events=f.probe.events
        XCTAssertThrowsError(try f.coordinator.joinExact(request,plan:plan,attachment:nil));XCTAssertEqual(before,try snapshot(f.journalRoot));XCTAssertEqual(events,f.probe.events)
        try f.coordinator.verifyExact(receipt,plan:f.plan,baseline:f.request.baseline)
    }
    func testOtherInstanceSameTipJoinRetryInvalidatesOriginalReceipt()throws {
        let f=try fixture(),receipt=try f.coordinator.joinExact(f.request,plan:f.plan,attachment:f.attachment)
        let other=DeviceLocalProvisioningIntentStore(root:f.journalRoot,rootID:f.roots.journalID,protectedRoots:[f.structuralRoot])
        let current=try DeviceNativeProvisioningCoordinator(journal:other,structural:f.structural).joinExact(f.request,plan:f.plan,attachment:nil)
        XCTAssertThrowsError(try f.coordinator.verifyExact(receipt,plan:f.plan,baseline:f.request.baseline))
        try DeviceNativeProvisioningCoordinator(journal:other,structural:f.structural).verifyExact(current,plan:f.plan,baseline:f.request.baseline)
    }

    #else
    func testNativeGenesisUnsupportedDigestFailsClosed()throws {
        let r=try root(),store=DeviceStructuralStore(root:r,rootID:UUID());try store.initializeExplicit()
        XCTAssertThrowsError(try store.initializeNativeGenesisExplicit(empty(owner)))
    }
    #endif
}
