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
@_spi(ManagedRender) @_spi(NativeInstallation) @testable import ScreenpunkCore

final class DeviceNativeDeliveryExecutionTests: XCTestCase {
    #if canImport(CryptoKit) && (os(iOS) || os(macOS))
    private func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    private func encode<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)}
    private struct Fixture {let files:[(String,Data)],expected:DevicePackageExpectation,manifest:Data}
    private func fixture(generic:Bool=false)throws->Fixture {
        let html=Data("<html><body>actual bounded ZIP fixture</body></html>".utf8)
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:UUID().uuidString.lowercased(),name:"ZIP fixture",revision:UUID().uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:generic ? [.init(alias:"api",required:false,operations:[.init(name:"read",kind:"http")])]:[],files:[.init(path:"index.html",bytes:html.count,sha256:hash(html))])
        manifest.digest=hash(try encode(manifest));let raw=try encode(manifest)
        let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        return .init(files:[("manifest.json",raw),("index.html",html)],expected:.init(revision:revision,target:.init(deviceId:"fixture",name:"Fixture"),profileID:"profile"),manifest:raw)
    }
    private func crc(_ bytes:Data)->UInt32 {
        var value:UInt32=0xffffffff
        for b in bytes {value ^= UInt32(b);for _ in 0..<8{value=value & 1 == 1 ? (value >> 1) ^ 0xedb88320:value >> 1}}
        return value ^ 0xffffffff
    }
    private func word(_ value:UInt16)->Data {Data([UInt8(truncatingIfNeeded:value),UInt8(truncatingIfNeeded:value >> 8)])}
    private func long(_ value:UInt32)->Data {Data([UInt8(truncatingIfNeeded:value),UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value >> 16),UInt8(truncatingIfNeeded:value >> 24)])}
    /// Genuine raw DEFLATE stored block inside ZIP method8. Uses no external dependency or
    /// production decompressor to construct the fixture; CRC is independent test arithmetic.
    private func deflated(_ bytes:Data)->Data {
        precondition(bytes.count <= 65535)
        let n=UInt16(bytes.count);var out=Data([1]);out.append(word(n));out.append(word(~n));out.append(bytes);return out
    }
    private func zip(_ files:[(String,Data)],method:UInt16=0,descriptor:Bool=false,
        flagsOverride:UInt16?=nil,mode:UInt32=0x81a4,trailingCompressed:Bool=false)throws->Data {
        var locals=Data(),central=Data();let flags=flagsOverride ?? (descriptor ? 0x808:0x800)
        for(path,raw)in files {
            let name=Data(path.utf8),offset=UInt32(locals.count),checksum=crc(raw)
            var payload=method == 8 ? deflated(raw):raw
            if trailingCompressed {payload.append(0)}
            locals.append(long(0x04034b50));locals.append(word(20));locals.append(word(flags));locals.append(word(method));locals.append(word(0));locals.append(word(0))
            locals.append(long(descriptor ? 0:checksum));locals.append(long(descriptor ? 0:UInt32(payload.count)));locals.append(long(descriptor ? 0:UInt32(raw.count)))
            locals.append(word(UInt16(name.count)));locals.append(word(0));locals.append(name);locals.append(payload)
            if descriptor {locals.append(long(0x08074b50));locals.append(long(checksum));locals.append(long(UInt32(payload.count)));locals.append(long(UInt32(raw.count)))}
            central.append(long(0x02014b50));central.append(word(0x314));central.append(word(20));central.append(word(flags));central.append(word(method));central.append(word(0));central.append(word(0));central.append(long(checksum));central.append(long(UInt32(payload.count)));central.append(long(UInt32(raw.count)));central.append(word(UInt16(name.count)));central.append(word(0));central.append(word(0));central.append(word(0));central.append(word(0));central.append(long(mode << 16));central.append(long(offset));central.append(name)
        }
        let offset=UInt32(locals.count),size=UInt32(central.count);locals.append(central)
        locals.append(long(0x06054b50));locals.append(word(0));locals.append(word(0));locals.append(word(UInt16(files.count)));locals.append(word(UInt16(files.count)));locals.append(long(size));locals.append(long(offset));locals.append(word(0));return locals
    }
    private func descriptor(_ bytes:Data,_ fixture:Fixture,files:[(String,Data)]?=nil,
        manifestHash:String?=nil,expanded:UInt64?=nil,entries:UInt64?=nil,archiveHash:String?=nil)throws->DeviceDeliveryPackageCandidate {
        let fs=files ?? fixture.files
        return try .validating(packageProfile:DeviceDeliveryPackageCandidate.profile,publicationID:UUID(),projectID:UUID(),packageID:UUID(),dashboardID:UUID(uuidString:fixture.expected.revision.dashboardId)!,revision:UUID(uuidString:fixture.expected.revision.revision)!,manifestDigest:.validating(fixture.expected.revision.digest),manifestSHA256:.validating(manifestHash ?? hash(fixture.manifest)),archiveSHA256:.validating(archiveHash ?? hash(bytes)),compressedBytes:UInt64(bytes.count),expandedBytes:expanded ?? UInt64(fs.reduce(0){$0+$1.1.count}),archiveEntries:entries ?? UInt64(fs.count))
    }

    private enum TestFailure:Error {case failed}
    private final class Backend:DeviceGrantCredentialBackend,@unchecked Sendable {
        var values:[String:DeviceGrantCredentialValue]=[:]
        var adds=0
        func inventory(service:String,maximum:Int,visit:(DeviceGrantCredentialItem)throws->Void)throws {
            for item in values.values {try visit(item.item)}
        }
        func read(service:String,account:String,maximumBytes:Int)throws->DeviceGrantCredentialValue? {values[account]}
        func add(service:String,account:String,bytes:Data)throws->DeviceGrantCredentialItem {
            guard values[account] == nil else{throw TestFailure.failed};adds+=1
            let item=DeviceGrantCredentialItem(account:account,persistentReference:Data(UUID().uuidString.utf8),byteCount:bytes.count)
            values[account] = .init(item:item,bytes:bytes);return item
        }
    }
    private struct Engine {
        let stores:NativeDeliveryExecutionStoreBinding,backend:Backend
        let command:Data,header:String,plan:Data
        let nativeOperation:UUID,grantOperation:UUID,grantRevision:UUID
        let archives:[NativeDeliveryArchiveInput]
    }
    private func engine(count:Int=2,generic:Bool=false)throws->Engine {
        guard let physical=realpath(FileManager.default.temporaryDirectory.path,nil) else{throw TestFailure.failed};defer{free(physical)}
        let root=URL(fileURLWithPath:String(cString:physical)).appendingPathComponent("delivery-execution-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock{try FileManager.default.removeItem(at:root)}
        let paths=["packages","grants","structural","journal"].map{root.appendingPathComponent($0)}
        for path in paths {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)}
        let protected=["legacy","archive","reset","cloud","management","preferences"].map{root.appendingPathComponent($0)}
        let scope=DevicePackageProtectedScope(legacyStateRoot:protected[0],legacyArchiveRoot:protected[1],resetRoot:protected[2],cloudRoot:protected[3],managementRoot:protected[4],preferencesRoot:protected[5],otherProtectedRoots:[])
        let backend=Backend(),packages=DevicePackagePreparationStore(root:paths[0],rootID:UUID(),protectedScope:scope)
        let grants=DeviceNativeGrantPreparationStore(root:paths[1],rootID:UUID(),protectedPaths:scope.roots,backend:backend)
        let structural=DeviceStructuralStore(root:paths[2],rootID:UUID())
        let journal=DeviceLocalProvisioningIntentStore(root:paths[3],rootID:UUID(),protectedRoots:scope.roots)
        try packages.initializeExplicit();try grants.initializeExplicit();try structural.initializeExplicit();try journal.initializeExplicit()
        let owner=DeviceNativeInstallationContentOwner(installationID:UUID(),accountID:UUID(),locationID:UUID(),transitionID:UUID())
        let initial=try DeviceNativeStructuralState.validating(generationID:UUID(),owner:.nativeInstallation(owner),entries:[],configuredEntryID:nil)
        let genesis=try structural.initializeNativeGenesisExplicit(initial)
        var wire:[[String:Any]]=[],entries:[DeviceDeliveryEntryCandidate]=[],inputs:[NativeDeliveryArchiveInput]=[]
        for _ in 0..<count {
            let f=try fixture(generic:generic),archive=try zip(f.files,method:8,descriptor:true),d=try descriptor(archive,f),id=UUID()
            entries.append(.validating(entryID:id,provenance:.cloud(d)))
            wire.append(["entryId":id.uuidString.lowercased(),"provenance":["kind":"cloud","package":["packageProfile":DeviceDeliveryPackageCandidate.profile,"publicationId":d.publicationID.uuidString.lowercased(),"projectId":d.projectID.uuidString.lowercased(),"packageId":d.packageID.uuidString.lowercased(),"dashboardId":d.dashboardID.uuidString.lowercased(),"revision":d.revision.uuidString.lowercased(),"manifestDigest":d.manifestDigest.text,"manifestSha256":d.manifestSHA256.text,"archiveSha256":d.archiveSHA256.text,"compressedBytes":d.compressedBytes,"expandedBytes":d.expandedBytes,"archiveEntries":d.archiveEntries]]])
            inputs.append(.init(entryID:id,preparationOperationID:UUID(),archiveBytes:archive,profileID:f.expected.profileID,revisionName:f.expected.revision.name,target:f.expected.target))
        }
        let set=try DeviceResultingSetCandidate.validating(entries:entries,configuredEntryID:entries.first?.entryID)
        let raw=Data("original exact raw delivery plan".utf8)
        let association:[String:Any]=["schemaVersion":1,"operationId":UUID().uuidString.lowercased(),"planId":UUID().uuidString.lowercased(),"installationId":owner.installationID.uuidString.lowercased(),"accountId":owner.accountID.uuidString.lowercased(),"locationId":owner.locationID.uuidString.lowercased(),"transitionId":owner.transitionID.uuidString.lowercased(),"planDigest":hash(raw),"planByteLength":raw.count]
        var command=association;command["sequence"]="1";command["expectedInstalledSetGenerationId"]=initial.generationID.uuidString.lowercased();command["desiredSetGenerationId"]=UUID().uuidString.lowercased();command["executionExpiresAt"]="2026-10-05T20:00:00Z";command["resultingSetDigest"]=try DeviceDeliveryCandidateCodec.resultingSetDigest(set);command["resultingSet"]=["schemaVersion":1,"entries":wire,"configuredEntryId":entries[0].entryID.uuidString.lowercased()]
        let header=try JSONSerialization.data(withJSONObject:association).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        return .init(stores:.init(packages:packages,grants:grants,structural:structural,journal:journal,genesis:genesis),backend:backend,command:try JSONSerialization.data(withJSONObject:command),header:header,plan:raw,nativeOperation:UUID(),grantOperation:UUID(),grantRevision:UUID(),archives:inputs)
    }
    private func compile(_ e:Engine,archives:[NativeDeliveryArchiveInput]?=nil)throws->DeviceNativeProvisioningRequest {
        try NativeDeliveryExecutionSession.makeStaticRequest(stores:e.stores,command:e.command,associationHeader:e.header,rawPlan:e.plan,nativeOperationID:e.nativeOperation,grantOperationID:e.grantOperation,grantRevisionID:e.grantRevision,archives:archives ?? e.archives)
    }
    /// Real archive compiler and real fixed resource commands; no Cloud admission is manufactured.
    func testGenuineTwoArchiveStaticPreparationAndDurableReportingPipeline()throws {
        let e=try engine(),request=try compile(e),plan=try DeviceNativeProvisioningPlanner.qualify(request)
        XCTAssertEqual(e.backend.adds,0);XCTAssertEqual(request.candidate.entries.count,2)
        let attachment=try e.stores.journal.publishDeliveryAttachmentExact(request.delivery)
        let joined=try DeviceNativeProvisioningCoordinator(journal:e.stores.journal,structural:e.stores.structural).joinExact(request,plan:plan,attachment:attachment)
        let c=DeviceNativeGrantPrivateCoordinator(journal:e.stores.journal,structural:e.stores.structural,packages:e.stores.packages,grants:e.stores.grants)
        let resolution=try e.stores.packages.resolveRetainedTerminalExact([])
        let anchor=try c.prepareExact(request,plan:plan,joined:joined,packageResolution:resolution)
        let batch=try c.preparePackagesExact(request,anchor:anchor)
        let credentials=try c.completeCredentialsExact(request,batch:batch)
        let terminal=try c.closeNativeGrantExact(request,progress:credentials)
        XCTAssertEqual(e.backend.adds,1) // Genuine static private attempt, zero credential additions.
        let activation=try c.retainNativeActivationRequestExact(request,terminal:terminal,requestID:UUID())
        var response=try XCTUnwrap(JSONSerialization.jsonObject(with:activation.requestBytes) as? [String:Any])
        response["authorizationDigest"]=String(repeating:"a",count:64);response["authorizedAt"]="2026-10-05T20:00:00Z";response["expiresAt"]="2026-10-05T20:00:30Z"
        let authorization=try c.retainNativeAuthorizationExact(request,original:activation,response:JSONSerialization.data(withJSONObject:response))
        // Mechanical engine exercise only: production session requires the genuine owner capability.
        let structural=try c.commitNativeStructuralExact(request,terminal:terminal)
        let completed=try c.completeNativeProvisioningExact(request,original:structural)
        let outcome=try c.retainNativeActivatedReceiptExact(request,completed:completed,authorization:authorization)
        var ack=try XCTUnwrap(JSONSerialization.jsonObject(with:activation.requestBytes) as? [String:Any]);ack.removeValue(forKey:"activationRequestId");ack["outcome"]="activated";ack["receiptId"]=UUID().uuidString.lowercased();ack["receivedAt"]="2026-10-05T20:00:31Z"
        _=try c.retainNativeReceiptAcknowledgmentExact(request,outgoing:outcome,response:JSONSerialization.data(withJSONObject:ack))
        let content=try c.projectNativeCompletedStaticExact(request,completed:completed)
        XCTAssertEqual(content.operationID,request.delivery.nativeOperationID)
        XCTAssertEqual(content.generationID,request.candidate.generationID)
        XCTAssertEqual(content.entryID,request.candidate.configuredEntryID)
        XCTAssertTrue(content.assets.contains(where:{$0.path == content.entrypoint}))
        try content.verifyResources()
        XCTAssertEqual(e.backend.adds,1)
    }
    func testChangedArchiveAndDuplicateInputRejectBeforePrivateEffects()throws {
        let e=try engine();let first=e.archives[0]
        var changed=first.archiveBytes;changed[0]^=1
        let input=NativeDeliveryArchiveInput(entryID:first.entryID,preparationOperationID:first.preparationOperationID,archiveBytes:changed,profileID:first.profileID,revisionName:first.revisionName,target:first.target)
        XCTAssertThrowsError(try compile(e,archives:[input,e.archives[1]]))
        XCTAssertThrowsError(try compile(e,archives:[first,first]))
        XCTAssertEqual(e.backend.adds,0)
    }
    func testGenericCapabilityIsNotSilentlyAdmittedByStaticAdapter()throws {
        let e=try engine(count:1,generic:true)
        XCTAssertThrowsError(try compile(e)){XCTAssertEqual($0 as? NativeDeliveryExecutionError,.unsupportedCapabilities)}
        XCTAssertEqual(e.backend.adds,0)
    }
    #endif
}
