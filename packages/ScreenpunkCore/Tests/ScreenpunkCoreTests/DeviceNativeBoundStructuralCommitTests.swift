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

final class DeviceNativeBoundStructuralCommitTests:XCTestCase {
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
    func testGenuineStaticSharedAndDistinctNativeStructuralDispatchKeepsJournalPending() throws {
        for (generic,distinct) in [(false,false),(true,false),(true,true)] {
            let f=try privateFixture(generic:generic,count:2,distinct:distinct),receipt=try terminal(f)
            let journal=try snapshot(f.original.journalRoot),adds=f.backend.adds
            let ack=try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:receipt)
            XCTAssertEqual(ack.operationID,f.original.request.delivery.nativeOperationID)
            try f.coordinator.verifyNativeStructuralAcknowledgmentExact(ack,request:f.original.request)
            XCTAssertEqual(try snapshot(f.original.journalRoot),journal);XCTAssertEqual(f.backend.adds,adds)
            let bytes=try Data(contentsOf:f.original.structuralRoot.appendingPathComponent("native-current.json"))
            let envelope=try DeviceNativeStructuralCommandCodec.envelope(bytes)
            XCTAssertEqual(try DeviceNativeStructuralStateCodec.decode(envelope.snapshotBytes),f.original.request.candidate)
            XCTAssertThrowsError(try f.original.structural.prepare(.init(rootID:f.original.roots.structuralID,operationID:UUID(),expectedOld:nil,candidate:bytes,resourceAssertions:Data())))
        }
    }
    func testExactDuplicateRecommitsAndOldAcknowledgmentCannotRenewNewEpoch() throws {
        let f=try privateFixture(),t=try terminal(f),journal=try snapshot(f.original.journalRoot)
        let first=try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t)
        let nodes=try operationEvidence(f.original.structuralRoot)
        let second=try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t)
        XCTAssertThrowsError(try f.coordinator.verifyNativeStructuralAcknowledgmentExact(first,request:f.original.request))
        try f.coordinator.verifyNativeStructuralAcknowledgmentExact(second,request:f.original.request)
        XCTAssertEqual(try operationEvidence(f.original.structuralRoot),nodes);XCTAssertEqual(try snapshot(f.original.journalRoot),journal)
    }
    func testRestartRecordedCurrentAndTerminalUncertaintyUsesGenuineRecoveredTerminal() throws {
        for site in [DeviceStructuralStore.Boundary.afterReplace(.nativeCommandCurrent),.afterReplace(.nativeCommandTerminal)] {
            let f=try privateFixture(generic:true,count:2,distinct:true),t=try terminal(f),journal=try snapshot(f.original.journalRoot)
            f.original.probe.structural=site
            XCTAssertThrowsError(try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t))
            let restarted=try reconstructed(f)
            let recovery=try restarted.coordinator.captureNativeGrantTerminalRecoveryExact(operationID:f.original.request.grantOperationID,resources:restarted.resources)
            let grant=try restarted.coordinator.closeNativeGrantRecoveredExact(recovery)
            let ack=try restarted.coordinator.commitNativeStructuralExact(f.original.request,terminal:grant)
            try restarted.coordinator.verifyNativeStructuralAcknowledgmentExact(ack,request:f.original.request)
            XCTAssertEqual(ack.operationID,f.original.request.delivery.nativeOperationID);XCTAssertEqual(try snapshot(f.original.journalRoot),journal)
        }
    }
    func testChangedEqualPublicSecretAndPackageEpochRejectBeforeStructuralEffects() throws {
        let f=try privateFixture(),t=try terminal(f),before=try snapshot(f.original.structuralRoot),events=f.original.probe.events
        let changed=try changedSecretRequest(f).0
        XCTAssertThrowsError(try f.coordinator.commitNativeStructuralExact(changed,terminal:t))
        XCTAssertEqual(try snapshot(f.original.structuralRoot),before);XCTAssertEqual(f.original.probe.events,events)
        _ = try f.packages.resolveRetainedTerminalExact(f.original.request.candidate.entries.map(\.preparedPackage))
        XCTAssertThrowsError(try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t))
        XCTAssertEqual(try snapshot(f.original.structuralRoot),before);XCTAssertEqual(f.original.probe.events,events)
    }
    func testWholeScopeExitFaultSuppressesAckAndExactLiveRetryKeepsOriginalIDs() throws {
        let f=try privateFixture(),t=try terminal(f),journal=try snapshot(f.original.journalRoot)
        f.original.probe.structural = .beforeNativeCommandScopeExit
        XCTAssertThrowsError(try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t))
        let ack=try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t)
        try f.coordinator.verifyNativeStructuralAcknowledgmentExact(ack,request:f.original.request)
        XCTAssertEqual(ack.operationID,f.original.request.delivery.nativeOperationID);XCTAssertEqual(try snapshot(f.original.journalRoot),journal)
    }
    func testRecordedCandidateSameByteReplacementAndMissingProofRejectWithoutEffects() throws {
        let f=try privateFixture(),t=try terminal(f),ack=try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t)
        let current=f.original.structuralRoot.appendingPathComponent("native-current.json"),bytes=try Data(contentsOf:current)
        try bytes.write(to:current,options:.atomic)
        let before=try snapshot(f.original.structuralRoot),events=f.original.probe.events
        XCTAssertThrowsError(try f.coordinator.verifyNativeStructuralAcknowledgmentExact(ack,request:f.original.request))
        XCTAssertThrowsError(try f.coordinator.commitNativeStructuralExact(f.original.request,terminal:t))
        XCTAssertEqual(try snapshot(f.original.structuralRoot),before);XCTAssertEqual(f.original.probe.events,events)
    }
    func testActualMaximumNativeShapeReservationIsBoundedBeforeEffects() throws {
        maximumNames=true
        let f=try privateFixture(generic:false,count:12),t=try terminal(f)
        let before=try snapshot(f.original.structuralRoot),events=f.original.probe.events
        var journalSites:[DeviceLocalProvisioningIntentStore.Boundary]=[]
        var structuralSites:[DeviceStructuralStore.Boundary]=[]
        f.original.probe.journalAction={journalSites.append($0)}
        f.original.probe.structuralAction={structuralSites.append($0)}
        defer {f.original.probe.journalAction=nil;f.original.probe.structuralAction=nil}
        let sizes=try f.coordinator.nativeStructuralReservationSizesForTesting(f.original.request,terminal:t)
        print("NATIVE_STRUCTURAL_GENUINE_MAX_SHAPE_BYTES",sizes)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["envelope"]),128*1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["method"]),384*1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["binding"]),32768)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["terminal"]),32768)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sizes["reservedPublicBytes"]),128*1024*1024)
        XCTAssertEqual(try snapshot(f.original.structuralRoot),before);XCTAssertEqual(journalSites,[.beforeNativeHTTPScopeExit,.beforeNativeCompletionScopeExit])
        XCTAssertEqual(structuralSites,[.beforeNativeCommandScopeExit])
        XCTAssertEqual(f.original.probe.events,events+journalSites.count+structuralSites.count) // Only the exact read scope-exit validation sites above.
    }
    func testIndependentFieldCeilingsDoNotBypassAggregateEnvelopeLimit() throws {
        let value=DeviceNativeStructuralEnvelope(operationID:UUID(),expectedGenerationID:UUID(),snapshotBytes:Data(repeating:65,count:64*1024))
        // Existing candidate schema stays unchanged. Invalid snapshot bytes never become a candidate.
        XCTAssertThrowsError(try DeviceNativeStructuralEnvelopeCodec.encode(value))
        // Size-only maximum-width public metadata, not a fabricated qualified method or receipt.
        let id=StructuralStoreIdentity(device:UInt64.max,inode:UInt64.max),marker=DeviceNativeStructuralMarker(identity:id,byteCount:384*1024,digest:String(repeating:"f",count:64))
        let originals=Dictionary(uniqueKeysWithValues:["root-binding.json","native-genesis.intent","native-genesis.binding","native-genesis.json","native-genesis.confirm"].map{($0,marker)})
        let method=DeviceNativeStructuralMethod(schemaVersion:2,rootID:UUID(),operationID:UUID(),selfID:id,genesisStateBytes:Data(repeating:65,count:64*1024),original:originals,candidate:Data(repeating:66,count:128*1024),resourceAssertions:Data(repeating:67,count:8192),intent:Data(repeating:68,count:32768),outcome:Data(repeating:69,count:32768))
        let bytes=try DeviceNativeStructuralCommandCodec.encode(method,limit:384*1024)
        print("NATIVE_STRUCTURAL_MAXIMUM_METHOD_ENCODER_BYTES",bytes.count)
        XCTAssertLessThanOrEqual(bytes.count,384*1024)
    }
    #else
    func testCryptoKitUnavailableFailsClosedWithoutNativeCommandEffects() throws {
        XCTAssertThrowsError(try DeviceNativeDeliveryAttachmentCodec.hash(Data()))
    }
    #endif
}
