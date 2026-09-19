import Foundation
import ScreenpunkCore

public final class ControllerService: @unchecked Sendable {
    public let store: DashboardPackageStore
    public let helper: HelperSupervisor
    public let devices: DeviceCoordinator
    public private(set) var renderer: PreviewRenderer?
    public private(set) var helperStarted = false
    // Installed once by the native app/MCP bootstrap, before serving requests.
    public var homeAssistantConfiguration: (@Sendable (String, String, String) throws -> HomeAssistantProvisioning)?
    public var connectionDescription: (@Sendable () throws -> Data)?
    public var connectionInspection: (@Sendable (String?) throws -> Data)?
    private var reviewedRevisions: Set<String> = []
    private let lock = NSLock()

    public init(
        store: DashboardPackageStore,
        helper: HelperSupervisor = HelperSupervisor(),
        renderer: PreviewRenderer? = nil,
        devices: DeviceCoordinator? = nil
    ) {
        self.store = store
        self.helper = helper
        self.renderer = renderer
        self.devices = devices ?? DeviceCoordinator(
            directory: DeviceDirectory(url: DeviceDirectory.defaultURL(controllerHome: store.root))
        )
    }

    public static func bootstrap(
        linkFactory: DeviceLinkFactory? = nil,
        hub: LoopbackDiscovery = LoopbackDiscovery.shared
    ) throws -> ControllerService {
        let store = try DashboardPackageStore(root: DashboardPackageStore.defaultRoot())
        let helper = HelperSupervisor()
        let devices = DeviceCoordinator(
            directory: DeviceDirectory(url: DeviceDirectory.defaultURL(controllerHome: store.root)),
            hub: hub,
            linkFactory: linkFactory
        )
        let service = ControllerService(store: store, helper: helper, renderer: helper.makeRenderer(), devices: devices)
        service.ensureHelper()
        return service
    }

    /// Revisions rendered through `previewDashboard` in this controller process.
    /// `deployDashboard` only ships one of these: the user approves what they saw.
    public func hasReviewed(revision: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reviewedRevisions.contains(revision)
    }

    public func markReviewed(revision: String) {
        lock.lock()
        reviewedRevisions.insert(revision)
        lock.unlock()
    }

