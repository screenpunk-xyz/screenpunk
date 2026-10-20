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
@_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore

final class DeviceNativeProvisioningCompletionTests:XCTestCase {
    private enum Fault:Error {case injected}
    private final class Probe {
        var journal:DeviceLocalProvisioningIntentStore.Boundary?,structural:DeviceStructuralStore.Boundary?
        var structuralAction:((DeviceStructuralStore.Boundary)throws->Void)?
        var events=0
        var journalAction:((DeviceLocalProvisioningIntentStore.Boundary)throws->Void)?
        func hit(_ site:DeviceLocalProvisioningIntentStore.Boundary)throws {events+=1;try journalAction?(site);if journal == site{journal=nil;throw Fault.injected}}
        func hit(_ site:DeviceStructuralStore.Boundary)throws {events+=1;try structuralAction?(site);if structural == site{structural=nil;throw Fault.injected}}
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
    private var maximumNames = false
    private var owner:DeviceNativeInstallationContentOwner {.init(installationID:UUID(),accountID:UUID(),locationID:UUID(),transitionID:UUID())}
    private func snapshot(_ r:URL)throws->[String:Data] {
        var result:[String:Data]=[:]
        for u in try FileManager.default.contentsOfDirectory(at:r,includingPropertiesForKeys:[.isRegularFileKey]) where try u.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {result[u.lastPathComponent]=try Data(contentsOf:u)}
        return result
    }
    #if canImport(CryptoKit)
    private func package(generic:Bool,mixed:Bool=false)throws->QualifiedDevicePackage {
        let html=Data("<html>native fixture</html>".utf8),dashboard=UUID(),revision=UUID()
        func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:dashboard.uuidString.lowercased(),name:"Explicit native fixture",revision:revision.uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:generic ? [.init(alias:"api",required:false,operations:[.init(name:"read",kind:"http")])]:[],files:[.init(path:"index.html",bytes:html.count,sha256:hash(html))])
        if mixed {
            var home = ManifestConnection(alias: "home", required: false)
            home.serviceCalls = [.init(domain: "light", service: "turn_on", entityIds: ["light.one"])]
            home.cameraEntities = ["camera.one"]
            var publicConnection = ManifestConnection(alias: "weather", required: false)
            publicConnection.publicHTTP = .init(origin: "https://example.com", operations: [.init(name: "forecast", path: "/forecast", response: "json")])
            manifest.connections += [home, publicConnection]
        }
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
    private func fixture(count:Int=1,generic:Bool=false,mixed:Bool=false,distinct:Bool=false)throws->Fixture {
        let j=try root(),s=try root(),roots=DeviceProvisioningRoots(journalID:UUID(),structuralID:UUID(),packageID:UUID(),grantID:UUID()),probe=Probe()
        let journal=DeviceLocalProvisioningIntentStore(root:j,rootID:roots.journalID,protectedRoots:[s],boundary:{try probe.hit($0)})
        let structural=DeviceStructuralStore(root:s,rootID:roots.structuralID,boundary:{try probe.hit($0)})
        try journal.initializeExplicit();try structural.initializeExplicit()
        let who=owner,initial=try empty(who),baseline=try structural.initializeNativeGenesisExplicit(initial),desired=UUID(),nativeOperation=UUID(),grantOperation=UUID()
        var entries:[DeviceNativeStructuralEntry]=[],inputs:[DeviceProvisioningPackageInput]=[],grantEntries:[DeviceGrantEntryInput]=[],expectations:[DeviceGrantEntryExpectation]=[]
        let secret=Data("NATIVE_PRIVATE_SECRET_CANARY".utf8),credential=UUID(),homeCredential=UUID()
        var credentialInputs: [DeviceGrantCredentialInput] = []
        for _ in 0..<count {
            let localCredential = distinct ? UUID() : credential
            let package=try package(generic:generic,mixed:mixed),entryID=UUID(),op=UUID()
            let reference=try PackagePreparationCodec.expectedReference(.init(operationID:op,package:package),rootID:roots.packageID)
            let descriptor=try DeviceDeliveryPackageCandidate.validating(packageProfile:DeviceDeliveryPackageCandidate.profile,publicationID:UUID(),projectID:UUID(),packageID:UUID(),dashboardID:UUID(uuidString:package.revision.dashboardId)!,revision:UUID(uuidString:package.revision.revision)!,manifestDigest:.validating(package.revision.digest),manifestSHA256:.validating(package.manifestSHA256),archiveSHA256:.validating(String(repeating:"d",count:64)),compressedBytes:10,expandedBytes:100,archiveEntries:2)
            entries.append(try .validating(entryID:entryID,displayName:maximumNames ? String(repeating:"x",count:1024) : "Explicit household name",package:descriptor,preparedPackage:reference))
            inputs.append(.supplied(entryID:entryID,operationID:op,package:package));expectations.append(.init(entryID:entryID,package:package))
            var provisioning:ConnectionProvisioning?,refs:[DeviceGrantCredentialReference]=[]
            if generic {
                let grant=ConnectionGrant(schemaVersion:1,id:UUID(),alias:"api",origin:"https://example.com",transport:.http,authRef:"shared-ref",lan:false,allowInsecureHTTP:false,operations:[.init(name:"read",kind:.http,method:.GET,path:"/data",idempotent:true,write:false)])
                provisioning = .init(dashboardId:package.revision.dashboardId,revision:package.revision.revision,provisioningId:"explicit-provisioning",entries:[.init(grant:grant,binding:.init(authRef:"shared-ref",placement:.bearer),secret:secret)])
                refs=[.init(credentialRevisionID:localCredential,kind:.generic,key:"shared-ref")]
                if !credentialInputs.contains(where: { $0.revisionID == localCredential }) {
                    credentialInputs.append(.init(revisionID: localCredential, bytes: secret))
                }
            }
            var home: HomeAssistantProvisioning?, publicReads: PublicReadProvisioning?
            if mixed {
                home = .init(schemaVersion: 3, dashboardId: package.revision.dashboardId, connectionId: "shared-home",
                    provisioningId: "explicit-home", revision: package.revision.revision, origin: "https://example.com",
                    token: String(decoding: secret, as: UTF8.self))
                home?.serviceCalls = package.manifest.connections.first(where: { $0.alias == "home" })?.serviceCalls
                home?.cameraEntities = ["camera.one"]
                publicReads = try .init(manifest: package.manifest)
                refs.append(.init(credentialRevisionID: homeCredential, kind: .homeAssistant, key: "shared-home"))
            }
            grantEntries.append(.init(entryID:entryID,revision:package.revision,generic:provisioning,homeAssistant:home,publicReads:publicReads,credentialReferences:refs))
        }
        let selected=entries.first?.entryID,candidate=try DeviceNativeStructuralState.validating(generationID:desired,owner:.nativeInstallation(who),entries:entries,configuredEntryID:selected)
        let set=try DeviceResultingSetCandidate.validating(entries:entries.map{.validating(entryID:$0.entryID,provenance:.cloud($0.package))},configuredEntryID:selected)
        let rawPlan=Data("exact raw native plan fixture".utf8)
        let association:[String:Any]=["schemaVersion":1,"operationId":UUID().uuidString.lowercased(),"planId":UUID().uuidString.lowercased(),"installationId":who.installationID.uuidString.lowercased(),"accountId":who.accountID.uuidString.lowercased(),"locationId":who.locationID.map { $0.uuidString.lowercased() } as Any? ?? NSNull(),"transitionId":who.transitionID.uuidString.lowercased(),"planDigest":try DeviceNativeDeliveryAttachmentCodec.hash(rawPlan),"planByteLength":rawPlan.count]
        var command=association;command["sequence"]="1";command["expectedInstalledSetGenerationId"]=initial.generationID.uuidString.lowercased();command["desiredSetGenerationId"]=desired.uuidString.lowercased();command["executionExpiresAt"]="2026-10-04T12:00:00Z";command["resultingSetDigest"]=try DeviceDeliveryCandidateCodec.resultingSetDigest(set)
        let wire=entries.map{e->[String:Any] in let p=e.package;return ["entryId":e.entryID.uuidString.lowercased(),"provenance":["kind":"cloud","package":["packageProfile":DeviceDeliveryPackageCandidate.profile,"publicationId":p.publicationID.uuidString.lowercased(),"projectId":p.projectID.uuidString.lowercased(),"packageId":p.packageID.uuidString.lowercased(),"dashboardId":p.dashboardID.uuidString.lowercased(),"revision":p.revision.uuidString.lowercased(),"manifestDigest":p.manifestDigest.text,"manifestSha256":p.manifestSHA256.text,"archiveSha256":p.archiveSHA256.text,"compressedBytes":p.compressedBytes,"expandedBytes":p.expandedBytes,"archiveEntries":p.archiveEntries]]]}
        let selectedWire:Any; if let selected {selectedWire=selected.uuidString.lowercased()} else {selectedWire=NSNull()}
        command["resultingSet"]=["schemaVersion":1,"entries":wire,"configuredEntryId":selectedWire]
        let header=try JSONSerialization.data(withJSONObject:association).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let delivery=try DeviceNativeDeliveryCommandBinding.bind(command:JSONSerialization.data(withJSONObject:command),associationHeader:header,rawPlan:rawPlan,nativeOperationID:nativeOperation,journalRootID:roots.journalID)
        let input=DeviceNativeGrantRevisionInput(schemaVersion:2,identity:.init(rootID:roots.grantID,revisionID:UUID()),owner:who,entries:grantEntries,credentials:credentialInputs + (mixed ? [.init(revisionID:homeCredential,bytes:secret)]:[]),retainedRevisions:[])
        let qualified=try DeviceNativeGrantRevisionQualifier.qualify(input,expectedEntries:expectations)
        let request=DeviceNativeProvisioningRequest(roots:roots,delivery:delivery,grantOperationID:grantOperation,baseline:baseline,candidate:candidate,packages:inputs,grantInput:input,qualifiedGrant:qualified)
        let plan=try DeviceNativeProvisioningPlanner.qualify(request),attachment=try journal.publishDeliveryAttachmentExact(delivery)
        return .init(journalRoot:j,structuralRoot:s,roots:roots,journal:journal,structural:structural,probe:probe,request:request,plan:plan,attachment:attachment)
    }
    private final class Backend: DeviceGrantCredentialBackend, @unchecked Sendable {
        var values: [String: DeviceGrantCredentialValue] = [:]
        var adds = 0
        var referenceBytes = 36
        var action: (() throws -> Void)?
        var readAction: (() throws -> Void)?
        var inventoryOverride: [DeviceGrantCredentialItem]?
        func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {
            if let inventoryOverride { for item in inventoryOverride { try visit(item) }; return }
            for value in values.values { try visit(value.item) }
        }
        func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? { try readAction?(); return values[account] }
        func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem {
            try action?()
            guard values[account] == nil else { throw DeviceNativeGrantPreparationError.conflict }
            adds += 1
            let item = DeviceGrantCredentialItem(account: account, persistentReference: referenceBytes == 1024 ? Data(repeating: UInt8(adds & 255), count: 1024) : Data(UUID().uuidString.utf8), byteCount: bytes.count)
            values[account] = .init(item: item, bytes: bytes)
            return item
        }
    }
    private final class GrantProbe {
        var events = 0
        var boundaries: [DeviceNativeGrantPreparationStore.Boundary] = []
        var failure: DeviceNativeGrantPreparationStore.Boundary?
        var action: ((DeviceNativeGrantPreparationStore.Boundary) throws -> Void)?
        func hit(_ boundary: DeviceNativeGrantPreparationStore.Boundary) throws {
            events += 1
            boundaries.append(boundary)
            try action?(boundary)
            if boundary == failure { failure = nil; throw Fault.injected }
        }
    }
    private final class PackageProbe {
        var events = 0, terminals = 0
        var failure: DevicePackagePreparationStore.Boundary?
        var failDuringSecondProgress = false
        var action: ((DevicePackagePreparationStore.Boundary) throws -> Void)?
        func hit(_ site: DevicePackagePreparationStore.Boundary) throws {
            events += 1
            if site == .afterDirectorySync(.terminal) { terminals += 1 }
            try action?(site)
            if failure == site { failure = nil; throw Fault.injected }
            if failDuringSecondProgress, terminals == 1, site == .afterReplace(.progress) {
                failDuringSecondProgress = false; throw Fault.injected
            }
        }
    }
    private struct PrivateFixture {
        let original: Fixture
        let packageRoot: URL, grantRoot: URL
        let packages: DevicePackagePreparationStore
        let grants: DeviceNativeGrantPreparationStore
        let backend: Backend, probe: GrantProbe, packageProbe: PackageProbe
        let resolution: DevicePackageTerminalResolution
        let joined: DeviceLocalProvisioningIntentStore.NativeJoinReceipt
        var coordinator: DeviceNativeGrantPrivateCoordinator {
            .init(journal: original.journal, structural: original.structural, packages: packages, grants: grants)
        }
    }
    private func privateFixture(generic: Bool = true, count: Int = 1, mixed: Bool = false, preinstalled: Int = 0, unrelatedLatest: Bool = false, distinct: Bool = false) throws -> PrivateFixture {
        let original = try fixture(count: count, generic: generic, mixed: mixed, distinct: distinct)
        let p = try root(), g = try root(), backend = Backend(), probe = GrantProbe(), packageProbe = PackageProbe()
        let scope = DevicePackageProtectedScope(legacyStateRoot: original.journalRoot,
            legacyArchiveRoot: original.structuralRoot, resetRoot: g, cloudRoot: original.journalRoot,
            managementRoot: original.structuralRoot, preferencesRoot: g, otherProtectedRoots: [])
        let packages = DevicePackagePreparationStore(root: p, rootID: original.roots.packageID, protectedScope: scope, boundary: { try packageProbe.hit($0) })
        try packages.initializeExplicit()
        let grants = DeviceNativeGrantPreparationStore(root: g, rootID: original.roots.grantID,
            protectedPaths: [p, original.journalRoot, original.structuralRoot], backend: backend, fault: { try probe.hit($0) })
        try grants.initializeExplicit()
        for input in original.request.packages.prefix(preinstalled) {
            if case .supplied(_, let operation, let value) = input {
                _ = try packages.prepareExact(.init(operationID: operation, package: value))
            }
        }
        if unrelatedLatest { _ = try packages.prepareExact(.init(operationID: UUID(), package: package(generic: false))) }
        let resolution = try packages.resolveRetainedTerminalExact([])
        let joined = try original.coordinator.joinExact(original.request, plan: original.plan, attachment: original.attachment)
        return .init(original: original, packageRoot: p, grantRoot: g, packages: packages, grants: grants,
            backend: backend, probe: probe, packageProbe: packageProbe, resolution: resolution, joined: joined)
    }
    private func prepare(_ f: PrivateFixture) throws -> DeviceNativeGrantPrivateAnchor {
        try f.coordinator.prepareExact(f.original.request, plan: f.original.plan, joined: f.joined, packageResolution: f.resolution)
    }
    private func expectations(_ f: PrivateFixture) -> [DeviceGrantEntryExpectation] {
        f.original.request.packages.map {
            switch $0 {
            case .supplied(let entryID, _, let package): return .init(entryID: entryID, package: package)
            case .retained(let entryID, _, let verified): return .init(entryID: entryID, package: verified.package)
            }
        }
    }
    private func resources(_ f: PrivateFixture, baseline: DeviceStructuralStore.NativeGenesisCheckpoint? = nil) -> DeviceNativeGrantRecoveryResources {
        .init(roots: f.original.roots, delivery: f.original.request.delivery,
            baseline: baseline ?? f.original.request.baseline, candidate: f.original.request.candidate,
            packages: f.original.request.packages)
    }
    private func changedSecretRequest(_ f: PrivateFixture) throws -> (DeviceNativeProvisioningRequest, DeviceValidatedNativeProvisioningPlan) {
        let old = f.original.request.grantInput, changed = Data(repeating: 88, count: old.credentials[0].bytes.count)
        let entries = old.entries.map { old -> DeviceGrantEntryInput in
            var generic = old.generic!
            for index in generic.entries.indices { generic.entries[index].secret = changed }
            return .init(entryID: old.entryID, revision: old.revision, generic: generic,
                         homeAssistant: nil, publicReads: nil, credentialReferences: old.credentialReferences)
        }
        let input = DeviceNativeGrantRevisionInput(schemaVersion: 2, identity: old.identity, owner: old.owner,
            entries: entries, credentials: [.init(revisionID: old.credentials[0].revisionID, bytes: changed)], retainedRevisions: [])
        let qualified = try DeviceNativeGrantRevisionQualifier.qualify(input, expectedEntries: expectations(f))
        let request = DeviceNativeProvisioningRequest(roots: f.original.roots, delivery: f.original.request.delivery,
            grantOperationID: f.original.request.grantOperationID, baseline: f.original.request.baseline,
            candidate: f.original.request.candidate, packages: f.original.request.packages, grantInput: input, qualifiedGrant: qualified)
        let plan = try DeviceNativeProvisioningPlanner.qualify(request)
        XCTAssertEqual(plan.intentBytes, f.original.plan.intentBytes)
        return (request, plan)
    }
    private struct FileEvidence: Equatable { let bytes: Data; let inode: UInt64 }
    private func operationEvidence(_ root: URL) throws -> [String: FileEvidence] {
        var result: [String: FileEvidence] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("operations"), includingPropertiesForKeys: nil) {
            var metadata = stat(); guard lstat(url.path, &metadata) == 0 else { throw Fault.injected }
            result[url.lastPathComponent] = .init(bytes: try Data(contentsOf: url), inode: UInt64(metadata.st_ino))
        }
        return result
    }
    private func packageScope(_ f: PrivateFixture) -> DevicePackageProtectedScope {
        .init(legacyStateRoot: f.original.journalRoot, legacyArchiveRoot: f.original.structuralRoot,
            resetRoot: f.grantRoot, cloudRoot: f.original.journalRoot, managementRoot: f.original.structuralRoot,
            preferencesRoot: f.grantRoot, otherProtectedRoots: [])
    }
    private struct Reconstructed {
        let coordinator: DeviceNativeGrantPrivateCoordinator
        let packages: DevicePackagePreparationStore
        let resources: DeviceNativeGrantRecoveryResources
    }
    private func reconstructed(_ f: PrivateFixture) throws -> Reconstructed {
        let structural = DeviceStructuralStore(root: f.original.structuralRoot, rootID: f.original.roots.structuralID)
        let baseline = try structural.recommitNativeGenesisForDispatchExact(f.original.request.baseline.state, operationID: f.original.request.delivery.nativeOperationID)
        let journal = DeviceLocalProvisioningIntentStore(root: f.original.journalRoot, rootID: f.original.roots.journalID,
            protectedRoots: [f.original.structuralRoot])
        let packages = DevicePackagePreparationStore(root: f.packageRoot, rootID: f.original.roots.packageID, protectedScope: packageScope(f))
        let grants = DeviceNativeGrantPreparationStore(root: f.grantRoot, rootID: f.original.roots.grantID,
            protectedPaths: [f.packageRoot, f.original.journalRoot, f.original.structuralRoot], backend: f.backend)
        return .init(coordinator: .init(journal: journal, structural: structural, packages: packages, grants: grants),
                     packages: packages, resources: resources(f, baseline: baseline))
    }
    private func batch(_ f: PrivateFixture) throws -> DeviceNativeBoundPackageBatch {
        try f.coordinator.preparePackagesExact(f.original.request, anchor: prepare(f))
    }
    private func credentialValues(_ backend: Backend) -> [DeviceGrantCredentialValue] {
        backend.values.filter { $0.key.hasPrefix("credential.") }.map(\.value)
    }
    private func completed(generic: Bool = true, count: Int = 2, distinct: Bool = true) throws -> (PrivateFixture, DeviceNativeBoundCredentialProgress) {
        let f = try privateFixture(generic: generic, count: count, distinct: distinct)
        return (f, try f.coordinator.completeCredentialsExact(f.original.request, batch: batch(f)))
    }

