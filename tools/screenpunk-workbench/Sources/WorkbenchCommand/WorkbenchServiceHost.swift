import Foundation
import ScreenpunkController
import ScreenpunkCore
import ScreenpunkApple

/// Owns one foreground broker, including its home lock and lazy native adapter.
/// Tests supply a private process inventory and inert native adapter; executable
/// entry points always use the live owner check and native LAN adapter.
final class WorkbenchServiceHost {
    private let ownerLock: WorkbenchServiceOwnerLock
    private let server: WorkbenchBrokerServer
    private var cloudSyncTask: Task<Void, Never>?

    init(broker: WorkbenchBrokerEnvironment, home: URL, documents: CLIWorkspaceDocuments,
         ownerCheck: @escaping () throws -> Void = { try WorkbenchLegacyOwnerGate.assertNoKnownWriter() },
         nativeFactory: (ControllerService) -> WorkbenchNativeComposition? = { controller in
             let lan = WorkbenchNativeLAN()
             return WorkbenchNativeComposition(activateOnStart: false,
                 activate: { try lan.activate($0) }, deactivate: { lan.deactivate(controller) })
         }, guiVerifier: WorkbenchGUIConsumerVerifier? = nil,
         installedReleaseTrust: WorkbenchInstalledReleaseTrust? = nil,
         onShutdown: @escaping () -> Void = {}) throws {
        try ownerCheck()
        // Competing legacy GUI and broker startups arbitrate on the same
        // controller-home inode before either can load identity or native state.
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lock = try WorkbenchServiceOwnerLock(home: home)
        try ownerCheck()
        let controller = try ControllerService.bootstrap(root: home,
            deviceDirectoryURL: DeviceDirectory.defaultURL(controllerHome: home),
            rendererFactory: { nil })
        let machineRoot = broker.runtimeDirectory.appendingPathComponent("machine").path
        try FileManager.default.createDirectory(atPath: machineRoot,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: documents, machineRootPath: machineRoot)
        let secrets = WorkbenchKeychainSecrets(ownerPin: {
            controller.devices.controllerIdentity.map { PeerPin.hex($0.publicKey) }
        })
        let homeAssistantAttempts = try WorkbenchHomeAssistantAttemptFileStore(
            path: URL(fileURLWithPath: machineRoot)
                .appendingPathComponent("home-assistant").path)
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: nativeFactory(controller),
            machineAuthorityPath: URL(fileURLWithPath: machineRoot).appendingPathComponent("device-authority.json").path,
            secrets: secrets, mutationGate: ownerCheck,
            homeAssistantAttempts: homeAssistantAttempts,
            homeAssistantTransport: HomeAssistantHTTPTransport(),
            homeAssistantResolver: LiteralOrResolvedDestinationResolver(),
            homeAssistantProvisioner: { deviceId, configuration in
                try controller.devices.provisionHomeAssistant(deviceId: deviceId,
                    configuration: configuration)
            }, installedReleaseTrust: installedReleaseTrust)
        let server = WorkbenchBrokerServer(environment: broker, domain: domain,
            onShutdown: onShutdown, guiVerifier: guiVerifier)
        _ = try server.start()
        self.ownerLock = lock
        self.server = server
        cloudSyncTask = Task.detached { [broker, home, documents] in
            var clients: [String: WorkbenchBrokerClient] = [:]
            var facades: [String: ControllerCloudWorkbench] = [:]
            defer { clients.values.forEach { $0.close() } }
            while !Task.isCancelled {
                do {
                    let environment = try WorkbenchCloudCLI.deploymentEnvironment(documents.environment)
                    if let origin = environment["SCREENPUNK_CLOUD_BASE_URL"], let base = URL(string: origin) {
                        for clientID in ["screenpunk-cli", "screenpunk-mac"] {
                            guard try ControllerCloudKeychain(server: base, clientID: clientID).load() != nil else { continue }
                            if facades[clientID] == nil {
                                let config = try await ControllerCloudConfiguration.deployment(clientID: clientID, environment: environment, machineRoot: broker.runtimeDirectory.appendingPathComponent("machine"))
                                let client = WorkbenchBrokerClient(environment: broker)
                                try client.connect()
                                guard try client.hello().controllerHomePath == home.path else { client.close(); throw ControllerCloudError.invalidConfiguration }
                                clients[clientID] = client
                                facades[clientID] = try ControllerCloudWorkbench(configuration: config, client: client,
                                    machineRoot: broker.runtimeDirectory.appendingPathComponent("machine"))
                            }
                            if let client = clients[clientID] { _ = try client.reconnectIfPeerClosed() }
                            try await facades[clientID]?.automaticSync()
                        }
                    }
                } catch is CancellationError { break }
                catch {
                    // Bounded status evidence, with no tokens or source bytes in service logs.
                    let value = ["state": "paused", "reason": String(describing: error), "checkedAt": ISO8601DateFormatter().string(from: Date())]
                    if let bytes = try? JSONSerialization.data(withJSONObject: value) {
                        try? bytes.write(to: broker.runtimeDirectory.appendingPathComponent("machine/cloud-sync-status.json"), options: .atomic)
                    }
                }
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { break }
            }
        }
    }

    func stop() { cloudSyncTask?.cancel(); cloudSyncTask = nil; server.stop() }
    deinit { cloudSyncTask?.cancel() }
}
