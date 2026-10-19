import XCTest
import Foundation
import Darwin
import ScreenpunkCore
import ScreenpunkController
@testable import WorkbenchCommand

private struct HACLITransportFactory: DeviceLinkFactory {
    let controllerIdentity: PairingIdentity
    func makeLink() throws -> DeviceLink { throw ConnectionFailure.deviceOffline }
}
private final class HACLISecrets: WorkbenchSecretProvider {
    var values: [String: Data] = [:]
    func install(_ secret: Data, for authRef: String) throws { values[authRef] = secret }
    func load(authRef: String) throws -> Data {
        guard let value = values[authRef] else { throw ConnectionFailure.permissionRequired }
        return value
    }
    func remove(authRef: String) throws { values[authRef] = nil }
}
private final class HACLIHTTP: HTTPTransport, @unchecked Sendable {
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        .init(status: 200, body: Data("{\"message\":\"API running.\"}".utf8))
    }
}
private struct HACLIResolver: DestinationResolver {
    func addresses(for host: String) throws -> [String] { ["192.168.1.20"] }
}
private final class HACLIProvisioning: @unchecked Sendable {
    var sends = 0
    var token: String?
    func send(_ device: String, _ configuration: HomeAssistantProvisioning) throws
        -> HomeAssistantProvisioningReceipt {
        sends += 1; token = configuration.token
        return .init(deviceId: device, dashboardId: configuration.dashboardId,
            revision: configuration.revision, connectionId: configuration.connectionId,
            provisioningId: configuration.provisioningId)
    }
}

final class WorkbenchHomeAssistantCLITests: XCTestCase {
    func testControllingTerminalReviewAndPrivateTokenInstall() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-ha-cli-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        let runtime = root.appendingPathComponent("runtime")
        for directory in [documents, runtime] {
            try FileManager.default.createDirectory(at: directory,
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let home = root.appendingPathComponent("home")
        let environment = ["SCREENPUNK_DOCUMENTS_DIRECTORY": documents.path]
        let workspace = try WorkspaceStore(documents: CLIWorkspaceDocuments(environment: environment),
            machineRootPath: runtime.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html>Home</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "ha-dashboard", name: "Home", revision: "ha-revision",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"),
            connections: [.init(alias: "home", required: true)],
            files: [.init(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let owner = PairingIdentityFactory.make(role: .controller)
        let controller = try ControllerService.bootstrap(root: home,
            deviceDirectoryURL: runtime.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        let peerPin = String(repeating: "a", count: 64)
        try controller.devices.directory.upsert(.init(
            device: PairedDevice(profile: .init(deviceId: "ha-device", name: "Fixture iPad"),
                owner: owner, reachable: false),
            host: "192.0.2.50", port: 7843, devicePinHex: peerPin, pairedAt: Date()))
        let secrets = HACLISecrets()
        let provisioning = HACLIProvisioning()
        let attempts = try WorkbenchHomeAssistantAttemptFileStore(path:
            runtime.appendingPathComponent("machine/home-assistant").path)
        let native = WorkbenchNativeComposition(activate: {
            $0.devices.attach(HACLITransportFactory(controllerIdentity: owner))
        }, deactivate: { controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native, machineAuthorityPath: runtime.appendingPathComponent("machine/authority").path,
            secrets: secrets, mutationGate: {}, homeAssistantAttempts: attempts,
            homeAssistantTransport: HACLIHTTP(), homeAssistantResolver: HACLIResolver(),
            homeAssistantProvisioner: { try provisioning.send($0, $1) })
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime,
            limits: .init(timeout: 1))
        let server = WorkbenchBrokerServer(environment: broker, domain: domain)
        try server.start(); defer { server.stop() }
        let command = ["connection", "home-assistant", "setup", "ha-device",
            "ha-dashboard", "ha-revision", "https://home.example.test:8123",
            "--home", home.path, "--runtime-directory", runtime.path, "--json"]
        XCTAssertNotEqual(WorkbenchCommand.run(arguments: command + ["--no-input"],
            environment: environment), 0)
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertEqual(provisioning.sends, 0)

        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let finished = DispatchSemaphore(value: 0)
        var status: Int32 = -1
        DispatchQueue.global().async {
            status = WorkbenchCommand.run(arguments: command, environment: environment,
                localReviewTTY: { Darwin.dup(slave) },
                localSecretInput: { Data("private-token".utf8) })
            finished.signal()
        }
        var rendered = ""
        var answeredPages = 0
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !rendered.contains("Type APPROVE to validate and install") {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(master, &chunk, chunk.count)
            if count > 0 { rendered += String(decoding: chunk.prefix(count), as: UTF8.self) }
            let prompts = rendered.components(separatedBy: "Press Enter to view the remaining scope").count - 1
            while answeredPages < prompts {
                let newline = Data("\n".utf8)
                _ = newline.withUnsafeBytes { Darwin.write(master, $0.baseAddress, newline.count) }
                answeredPages += 1
            }
            usleep(10_000)
        }
        XCTAssertTrue(rendered.contains("Type APPROVE to validate and install"), rendered)
        XCTAssertTrue(rendered.contains("Exact home declaration"), rendered)
        XCTAssertFalse(rendered.contains("private-token"))
        let approval = Data("APPROVE\n".utf8)
        XCTAssertEqual(approval.withUnsafeBytes {
            Darwin.write(master, $0.baseAddress, approval.count)
        }, approval.count)
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(provisioning.sends, 1)
        XCTAssertEqual(provisioning.token, "private-token")
        XCTAssertEqual(secrets.values.count, 1)
    }
}