    private func terminal(_ f:PrivateFixture) throws -> DeviceNativeBoundGrantTerminal {
        let progress=try f.coordinator.completeCredentialsExact(f.original.request,batch:batch(f))
        return try f.coordinator.closeNativeGrantExact(f.original.request,progress:progress)
    }
    private func structural(_ f:PrivateFixture)throws->DeviceNativeStructuralCommitAcknowledgment {
        try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:terminal(f))
    }
    private func activationResponse(_ request:DeviceNativeActivationRequestReceipt,digest:String=String(repeating:"a",count:64))throws->Data {
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:request.requestBytes) as? [String:Any])
        object["authorizationDigest"]=digest
        // Deliberately historical dates. Retention/reporting does not revive or assess a lease.
        object["authorizedAt"]="2020-01-01T00:00:00.0000000000000000000000001Z"
        object["expiresAt"]="2020-01-01T00:00:30.0000000000000000000000001Z"
        return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
    }
    private func reportedResponse(_ outgoing:DeviceNativeOutgoingActivatedReceipt,id:UUID)throws->Data {
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:outgoing.bytes) as? [String:Any])
        for key in ["activationRequestId","authorizationDigest","previousGenerationId","resultingGenerationId","renderState"]{object.removeValue(forKey:key)}
        object["receiptId"]=id.uuidString.lowercased();object["receivedAt"]="2026-10-05T12:00:00Z"
        return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
    }
    func testActualHTTPEncoderShapesReserveAllLeafCopies()throws {
        let f=try fixture(),sizes=try f.journal.maximumNativeHTTPEncoderSizesForTesting()
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["method"]),32768)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["binding"]),65536)
        XCTAssertEqual(sizes["reservedCopies"],2*(sizes["method"]!+sizes["binding"]!+sizes["request"]!+sizes["response"]!))
        print("NATIVE_HTTP_PUBLIC_ENCODER_SIZES",sizes.sorted{$0.key < $1.key})
    }
    func testGenuineEmptyEnrollmentGenesisCanSeedCommonInventoryWithoutCloudPackageCompletion() throws {
        let f = try privateFixture(generic: false)
        let commonRoot = try root(), store = DeviceMixedInventoryStore(root: commonRoot, rootID: UUID())
        try store.initializeExplicit()
        try f.coordinator.verifyUnifiedGenesisSourceExact(f.original.request.baseline)
        let resolver = DeviceMixedResourceResolver(native: f.coordinator)
        let source = DeviceMixedNativeSource.genesis(f.original.request.baseline, f.original.roots)
        let original = try resolver.resolveInitialMigrationExact(local: nil, native: source, generationID: UUID())
        XCTAssertTrue(original.snapshot.entries.isEmpty)
        XCTAssertNil(original.snapshot.configuredEntryID)
        let result = try resolver.commitInitialMigrationExact(original, store: store, operationID: UUID(), admissionEnabled: false)
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: result.0)
        XCTAssertEqual(f.backend.adds, 0)
        let terminal = try terminal(f)
        let activation = try f.coordinator.retainNativeActivationRequestExact(f.original.request, terminal: terminal, requestID: UUID())
        _ = try f.coordinator.retainNativeAuthorizationExact(f.original.request, original: activation, response: activationResponse(activation))
        _ = try f.coordinator.commitNativeStructuralExact(f.original.request, terminal: terminal)
        XCTAssertThrowsError(try f.coordinator.verifyUnifiedGenesisSourceExact(f.original.request.baseline))
    }
    func testCompletedStaticSourceRestoresFromActualDurableStoresWithoutCloudStatusOrArchives() throws {
        let f = try privateFixture(generic: false), terminal = try terminal(f)
        let activation = try f.coordinator.retainNativeActivationRequestExact(f.original.request, terminal: terminal, requestID: UUID())
        _ = try f.coordinator.retainNativeAuthorizationExact(f.original.request, original: activation, response: activationResponse(activation))
        let structural = try f.coordinator.commitNativeStructuralExact(f.original.request, terminal: terminal)
        _ = try f.coordinator.completeNativeProvisioningExact(f.original.request, original: structural)
        let reopened = try reconstructed(f)
        let restored = try reopened.coordinator.restoreCompletedStaticSourceExact(operationID: f.original.request.delivery.nativeOperationID,
            grantOperationID: f.original.request.grantOperationID,
            grantRevisionID: f.original.request.grantInput.identity.revisionID, baseline: reopened.resources.baseline)
        XCTAssertEqual(restored.0.candidate, f.original.request.candidate)
        XCTAssertEqual(restored.0.delivery.commandBytes, f.original.request.delivery.commandBytes)
        try reopened.coordinator.verifyUnifiedInventorySourceExact(restored.0, completed: restored.1)
    }
    private final class DisplayTransport: DeviceGrantCredentialTransport, @unchecked Sendable {
        let rootID: UUID
        var values: [String: DeviceGrantCredentialTransportSecret] = [:]
        var adds = 0
        init(rootID: UUID) { self.rootID = rootID }
        func inventory(maximum: Int, visit: (DeviceGrantCredentialObservation) throws -> Void) throws {
            guard values.count <= maximum else { throw DeviceGrantCredentialTransportFailure.capacity }
            for key in values.keys.sorted() { try visit(values[key]!.observation) }
        }
        func read(account: String, maximumBytes: Int) throws -> DeviceGrantCredentialTransportSecret? { values[account] }
        func add(account: String, bytes: Data) throws -> DeviceGrantCredentialObservation {
            guard values[account] == nil else { throw DeviceGrantCredentialTransportFailure.duplicateItem }
            let observation = try DeviceGrantCredentialObservation(account: account, persistentReference: Data(UUID().uuidString.utf8), byteCount: bytes.count)
            values[account] = try .init(observation: observation, bytes: bytes); adds += 1
            return observation
        }
    }
    private func displayLocalSource() throws -> (source: DeviceMixedIncomingLocalResources, transport: DisplayTransport, roots: [URL], manifest: DashboardManifest) {
        let p = try root(), g = try root(), s = try root(), j = try root(), protected = try root()
        let roots = DeviceProvisioningRoots(journalID: UUID(), structuralID: UUID(), packageID: UUID(), grantID: UUID())
        let transport = DisplayTransport(rootID: roots.grantID)
        let session = try DeviceLegacyMigrationSession(packageRoot: p, packageRootID: roots.packageID,
            grantRoot: g, grantRootID: roots.grantID, structuralRoot: s, structuralRootID: roots.structuralID,
            provisioningRoot: j, provisioningRootID: roots.journalID,
            legacyStateRoot: protected.appendingPathComponent("state"), legacyArchiveRoot: protected.appendingPathComponent("archive"),
            resetRoot: protected.appendingPathComponent("reset"), cloudRoot: protected.appendingPathComponent("cloud"),
            managementRoot: protected.appendingPathComponent("management"), preferencesRoot: protected.appendingPathComponent("preferences"),
            otherProtectedRoots: [], credentialTransport: transport, validateRoots: {})
        let package = try package(generic: true), id = UUID(), operation = UUID()
        let screen = DeviceLegacyMigrationScreen(entryID: id, packageOperationID: UUID(), displayName: "Nonselected local",
            revision: package.revision, manifest: package.originalManifestBytes,
            files: Dictionary(uniqueKeysWithValues: package.files.map { ($0.path, $0.bytes) }),
            homeAssistant: nil, generic: nil, publicReads: nil)
        try session.prepareAndCommit(screens: [screen], selected: id,
            owner: .init(role: .controller, publicKey: Array(repeating: 7, count: PairingLimits.identityByteCount)),
            profile: .init(deviceId: "fixture", name: "Fixture"), profileID: "profile",
            operationID: operation, grantOperationID: UUID(), generationID: UUID(), grantRevisionID: UUID(),
            legacyGrantSet: nil, validateOriginal: {})
        return (try DeviceIncomingLocalPreparation(completed: session, operationID: operation).resources,
            transport, [p, g, s, j], package.manifest)
    }
    private func displayResourceSnapshot(_ roots: [URL]) throws -> [String: Data] {
        var values: [String: Data] = [:]
        for root in roots {
            let paths = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let path as URL in paths where try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                values[path.path] = try Data(contentsOf: path)
            }
        }
        return values
    }
    func testDisplayManifestsIncludeNonselectedRetainedAndIncomingLocalAlongsideCloudWithoutMutationAndRejectInvalidGraph() throws {
        let f = try privateFixture(generic: false), terminal = try terminal(f)
        let activation = try f.coordinator.retainNativeActivationRequestExact(f.original.request, terminal: terminal, requestID: UUID())
        _ = try f.coordinator.retainNativeAuthorizationExact(f.original.request, original: activation, response: activationResponse(activation))
        let committed = try f.coordinator.commitNativeStructuralExact(f.original.request, terminal: terminal)
        let completed = try f.coordinator.completeNativeProvisioningExact(f.original.request, original: committed)
        let retained = try displayLocalSource(), incoming = try displayLocalSource()
        let common = try root(), store = DeviceMixedInventoryStore(root: common, rootID: UUID())
        try store.initializeExplicit()
        let resolver = DeviceMixedResourceResolver(local: retained.source.gate, native: f.coordinator)
        let original = try resolver.resolveInitialMigrationExact(local: retained.source.binding,
            native: .completed(f.original.request, completed), generationID: UUID())
        let initial = try resolver.commitInitialMigrationExact(original, store: store, operationID: UUID(), admissionEnabled: true).0
        let current = try resolver.commitIncomingLocalExact(original, store: store, previous: initial,
            source: incoming.source, operationID: incoming.source.operationID, generationID: UUID(),
            retainedEntryIDs: initial.snapshot.entries.map(\.entryID), selected: initial.snapshot.configuredEntryID,
            peerPinHex: String(repeating: "07", count: PairingLimits.identityByteCount))
        let allRoots = retained.roots + incoming.roots + [common, f.packageRoot, f.grantRoot, f.original.journalRoot, f.original.structuralRoot]
        let before = try displayResourceSnapshot(allRoots), adds = f.backend.adds
        let localAdds = retained.transport.adds + incoming.transport.adds
        let manifests = try resolver.displayManifestsExact(original, store: store, current: current)
        XCTAssertEqual(manifests.map(\.dashboardId), current.snapshot.entries.map(\.dashboardID))
        XCTAssertEqual(manifests.count, 3)
        XCTAssertEqual(manifests[0], retained.manifest)
        XCTAssertEqual(manifests[2], incoming.manifest)
        XCTAssertEqual(manifests[0].connections.map(\.alias), ["api"])
        XCTAssertEqual(manifests[2].connections.map(\.alias), ["api"])
        XCTAssertTrue(manifests[1].connections.isEmpty)
        XCTAssertEqual(current.snapshot.configuredEntryID, current.snapshot.entries[1].entryID)
        XCTAssertEqual(try displayResourceSnapshot(allRoots), before)
        XCTAssertEqual(f.backend.adds, adds)
        XCTAssertEqual(retained.transport.adds + incoming.transport.adds, localAdds)
        XCTAssertThrowsError(try resolver.displayManifestsExact(original, store: store, current: initial))
        XCTAssertEqual(try displayResourceSnapshot(allRoots), before)
        let package = try XCTUnwrap(f.original.request.candidate.entries.first)
        let asset = f.packageRoot.appendingPathComponent(package.preparedPackage.directory).appendingPathComponent("index.html")
        let bytes = try Data(contentsOf: asset)
        defer { try? bytes.write(to: asset) }
        try Data("changed fixture".utf8).write(to: asset)
        let damaged = try displayResourceSnapshot(allRoots)
        XCTAssertThrowsError(try resolver.displayManifestsExact(original, store: store, current: current))
        XCTAssertEqual(try displayResourceSnapshot(allRoots), damaged)
        XCTAssertEqual(f.backend.adds, adds)
        XCTAssertEqual(retained.transport.adds + incoming.transport.adds, localAdds)
    }
    func testDurableOriginalActivationAndGenuineCompletedActivatedReporting()throws {
        let f=try privateFixture(generic:true,count:2,distinct:true),t=try terminal(f),id=UUID(),adds=f.backend.adds
        let request=try f.coordinator.retainNativeActivationRequestExact(f.original.request,terminal:t,requestID:id)
        let prefix=f.original.plan.nativeOperationID.uuidString.lowercased()
        XCTAssertEqual(try Data(contentsOf:f.original.journalRoot.appendingPathComponent("operations/"+prefix+".activation.request")),request.requestBytes)
        let raw=try activationResponse(request)
        let auth=try f.coordinator.retainNativeAuthorizationExact(f.original.request,original:request,response:raw)
        try f.coordinator.verifyNativeRetainedAuthorizationExact(f.original.request,original:auth)
        let ack=try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t)
        let complete=try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack)
        let outgoing=try f.coordinator.retainNativeActivatedReceiptExact(f.original.request,completed:complete,authorization:auth)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:outgoing.bytes) as? [String:Any])
        XCTAssertEqual(object["activationRequestId"] as? String,id.uuidString.lowercased())
        XCTAssertEqual(object["authorizationDigest"] as? String,String(repeating:"a",count:64))
        XCTAssertEqual(object["outcome"] as? String,"activated")
        XCTAssertEqual(try Data(contentsOf:f.original.journalRoot.appendingPathComponent("operations/"+prefix+".receipt.request")),outgoing.bytes)
        let receiptID=UUID(),reported=try f.coordinator.retainNativeReceiptAcknowledgmentExact(f.original.request,outgoing:outgoing,response:reportedResponse(outgoing,id:receiptID))
        XCTAssertEqual(reported.receiptID,receiptID);XCTAssertEqual(f.backend.adds,adds)
        XCTAssertThrowsError(try f.original.journal.inspectLatestRetainedIntentExact())
    }
    func testActivationResponseFaultExactRetryAndChangedInputBeforeEffects()throws {
        let f=try privateFixture(),t=try terminal(f),id=UUID()
        let request=try f.coordinator.retainNativeActivationRequestExact(f.original.request,terminal:t,requestID:id)
        let response=try activationResponse(request)
        f.original.probe.journal = .afterWrite(.nativeHTTPBinding)
        XCTAssertThrowsError(try f.coordinator.retainNativeAuthorizationExact(f.original.request,original:request,response:response))
        let before=try operationEvidence(f.original.journalRoot),events=f.original.probe.events,adds=f.backend.adds
        let changed=try activationResponse(request,digest:String(repeating:"b",count:64))
        XCTAssertEqual(changed.count,response.count)
        XCTAssertThrowsError(try f.coordinator.retainNativeAuthorizationExact(f.original.request,original:request,response:changed))
        XCTAssertEqual(try operationEvidence(f.original.journalRoot),before)
        XCTAssertEqual(f.original.probe.events,events);XCTAssertEqual(f.backend.adds,adds)
        let auth=try f.coordinator.retainNativeAuthorizationExact(f.original.request,original:request,response:response)
        try f.coordinator.verifyNativeRetainedAuthorizationExact(f.original.request,original:auth)
    }
    func testActivationRequestWholeScopeExitSuppressesPublicationAndExactRetry()throws {
        let f=try privateFixture(generic:false),t=try terminal(f),id=UUID()
        f.original.probe.journal = .beforeNativeHTTPScopeExit
        XCTAssertThrowsError(try f.coordinator.retainNativeActivationRequestExact(f.original.request,terminal:t,requestID:id))
        let old=try operationEvidence(f.original.journalRoot),events=f.original.probe.events
        XCTAssertThrowsError(try f.coordinator.retainNativeActivationRequestExact(f.original.request,terminal:t,requestID:UUID()))
        XCTAssertEqual(try operationEvidence(f.original.journalRoot),old);XCTAssertEqual(f.original.probe.events,events)
        let valid=try f.coordinator.retainNativeActivationRequestExact(f.original.request,terminal:t,requestID:id)
        XCTAssertEqual(valid.requestID,id)
    }
    func testCompletedRestartRetainsOriginalAuthorizationForOutcomeOnly()throws {
        let f=try privateFixture(),t=try terminal(f),request=try f.coordinator.retainNativeActivationRequestExact(f.original.request,terminal:t,requestID:UUID())
        let auth=try f.coordinator.retainNativeAuthorizationExact(f.original.request,original:request,response:activationResponse(request))
        let ack=try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t)
        _ = try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack)
        let r=try reconstructed(f),original=try r.coordinator.captureNativeCompletedRecoveryExact(operationID:f.original.request.grantOperationID,resources:r.resources)
        let restored=try r.coordinator.completeNativeProvisioningRecoveredExact(original)
        let outgoing=try r.coordinator.retainNativeActivatedReceiptExact(f.original.request,completed:restored,authorization:auth)
        XCTAssertEqual(restored.operationID,f.original.plan.nativeOperationID)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with:outgoing.bytes) as? [String:Any])["authorizationDigest"] as? String,String(repeating:"a",count:64))
    }

    func testGenuineFirstNativeCompletionStaticSharedDistinctKeepsOriginalIntentBytes()throws {
        for (generic,distinct) in [(false,false),(true,false),(true,true)] {
            let f=try privateFixture(generic:generic,count:2,distinct:distinct),ack=try structural(f)
            let original=try snapshot(f.original.journalRoot),adds=f.backend.adds
            let completion=try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack)
            XCTAssertEqual(completion.operationID,ack.operationID)
            for name in ["delivery.intent","delivery.binding","delivery.command","delivery.plan","delivery.confirm","native-join.intent","native-join.binding","native-join.candidate","native-join.confirm"] {
                XCTAssertEqual(try Data(contentsOf:f.original.journalRoot.appendingPathComponent(name)),original[name])
            }
            XCTAssertEqual(f.backend.adds,adds)
            let head=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:f.original.journalRoot.appendingPathComponent("head.json"))) as? [String:Any])
            XCTAssertEqual(head["schemaVersion"] as? Int,3)
            XCTAssertThrowsError(try f.original.journal.inspectLatestRetainedIntentExact())
        }
    }
    func testNativeCompletionExactRetryAndWholeScopeExitSuppression()throws {
        let f=try privateFixture(),ack=try structural(f),op=ack.operationID
        f.original.probe.journal = .beforeNativeCompletionScopeExit
        XCTAssertThrowsError(try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack))
        let receipt=try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack)
        XCTAssertEqual(receipt.operationID,op)
        XCTAssertEqual(try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack).operationID,op)
    }
    func testCapturedCompletionHeadStageMissingOrReplacedBlocksBeforeEffects()throws {
        for replace in [false,true] {
            let f=try privateFixture(),ack=try structural(f)
            f.original.probe.journal = .afterCreate(.nativeCompletionHead)
            XCTAssertThrowsError(try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack))
            let stage=f.original.journalRoot.appendingPathComponent("head.json.stage")
            let bytes=try Data(contentsOf:stage)
            if replace {try bytes.write(to:stage,options:.atomic)}
            else {try FileManager.default.removeItem(at:stage)}
            let before=try snapshot(f.original.journalRoot),events=f.original.probe.events,adds=f.backend.adds
            XCTAssertThrowsError(try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack))
            XCTAssertEqual(before,try snapshot(f.original.journalRoot))
            XCTAssertEqual(events,f.original.probe.events);XCTAssertEqual(adds,f.backend.adds)
        }
    }
    func testSameByteCompletionRecordReplacementBlocksWithoutResourceAdds()throws {
        let f=try privateFixture(),ack=try structural(f)
        _=try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack)
        let url=f.original.journalRoot.appendingPathComponent("native-completion.record")
        let bytes=try Data(contentsOf:url);try bytes.write(to:url,options:.atomic)
        let before=try snapshot(f.original.journalRoot),adds=f.backend.adds
        XCTAssertThrowsError(try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack))
        XCTAssertEqual(before,try snapshot(f.original.journalRoot));XCTAssertEqual(f.backend.adds,adds)
    }
    func testStalePackageCaptureSuppressesCompletionBeforeJournalEffects()throws {
        let f=try privateFixture(),ack=try structural(f)
        _=try f.packages.prepareExact(.init(operationID:UUID(),package:package(generic:false)))
        let before=try snapshot(f.original.journalRoot)
        XCTAssertThrowsError(try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack))
        XCTAssertEqual(before,try snapshot(f.original.journalRoot))
    }
    func testCompletedNativeRestartUsesGenuineGrantAndStructuralRecommitWithoutHeadRewind()throws {
        let f=try privateFixture(count:2,distinct:true),ack=try structural(f)
        _=try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack)
        let before=try snapshot(f.original.journalRoot),r=try reconstructed(f)
        let recovery=try r.coordinator.captureNativeCompletedRecoveryExact(operationID:f.original.request.grantOperationID,resources:r.resources)
        let complete=try r.coordinator.completeNativeProvisioningRecoveredExact(recovery)
        XCTAssertEqual(complete.operationID,ack.operationID)
        XCTAssertEqual(try snapshot(f.original.journalRoot),before)
    }
    func testRecordedHeadRenameUncertaintyRestartsOnlyThroughExactResourceRepair()throws {
        let f=try privateFixture(),ack=try structural(f)
        f.original.probe.journal = .afterReplace(.nativeCompletionHead)
        XCTAssertThrowsError(try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack))
        let originalIntent=try Data(contentsOf:f.original.journalRoot.appendingPathComponent("native-join.intent"))
        let r=try reconstructed(f)
        let recovery=try r.coordinator.captureNativeCompletedRecoveryExact(operationID:f.original.request.grantOperationID,resources:r.resources)
        XCTAssertEqual(try r.coordinator.completeNativeProvisioningRecoveredExact(recovery).operationID,ack.operationID)
        XCTAssertEqual(try Data(contentsOf:f.original.journalRoot.appendingPathComponent("native-join.intent")),originalIntent)
    }
    func testUnknownCompletionMethodFieldRejectsBeforeEffects()throws {
        let f=try privateFixture(),ack=try structural(f)
        _=try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack)
        let path=f.original.journalRoot.appendingPathComponent("native-completion.method")
        var value=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any]);value["approved"]=true
        let handle=try FileHandle(forWritingTo:path);defer{try? handle.close()}
        try handle.truncate(atOffset:0);try handle.write(contentsOf:JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes]))
        let before=try snapshot(f.original.journalRoot),adds=f.backend.adds
        XCTAssertThrowsError(try f.coordinator.completeNativeProvisioningExact(f.original.request,original:ack))
        XCTAssertEqual(try snapshot(f.original.journalRoot),before);XCTAssertEqual(f.backend.adds,adds)
    }
    func testActualMaximumPublicEncoderShapesFitBeforeEffects()throws {
        let sizes=try DeviceLocalProvisioningIntentStore.maximumNativeCompletionEncoderSizesForTesting()
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["method"]),32768)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["binding"]),65536)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["record"]),256*1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["confirmation"]),65536)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["head"]),8192)
        print("Native completion public encoder sizes: \(sizes)")
    }
    #else
    func testPortableDigestDoesNotPromoteUnsupportedLegacyObservation() throws {
        XCTAssertEqual(try DeviceNativeDeliveryAttachmentCodec.hash(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let observation=try DeviceDeliveryObservationCandidate.validating(installationID:UUID(),transitionID:UUID(),generationID:UUID(),entries:[],configuredEntryID:nil)
        XCTAssertThrowsError(try DeviceDeliveryCandidateCodec.observationDigest(observation)) {
            XCTAssertEqual($0 as? DeviceDeliveryCandidateFailure,.digestUnavailable)
        }
        let r=try root(),probe=Probe()
        let journal=DeviceLocalProvisioningIntentStore(root:r,rootID:UUID(),protectedRoots:[],boundary:{try probe.hit($0)})
        try journal.initializeExplicit()
        let before=try snapshot(r),events=probe.events
        let legacy=DevicePersistedState(owner:nil,activeRevision:nil,activeStoredRevision:nil,lastDeployment:nil,savedAt:Date(timeIntervalSince1970:0))
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let bytes=try encoder.encode(legacy)
        _=try DeviceNativeDeliveryAttachmentCodec.hash(bytes)
        XCTAssertEqual(DeviceStructuralStateReader.read(structural:.missing,legacy:.bytes(bytes),expectation:.unbound,packages:[]),.blocked(.digestUnavailable))
        XCTAssertEqual(try snapshot(r),before);XCTAssertEqual(probe.events,events)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:r.appendingPathComponent("operations").path).isEmpty)
        for name in ["native-completion.method","native-completion.binding","native-completion.record","native-completion.confirm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath:r.appendingPathComponent(name).path))
        }
    }
    #endif
}
