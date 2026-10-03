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

final class DeviceLocalCompleteSetTransactionTests: XCTestCase {
    private final class Backend: DeviceGrantCredentialBackend, @unchecked Sendable {
        var values: [String:DeviceGrantCredentialValue] = [:], adds = 0
        func inventory(service:String,maximum:Int,visit:(DeviceGrantCredentialItem)throws->Void)throws { for key in values.keys.sorted() { try visit(values[key]!.item) } }
        func read(service:String,account:String,maximumBytes:Int)throws->DeviceGrantCredentialValue? { values[account] }
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
        for name in ["packages","grants","legacy","archive","reset","cloud","management","preferences"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:false) }
        return (root,.init(legacyStateRoot:root.appendingPathComponent("legacy"),legacyArchiveRoot:root.appendingPathComponent("archive"),resetRoot:root.appendingPathComponent("reset"),cloudRoot:root.appendingPathComponent("cloud"),managementRoot:root.appendingPathComponent("management"),preferencesRoot:root.appendingPathComponent("preferences"),otherProtectedRoots:[]))
    }
    private struct Fixture {
        let root:URL; let packages:DevicePackagePreparationStore; let grants:DeviceGrantPreparationStore; let backend:Backend
        let request:DeviceLocalCompleteSetRequest
        var coordinator:DeviceLocalCompleteSetCoordinator { .init(packageStore:packages,grantStore:grants) }
    }
    private func replacing(_ r:DeviceLocalCompleteSetRequest,snapshot:DeviceStructuralSnapshot?=nil,baseline:DeviceLocalCompleteSetBaseline?=nil,
                           expected:UUID??=nil,packages:[DeviceLocalCompleteSetPackageBinding]?=nil,grant:DeviceGrantPreparationRequest?=nil,
                           owner:PairingIdentity?=nil)->DeviceLocalCompleteSetRequest {
        .init(structuralRootID:r.structuralRootID,operationID:r.operationID,expectedGenerationID:expected ?? r.expectedGenerationID,
            baseline:baseline ?? r.baseline,snapshot:snapshot ?? r.snapshot,packages:packages ?? r.packages,
            grantReceipt:r.grantReceipt,grantRequest:grant ?? r.grantRequest,owner:owner ?? r.owner)
    }
    private func fixtureEmpty()throws->Fixture {
        let env = try environment(), backend = Backend()
        let packages = DevicePackagePreparationStore(root:env.0.appendingPathComponent("packages"),rootID:id(1),protectedScope:env.1)
        let grants = DeviceGrantPreparationStore(root:env.0.appendingPathComponent("grants"),rootID:id(2),protectedScope:env.1,backend:backend)
        try packages.initializeExplicit(); try grants.initializeExplicit()
        let input = DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(3)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        let grant = DeviceGrantPreparationRequest(operationID:id(4),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
        let receipt = try grants.prepareExact(grant)
        return .init(root:env.0,packages:packages,grants:grants,backend:backend,request:.init(structuralRootID:id(5),operationID:id(6),expectedGenerationID:nil,
            baseline:.initialExplicit(legacyGrantSet:"opaque-legacy"),snapshot:.init(generationID:id(7),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque-legacy"),packages:[],grantReceipt:receipt,grantRequest:grant,owner:owner))
    }
    func testExplicitEmptySetIsReadOnlyAndCarriesSeparateIdentities()throws {
        let f = try fixtureEmpty(), adds = f.backend.adds
        let before = try Data(contentsOf:f.root.appendingPathComponent("grants/head.json"))
        let result = try f.coordinator.observeSequentially(f.request)
        XCTAssertEqual(result.references.grants.identity,f.request.grantRequest.input.identity)
        XCTAssertEqual(result.references.structuralRootID,id(5)); XCTAssertEqual(result.references.generationID,id(7))
        XCTAssertEqual(result.observedSnapshot.grantSet,"opaque-legacy"); XCTAssertNil(result.observedSnapshot.configuredEntryID)
        XCTAssertNil(result.expectedOldEnvelopeBytes); XCTAssertTrue(result.references.packages.isEmpty)
        XCTAssertEqual(f.backend.adds,adds); XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent("grants/head.json")),before)
        XCTAssertFalse(String(decoding:result.candidateEnvelopeBytes,as:UTF8.self).contains("credentials"))
    }
    func testEmptyOwnerSelectionBaselineAndPreCopyBounds()throws {
        let f = try fixtureEmpty(); var snapshot = f.request.snapshot
        snapshot.contentOwner = nil; XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,snapshot:snapshot)))
        snapshot = f.request.snapshot; snapshot.configuredEntryID = id(999); XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,snapshot:snapshot)))
        XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,owner:.init(role:.controller,publicKey:[UInt8](repeating:8,count:32)))))
        XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,baseline:.initialExplicit(legacyGrantSet:"changed"))))
        XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,baseline:.expectedEnvelope(Data(repeating:1,count:128*1024+1)))))
        snapshot = f.request.snapshot; snapshot.grantSet = String(repeating:"x",count:257); XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,snapshot:snapshot)))
        snapshot = f.request.snapshot; snapshot.entries = (0..<13).map { .init(entryID:id($0+200),displayName:"n",revision:.init(revision:"r",dashboardId:"d",name:"n",digest:"h",orientation:.portrait,width:1,height:1),packageDirectory:"package") }
        XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,snapshot:snapshot)))
    }
    func testExactReadOnlyGrantBindingRejectsOperationRevisionAndRootChanges()throws {
        let f = try fixtureEmpty(), original = f.request.grantRequest
        for change in 0..<3 {
            let input = DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:change == 0 ? id(90):original.input.identity.rootID,revisionID:change == 1 ? id(91):original.input.identity.revisionID),owner:owner,entries:[],credentials:[],retainedRevisions:[])
            let changed = DeviceGrantPreparationRequest(operationID:change == 2 ? id(92):original.operationID,input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
            XCTAssertThrowsError(try f.grants.verify(f.request.grantReceipt,exactRequest:changed,expectedEntries:[]))
        }
        XCTAssertNoThrow(try f.grants.verify(f.request.grantReceipt,exactRequest:original,expectedEntries:[]))
    }
    func testChangedGrantInventoryInvalidatesSequentialObservation()throws {
        let f = try fixtureEmpty(); XCTAssertNoThrow(try f.coordinator.observeSequentially(f.request))
        let account = f.backend.values.keys.first!; let prior = f.backend.values[account]!
        f.backend.values[account] = .init(item:.init(account:account,persistentReference:Data("replaced".utf8),byteCount:prior.bytes.count),bytes:prior.bytes)
        XCTAssertThrowsError(try f.coordinator.observeSequentially(f.request))
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
        return .init(root:empty.root,packages:empty.packages,grants:empty.grants,backend:empty.backend,request:.init(structuralRootID:id(5),operationID:id(403),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:nil),snapshot:.init(generationID:id(404),entries:entries,configuredEntryID:id(20),contentOwner:owner,grantSet:nil),packages:bindings,grantReceipt:receipt,grantRequest:request,owner:owner))
    }
    func testGenuinePackagesCompleteSharedGrantRevisionAndSecretFreeCandidate()throws {
        let f=try populated(),result=try f.coordinator.observeSequentially(f.request)
        XCTAssertEqual(result.references.packages.map(\.entryID),[id(10),id(20)]);XCTAssertEqual(result.observedSnapshot.configuredEntryID,id(20))
        XCTAssertEqual(result.observedSnapshot.entries[0].displayName,"Household 10")
        XCTAssertFalse(String(decoding:result.candidateEnvelopeBytes,as:UTF8.self).contains("PRIVATE_TRANSACTION_CANARY"))
        XCTAssertFalse(String(decoding:result.candidateEnvelopeBytes,as:UTF8.self).contains(Data("PRIVATE_TRANSACTION_CANARY".utf8).base64EncodedString()))
        var snapshot=f.request.snapshot;snapshot.configuredEntryID=id(999);XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,snapshot:snapshot)))
        snapshot=f.request.snapshot;snapshot.entries[0].revision.name="wrong";XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,snapshot:snapshot)))
        XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,packages:Array(f.request.packages.prefix(1)))))
    }
    func testEqualPublicProjectionAlteredSecretCannotBindReceipt()throws {
        let f=try populated(),original=f.request.grantRequest,secret=Data("DIFFERENT_TRANSACTION_SECRET".utf8)
        let entries=original.input.entries.map { entry -> DeviceGrantEntryInput in
            var generic=entry.generic!;generic.entries[0].secret=secret
            return .init(entryID:entry.entryID,revision:entry.revision,generic:generic,homeAssistant:nil,publicReads:nil,credentialReferences:entry.credentialReferences)
        }
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:original.input.identity,owner:owner,entries:entries,credentials:[.init(revisionID:id(400),bytes:secret)],retainedRevisions:original.input.retainedRevisions)
        let qualified=try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:original.expectedEntries)
        XCTAssertEqual(qualified.publicMetadataBytes,original.qualified.publicMetadataBytes)
        let altered=DeviceGrantPreparationRequest(operationID:original.operationID,input:input,qualified:qualified,expectedEntries:original.expectedEntries)
        let adds=f.backend.adds;XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,grant:altered)));XCTAssertEqual(f.backend.adds,adds)
        XCTAssertNoThrow(try f.coordinator.observeSequentially(f.request))
    }
    func testLegacyGrantSetExactPreservationAndExpectedGeneration()throws {
        let f=try populated(),first=try f.coordinator.observeSequentially(f.request)
        var oldSnapshot=f.request.snapshot;oldSnapshot.generationID=id(500);oldSnapshot.grantSet="e\u{301}"
        let old=try encode(DeviceStructuralCommitEnvelope(operationID:id(501),expectedGenerationID:nil,snapshot:oldSnapshot,intent:Data(),outcome:Data()))
        var snapshot=f.request.snapshot;snapshot.grantSet="e\u{301}"
        let request=replacing(f.request,snapshot:snapshot,baseline:.expectedEnvelope(old),expected:.some(id(500)))
        let result=try f.coordinator.observeSequentially(request);XCTAssertEqual(result.expectedOldEnvelopeBytes,old)
        snapshot.grantSet="é";XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(request,snapshot:snapshot)))
        XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(request,expected:.some(id(999)))))
        XCTAssertLessThan(first.candidateEnvelopeBytes.count,128*1024)
        let decoded=try StructuralStoreCodec.envelope(first.candidateEnvelopeBytes);XCTAssertLessThan(decoded.intent.count,32*1024);XCTAssertLessThan(decoded.outcome.count,32*1024)
    }
    func testGenuineExpectationsReplaceCallerExpectationsAndExpansionIsBounded()throws {
        let f=try populated(),original=f.request.grantRequest
        let mismatched=[DeviceGrantEntryExpectation(entryID:id(10),package:try package(99)),original.expectedEntries[1]]
        XCTAssertThrowsError(try f.grants.verify(f.request.grantReceipt,exactRequest:original,expectedEntries:mismatched))
        var snapshot=f.request.snapshot
        snapshot.entries[0].displayName=String(repeating:"\"",count:256)
        let observed=try f.coordinator.observeSequentially(replacing(f.request,snapshot:snapshot))
        let envelope=try StructuralStoreCodec.envelope(observed.candidateEnvelopeBytes)
        XCTAssertEqual(envelope.snapshot.entries[0].displayName,snapshot.entries[0].displayName)
        XCTAssertLessThanOrEqual(envelope.intent.count,32*1024);XCTAssertLessThanOrEqual(envelope.outcome.count,32*1024)
        XCTAssertLessThanOrEqual(observed.candidateEnvelopeBytes.count,128*1024)
        let repeated=Array(repeating:f.request.packages[0],count:13)
        XCTAssertThrowsError(try f.coordinator.observeSequentially(replacing(f.request,packages:repeated)))
    }
    func testPreparedPackageReplacementInvalidatesObservation()throws {
        let f=try populated();XCTAssertNoThrow(try f.coordinator.observeSequentially(f.request))
        let ref=f.request.packages[0].receipt.reference
        let path=f.root.appendingPathComponent("packages/\(ref.directory)/index.html"),bytes=try Data(contentsOf:path),temp=path.appendingPathExtension("replacement")
        try bytes.write(to:temp);try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:temp,to:path)
        XCTAssertThrowsError(try f.coordinator.observeSequentially(f.request))
    }
    #endif
}
