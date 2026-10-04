import XCTest
import Foundation
import ScreenpunkCore
import SQLite3
@testable import ScreenpunkController

#if os(macOS)
private final class LookupPeer: WorkbenchDeploymentPeer {
    var profile = DeviceProfile(deviceId: "device-1", name: "Living Room")
    var screens: [LANScreenSetEntry] = []
    var selected: String?
    var calls = 0
    var acceptThenDrop = false
    var delayActivation = false
    var observeHook: (() -> Void)?
    var sendPreparationHook: (() -> Void)?
    func observe(deviceId: String) throws -> WorkbenchDeploymentObservation {
        observeHook?()
        return WorkbenchDeploymentObservation(deviceId: deviceId, name: profile.name, profile: profile,
            screens: screens, selectedDashboardId: selected, observedAt: Date(timeIntervalSince1970: 2_000_000_000))
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

private struct LookupFactory: DeviceLinkFactory {
    let device: FakeLANDevice
    let controllerIdentity: PairingIdentity
    func makeLink() throws -> DeviceLink {
        FakeLANLink(device: device, controllerPin: controllerIdentity.publicKey)
    }
}
private struct LookupDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchDeploymentLookupTests: XCTestCase {
    func testWireLookupDistinguishesUnadmittedPlanFromExistingOperation() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-lookup-" + String(UUID().uuidString.prefix(12)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: LookupDocuments(url: root.appendingPathComponent("Documents")),
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
        let peer = LookupPeer()
        let owner = PairingIdentityFactory.make(role: .controller)
        let paired = PairedDevice(profile: peer.profile, owner: owner, reachable: false)
        try controller.devices.directory.upsert(PairedDeviceRecord(device: paired,
            host: "192.0.2.10", port: 7843,
            devicePinHex: PeerPin.hex(Array(repeating: 8, count: 32)), pairedAt: Date()))
        let linkDevice = FakeLANDevice(deviceId: "device-1", name: "Fixture iPad")
        let factory = LookupFactory(device: linkDevice, controllerIdentity: owner)
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
        let lookup = try client.performDeployment(method: .lookup,
            params: fields(["planId": review.plan.planId]))
        XCTAssertNil(lookup.operation)
        let encoded = try WorkbenchWireJSON.object(WorkbenchSocket.encode(lookup))
        let absence = try XCTUnwrap(encoded["absence"] as? [String: Any])
        XCTAssertEqual(absence["planId"] as? String, review.plan.planId)
        XCTAssertEqual(absence["state"] as? String, "not-admitted")
        XCTAssertEqual(try client.health().status, "ready")
        XCTAssertEqual(peer.calls, 0)
        let request = try WorkbenchDeploymentRequest.parse(.lookup,
            fields(["planId": review.plan.planId]))
        var wrong = encoded
        wrong["absence"] = ["planId": "different-plan", "state": "not-admitted"]
        let wrongReply = try JSONDecoder().decode(WorkbenchDeploymentActionResult.self,
            from: JSONSerialization.data(withJSONObject: wrong))
        XCTAssertThrowsError(try wrongReply.validate(for: request))
        wrong["absence"] = ["planId": review.plan.planId, "state": "unknown"]
        let unknownReply = try JSONDecoder().decode(WorkbenchDeploymentActionResult.self,
            from: JSONSerialization.data(withJSONObject: wrong))
        XCTAssertThrowsError(try unknownReply.validate(for: request))
        let missing = WorkbenchBrokerClient(environment: environment)
        try missing.connect(); defer { missing.close() }
        XCTAssertThrowsError(try missing.performDeployment(method: .lookup,
            params: fields(["planId": "unknown-plan"])))
        XCTAssertEqual(peer.calls, 0)
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
        let existing = try client.performDeployment(method: .lookup,
            params: fields(["planId": review.plan.planId]))
        XCTAssertEqual(existing.operation?.operationId, operation.operationId)
        XCTAssertNil(try WorkbenchWireJSON.object(WorkbenchSocket.encode(existing))["absence"])
        XCTAssertEqual(try client.performDeployment(method: .apply,
            params: apply).operation?.operationId, operation.operationId)
        XCTAssertEqual(peer.calls, 1)
        // A corrupt row must remain an error, never authoritative absence.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("machine/deployment-ledger.sqlite").path,
            &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE operations SET record=x'7b7d'", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try client.performDeployment(method: .lookup,
            params: fields(["planId": review.plan.planId])))
        XCTAssertEqual(peer.calls, 1)
    }
}
#endif
