import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
@_spi(ManagedRender) @testable import ScreenpunkCore

final class DeviceManagedRenderTransportTests:XCTestCase {
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
        let url=URL(fileURLWithPath:String(cString:p)).appendingPathComponent("managed-render-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url
    }
    private func scope(_ root:URL)->DevicePackageProtectedScope {let p=root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-protected");return .init(legacyStateRoot:p.appendingPathComponent("state"),legacyArchiveRoot:p.appendingPathComponent("archive"),resetRoot:p.appendingPathComponent("reset"),cloudRoot:p.appendingPathComponent("cloud"),managementRoot:p.appendingPathComponent("management"),preferencesRoot:p.appendingPathComponent("preferences"),otherProtectedRoots:[])}
    private func grantStore(_ root:URL,_ backend:Backend,boundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in})->DeviceGrantPreparationStore {.init(root:root,rootID:id(4),protectedScope:scope(root),backend:backend,boundary:boundary)}
    private func journal(_ root:URL,boundary:@escaping(DeviceLocalProvisioningIntentStore.Boundary)throws->Void={_ in})->DeviceLocalProvisioningIntentStore {.init(root:root,rootID:id(1),protectedRoots:[root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-protected")],boundary:boundary)}
    private func request(generation:Int=7,revision:Int=5)throws->DeviceProvisioningPlanRequest {
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(revision)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        return .init(roots:roots,operationID:id(10),grantOperationID:id(6),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:"opaque"),snapshot:.init(generationID:id(generation),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:[],grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]))
    }
    private func files(_ root:URL)throws->[String:Data] {var result:[String:Data]=[:];for path in try FileManager.default.subpathsOfDirectory(atPath:root.path){var isDir:ObjCBool=false;let url=root.appendingPathComponent(path);if FileManager.default.fileExists(atPath:url.path,isDirectory:&isDir),!isDir.boolValue{result[path]=try Data(contentsOf:url)}};return result}
    private func packageStore(_ root:URL,boundary:@escaping(DevicePackagePreparationStore.Boundary)throws->Void={_ in})->DevicePackagePreparationStore {.init(root:root,rootID:id(3),protectedScope:scope(root),boundary:boundary)}
    private struct Fixture {
        let jr:URL,gr:URL,pr:URL,b:Backend,j:DeviceLocalProvisioningIntentStore,g:DeviceGrantPreparationStore,p:DevicePackagePreparationStore
        let r:DeviceProvisioningPlanRequest,plan:DeviceValidatedProvisioningPlan,c:DeviceBoundPackagePreparationCoordinator,completed:DeviceBoundCompletedCredentials
    }
    private func fixture(_ request:DeviceProvisioningPlanRequest,boundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in},prewarm:[DeviceProvisioningPackageInput]=[],predecessor:Bool=false,journalBoundary:@escaping(DeviceLocalProvisioningIntentStore.Boundary)throws->Void={_ in})throws->Fixture {
        let jr=try directory(),gr=try directory(),pr=try directory(),b=Backend(),j=journal(jr,boundary:journalBoundary),g=grantStore(gr,b,boundary:boundary),p=packageStore(pr),plan=try DeviceProvisioningPlanner.qualify(request)
        try j.initializeExplicit();try g.initializeExplicit();try p.initializeExplicit()
        if predecessor {_ = try g.prepareExact(freshV1())}
        for input in prewarm {guard case .supplied(_,let op,let value)=input else{throw Injected.fault};_ = try p.prepareExact(.init(operationID:op,package:value))}
        let receipt=try j.stageExact(plan),anchor=try DeviceBoundGrantAttemptCoordinator(journal:j,grants:g).stageExact(request,plan:plan,journalReceipt:receipt),c=DeviceBoundPackagePreparationCoordinator(journal:j,grants:g,packages:p)
        let batch=try c.preparePackagesExact(plan:plan,journalReceipt:receipt,privateAnchor:anchor,packages:request.packages),completed=try c.completeCredentialsExact(batch)
        return .init(jr:jr,gr:gr,pr:pr,b:b,j:j,g:g,p:p,r:request,plan:plan,c:c,completed:completed)
    }
    private func freshV1()throws->DeviceGrantPreparationRequest {
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(9000)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        return .init(operationID:id(9001),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
    }
    private func structural(_ root:URL,boundary:@escaping(DeviceStructuralStore.Boundary)throws->Void={_ in})->DeviceStructuralStore {.init(root:root,rootID:id(2),boundary:boundary)}
    private func commit(_ f:Fixture,_ store:DeviceStructuralStore)->DeviceLocalCompleteSetCommitCoordinator {.init(packageStore:f.p,grantStore:f.g,structuralStore:store)}
    private struct Ready {
        let f:Fixture,root:URL,store:DeviceStructuralStore,coordinator:DeviceLocalCompleteSetCommitCoordinator,terminal:DeviceBoundTerminalGrantReceipt,ack:DeviceLocalCompleteSetCommitAcknowledgment
    }
    private func ready(_ input:DeviceProvisioningPlanRequest?=nil,prewarm:[DeviceProvisioningPackageInput]=[],predecessor:Bool=false,structuralBoundary:@escaping(DeviceStructuralStore.Boundary)throws->Void={_ in},boundary:@escaping(DeviceLocalProvisioningIntentStore.Boundary)throws->Void={_ in},grantBoundary:@escaping(DeviceGrantPreparationStore.Boundary)throws->Void={_ in})throws->Ready {
        let f=try fixture(input ?? request(),boundary:grantBoundary,prewarm:prewarm,predecessor:predecessor,journalBoundary:boundary),root=try directory(),store=structural(root,boundary:structuralBoundary);try store.initializeExplicit()
        let coordinator=commit(f,store),terminal=try f.c.closeGrantTerminalExact(f.completed),ack=try coordinator.commitBoundTerminalExact(terminal,journal:f.j)
        return .init(f:f,root:root,store:store,coordinator:coordinator,terminal:terminal,ack:ack)
    }
    private func next(_ ack:DeviceLocalCompleteSetCommitAcknowledgment,n:Int=20)throws->DeviceProvisioningPlanRequest {
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(n+1)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        return .init(roots:roots,operationID:id(n),grantOperationID:id(n+2),expectedGenerationID:ack.generationID,baseline:.expectedEnvelope(ack.envelopeBytes),snapshot:.init(generationID:id(n+3),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:[],grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]))
    }
    private func completeFirst(_ ready:Ready)throws {
        let receipt=try ready.coordinator.completeProvisioningExact(ready.terminal,acknowledgment:ready.ack,journal:ready.f.j)
        try ready.f.j.verifyCompletion(receipt)
    }
    private func gate(_ r:Ready)->DeviceLocalResourceGate{.init(packageStore:r.f.p,grantStore:r.f.g,structuralStore:r.store)}
#if canImport(CryptoKit)
    private func staticRequest(count:Int=1,connections:[ManifestConnection]=[],behavior:DeviceBehavior?=nil)throws->DeviceProvisioningPlanRequest {
        func hash(_ d:Data)->String{SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()}
        var packages:[DeviceProvisioningPackageInput]=[],entries:[DeviceGrantEntryInput]=[],installed:[DeviceStructuralEntry]=[],expectations:[DeviceGrantEntryExpectation]=[]
        for n in 0..<count {
            let bytes=Data("<html><body>Static \(n)</body></html>".utf8)
            var manifest=DashboardManifest(schemaVersion:1,dashboardId:id(100+n).uuidString.lowercased(),name:"Static",revision:id(200+n).uuidString.lowercased(),entrypoint:"screen.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:connections,files:[.init(path:"screen.html",bytes:bytes.count,sha256:hash(bytes))])
            manifest.deviceBehavior=behavior;manifest.digest=hash(try GrantPreparationCodec.encode(manifest))
            let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:"Static",digest:manifest.digest!,orientation:.portrait,width:390,height:844)
            let package=try DevicePackageQualifier.qualify(.init(manifest:GrantPreparationCodec.encode(manifest),files:[.init(path:"screen.html",bytes:bytes)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
            let reference=try PackagePreparationCodec.expectedReference(.init(operationID:id(300+n),package:package),rootID:id(3)),entryID=id(400+n)
            packages.append(.supplied(entryID:entryID,operationID:id(300+n),package:package));expectations.append(.init(entryID:entryID,package:package))
            installed.append(.init(entryID:entryID,displayName:"Household \(n)",revision:revision,packageDirectory:reference.directory))
            entries.append(.init(entryID:entryID,revision:revision,generic:nil,homeAssistant:nil,publicReads:nil,credentialReferences:[]))
        }
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(4),revisionID:id(5)),owner:owner,entries:entries,credentials:[],retainedRevisions:[])
        return .init(roots:roots,operationID:id(10),grantOperationID:id(6),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:"opaque"),snapshot:.init(generationID:id(7),entries:installed,configuredEntryID:installed.last?.entryID,contentOwner:owner,grantSet:"opaque"),owner:owner,packages:packages,grantInput:input,qualifiedGrant:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:expectations))
    }
    private func render(_ r:Ready)throws->DeviceManagedStaticContent {
        let binding=try DeviceLocalCompleteSetRestoreCoordinator(packageStore:r.f.p,grantStore:r.f.g,structuralStore:r.store).restoreLatestBoundCompletedExact(journal:r.f.j)
        return try gate(r).makeManagedStaticContentExact(binding:binding)
    }
    func testGenuineConfiguredEntryAssetsOriginalManifestAndNoBackendEffects()throws {
        let request=try staticRequest(count:2),r=try ready(request);try completeFirst(r);let adds=r.f.b.adds
        let content=try render(r);try content.verifyResources()
        XCTAssertEqual(content.entryID,id(401));XCTAssertEqual(content.generationID,r.ack.generationID);XCTAssertEqual(content.operationID,r.ack.operationID)
        XCTAssertEqual(content.displayName,"Household 1");XCTAssertEqual(content.entrypoint,"screen.html")
        guard case .supplied(_,_,let package)=request.packages[1] else{throw Injected.fault}
        XCTAssertEqual(content.assets.first(where:{$0.path == "manifest.json"})?.bytes,package.originalManifestBytes)
        XCTAssertEqual(content.assets.first(where:{$0.path == "screen.html"})?.bytes,package.files[0].bytes)
        XCTAssertEqual(r.f.b.adds,adds);XCTAssertThrowsError(try r.f.j.stageExact(DeviceProvisioningPlanner.qualify(next(r.ack))))
    }
    func testReconstructedCurrentProducesNonAuthorizingStaticContent()throws {
        let r=try ready(staticRequest());try completeFirst(r);let adds=r.f.b.adds
        let j=journal(r.f.jr),g=grantStore(r.f.gr,r.f.b),p=packageStore(r.f.pr),s=structural(r.root)
        let binding=try DeviceLocalCompleteSetRestoreCoordinator(packageStore:p,grantStore:g,structuralStore:s).restoreLatestBoundCompletedExact(journal:j)
        let content=try DeviceLocalResourceGate(packageStore:p,grantStore:g,structuralStore:s).makeManagedStaticContentExact(binding:binding)
        try content.verifyResources();XCTAssertEqual(content.entryID,id(400));XCTAssertEqual(r.f.b.adds,adds)
    }
    func testOriginalFourCheckpointMutationInvalidatesContent()throws {
        for kind in 0..<4 {
            let r=try ready(staticRequest());try completeFirst(r);let content=try render(r),adds=r.f.b.adds
            switch kind {
            case 0:_ = try journal(r.f.jr).recommitExact(r.f.plan)
            case 1:let url=r.f.gr.appendingPathComponent("root-binding.json");try Data(contentsOf:url).write(to:url,options:.atomic)
            case 2:guard case .supplied(_,let op,let package)=r.f.r.packages[0] else{throw Injected.fault};let ref=try PackagePreparationCodec.expectedReference(.init(operationID:op,package:package),rootID:id(3));_ = try packageStore(r.f.pr).resolveRetainedTerminalExact([ref])
            default:_ = try structural(r.root).recommitExact(operationID:r.ack.operationID)
            }
            XCTAssertThrowsError(try content.verifyResources());XCTAssertEqual(r.f.b.adds,adds)
        }
    }
    func testUnsupportedGenericHomePublicAndAudioCapabilitiesRejectProjection()throws {
        var publicRead=ManifestConnection(alias:"weather",required:false)
        publicRead.publicHTTP = .init(origin:"https://example.com",operations:[.init(name:"read",path:"/weather",response:"json")])
        for request in [try staticRequest(connections:[.init(alias:"api",required:false,operations:[.init(name:"read",kind:"http")])]),try staticRequest(connections:[.init(alias:"home",required:false,operations:[.init(name:"states",kind:"ws")])]),try staticRequest(connections:[publicRead]),try staticRequest(behavior:.init(audio:.init(autoplay:true)))] {
            guard case .supplied(_,_,let package)=request.packages[0] else{throw Injected.fault};var checks=0
            XCTAssertThrowsError(try DeviceManagedRenderProjection.make(package:package,operationID:id(10),generationID:id(7),entryID:id(400),displayName:"Static",validate:{checks += 1}))
            XCTAssertEqual(checks,0)
        }
    }
#endif
    func testEmptyCompleteSetNeverInventsStaticSelection()throws {
        let r=try ready();try completeFirst(r)
        let binding=try DeviceLocalCompleteSetRestoreCoordinator(packageStore:r.f.p,grantStore:r.f.g,structuralStore:r.store).restoreLatestBoundCompletedExact(journal:r.f.j)
        XCTAssertThrowsError(try gate(r).makeManagedStaticContentExact(binding:binding))
    }
}
