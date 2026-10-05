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

final class DeviceNativeBoundPackagePreparationTests:XCTestCase {
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
    private func fixture(count:Int=1,generic:Bool=false,mixed:Bool=false)throws->Fixture {
        let j=try root(),s=try root(),roots=DeviceProvisioningRoots(journalID:UUID(),structuralID:UUID(),packageID:UUID(),grantID:UUID()),probe=Probe()
        let journal=DeviceLocalProvisioningIntentStore(root:j,rootID:roots.journalID,protectedRoots:[s],boundary:{try probe.hit($0)})
        let structural=DeviceStructuralStore(root:s,rootID:roots.structuralID,boundary:{try probe.hit($0)})
        try journal.initializeExplicit();try structural.initializeExplicit()
        let who=owner,initial=try empty(who),baseline=try structural.initializeNativeGenesisExplicit(initial),desired=UUID(),nativeOperation=UUID(),grantOperation=UUID()
        var entries:[DeviceNativeStructuralEntry]=[],inputs:[DeviceProvisioningPackageInput]=[],grantEntries:[DeviceGrantEntryInput]=[],expectations:[DeviceGrantEntryExpectation]=[]
        let secret=Data("NATIVE_PRIVATE_SECRET_CANARY".utf8),credential=UUID(),homeCredential=UUID()
        for _ in 0..<count {
            let package=try package(generic:generic,mixed:mixed),entryID=UUID(),op=UUID()
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
        let input=DeviceNativeGrantRevisionInput(schemaVersion:2,identity:.init(rootID:roots.grantID,revisionID:UUID()),owner:who,entries:grantEntries,credentials:(generic ? [.init(revisionID:credential,bytes:secret)]:[]) + (mixed ? [.init(revisionID:homeCredential,bytes:secret)]:[]),retainedRevisions:[])
        let qualified=try DeviceNativeGrantRevisionQualifier.qualify(input,expectedEntries:expectations)
        let request=DeviceNativeProvisioningRequest(roots:roots,delivery:delivery,grantOperationID:grantOperation,baseline:baseline,candidate:candidate,packages:inputs,grantInput:input,qualifiedGrant:qualified)
        let plan=try DeviceNativeProvisioningPlanner.qualify(request),attachment=try journal.publishDeliveryAttachmentExact(delivery)
        return .init(journalRoot:j,structuralRoot:s,roots:roots,journal:journal,structural:structural,probe:probe,request:request,plan:plan,attachment:attachment)
    }
    private final class Backend: DeviceGrantCredentialBackend, @unchecked Sendable {
        var values: [String: DeviceGrantCredentialValue] = [:]
        var adds = 0
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
            let item = DeviceGrantCredentialItem(account: account, persistentReference: Data(UUID().uuidString.utf8), byteCount: bytes.count)
            values[account] = .init(item: item, bytes: bytes)
            return item
        }
    }
    private final class GrantProbe {
        var events = 0
        var failure: DeviceNativeGrantPreparationStore.Boundary?
        func hit(_ boundary: DeviceNativeGrantPreparationStore.Boundary) throws {
            events += 1
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
    private func privateFixture(generic: Bool = true, count: Int = 1, mixed: Bool = false, preinstalled: Int = 0, unrelatedLatest: Bool = false) throws -> PrivateFixture {
        let original = try fixture(count: count, generic: generic, mixed: mixed)
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
    private func retainedRequest(_ f: PrivateFixture) throws -> DeviceNativeProvisioningRequest {
        let inputs = try f.original.request.packages.map { input -> DeviceProvisioningPackageInput in
            guard case .supplied(let id, let operation, let value) = input else { return input }
            let ref = try PackagePreparationCodec.expectedReference(.init(operationID: operation, package: value), rootID: f.original.roots.packageID)
            let receipt = try f.packages.resolveRetainedTerminalExact([ref]).receipts[0]
            return .retained(entryID: id, reference: ref, verified: try f.packages.verify(receipt))
        }
        return .init(roots: f.original.roots, delivery: f.original.request.delivery, grantOperationID: f.original.request.grantOperationID,
            baseline: f.original.request.baseline, candidate: f.original.request.candidate, packages: inputs,
            grantInput: f.original.request.grantInput, qualifiedGrant: f.original.request.qualifiedGrant)
    }
    func testGenuineTwoDistinctNativePackagesAreDurableWithoutCredentialOrStructuralEffects() throws {
        let f = try privateFixture(count: 2), anchor = try prepare(f)
        let journal = try snapshot(f.original.journalRoot), structural = try snapshot(f.original.structuralRoot)
        let grant = try operationEvidence(f.grantRoot)
        let batch = try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor)
        try f.coordinator.verifyPackageBatchExact(batch, request: f.original.request)
        XCTAssertEqual(try operationEvidence(f.packageRoot).count, 2)
        XCTAssertEqual(f.backend.adds, 1); XCTAssertEqual(try operationEvidence(f.grantRoot), grant)
        XCTAssertEqual(try snapshot(f.original.journalRoot), journal); XCTAssertEqual(try snapshot(f.original.structuralRoot), structural)
        XCTAssertThrowsError(try f.coordinator.verifyExact(anchor, request: f.original.request, packageResolution: f.resolution))
    }
    func testStaticOnlyPackageBatchUsesGenuinePrivateAttemptButNoCredentials() throws {
        let f = try privateFixture(generic: false, count: 2), anchor = try prepare(f)
        let batch = try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor)
        try f.coordinator.verifyPackageBatchExact(batch, request: f.original.request)
        XCTAssertEqual(f.backend.values.count, 1)
        XCTAssertTrue(f.backend.values.keys.allSatisfy { $0.hasPrefix("attempt.") })
    }
    func testSharedMixedGenericHomeAssistantPublicGrantBytesRemainPrivateOnly() throws {
        let f = try privateFixture(count: 2, mixed: true), anchor = try prepare(f)
        let batch = try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor)
        try f.coordinator.verifyPackageBatchExact(batch, request: f.original.request)
        XCTAssertEqual(f.backend.adds, 1); XCTAssertEqual(f.backend.values.count, 1)
    }
    func testPendingSecondPackageRestartRetainsFirstAndRetriesExactOriginalOperation() throws {
        let f = try privateFixture(count: 2), anchor = try prepare(f)
        f.packageProbe.failDuringSecondProgress = true
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        XCTAssertEqual(f.packageProbe.terminals, 1)
        guard case .supplied(_, let firstOp, _) = f.original.request.packages[0] else { return XCTFail("fixture") }
        let filename = firstOp.uuidString.lowercased() + ".json"
        let firstEvidence = try XCTUnwrap(operationEvidence(f.packageRoot)[filename])
        let restarted = try reconstructed(f)
        let original = try restarted.coordinator.capturePackagesRecoveryExact(operationID: f.original.request.grantOperationID,
            resources: restarted.resources)
        let batch = try restarted.coordinator.preparePackagesRecoveredExact(original)
        XCTAssertEqual(try operationEvidence(f.packageRoot)[filename], firstEvidence)
        XCTAssertEqual(try operationEvidence(f.packageRoot).count, 2); XCTAssertEqual(f.backend.adds, 1)
        // Newly reconstructed native genesis has the same exact bytes/owner, never inferred IDs.
        let request = DeviceNativeProvisioningRequest(roots: f.original.request.roots, delivery: f.original.request.delivery,
            grantOperationID: f.original.request.grantOperationID, baseline: restarted.resources.baseline,
            candidate: f.original.request.candidate, packages: f.original.request.packages,
            grantInput: f.original.request.grantInput, qualifiedGrant: f.original.request.qualifiedGrant)
        try restarted.coordinator.verifyPackageBatchExact(batch, request: request)
        XCTAssertThrowsError(try restarted.coordinator.preparePackagesRecoveredExact(original))
    }
    func testHistoricalSelectedAndUnrelatedActualLatestAreBothRetainedWithoutTipPromotion() throws {
        let f = try privateFixture(count: 2, preinstalled: 2, unrelatedLatest: true)
        let retained = try retainedRequest(f)
        let references = retained.packages.compactMap { input -> DevicePreparedPackageReference? in
            if case .retained(_, let reference, _) = input { return reference }; return nil
        }
        let resolution = try f.packages.resolveRetainedTerminalExact(references)
        let anchor = try f.coordinator.prepareExact(retained, plan: f.original.plan, joined: f.joined, packageResolution: resolution)
        let before = try operationEvidence(f.packageRoot)
        let batch = try f.coordinator.preparePackagesExact(retained, anchor: anchor)
        try f.coordinator.verifyPackageBatchExact(batch, request: retained)
        XCTAssertEqual(try operationEvidence(f.packageRoot), before); XCTAssertEqual(before.count, 3)
    }
    func testEqualPublicChangedSecretRejectsBeforePackageEventsAndPreservesOriginalAnchor() throws {
        let f = try privateFixture(count: 2), anchor = try prepare(f), changed = try changedSecretRequest(f)
        let before = try operationEvidence(f.packageRoot), events = f.packageProbe.events
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(changed.0, anchor: anchor))
        XCTAssertEqual(try operationEvidence(f.packageRoot), before); XCTAssertEqual(f.packageProbe.events, events)
        try f.coordinator.verifyExact(anchor, request: f.original.request, packageResolution: f.resolution)
        _ = try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor)
    }
    func testSameInstancePackageEpochChangeRejectsOriginalAnchorBeforeEffects() throws {
        let f = try privateFixture(), anchor = try prepare(f)
        _ = try f.packages.resolveRetainedTerminalExact([])
        let events = f.packageProbe.events
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        XCTAssertEqual(f.packageProbe.events, events); XCTAssertEqual(try operationEvidence(f.packageRoot), [:])
    }
    func testOtherInstancePrivateRecommitRejectsOriginalAnchorBeforePackageEffects() throws {
        let f = try privateFixture(), anchor = try prepare(f)
        let other = DeviceNativeGrantPreparationStore(root: f.grantRoot, rootID: f.original.roots.grantID,
            protectedPaths: [f.packageRoot, f.original.journalRoot, f.original.structuralRoot], backend: f.backend)
        let coordinator = DeviceNativeGrantPrivateCoordinator(journal: f.original.journal, structural: f.original.structural,
            packages: f.packages, grants: other)
        _ = try coordinator.prepareExact(f.original.request, plan: f.original.plan, joined: f.joined, packageResolution: f.resolution)
        let events = f.packageProbe.events
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        XCTAssertEqual(f.packageProbe.events, events); XCTAssertEqual(f.backend.adds, 1)
    }
    func testBindingSyncFaultSuppressesBatchAndExplicitCapturedRecoverySucceeds() throws {
        let f = try privateFixture(count: 2), anchor = try prepare(f)
        f.packageProbe.failure = .afterFileSync(.binding)
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        XCTAssertEqual(try operationEvidence(f.packageRoot), [:])
        let original = try f.coordinator.capturePackagesRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let batch = try f.coordinator.preparePackagesRecoveredExact(original)
        try f.coordinator.verifyPackageBatchExact(batch, request: f.original.request)
        XCTAssertEqual(f.backend.adds, 1)
    }
    func testThrownWholeScopeExitSuppressesBatchAfterPackagesLand() throws {
        let f = try privateFixture(), anchor = try prepare(f)
        f.packageProbe.action = { site in
            if site == .afterDirectorySync(.terminal) { f.probe.failure = .beforeScopeExit }
        }
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        f.packageProbe.action = nil
        XCTAssertEqual(try operationEvidence(f.packageRoot).count, 1)
        let original = try f.coordinator.capturePackagesRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let batch = try f.coordinator.preparePackagesRecoveredExact(original)
        try f.coordinator.verifyPackageBatchExact(batch, request: f.original.request)
    }
    func testRecoveryCapturedBeforePackageMutationCannotRefreshAtDispatch() throws {
        let f = try privateFixture(), anchor = try prepare(f)
        let original = try f.coordinator.capturePackagesRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        _ = try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor)
        let packageEvidence = try operationEvidence(f.packageRoot), grantEvidence = try operationEvidence(f.grantRoot)
        let events = f.packageProbe.events
        XCTAssertThrowsError(try f.coordinator.preparePackagesRecoveredExact(original))
        XCTAssertEqual(try operationEvidence(f.packageRoot), packageEvidence)
        XCTAssertEqual(try operationEvidence(f.grantRoot), grantEvidence); XCTAssertEqual(f.packageProbe.events, events)
    }
    func testMissingReplacedOriginalPrivateItemRejectsBeforePackageEffects() throws {
        for replaced in [false, true] {
            let f = try privateFixture(), anchor = try prepare(f)
            let key = try XCTUnwrap(f.backend.values.keys.first), old = try XCTUnwrap(f.backend.values[key])
            if replaced {
                f.backend.values[key] = .init(item: .init(account: old.item.account, persistentReference: Data("different-ref".utf8), byteCount: old.item.byteCount), bytes: old.bytes)
            } else { f.backend.values.removeValue(forKey: key) }
            let events = f.packageProbe.events
            XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
            XCTAssertEqual(f.packageProbe.events, events); XCTAssertEqual(try operationEvidence(f.packageRoot), [:])
        }
    }
    func testUnmappedPendingPackageBlocksWholeBatchBeforeEvents() throws {
        let f = try privateFixture(), anchor = try prepare(f), unrelated = try package(generic: false)
        f.packageProbe.failure = .afterReplace(.intent)
        XCTAssertThrowsError(try f.packages.prepareExact(.init(operationID: UUID(), package: unrelated)))
        let before = try operationEvidence(f.packageRoot), events = f.packageProbe.events
        XCTAssertThrowsError(try f.coordinator.capturePackagesRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f)))
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        XCTAssertEqual(try operationEvidence(f.packageRoot), before); XCTAssertEqual(f.packageProbe.events, events)
    }
    func testUnknownPackageLeafIsPreservedAndBlocksWithoutEvents() throws {
        let f = try privateFixture(), anchor = try prepare(f)
        let unexpected = f.packageRoot.appendingPathComponent("unknown")
        try Data("sentinel".utf8).write(to: unexpected)
        let events = f.packageProbe.events
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        XCTAssertEqual(try Data(contentsOf: unexpected), Data("sentinel".utf8)); XCTAssertEqual(f.packageProbe.events, events)
    }
    func testPackageFaultNestedEntryFailsPromptlyWithoutGrantBackendEffects() throws {
        let f = try privateFixture(), anchor = try prepare(f)
        f.packageProbe.action = { _ in try f.packages.initializeExplicit() }
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        f.packageProbe.action = nil
        XCTAssertEqual(f.backend.adds, 1)
        let recovery = try f.coordinator.capturePackagesRecoveryExact(operationID: f.original.request.grantOperationID, resources: resources(f))
        let batch = try f.coordinator.preparePackagesRecoveredExact(recovery)
        try f.coordinator.verifyPackageBatchExact(batch, request: f.original.request)
    }
    func testOversizedAndDuplicateMappingsRejectBeforeEffectsWithoutInvalidatingAnchor() throws {
        let f = try privateFixture(), anchor = try prepare(f), request = f.original.request
        for inputs in [Array(repeating: request.packages[0], count: 13), [request.packages[0], request.packages[0]]] {
            let invalid = DeviceNativeProvisioningRequest(roots: request.roots, delivery: request.delivery,
                grantOperationID: request.grantOperationID, baseline: request.baseline, candidate: request.candidate,
                packages: inputs, grantInput: request.grantInput, qualifiedGrant: request.qualifiedGrant)
            let events = f.packageProbe.events
            XCTAssertThrowsError(try f.coordinator.preparePackagesExact(invalid, anchor: anchor))
            XCTAssertEqual(f.packageProbe.events, events); XCTAssertEqual(try operationEvidence(f.packageRoot), [:])
            try f.coordinator.verifyExact(anchor, request: request, packageResolution: f.resolution)
        }
    }
    func testOriginalJournalAndGenesisSameByteReplacementRejectBeforePackageEffects() throws {
        for journal in [false, true] {
            let f = try privateFixture(), anchor = try prepare(f)
            let node = (journal ? f.original.journalRoot : f.original.structuralRoot)
                .appendingPathComponent(journal ? "native-join.confirm" : "native-genesis.confirm")
            let backup = try root().appendingPathComponent("owned-original")
            let bytes = try Data(contentsOf: node)
            try FileManager.default.moveItem(at: node, to: backup); try bytes.write(to: node)
            let events = f.packageProbe.events
            XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
            XCTAssertEqual(f.packageProbe.events, events); XCTAssertEqual(try operationEvidence(f.packageRoot), [:])
        }
    }
    func testPostDispatchJournalReplacementSuppressesBatchAcknowledgment() throws {
        let f = try privateFixture(), anchor = try prepare(f)
        let node = f.original.journalRoot.appendingPathComponent("native-join.confirm")
        let backup = try root().appendingPathComponent("owned-original")
        var replaced = false
        f.packageProbe.action = { site in
            if !replaced, site == .afterDirectorySync(.terminal) {
                replaced = true
                let bytes = try Data(contentsOf: node)
                try FileManager.default.moveItem(at: node, to: backup); try bytes.write(to: node)
            }
        }
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        XCTAssertTrue(replaced); XCTAssertEqual(try operationEvidence(f.packageRoot).count, 1)
        XCTAssertEqual(f.backend.adds, 1)
    }
    func testUnknownRestartPackageCreationIsPreservedWithoutAdoption() throws {
        let f = try privateFixture(), anchor = try prepare(f)
        f.packageProbe.failure = .afterCreate(.directory)
        XCTAssertThrowsError(try f.coordinator.preparePackagesExact(f.original.request, anchor: anchor))
        let names = try FileManager.default.contentsOfDirectory(atPath: f.packageRoot.path)
        let records = try operationEvidence(f.packageRoot)
        let restarted = try reconstructed(f)
        XCTAssertThrowsError(try restarted.coordinator.capturePackagesRecoveryExact(
            operationID: f.original.request.grantOperationID, resources: restarted.resources))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.packageRoot.path), names)
        XCTAssertEqual(try operationEvidence(f.packageRoot), records); XCTAssertEqual(f.backend.adds, 1)
    }
    func testLateOldRecoveredJournalPublicationCannotInvalidateNewerGenuineJoin() throws {
        let f = try privateFixture(); _ = try prepare(f)
        let coordinator = f.coordinator
        let recovery = try coordinator.capturePackagesRecoveryExact(operationID: f.original.request.grantOperationID,
            resources: resources(f))
        let old = try coordinator.deferRecoveredJournalPublicationForTesting(recovery)
        let newer = try f.original.coordinator.joinExact(f.original.request, plan: f.original.plan, attachment: f.original.attachment)
        try f.original.coordinator.verifyExact(newer, plan: f.original.plan, baseline: f.original.request.baseline)
        XCTAssertThrowsError(try coordinator.publishDeferredJournalForTesting(old))
        try f.original.coordinator.verifyExact(newer, plan: f.original.plan, baseline: f.original.request.baseline)
        XCTAssertEqual(f.backend.adds, 1); XCTAssertEqual(try operationEvidence(f.packageRoot), [:])
    }
    func testDiscardedCurrentRecoveredPublicationCannotManufactureQualification() throws {
        let f = try privateFixture(); _ = try prepare(f)
        let coordinator = f.coordinator
        let recovery = try coordinator.capturePackagesRecoveryExact(operationID: f.original.request.grantOperationID,
            resources: resources(f))
        let pending = try coordinator.deferRecoveredJournalPublicationForTesting(recovery)
        try coordinator.discardDeferredJournalForTesting(pending)
        XCTAssertThrowsError(try coordinator.publishDeferredJournalForTesting(pending))
        XCTAssertThrowsError(try f.original.coordinator.verifyExact(f.joined, plan: f.original.plan, baseline: f.original.request.baseline))
        let exact = try f.original.coordinator.joinExact(f.original.request, plan: f.original.plan, attachment: f.original.attachment)
        try f.original.coordinator.verifyExact(exact, plan: f.original.plan, baseline: f.original.request.baseline)
        XCTAssertEqual(f.backend.adds, 1); XCTAssertEqual(try operationEvidence(f.packageRoot), [:])
    }
    func testOrdinaryPackageAndLocalGrantDomainsDoNotAcquireNativeAuthority() throws {
        let f = try privateFixture(generic: false), value = try package(generic: false), operation = UUID()
        let receipt = try f.packages.prepareExact(.init(operationID: operation, package: value))
        let replay = try f.packages.recommitExact(.init(operationID: operation, package: value))
        XCTAssertEqual(receipt.reference, replay.reference)
        _ = try f.packages.verify(replay)
        let protected = DevicePackageProtectedScope(legacyStateRoot: f.original.journalRoot,
            legacyArchiveRoot: f.original.structuralRoot, resetRoot: f.packageRoot, cloudRoot: f.original.journalRoot,
            managementRoot: f.original.structuralRoot, preferencesRoot: f.packageRoot, otherProtectedRoots: [])
        let legacy = DeviceGrantPreparationStore(root: f.grantRoot, rootID: f.original.roots.grantID,
            protectedScope: protected, backend: f.backend)
        let before = try operationEvidence(f.grantRoot)
        XCTAssertThrowsError(try legacy.initializeExplicit())
        XCTAssertEqual(try operationEvidence(f.grantRoot), before); XCTAssertEqual(f.backend.adds, 0)
    }
    #endif
}
