import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private final class M4Peer: WorkbenchDeploymentPeer {
    var profile = DeviceProfile(deviceId: "device-1", name: "Living Room")
    var screens: [LANScreenSetEntry] = []
    var selected: String?
    var calls = 0
    var generation: String?
    var commonEntries: [LANCommonScreenEntry]?
    var configuredEntryId: String?
    var activeGenerationId: String?
    var activeEntryId: String?
    var unifiedCalls = 0
    var acceptThenDrop = false
    var delayActivation = false
    var observeHook: (() -> Void)?
    var sendPreparationHook: (() -> Void)?
    func observe(deviceId: String) throws -> WorkbenchDeploymentObservation {
        observeHook?()
        var result = WorkbenchDeploymentObservation(deviceId: deviceId, name: profile.name, profile: profile,
            screens: screens, selectedDashboardId: selected, observedAt: Date(timeIntervalSince1970: 2_000_000_000))
        result.stateGenerationId = generation; result.commonEntries = commonEntries; result.configuredEntryId = configuredEntryId
        result.activeGenerationId = activeGenerationId; result.activeEntryId = activeEntryId
        return result
    }
    func sendUnified(_ body: LANUnifiedScreenInstall, deviceId: String, preSend: () throws -> Void) throws -> LANActiveQuery {
        sendPreparationHook?(); try preSend(); unifiedCalls += 1
        guard body.expectedGenerationId == generation else { throw TransferFailure.validationFailed }
        var entries = (commonEntries ?? []).filter { body.retainedEntryIds.contains($0.entryId) }
        for entry in body.incoming {
            entries.removeAll { $0.entryId == entry.entryId }
            entries.append(.init(entryId: entry.entryId, dashboardId: entry.screen.deployment.revision.dashboardId,
                revision: entry.screen.deployment.revision.revision, name: entry.screen.name, origin: "retainedLocal"))
        }
        generation = body.operationId; commonEntries = entries; configuredEntryId = body.selectedEntryId
        screens = entries.map { .init(dashboardId: $0.dashboardId, revision: $0.revision, name: $0.name) }
        selected = entries.first { $0.entryId == configuredEntryId }?.dashboardId
        return LANActiveQuery(screens: screens, selectedDashboardId: selected, controllerApproved: true,
            stateGenerationId: generation, commonEntries: entries, configuredEntryId: configuredEntryId)
    }
    func send(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt {
        calls += 1
        let entries = body.screens.map { LANScreenSetEntry(dashboardId: $0.deployment.revision.dashboardId,
            revision: $0.deployment.revision.revision, name: $0.name) }
        if !delayActivation { screens = entries; selected = body.selectedDashboardId }
        if acceptThenDrop { throw TransferFailure.interrupted }
        return LANScreenSetReceipt(deploymentId: body.deploymentId, deviceId: body.deviceId,
            screens: entries, selectedDashboardId: body.selectedDashboardId)
    }
    func send(_ body: LANScreenSetDeployBody,
              preSend: () throws -> Void) throws -> LANScreenSetReceipt {
        sendPreparationHook?()
        try preSend()
        return try send(body)
    }
}

private final class M4NativeSendState: @unchecked Sendable {
    var calls = 0
    var dropReply = true
    var helloCountdown = 0
    var onCountedHello: (() -> Void)?
}
private final class M4NativeDropLink: DeviceLink {
    let inner: FakeLANLink
    let state: M4NativeSendState
    init(device: FakeLANDevice, owner: PairingIdentity, state: M4NativeSendState) {
        inner = FakeLANLink(device: device, controllerPin: owner.publicKey); self.state = state
    }
    var devicePin: [UInt8]? { inner.devicePin }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws {
        try inner.connect(host: host, port: port, pinnedDevice: pinnedDevice)
    }
    func hello() throws -> LANHello {
        if state.helloCountdown > 0 {
            state.helloCountdown -= 1
            if state.helloCountdown == 0 { state.onCountedHello?() }
        }
        return try inner.hello()
    }
    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult { try inner.beginPairing(nonce: nonce) }
    func confirmPairing(code: String) throws { try inner.confirmPairing(code: code) }
    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord { try inner.deploy(body) }
    func queryActive() throws -> String? { try inner.queryActive() }
    func deployScreenSet(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt {
        state.calls += 1
        let receipt = try inner.deployScreenSet(body)
        if state.dropReply { throw TransferFailure.interrupted }
        return receipt
    }
    func provisionConnections(_ configuration: ConnectionProvisioning) throws -> ConnectionProvisioningReceipt {
        try configuration.validate()
        return .init(deviceId: inner.device.runtime.profile.deviceId,
                     dashboardId: configuration.dashboardId, revision: configuration.revision,
                     provisioningId: configuration.provisioningId)
    }
    func cancel() { inner.cancel() }
}
private final class M4Secrets: WorkbenchSecretProvider {
    var values: [String: Data] = [:]
    func install(_ secret: Data, for authRef: String) throws { values[authRef] = secret }
    func load(authRef: String) throws -> Data {
        guard let value = values[authRef] else { throw ConnectionFailure.permissionRequired }
        return value
    }
    func remove(authRef: String) throws { values[authRef] = nil }
}
private struct M4NativeDropFactory: DeviceLinkFactory {
    let device: FakeLANDevice
    let controllerIdentity: PairingIdentity
    let state: M4NativeSendState
    func makeLink() throws -> DeviceLink {
        M4NativeDropLink(device: device, owner: controllerIdentity, state: state)
    }
}
private struct M4BrokerFactory: DeviceLinkFactory {
    let device: FakeLANDevice
    let controllerIdentity: PairingIdentity
    func makeLink() throws -> DeviceLink {
        FakeLANLink(device: device, controllerPin: controllerIdentity.publicKey)
    }
}
private struct M4Documents: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchM4DeploymentDomainTests: XCTestCase {
    func testBrokerPreparedPlanApplyStatusAndIdempotentRetryWithFakePeer() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-m4-broker-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: M4Documents(url: root.appendingPathComponent("Documents")),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html>Exact package</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "broker-screen", name: "Exact screen", revision: "source-one",
            entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "source", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("home"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        let peer = M4Peer()
        let owner = PairingIdentityFactory.make(role: .controller)
        let paired = PairedDevice(profile: peer.profile, owner: owner, reachable: false)
        try controller.devices.directory.upsert(PairedDeviceRecord(device: paired,
            host: "192.0.2.10", port: 7843,
            devicePinHex: PeerPin.hex(Array(repeating: 8, count: 32)), pairedAt: Date()))
        let linkDevice = FakeLANDevice(deviceId: "device-1", name: "Fixture iPad")
        let factory = M4BrokerFactory(device: linkDevice, controllerIdentity: owner)
        let native = WorkbenchNativeComposition(activateOnStart: false,
            activate: { $0.devices.attach(factory) },
            deactivate: { controller.devices.attach(nil) })
        let clock = WorkbenchDeploymentClock(wallSeconds: 2_000_000_000,
            monotonicMilliseconds: 100_000, bootId: "test-boot")
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native, dispatchObserver: nil,
            machineAuthorityPath: root.appendingPathComponent("machine/authority.json").path,
            mutationGate: {}, deploymentPeerFactory: { _ in peer }, deploymentClock: { clock })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect(); defer { client.close() }
        let selected = try client.workspaceStatus()
        let base: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": try XCTUnwrap(selected.workspaceId),
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)]
        func fields(_ extra: [String: Any]) -> [String: Any] { base.merging(extra) { _, new in new } }
        let preparation = try client.performDeployment(method: .prepare, params: fields([
            "deviceId": "device-1", "dashboardId": "broker-screen",
            "sourceRevision": "source-one", "orientation": "portrait"]))
        let prepared = try XCTUnwrap(preparation.prepared)
        XCTAssertNotEqual(prepared.revision, manifest.revision)
        let plan = try client.performDeployment(method: .plan, params: fields([
            "deviceId": "device-1", "packages": [["dashboardId": prepared.dashboardId,
                "sourceRevision": prepared.sourceRevision, "revision": prepared.revision,
                "dataDescription": "Private fixture"]],
            "selectedDashboardId": prepared.dashboardId, "removedDashboardIds": [String](),
            "bindingIds": [String](), "lifetimeSeconds": 3600]))
        let review = try XCTUnwrap(plan.review)
        XCTAssertEqual(review.plan.packages.first?.revision, prepared.revision)
        XCTAssertEqual(try client.performDeployment(method: .review, params: fields([
            "planId": review.plan.planId])).review?.planHash, review.planHash)
        let rejected = WorkbenchBrokerClient(environment: environment)
        try rejected.connect(); defer { rejected.close() }
        XCTAssertThrowsError(try rejected.performDeployment(method: .apply, params: fields([
            "planId": review.plan.planId, "expectedPlanHash": review.planHash,
            "expectedAuthorizationContextHash": review.authorizationContextHash!,
            "idempotencyKey": "attempt-one", "approved": false]))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .confirmationRequired)
        }
        XCTAssertEqual(peer.calls, 0)
        let apply: [String: Any] = fields(["planId": review.plan.planId,
            "expectedPlanHash": review.planHash,
            "expectedAuthorizationContextHash": review.authorizationContextHash!,
            "idempotencyKey": "attempt-one",
            "approved": true])
        var staleContext = apply
        staleContext["expectedAuthorizationContextHash"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try client.performDeployment(method: .apply,
            params: staleContext)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        XCTAssertEqual(peer.calls, 0)
        client.close()
        try client.connect()
        let operation = try XCTUnwrap(client.performDeployment(method: .apply,
            params: apply).operation)
        XCTAssertEqual(operation.state, .active)
        let ledger = try WorkbenchDeploymentLedger(path:
            root.appendingPathComponent("machine/deployment-ledger.sqlite").path)
        XCTAssertEqual(try ledger.approval(operation.approvalId).consentSource, "agent_asserted")
        XCTAssertEqual(peer.calls, 1)
        XCTAssertEqual(try client.performDeployment(method: .apply,
            params: apply).operation?.operationId, operation.operationId)
        XCTAssertEqual(peer.calls, 1)
        XCTAssertEqual(try client.performDeployment(method: .status, params: fields([
            "operationId": operation.operationId])).operation?.state, .active)
        XCTAssertEqual(try client.performDeployment(method: .reconcile, params: fields([
            "operationId": operation.operationId])).operation?.state, .active)

        var newer = manifest
        newer.revision = "source-two"
        newer.name = "Updated screen"
        newer.digest = try DeploymentDigest.digest(for: newer)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: newer, files: ["index.html": html]))
        let nextPrepared = try XCTUnwrap(client.performDeployment(method: .prepare,
            params: fields(["deviceId": "device-1", "dashboardId": "broker-screen",
                "sourceRevision": "source-two", "orientation": "portrait"])).prepared)
        func planFields(_ package: WorkbenchPreparedPackageSummary) -> [String: Any] {
            fields(["deviceId": "device-1", "packages": [["dashboardId": package.dashboardId,
                "sourceRevision": package.sourceRevision, "revision": package.revision,
                "dataDescription": "Private fixture"]],
                "selectedDashboardId": package.dashboardId, "removedDashboardIds": [String](),
                "bindingIds": [String](), "lifetimeSeconds": 3600])
        }
        let update = try XCTUnwrap(client.performDeployment(method: .plan,
            params: planFields(nextPrepared)).review)
        XCTAssertEqual(update.previouslySelectedDashboardId, prepared.dashboardId)
        let scripted = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview)
        try scripted.connect(); defer { scripted.close() }
        let updated = try XCTUnwrap(scripted.performDeployment(method: .apply,
            params: fields(["planId": update.plan.planId, "expectedPlanHash": update.planHash,
                "expectedAuthorizationContextHash": update.authorizationContextHash!,
                "idempotencyKey": "attempt-two", "approved": true,
                "approvalMode": "scripted"])).operation)
        XCTAssertEqual(updated.state, .active)
        XCTAssertEqual(try ledger.approval(updated.approvalId).consentSource, "terminal_asserted")
        XCTAssertEqual(peer.calls, 2)

        // Rollback is a fresh exact-set plan and consent, using retained
        // prepared bytes rather than resurrecting the old approval.
        let rollback = try XCTUnwrap(client.performDeployment(method: .rollbackPlan,
            params: planFields(prepared)).review)
        XCTAssertEqual(rollback.plan.packages[0].revision, prepared.revision)
        let restored = try XCTUnwrap(client.performDeployment(method: .apply,
            params: fields(["planId": rollback.plan.planId,
                "expectedPlanHash": rollback.planHash,
                "expectedAuthorizationContextHash": rollback.authorizationContextHash!,
                "idempotencyKey": "rollback-one", "approved": true])).operation)
        XCTAssertEqual(restored.state, .active)
        XCTAssertEqual(peer.screens.first?.revision, prepared.revision)
        XCTAssertEqual(peer.calls, 3)

        let cancelledPlan = try XCTUnwrap(client.performDeployment(method: .plan,
            params: planFields(nextPrepared)).review)
        let cancellation = try client.performDeployment(method: .cancel, params: fields([
            "planId": cancelledPlan.plan.planId, "deviceId": "device-1"]))
        XCTAssertEqual(cancellation.cancelled, true)
        let deniedAfterCancel = WorkbenchBrokerClient(environment: environment)
        try deniedAfterCancel.connect(); defer { deniedAfterCancel.close() }
        XCTAssertThrowsError(try deniedAfterCancel.performDeployment(method: .apply,
            params: fields(["planId": cancelledPlan.plan.planId,
                "expectedPlanHash": cancelledPlan.planHash,
                "expectedAuthorizationContextHash": cancelledPlan.authorizationContextHash!,
                "idempotencyKey": "cancelled-attempt", "approved": true])))
        XCTAssertEqual(peer.calls, 3)

        peer.acceptThenDrop = true
        let uncertainPlan = try XCTUnwrap(client.performDeployment(method: .plan,
            params: planFields(nextPrepared)).review)
        let uncertainParams = fields(["planId": uncertainPlan.plan.planId,
            "expectedPlanHash": uncertainPlan.planHash,
            "expectedAuthorizationContextHash": uncertainPlan.authorizationContextHash!,
            "idempotencyKey": "dropped-receipt", "approved": true])
        let uncertain = try XCTUnwrap(client.performDeployment(method: .apply,
            params: uncertainParams).operation)
        XCTAssertEqual(uncertain.state, .unknown)
        XCTAssertEqual(peer.calls, 4)
        XCTAssertEqual(try client.performDeployment(method: .lookup,
            params: fields(["planId": uncertainPlan.plan.planId])).operation?.operationId,
            uncertain.operationId)
        XCTAssertEqual(peer.calls, 4)
        XCTAssertEqual(try client.performDeployment(method: .apply,
            params: uncertainParams).operation?.operationId, uncertain.operationId)
        XCTAssertEqual(peer.calls, 4)
        XCTAssertEqual(try client.performDeployment(method: .reconcile,
            params: fields(["operationId": uncertain.operationId])).operation?.state, .unknown)
    }

    private final class Fixture {
        let root: URL
        let peer = M4Peer()
        let boundary = WorkbenchAuthorityBoundary()
        var context = "537f52ca0ccc7aab4d8b932a4ab563af530eee944294d77375da80e32d420c20"
        var clock = WorkbenchDeploymentClock(wallSeconds: 2_000_000_000,
            monotonicMilliseconds: 100_000, bootId: "test-boot")
        var domain: WorkbenchDeploymentDomain!
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/sp-m4-domain-" + UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            domain = try WorkbenchDeploymentDomain(ledgerPath: root.appendingPathComponent("authority/deployments.sqlite").path,
                peer: peer, boundary: boundary, currentContext: { [unowned self] _, _ in self.context },
                clock: { [unowned self] in self.clock }, dispatchEnabled: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func reopen() throws -> WorkbenchDeploymentDomain {
            try WorkbenchDeploymentDomain(ledgerPath: root.appendingPathComponent("authority/deployments.sqlite").path,
                peer: peer, boundary: boundary, currentContext: { [unowned self] _, _ in self.context },
                clock: { [unowned self] in self.clock }, dispatchEnabled: true)
        }
        func screen(_ name: String, behavior: DeviceBehavior? = nil,
                    connections: [ManifestConnection] = []) throws -> WorkbenchFrozenScreen {
            let store = try DashboardPackageStore(root: root.appendingPathComponent("package-" + UUID().uuidString.lowercased()))
            let record = try store.putDashboard(dashboardId: nil, name: name, baseRevision: nil,
                target: ManifestTarget(profileId: "device-1", width: peer.profile.width,
                    height: peer.profile.height, scale: 3, orientation: "portrait"),
                connections: connections, files: [htmlFile(name)], deviceBehavior: behavior)
            let manifestData = try Data(contentsOf: record.packageDirectory.appendingPathComponent("manifest.json"))
            var blobs = record.files.map { path, bytes in
                LANFileBlob(path: path, sha256: DeploymentDigest.sha256Hex(bytes),
                            dataBase64: bytes.base64EncodedString())
            }
            blobs.append(.init(path: "manifest.json", sha256: DeploymentDigest.sha256Hex(manifestData),
                               dataBase64: manifestData.base64EncodedString()))
            blobs.sort { $0.path < $1.path }
            let revision = StoredRevision(revision: record.manifest.revision,
                dashboardId: record.manifest.dashboardId, name: record.manifest.name,
                digest: try XCTUnwrap(record.manifest.digest), orientation: .portrait,
                width: record.manifest.target.width, height: record.manifest.target.height)
            let deploy = LANDeployBody(deployment: DeploymentRecord(deploymentId: "planned",
                revision: revision.revision, dashboardId: revision.dashboardId,
                deviceId: "device-1", phase: .queued), revision: revision, files: blobs)
            return WorkbenchFrozenScreen(sourceRevision: record.manifest.revision,
                dataDescription: "Fixture only \u{1b}[31m\n unknown", item: LANScreenSetItem(name: name, deployment: deploy))
        }
        func prepare(_ screens: [WorkbenchFrozenScreen], selected: String,
                     removed: [String] = []) throws -> WorkbenchDeploymentReview {
            try domain.prepare(workspaceId: "workspace-1", deviceId: "device-1",
                material: .init(screens: screens.sorted { $0.item.deployment.revision.dashboardId < $1.item.deployment.revision.dashboardId },
                                selectedDashboardId: selected, bindingIds: []),
                removedDashboardIds: removed)
        }
    }

    func testConnectionBearingPlanAwaitsGrantThenChecksScopeBeforeSingleSend() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let declaration = ManifestConnection(alias: "weather", required: true,
            operations: [.init(name: "read", kind: "http")])
        let screen = try fixture.screen("Connected", connections: [declaration])
        let dashboardId = screen.item.deployment.revision.dashboardId
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "weather",
            origin: "https://example.local", transport: .http, authRef: "fixture-ref", lan: true,
            allowInsecureHTTP: false,
            operations: [.init(name: "read", kind: .http, method: .GET,
                               path: "/api/read", idempotent: true, write: false)])
        let scope = WorkbenchConnectionSummary(bindingId: grant.id.uuidString.lowercased(),
            deviceId: "device-1", dashboardId: dashboardId,
            revision: screen.item.deployment.revision.revision,
            grant: grant, auth: .init(authRef: "fixture-ref", placement: .none),
            localStatus: "locally_authorized")
        var ready = false, installs = 0, failInstall = false
        let domain = try WorkbenchDeploymentDomain(
            ledgerPath: fixture.root.appendingPathComponent("authority/connected.sqlite").path,
            peer: fixture.peer, boundary: fixture.boundary,
            currentContext: { [unowned fixture] _, _ in fixture.context },
            clock: { [unowned fixture] in fixture.clock }, dispatchEnabled: true,
            grantAssessor: { _, requirements, ids in
                XCTAssertEqual(requirements.first?.manifest.connections, [declaration])
                XCTAssertEqual(ids, [scope.bindingId])
                return .init(scopes: ready ? [scope] : [],
                    missing: ready ? [] : [dashboardId + "/weather"])
            }, grantInstaller: { _, selected, ids in
                XCTAssertEqual(selected.dashboardId, dashboardId)
                XCTAssertEqual(ids, [scope.bindingId])
                installs += 1
                if failInstall { throw ConnectionFailure.deviceOffline }
            })
        let material = WorkbenchDeploymentMaterial(screens: [screen],
            selectedDashboardId: dashboardId, bindingIds: [scope.bindingId])
        let awaiting = try domain.prepare(workspaceId: "workspace-1", deviceId: "device-1",
            material: material, removedDashboardIds: [])
        XCTAssertNil(awaiting.authorizationContextHash)
        XCTAssertEqual(awaiting.missingGrants, [dashboardId + "/weather"])
        XCTAssertNotNil(try domain.review(planId: awaiting.plan.planId))
        XCTAssertThrowsError(try domain.approve(awaiting, consent: .terminal()))
        XCTAssertEqual(fixture.peer.calls, 0)
        ready = true
        let review = try domain.prepare(workspaceId: "workspace-1", deviceId: "device-1",
            material: material, removedDashboardIds: [])
        XCTAssertNotNil(review.authorizationContextHash)
        XCTAssertEqual(review.grantScopes, [scope])
        XCTAssertNotEqual(review.plan.requiredDeclarationsHash,
            try ToolchainCanonical.hash(domain: "required-declarations", value: [] as [String]))
        let text = WorkbenchDeploymentPresentation.render(review)
        XCTAssertTrue(text.contains("https://example.local/api/read"))
        let approval = try domain.approve(review, consent: .terminal())
        let admitted = try domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "connected", approved: true)
        let active = try domain.dispatch(operationId: admitted.operationId, review: review)
        XCTAssertEqual(active.state, .active)
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(fixture.peer.calls, 1)
        let duplicate = try domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "connected", approved: true)
        XCTAssertEqual(duplicate.operationId, active.operationId)
        failInstall = true
        let second = try domain.prepare(workspaceId: "workspace-1", deviceId: "device-1",
            material: material, removedDashboardIds: [])
        let secondApproval = try domain.approve(second, consent: .terminal())
        let secondAdmitted = try domain.admit(second, approvalId: secondApproval.approvalId,
            idempotencyKey: "connected-second", approved: true)
        XCTAssertThrowsError(try domain.dispatch(operationId: secondAdmitted.operationId,
            review: second)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .unknownRemoteOutcome)
        }
        XCTAssertEqual(try domain.status(secondAdmitted.operationId).state, .unknown)
        XCTAssertEqual(fixture.peer.calls, 2)
        XCTAssertThrowsError(try domain.dispatch(operationId: secondAdmitted.operationId,
            review: second))
        XCTAssertEqual(fixture.peer.calls, 2)
    }

    func testCommonInstallKeepsCloudScreenAndReceiptDoesNotClaimMounted() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let cloudID = UUID().uuidString.lowercased()
        fixture.peer.generation = UUID().uuidString.lowercased()
        fixture.peer.commonEntries = [.init(entryId: cloudID, dashboardId: "cloud-screen", revision: "cloud-revision", name: "Cloud", origin: "cloud")]
        fixture.peer.configuredEntryId = cloudID
        fixture.peer.screens = [.init(dashboardId: "cloud-screen", revision: "cloud-revision", name: "Cloud")]
        fixture.peer.selected = "cloud-screen"
        let screen = try fixture.screen("A")
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        XCTAssertEqual(review.plan.expectedStateGenerationId, fixture.peer.generation)
        XCTAssertTrue(review.result.contains { $0.dashboardId == "cloud-screen" })
        let approval = try fixture.domain.approve(review, consent: .terminal())
        let admitted = try fixture.domain.admit(review, approvalId: approval.approvalId, idempotencyKey: "common", approved: true)
        let result = try fixture.domain.dispatch(operationId: admitted.operationId, review: review)
        XCTAssertEqual(result.state, .received)
        XCTAssertEqual(fixture.peer.unifiedCalls, 1)
        XCTAssertEqual(fixture.peer.calls, 0)
        XCTAssertTrue(fixture.peer.commonEntries!.contains { $0.entryId == cloudID && $0.origin == "cloud" })
        XCTAssertEqual(try fixture.domain.reconcile(operationId: admitted.operationId, review: review).state, .received)
        let localID = try XCTUnwrap(fixture.peer.commonEntries!.first { $0.origin == "retainedLocal" }?.entryId)
        let reapplied = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        let secondApproval = try fixture.domain.approve(reapplied, consent: .terminal())
        let second = try fixture.domain.admit(reapplied, approvalId: secondApproval.approvalId, idempotencyKey: "explicit-reapply", approved: true)
        XCTAssertEqual(try fixture.domain.dispatch(operationId: second.operationId, review: reapplied).state, .received)
        XCTAssertEqual(fixture.peer.commonEntries!.first { $0.origin == "retainedLocal" }?.entryId, localID)
        XCTAssertEqual(fixture.peer.commonEntries!.count, 2)
        // A last-successful screen from an older generation cannot complete this operation.
        fixture.peer.activeGenerationId = admitted.operationId; fixture.peer.activeEntryId = localID
        XCTAssertEqual(try fixture.domain.reconcile(operationId: second.operationId, review: reapplied).state, .received)
        fixture.peer.activeGenerationId = second.operationId
        XCTAssertEqual(try fixture.domain.reconcile(operationId: second.operationId, review: reapplied).state, .active)
    }

    func testCommonGenerationChangeAfterReviewPreventsFirstSend() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.peer.generation = UUID().uuidString.lowercased(); fixture.peer.commonEntries = []
        let screen = try fixture.screen("A")
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        let approval = try fixture.domain.approve(review, consent: .terminal())
        let admitted = try fixture.domain.admit(review, approvalId: approval.approvalId, idempotencyKey: "stale-common", approved: true)
        fixture.peer.sendPreparationHook = { fixture.peer.generation = UUID().uuidString.lowercased() }
        _ = try fixture.domain.dispatch(operationId: admitted.operationId, review: review)
        XCTAssertEqual(fixture.peer.unifiedCalls, 0)
        XCTAssertEqual(fixture.peer.calls, 0)
    }

    func testExplicitApprovalOneSendAndSafeExactReview() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("A")
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        XCTAssertEqual(review.nativeRenderVerification, "not_performed")
        XCTAssertTrue(review.plan.packages[0].dataDescription.contains("\u{1b}"))
        XCTAssertTrue(review.plan.packages[0].dataDescription.contains("\n"))
        let terminal = WorkbenchDeploymentPresentation.render(review)
        XCTAssertFalse(terminal.contains("\u{1b}"))
        XCTAssertTrue(terminal.contains("\\u{1B}"))
        XCTAssertTrue(terminal.contains("\\u{A}"))
        XCTAssertEqual(WorkbenchDeploymentPresentation.escape("A\u{202e}B"), "A\\u{202E}B")
        XCTAssertEqual(try WorkbenchDeploymentHash.plan(review.plan), review.planHash)
        let approval = try fixture.domain.approve(review, consent: .terminal())
        XCTAssertThrowsError(try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "attempt", approved: false)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .invalidApproval)
        }
        let admitted = try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "attempt", approved: true)
        XCTAssertEqual(admitted.state, .admitted)
        let result = try fixture.domain.dispatch(operationId: admitted.operationId, review: review)
        XCTAssertEqual(result.state, .active)
        XCTAssertEqual(fixture.peer.calls, 1)
        XCTAssertEqual(try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "second-key", approved: true).operationId, admitted.operationId)
        XCTAssertThrowsError(try fixture.domain.dispatch(operationId: admitted.operationId, review: review))
        XCTAssertEqual(fixture.peer.calls, 1)
    }

    func testSubsecondApprovalDeadlineAndAutoplayAreRepresented() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("Audio", behavior: .init(audio: .init(autoplay: true)))
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        XCTAssertTrue(review.plan.packages[0].declaredCapabilities.contains("audio.autoplay.allowed"))
        XCTAssertTrue(WorkbenchDeploymentPresentation.render(review).contains("audio.autoplay.allowed"))
        fixture.clock = .init(wallSeconds: fixture.clock.wallSeconds,
            monotonicMilliseconds: fixture.clock.monotonicMilliseconds + 100,
            bootId: fixture.clock.bootId)
        XCTAssertNoThrow(try fixture.domain.approve(review, consent: .terminal()))
    }

    func testFailedPlanPreparationPersistsRollbackAcrossReopen() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("Clock preparation")
        let selected = screen.item.deployment.revision.dashboardId
        let review = try fixture.prepare([screen], selected: selected)
        let approval = try fixture.domain.approve(review, consent: .terminal())
        let base = fixture.clock
        fixture.clock = .init(wallSeconds: base.wallSeconds - 1,
                              monotonicMilliseconds: base.monotonicMilliseconds + 1,
                              bootId: base.bootId)
        XCTAssertThrowsError(try fixture.prepare([screen], selected: selected)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .clockUncertain)
        }
        let reopened = try fixture.reopen()
        fixture.clock = .init(wallSeconds: base.wallSeconds + 1,
                              monotonicMilliseconds: base.monotonicMilliseconds + 2,
                              bootId: base.bootId)
        XCTAssertThrowsError(try reopened.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "after-preparation-reopen", approved: true)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .clockUncertain)
        }
        XCTAssertEqual(fixture.peer.calls, 0)
    }

    func testPreparationOverflowPrecheckStillPersistsObservedClock() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("Clock overflow")
        let selected = screen.item.deployment.revision.dashboardId
        let review = try fixture.prepare([screen], selected: selected)
        let approval = try fixture.domain.approve(review, consent: .terminal())
        let base = fixture.clock
        fixture.clock = .init(wallSeconds: Int64.max - 1,
                              monotonicMilliseconds: base.monotonicMilliseconds + 1,
                              bootId: base.bootId)
        XCTAssertThrowsError(try fixture.prepare([screen], selected: selected)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .clockUncertain)
        }
        let reopened = try fixture.reopen()
        fixture.clock = .init(wallSeconds: base.wallSeconds + 1,
                              monotonicMilliseconds: base.monotonicMilliseconds + 2,
                              bootId: base.bootId)
        XCTAssertThrowsError(try reopened.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "after-overflow-reopen", approved: true)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .clockUncertain)
        }
        XCTAssertEqual(fixture.peer.calls, 0)
    }

    func testExpiredApprovalPrecheckRetiresOldConsentAcrossReopen() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("Clock approval")
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        let approval = try fixture.domain.approve(review, consent: .terminal())
        let base = fixture.clock
        let expiry = Int64(try XCTUnwrap(ISO8601DateFormatter().date(from: review.plan.expiresAt)).timeIntervalSince1970)
        fixture.clock = .init(wallSeconds: expiry,
                              monotonicMilliseconds: base.monotonicMilliseconds + 1,
                              bootId: base.bootId)
        XCTAssertThrowsError(try fixture.domain.approve(review, consent: .terminal())) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .expired)
        }
        let reopened = try fixture.reopen()
        fixture.clock = .init(wallSeconds: expiry - 1,
                              monotonicMilliseconds: base.monotonicMilliseconds + 2,
                              bootId: base.bootId)
        XCTAssertThrowsError(try reopened.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "after-expiry-reopen", approved: true)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .invalidApproval)
        }
        XCTAssertEqual(fixture.peer.calls, 0)
    }

    func testReconciliationRejectsAlteredCallerResultEvenWithCorrelatedReceipt() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("New")
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        let approval = try fixture.domain.approve(review, consent: .terminal())
        let admitted = try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "tamper", approved: true)
        fixture.peer.delayActivation = true
        XCTAssertEqual(try fixture.domain.dispatch(operationId: admitted.operationId, review: review).state, .received)
        let forged = WorkbenchDeploymentReview(plan: review.plan, planHash: review.planHash,
            authorizationContextHash: review.authorizationContextHash,
            deviceName: review.deviceName, observedAt: review.observedAt,
            previouslyInstalled: review.previouslyInstalled,
            previouslySelectedDashboardId: review.previouslySelectedDashboardId, result: [],
            packageBytes: review.packageBytes, note: review.note,
            nativeRenderVerification: review.nativeRenderVerification)
        XCTAssertThrowsError(try fixture.domain.reconcile(operationId: admitted.operationId, review: forged)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .conflict)
        }
        XCTAssertEqual(try fixture.domain.status(admitted.operationId).state, .received)
    }

    func testDispatchRechecksExpiryAfterSlowFinalObservation() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("Slow")
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        let approval = try fixture.domain.approve(review, consent: .terminal())
        let admitted = try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "slow", approved: true)
        let before = fixture.clock
        fixture.peer.observeHook = {
            fixture.clock = .init(wallSeconds: before.wallSeconds + 3600,
                monotonicMilliseconds: before.monotonicMilliseconds + 3_600_000,
                bootId: before.bootId)
        }
        let state = try fixture.domain.dispatch(operationId: admitted.operationId, review: review)
        XCTAssertEqual(state.state, .cancelled)
        XCTAssertFalse(state.sendAttempted)
        XCTAssertEqual(fixture.peer.calls, 0)
    }

    func testExpiryDuringNativeSendPreparationFailsBeforeFirstFrameAndConsumesAdmission() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("Slow capability query")
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        let approval = try fixture.domain.approve(review, consent: .terminal())
        let admitted = try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "slow-native-preparation", approved: true)
        let before = fixture.clock
        fixture.peer.sendPreparationHook = {
            fixture.clock = .init(wallSeconds: before.wallSeconds + 3600,
                monotonicMilliseconds: before.monotonicMilliseconds + 3_600_000,
                bootId: before.bootId)
        }
        let outcome = try fixture.domain.dispatch(operationId: admitted.operationId, review: review)
        XCTAssertEqual(outcome.state, .failed)
        XCTAssertFalse(outcome.sendAttempted)
        XCTAssertEqual(fixture.peer.calls, 0)
        XCTAssertEqual(try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "slow-native-preparation", approved: true).state, .failed)
        XCTAssertThrowsError(try fixture.domain.dispatch(operationId: admitted.operationId, review: review))
        XCTAssertEqual(fixture.peer.calls, 0)
    }

    func testDroppedReplyStaysUnknownUntilCorrelatedObservationWithoutRetry() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("B")
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        let approval = try fixture.domain.approve(review, consent: .agentAssertion())
        let admitted = try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "drop", approved: true)
        fixture.peer.acceptThenDrop = true
        XCTAssertThrowsError(try fixture.domain.dispatch(operationId: admitted.operationId, review: review)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .unknownRemoteOutcome)
        }
        XCTAssertEqual(try fixture.domain.status(admitted.operationId).state, .unknown)
        XCTAssertEqual(fixture.peer.calls, 1)
        XCTAssertEqual(try fixture.domain.reconcile(operationId: admitted.operationId, review: review).state, .unknown,
                       "the existing query lacks a correlated deployment ID")
        XCTAssertThrowsError(try fixture.domain.dispatch(operationId: admitted.operationId, review: review))
        XCTAssertEqual(fixture.peer.calls, 1)
    }

    func testReceiptIsNotActivationAndPreservedScreensMustBeExplicit() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = try fixture.screen("Original")
        let next = try fixture.screen("Next")
        let oldID = original.item.deployment.revision.dashboardId
        let newID = next.item.deployment.revision.dashboardId
        fixture.peer.screens = [.init(dashboardId: oldID, revision: original.item.deployment.revision.revision,
                                      name: original.item.name)]
        fixture.peer.selected = oldID
        XCTAssertThrowsError(try fixture.prepare([next], selected: newID)) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .invalidPlan)
        }
        let review = try fixture.prepare([original, next], selected: newID)
        XCTAssertTrue(review.plan.removedDashboardIds.isEmpty)
        let approval = try fixture.domain.approve(review, consent: .gui())
        let admitted = try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "two", approved: true)
        fixture.peer.delayActivation = true
        XCTAssertEqual(try fixture.domain.dispatch(operationId: admitted.operationId, review: review).state, .received)
        XCTAssertEqual(try fixture.domain.reconcile(operationId: admitted.operationId, review: review).state, .received)
        fixture.peer.screens = review.result; fixture.peer.selected = newID
        XCTAssertEqual(try fixture.domain.reconcile(operationId: admitted.operationId, review: review).state, .active)
    }

    func testContextChangesAndCancellationBeforeDispatchNeverSend() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("C")
        let review = try fixture.prepare([screen], selected: screen.item.deployment.revision.dashboardId)
        fixture.context = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try fixture.domain.approve(review, consent: .terminal())) {
            XCTAssertEqual($0 as? WorkbenchDeploymentError, .staleContext)
        }
        fixture.context = review.authorizationContextHash!
        let approval = try fixture.domain.approve(review, consent: .terminal())
        let admitted = try fixture.domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "cancel", approved: true)
        fixture.context = String(repeating: "e", count: 64)
        XCTAssertEqual(try fixture.domain.dispatch(operationId: admitted.operationId, review: review).state, .cancelled)
        XCTAssertEqual(fixture.peer.calls, 0)
    }

    func testNativeCachedLinkDoesNotReplayScreenSetAfterDroppedReply() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try fixture.screen("Native")
        let device = FakeLANDevice(deviceId: "device-1", name: "Native")
        let owner = PairingIdentityFactory.make(role: .controller)
        let state = M4NativeSendState()
        let hub = LoopbackDiscovery(); hub.advertise(device.runtime.advertisement)
        let coordinator = DeviceCoordinator(directory: DeviceDirectory(url: fixture.root.appendingPathComponent("devices.json")),
            hub: hub, linkFactory: M4NativeDropFactory(device: device, controllerIdentity: owner, state: state))
        let pending = try coordinator.requestPairing(deviceId: "device-1", host: nil, port: nil)
        device.confirmLocally()
        _ = try coordinator.confirmPairing(deviceId: pending.deviceId)
        var item = screen.item
        item.deployment.deployment.deploymentId = "operation-1"
        let body = LANScreenSetDeployBody(deploymentId: "operation-1", deviceId: "device-1",
            screens: [item], selectedDashboardId: item.deployment.revision.dashboardId)
        XCTAssertThrowsError(try coordinator.deployScreenSet(body))
        XCTAssertEqual(state.calls, 1)
    }

    func testActualM3ForgetSharesAdmissionBoundaryAndPreventsM4FirstSend() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let documents = fixture.root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: M4Documents(url: documents),
            machineRootPath: fixture.root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let native = FakeLANDevice(deviceId: "device-1", name: "Native")
        let owner = PairingIdentityFactory.make(role: .controller)
        let hub = LoopbackDiscovery(); hub.advertise(native.runtime.advertisement)
        let coordinator = DeviceCoordinator(directory: DeviceDirectory(url: fixture.root.appendingPathComponent("devices.json")),
            hub: hub, linkFactory: FakeLANLinkFactory(device: native, controllerIdentity: owner))
        let connections = try WorkbenchConnectionDomain(machineAuthorityPath: fixture.root.appendingPathComponent("authority-m3").path,
            devices: coordinator, workspace: workspace)
        let devices = connections.deviceDomain()
        let pending = try devices.beginPairing(deviceId: "device-1")
        native.confirmLocally()
        _ = try devices.confirmPairing(pendingId: pending.pendingId, matchingCode: pending.matchingCode)
        let domain = try WorkbenchDeploymentDomain(ledgerPath: fixture.root.appendingPathComponent("authority-m4/deployments.sqlite").path,
            peer: fixture.peer, boundary: connections.authorityBoundary,
            currentContext: { deviceId, bindings in
                try connections.authorizationContextHash(deviceId: deviceId, bindingIds: bindings)
            }, clock: { [unowned fixture] in fixture.clock }, dispatchEnabled: true)
        let screen = try fixture.screen("Shared")
        let material = WorkbenchDeploymentMaterial(screens: [screen],
            selectedDashboardId: screen.item.deployment.revision.dashboardId, bindingIds: [])
        let review = try domain.prepare(workspaceId: try XCTUnwrap(workspace.current()).descriptor.workspaceId,
            deviceId: "device-1", material: material, removedDashboardIds: [])
        let approval = try domain.approve(review, consent: .terminal())
        let admitted = try domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "shared", approved: true)
        let selectionState = try connections.authorityBoundary.withWorkspaceSelection {
            _ = try workspace.open(at: fixture.root.appendingPathComponent("visible").path)
            return try domain.dispatch(operationId: admitted.operationId, review: review)
        }
        XCTAssertEqual(selectionState.state, .cancelled)
        XCTAssertFalse(selectionState.sendAttempted)
        let refreshed = try domain.prepare(workspaceId: try XCTUnwrap(workspace.current()).descriptor.workspaceId,
            deviceId: "device-1", material: material, removedDashboardIds: [])
        let secondApproval = try domain.approve(refreshed, consent: .terminal())
        let second = try domain.admit(refreshed, approvalId: secondApproval.approvalId,
            idempotencyKey: "shared-forget", approved: true)
        let state = try connections.authorityBoundary.withDevice("device-1") {
            XCTAssertTrue(try devices.forget(deviceId: "device-1"))
            return try domain.dispatch(operationId: second.operationId, review: refreshed)
        }
        XCTAssertEqual(state.state, .cancelled)
        XCTAssertFalse(state.sendAttempted)
        XCTAssertEqual(fixture.peer.calls, 0)
    }

    func testTargetPreparationPublishesVerifiedImmutableHistoryBeforePlanning() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let documents = fixture.root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: M4Documents(url: documents),
            machineRootPath: fixture.root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let sourceStore = try DashboardPackageStore(root: fixture.root.appendingPathComponent("source-package"))
        let source = try sourceStore.putDashboard(dashboardId: nil, name: "Prepared",
            baseRevision: nil, target: fixtureTarget(), connections: [], files: [htmlFile("prepared")])
        let sourcePackage = WorkbenchPortablePackage(manifest: source.manifest, files: source.files)
        let preparedStore = WorkbenchPreparedPackages(workspace: workspace)
        let prepared = try preparedStore.prepare(source: sourcePackage, profile: fixture.peer.profile,
            orientation: .portrait)
        let afterPublication = try XCTUnwrap(workspace.current())
        XCTAssertEqual(afterPublication.catalog.generation, afterPublication.descriptor.generation)
        XCTAssertEqual(afterPublication.settings.generation, afterPublication.descriptor.generation)
        _ = try workspace.updateSettings(["theme": "dark"], profiles: [:],
            expectedGeneration: afterPublication.settings.generation)
        XCTAssertNotEqual(prepared.manifest.revision, source.manifest.revision)
        XCTAssertEqual(prepared.manifest.target.profileId, "device-1")
        let reopened = try preparedStore.get(dashboardId: prepared.manifest.dashboardId,
            revision: prepared.manifest.revision, sourceRevision: source.manifest.revision,
            targetProfileHash: WorkbenchDeploymentHash.profile(fixture.peer.profile))
        XCTAssertEqual(reopened.files, prepared.files)
        let frozen = try preparedStore.freeze(reopened, deviceId: "device-1", dataDescription: "Unknown")
        let review = try fixture.domain.prepareFromHistory(workspaceId: try XCTUnwrap(workspace.current()).descriptor.workspaceId,
            deviceId: "device-1", preparedStore: preparedStore,
            packages: [.init(dashboardId: prepared.manifest.dashboardId,
                             sourceRevision: source.manifest.revision,
                             revision: prepared.manifest.revision, dataDescription: "Unknown")],
            selectedDashboardId: frozen.item.deployment.revision.dashboardId,
            removedDashboardIds: [], bindingIds: [])
        XCTAssertEqual(review.plan.packages[0].sourceRevision, source.manifest.revision)
        XCTAssertEqual(review.plan.packages[0].revision, prepared.manifest.revision)
    }

    func testPreparedHistoryRejectsOversizeInventoryBeforeMissingMemberRead() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let documents = fixture.root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: M4Documents(url: documents),
            machineRootPath: fixture.root.appendingPathComponent("machine").path)
        let selected = try workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let sourceStore = try DashboardPackageStore(root: fixture.root.appendingPathComponent("source-package"))
        let source = try sourceStore.putDashboard(dashboardId: nil, name: "Prepared",
            baseRevision: nil, target: fixtureTarget(), connections: [], files: [htmlFile("prepared")])
        let preparedStore = WorkbenchPreparedPackages(workspace: workspace)
        let prepared = try preparedStore.prepare(source: .init(manifest: source.manifest, files: source.files),
            profile: fixture.peer.profile, orientation: .portrait)
        let expiredBudget = WorkspaceReadBudget(deadline: ProcessInfo.processInfo.systemUptime - 1,
                                                cancelled: { false })
        XCTAssertThrowsError(try preparedStore.get(dashboardId: prepared.manifest.dashboardId,
            revision: prepared.manifest.revision, sourceRevision: source.manifest.revision,
            targetProfileHash: WorkbenchDeploymentHash.profile(fixture.peer.profile),
            readBudget: expiredBudget))
        let objectId = try ToolchainCanonical.hash(domain: "prepared-package-object", value: [
            "dashboardId": prepared.manifest.dashboardId, "revision": prepared.manifest.revision])
        let manifestURL = URL(fileURLWithPath: selected.path).appendingPathComponent(
            "Workbench/History/Prepared/\(objectId)/manifest.json")
        var corrupt = prepared.manifest
        corrupt.files = Array(repeating: try XCTUnwrap(corrupt.files.first), count: PackageLimits.maxFiles + 1)
        try JSONEncoder().encode(corrupt).write(to: manifestURL, options: .atomic)
        XCTAssertThrowsError(try preparedStore.get(dashboardId: prepared.manifest.dashboardId,
            revision: prepared.manifest.revision, sourceRevision: source.manifest.revision,
            targetProfileHash: WorkbenchDeploymentHash.profile(fixture.peer.profile))) {
            XCTAssertTrue($0 is PackageValidationError, "inventory validation must precede member reads: \($0)")
        }
    }

    func testActualM3GrantRevocationBeforeDispatchPreventsSend() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let documents = fixture.root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: M4Documents(url: documents),
            machineRootPath: fixture.root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let native = FakeLANDevice(deviceId: "device-1", name: "Native")
        let owner = PairingIdentityFactory.make(role: .controller)
        let state = M4NativeSendState()
        let hub = LoopbackDiscovery(); hub.advertise(native.runtime.advertisement)
        let coordinator = DeviceCoordinator(directory: DeviceDirectory(url: fixture.root.appendingPathComponent("devices.json")),
            hub: hub, linkFactory: M4NativeDropFactory(device: native, controllerIdentity: owner, state: state))
        let secrets = M4Secrets()
        let connections = try WorkbenchConnectionDomain(machineAuthorityPath: fixture.root.appendingPathComponent("authority-m3").path,
            devices: coordinator, workspace: workspace, secrets: secrets)
        let devices = connections.deviceDomain()
        let pending = try devices.beginPairing(deviceId: "device-1")
        native.confirmLocally()
        _ = try devices.confirmPairing(pendingId: pending.pendingId, matchingCode: pending.matchingCode)
        let capability = WorkbenchTrustedLocalCapability.hostTerminalOrGUI()
        try connections.installSecret(authRef: "m4-secret", secret: Data("secret".utf8), capability: capability)
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "fixture",
            origin: "https://example.local", transport: .http, authRef: "m4-secret", lan: true,
            allowInsecureHTTP: false, operations: [.init(name: "read", kind: .http,
                method: .GET, path: "/api", idempotent: true, write: false)])
        let auth = ConnectionAuthBinding(authRef: "m4-secret", placement: .bearer)
        let intent = try connections.requestGenericIntent(deviceId: "device-1", dashboardId: "dashboard-1",
            revision: "revision-1", grant: grant, auth: auth)
        let applied = try XCTUnwrap(connections.resolveGenericIntent(intent.intentId, approve: true,
            capability: capability))
        let domain = try WorkbenchDeploymentDomain(ledgerPath: fixture.root.appendingPathComponent("authority-m4/deployments.sqlite").path,
            peer: fixture.peer, connections: connections,
            clock: { [unowned fixture] in fixture.clock }, dispatchEnabled: true)
        let screen = try fixture.screen("Grant")
        let material = WorkbenchDeploymentMaterial(screens: [screen],
            selectedDashboardId: screen.item.deployment.revision.dashboardId,
            bindingIds: [applied.summary.bindingId])
        let review = try domain.prepare(workspaceId: try XCTUnwrap(workspace.current()).descriptor.workspaceId,
            deviceId: "device-1", material: material, removedDashboardIds: [])
        let approval = try domain.approve(review, consent: .terminal())
        let admitted = try domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "revoke", approved: true)
        let result = try connections.authorityBoundary.withDevice("device-1") {
            _ = try connections.revoke(bindingId: applied.summary.bindingId, capability: capability)
            return try domain.dispatch(operationId: admitted.operationId, review: review)
        }
        XCTAssertEqual(result.state, .cancelled)
        XCTAssertFalse(result.sendAttempted)
        XCTAssertEqual(fixture.peer.calls, 0)
    }

    func testNativeFakeOwnerCompletesPreparedPlanThroughSharedDomain() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let documents = fixture.root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: M4Documents(url: documents),
            machineRootPath: fixture.root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let native = FakeLANDevice(deviceId: "device-1", name: "Native")
        let owner = PairingIdentityFactory.make(role: .controller)
        let hub = LoopbackDiscovery(); hub.advertise(native.runtime.advertisement)
        let coordinator = DeviceCoordinator(directory: DeviceDirectory(url: fixture.root.appendingPathComponent("devices.json")),
            hub: hub, linkFactory: FakeLANLinkFactory(device: native, controllerIdentity: owner))
        let connections = try WorkbenchConnectionDomain(machineAuthorityPath: fixture.root.appendingPathComponent("authority-m3").path,
            devices: coordinator, workspace: workspace)
        let devices = connections.deviceDomain()
        let pending = try devices.beginPairing(deviceId: "device-1")
        native.confirmLocally()
        _ = try devices.confirmPairing(pendingId: pending.pendingId, matchingCode: pending.matchingCode)
        let domain = try WorkbenchDeploymentDomain(ledgerPath: fixture.root.appendingPathComponent("authority-m4/deployments.sqlite").path,
            peer: WorkbenchNativeDeploymentPeer(devices: coordinator), connections: connections,
            clock: { [unowned fixture] in fixture.clock }, dispatchEnabled: true)
        let screen = try fixture.screen("Real adapter")
        let review = try domain.prepare(workspaceId: try XCTUnwrap(workspace.current()).descriptor.workspaceId,
            deviceId: "device-1", material: .init(screens: [screen],
                selectedDashboardId: screen.item.deployment.revision.dashboardId, bindingIds: []),
            removedDashboardIds: [])
        let approval = try domain.approve(review, consent: .terminal())
        let operation = try domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "native", approved: true)
        let result = try domain.dispatch(operationId: operation.operationId, review: review)
        XCTAssertEqual(result.state, .active)
        XCTAssertEqual(native.installedSet, review.result)
        XCTAssertEqual(native.selectedDashboardId, review.plan.selectedDashboardId)
    }

    func testNativeCapabilityHelloExpiryCannotCrossFirstDeployFrame() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let documents = fixture.root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: M4Documents(url: documents),
            machineRootPath: fixture.root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let native = FakeLANDevice(deviceId: "device-1", name: "Clocked native")
        let owner = PairingIdentityFactory.make(role: .controller)
        let state = M4NativeSendState(); state.dropReply = false
        let hub = LoopbackDiscovery(); hub.advertise(native.runtime.advertisement)
        let coordinator = DeviceCoordinator(directory: DeviceDirectory(
            url: fixture.root.appendingPathComponent("devices.json")), hub: hub,
            linkFactory: M4NativeDropFactory(device: native, controllerIdentity: owner, state: state))
        let connections = try WorkbenchConnectionDomain(machineAuthorityPath:
            fixture.root.appendingPathComponent("authority-m3").path,
            devices: coordinator, workspace: workspace)
        let devices = connections.deviceDomain()
        let pending = try devices.beginPairing(deviceId: "device-1")
        native.confirmLocally()
        _ = try devices.confirmPairing(pendingId: pending.pendingId, matchingCode: pending.matchingCode)
        let domain = try WorkbenchDeploymentDomain(ledgerPath:
            fixture.root.appendingPathComponent("authority-m4/deployments.sqlite").path,
            peer: WorkbenchNativeDeploymentPeer(devices: coordinator), connections: connections,
            clock: { [unowned fixture] in fixture.clock }, dispatchEnabled: true)
        let screen = try fixture.screen("Expires during capability query")
        let review = try domain.prepare(workspaceId: try XCTUnwrap(workspace.current()).descriptor.workspaceId,
            deviceId: "device-1", material: .init(screens: [screen],
                selectedDashboardId: screen.item.deployment.revision.dashboardId, bindingIds: []),
            removedDashboardIds: [])
        let approval = try domain.approve(review, consent: .terminal())
        let admitted = try domain.admit(review, approvalId: approval.approvalId,
            idempotencyKey: "native-capability-expiry", approved: true)
        let before = fixture.clock
        // markSending first observes the device; the next hello is the native
        // capability query, after which the final pre-frame guard must reject.
        state.helloCountdown = 2
        state.onCountedHello = {
            fixture.clock = .init(wallSeconds: before.wallSeconds + 3600,
                monotonicMilliseconds: before.monotonicMilliseconds + 3_600_000,
                bootId: before.bootId)
        }
        let result = try domain.dispatch(operationId: admitted.operationId, review: review)
        XCTAssertEqual(result.state, .failed)
        XCTAssertFalse(result.sendAttempted)
        XCTAssertEqual(state.calls, 0)
        XCTAssertTrue(native.installedSet?.isEmpty ?? true)
    }
}
#endif
