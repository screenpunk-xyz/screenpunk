import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ScreenpunkCore

final class DeviceNativeDeliveryAttachmentTests: XCTestCase {
    private func root() throws -> URL {
        let temp=FileManager.default.temporaryDirectory.path
        guard let pointer=realpath(temp,nil) else{throw NSError(domain:"fixture",code:1)}
        defer{free(pointer)}
        let root=URL(fileURLWithPath:String(cString:pointer)).appendingPathComponent("native-delivery-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock{try FileManager.default.removeItem(at:root)};return root
    }
    private func command(_ plan:Data, sequence:String="9223372036854775807") throws -> (Data,String) {
        #if !canImport(CryptoKit)
        throw XCTSkip("Genuine SHA256 package/profile checks require CryptoKit; unsupported platforms fail closed")
        #else
        let uuid="00000000-0000-0000-0000-000000000001"
        let p=try DeviceDeliveryPackageCandidate.validating(packageProfile:DeviceDeliveryPackageCandidate.profile,
            publicationID:UUID(),projectID:UUID(),packageID:UUID(),dashboardID:UUID(),revision:UUID(),
            manifestDigest:.validating(String(repeating:"a",count:64)),manifestSHA256:.validating(String(repeating:"b",count:64)),archiveSHA256:.validating(String(repeating:"c",count:64)),compressedBytes:1,expandedBytes:1,archiveEntries:1)
        let id=UUID(),set=try DeviceResultingSetCandidate.validating(entries:[.validating(entryID:id,provenance:.cloud(p))],configuredEntryID:id)
        let a:[String:Any]=["schemaVersion":1,"operationId":uuid,"planId":uuid,"installationId":uuid,"accountId":uuid,"locationId":uuid,"transitionId":uuid,"planDigest":try DeviceNativeDeliveryAttachmentCodec.hash(plan),"planByteLength":plan.count]
        let rawAssociation=try JSONSerialization.data(withJSONObject:a,options:[.sortedKeys])
        let header=rawAssociation.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let package:[String:Any]=["packageProfile":DeviceDeliveryPackageCandidate.profile,"publicationId":p.publicationID.uuidString.lowercased(),"projectId":p.projectID.uuidString.lowercased(),"packageId":p.packageID.uuidString.lowercased(),"dashboardId":p.dashboardID.uuidString.lowercased(),"revision":p.revision.uuidString.lowercased(),"manifestDigest":p.manifestDigest.text,"manifestSha256":p.manifestSHA256.text,"archiveSha256":p.archiveSHA256.text,"compressedBytes":1,"expandedBytes":1,"archiveEntries":1]
        var o=a;o["sequence"]=sequence;o["expectedInstalledSetGenerationId"]=uuid;o["desiredSetGenerationId"]="00000000-0000-0000-0000-000000000002"
        o["resultingSet"]=["schemaVersion":1,"entries":[["entryId":id.uuidString.lowercased(),"provenance":["kind":"cloud","package":package]]],"configuredEntryId":id.uuidString.lowercased()]
        o["resultingSetDigest"]=try DeviceDeliveryCandidateCodec.resultingSetDigest(set);o["executionExpiresAt"]="2026-10-04T12:00:00.123Z"
        return (try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys]),header)
        #endif
    }
    private func input(rootID:UUID,op:UUID=UUID(),plan:Data=Data("approved exact plan".utf8))throws->DeviceNativeDeliveryCommandBinding {
        let (c,h)=try command(plan)
        return try DeviceNativeDeliveryCommandBinding.bind(command:c,associationHeader:h,rawPlan:plan,nativeOperationID:op,journalRootID:rootID)
    }
    private func rebind(_ original:DeviceNativeDeliveryCommandBinding,mutate:(inout [String:Any])->Void)throws->DeviceNativeDeliveryCommandBinding {
        var o=try XCTUnwrap(JSONSerialization.jsonObject(with:original.commandBytes) as? [String:Any]);mutate(&o)
        let a=original.association
        let headerObject:[String:Any]=["schemaVersion":1,"operationId":a.operationID.uuidString.lowercased(),"planId":a.planID.uuidString.lowercased(),"installationId":a.installationID.uuidString.lowercased(),"accountId":a.accountID.uuidString.lowercased(),"locationId":a.locationID.uuidString.lowercased(),"transitionId":a.transitionID.uuidString.lowercased(),"planDigest":a.planDigest,"planByteLength":a.planByteLength]
        let h=try JSONSerialization.data(withJSONObject:headerObject).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        return try .bind(command:JSONSerialization.data(withJSONObject:o),associationHeader:h,rawPlan:original.planBytes,nativeOperationID:original.nativeOperationID,journalRootID:original.journalRootID)
    }
    func testExactAssociationAndMaximumRawPlanRemainNonAuthorizing()throws {
        let value=try input(rootID:UUID(),plan:Data(repeating:65,count:65536))
        XCTAssertEqual(value.planBytes.count,65536);XCTAssertEqual(value.sequence,9223372036854775807)
        XCTAssertThrowsError(try input(rootID:UUID(),plan:Data(repeating:65,count:65537)))
    }
    func testStrictSequenceIdentityUnknownKeysAndDateControls()throws {
        let value=try input(rootID:UUID())
        for sequence in ["0","01","1\n","9223372036854775808","10000000000000000000","1e0"] {XCTAssertThrowsError(try rebind(value){$0["sequence"]=sequence})}
        for field in ["operationId","planId","installationId","accountId","locationId","transitionId","expectedInstalledSetGenerationId","desiredSetGenerationId","planDigest","resultingSetDigest"] {
            XCTAssertThrowsError(try rebind(value){$0[field]=($0[field] as! String)+"\n"})
        }
        XCTAssertThrowsError(try rebind(value){$0["approved"]=true})
        for date in ["2026-02-30T12:00:00Z","2026-10-04T24:00:00Z","2026-10-04T12:00:00Z\n"] {XCTAssertThrowsError(try rebind(value){$0["executionExpiresAt"]=date})}
    }
    func testPlanFetchBytesAndBase64AssociationCannotSubstituteApproval()throws {
        let plan=Data("original plan".utf8),id=UUID(),op=UUID(),pair=try command(plan)
        XCTAssertThrowsError(try DeviceNativeDeliveryCommandBinding.bind(command:pair.0,associationHeader:pair.1+"=",rawPlan:plan,nativeOperationID:op,journalRootID:id))
        XCTAssertThrowsError(try DeviceNativeDeliveryCommandBinding.bind(command:pair.0,associationHeader:pair.1+"\n",rawPlan:plan,nativeOperationID:op,journalRootID:id))
        XCTAssertThrowsError(try DeviceNativeDeliveryCommandBinding.bind(command:pair.0,associationHeader:pair.1,rawPlan:Data("differentplan".utf8),nativeOperationID:op,journalRootID:id))
        var body=try XCTUnwrap(JSONSerialization.jsonObject(with:pair.0) as? [String:Any]);body["planId"]=UUID().uuidString.lowercased()
        XCTAssertThrowsError(try DeviceNativeDeliveryCommandBinding.bind(command:JSONSerialization.data(withJSONObject:body),associationHeader:pair.1,rawPlan:plan,nativeOperationID:op,journalRootID:id))
    }
    func testStrictDuplicateUnicodeDepthAndRawBoundsBeforeDecoding()throws {
        for raw in ["{\"x\":1,\"\\u0078\":2}","{\"x\":\"\\ud800\"}","{}{}"] {XCTAssertThrowsError(try DeviceNativeDeliveryAttachmentCodec.object(Data(raw.utf8),limit:32768,keys:["x"]))}
        XCTAssertThrowsError(try DeviceNativeDeliveryAttachmentCodec.object(Data(repeating:32,count:32769),limit:32768,keys:[]))
        let deep=String(repeating:"{\"x\":",count:17)+"0"+String(repeating:"}",count:17)
        XCTAssertThrowsError(try DeviceNativeDeliveryAttachmentCodec.object(Data(deep.utf8),limit:32768,keys:["x"]))
    }
    func testPublishedAttachmentExactRestartAndReceiptEpoch()throws {
        let r=try root(),id=UUID(),value=try input(rootID:id)
        let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]);try store.initializeExplicit()
        let receipt=try store.publishDeliveryAttachmentExact(value);try store.verifyDeliveryAttachmentExact(receipt)
        XCTAssertEqual(try store.inspectDeliveryAttachmentExact()?.nativeOperationID,value.nativeOperationID)
        let restarted=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[])
        XCTAssertThrowsError(try restarted.verifyDeliveryAttachmentExact(receipt))
        let recovered=try restarted.recommitDeliveryAttachmentExact(value);try restarted.verifyDeliveryAttachmentExact(recovered)
        XCTAssertThrowsError(try store.verifyDeliveryAttachmentExact(receipt))
        XCTAssertEqual(try Data(contentsOf:r.appendingPathComponent("delivery.plan")),value.planBytes)
    }
    func testOneSharedPendingReservationNoSecondOperationOrRelease()throws {
        let r=try root(),id=UUID(),value=try input(rootID:id)
        let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]);try store.initializeExplicit()
        let receipt=try store.publishDeliveryAttachmentExact(value)
        XCTAssertThrowsError(try store.publishDeliveryAttachmentExact(input(rootID:id)))
        XCTAssertThrowsError(try store.inspectPendingExact()) // Legacy journal consumers cannot bypass pending attachment.
        try store.verifyDeliveryAttachmentExact(receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath:r.appendingPathComponent("delivery.completion").path))
    }
    func testSameLengthChangedInputRejectedWithoutEvidenceOrEpochChange()throws {
        let r=try root(),id=UUID(),value=try input(rootID:id)
        let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]);try store.initializeExplicit()
        let receipt=try store.publishDeliveryAttachmentExact(value)
        let before=try Data(contentsOf:r.appendingPathComponent("delivery.intent"))
        let changed=try rebind(value){$0["sequence"]="9223372036854775806"}
        XCTAssertEqual(value.commandBytes.count,changed.commandBytes.count)
        XCTAssertThrowsError(try store.recommitDeliveryAttachmentExact(changed))
        XCTAssertEqual(try Data(contentsOf:r.appendingPathComponent("delivery.intent")),before)
        try store.verifyDeliveryAttachmentExact(receipt)
    }
    func testAllPublicationFaultBoundariesExactLiveRetry()throws {
        let kinds:[DeviceLocalProvisioningIntentStore.Kind]=[.deliveryIntent,.deliveryBinding,.deliveryCommand,.deliveryPlan,.deliveryConfirmation]
        for kind in kinds {
            let boundaries:[DeviceLocalProvisioningIntentStore.Boundary]=[.afterCreate(kind),.afterWrite(kind),.afterFileSync(kind),.beforeReplace(kind),.afterReplace(kind),.afterDirectorySync(kind)]
            for target in boundaries {
                let r=try root(),id=UUID(),value=try input(rootID:id);var armed=false,hit=false
                let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]){boundary in if armed && !hit && boundary == target {hit=true;throw NSError(domain:"fault",code:1)}}
                try store.initializeExplicit();armed=true
                XCTAssertThrowsError(try store.publishDeliveryAttachmentExact(value));XCTAssertTrue(hit)
                let receipt=try store.recommitDeliveryAttachmentExact(value);try store.verifyDeliveryAttachmentExact(receipt)
            }
        }
    }
    func testRestartBeforeReciprocalBindingPreservesUnknownOrphan()throws {
        let r=try root(),id=UUID(),value=try input(rootID:id);var armed=false
        let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]){if armed && $0 == .afterCreate(.deliveryCommand){throw NSError(domain:"fault",code:1)}}
        try store.initializeExplicit();armed=true;XCTAssertThrowsError(try store.publishDeliveryAttachmentExact(value))
        let before=try Data(contentsOf:r.appendingPathComponent("delivery.intent"))
        let restarted=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[])
        XCTAssertThrowsError(try restarted.recommitDeliveryAttachmentExact(value))
        XCTAssertEqual(try Data(contentsOf:r.appendingPathComponent("delivery.intent")),before)
        XCTAssertTrue(FileManager.default.fileExists(atPath:r.appendingPathComponent("delivery.command.stage").path))
    }
    func testSameByteReplacementAndMissingOriginalNodesBlock()throws {
        let r=try root(),id=UUID(),value=try input(rootID:id)
        let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]);try store.initializeExplicit();let receipt=try store.publishDeliveryAttachmentExact(value)
        let path=r.appendingPathComponent("delivery.plan"),bytes=try Data(contentsOf:path);try bytes.write(to:path,options:.atomic)
        XCTAssertThrowsError(try store.verifyDeliveryAttachmentExact(receipt));XCTAssertThrowsError(try store.recommitDeliveryAttachmentExact(value))
        let restarted=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]);XCTAssertThrowsError(try restarted.recommitDeliveryAttachmentExact(value))
    }
    func testBindingSyncFailureSuppressesAcknowledgmentThenExactRetry()throws {
        let r=try root(),id=UUID(),value=try input(rootID:id);var armed=false,hit=false
        let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]){if armed && !hit && $0 == .afterFileSync(.binding){hit=true;throw NSError(domain:"fault",code:1)}}
        try store.initializeExplicit();armed=true;XCTAssertThrowsError(try store.publishDeliveryAttachmentExact(value));XCTAssertTrue(hit)
        let receipt=try store.recommitDeliveryAttachmentExact(value);try store.verifyDeliveryAttachmentExact(receipt)
    }
    func testUnknownLeavesAndBoundedOperationScanRejectBeforeAttachmentEffects()throws {
        let r=try root(),id=UUID(),value=try input(rootID:id)
        let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]);try store.initializeExplicit()
        // Mechanical malformed inventory controls, not128 genuine completed operations.
        for i in 0..<129 {
            let name=String(format:"00000000-0000-0000-0000-%012x.intent.json",i)
            try Data("preserved evidence".utf8).write(to:r.appendingPathComponent("operations").appendingPathComponent(name))
        }
        XCTAssertThrowsError(try store.publishDeliveryAttachmentExact(value))
        XCTAssertFalse(FileManager.default.fileExists(atPath:r.appendingPathComponent("delivery.intent.stage").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:r.appendingPathComponent("operations").path).count,129)
    }
    private struct NodeEvidence:Equatable {let inode:UInt64;let bytes:Data}
    private func evidence(_ root:URL)throws->[String:NodeEvidence] {
        var result:[String:NodeEvidence]=[:]
        for path in try FileManager.default.subpathsOfDirectory(atPath:root.path) {
            let url=root.appendingPathComponent(path),a=try FileManager.default.attributesOfItem(atPath:url.path)
            guard a[.type] as? FileAttributeType == .typeRegular else{continue}
            result[path] = .init(inode:(a[.systemFileNumber] as! NSNumber).uint64Value,bytes:try Data(contentsOf:url))
        }
        return result
    }
    private func overwritePreservingInode(_ url:URL,_ data:Data)throws {
        let file=try FileHandle(forWritingTo:url);defer{try? file.close()}
        try file.truncate(atOffset:0);try file.write(contentsOf:data)
    }
    func testCompleteRetryPreflightRejectsEveryMissingMalformedReplacedNodeWithoutEffects()throws {
        for leaf in ["delivery.intent","delivery.binding","delivery.command","delivery.plan","delivery.confirm"] {
            for mutation in ["malformed","missing","replacement"] {
                let r=try root(),id=UUID(),value=try input(rootID:id);var events=0
                let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]){_ in events += 1}
                try store.initializeExplicit();let receipt=try store.publishDeliveryAttachmentExact(value)
                let url=r.appendingPathComponent(leaf),original=try Data(contentsOf:url)
                let backup=r.deletingLastPathComponent().appendingPathComponent("delivery-owned-backup-"+UUID().uuidString)
                addTeardownBlock{try? FileManager.default.removeItem(at:backup)}
                if mutation == "malformed" {try overwritePreservingInode(url,Data("malformed".utf8))}
                else {
                    try FileManager.default.moveItem(at:url,to:backup)
                    if mutation == "replacement" {try original.write(to:url)}
                }
                let before=try evidence(r),count=events
                XCTAssertThrowsError(try store.recommitDeliveryAttachmentExact(value),leaf+" "+mutation)
                XCTAssertEqual(events,count);XCTAssertEqual(try evidence(r),before)
                if mutation == "malformed" {try overwritePreservingInode(url,original)}
                else {
                    if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}
                    try FileManager.default.moveItem(at:backup,to:url)
                }
                // Exact original receipt remains valid after externally restoring ORIGINAL inode/bytes:
                // rejected retry did not invalidate epoch or qualification.
                try store.verifyDeliveryAttachmentExact(receipt)
            }
        }
    }
    func testExtraKnownStageAndUnknownLeafPreflightHaveNoEffects()throws {
        for leaf in ["delivery.plan.stage","unknown-delivery-leaf"] {
            let r=try root(),id=UUID(),value=try input(rootID:id);var events=0
            let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]){_ in events += 1}
            try store.initializeExplicit();let receipt=try store.publishDeliveryAttachmentExact(value)
            let url=r.appendingPathComponent(leaf);try Data("unknown preserved".utf8).write(to:url)
            let before=try evidence(r),count=events
            XCTAssertThrowsError(try store.recommitDeliveryAttachmentExact(value));XCTAssertEqual(events,count);XCTAssertEqual(try evidence(r),before)
            try FileManager.default.removeItem(at:url);try store.verifyDeliveryAttachmentExact(receipt)
        }
    }
    func testEveryPreBindingCapturedPrefixMissingReplacementAndExtraRejectWithoutEffects()throws {
        let points:[(DeviceLocalProvisioningIntentStore.Kind,String)]=[(.deliveryIntent,"delivery.intent.stage"),(.deliveryCommand,"delivery.command.stage"),(.deliveryPlan,"delivery.plan.stage"),(.deliveryConfirmation,"delivery.confirm.stage"),(.deliveryBinding,"delivery.binding.stage")]
        for (kind,leaf) in points {
            for mutation in ["missing","replacement","extra"] {
                let r=try root(),id=UUID(),value=try input(rootID:id);var armed=false,hit=false,events=0
                let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]){point in
                    events += 1
                    if armed && !hit && point == .afterCreate(kind) {hit=true;throw NSError(domain:"prefix-fault",code:1)}
                }
                try store.initializeExplicit();armed=true
                XCTAssertThrowsError(try store.publishDeliveryAttachmentExact(value));XCTAssertTrue(hit)
                let originalURL=r.appendingPathComponent(leaf)
                let backup=r.deletingLastPathComponent().appendingPathComponent("prefix-owned-backup-"+UUID().uuidString)
                addTeardownBlock{try? FileManager.default.removeItem(at:backup)}
                var extraURL:URL?
                if mutation == "extra" {
                    // Select a never-captured leaf; when all five are captured, make a duplicate
                    // intent stage beside its installed original. Both must be rejected.
                    let names=["delivery.command.stage","delivery.plan.stage","delivery.confirm.stage","delivery.binding.stage","delivery.intent.stage"]
                    let name=names.first{!FileManager.default.fileExists(atPath:r.appendingPathComponent($0).path)}!
                    let url=r.appendingPathComponent(name);try Data().write(to:url);extraURL=url
                } else {
                    try FileManager.default.moveItem(at:originalURL,to:backup)
                    if mutation == "replacement" {try Data().write(to:originalURL)}
                }
                let before=try evidence(r),count=events
                XCTAssertThrowsError(try store.recommitDeliveryAttachmentExact(value),leaf+" "+mutation)
                XCTAssertEqual(events,count);XCTAssertEqual(try evidence(r),before)
                if let extraURL {try FileManager.default.removeItem(at:extraURL)}
                else {
                    if FileManager.default.fileExists(atPath:originalURL.path){try FileManager.default.removeItem(at:originalURL)}
                    try FileManager.default.moveItem(at:backup,to:originalURL)
                }
                // ORIGINAL inode restoration, not same-byte adoption: exact live retry succeeds.
                let receipt=try store.recommitDeliveryAttachmentExact(value);try store.verifyDeliveryAttachmentExact(receipt)
            }
        }
    }
    func testThrowingScopeExitCannotPublishAttachmentQualification()throws {
        let r=try root(),id=UUID(),value=try input(rootID:id);var armed=false,hit=false
        let extra=r.appendingPathComponent("scope-exit-sentinel")
        let store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]){point in
            if armed && point == .beforeDeliveryScopeExit {armed=false;hit=true;try Data("preserved".utf8).write(to:extra)}
        }
        try store.initializeExplicit();armed=true
        XCTAssertThrowsError(try store.publishDeliveryAttachmentExact(value));XCTAssertTrue(hit)
        let before=try evidence(r);XCTAssertThrowsError(try store.initializeExplicit());XCTAssertEqual(try evidence(r),before)
        try FileManager.default.removeItem(at:extra)
        // Diagnosis returns no ACK. Only explicit exact recommit can produce a usable receipt.
        XCTAssertNotNil(try store.inspectDeliveryAttachmentExact())
        let receipt=try store.recommitDeliveryAttachmentExact(value);try store.verifyDeliveryAttachmentExact(receipt)
    }
    private final class LegacyBackend:DeviceGrantCredentialBackend,@unchecked Sendable {
        var values:[String:DeviceGrantCredentialValue]=[:]
        func inventory(service:String,maximum:Int,visit:(DeviceGrantCredentialItem)throws->Void)throws {for key in values.keys.sorted(){try visit(values[key]!.item)}}
        func read(service:String,account:String,maximumBytes:Int)throws->DeviceGrantCredentialValue? {values[account]}
        func add(service:String,account:String,bytes:Data)throws->DeviceGrantCredentialItem {
            guard values[account] == nil else{throw DeviceGrantPreparationError.conflict}
            let item=DeviceGrantCredentialItem(account:account,persistentReference:Data(UUID().uuidString.utf8),byteCount:bytes.count)
            values[account] = .init(item:item,bytes:bytes);return item
        }
    }
    func testRetainedGenuineLegacyLivePlanRetryCannotCatchAwayAttachmentReservation()throws {
        let jr=try root(),pr=try root(),gr=try root(),sr=try root(),journalID=UUID(),packageID=UUID(),grantID=UUID(),structuralID=UUID()
        var events=0
        let journal=DeviceLocalProvisioningIntentStore(root:jr,rootID:journalID,protectedRoots:[]){_ in events += 1}
        func scope(_ url:URL)->DevicePackageProtectedScope {
            let p=url.deletingLastPathComponent().appendingPathComponent("delivery-protected-"+UUID().uuidString)
            return .init(legacyStateRoot:p.appendingPathComponent("state"),legacyArchiveRoot:p.appendingPathComponent("archive"),resetRoot:p.appendingPathComponent("reset"),cloudRoot:p.appendingPathComponent("cloud"),managementRoot:p.appendingPathComponent("management"),preferencesRoot:p.appendingPathComponent("preferences"),otherProtectedRoots:[])
        }
        let package=DevicePackagePreparationStore(root:pr,rootID:packageID,protectedScope:scope(pr))
        let grants=DeviceGrantPreparationStore(root:gr,rootID:grantID,protectedScope:scope(gr),backend:LegacyBackend())
        let structural=DeviceStructuralStore(root:sr,rootID:structuralID)
        try journal.initializeExplicit();try package.initializeExplicit();try grants.initializeExplicit();try structural.initializeExplicit()
        let owner=PairingIdentity(role:.controller,publicKey:[UInt8](repeating:7,count:32))
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:grantID,revisionID:UUID()),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        let request=DeviceProvisioningPlanRequest(roots:.init(journalID:journalID,structuralID:structuralID,packageID:packageID,grantID:grantID),operationID:UUID(),grantOperationID:UUID(),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:"preserved"),snapshot:.init(generationID:UUID(),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"preserved"),owner:owner,packages:[],grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]))
        let plan=try DeviceProvisioningPlanner.qualify(request),receipt=try journal.stageExact(plan)
        let anchor=try DeviceBoundGrantAttemptCoordinator(journal:journal,grants:grants).stageExact(request,plan:plan,journalReceipt:receipt)
        let resources=DeviceBoundPackagePreparationCoordinator(journal:journal,grants:grants,packages:package)
        let batch=try resources.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:[])
        let terminal=try resources.closeGrantTerminalExact(resources.completeCredentialsExact(batch))
        let coordinator=DeviceLocalCompleteSetCommitCoordinator(packageStore:package,grantStore:grants,structuralStore:structural)
        let ack=try coordinator.commitBoundTerminalExact(terminal,journal:journal)
        _ = try coordinator.completeProvisioningExact(terminal,acknowledgment:ack,journal:journal)
        let attachment=try journal.publishDeliveryAttachmentExact(self.input(rootID:journalID))
        let before=try evidence(jr),count=events
        XCTAssertThrowsError(try journal.recommitExact(plan))
        XCTAssertEqual(events,count);XCTAssertEqual(try evidence(jr),before)
        try journal.verifyDeliveryAttachmentExact(attachment)
    }
    func testNonreentrantFaultCallbackCannotEnterJournal()throws {
        let r=try root(),id=UUID(),value=try input(rootID:id);var armed=false,hit=false
        var store:DeviceLocalProvisioningIntentStore!
        store=DeviceLocalProvisioningIntentStore(root:r,rootID:id,protectedRoots:[]){if armed && !hit && $0 == .afterWrite(.deliveryIntent){hit=true;XCTAssertThrowsError(try store.inspectDeliveryAttachmentExact())}}
        try store.initializeExplicit();armed=true;let receipt=try store.publishDeliveryAttachmentExact(value);XCTAssertTrue(hit);try store.verifyDeliveryAttachmentExact(receipt)
    }
}
