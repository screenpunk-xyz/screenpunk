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

final class DeviceNativeBoundGrantTerminalTests:XCTestCase {
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
            entries.append(try .validating(entryID:entryID,displayName:"Explicit household name",package:descriptor,preparedPackage:reference))
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
        let baseline = try structural.initializeNativeGenesisExplicit(f.original.request.baseline.state)
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
    func testTwoDistinctCredentialsCloseGenuineTerminalWithoutBackendAddsOrJournalCompletion() throws {
        let (f, progress) = try completed()
        let adds = f.backend.adds, journal = try snapshot(f.original.journalRoot), before = try operationEvidence(f.grantRoot)
        let receipt = try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)
        try f.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
        XCTAssertEqual(f.backend.adds, adds); XCTAssertEqual(credentialValues(f.backend).count, 2)
        XCTAssertEqual(try snapshot(f.original.journalRoot), journal)
        let after = try operationEvidence(f.grantRoot)
        for (name, evidence) in before { XCTAssertEqual(after[name], evidence) }
        XCTAssertNotNil(try? Data(contentsOf: f.grantRoot.appendingPathComponent("native-head.json")))
        XCTAssertThrowsError(try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request))
    }
    func testExplicitSharingAndStaticNonemptyZeroCredentialsCloseWithoutSyntheticEmptyDelivery() throws {
        for generic in [true, false] {
            let (f, progress) = try completed(generic: generic, count: 2, distinct: false)
            let adds = f.backend.adds
            let receipt = try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)
            try f.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
            XCTAssertEqual(f.backend.adds, adds)
            XCTAssertEqual(credentialValues(f.backend).count, generic ? 1 : 0)
            XCTAssertEqual(f.original.request.candidate.entries.count, 2)
        }
    }
    func testCompletedTerminalReconstructedRecoveryRequiresOriginalRecordedRefsAndExactRecommit() throws {
        let (f, progress) = try completed()
        _ = try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)
        let adds = f.backend.adds, old = try operationEvidence(f.grantRoot), new = try reconstructed(f)
        let recovery = try new.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: new.resources)
        let receipt = try new.coordinator.closeNativeGrantRecoveredExact(recovery)
        try new.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
        XCTAssertEqual(f.backend.adds, adds); XCTAssertEqual(try operationEvidence(f.grantRoot), old)
    }
    func testEveryTerminalBoundaryLiveRecoveryKeepsRecordedPrivateAndCredentialReferences() throws {
        let kinds: [DeviceNativeGrantPreparationStore.Kind] = [.terminalIntent, .terminalBinding, .terminalRecord,
            .terminalConfirmation, .terminalHead, .terminalHeadConfirmation]
        for kind in kinds {
            let sites: [DeviceNativeGrantPreparationStore.Boundary] = [.afterCreate(kind), .afterWrite(kind), .afterFileSync(kind),
                .beforeReplace(kind), .afterReplace(kind), .afterDirectorySync(kind)]
            for site in sites {
                let (f, progress) = try completed()
                let adds = f.backend.adds, values = f.backend.values
                f.probe.failure = site
                XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress), "\(site)")
                let recovery = try f.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
                let receipt = try f.coordinator.closeNativeGrantRecoveredExact(recovery)
                try f.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
                XCTAssertEqual(f.backend.adds, adds); XCTAssertEqual(f.backend.values.mapValues(\.item), values.mapValues(\.item))
            }
        }
    }
    func testRecordedPartialHeadAndTerminalStagesRepairAfterRestartWithoutFreshInodeAdoption() throws {
        for site in [DeviceNativeGrantPreparationStore.Boundary.afterReplace(.terminalRecord), .afterReplace(.terminalHead), .afterDirectorySync(.terminalHeadConfirmation)] {
            let (f, progress) = try completed()
            f.probe.failure = site
            XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
            let adds = f.backend.adds, new = try reconstructed(f)
            let recovery = try new.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: new.resources)
            let receipt = try new.coordinator.closeNativeGrantRecoveredExact(recovery)
            try new.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
            XCTAssertEqual(f.backend.adds, adds)
        }
    }
    func testUnknownPrebindingCreationOrphanIsPreservedAndRestartCannotAdoptIt() throws {
        for kind in [DeviceNativeGrantPreparationStore.Kind.terminalIntent, .terminalRecord, .terminalBinding] {
            let (f, progress) = try completed()
            f.probe.failure = .afterCreate(kind)
            XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
            let nodes = try operationEvidence(f.grantRoot), root = try snapshot(f.grantRoot), adds = f.backend.adds, new = try reconstructed(f)
            XCTAssertThrowsError(try new.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: new.resources))
            XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(try snapshot(f.grantRoot), root); XCTAssertEqual(f.backend.adds, adds)
        }
    }
    func testEqualPublicChangedSecretRejectsBeforeTerminalEpochAndPreservesOriginalProgress() throws {
        let (f, progress) = try completed(count: 1)
        let changed = try changedSecretRequest(f).0
        let nodes = try operationEvidence(f.grantRoot), adds = f.backend.adds, boundaryCount = f.probe.boundaries.count
        XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(changed, progress: progress))
        XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(f.backend.adds, adds)
        XCTAssertTrue(f.probe.boundaries.dropFirst(boundaryCount).allSatisfy { $0 == .beforeScopeExit })
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
    }
    func testMissingOrReplacedRecordedPrivateAndCredentialItemsBlockTerminalAcknowledgment() throws {
        for credential in [false, true] {
            let (f, progress) = try completed()
            let old = try XCTUnwrap(f.backend.values.first(where: { credential ? $0.key.hasPrefix("credential.") : $0.key.hasPrefix("attempt.") }))
            f.backend.values.removeValue(forKey: old.key)
            let nodes = try operationEvidence(f.grantRoot), adds = f.backend.adds
            XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
            XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(f.backend.adds, adds)
        }
    }
    func testSameByteHeadProofAndTerminalReplacementBlocksCapturedReplayAcrossInstances() throws {
        for suffix in ["head", "proof", "record", "binding", "intent"] {
            let (f, progress) = try completed()
            let receipt = try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)
            let name = f.original.request.grantOperationID.uuidString.lowercased() + ".terminal." + suffix + ".json"
            let path = suffix == "head" ? f.grantRoot.appendingPathComponent("native-head.json") : suffix == "proof" ? f.grantRoot.appendingPathComponent("native-head.confirm") : f.grantRoot.appendingPathComponent("operations/" + name)
            let bytes = try Data(contentsOf: path); try bytes.write(to: path, options: .atomic)
            XCTAssertThrowsError(try f.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request))
            XCTAssertThrowsError(try f.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f)))
        }
    }
    func testCapturedCandidateDeletionRejectsWithoutRecreationOrEffectsAndExactInodeRestoreRepairs() throws {
        let (f, progress) = try completed()
        f.probe.failure = .afterCreate(.terminalRecord)
        XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
        let file = f.grantRoot.appendingPathComponent("operations/" + f.original.request.grantOperationID.uuidString.lowercased() + ".terminal.record.json.stage")
        let holding = try root().appendingPathComponent("held")
        try FileManager.default.moveItem(at: file, to: holding)
        let events = f.probe.events
        XCTAssertThrowsError(try f.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f)))
        XCTAssertEqual(f.probe.events, events)
        try FileManager.default.moveItem(at: holding, to: file)
        let recovery = try f.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let receipt = try f.coordinator.closeNativeGrantRecoveredExact(recovery)
        try f.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
    }
    func testScopeExitFaultCannotPublishTerminalOrReleaseJournalCapacity() throws {
        let (f, progress) = try completed()
        let journal = try snapshot(f.original.journalRoot)
        f.probe.failure = .beforeScopeExit
        XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
        XCTAssertEqual(try snapshot(f.original.journalRoot), journal)
        let recovery = try f.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let receipt = try f.coordinator.closeNativeGrantRecoveredExact(recovery)
        try f.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
    }
    func testFaultReentryCannotMintTerminalMutationOrDeadlock() throws {
        let (f, progress) = try completed()
        var rejected = false
        f.probe.action = { site in
            guard site == .afterWrite(.terminalIntent), !rejected else { return }
            XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)); rejected = true
        }
        let receipt = try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)
        XCTAssertTrue(rejected); try f.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
    }
    func testBackendReadReentryIsRejectedBeforeLockAndOuterTerminalStillCompletes() throws {
        let (f, progress) = try completed()
        var rejected = false
        f.backend.readAction = {
            guard !rejected else { return }
            XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
            rejected = true
        }
        let receipt = try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)
        XCTAssertTrue(rejected); try f.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
    }
    func testStrictUnknownDuplicateAndExtraTerminalLeavesRejectBeforeAnyRepair() throws {
        for mutation in 0..<4 {
            let (f, progress) = try completed()
            _ = try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)
            let file = f.grantRoot.appendingPathComponent("operations/" + f.original.request.grantOperationID.uuidString.lowercased() + ".terminal.intent.json")
            if mutation == 0 { try Data("unknown".utf8).write(to: f.grantRoot.appendingPathComponent("operations/extra")) }
            else {
                var text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
                if mutation == 1 { text.insert(contentsOf: "\"schemaVersion\":1,", at: text.index(after: text.startIndex)) }
                else if mutation == 2 { text += " true" }
                else { text.insert(contentsOf: "\"unknown\":\"\\uD800\",", at: text.index(after: text.startIndex)) }
                let h = try FileHandle(forWritingTo: file); try h.truncate(atOffset: 0); try h.write(contentsOf: Data(text.utf8)); try h.close()
            }
            let nodes = try operationEvidence(f.grantRoot), adds = f.backend.adds
            XCTAssertThrowsError(try f.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f)))
            XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(f.backend.adds, adds)
        }
    }
    func testOrdinaryNativePrivateProgressAndLocalGrantConsumersCannotAdvanceTerminal() throws {
        let (f, progress) = try completed()
        let receipt = try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)
        XCTAssertThrowsError(try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request))
        XCTAssertThrowsError(try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f)))
        XCTAssertThrowsError(try f.grants.initializeExplicit())
        try f.coordinator.verifyNativeGrantTerminalExact(receipt, request: f.original.request)
    }
    func testActualGenuineReservationRunsBeforeTerminalEffectsAndOriginalProgressStaysValid() throws {
        let (f, progress) = try completed()
        let before = try operationEvidence(f.grantRoot), adds = f.backend.adds
        let sizes = try f.coordinator.terminalReservationSizesForTesting(f.original.request, progress: progress)
        print("NATIVE_TERMINAL_GENUINE_ENCODER_BYTES", sizes)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["reservedPublicBytes"]), 128 * 1024 * 1024)
        XCTAssertEqual(try operationEvidence(f.grantRoot), before); XCTAssertEqual(f.backend.adds, adds)
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
    }
    func testCapacitySentinelAndOriginalPackageEpochRejectBeforeTerminalEffects() throws {
        do {
            let (f, progress) = try completed()
            f.backend.inventoryOverride = Array(f.backend.values.values.map(\.item)) + (0..<4225).map { index in
                DeviceGrantCredentialItem(account: "credential." + UUID().uuidString.lowercased(),
                    persistentReference: Data("capacity-\(index)".utf8), byteCount: 8192)
            }
            let nodes = try operationEvidence(f.grantRoot), adds = f.backend.adds
            XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
            XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(f.backend.adds, adds)
        }
        do {
            let (f, progress) = try completed()
            _ = try f.packages.resolveRetainedTerminalExact(f.original.request.candidate.entries.map(\.preparedPackage))
            let nodes = try operationEvidence(f.grantRoot), adds = f.backend.adds
            XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
            XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(f.backend.adds, adds)
        }
    }
    func testActualBackendSecretMutationAtFinalScopeExitSuppressesAcknowledgment() throws {
        let (f, progress) = try completed()
        var mutated = false
        f.probe.action = { site in
            guard site == .beforeScopeExit, !mutated else { return }
            let old = try XCTUnwrap(self.credentialValues(f.backend).first)
            f.backend.values[old.item.account] = .init(item: old.item, bytes: Data(repeating: 88, count: old.bytes.count))
            mutated = true
        }
        XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
        XCTAssertTrue(mutated); XCTAssertThrowsError(try f.grants.captureTerminalCleanupTokenForTesting())
    }
    func testLateOldCleanupAndSameTipRecommitDoNotRenewOrDestroyNewerQualification() throws {
        let (f, progress) = try completed()
        let oldReceipt = try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress)
        let old = try f.grants.captureTerminalCleanupTokenForTesting()
        let recovery = try f.coordinator.captureNativeGrantTerminalRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let newReceipt = try f.coordinator.closeNativeGrantRecoveredExact(recovery)
        try f.grants.discardTerminalPublication(old)
        try f.coordinator.verifyNativeGrantTerminalExact(newReceipt, request: f.original.request)
        XCTAssertThrowsError(try f.coordinator.verifyNativeGrantTerminalExact(oldReceipt, request: f.original.request))
        XCTAssertThrowsError(try f.coordinator.closeNativeGrantRecoveredExact(recovery))
    }
    func testRootBindingAndGenesisReplacementRejectBeforeTerminalEffects() throws {
        for name in ["root-binding.json", "genesis.json"] {
            let (f, progress) = try completed()
            let file = f.grantRoot.appendingPathComponent(name), bytes = try Data(contentsOf: file)
            try bytes.write(to: file, options: .atomic)
            let nodes = try operationEvidence(f.grantRoot), adds = f.backend.adds
            XCTAssertThrowsError(try f.coordinator.closeNativeGrantExact(f.original.request, progress: progress))
            XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(f.backend.adds, adds)
        }
    }
    #endif
    func testActualMaximumPublicEncoderShapesAccountForEveryBase64Reference() throws {
        let sizes = try DeviceNativeGrantPreparationStore.maximumTerminalEncoderSizesForTesting()
        print("NATIVE_TERMINAL_MAXIMUM_PUBLIC_ENCODER_BYTES", sizes)
        for (name, limit) in [("intent", 512 * 1024), ("binding", 2 * 1024 * 1024), ("record", 1024 * 1024),
                              ("confirmation", 8 * 1024), ("head", 32 * 1024), ("headConfirmation", 8 * 1024)] {
            XCTAssertLessThanOrEqual(try XCTUnwrap(sizes[name]), limit)
        }
        XCTAssertGreaterThan(try XCTUnwrap(sizes["record"]), 396 * 1024)
    }
}
