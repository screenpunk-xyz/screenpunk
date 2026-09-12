import Foundation
import ScreenpunkCore

public struct MCPToolRouter: Sendable {
    public let service: ControllerService
    public let catalog: MCPCatalogFile

    public init(service: ControllerService, catalog: MCPCatalogFile = MCPCatalog.load()) {
        self.service = service
        self.catalog = catalog
    }

    public func call(name: String, arguments: JSONValue) -> MCPToolResult {
        do {
            return try dispatch(name: name, arguments: arguments)
        } catch let error as ControllerError {
            return .failure(error)
        } catch let error as PackageValidationError {
            let codes = error.issues.map(\.rawValue).joined(separator: ",")
            if error.issues.contains(.unsupportedVersion) {
                return .failure(ControllerError(code: .unsupportedVersion, detail: codes))
            }
            return .failure(.validationFailed(detail: codes))
        } catch {
            return .failure(.validationFailed(detail: error.localizedDescription))
        }
    }

    private func dispatch(name: String, arguments: JSONValue) throws -> MCPToolResult {
        switch name {
        case "list_devices", "discover_services":
            return json(["devices": [], "services": [], "error": "not_paired"])
        case "get_device":
            throw ControllerError.notPaired()
        case "request_pairing":
            return json([
                "status": "pending",
                "selfApproved": false,
                "detail": "Pairing requires matching-code confirmation on both screens."
            ])
        case "propose_connection":
            return json([
                "status": "permission_required",
                "selfApproved": false,
                "error": "permission_required",
                "detail": "New or expanded connections require trusted native approval. MCP cannot self-approve."
            ])
        case "list_dashboards":
            let items = try service.listDashboards().map { summary -> [String: Any] in
                [
                    "dashboardId": summary.dashboardId,
                    "name": summary.name,
                    "draftRevision": summary.draftRevision,
                    "revisionCount": summary.revisionCount
                ]
            }
            return json(["dashboards": items])
        case "get_dashboard":
            let record = try service.getDashboard(
                dashboardId: try requireString(arguments, "dashboardId"),
                revision: arguments["revision"]?.string
            )
            return json(dashboardObject(record))
        case "update_dashboard":
            let record = try service.updateDashboard(arguments: arguments)
            return json(dashboardObject(record))
        case "validate_dashboard":
            let manifest = try service.validateDashboard(
                dashboardId: try requireString(arguments, "dashboardId"),
                revision: arguments["revision"]?.string
            )
            return json([
                "ok": true,
                "dashboardId": manifest.dashboardId,
                "revision": manifest.revision,
                "digest": manifest.digest ?? ""
            ])
        case "list_connections", "describe_connection", "inspect_connection":
            return json([
                "connections": [],
                "detail": "No approved connections in this controller. Secrets are never returned."
            ])
        case "preview_dashboard":
            return try preview(arguments: arguments, interaction: nil)
        case "interact_preview":
            let interaction = PreviewInteraction(
                kind: arguments["kind"]?.string ?? "tap",
                x: arguments["x"]?.int.map(Double.init),
                y: arguments["y"]?.int.map(Double.init),
                text: arguments["text"]?.string,
                dy: arguments["dy"]?.int.map(Double.init)
            )
            return try preview(arguments: arguments, interaction: interaction)
        case "deploy_dashboard", "rollback_dashboard":
            throw ControllerError.notPaired("deployment requires a paired device")
        case "list_versions":
            let id = try requireString(arguments, "dashboardId")
            let summaries = try service.listDashboards()
            guard let summary = summaries.first(where: { $0.dashboardId == id }) else {
                throw ControllerError.validationFailed(detail: "dashboard not found")
            }
            let revisions = try service.store.listRevisions(dashboardId: id).map { revision -> [String: Any] in
                let record = try service.getDashboard(dashboardId: id, revision: revision)
                return [
                    "revision": record.manifest.revision,
                    "digest": record.manifest.digest ?? ""
                ]
            }
            return json([
                "dashboardId": id,
                "draftRevision": summary.draftRevision,
                "revisions": revisions
            ])
        case "get_deployment":
            throw ControllerError.notPaired("no deployments")
        case "get_logs":
            return json([
                "lines": [
                    "controller ready",
                    service.helperStarted ? "preview helper available" : "preview helper not found"
                ],
                "bounded": true,
                "redacted": true
            ])
        case "get_help":
            let topic = HelpCatalog.topic(id: arguments["topic"]?.string ?? "onboarding")
            return .text("\(topic.title)\n\n\(topic.body)")
        default:
            throw ControllerError.validationFailed(detail: "unknown tool \(name)")
        }
    }

    private func preview(arguments: JSONValue, interaction: PreviewInteraction?) throws -> MCPToolResult {
        let live = arguments["live"]?.bool ?? catalog.previewLiveDefault
        let capture = try service.previewDashboard(
            dashboardId: try requireString(arguments, "dashboardId"),
            revision: arguments["revision"]?.string,
            live: live,
            interaction: interaction
        )
        guard PNGMagic.isPNG(capture.png) else {
            throw ControllerError.snapshotUnavailable(reason: "not_png")
        }
        let metadata: [String: String] = [
            "revision": capture.revision,
            "digest": capture.digest,
            "width": String(capture.width),
            "height": String(capture.height),
            "renderingPlatform": capture.renderingPlatform,
            "live": capture.live ? "true" : "false",
            "connectionHealth": capture.connectionHealth
        ]
        var text: [String: Any] = [
            "revision": capture.revision,
            "digest": capture.digest,
            "width": capture.width,
            "height": capture.height,
            "renderingPlatform": capture.renderingPlatform,
            "live": capture.live,
            "liveLabel": HelpCatalog.livePreviewLabel,
            "connectionHealth": capture.connectionHealth,
            "diagnostics": capture.diagnostics,
            "pathOnly": false
        ]
        if let note = capture.interactionNote {
            text["interaction"] = note
        }
        let textJSON = String(data: try JSONSerialization.data(withJSONObject: text, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        return MCPToolResult(
            content: [
                .image(dataBase64: capture.png.base64EncodedString(), mimeType: "image/png", metadata: metadata),
                .text(textJSON)
            ],
            isError: false
        )
    }

    private func dashboardObject(_ record: DashboardRevisionRecord) -> [String: Any] {
        [
            "dashboardId": record.manifest.dashboardId,
            "name": record.manifest.name,
            "revision": record.manifest.revision,
            "digest": record.manifest.digest ?? "",
            "entrypoint": record.manifest.entrypoint,
            "target": [
                "profileId": record.manifest.target.profileId,
                "width": record.manifest.target.width,
                "height": record.manifest.target.height,
                "orientation": record.manifest.target.orientation
            ],
            "files": record.manifest.files.map { ["path": $0.path, "bytes": $0.bytes, "sha256": $0.sha256] }
        ]
    }

    private func requireString(_ arguments: JSONValue, _ key: String) throws -> String {
        guard let value = arguments[key]?.string, value.isEmpty == false else {
            throw ControllerError.validationFailed(detail: "\(key) required")
        }
        return value
    }

    private func json(_ object: [String: Any]) -> MCPToolResult {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return .text(String(data: data, encoding: .utf8) ?? "{}")
    }
}
