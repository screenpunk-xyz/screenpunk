import Foundation
import ScreenpunkCore

public final class ControllerService: @unchecked Sendable {
    public let store: DashboardPackageStore
    public let helper: HelperSupervisor
    public private(set) var renderer: PreviewRenderer?
    public private(set) var helperStarted = false
    private let lock = NSLock()

    public init(store: DashboardPackageStore, helper: HelperSupervisor = HelperSupervisor(), renderer: PreviewRenderer? = nil) {
        self.store = store
        self.helper = helper
        self.renderer = renderer
    }

    public static func bootstrap() throws -> ControllerService {
        let store = try DashboardPackageStore(root: DashboardPackageStore.defaultRoot())
        let helper = HelperSupervisor()
        let service = ControllerService(store: store, helper: helper, renderer: helper.makeRenderer())
        service.ensureHelper()
        return service
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
        let request = PreviewRequest(
            dashboardId: record.manifest.dashboardId,
            revision: record.manifest.revision,
            digest: record.manifest.digest ?? "",
            packageDirectory: record.packageDirectory,
            width: record.manifest.target.width,
            height: record.manifest.target.height,
            live: live,
            interaction: interaction
        )
        let capture = try renderer.render(request)
        guard PNGMagic.isPNG(capture.png) else {
            throw ControllerError.snapshotUnavailable(reason: "not_png")
        }
        return capture
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
        return items.compactMap { item in
            guard let alias = item["alias"]?.string else { return nil }
            return ManifestConnection(
                alias: alias,
                required: item["required"]?.bool ?? false,
                operations: nil
            )
        }
    }
}
