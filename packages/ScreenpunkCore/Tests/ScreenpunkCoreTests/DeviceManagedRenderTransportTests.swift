import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
@_spi(NativeInstallation) @_spi(DeviceGrantTransport) @_spi(ManagedRender) @testable import ScreenpunkCore

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
#if DEBUG || SCREENPUNK_CORE_TESTING
    func testMixedLocalEntriesNilCallbackKeepsOriginalFourCheckpointValidation() throws {
        for kind in 0..<4 {
            let r = try ready(staticRequest()); try completeFirst(r)
            let binding = try DeviceLocalCompleteSetRestoreCoordinator(packageStore: r.f.p, grantStore: r.f.g,
                structuralStore: r.store).restoreLatestBoundCompletedExact(journal: r.f.j)
            let resourceGate = gate(r), adds = r.f.b.adds
            XCTAssertEqual(try resourceGate.qualifiedMixedLocalEntriesForTesting(binding).map(\.entryID), [id(400)])
            switch kind {
            case 0: _ = try journal(r.f.jr).recommitExact(r.f.plan)
            case 1:
                let url = r.f.gr.appendingPathComponent("root-binding.json")
                try Data(contentsOf: url).write(to: url, options: .atomic)
            case 2:
                guard case .supplied(_, let operation, let package) = r.f.r.packages[0] else { throw Injected.fault }
                let reference = try PackagePreparationCodec.expectedReference(.init(operationID: operation, package: package), rootID: id(3))
                _ = try packageStore(r.f.pr).resolveRetainedTerminalExact([reference])
            default: _ = try structural(r.root).recommitExact(operationID: r.ack.operationID)
            }
            XCTAssertThrowsError(try resourceGate.qualifiedMixedLocalEntriesForTesting(binding))
            XCTAssertEqual(r.f.b.adds, adds)
        }
    }
    func testMixedLocalEntriesCallbackMutationFailsBeforeValuesEscape() throws {
        let r = try ready(staticRequest()); try completeFirst(r)
        let binding = try DeviceLocalCompleteSetRestoreCoordinator(packageStore: r.f.p, grantStore: r.f.g,
            structuralStore: r.store).restoreLatestBoundCompletedExact(journal: r.f.j)
        let resourceGate = gate(r), adds = r.f.b.adds
        let entry = try XCTUnwrap(r.f.r.snapshot.entries.first)
        let asset = r.f.pr.appendingPathComponent(entry.packageDirectory).appendingPathComponent("screen.html")
        var callbacks = 0, mutationFailure: Error?
        XCTAssertThrowsError(try resourceGate.qualifiedMixedLocalEntriesForTesting(binding, displayManifest: { observed, manifest in
            callbacks += 1
            XCTAssertEqual(observed.entryID, entry.entryID)
            XCTAssertEqual(manifest.dashboardId, entry.revision.dashboardId)
            do { try Data("changed during callback".utf8).write(to: asset) }
            catch { mutationFailure = error }
        }))
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(mutationFailure)
        XCTAssertEqual(r.f.b.adds, adds)
    }
#endif
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

