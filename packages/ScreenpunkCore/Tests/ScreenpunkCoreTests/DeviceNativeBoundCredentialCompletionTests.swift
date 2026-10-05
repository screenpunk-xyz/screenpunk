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

final class DeviceNativeBoundCredentialCompletionTests:XCTestCase {
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
        let association:[String:Any]=["schemaVersion":1,"operationId":UUID().uuidString.lowercased(),"planId":UUID().uuidString.lowercased(),"installationId":who.installationID.uuidString.lowercased(),"accountId":who.accountID.uuidString.lowercased(),"locationId":who.locationID.uuidString.lowercased(),"transitionId":who.transitionID.uuidString.lowercased(),"planDigest":try DeviceNativeDeliveryAttachmentCodec.hash(rawPlan),"planByteLength":rawPlan.count]
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
        var inventoryOverride: [DeviceGrantCredentialItem]?
        func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {
            if let inventoryOverride { for item in inventoryOverride { try visit(item) }; return }
            for value in values.values { try visit(value.item) }
        }
        func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? { values[account] }
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
    func testTwoDistinctCredentialRevisionsAddedInCanonicalOrderWithOriginalPrivateAndPackageEvidence() throws {
        let f = try privateFixture(count: 2, distinct: true), b = try batch(f)
        let before = try operationEvidence(f.grantRoot), journal = try snapshot(f.original.journalRoot)
        let progress = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
        XCTAssertEqual(credentialValues(f.backend).count, 2); XCTAssertEqual(f.backend.adds, 3)
        let after = try operationEvidence(f.grantRoot)
        for (name, evidence) in before { XCTAssertEqual(after[name], evidence) }
        XCTAssertEqual(try snapshot(f.original.journalRoot), journal)
        XCTAssertFalse(after.keys.contains { $0.contains("terminal") || $0.contains("head") })
        for evidence in after.values { XCTAssertFalse(String(decoding: evidence.bytes, as: UTF8.self).contains("NATIVE_PRIVATE_SECRET_CANARY")) }
    }
    func testMixedGenericHomeAssistantAndPublicSemanticsPreserveExplicitSharedCredentialMapping() throws {
        let f = try privateFixture(count: 2, mixed: true), b = try batch(f)
        let progress = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
        XCTAssertEqual(credentialValues(f.backend).count, 2)
        XCTAssertEqual(f.backend.adds, 3)
        XCTAssertFalse(String(describing: progress).contains("NATIVE_PRIVATE_SECRET_CANARY"))
        XCTAssertTrue(Mirror(reflecting: progress).children.isEmpty)
    }
    func testExplicitSharingConsumesOneCredentialAddition() throws {
        let f = try privateFixture(count: 2), b = try batch(f)
        let progress = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
        XCTAssertEqual(credentialValues(f.backend).count, 1); XCTAssertEqual(f.backend.adds, 2)
    }
    func testGenuineNonemptyStaticSetCompletesZeroCredentials() throws {
        let f = try privateFixture(generic: false, count: 2), b = try batch(f)
        let progress = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
        XCTAssertTrue(credentialValues(f.backend).isEmpty); XCTAssertEqual(f.backend.adds, 1)
    }
    func testDurableFirstReferenceFaultBeforeSecondAddRecoversAcrossReconstructedStores() throws {
        let f = try privateFixture(count: 2, distinct: true), b = try batch(f)
        f.probe.failure = .afterDirectorySync(.credentialConfirmation)
        XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b))
        XCTAssertEqual(credentialValues(f.backend).count, 1)
        let old = f.backend.values, new = try reconstructed(f)
        let original = try new.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: new.resources)
        let progress = try new.coordinator.completeCredentialsRecoveredExact(original)
        try new.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
        XCTAssertEqual(credentialValues(f.backend).count, 2)
        for (account, value) in old { XCTAssertEqual(f.backend.values[account]?.item, value.item); XCTAssertEqual(f.backend.values[account]?.bytes, value.bytes) }
    }
    func testCompletedProgressRestartRequiresExplicitExactRecoveryAndRetainsAllReferences() throws {
        let f = try privateFixture(count: 2, distinct: true), b = try batch(f)
        _ = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        let adds = f.backend.adds, new = try reconstructed(f)
        let original = try new.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: new.resources)
        let progress = try new.coordinator.completeCredentialsRecoveredExact(original)
        try new.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
        XCTAssertEqual(f.backend.adds, adds)
    }
    func testEqualPublicChangedSecretRejectsBeforeEventsAndPreservesOriginalBatch() throws {
        let f = try privateFixture(), b = try batch(f), changed = try changedSecretRequest(f).0
        let events = f.probe.events, adds = f.backend.adds, before = try operationEvidence(f.grantRoot)
        XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(changed, batch: b))
        XCTAssertEqual(f.probe.events, events); XCTAssertEqual(f.backend.adds, adds)
        XCTAssertEqual(try operationEvidence(f.grantRoot), before)
        try f.coordinator.verifyPackageBatchExact(b, request: f.original.request)
    }
    func testLiveUnrecordedCredentialIdentityRepairsButRestartUnknownOrphanIsPreservedBlocked() throws {
        do {
            let f = try privateFixture(), b = try batch(f)
            f.probe.failure = .afterCreate(.credentialItem)
            XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b))
            let adds = f.backend.adds
            let live = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
            let progress = try f.coordinator.completeCredentialsRecoveredExact(live)
            try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
            XCTAssertEqual(f.backend.adds, adds)
        }
        do {
            let f = try privateFixture(), b = try batch(f)
            f.probe.failure = .afterCreate(.credentialItem)
            XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b))
            let adds = f.backend.adds, nodes = try operationEvidence(f.grantRoot), new = try reconstructed(f)
            XCTAssertThrowsError(try new.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: new.resources))
            XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(f.backend.adds, adds)
        }
    }
    func testRecordedCredentialMissingReferenceReplacementOrChangedBytesRejectWithoutEffects() throws {
        for mutation in 0..<3 {
            let f = try privateFixture(), b = try batch(f)
            let progress = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
            let old = try XCTUnwrap(credentialValues(f.backend).first), account = old.item.account
            if mutation == 0 { f.backend.values.removeValue(forKey: account) }
            else if mutation == 1 { f.backend.values[account] = .init(item: .init(account: account, persistentReference: Data("replacement".utf8), byteCount: old.item.byteCount), bytes: old.bytes) }
            else { f.backend.values[account] = .init(item: old.item, bytes: Data(repeating: 88, count: old.bytes.count)) }
            let nodes = try operationEvidence(f.grantRoot), events = f.probe.events, adds = f.backend.adds
            XCTAssertThrowsError(try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request))
            XCTAssertThrowsError(try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f)))
            XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(f.probe.events, events); XCTAssertEqual(f.backend.adds, adds)
        }
    }
    func testSameByteMethodProgressProofAndOriginalPrivateReplacementBlocks() throws {
        for suffix in ["credentials.intent", "credentials.progress", "credentials.confirm", "record", "confirm"] {
            let f = try privateFixture(), b = try batch(f)
            let progress = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
            let url = f.grantRoot.appendingPathComponent("operations").appendingPathComponent(f.original.request.grantOperationID.uuidString.lowercased() + "." + suffix + ".json")
            let bytes = try Data(contentsOf: url); try bytes.write(to: url, options: .atomic)
            let events = f.probe.events, adds = f.backend.adds
            XCTAssertThrowsError(try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request))
            XCTAssertThrowsError(try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f)))
            XCTAssertEqual(f.probe.events, events); XCTAssertEqual(f.backend.adds, adds)
        }
    }
    func testUnknownMetadataAndStrictUnknownDuplicateTrailingAndUnicodeRejectBeforeEffects() throws {
        for kind in 0..<5 {
            let f = try privateFixture(), b = try batch(f)
            _ = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
            let url = f.grantRoot.appendingPathComponent("operations").appendingPathComponent(f.original.request.grantOperationID.uuidString.lowercased() + ".credentials.intent.json")
            let old = try Data(contentsOf: url)
            if kind == 0 { try Data("unknown".utf8).write(to: f.grantRoot.appendingPathComponent("operations/extra")) }
            else {
                var text = String(decoding: old, as: UTF8.self)
                switch kind { case 1: text.insert(contentsOf: "\"unknown\":0,", at: text.index(after: text.startIndex))
                case 2: text.insert(contentsOf: "\"schemaVersion\":1,", at: text.index(after: text.startIndex))
                case 3: text += " true"
                default: text.insert(contentsOf: "\"unknown\":\"\\uD800\",", at: text.index(after: text.startIndex)) }
                // In-place corruption preserves inode so this exercises strict bytes/shape.
                let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
            }
            let nodes = try operationEvidence(f.grantRoot), events = f.probe.events
            XCTAssertThrowsError(try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f)))
            XCTAssertEqual(try operationEvidence(f.grantRoot), nodes); XCTAssertEqual(f.probe.events, events)
        }
    }
    func testThrowingWholeScopeExitSuppressesPublicationAndExactRecoveryRemainsExplicit() throws {
        let f = try privateFixture(), b = try batch(f)
        f.probe.failure = .beforeScopeExit
        XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b))
        XCTAssertThrowsError(try f.grants.captureCredentialCleanupTokenForTesting())
        let original = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let progress = try f.coordinator.completeCredentialsRecoveredExact(original)
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
    }
    func testLateOldCleanupDoesNotInvalidateNewerGenuineProgress() throws {
        let f = try privateFixture(), b = try batch(f)
        _ = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        let old = try f.grants.captureCredentialCleanupTokenForTesting()
        let original = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let newer = try f.coordinator.completeCredentialsRecoveredExact(original)
        try f.grants.discardCredentialPublication(old)
        try f.coordinator.verifyCredentialProgressExact(newer, request: f.original.request)
    }
    func testSameAndOtherInstanceRecoveryEpochChangesRejectOldReceiptAndCapturedRecovery() throws {
        let f = try privateFixture(), b = try batch(f)
        let old = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        let a = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let z = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let newer = try f.coordinator.completeCredentialsRecoveredExact(a)
        XCTAssertThrowsError(try f.coordinator.verifyCredentialProgressExact(old, request: f.original.request))
        XCTAssertThrowsError(try f.coordinator.completeCredentialsRecoveredExact(z))
        try f.coordinator.verifyCredentialProgressExact(newer, request: f.original.request)
        let new = try reconstructed(f), other = try new.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: new.resources)
        _ = try new.coordinator.completeCredentialsRecoveredExact(other)
        XCTAssertThrowsError(try f.coordinator.verifyCredentialProgressExact(newer, request: f.original.request))
    }
    func testSameInstancePackageMutationRejectsOriginalBeforeJournalOrPackageSync() throws {
        let f = try privateFixture(), b = try batch(f)
        _ = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        let original = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        _ = try f.packages.resolveRetainedTerminalExact(f.original.request.candidate.entries.map(\.preparedPackage))
        let j = try snapshot(f.original.journalRoot), p = try operationEvidence(f.packageRoot)
        let events = f.packageProbe.events, journalEvents = f.original.probe.events, adds = f.backend.adds
        XCTAssertThrowsError(try f.coordinator.completeCredentialsRecoveredExact(original))
        XCTAssertEqual(try snapshot(f.original.journalRoot), j); XCTAssertEqual(try operationEvidence(f.packageRoot), p)
        XCTAssertEqual(f.packageProbe.events, events); XCTAssertEqual(f.original.probe.events, journalEvents); XCTAssertEqual(f.backend.adds, adds)
    }
    func testPendingPackageAndMappingFailureRejectBeforeJournalOrPackageEffects() throws {
        let f = try privateFixture(), b = try batch(f)
        _ = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        let original = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let pending = try package(generic: false)
        f.packageProbe.failure = .afterReplace(.intent)
        XCTAssertThrowsError(try f.packages.prepareExact(.init(operationID: UUID(), package: pending)))
        let j = try snapshot(f.original.journalRoot), p = try operationEvidence(f.packageRoot)
        let events = f.packageProbe.events, journalEvents = f.original.probe.events
        XCTAssertThrowsError(try f.coordinator.completeCredentialsRecoveredExact(original))
        XCTAssertEqual(try snapshot(f.original.journalRoot), j); XCTAssertEqual(try operationEvidence(f.packageRoot), p)
        XCTAssertEqual(f.packageProbe.events, events); XCTAssertEqual(f.original.probe.events, journalEvents)
        let bad = DeviceNativeGrantRecoveryResources(roots: f.original.roots, delivery: f.original.request.delivery,
            baseline: f.original.request.baseline, candidate: f.original.request.candidate, packages: [])
        XCTAssertThrowsError(try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: bad))
        XCTAssertEqual(f.original.probe.events, journalEvents); XCTAssertEqual(f.packageProbe.events, events)
    }
    func testJournalChangesDuringOutsidePackageRepairSuppressCredentialsAndAck() throws {
        let f = try privateFixture(), b = try batch(f)
        let old = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        let original = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let adds = f.backend.adds
        f.packageProbe.action = { site in
            if site == .afterFileSync(.binding) {
                f.packageProbe.action = nil
                let owned = f.original.journalRoot.appendingPathComponent("native-join.confirm")
                // Owned synthetic fault: no ordinary nested API and no production callback.
                let bytes = try Data(contentsOf: owned); try bytes.write(to: owned, options: .atomic)
            }
        }
        XCTAssertThrowsError(try f.coordinator.completeCredentialsRecoveredExact(original))
        XCTAssertEqual(f.backend.adds, adds)
        XCTAssertThrowsError(try f.coordinator.verifyCredentialProgressExact(old, request: f.original.request))
    }
    func testBackendAndFaultNestedEntryThrowPromptlyWithoutMutationCapability() throws {
        let f = try privateFixture(), b = try batch(f)
        var rejected = false
        f.backend.action = {
            do { _ = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: self.resources(f)) }
            catch { rejected = true }
        }
        let progress = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        XCTAssertTrue(rejected); f.backend.action = nil
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
    }
    func testFaultHookNestedFixedCommandCannotBorrowMutationCapability() throws {
        let f = try privateFixture(), b = try batch(f)
        var rejected = false
        f.probe.action = { site in
            if site == .afterWrite(.credentialProgress) {
                f.probe.action = nil
                do { _ = try f.coordinator.completeCredentialsExact(f.original.request, batch: b) }
                catch { rejected = true }
            }
        }
        let progress = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        XCTAssertTrue(rejected)
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
    }
    func testOriginalRootBindingAndGenesisReplacementRejectWithoutCredentialEffects() throws {
        for name in ["root-binding.json", "genesis.json"] {
            let f = try privateFixture(), b = try batch(f)
            let url = f.grantRoot.appendingPathComponent(name), bytes = try Data(contentsOf: url)
            try bytes.write(to: url, options: .atomic)
            let evidence = try operationEvidence(f.grantRoot), adds = f.backend.adds, events = f.probe.events
            XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b))
            XCTAssertEqual(try operationEvidence(f.grantRoot), evidence)
            XCTAssertEqual(f.backend.adds, adds); XCTAssertEqual(f.probe.events, events)
        }
    }
    func testBindingFileSyncFaultSuppressesAckAndRequiresFreshExplicitCapture() throws {
        let f = try privateFixture(), b = try batch(f)
        f.probe.failure = .afterFileSync(.rootBinding)
        XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b))
        XCTAssertThrowsError(try f.grants.captureCredentialCleanupTokenForTesting())
        let old = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        f.probe.failure = .afterFileSync(.rootBinding)
        XCTAssertThrowsError(try f.coordinator.completeCredentialsRecoveredExact(old))
        XCTAssertThrowsError(try f.coordinator.completeCredentialsRecoveredExact(old))
        let fresh = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let progress = try f.coordinator.completeCredentialsRecoveredExact(fresh)
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
    }
    func testBoundedCapacityInventoryRejectsBeforeAnyCredentialEffects() throws {
        let f = try privateFixture(), b = try batch(f)
        f.backend.inventoryOverride = Array(f.backend.values.values.map(\.item)) + (0..<4225).map { index in
            DeviceGrantCredentialItem(account: "credential." + UUID().uuidString.lowercased(), persistentReference: Data("ref-\(index)".utf8), byteCount: 8192)
        }
        let evidence = try operationEvidence(f.grantRoot), events = f.probe.events, adds = f.backend.adds
        XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b))
        XCTAssertEqual(try operationEvidence(f.grantRoot), evidence); XCTAssertEqual(f.probe.events, events); XCTAssertEqual(f.backend.adds, adds)
    }
    func testAllCredentialMetadataFaultBoundariesRequireExactLiveRecoveryWithoutExtraAdds() throws {
        let kinds: [DeviceNativeGrantPreparationStore.Kind] = [.credentialMethod, .credentialBinding, .credentialProgress, .credentialConfirmation]
        for kind in kinds {
            let sites: [DeviceNativeGrantPreparationStore.Boundary] = [.afterCreate(kind), .afterWrite(kind),
                .afterFileSync(kind), .beforeReplace(kind), .afterReplace(kind), .afterDirectorySync(kind)]
            for site in sites {
                let f = try privateFixture(count: 2, distinct: true), b = try batch(f)
                f.probe.failure = site
                XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b), "\(site)")
                let original = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
                let progress = try f.coordinator.completeCredentialsRecoveredExact(original)
                try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
                XCTAssertEqual(credentialValues(f.backend).count, 2); XCTAssertEqual(f.backend.adds, 3)
            }
        }
    }
    func testUnboundMetadataCreateAfterCrashPreservesUnknownOrphanAndDoesNotAdopt() throws {
        let f = try privateFixture(), b = try batch(f)
        f.probe.failure = .afterCreate(.credentialMethod)
        XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b))
        let evidence = try operationEvidence(f.grantRoot), new = try reconstructed(f), adds = f.backend.adds
        XCTAssertThrowsError(try new.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: new.resources))
        XCTAssertEqual(try operationEvidence(f.grantRoot), evidence); XCTAssertEqual(f.backend.adds, adds)
    }
    func testLiveCapturedMethodDeletionRejectsBeforeEffectsAndExactRestorationAllowsRetry() throws {
        let f = try privateFixture(), b = try batch(f)
        f.probe.failure = .afterWrite(.credentialMethod)
        XCTAssertThrowsError(try f.coordinator.completeCredentialsExact(f.original.request, batch: b))
        let name = f.original.request.grantOperationID.uuidString.lowercased() + ".credentials.intent.json.stage"
        let file = f.grantRoot.appendingPathComponent("operations").appendingPathComponent(name)
        let holdingRoot = try root(), holding = holdingRoot.appendingPathComponent(name + ".owned-holding")
        try FileManager.default.moveItem(at: file, to: holding)
        let evidence = try operationEvidence(f.grantRoot), events = f.probe.events, adds = f.backend.adds
        XCTAssertThrowsError(try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f)))
        XCTAssertEqual(try operationEvidence(f.grantRoot), evidence); XCTAssertEqual(f.probe.events, events); XCTAssertEqual(f.backend.adds, adds)
        try FileManager.default.moveItem(at: holding, to: file)
        let original = try f.coordinator.captureCredentialRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let progress = try f.coordinator.completeCredentialsRecoveredExact(original)
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
    }
    func testActualGenuineReservationEncoderRunsBeforeCredentialEffects() throws {
        let f = try privateFixture(count: 2, distinct: true)
        f.backend.referenceBytes = 1024
        let b = try batch(f)
        let adds = f.backend.adds, events = f.probe.events, boundaryCount = f.probe.boundaries.count, before = try operationEvidence(f.grantRoot)
        let sizes = try f.coordinator.credentialReservationSizesForTesting(f.original.request, batch: b)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["method"]), 512 * 1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["binding"]), 2 * 1024 * 1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["reservedPublicBytes"]), 128 * 1024 * 1024)
        print("GENUINE_RESERVATION_BYTES", sizes)
        print("RESERVATION_SEAMS", Array(f.probe.boundaries.dropFirst(boundaryCount)))
        XCTAssertEqual(f.backend.adds, adds); XCTAssertEqual(f.probe.events, events + 1)
        XCTAssertEqual(Array(f.probe.boundaries.dropFirst(boundaryCount)), [.beforeScopeExit])
        XCTAssertEqual(try operationEvidence(f.grantRoot), before)
        try f.coordinator.verifyPackageBatchExact(b, request: f.original.request)
    }
    func testOldNativePrivateAndLegacyGrantConsumersRemainBlockedByProgress() throws {
        let f = try privateFixture(), b = try batch(f)
        let progress = try f.coordinator.completeCredentialsExact(f.original.request, batch: b)
        XCTAssertThrowsError(try f.coordinator.verifyPackageBatchExact(b, request: f.original.request))
        XCTAssertThrowsError(try f.grants.inspectRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f), expectedEntries: expectations(f)))
        let legacyScope = DevicePackageProtectedScope(legacyStateRoot: f.original.journalRoot,
            legacyArchiveRoot: f.original.structuralRoot, resetRoot: f.packageRoot,
            cloudRoot: f.original.journalRoot, managementRoot: f.original.structuralRoot,
            preferencesRoot: f.packageRoot, otherProtectedRoots: [])
        let legacy = DeviceGrantPreparationStore(root: f.grantRoot, rootID: f.original.roots.grantID, protectedScope: legacyScope, backend: f.backend)
        XCTAssertThrowsError(try legacy.initializeExplicit())
        try f.coordinator.verifyCredentialProgressExact(progress, request: f.original.request)
    }
    #endif
    func testActualMaximumPublicEncoderShapesIncludeBase64AndFitDeclaredCeilings() throws {
        // Synthetic metadata sizing only; these values cannot become a receipt or operation.
        let sizes = try DeviceNativeGrantPreparationStore.maximumCredentialEncoderSizesForTesting()
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["method"]), 512 * 1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["binding"]), 2 * 1024 * 1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["progress"]), 1024 * 1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["confirmation"]), 8 * 1024)
        XCTAssertGreaterThan(try XCTUnwrap(sizes["binding"]), 1024 * 1024)
    }
}