    @discardableResult
    public func ensureHelper() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if renderer == nil {
            renderer = helper.makeRenderer()
        }
        helperStarted = renderer != nil
        return helperStarted
    }

    public func replaceRenderer(_ renderer: PreviewRenderer?) {
        lock.lock()
        defer { lock.unlock() }
        self.renderer = renderer
        helperStarted = renderer != nil
    }

    public func listDashboards() throws -> [DashboardSummary] {
        try store.listDashboards()
    }

    public func getDashboard(dashboardId: String, revision: String?) throws -> DashboardRevisionRecord {
        try store.getRevision(dashboardId: dashboardId, revision: revision)
    }

    public func updateDashboard(arguments: JSONValue) throws -> DashboardRevisionRecord {
        let object = arguments.object ?? [:]
        let files = try (object["files"]?.array ?? []).map { item -> DashboardFileInput in
            guard let path = item["path"]?.string else {
                throw ControllerError.validationFailed(detail: "file path required")
            }
            return DashboardFileInput(path: path, text: item["text"]?.string, base64: item["base64"]?.string)
        }
        let target = try parseTarget(object["target"])
        let connections = try parseConnections(object["connections"])
        guard let name = object["name"]?.string, name.isEmpty == false else {
            throw ControllerError.validationFailed(detail: "name required")
        }
        return try store.putDashboard(
            dashboardId: object["dashboardId"]?.string,
            name: name,
            baseRevision: object["baseRevision"]?.string,
            target: target,
            connections: connections,
            files: files
        )
    }

    public func validateDashboard(dashboardId: String, revision: String?) throws -> DashboardManifest {
        let record = try store.getRevision(dashboardId: dashboardId, revision: revision)
        try PackageValidator.validate(record.manifest)
        return record.manifest
    }

    public func previewDashboard(
        dashboardId: String,
        revision: String?,
        live: Bool = true,
        interaction: PreviewInteraction? = nil
    ) throws -> PreviewCapture {
        _ = ensureHelper()
        let record = try store.getRevision(dashboardId: dashboardId, revision: revision)
        try PackageValidator.validate(record.manifest)
        guard let renderer else {
            throw ControllerError.snapshotUnavailable(reason: "helper_not_found")
        }
        let nativeConnection: HomeAssistantProvisioning?
        if live, record.manifest.connections.contains(where: { $0.alias == "home" }), let provider = homeAssistantConfiguration {
            nativeConnection = try provider(record.manifest.dashboardId, record.manifest.revision, UUID().uuidString).scoped(to: record.manifest)
        } else { nativeConnection = nil }
        let request = PreviewRequest(
            dashboardId: record.manifest.dashboardId,
            revision: record.manifest.revision,
            digest: record.manifest.digest ?? "",
            packageDirectory: record.packageDirectory,
            width: record.manifest.target.width,
            height: record.manifest.target.height,
            live: live,
            interaction: interaction,
            nativeHomeAssistant: nativeConnection,
            nativePublicReads: live ? try approvedPublicConnections(record.manifest) : nil
        )
        let capture = try renderer.render(request)
        guard PNGMagic.isPNG(capture.png) else {
            throw ControllerError.snapshotUnavailable(reason: "not_png")
        }
        markReviewed(revision: record.manifest.revision)
        return capture
    }

    // MARK: Deploy

    /// Ships an exact, previewed revision to a paired device over the LAN link.
    /// `approved` is the agent's statement that the user approved this revision in
    /// chat. It is agent-mediated approval, not a cryptographic guarantee.
    public func deployDashboard(
        deviceId: String,
        dashboardId: String,
        revision: String,
        deploymentId: String?,
        approved: Bool
    ) throws -> DeploymentRecord {
        guard approved else {
            throw ControllerError.permissionRequired(
                "deploy_dashboard needs approved=true after the user reviewed revision \(revision) in chat"
            )
        }
        let record = try store.getRevision(dashboardId: dashboardId, revision: revision)
        guard hasReviewed(revision: record.manifest.revision) else {
            throw ControllerError.permissionRequired(
                "revision \(record.manifest.revision) has not been previewed by this controller; call preview_dashboard so the user reviews it, then deploy that exact revision"
            )
        }
        return try ship(record: record, deviceId: deviceId, deploymentId: deploymentId)
    }

    /// Redeploys a revision that was active on the device before. Normal deploy path.
    public func rollbackDashboard(
        deviceId: String,
        dashboardId: String?,
        revision: String,
        deploymentId: String?,
        approved: Bool
    ) throws -> DeploymentRecord {
        guard approved else {
            throw ControllerError.permissionRequired(
                "rollback_dashboard needs approved=true after the user chose revision \(revision) in chat"
            )
        }
        let device = try devices.device(deviceId, probe: false)
        guard let previous = device.device.history.first(where: { $0.revision == revision }) else {
            throw ControllerError.validationFailed(
                detail: "revision \(revision) was never active on \(deviceId); use deploy_dashboard for new revisions"
            )
        }
        let resolvedDashboard = dashboardId ?? previous.dashboardId
        let record = try store.getRevision(dashboardId: resolvedDashboard, revision: revision)
        return try ship(record: record, deviceId: deviceId, deploymentId: deploymentId)
    }

    public func deploymentStatus(deploymentId: String) throws -> (device: PairedDeviceRecord, deployment: DeploymentRecord) {
        guard let found = devices.directory.deployment(deploymentId) else {
            throw ControllerError.validationFailed(detail: "unknown deploymentId \(deploymentId)")
        }
        return found
    }

    public func storedRevision(for manifest: DashboardManifest) throws -> StoredRevision {
        guard let orientation = DeviceOrientation(rawValue: manifest.target.orientation) else {
            throw ControllerError.validationFailed(detail: "orientation must be portrait or landscape")
        }
        return StoredRevision(
            revision: manifest.revision,
            dashboardId: manifest.dashboardId,
            name: manifest.name,
            digest: manifest.digest ?? "",
            orientation: orientation,
            width: manifest.target.width,
            height: manifest.target.height
        )
    }

    /// Package bytes plus `manifest.json`, each with its SHA-256 for device-side checks.
    public func transferBlobs(for record: DashboardRevisionRecord) throws -> [LANFileBlob] {
        var blobs = record.files.map { path, data in
            LANFileBlob(path: path, sha256: DeploymentDigest.sha256Hex(data), dataBase64: data.base64EncodedString())
        }
        let manifestURL = record.packageDirectory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path), record.files["manifest.json"] == nil {
            let data = try Data(contentsOf: manifestURL)
            blobs.append(
                LANFileBlob(path: "manifest.json", sha256: DeploymentDigest.sha256Hex(data), dataBase64: data.base64EncodedString())
            )
        }
        return blobs.sorted { $0.path < $1.path }
    }

    public func ship(record: DashboardRevisionRecord, deviceId: String, deploymentId: String?) throws -> DeploymentRecord {
        let id = deploymentId ?? UUID().uuidString.lowercased()
        let receipt: LANScreenSetReceipt
        do {
            receipt = try shipSet(records: [record], deviceId: deviceId,
                selectedDashboardId: record.manifest.dashboardId, deploymentId: id)
        } catch {
            if let failed = devices.directory.get(deviceId)?.device.deployments.first(where: { $0.deploymentId == id && $0.phase == .failed }) { return failed }
            throw error
        }
        return DeploymentRecord(deploymentId: id, revision: record.manifest.revision,
            dashboardId: record.manifest.dashboardId, deviceId: receipt.deviceId, phase: .active)
    }

    public func shipSet(records: [DashboardRevisionRecord], deviceId: String,
                        selectedDashboardId: String, deploymentId: String? = nil) throws -> LANScreenSetReceipt {
        guard (1...12).contains(records.count), Set(records.map { $0.manifest.dashboardId }).count == records.count,
              Set(records.map { $0.manifest.revision }).count == records.count,
              records.contains(where: { $0.manifest.dashboardId == selectedDashboardId }) else {
            throw ControllerError.validationFailed(detail: "Choose between one and twelve distinct screens.")
        }
        let id = deploymentId ?? UUID().uuidString.lowercased()
        // Prepare every package before obtaining credentials or sending a mutation.
        let packages = try records.enumerated().map { index, record -> LANDeployBody in
            try PackageValidator.validate(record.manifest)
            let revision = try storedRevision(for: record.manifest)
            return LANDeployBody(deployment: DeploymentRecord(deploymentId: records.count == 1 ? id : "\(id)-\(index)",
                revision: revision.revision, dashboardId: revision.dashboardId, deviceId: deviceId, phase: .queued),
                revision: revision, files: try transferBlobs(for: record))
        }
        try devices.requireScreenSetSupport(deviceId: deviceId, serviceCalls: records.contains { $0.manifest.connections.contains { $0.serviceCalls != nil } },
            cameras: records.contains { $0.manifest.connections.contains { $0.cameraEntities != nil } },
            publicReads: records.contains { $0.manifest.connections.contains { $0.publicHTTP != nil } })
        let items = try zip(records, packages).map { record, package -> LANScreenSetItem in
            let configuration: HomeAssistantProvisioning?
            if record.manifest.connections.contains(where: { $0.alias == "home" }) {
                guard let provider = homeAssistantConfiguration else {
                    throw ControllerError.permissionRequired("Set up Home Assistant in Connections before applying these screens. The device has not been changed.")
                }
                do {
                    configuration = try provider(record.manifest.dashboardId, record.manifest.revision, package.deployment.deploymentId).scoped(to: record.manifest)
                    try configuration?.validate()
                } catch {
                    throw ControllerError.permissionRequired("Check the saved Home Assistant connection before applying these screens. The device has not been changed.")
                }
            } else { configuration = nil }
            let reads = try approvedPublicConnections(record.manifest)
            let required = record.manifest.connections.filter { $0.publicHTTP != nil && $0.required }
            guard required.allSatisfy({ reads?.connections.contains($0) == true }) else {
                throw ControllerError.permissionRequired("Approve every required public connection before deployment.")
            }
            return LANScreenSetItem(name: record.manifest.name, deployment: package, homeAssistant: configuration, publicReads: reads)
        }
        return try devices.deployScreenSet(LANScreenSetDeployBody(schemaVersion: 1, deploymentId: id, deviceId: deviceId,
            screens: items, selectedDashboardId: selectedDashboardId))
    }

    public func defaultTarget() -> ManifestTarget {
        ManifestTarget(
            profileId: "fixture-phone",
            width: 390,
            height: 844,
            scale: 3,
            orientation: "portrait",
            safeArea: SafeAreaInsets(top: 47, right: 0, bottom: 34, left: 0)
        )
    }

    private func parseTarget(_ value: JSONValue?) throws -> ManifestTarget {
        guard let object = value?.object else { return defaultTarget() }
        return ManifestTarget(
            profileId: object["profileId"]?.string ?? "fixture-phone",
            width: object["width"]?.int ?? 390,
            height: object["height"]?.int ?? 844,
            scale: Double(object["scale"]?.int ?? 3),
            orientation: object["orientation"]?.string ?? "portrait",
            safeArea: SafeAreaInsets(top: 47, right: 0, bottom: 34, left: 0)
        )
    }

    private func parseConnections(_ value: JSONValue?) throws -> [ManifestConnection] {
        guard let items = value?.array else { return [] }
        return try items.map { item in
            guard let alias = item["alias"]?.string else { throw ControllerError.validationFailed(detail: "Connection alias is required.") }
            let operations: [ManifestOperation]? = try item["operations"]?.array?.map { operation in
                guard let name = operation["name"]?.string, let kind = operation["kind"]?.string else {
                    throw ControllerError.validationFailed(detail: "Connection operations need a name and kind.")
                }
                return ManifestOperation(name: name, kind: kind, maxAgeSeconds: operation["maxAgeSeconds"]?.int)
            }
            let grants: [HomeAssistantServiceGrant]?
            if let declarations = item["serviceCalls"] {
                do {
                    grants = try JSONDecoder().decode([HomeAssistantServiceGrant].self, from: declarations.data())
                    guard alias == "home" else { throw ConnectionFailure.validationFailed }
                    try HomeAssistantServiceGrant.validate(grants ?? [])
                } catch { throw ControllerError.validationFailed(detail: "Invalid Home Assistant serviceCalls declarations.") }
            } else { grants = nil }
            var connection = ManifestConnection(alias: alias, required: item["required"]?.bool ?? false, operations: operations, serviceCalls: grants)
            if let declarations = item["cameraEntities"] {
                do {
                    let entities = try JSONDecoder().decode([String].self, from: declarations.data())
                    guard alias == "home" else { throw ConnectionFailure.validationFailed }
                    try CameraSource.validateEntities(entities)
                    connection.cameraEntities = entities
                } catch { throw ControllerError.validationFailed(detail: "Invalid Home Assistant cameraEntities declarations.") }
            }
            if let declaration = item["publicHTTP"] {
                connection.publicHTTP = try JSONDecoder().decode(PublicReadDeclaration.self, from: declaration.data())
                try connection.publicHTTP?.validate(alias: alias)
            }
            return connection
        }
    }
}
