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
        case "create_screen_project":
            return json(try service.authoring.create(starter: arguments["starter"]?.string ?? "earthquakes", catalogVersion: arguments["catalogVersion"]?.string).object?.mapValues { $0.jsonObject() } ?? [:])
        case "get_screen_project":
            return json(try service.authoring.get(id: arguments["projectId"]?.string ?? "", paths: arguments["paths"]?.array?.compactMap { $0.string } ?? []).object?.mapValues { $0.jsonObject() } ?? [:])
        case "update_screen_project":
            return json(try service.authoring.update(id: arguments["projectId"]?.string ?? "", expected: arguments["sourceVersion"]?.string ?? "", edits: arguments["files"]?.array ?? []).object?.mapValues { $0.jsonObject() } ?? [:])
        case "build_screen_project":
            return json(try service.authoring.build(id: arguments["projectId"]?.string ?? "", expected: arguments["sourceVersion"]?.string ?? "", baseRevision: arguments["baseRevision"]?.string, service: service).object?.mapValues { $0.jsonObject() } ?? [:])
        case "list_devices":
            let devices = service.devices.listDevices().map(deviceObject)
            let pending = service.devices.pendingPairings().map { entry -> [String: Any] in
                [
                    "deviceId": entry.deviceId,
                    "name": entry.deviceName,
                    "host": entry.host,
                    "port": entry.port,
                    "status": "pending",
                    "expiresAt": iso(entry.expiresAt)
                ]
            }
            var object: [String: Any] = [
                "devices": devices,
                "pendingPairings": pending,
                "transportAvailable": service.devices.transportAvailable
            ]
            if devices.isEmpty {
                object["detail"] = "No paired devices. Call discover_services, then request_pairing."
            }
            return json(object)
        case "discover_services":
            if let host = arguments["host"]?.string, host.isEmpty == false {
                guard let port = arguments["port"]?.int, port > 0, port <= 65535 else {
                    throw ControllerError.validationFailed(detail: "port must be 1-65535 when host is given")
                }
                _ = service.devices.addManual(host: host, port: port)
            }
            let paired = Set(service.devices.listDevices().map(\.id))
            let services = service.devices.discover().map { ad -> [String: Any] in
                [
                    "deviceId": ad.deviceId,
                    "host": ad.host,
                    "port": ad.port,
                    "source": ad.source.rawValue,
                    "protocolMajor": ad.protocolMajor,
                    "paired": paired.contains(ad.deviceId)
                ]
            }
            return json([
                "services": services,
                "serviceType": DiscoveryService.type,
                "detail": "Known advertised or manually entered services only. Screenpunk never scans the network. Advertisements are untrusted until pairing."
            ])
        case "get_device":
            let record = try service.devices.device(
                try requireString(arguments, "deviceId"),
                probe: arguments["probe"]?.bool ?? true
            )
            return json(deviceObject(record))
        case "request_pairing":
            let result = try service.devices.requestPairing(
                deviceId: arguments["deviceId"]?.string,
                host: arguments["host"]?.string,
                port: arguments["port"]?.int
            )
            return json([
                "status": "pending",
                "selfApproved": false,
                "deviceId": result.deviceId,
                "name": result.deviceName,
                "host": result.host,
                "port": result.port,
                "code": result.code,
                "devicePinHex": result.devicePinHex,
                "expiresAt": iso(result.expiresAt),
                "rePairing": result.rePairing,
                "detail": "Show this code to the user. The device shows its own code. Only if both match, the user taps Confirm on the device; then call confirm_pairing. Codes expire after \(Int(PairingLimits.expirySeconds)) seconds."
            ])
        case "confirm_pairing":
            let record = try service.devices.confirmPairing(deviceId: try requireString(arguments, "deviceId"))
            var object = deviceObject(record)
            object["status"] = "paired"
            object["selfApproved"] = false
            object["detail"] = "The device confirmed natively and is now owned by this Mac."
            return json(object)
        case "forget_device":
            let id = try requireString(arguments, "deviceId")
            let removed = try service.devices.forget(deviceId: id)
            return json([
                "deviceId": id,
                "forgotten": removed,
                "deviceErased": false,
                "detail": WorkbenchCopy.forgetUnreachable
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
        case "approve_public_connections":
            let aliases: [String]?
            if let value = arguments["aliases"] {
                guard let items = value.array, !items.isEmpty, items.allSatisfy({ $0.string != nil }) else {
                    throw ControllerError.validationFailed(detail: "aliases must be a nonempty array of strings")
                }
                aliases = items.compactMap(\.string)
            } else { aliases = nil }
            let result = try service.approvePublicConnections(dashboardId: requireString(arguments, "dashboardId"),
                revision: requireString(arguments, "revision"), approved: arguments["approved"]?.bool == true, aliases: aliases)
            return .text(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        case "inspect_public_connections":
            return .text(String(decoding: try service.inspectPublicConnections(dashboardId: requireString(arguments, "dashboardId"),
                revision: arguments["revision"]?.string), as: UTF8.self))
        case "list_connections", "describe_connection":
            if let alias = arguments["alias"]?.string, alias != "home" {
                throw ControllerError.validationFailed(detail: "Unknown connection alias. Call list_connections.")
            }
            if let describe = service.connectionDescription {
                return .text(String(decoding: try describe(), as: UTF8.self))
            }
            return json(["connections": [], "detail": "Set up Home Assistant in the Mac app’s Connections page. Secrets are never returned."])
        case "inspect_connection":
            guard arguments["alias"]?.string == "home", let inspect = service.connectionInspection else {
                throw ControllerError.validationFailed(detail: "Use alias home for the configured Home Assistant connection.")
            }
            do { return .text(String(decoding: try inspect(arguments["query"]?.string), as: UTF8.self)) }
            catch { throw ControllerError.validationFailed(detail: "Home Assistant could not be read. Check its address, token permissions, and connection in the Mac app.") }
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
        case "deploy_dashboard":
            let outcome = try service.deployDashboard(
                deviceId: try requireString(arguments, "deviceId"),
                dashboardId: try requireString(arguments, "dashboardId"),
                revision: try requireString(arguments, "revision"),
                deploymentId: arguments["deploymentId"]?.string,
                approved: arguments["approved"]?.bool ?? false
            )
            return deploymentResult(outcome)
        case "rollback_dashboard":
            let outcome = try service.rollbackDashboard(
                deviceId: try requireString(arguments, "deviceId"),
                dashboardId: arguments["dashboardId"]?.string,
                revision: try requireString(arguments, "revision"),
                deploymentId: arguments["deploymentId"]?.string,
                approved: arguments["approved"]?.bool ?? false
            )
            return deploymentResult(outcome)
        case "list_versions":
            let id = try requireString(arguments, "dashboardId")
            let summaries = try service.listDashboards()
            guard let summary = summaries.first(where: { $0.dashboardId == id }) else {
                throw ControllerError.validationFailed(detail: "dashboard not found")
            }
            let devices = service.devices.listDevices()
            let revisions = try service.store.listRevisions(dashboardId: id).map { revision -> [String: Any] in
                let record = try service.getDashboard(dashboardId: id, revision: revision)
                return [
                    "revision": record.manifest.revision,
                    "digest": record.manifest.digest ?? "",
                    "reviewed": service.hasReviewed(revision: record.manifest.revision),
                    "activeOn": devices.filter { $0.device.activeRevision == record.manifest.revision }.map(\.id)
                ]
            }
            return json([
                "dashboardId": id,
                "draftRevision": summary.draftRevision,
                "revisions": revisions
            ])
        case "get_deployment":
            let found = try service.deploymentStatus(deploymentId: try requireString(arguments, "deploymentId"))
            var object = deploymentObject(found.deployment)
            object["activeRevision"] = found.device.device.activeRevision ?? NSNull()
            object["queuedSilently"] = false
            return json(object)
        case "get_logs":
            let devices = service.devices.listDevices()
            return json([
                "lines": [
                    "controller ready",
                    service.helperStarted ? "preview helper available" : "preview helper not found",
                    service.devices.transportAvailable ? "LAN transport TLS 1.3 available" : "LAN transport unavailable",
                    "paired devices: \(devices.count)",
                    "pending pairings: \(service.devices.pendingPairings().count)",
                    "deployments recorded: \(devices.reduce(0) { $0 + $1.device.deployments.count })"
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

    private func deviceObject(_ record: PairedDeviceRecord) -> [String: Any] {
        var object: [String: Any] = [
            "deviceId": record.id,
            "name": record.device.profile.name,
            "host": record.host,
            "port": record.port,
            "reachable": record.device.reachable,
            "status": "paired",
            "owner": "this-mac",
            "devicePinHex": record.devicePinHex,
            "viewport": [
                "width": record.device.profile.width,
                "height": record.device.profile.height,
                "orientation": record.device.profile.orientation.rawValue
            ],
            "activeRevision": record.device.activeRevision ?? NSNull(),
            "history": record.device.history.map { revision in
                [
                    "revision": revision.revision,
                    "dashboardId": revision.dashboardId,
                    "name": revision.name,
                    "digest": revision.digest
                ]
            },
            "deployments": record.device.deployments.map(deploymentObject),
            "pairedAt": iso(record.pairedAt),
            "capabilities": ["tls": "1.3", "transfer": "lan", "runtimeProxy": false]
        ]
        if let seen = record.lastSeenAt {
            object["lastSeenAt"] = iso(seen)
        }
        return object
    }

    private func deploymentObject(_ record: DeploymentRecord) -> [String: Any] {
        var object: [String: Any] = [
            "deploymentId": record.deploymentId,
            "deviceId": record.deviceId,
            "dashboardId": record.dashboardId,
            "revision": record.revision,
            "phase": record.phase.rawValue
        ]
        if let error = record.error {
            object["error"] = error
        }
        return object
    }

    /// A failed transfer is reported as an error result that still carries the
    /// deployment record. The device keeps its current dashboard.
    private func deploymentResult(_ outcome: DeploymentRecord) -> MCPToolResult {
        var object = deploymentObject(outcome)
        let active = service.devices.listDevices().first { $0.id == outcome.deviceId }?.device.activeRevision
        object["activeRevision"] = active ?? NSNull()
        object["currentDashboardKept"] = outcome.phase != .active
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        guard outcome.phase == .failed else {
            return .text(text)
        }
        let code: ControllerErrorCode
        switch outcome.error ?? "" {
        case TransferFailure.notPaired.rawValue:
            code = .notPaired
        case TransferFailure.interrupted.rawValue, TransferFailure.deviceOffline.rawValue:
            code = .deviceOffline
        default:
            code = .validationFailed
        }
        return MCPToolResult(content: [.text(text)], isError: true, errorCode: code.rawValue)
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func dashboardObject(_ record: DashboardRevisionRecord) -> [String: Any] {
        [
            "dashboardId": record.manifest.dashboardId,
            "name": record.manifest.name,
            "revision": record.manifest.revision,
            "digest": record.manifest.digest ?? "",
            "entrypoint": record.manifest.entrypoint,
            "connections": record.manifest.connections.map { connection -> [String: Any] in
                ["alias": connection.alias, "required": connection.required,
                 "operations": (connection.operations ?? []).map { ["name": $0.name, "kind": $0.kind] }]
            },
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