#if canImport(CryptoKit) && (DEBUG || SCREENPUNK_CORE_TESTING)
extension DeviceManagedRenderTransportTests {
    // These tests qualify real four-store resources and session serialization.
    // The common detached ledger is synthetic nonsecret resource evidence; it
    // does not mint native enrollment, server revocation or transport admission.
    private final class ActiveCredentials: DeviceGrantCredentialTransport, @unchecked Sendable {
        let rootID: UUID
        private let lock = NSLock()
        private var values: [String: (DeviceGrantCredentialObservation, Data)] = [:]
        private var reads = 0
        var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
        private var readHook: (() throws -> Void)?
        init(rootID: UUID) { self.rootID = rootID }
        func armRead(_ hook: @escaping () throws -> Void) { lock.lock(); readHook = hook; lock.unlock() }
        func inventory(maximum: Int, visit: (DeviceGrantCredentialObservation) throws -> Void) throws {
            lock.lock(); let observed = values.keys.sorted().map { values[$0]!.0 }; lock.unlock()
            guard observed.count <= maximum else { throw DeviceGrantCredentialTransportFailure.capacity }
            for item in observed { try visit(item) }
        }
        func read(account: String, maximumBytes: Int) throws -> DeviceGrantCredentialTransportSecret? {
            lock.lock(); reads += 1; let hook = readHook; readHook = nil; lock.unlock()
            try hook?()
            lock.lock(); let value = values[account]; lock.unlock()
            guard let value else { return nil }
            guard value.1.count <= maximumBytes else { throw DeviceGrantCredentialTransportFailure.sizeLimit }
            return try .init(observation: value.0, bytes: value.1)
        }
        func add(account: String, bytes: Data) throws -> DeviceGrantCredentialObservation {
            lock.lock(); defer { lock.unlock() }
            guard values[account] == nil else { throw DeviceGrantCredentialTransportFailure.duplicateItem }
            let item = try DeviceGrantCredentialObservation(account: account,
                persistentReference: Data(UUID().uuidString.utf8), byteCount: bytes.count)
            values[account] = (item, bytes); return item
        }
        func changePrivateIdentity() throws {
            lock.lock(); defer { lock.unlock() }
            guard let account = values.keys.sorted().first, let value = values[account] else { throw Injected.fault }
            values[account] = (try .init(account: account, persistentReference: Data(UUID().uuidString.utf8), byteCount: value.1.count), value.1)
        }
        func changePrivateBytes() throws {
            lock.lock(); defer { lock.unlock() }
            guard let account = values.keys.sorted().first, let value = values[account], !value.1.isEmpty else { throw Injected.fault }
            var bytes = value.1; bytes[bytes.startIndex] ^= 1
            values[account] = (value.0, bytes)
        }
    }
    private final class ActiveAuthority: @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        func validate() throws {
            // This is deliberately checked by the supplied authority callback,
            // proving that the active composite never calls it under a permit.
            try DeviceLocalResourceRegistry.requireIdle()
            lock.lock(); let denied = revoked; lock.unlock()
            if denied { throw ConnectionFailure.permissionRequired }
        }
        func revoke() { lock.lock(); revoked = true; lock.unlock() }
    }
    private final class ActiveHTTP: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        var hook: (() async throws -> Void)?
        func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
            record(); try await hook?(); return .init(status: 200, body: Data("bounded fixture".utf8))
        }
        private func record() { lock.lock(); count += 1; lock.unlock() }
    }
    private struct ActiveResolver: DestinationResolver {
        func addresses(for host: String) throws -> [String] { throw Injected.fault }
    }
    private struct ActiveSockets: WebSocketTransport {
        func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession { throw Injected.fault }
    }
    private final class ActiveOwner: NativeUnifiedLocalInventoryOwner {
        let commonRootID: UUID
        let peerPinHex = String(repeating: "7", count: 64)
        init(rootID: UUID) { commonRootID = rootID }
        func performFixedUnifiedLocalDispatch(command: NativeInstallationUnifiedLocalDispatchCommand) throws -> NativeInstallationUnifiedLocalDispatchResult {
            try command.performDuringFixedOwner()
        }
    }
    private struct ActiveFixture {
        let request: DeviceProvisioningPlanRequest, local: DeviceLegacyMigrationSession
        let commonRoot: URL, grantRoot: URL, commonID: UUID, common: DeviceUnifiedInventorySession
        let credentials: ActiveCredentials, authority: ActiveAuthority, http: ActiveHTTP
        let entries: [UUID], initial: DeviceMixedInventoryStore.Capture
    }
    // Test data for mutating a bound field while preserving canonical framing.
    // This is not an inventory/store constructor or authority seam.
    private struct ActiveCommonBinding: Codable {
        var rootID: UUID
        let path: String
        let device: UInt64, inode: UInt64, lockDevice: UInt64, lockInode: UInt64
    }
    private func activeFixture() throws -> ActiveFixture {
        let input = try staticRequest(count: 2), p = try directory(), g = try directory()
        let s = try directory(), j = try directory(), protected = try directory(), commonRoot = try directory()
        let credentials = ActiveCredentials(rootID: roots.grantID), authority = ActiveAuthority()
        let local = try DeviceLegacyMigrationSession(packageRoot: p, packageRootID: roots.packageID,
            grantRoot: g, grantRootID: roots.grantID, structuralRoot: s, structuralRootID: roots.structuralID,
            provisioningRoot: j, provisioningRootID: roots.journalID,
            legacyStateRoot: protected.appendingPathComponent("state"), legacyArchiveRoot: protected.appendingPathComponent("archive"),
            resetRoot: protected.appendingPathComponent("reset"), cloudRoot: protected.appendingPathComponent("cloud"),
            managementRoot: protected.appendingPathComponent("management"), preferencesRoot: protected.appendingPathComponent("preferences"),
            otherProtectedRoots: [], credentialTransport: credentials, validateRoots: {})
        let screens = try input.packages.map { value -> DeviceLegacyMigrationScreen in
            guard case .supplied(let entryID, let operationID, let package) = value else { throw Injected.fault }
            return .init(entryID: entryID, packageOperationID: operationID,
                displayName: try XCTUnwrap(input.snapshot.entries.first { $0.entryID == entryID }).displayName,
                revision: package.revision, manifest: package.originalManifestBytes,
                files: Dictionary(uniqueKeysWithValues: package.files.map { ($0.path, $0.bytes) }),
                homeAssistant: nil, generic: nil, publicReads: nil)
        }
        try local.prepareAndCommit(screens: screens, selected: input.snapshot.configuredEntryID,
            owner: owner, profile: .init(deviceId: "device", name: "Device"), profileID: "profile",
            operationID: input.operationID, grantOperationID: input.grantOperationID,
            generationID: input.snapshot.generationID, grantRevisionID: input.grantInput.identity.revisionID,
            legacyGrantSet: "opaque", validateOriginal: {})
        let binding = try XCTUnwrap(local.binding)
        let gate = DeviceLocalResourceGate(packageStore: local.packages, grantStore: local.grants, structuralStore: local.structural)
        let entries = try gate.qualifiedMixedLocalEntriesForTesting(binding)
        let commonID = UUID(), store = DeviceMixedInventoryStore(root: commonRoot, rootID: commonID)
        try store.initializeExplicit()
        // Record the exact store-owned spellings used by mixedSourceRoots.
        // In particular, macOS structural storage standardizes its caller URL.
        let grantSource = local.grants.mixedInventorySourceRoot
        let localRoots = [
            DeviceMixedInventoryStore.LocalSourceRoot(rootID: local.packages.rootID, path: local.packages.root.path),
            .init(rootID: grantSource.rootID, path: grantSource.root.path),
            .init(rootID: local.structural.rootID, path: local.structural.root.path),
            .init(rootID: local.journal.rootID, path: local.journal.root.path)
        ]
        let state = try DeviceMixedStructuralState.validating(generationID: UUID(),
            installationOwner: .init(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID()),
            entries: entries, configuredEntryID: input.snapshot.configuredEntryID,
            detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: Data("synthetic-resource-evidence".utf8)),
            legacyLocalRoots: localRoots)
        let initial = try DeviceMixedInventoryQualificationHarness.scope(store) {
            try store.commitExact(operationID: UUID(), previous: nil, candidate: state, admissionEnabled: true, permit: $0).0
        }
        let common = try DeviceUnifiedInventorySession.restoreDetached(local: local,
            commonRoot: commonRoot, commonRootID: commonID, validateOriginal: authority.validate,
            validateMutation: { throw NativeDeliveryExecutionError.unavailableDispatchCapability })
        return .init(request: input, local: local, commonRoot: commonRoot, grantRoot: g, commonID: commonID,
            common: common, credentials: credentials, authority: authority, http: ActiveHTTP(), entries: entries.map(\.entryID), initial: initial)
    }
    private func activeRuntime(_ f: ActiveFixture, historical: Bool = false) async throws -> DeviceUnifiedManagedRuntime {
        if historical {
            return try await f.common.lastSuccessfulManagedRuntime(operationID: UUID(), http: f.http,
                webSocket: ActiveSockets(), resolver: ActiveResolver(), clock: FixedClock(Date(timeIntervalSince1970: 1)))
        }
        return try await f.common.makeManagedRuntime(operationID: UUID(), http: f.http,
            webSocket: ActiveSockets(), resolver: ActiveResolver(), clock: FixedClock(Date(timeIntervalSince1970: 1)))
    }
    private func activeSelect(_ f: ActiveFixture, entry: UUID) throws {
        try f.common.selectOrRemove(operationID: UUID(), generationID: UUID(), retainedEntryIDs: f.entries,
            selected: entry, owner: ActiveOwner(rootID: f.commonID))
    }
    private var activeRequest: AuthorizedHTTPRequest {
        .init(url: URL(string: "https://fixture.invalid/bounded")!, method: "GET", headers: [:], body: nil, timeout: 1, maxBytes: 1024)
    }
    private func activeRefused(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected active refusal", file: file, line: line) } catch {}
    }
    func testUnifiedActiveRequiresExactConfirmedObjectAndOriginalSessionSource() async throws {
        let f = try activeFixture(), runtime = try await activeRuntime(f)
        try runtime.verifyResources()
        XCTAssertThrowsError(try runtime.verifyActive()) { error in
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired, "No current mount precedes exact-object confirmation")
        }
        await activeRefused { _ = try await runtime.guardedHTTP(f.http).send(self.activeRequest) }
        XCTAssertEqual(f.http.calls, 0)
        try f.common.confirmMountedLocalContent(runtime.content); try runtime.verifyActive()
        let another = try await activeRuntime(f)
        XCTAssertEqual(another.content.generationID, runtime.content.generationID)
        XCTAssertEqual(another.content.entryID, runtime.content.entryID)
        XCTAssertFalse(another.content === runtime.content)
        XCTAssertThrowsError(try another.verifyActive()) { error in
            XCTAssertEqual(error as? DeviceStructuralStoreError, .conflict, "A matching mount does not confirm another same-ID object")
        }
        try runtime.verifyActive()
        let otherSession = try DeviceUnifiedInventorySession.restoreDetached(local: f.local,
            commonRoot: f.commonRoot, commonRootID: f.commonID, validateOriginal: f.authority.validate,
            validateMutation: { throw NativeDeliveryExecutionError.unavailableDispatchCapability })
        let source = try f.common.runtimeSourceExact()
        XCTAssertThrowsError(try otherSession.verifyActiveRuntimePresentationExact(runtime.content,
            resolver: source.resolver, original: source.original, store: source.store, presentation: source.capture,
            entryID: runtime.content.entryID, manifestDigest: runtime.manifest.digest!))
        // Each captured source identity remains independently bound, even when
        // the second session reads the same durable common bytes and Local roots.
        let otherSource = try otherSession.runtimeSourceExact()
        XCTAssertThrowsError(try f.common.verifyActiveRuntimePresentationExact(runtime.content,
            resolver: otherSource.resolver, original: source.original, store: source.store, presentation: source.capture,
            entryID: runtime.content.entryID, manifestDigest: runtime.manifest.digest!))
        XCTAssertThrowsError(try f.common.verifyActiveRuntimePresentationExact(runtime.content,
            resolver: source.resolver, original: otherSource.original, store: source.store, presentation: source.capture,
            entryID: runtime.content.entryID, manifestDigest: runtime.manifest.digest!))
        XCTAssertThrowsError(try f.common.verifyActiveRuntimePresentationExact(runtime.content,
            resolver: source.resolver, original: source.original, store: otherSource.store, presentation: source.capture,
            entryID: runtime.content.entryID, manifestDigest: runtime.manifest.digest!))
        XCTAssertThrowsError(try otherSession.confirmMountedLocalContent(runtime.content))
        try runtime.verifyActive()
    }
    func testUnifiedActiveKeepsHistoricalMountedAWhileCurrentBAndRejectsAfterBMounts() async throws {
        let f = try activeFixture(), a = try await activeRuntime(f)
        try f.common.confirmMountedLocalContent(a.content); try a.verifyActive()
        try activeSelect(f, entry: f.entries[0])
        let b = try await activeRuntime(f)
        try f.common.confirmMountFailure(b.content, code: "navigation_failed")
        XCTAssertNotEqual(b.content.generationID, a.content.generationID)
        XCTAssertNotEqual(b.content.entryID, a.content.entryID)
        try a.verifyActive()
        XCTAssertThrowsError(try b.verifyActive()) { error in
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired, "Current B has a different valid mounted A")
        }
        let restored = try await activeRuntime(f, historical: true)
        XCTAssertEqual(restored.content.generationID, a.content.generationID)
        XCTAssertEqual(restored.content.entryID, a.content.entryID)
        XCTAssertThrowsError(try restored.verifyActive()) { error in
            XCTAssertEqual(error as? DeviceStructuralStoreError, .conflict, "Valid historical A still needs exact-object confirmation")
        }
        try f.common.confirmMountedLocalContent(restored.content); try restored.verifyActive()
        XCTAssertThrowsError(try a.verifyActive()) { error in
            XCTAssertEqual(error as? DeviceStructuralStoreError, .conflict, "Original same-ID A object was replaced by restored A")
        }
        try f.common.confirmMountedLocalContent(b.content); try b.verifyActive()
        XCTAssertThrowsError(try restored.verifyActive()) { error in
            XCTAssertEqual(error as? DeviceStructuralStoreError, .conflict, "Historical A no longer matches the mounted source")
        }
    }
    func testUnifiedActiveRejectsRemovedOrChangedHistoricalMountEvenWithCanonicalCurrentB() async throws {
        for kind in 0..<2 {
            let f = try activeFixture(), a = try await activeRuntime(f)
            try f.common.confirmMountedLocalContent(a.content)
            try activeSelect(f, entry: f.entries[0]); try a.verifyActive()
            let current = try f.common.runtimeSourceExact().capture
            let names = try FileManager.default.contentsOfDirectory(atPath: f.commonRoot.path)
                .filter { $0.hasSuffix(".mixed-intent.json") }
            let records = try names.map { name in
                (name, try JSONDecoder().decode(DeviceMixedInventoryStore.Intent.self,
                    from: Data(contentsOf: f.commonRoot.appendingPathComponent(name))))
            }
            let old = try XCTUnwrap(records.first { $0.1.candidate == f.initial.bytes })
            let tip = try XCTUnwrap(records.first { $0.1.candidate == current.bytes })
            let previous: Data?
            if kind == 0 {
                try FileManager.default.removeItem(at: f.commonRoot.appendingPathComponent(old.0))
                try FileManager.default.removeItem(at: f.commonRoot.appendingPathComponent(old.1.operationID.uuidString.lowercased() + ".mixed-receipt.json"))
                previous = nil
            } else {
                let prior = f.initial.snapshot
                let changed = try DeviceMixedStructuralState.validating(generationID: prior.generationID,
                    installationOwner: prior.installationOwner, entries: prior.entries, configuredEntryID: f.entries[0],
                    detachment: prior.detachment, legacyLocalRoots: prior.legacyLocalRoots,
                    cloudObservationEpoch: prior.cloudObservationEpoch)
                let bytes = try DeviceMixedStructuralStateCodec.encode(changed)
                let intent = DeviceMixedInventoryStore.Intent(operationID: old.1.operationID, previous: nil, candidate: bytes)
                try DeviceLocalCompleteSetBounds.encode(intent, maximum: 384 * 1024).write(to: f.commonRoot.appendingPathComponent(old.0))
                let receipt = DeviceMixedInventoryStore.Receipt(operationID: old.1.operationID,
                    generationID: changed.generationID, digest: try DeviceNativeDeliveryAttachmentCodec.hash(bytes))
                try DeviceLocalCompleteSetBounds.encode(receipt, maximum: 8192).write(to: f.commonRoot.appendingPathComponent(old.1.operationID.uuidString.lowercased() + ".mixed-receipt.json"))
                previous = bytes
            }
            let rewritten = DeviceMixedInventoryStore.Intent(operationID: tip.1.operationID, previous: previous, candidate: tip.1.candidate)
            try DeviceLocalCompleteSetBounds.encode(rewritten, maximum: 384 * 1024).write(to: f.commonRoot.appendingPathComponent(tip.0))
            // This is still a valid canonical chain with the exact captured B tip.
            // Its mounted A membership/selection proof was separately destroyed.
            let reopened = DeviceMixedInventoryStore(root: f.commonRoot, rootID: f.commonID)
            XCTAssertEqual(try reopened.readCurrent()?.bytes, current.bytes)
            XCTAssertThrowsError(try reopened.mountedExact())
            XCTAssertThrowsError(try a.verifyActive())
            await activeRefused { _ = try await a.guardedHTTP(f.http).send(self.activeRequest) }
            XCTAssertEqual(f.http.calls, 0)
        }
    }
    func testUnifiedActiveAlwaysRequiresExactMountedReceiptForCurrentPresentation() async throws {
        for kind in 0..<5 {
            let f = try activeFixture(), runtime = try await activeRuntime(f)
            try f.common.confirmMountedLocalContent(runtime.content); try runtime.verifyActive()
            let path = f.commonRoot.appendingPathComponent("mixed-mounted.json")
            if kind == 0 { try FileManager.default.removeItem(at: path) }
            else if kind == 4 { try Data("{}".utf8).write(to: path) }
            else {
                let mounted = DeviceMixedInventoryStore.MountedFrame(
                    generationID: kind == 1 ? UUID() : runtime.content.generationID,
                    entryID: kind == 2 ? f.entries[0] : runtime.content.entryID,
                    manifestDigest: kind == 3 ? String(repeating: "a", count: 64) : runtime.manifest.digest!)
                try DeviceLocalCompleteSetBounds.encode(mounted, maximum: 8192).write(to: path)
            }
            XCTAssertThrowsError(try runtime.verifyActive()) { error in
                if kind == 0 { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired, "Confirmed current object lost its mount") }
            }
            await activeRefused { _ = try await runtime.guardedHTTP(f.http).send(self.activeRequest) }
            XCTAssertEqual(f.http.calls, 0)
        }
    }
    func testUnifiedActiveRejectsOriginalCheckpointsPhysicalBindingAssetsAndPrivateBytes() async throws {
        for kind in 0..<11 {
            let f = try activeFixture(), runtime = try await activeRuntime(f)
            try f.common.confirmMountedLocalContent(runtime.content); try runtime.verifyActive()
            switch kind {
            case 0: _ = try f.local.journal.recommitExact(DeviceProvisioningPlanner.qualify(f.request))
            case 1:
                let path = f.grantRoot.appendingPathComponent("root-binding.json")
                try Data(contentsOf: path).write(to: path, options: .atomic)
            case 2:
                guard case .supplied(_, let op, let package) = f.request.packages[0] else { throw Injected.fault }
                let reference = try PackagePreparationCodec.expectedReference(.init(operationID: op, package: package), rootID: roots.packageID)
                _ = try f.local.packages.resolveRetainedTerminalExact([reference])
            case 3: _ = try f.local.structural.recommitExact(operationID: f.request.operationID)
            case 4:
                let entry = try XCTUnwrap(f.request.snapshot.entries.first)
                try Data("tampered original asset".utf8).write(to: f.local.packages.root.appendingPathComponent(entry.packageDirectory).appendingPathComponent("screen.html"))
            case 5: try f.credentials.changePrivateIdentity()
            case 6: try f.credentials.changePrivateBytes()
            case 7:
                let path = f.commonRoot.appendingPathComponent("mixed-root.json")
                let original = try Data(contentsOf: path)
                var binding = try JSONDecoder().decode(ActiveCommonBinding.self, from: original)
                XCTAssertEqual(binding.rootID, f.commonID, "Mutation7 must start from this fixture's bound root")
                XCTAssertEqual(try DeviceLocalCompleteSetBounds.encode(binding, maximum: 8192), original)
                let replacement = UUID()
                XCTAssertNotEqual(replacement, binding.rootID)
                binding.rootID = replacement
                let changed = try DeviceLocalCompleteSetBounds.encode(binding, maximum: 8192)
                XCTAssertNotEqual(changed, original, "Mutation7 must change the captured binding value")
                try changed.write(to: path, options: .atomic)
                let persisted = try Data(contentsOf: path)
                XCTAssertEqual(persisted, changed)
                XCTAssertEqual(try JSONDecoder().decode(ActiveCommonBinding.self, from: persisted).rootID, replacement)
            case 8: try Data("{}".utf8).write(to: f.commonRoot.appendingPathComponent("mixed-current.json"))
            case 9: try Data().write(to: f.commonRoot.appendingPathComponent("mixed.lock"), options: .atomic)
            default:
                let moved = try directory()
                try FileManager.default.removeItem(at: moved)
                try FileManager.default.moveItem(at: f.commonRoot, to: moved)
                try FileManager.default.createDirectory(at: f.commonRoot, withIntermediateDirectories: false)
            }
            XCTAssertThrowsError(try runtime.verifyActive(), "Original-evidence mutation kind \(kind)")
            await activeRefused { _ = try await runtime.guardedHTTP(f.http).send(self.activeRequest) }
            XCTAssertEqual(f.http.calls, 0, "Original-evidence mutation kind \(kind)")
        }
    }
    func testUnifiedActivePostQualificationDetectsBackendMutationAndAuthorityRevocation() async throws {
        for kind in 0..<4 {
            let f = try activeFixture(), runtime = try await activeRuntime(f)
            try f.common.confirmMountedLocalContent(runtime.content); try runtime.verifyActive()
            let entry = try XCTUnwrap(f.request.snapshot.entries.first)
            let asset = f.local.packages.root.appendingPathComponent(entry.packageDirectory).appendingPathComponent("screen.html")
            var reads = 0
            f.credentials.armRead {
                reads += 1
                if kind == 0 { try Data("changed after package qualification".utf8).write(to: asset) }
                else if kind == 1 { try FileManager.default.removeItem(at: f.commonRoot.appendingPathComponent("mixed-mounted.json")) }
                else if kind == 2 { f.authority.revoke() }
                else { try Data("{}".utf8).write(to: f.commonRoot.appendingPathComponent("mixed-current.json")) }
            }
            XCTAssertThrowsError(try runtime.verifyActive())
            XCTAssertEqual(reads, 1)
            await activeRefused { _ = try await runtime.guardedHTTP(f.http).send(self.activeRequest) }
            XCTAssertEqual(f.http.calls, 0)
        }
    }
    func testUnifiedActiveBackendReentryRejectsWithoutLosingOuterScope() async throws {
        let f = try activeFixture(), runtime = try await activeRuntime(f)
        try f.common.confirmMountedLocalContent(runtime.content)
        var reentries = 0
        f.credentials.armRead {
            XCTAssertThrowsError(try f.common.validatedAssociation()) { error in
                XCTAssertEqual(error as? DeviceLocalResourceGateFailure, .reentrant)
            }
            XCTAssertThrowsError(try runtime.verifyResources()) { error in
                XCTAssertEqual(error as? DeviceLocalResourceGateFailure, .reentrant)
            }
            reentries += 1
        }
        try runtime.verifyActive(); XCTAssertEqual(reentries, 1)
        try runtime.verifyActive()
    }
    func testUnifiedActiveSerializesConcurrentSelectionAndChecksCancellationAfterHeldGraph() async throws {
        let f = try activeFixture(), runtime = try await activeRuntime(f)
        try f.common.confirmMountedLocalContent(runtime.content)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        f.credentials.armRead {
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw Injected.fault }
        }
        let active = Task.detached { try runtime.verifyActive() }
        defer { active.cancel(); release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        let writer = Task.detached { try self.activeSelect(f, entry: f.entries[0]) }
        defer { writer.cancel() }
        active.cancel(); release.signal()
        do { try await active.value; XCTFail("Cancelled graph verification returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await writer.value
        XCTAssertEqual(try f.common.validatedAssociation().configuredEntryID, f.entries[0])
        // A remains the exact confirmed historical mount after the serialized B CAS.
        try runtime.verifyActive()
    }
    func testExplicitCancellationOnDispatchWorkerStopsBeforeSecondGraphPass() async throws {
        let f = try activeFixture(), runtime = try await activeRuntime(f)
        try f.common.confirmMountedLocalContent(runtime.content)
        let before = f.credentials.readCount
        try runtime.verifyActive()
        let fullReads = f.credentials.readCount - before
        XCTAssertGreaterThan(fullReads, 0)
        let cancellation = DeviceRuntimeVerificationCancellation()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        f.credentials.armRead {
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw Injected.fault }
        }
        let cancelledBefore = f.credentials.readCount
        let finished = expectation(description: "dispatch verification observed cancellation")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do { try runtime.verifyActive(cancellation: cancellation); XCTFail("expired verification succeeded") }
            catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
        }
        defer { cancellation.cancel(); release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        cancellation.cancel(); release.signal()
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertLessThan(f.credentials.readCount - cancelledBefore, fullReads,
            "Cancellation must interrupt Core graph work, not merely reject its final result")
        // Cancellation is scoped to one verification, not a permanent runtime revocation.
        try runtime.verifyActive()
    }

    func testUnifiedActivePreCancelledCallAndLateResponseCannotAuthorizeEffects() async throws {
        let f = try activeFixture(), runtime = try await activeRuntime(f)
        try f.common.confirmMountedLocalContent(runtime.content)
        let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cancelled = Task.detached {
            ready.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw Injected.fault }
            try runtime.verifyActive()
        }
        defer { cancelled.cancel(); release.signal() }
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success)
        cancelled.cancel(); release.signal()
        do { try await cancelled.value; XCTFail("Pre-cancelled active verification returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        f.http.hook = { f.authority.revoke() }
        await activeRefused { _ = try await runtime.guardedHTTP(f.http).send(self.activeRequest) }
        XCTAssertEqual(f.http.calls, 1)
        XCTAssertThrowsError(try runtime.verifyActive())
    }
}
#endif
