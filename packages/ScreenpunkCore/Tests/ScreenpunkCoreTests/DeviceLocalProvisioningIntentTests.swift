import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ScreenpunkCore
#if canImport(CryptoKit)
import CryptoKit
#endif
final class DeviceLocalProvisioningIntentTests:XCTestCase {
    private func id(_ n:Int)->UUID{UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",n))!}
    private var owner:PairingIdentity{.init(role:.controller,publicKey:[UInt8](repeating:7,count:32))}
    private func plan(_ operation:Int=10,generation:Int=7)throws->DeviceValidatedProvisioningPlan {
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(5)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        return try DeviceProvisioningPlanner.qualify(.init(roots:.init(journalID:id(1),structuralID:id(2),packageID:id(3),grantID:id(4)),operationID:id(operation),grantOperationID:id(6),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:"opaque-old"),snapshot:.init(generationID:id(generation),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque-old"),owner:owner,packages:[],grantInput:input,qualifiedGrant:DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[])))
    }
    private func root()throws->URL {
        let physical=try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil));defer{free(physical)}
        let root=URL(fileURLWithPath:String(cString:physical)).appendingPathComponent("provisioning-intent-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
    }
    private func store(_ root:URL,boundary:@escaping(DeviceLocalProvisioningIntentStore.Boundary)throws->Void={_ in})->DeviceLocalProvisioningIntentStore {.init(root:root,rootID:id(1),protectedRoots:[root.deletingLastPathComponent().appendingPathComponent("protected-"+root.lastPathComponent)],boundary:boundary)}
    private enum Marker:Error{case injected}
    private final class Fault {var target:DeviceLocalProvisioningIntentStore.Boundary?;var hit=false}
    func testEmptyPlanOneUnresolvedAndRestartEpoch()throws {
        let p=try plan(),r=try root(),a=store(r);XCTAssertThrowsError(try a.stageExact(p));try a.initializeExplicit()
        let old=try a.stageExact(p);XCTAssertNoThrow(try a.verify(old));XCTAssertEqual(try a.inspectPendingExact()?.exactIntentBytes,p.canonicalBytes)
        XCTAssertThrowsError(try a.stageExact(p));XCTAssertThrowsError(try a.recommitExact(plan(11)))
        let b=store(r),repaired=try b.recommitExact(p);XCTAssertNoThrow(try b.verify(repaired));XCTAssertThrowsError(try a.verify(old))
    }
    func testHeadAndProofReplacementOrRemovalBlockRestart()throws {
        for name in ["head.json","root-binding.json","genesis.json","operations/"+id(10).uuidString.lowercased()+".confirm.json"] {
            for remove in [true,false] {
                let r=try root(),p=try plan(),s=store(r);try s.initializeExplicit();_ = try s.stageExact(p)
                let path=r.appendingPathComponent(name),bytes=try Data(contentsOf:path)
                if !remove {let tmp=path.appendingPathExtension("external");try bytes.write(to:tmp);try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:tmp,to:path)}else{try FileManager.default.removeItem(at:path)}
                XCTAssertThrowsError(try store(r).recommitExact(p),name)
            }
        }
    }
    func testStageSynchronizationBoundariesExactRetry()throws {
        for kind in [DeviceLocalProvisioningIntentStore.Kind.intent,.attempt,.head,.confirmation] {
            for point in [DeviceLocalProvisioningIntentStore.Boundary.afterWrite(kind),.afterFileSync(kind),.beforeReplace(kind),.afterReplace(kind),.afterDirectorySync(kind)] {
                let r=try root(),p=try plan(),f=Fault(),s=store(r,boundary:{b in if f.target == b{f.target=nil;f.hit=true;throw Marker.injected}})
                try s.initializeExplicit();f.target=point;XCTAssertThrowsError(try s.stageExact(p));XCTAssertTrue(f.hit,String(describing:point))
                let restart=store(r)
                let unboundCreation = (kind == .intent || kind == .head) && (point == .afterWrite(kind) || point == .afterFileSync(kind))
                if unboundCreation {
                    XCTAssertThrowsError(try restart.recommitExact(p))
                    let receipt=try s.recommitExact(p);XCTAssertNoThrow(try s.verify(receipt))
                } else {let receipt=try restart.recommitExact(p);XCTAssertNoThrow(try restart.verify(receipt))}
            }
        }
    }
    func testInitializationRenameUncertaintyRestartExactRepair()throws {
        for kind in [DeviceLocalProvisioningIntentStore.Kind.binding,.genesis,.head] {
            let r=try root(),f=Fault();f.target = .afterReplace(kind)
            let s=store(r,boundary:{b in if f.target == b{f.target=nil;f.hit=true;throw Marker.injected}})
            XCTAssertThrowsError(try s.initializeExplicit());XCTAssertTrue(f.hit)
            let next=store(r);XCTAssertThrowsError(try next.stageExact(plan()));try next.initializeExplicit();XCTAssertNoThrow(try next.stageExact(plan()))
        }
    }
    func testUnknownPartialCreationPreservedAndBlocked()throws {
        let r=try root(),f=Fault(),s=store(r,boundary:{b in if f.target == b{f.target=nil;throw Marker.injected}})
        try s.initializeExplicit();f.target = .afterCreate(.intent);XCTAssertThrowsError(try s.stageExact(plan()))
        let files=try FileManager.default.subpathsOfDirectory(atPath:r.path)
        XCTAssertThrowsError(try store(r).recommitExact(plan()));XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath:r.path),files)
        XCTAssertNoThrow(try s.recommitExact(plan()))
    }
    func testStrictUnknownDuplicateBounds()throws {
        let text=String(decoding:try plan().canonicalBytes,as:UTF8.self)
        for prefix in ["{\"unknown\":1,","{\"schemaVersion\":1,"]{XCTAssertThrowsError(try ProvisioningIntentCodec.decode(Data((prefix+text.dropFirst()).utf8)))}
        XCTAssertThrowsError(try ProvisioningIntentCodec.decode(Data(repeating:32,count:ProvisioningIntentCodec.limit+1)))
        XCTAssertThrowsError(try ProvisioningIntentCodec.decode(Data((text+"x").utf8)))
    }
    func testProtectedSentinelAndNestedEntry()throws {
        let r=try root(),sentinel=r.appendingPathComponent("sentinel");try Data("keep".utf8).write(to:sentinel)
        XCTAssertThrowsError(try DeviceLocalProvisioningIntentStore(root:r,rootID:id(1),protectedRoots:[r]).initializeExplicit());XCTAssertEqual(try Data(contentsOf:sentinel),Data("keep".utf8))
        let clean=try root();var s:DeviceLocalProvisioningIntentStore!;var hook=false
        s=store(clean,boundary:{_ in if hook{hook=false;XCTAssertThrowsError(try s.inspectPendingExact())}})
        try s.initializeExplicit();hook=true;XCTAssertNoThrow(try s.stageExact(plan()));XCTAssertFalse(hook)
    }
    func testAllInitializationFileBoundariesRepairAndCreationResidue()throws {
        for kind in [DeviceLocalProvisioningIntentStore.Kind.binding,.genesis,.head] {
            for point in [DeviceLocalProvisioningIntentStore.Boundary.afterCreate(kind),.afterWrite(kind),.afterFileSync(kind),.beforeReplace(kind),.afterReplace(kind),.afterDirectorySync(kind)] {
                let r=try root(),f=Fault();f.target=point
                let s=store(r,boundary:{b in if f.target == b{f.target=nil;f.hit=true;throw Marker.injected}})
                XCTAssertThrowsError(try s.initializeExplicit());XCTAssertTrue(f.hit,String(describing:point))
                try s.initializeExplicit();XCTAssertNoThrow(try s.stageExact(plan()))
            }
        }
    }
    func testMissingAttemptAndSharedSameTipEpochBlock()throws {
        let r=try root(),p=try plan(),a=store(r);try a.initializeExplicit();let first=try a.stageExact(p)
        let b=store(r);_ = try b.recommitExact(p);XCTAssertThrowsError(try a.verify(first))
        try FileManager.default.removeItem(at:r.appendingPathComponent("operations/"+id(10).uuidString.lowercased()+".binding.json"))
        XCTAssertThrowsError(try store(r).recommitExact(p))
    }
    #if canImport(CryptoKit)
    private func encode<T:Encodable>(_ value:T)throws->Data{let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)}
    private func hash(_ bytes:Data)->String{SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    private func package()throws->QualifiedDevicePackage {
        let file=Data("<html></html>".utf8)
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:id(30).uuidString.lowercased(),name:"Package",revision:id(31).uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[.init(alias:"api",required:false,operations:[.init(name:"read",kind:"http")])],files:[.init(path:"index.html",bytes:file.count,sha256:hash(file))])
        manifest.digest=hash(try encode(manifest))
        let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        return try DevicePackageQualifier.qualify(.init(manifest:encode(manifest),files:[.init(path:"index.html",bytes:file)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
    }
    func testGenuineExpectedReferenceCompletePrivateGrantAndSecretExclusion()throws {
        let package=try package(),expected=try PackagePreparationCodec.expectedReference(.init(operationID:id(32),package:package),rootID:id(3))
        let secret=Data("PRIVATE_PROVISIONING_CANARY".utf8),grant=ConnectionGrant(schemaVersion:1,id:id(34),alias:"api",origin:"https://example.com",transport:.http,authRef:"logical",lan:false,allowInsecureHTTP:false,operations:[.init(name:"read",kind:.http,method:.GET,path:"/states",idempotent:true,write:false)])
        let config=ConnectionProvisioning(dashboardId:package.revision.dashboardId,revision:package.revision.revision,provisioningId:"explicit",entries:[.init(grant:grant,binding:.init(authRef:"logical",placement:.bearer),secret:secret)])
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(5)),owner:owner,entries:[.init(entryID:id(33),revision:package.revision,generic:config,homeAssistant:nil,publicReads:nil,credentialReferences:[.init(credentialRevisionID:id(35),kind:.generic,key:"logical")])],credentials:[.init(revisionID:id(35),bytes:secret)],retainedRevisions:[])
        let expectations=[DeviceGrantEntryExpectation(entryID:id(33),package:package)],qualified=try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:expectations)
        let request=DeviceProvisioningPlanRequest(roots:.init(journalID:id(1),structuralID:id(2),packageID:id(3),grantID:id(4)),operationID:id(10),grantOperationID:id(6),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:nil),snapshot:.init(generationID:id(7),entries:[.init(entryID:id(33),displayName:"Household",revision:package.revision,packageDirectory:expected.directory)],configuredEntryID:id(33),contentOwner:owner,grantSet:nil),owner:owner,packages:[.supplied(entryID:id(33),operationID:id(32),package:package)],grantInput:input,qualifiedGrant:qualified)
        func replacing(snapshot:DeviceStructuralSnapshot?=nil,owner:PairingIdentity?=nil,baseline:DeviceLocalCompleteSetBaseline?=nil,packages:[DeviceProvisioningPackageInput]?=nil)->DeviceProvisioningPlanRequest {
            .init(roots:request.roots,operationID:request.operationID,grantOperationID:request.grantOperationID,expectedGenerationID:request.expectedGenerationID,baseline:baseline ?? request.baseline,snapshot:snapshot ?? request.snapshot,owner:owner ?? request.owner,packages:packages ?? request.packages,grantInput:request.grantInput,qualifiedGrant:request.qualifiedGrant)
        }
        var noSelection=request.snapshot;noSelection.configuredEntryID=nil
        XCTAssertThrowsError(try DeviceProvisioningPlanner.qualify(replacing(snapshot:noSelection)))
        XCTAssertThrowsError(try DeviceProvisioningPlanner.qualify(replacing(owner:.init(role:.controller,publicKey:[UInt8](repeating:8,count:32)))))
        XCTAssertThrowsError(try DeviceProvisioningPlanner.qualify(replacing(baseline:.initialExplicit(legacyGrantSet:"changed"))))
        XCTAssertThrowsError(try DeviceProvisioningPlanner.qualify(replacing(packages:[.supplied(entryID:id(99),operationID:id(32),package:package)])))
        var oversized=request.snapshot;oversized.entries=[.init(entryID:id(33),displayName:String(repeating:"x",count:257),revision:package.revision,packageDirectory:expected.directory)]
        XCTAssertThrowsError(try DeviceProvisioningPlanner.qualify(replacing(snapshot:oversized)))
        let p=try DeviceProvisioningPlanner.qualify(request),body=try ProvisioningIntentCodec.decode(p.canonicalBytes)
        let v2=try DeviceProvisioningPrivateAttemptV2.encoded(.init(operationID:id(6),input:input,qualified:qualified,expectedEntries:expectations),intent:p.canonicalBytes)
        XCTAssertEqual(v2.count,body.privateAttemptByteCount)
        XCTAssertFalse(p.canonicalBytes.range(of:secret) != nil);XCTAssertFalse(String(decoding:body.grantPublicMetadata,as:UTF8.self).contains(secret.base64EncodedString()))
        let r=try root(),s=store(r);try s.initializeExplicit();_ = try s.stageExact(p)
        for name in try FileManager.default.subpathsOfDirectory(atPath:r.path) where name != "operations" {
            let bytes=try Data(contentsOf:r.appendingPathComponent(name));XCTAssertNil(bytes.range(of:secret));XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains(secret.base64EncodedString()))
        }
        let actualRoot=try root(),scope=DevicePackageProtectedScope(legacyStateRoot:actualRoot.appendingPathComponent("legacy"),legacyArchiveRoot:actualRoot.appendingPathComponent("archive"),resetRoot:actualRoot.appendingPathComponent("reset"),cloudRoot:actualRoot.appendingPathComponent("cloud"),managementRoot:actualRoot.appendingPathComponent("management"),preferencesRoot:actualRoot.appendingPathComponent("preferences"),otherProtectedRoots:[])
        let packageRoot=actualRoot.appendingPathComponent("packages");try FileManager.default.createDirectory(at:packageRoot,withIntermediateDirectories:false)
        let ps=DevicePackagePreparationStore(root:packageRoot,rootID:id(3),protectedScope:scope);try ps.initializeExplicit()
        let actual=try ps.prepareExact(.init(operationID:id(32),package:package));XCTAssertTrue(DeviceProvisioningPlanner.exactReference(actual.reference,expected))
    }
    #endif

    func testInitialQualificationEpochAndUnknownRootResidueBlock()throws {
        let r=try root(),a=store(r);try a.initializeExplicit();let b=store(r);try b.initializeExplicit()
        XCTAssertThrowsError(try a.stageExact(plan()));XCTAssertNoThrow(try b.stageExact(plan()))
        for name in ["root-binding.json.stage","genesis.json.stage"] {
            let bytes=Data("unknown".utf8),path=r.appendingPathComponent(name);try bytes.write(to:path)
            XCTAssertThrowsError(try b.recommitExact(plan()));XCTAssertEqual(try Data(contentsOf:path),bytes)
            try FileManager.default.removeItem(at:path) // test-owned hostile fixture only
        }
    }

    func testMetadataIdentityOwnerAndNestedUnknownCannotRebindIntent()throws {
        let p=try plan(),body=try ProvisioningIntentCodec.decode(p.canonicalBytes)
        var metadata=try XCTUnwrap(JSONSerialization.jsonObject(with:body.grantPublicMetadata) as? [String:Any])
        metadata["identity"]=["rootID":id(99).uuidString,"revisionID":id(5).uuidString]
        let changed=ProvisioningIntentBody(schemaVersion:body.schemaVersion,roots:body.roots,operationID:body.operationID,grantOperationID:body.grantOperationID,grantIdentity:body.grantIdentity,expectedOld:body.expectedOld,candidate:body.candidate,grantPublicMetadata:try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]),privateAttemptByteCount:body.privateAttemptByteCount)
        XCTAssertThrowsError(try ProvisioningIntentCodec.decode(ProvisioningIntentCodec.encode(changed)))
        let text=String(decoding:p.canonicalBytes,as:UTF8.self)
        let malformed=text.replacingOccurrences(of:"\"roots\":{",with:"\"roots\":{\"unknown\":1,")
        XCTAssertThrowsError(try ProvisioningIntentCodec.decode(Data(malformed.utf8)))
    }

    func testProtectedAliasIsRejectedBeforeSetupEffects()throws {
        let r=try root(),alias=r.deletingLastPathComponent().appendingPathComponent(r.lastPathComponent+"-alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:r)
        addTeardownBlock{try? FileManager.default.removeItem(at:alias)}
        let s=DeviceLocalProvisioningIntentStore(root:r,rootID:id(1),protectedRoots:[alias])
        XCTAssertThrowsError(try s.initializeExplicit());XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:r.path).isEmpty)
    }

    private struct FileEvidence:Equatable {let inode:UInt64,device:UInt64;let bytes:Data}
    private func evidence(_ root:URL)throws->[String:FileEvidence] {
        var result:[String:FileEvidence]=[:]
        for name in try FileManager.default.subpathsOfDirectory(atPath:root.path) where name != "operations" {
            let path=root.appendingPathComponent(name);var node=stat()
            guard lstat(path.path,&node) == 0 else{throw Marker.injected}
            result[name]=FileEvidence(inode:UInt64(node.st_ino),device:UInt64(node.st_dev),bytes:try Data(contentsOf:path))
        }
        return result
    }
    func testChangedSameOperationBeforeAttemptCannotReplaceOriginal()throws {
        for point in [DeviceLocalProvisioningIntentStore.Boundary.afterCreate(.intent),.afterWrite(.intent)] {
            let r=try root(),f=Fault(),s=store(r,boundary:{b in if f.target == b{f.target=nil;throw Marker.injected}})
            try s.initializeExplicit();let original=try plan(),changed=try plan(generation:8)
            XCTAssertNotEqual(original.canonicalBytes,changed.canonicalBytes);XCTAssertEqual(original.canonicalBytes.count,changed.canonicalBytes.count)
            f.target=point;XCTAssertThrowsError(try s.stageExact(original))
            let before=try evidence(r)
            XCTAssertThrowsError(try s.recommitExact(changed),"Changed genuinely qualified plan reused live same-op inode: \(point)")
            XCTAssertEqual(try evidence(r),before)
            let receipt=try s.recommitExact(original)
            XCTAssertNoThrow(try s.verify(receipt));XCTAssertEqual(try s.inspectPendingExact()?.exactIntentBytes,original.canonicalBytes)
            let qualified=try evidence(r)
            XCTAssertThrowsError(try s.recommitExact(changed))
            XCTAssertEqual(try evidence(r),qualified);XCTAssertNoThrow(try s.verify(receipt)) // Original epoch/qualification unchanged.
            let again=try s.recommitExact(original);XCTAssertNoThrow(try s.verify(again))
        }
    }

    func testURLKindsAndProtectedCountRejectBeforeSetup()throws {
        for invalid in ["root","protected","count"] {
            let owned=try root()
            var components=URLComponents();components.scheme="https";components.host="example.invalid";components.path=owned.path
            let nonFileRoot=try XCTUnwrap(components.url)
            components.path=owned.deletingLastPathComponent().appendingPathComponent("protected-"+owned.lastPathComponent).path
            let nonFileProtected=try XCTUnwrap(components.url)
            XCTAssertFalse(nonFileRoot.isFileURL);XCTAssertEqual(nonFileRoot.path,owned.path)
            let protectedURLs:[URL]
            if invalid == "count" {protectedURLs=(0..<33).map{owned.deletingLastPathComponent().appendingPathComponent("protected-\($0)-"+owned.lastPathComponent)}}
            else if invalid == "protected" {protectedURLs=[nonFileProtected]}
            else {protectedURLs=[]}
            let s=DeviceLocalProvisioningIntentStore(root:invalid == "root" ? nonFileRoot:owned,rootID:id(1),protectedRoots:protectedURLs)
            XCTAssertThrowsError(try s.initializeExplicit(),"Non-file URL treated as local filesystem input: \(invalid)")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:owned.path).isEmpty,"Invalid input created journal files: \(invalid)")
        }
        let valid=try root(),s=store(valid);try s.initializeExplicit();XCTAssertNoThrow(try s.stageExact(plan()))
    }

}
