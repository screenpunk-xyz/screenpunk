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

final class DeviceNativeGrantPrivateAttemptTests:XCTestCase {
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
    private struct PrivateFixture {
        let original: Fixture
        let packageRoot: URL, grantRoot: URL
        let packages: DevicePackagePreparationStore
        let grants: DeviceNativeGrantPreparationStore
        let backend: Backend, probe: GrantProbe
        let resolution: DevicePackageTerminalResolution
        let joined: DeviceLocalProvisioningIntentStore.NativeJoinReceipt
        var coordinator: DeviceNativeGrantPrivateCoordinator {
            .init(journal: original.journal, structural: original.structural, packages: packages, grants: grants)
        }
    }
    private func privateFixture(generic: Bool = true, count: Int = 1, mixed: Bool = false) throws -> PrivateFixture {
        let original = try fixture(count: count, generic: generic, mixed: mixed)
        let p = try root(), g = try root(), backend = Backend(), probe = GrantProbe()
        let scope = DevicePackageProtectedScope(legacyStateRoot: original.journalRoot,
            legacyArchiveRoot: original.structuralRoot, resetRoot: g, cloudRoot: original.journalRoot,
            managementRoot: original.structuralRoot, preferencesRoot: g, otherProtectedRoots: [])
        let packages = DevicePackagePreparationStore(root: p, rootID: original.roots.packageID, protectedScope: scope)
        try packages.initializeExplicit()
        let grants = DeviceNativeGrantPreparationStore(root: g, rootID: original.roots.grantID,
            protectedPaths: [p, original.journalRoot, original.structuralRoot], backend: backend, fault: { try probe.hit($0) })
        try grants.initializeExplicit()
        let resolution = try packages.resolveRetainedTerminalExact([])
        let joined = try original.coordinator.joinExact(original.request, plan: original.plan, attachment: original.attachment)
        return .init(original: original, packageRoot: p, grantRoot: g, packages: packages, grants: grants,
            backend: backend, probe: probe, resolution: resolution, joined: joined)
    }
    private func prepare(_ f: PrivateFixture) throws -> DeviceNativeGrantPrivateAnchor {
        try f.coordinator.prepareExact(f.original.request, plan: f.original.plan, joined: f.joined, packageResolution: f.resolution)
    }
    func testPrivateOnlyAddsOneExactAttemptAndLeavesOtherDomainsUnchanged() throws {
        let f = try privateFixture(count: 2)
        let journal = try snapshot(f.original.journalRoot), structural = try snapshot(f.original.structuralRoot)
        let anchor = try prepare(f)
        XCTAssertEqual(anchor.operationID, f.original.request.grantOperationID)
        XCTAssertEqual(f.backend.adds, 1)
        XCTAssertEqual(f.backend.values.count, 1)
        XCTAssertTrue(f.backend.values.keys.allSatisfy { $0.hasPrefix("attempt.") })
        XCTAssertEqual(try snapshot(f.original.journalRoot), journal)
        XCTAssertEqual(try snapshot(f.original.structuralRoot), structural)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.packageRoot.appendingPathComponent("operations").path), [])
    }
    func testPublicFilesExcludeSecretFieldsAndPrivateBytes() throws {
        let f = try privateFixture()
        _ = try prepare(f)
        let secret = f.original.request.grantInput.credentials[0].bytes
        let operationRoot = f.grantRoot.appendingPathComponent("operations")
        for url in try FileManager.default.contentsOfDirectory(at: operationRoot, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(bytes.range(of: secret))
            XCTAssertNil(bytes.range(of: Data(secret.base64EncodedString().utf8)))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\"secret\""))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\"token\""))
        }
    }
    func testStaticNoCredentialInputStillRecordsPrivateAttemptOnly() throws {
        let f = try privateFixture(generic: false)
        _ = try prepare(f)
        XCTAssertEqual(f.backend.adds, 1)
        XCTAssertEqual(f.backend.values.count, 1)
    }
    func testLiveAddUncertaintyRetriesCapturedExactIdentityWithoutSecondAdd() throws {
        let f = try privateFixture()
        f.probe.failure = .afterCreate(.privateItem)
        XCTAssertThrowsError(try prepare(f))
        XCTAssertEqual(f.backend.adds, 1)
        _ = try prepare(f)
        XCTAssertEqual(f.backend.adds, 1)
    }
    func testRestartUnknownPrivateOrphanIsPreservedAndBlocked() throws {
        let f = try privateFixture()
        f.probe.failure = .afterCreate(.privateItem)
        XCTAssertThrowsError(try prepare(f))
        let originalItem = f.backend.values
        let reconstructed = DeviceNativeGrantPreparationStore(root: f.grantRoot, rootID: f.original.roots.grantID,
            protectedPaths: [f.packageRoot, f.original.journalRoot, f.original.structuralRoot], backend: f.backend)
        let coordinator = DeviceNativeGrantPrivateCoordinator(journal: f.original.journal, structural: f.original.structural,
            packages: f.packages, grants: reconstructed)
        XCTAssertThrowsError(try coordinator.prepareExact(f.original.request, plan: f.original.plan,
            joined: f.joined, packageResolution: f.resolution))
        XCTAssertEqual(f.backend.adds, 1)
        XCTAssertEqual(Set(f.backend.values.keys), Set(originalItem.keys))
    }
    func testEmptyNativeGrantQualificationDoesNotBypassNonemptyDeliveryBoundary() throws {
        let input = DeviceNativeGrantRevisionInput(schemaVersion: 2,
            identity: .init(rootID: UUID(), revisionID: UUID()), owner: owner,
            entries: [], credentials: [], retainedRevisions: [])
        let qualified = try DeviceNativeGrantRevisionQualifier.qualify(input, expectedEntries: [])
        let repeated = try DeviceNativeGrantRevisionQualifier.qualify(input, expectedEntries: [])
        XCTAssertTrue(qualified.exactlyMatches(repeated))
        // The genuine fixture must bind an accepted delivery command before it can
        // publish an attachment/join or construct a private backend/store. Empty
        // delivery sets are rejected there; no executable empty pipeline is claimed.
        XCTAssertThrowsError(try privateFixture(generic: false, count: 0)) { error in
            XCTAssertEqual(error as? DeviceNativeDeliveryAttachmentCodec.Failure, .invalidSchema)
        }
    }
    func testEveryPrivateStageBoundaryAllowsOnlyExactLiveRetry() throws {
        let failures: [DeviceNativeGrantPreparationStore.Boundary] = [
            .afterCreate(.intent), .afterWrite(.intent), .afterFileSync(.intent), .beforeReplace(.intent), .afterReplace(.intent),
            .afterDirectorySync(.intent), .afterCreate(.record), .afterCreate(.confirmation), .afterCreate(.binding),
            .afterWrite(.binding), .afterReplace(.binding), .afterCreate(.privateItem), .afterWrite(.record),
            .afterReplace(.record), .afterWrite(.confirmation), .afterReplace(.confirmation), .beforeScopeExit]
        for failure in failures {
            let f = try privateFixture(); f.probe.failure = failure
            XCTAssertThrowsError(try prepare(f), "\(failure)")
            _ = try prepare(f)
            XCTAssertEqual(f.backend.adds, 1, "\(failure)")
        }
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
    func testRecordedReferenceRestartRecoveryDoesNotExposePrivateInputOrAddAgain() throws {
        let f = try privateFixture()
        f.probe.failure = .afterFileSync(.record)
        XCTAssertThrowsError(try prepare(f))
        let structural = DeviceStructuralStore(root: f.original.structuralRoot, rootID: f.original.roots.structuralID)
        let baseline = try structural.initializeNativeGenesisExplicit(f.original.request.baseline.state)
        let journal = DeviceLocalProvisioningIntentStore(root: f.original.journalRoot, rootID: f.original.roots.journalID,
            protectedRoots: [f.original.structuralRoot])
        let grant = DeviceNativeGrantPreparationStore(root: f.grantRoot, rootID: f.original.roots.grantID,
            protectedPaths: [f.packageRoot, f.original.journalRoot, f.original.structuralRoot], backend: f.backend)
        let supplied = resources(f, baseline: baseline)
        let recovery = try grant.inspectRecoveryExact(operationID: f.original.request.grantOperationID,
            resources: supplied, expectedEntries: expectations(f))
        // Original grant checkpoint precedes package/journal durability repairs.
        let resolution = try f.packages.resolveRetainedTerminalExact([])
        let coordinator = DeviceNativeGrantPrivateCoordinator(journal: journal, structural: structural, packages: f.packages, grants: grant)
        let joined = try coordinator.recommitJournalForRecoveryExact(recovery, resources: supplied, packageResolution: resolution)
        let anchor = try coordinator.prepareRecoveredExact(recovery, resources: supplied, joined: joined, packageResolution: resolution)
        XCTAssertEqual(anchor.operationID, f.original.request.grantOperationID)
        XCTAssertEqual(f.backend.adds, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.original.structuralRoot.appendingPathComponent("operations").path), [])
        XCTAssertThrowsError(try coordinator.prepareRecoveredExact(recovery, resources: supplied, joined: joined, packageResolution: resolution))
    }
    func testSameTipExactRetryInvalidatesOriginalAnchorEpoch() throws {
        let f = try privateFixture(), first = try prepare(f)
        try f.coordinator.verifyExact(first, request: f.original.request, packageResolution: f.resolution)
        let second = try prepare(f)
        XCTAssertThrowsError(try f.coordinator.verifyExact(first, request: f.original.request, packageResolution: f.resolution))
        try f.coordinator.verifyExact(second, request: f.original.request, packageResolution: f.resolution)
        XCTAssertEqual(f.backend.adds, 1)
    }
    func testStalePublicationCleanupDoesNotInvalidateNewerGenuineAnchor() throws {
        let f = try privateFixture(), first = try prepare(f)
        let original = try f.grants.capturePublishedCleanupTokenForTesting()
        let newer = try prepare(f)
        try f.coordinator.verifyExact(newer, request: f.original.request, packageResolution: f.resolution)
        try f.grants.discardPrivatePublication(original)
        try f.coordinator.verifyExact(newer, request: f.original.request, packageResolution: f.resolution)
        XCTAssertEqual(f.backend.adds, 1)
        XCTAssertThrowsError(try f.coordinator.verifyExact(first, request: f.original.request, packageResolution: f.resolution))
    }
    func testOtherInstanceExactRetryInvalidatesOriginalAnchor() throws {
        let f = try privateFixture(), first = try prepare(f)
        let other = DeviceNativeGrantPreparationStore(root: f.grantRoot, rootID: f.original.roots.grantID,
            protectedPaths: [f.packageRoot, f.original.journalRoot, f.original.structuralRoot], backend: f.backend)
        let coordinator = DeviceNativeGrantPrivateCoordinator(journal: f.original.journal,
            structural: f.original.structural, packages: f.packages, grants: other)
        _ = try coordinator.prepareExact(f.original.request, plan: f.original.plan, joined: f.joined, packageResolution: f.resolution)
        XCTAssertThrowsError(try f.coordinator.verifyExact(first, request: f.original.request, packageResolution: f.resolution))
        XCTAssertEqual(f.backend.adds, 1)
    }
    func testRecordedMissingReplacedReferenceAndChangedBytesRejectBeforeEvents() throws {
        for mode in 0..<3 {
            let f = try privateFixture(); _ = try prepare(f)
            let account = GrantPreparationCodec.attemptAccount(f.original.request.grantOperationID)
            let original = f.backend.values[account]!, events = f.probe.events
            if mode == 0 { f.backend.values.removeValue(forKey: account) }
            else if mode == 1 {
                let item = DeviceGrantCredentialItem(account: account, persistentReference: Data("replacement".utf8), byteCount: original.bytes.count)
                f.backend.values[account] = .init(item: item, bytes: original.bytes)
            } else {
                var changed = original.bytes; changed[changed.startIndex] ^= 1
                f.backend.values[account] = .init(item: original.item, bytes: changed)
            }
            XCTAssertThrowsError(try prepare(f))
            XCTAssertEqual(f.probe.events, events)
            XCTAssertEqual(f.backend.adds, 1)
            f.backend.values[account] = original
            _ = try prepare(f)
        }
    }
    func testBindingSynchronizationFailureSuppressesAnchorAndAllowsExactRetry() throws {
        let f = try privateFixture()
        f.probe.failure = .afterFileSync(.rootBinding)
        XCTAssertThrowsError(try prepare(f))
        XCTAssertEqual(f.backend.adds, 1)
        _ = try prepare(f)
        XCTAssertEqual(f.backend.adds, 1)
    }
    func testSameByteRootBindingReplacementRejectedBeforeEffects() throws {
        let f = try privateFixture(); _ = try prepare(f)
        let path = f.grantRoot.appendingPathComponent("root-binding.json"), bytes = try Data(contentsOf: path)
        try bytes.write(to: path, options: .atomic)
        let events = f.probe.events
        XCTAssertThrowsError(try prepare(f))
        XCTAssertEqual(f.probe.events, events)
        XCTAssertEqual(f.backend.adds, 1)
    }
    func testBackendNestedEntryRejectsBeforeMutexAndCanExactRetry() throws {
        let f = try privateFixture()
        f.backend.action = { try f.grants.initializeExplicit() }
        XCTAssertThrowsError(try prepare(f)) { XCTAssertEqual($0 as? DeviceLocalResourceGateFailure, .reentrant) }
        XCTAssertEqual(f.backend.adds, 0)
        f.backend.action = nil
        _ = try prepare(f)
        XCTAssertEqual(f.backend.adds, 1)
    }
    func testUnknownOperationLeafPreservedWithoutEffects() throws {
        let f = try privateFixture(), path = f.grantRoot.appendingPathComponent("operations/unknown")
        let bytes = Data("retained sentinel".utf8); try bytes.write(to: path)
        let events = f.probe.events
        XCTAssertThrowsError(try prepare(f))
        XCTAssertEqual(f.backend.adds, 0); XCTAssertEqual(f.probe.events, events)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testCompleteInventoryReservationRejectsOversizedPrivateHistoryBeforeEffects() throws {
        let f = try privateFixture()
        f.backend.inventoryOverride = (0..<33).map { _ in
            .init(account: GrantPreparationCodec.attemptAccount(UUID()), persistentReference: Data(UUID().uuidString.utf8),
                byteCount: 4 * 1024 * 1024)
        }
        let events = f.probe.events
        XCTAssertThrowsError(try prepare(f))
        XCTAssertEqual(f.backend.adds, 0); XCTAssertEqual(f.probe.events, events)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.grantRoot.appendingPathComponent("operations").path), [])
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
    func testChangedEqualPublicSecretsRejectWithoutEpochOrEvidenceChange() throws {
        for fault in [DeviceNativeGrantPreparationStore.Boundary.afterCreate(.intent), .afterWrite(.intent)] {
            let f = try privateFixture(), changed = try changedSecretRequest(f)
            f.probe.failure = fault; XCTAssertThrowsError(try prepare(f))
            let evidence = try operationEvidence(f.grantRoot), events = f.probe.events
            XCTAssertThrowsError(try f.coordinator.prepareExact(changed.0, plan: changed.1, joined: f.joined, packageResolution: f.resolution))
            XCTAssertEqual(try operationEvidence(f.grantRoot), evidence); XCTAssertEqual(f.probe.events, events)
            XCTAssertEqual(f.backend.adds, 0)
            _ = try prepare(f); XCTAssertEqual(f.backend.adds, 1)
        }
        let f = try privateFixture(), anchor = try prepare(f), changed = try changedSecretRequest(f)
        let evidence = try operationEvidence(f.grantRoot), events = f.probe.events
        XCTAssertThrowsError(try f.coordinator.prepareExact(changed.0, plan: changed.1, joined: f.joined, packageResolution: f.resolution))
        XCTAssertEqual(try operationEvidence(f.grantRoot), evidence); XCTAssertEqual(f.probe.events, events)
        try f.coordinator.verifyExact(anchor, request: f.original.request, packageResolution: f.resolution)
        let other = DeviceNativeGrantPreparationStore(root: f.grantRoot, rootID: f.original.roots.grantID,
            protectedPaths: [f.packageRoot, f.original.journalRoot, f.original.structuralRoot], backend: f.backend)
        let coordinator = DeviceNativeGrantPrivateCoordinator(journal: f.original.journal,
            structural: f.original.structural, packages: f.packages, grants: other)
        XCTAssertThrowsError(try coordinator.prepareExact(changed.0, plan: changed.1, joined: f.joined, packageResolution: f.resolution))
        XCTAssertEqual(try operationEvidence(f.grantRoot), evidence)
        try f.coordinator.verifyExact(anchor, request: f.original.request, packageResolution: f.resolution)
    }
    func testOriginalPackageCheckpointAndJournalReceiptRejectStaleBeforePrivateEffects() throws {
        let f = try privateFixture(), events = f.probe.events
        _ = try f.packages.resolveRetainedTerminalExact([])
        XCTAssertThrowsError(try prepare(f))
        XCTAssertEqual(f.backend.adds, 0); XCTAssertEqual(f.probe.events, events)
        let other = try privateFixture(), originalEvents = other.probe.events
        _ = try other.original.coordinator.joinExact(other.original.request, plan: other.original.plan, attachment: other.original.attachment)
        XCTAssertThrowsError(try prepare(other))
        XCTAssertEqual(other.backend.adds, 0); XCTAssertEqual(other.probe.events, originalEvents)
    }
    func testRecoveryCheckpointCannotRefreshAfterSameInstancePrivateRecommit() throws {
        let f = try privateFixture(); _ = try prepare(f)
        let original = try f.grants.inspectRecoveryExact(operationID: f.original.request.grantOperationID,
            resources: resources(f), expectedEntries: expectations(f))
        _ = try prepare(f)
        let events = f.probe.events, journal = try snapshot(f.original.journalRoot)
        XCTAssertThrowsError(try f.coordinator.recommitJournalForRecoveryExact(original,
            resources: resources(f), packageResolution: f.resolution))
        XCTAssertEqual(f.probe.events, events); XCTAssertEqual(try snapshot(f.original.journalRoot), journal)
        XCTAssertEqual(f.backend.adds, 1)
    }
    func testInitializationFaultsRequireExactOwnedRepairAndPreserveUnknownRestartStages() throws {
        let failures: [DeviceNativeGrantPreparationStore.Boundary] = [.afterCreate(.rootBinding), .afterCreate(.genesis),
            .afterWrite(.rootBinding), .afterFileSync(.rootBinding), .afterReplace(.rootBinding), .afterDirectorySync(.rootBinding),
            .afterWrite(.genesis), .afterReplace(.genesis), .afterDirectorySync(.genesis)]
        for failure in failures {
            let r = try root(), protected = try root(), backend = Backend(), probe = GrantProbe(), id = UUID()
            let store = DeviceNativeGrantPreparationStore(root: r, rootID: id, protectedPaths: [protected], backend: backend,
                fault: { try probe.hit($0) })
            probe.failure = failure
            XCTAssertThrowsError(try store.initializeExplicit())
            if failure == .afterCreate(.rootBinding) || failure == .afterCreate(.genesis) {
                let before = try snapshot(r)
                let reconstructed = DeviceNativeGrantPreparationStore(root: r, rootID: id, protectedPaths: [protected], backend: backend)
                XCTAssertThrowsError(try reconstructed.initializeExplicit())
                XCTAssertEqual(try snapshot(r), before)
            }
            try store.initializeExplicit()
            XCTAssertEqual(backend.adds, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.appendingPathComponent("operations").path), [])
        }
    }
    func testInvalidRootScopeAndUnknownNamespaceRejectBeforeSetupEffects() throws {
        let r = try root(), backend = Backend(), id = UUID()
        let nonFile = URL(string: "https://fixture.invalid" + r.path)!
        for store in [DeviceNativeGrantPreparationStore(root: nonFile, rootID: id, protectedPaths: [], backend: backend),
                      DeviceNativeGrantPreparationStore(root: r, rootID: id, protectedPaths: [nonFile], backend: backend),
                      DeviceNativeGrantPreparationStore(root: r, rootID: id, protectedPaths: Array(repeating: r, count: 33), backend: backend),
                      DeviceNativeGrantPreparationStore(root: r, rootID: id, protectedPaths: [r], backend: backend)] {
            XCTAssertThrowsError(try store.initializeExplicit())
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.path), [])
        }
        backend.inventoryOverride = [.init(account: GrantPreparationCodec.attemptAccount(UUID()),
            persistentReference: Data("unknown retained reference".utf8), byteCount: 8)]
        let valid = DeviceNativeGrantPreparationStore(root: r, rootID: id, protectedPaths: [], backend: backend)
        XCTAssertThrowsError(try valid.initializeExplicit())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.path), [])
        XCTAssertEqual(backend.adds, 0)
    }
    func testMalformedPrivateFramesBlockRecoveryWithoutSecretGetterOrEffects() throws {
        for fragment in ["\"unexpected\":0,", "\"schemaVersion\":3,", "\"schemaVersion\":1,"] {
            let f = try privateFixture(); _ = try prepare(f)
            let account = GrantPreparationCodec.attemptAccount(f.original.request.grantOperationID), old = f.backend.values[account]!
            var bytes = old.bytes; bytes.insert(contentsOf: fragment.utf8, at: bytes.startIndex + 1)
            f.backend.values[account] = .init(item: old.item, bytes: bytes)
            let evidence = try operationEvidence(f.grantRoot), events = f.probe.events
            XCTAssertThrowsError(try f.grants.inspectRecoveryExact(operationID: f.original.request.grantOperationID,
                resources: resources(f), expectedEntries: expectations(f)))
            XCTAssertEqual(try operationEvidence(f.grantRoot), evidence); XCTAssertEqual(f.probe.events, events)
            XCTAssertEqual(f.backend.adds, 1)
        }
    }
    func testDuplicateInventoryReferencesBlockBeforeMutation() throws {
        let f = try privateFixture(), ref = Data("same-ref".utf8), events = f.probe.events
        f.backend.inventoryOverride = [.init(account: GrantPreparationCodec.attemptAccount(UUID()), persistentReference: ref, byteCount: 4),
            .init(account: GrantPreparationCodec.attemptAccount(UUID()), persistentReference: ref, byteCount: 4)]
        XCTAssertThrowsError(try prepare(f)); XCTAssertEqual(f.backend.adds, 0); XCTAssertEqual(f.probe.events, events)
    }
    func testMixedGenericHAPublicPrivateFramePreservesSharedCompleteInventory() throws {
        let f = try privateFixture(count: 2, mixed: true)
        _ = try prepare(f)
        XCTAssertEqual(f.backend.adds, 1)
        XCTAssertEqual(f.original.request.grantInput.credentials.count, 2)
        XCTAssertTrue(f.original.request.grantInput.entries.allSatisfy { $0.generic != nil && $0.homeAssistant != nil && $0.publicReads != nil })
        let item = f.backend.values.values.first!
        let body = try DeviceNativeProvisioningIntentCodec.decode(f.original.plan.intentBytes)
        XCTAssertEqual(item.bytes.count, body.privateAttemptByteCount)
        XCTAssertTrue(f.backend.values.keys.allSatisfy { $0.hasPrefix("attempt.") })
    }
    func testPreBindingPublicOrphanCannotBeAdoptedByReconstructedStore() throws {
        for failure in [DeviceNativeGrantPreparationStore.Boundary.afterWrite(.intent), .afterReplace(.intent)] {
            let f = try privateFixture(); f.probe.failure = failure
            XCTAssertThrowsError(try prepare(f))
            let original = try operationEvidence(f.grantRoot)
            let other = DeviceNativeGrantPreparationStore(root: f.grantRoot, rootID: f.original.roots.grantID,
                protectedPaths: [f.packageRoot, f.original.journalRoot, f.original.structuralRoot], backend: f.backend)
            let coordinator = DeviceNativeGrantPrivateCoordinator(journal: f.original.journal,
                structural: f.original.structural, packages: f.packages, grants: other)
            XCTAssertThrowsError(try coordinator.prepareExact(f.original.request, plan: f.original.plan,
                joined: f.joined, packageResolution: f.resolution))
            XCTAssertEqual(try operationEvidence(f.grantRoot), original)
            XCTAssertEqual(f.backend.adds, 0)
            _ = try prepare(f); XCTAssertEqual(f.backend.adds, 1)
        }
    }
    func testMissingCapturedPrefixIsNotRecreatedAndExactInodeRestorationWorks() throws {
        let f = try privateFixture(); f.probe.failure = .afterWrite(.intent)
        XCTAssertThrowsError(try prepare(f))
        let leaf = f.grantRoot.appendingPathComponent("operations/" + f.original.request.grantOperationID.uuidString.lowercased() + ".intent.json.stage")
        let backup = try root().appendingPathComponent("captured-public-node")
        try FileManager.default.moveItem(at: leaf, to: backup)
        let events = f.probe.events
        XCTAssertThrowsError(try prepare(f)); XCTAssertEqual(f.probe.events, events)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaf.path)); XCTAssertEqual(f.backend.adds, 0)
        try FileManager.default.moveItem(at: backup, to: leaf)
        _ = try prepare(f); XCTAssertEqual(f.backend.adds, 1)
    }
    func testHardlinkedRecordAndSpecialLockRejectWithoutBlockingOrEffects() throws {
        let f = try privateFixture(); _ = try prepare(f)
        let record = f.grantRoot.appendingPathComponent("operations/" + f.original.request.grantOperationID.uuidString.lowercased() + ".record.json")
        let link = try root().appendingPathComponent("owned-link")
        try FileManager.default.linkItem(at: record, to: link)
        let events = f.probe.events
        XCTAssertThrowsError(try prepare(f)); XCTAssertEqual(f.probe.events, events); XCTAssertEqual(f.backend.adds, 1)
        try FileManager.default.removeItem(at: link)
        _ = try prepare(f)
        let g = try privateFixture(), lock = g.grantRoot.appendingPathComponent("native-grant.lock")
        let backup = try root().appendingPathComponent("owned-lock")
        try FileManager.default.moveItem(at: lock, to: backup)
        guard mkfifo(lock.path, mode_t(0o600)) == 0 else { throw Fault.injected }
        let before = g.probe.events
        XCTAssertThrowsError(try prepare(g)); XCTAssertEqual(g.probe.events, before); XCTAssertEqual(g.backend.adds, 0)
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.moveItem(at: backup, to: lock)
        _ = try prepare(g)
    }
    #endif
}
