import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController
@testable import ScreenpunkBrokerMCP

#if os(macOS)
private struct IntentDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}
private struct IntentLinkFactory: DeviceLinkFactory {
    var controllerIdentity: PairingIdentity {
        PairingIdentity(role: .controller, publicKey: Array(repeating: 7, count: 32))
    }
    func makeLink() throws -> DeviceLink { throw ControllerError.deviceOffline("isolated fixture") }
}

final class RealBrokerIntentTests: XCTestCase {
    func testOrdinaryMCPRequestMatchesRealBrokerScopeBeforeReferenceAssignment() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-mcp-intent-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let workspace = try WorkspaceStore(documents: IntentDocuments(root: root),
            machineRootPath: machine.path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let controllerHome = root.appendingPathComponent("legacy")
        let controller = try ControllerService.bootstrap(root: controllerHome,
            deviceDirectoryURL: machine.appendingPathComponent("devices.json"),
            rendererFactory: { nil })
        let native = WorkbenchNativeComposition(activate: { controller in
            controller.devices.attach(IntentLinkFactory())
        }, deactivate: { controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native,
            machineAuthorityPath: machine.appendingPathComponent("device-authority.json").path)
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment, credentialScope: .ordinary)
        try client.connect(); defer { client.close() }
        let owner = PairingIdentity(role: .controller, publicKey: Array(repeating: 7, count: 32))
        let device = PairedDevice(profile: DeviceProfile(deviceId: "fixture-device",
            name: "Fixture device"), owner: owner, reachable: false)
        try controller.devices.directory.upsert(PairedDeviceRecord(device: device,
            host: "127.0.0.1", port: 1234,
            devicePinHex: PeerPin.hex(Array(repeating: 8, count: 32)), pairedAt: Date()))
        _ = try client.addDevice(host: "127.0.0.1", port: 1234)
        let selected = try client.workspaceStatus()
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "weather",
            origin: "https://example.local", transport: .http, authRef: "", lan: true,
            allowInsecureHTTP: false, operations: [.init(name: "current", kind: .http,
                method: .GET, path: "/api/current", idempotent: true,
                write: false, maxAgeSeconds: 30)])
        let auth = ConnectionAuthBinding(authRef: "", placement: .none)
        let arguments: [String: Any] = ["deviceId": "fixture-device",
            "dashboardId": "dashboard-1", "revision": "revision-1",
            "expectedWorkspaceId": try XCTUnwrap(selected.workspaceId),
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration),
            "grant": try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)),
            "auth": try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth))]
        let adapter = try LegacyBrokerAdapter(client: client,
            expectedControllerHomePath: controllerHome.path)
        let response = adapter.call(name: "request_connection_intent", arguments: arguments)
        XCTAssertFalse(response.isError, response.text)
        let intent = try JSONDecoder().decode(WorkbenchConnectionIntentView.self,
            from: Data(response.text.utf8))
        XCTAssertEqual(intent.proposalScopeHash,
            try WorkbenchConnectionIntentAttestation.proposalScopeHash(
                deviceId: "fixture-device", dashboardId: "dashboard-1",
                revision: "revision-1", grant: grant, auth: auth))
        XCTAssertEqual(intent.state, "pending")
        XCTAssertNotEqual(intent.declarationHash,
            try WorkbenchConnectionIntentAttestation.declarationHash(
                dashboardId: "dashboard-1", revision: "revision-1",
                grant: grant, auth: auth), "broker-owned authRef must change the authority hash")
        let inspected = adapter.call(name: "get_connection_intent",
            arguments: ["intentId": intent.intentId])
        XCTAssertFalse(inspected.isError, inspected.text)
        let stored = try JSONDecoder().decode(WorkbenchConnectionIntentView.self,
            from: Data(inspected.text.utf8))
        XCTAssertEqual(stored.proposalScopeHash, intent.proposalScopeHash)
    }
}
#endif
