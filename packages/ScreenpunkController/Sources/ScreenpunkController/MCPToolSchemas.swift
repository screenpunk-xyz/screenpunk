import Foundation

/// Input schemas shared by the official-SDK server and the JSON-RPC fallback.
public enum MCPToolSchemas {
    public static func inputSchema(for name: String) -> JSONValue {
        switch name {
        case "approve_public_connections":
            return object(required: ["dashboardId", "revision", "approved"], properties: [
                "dashboardId": string(), "revision": string("Exact immutable revision whose declarations the owner reviewed."),
                "aliases": .object(["type": .string("array"), "items": string(), "description": .string("Optional aliases to approve; omit to approve every public declaration. JSON and raster can use separate aliases.")]),
                "approved": .object(["type": .string("boolean"), "description": .string("True only after owner approval of these public HTTPS reads.")])])
        case "inspect_public_connections":
            return object(required: ["dashboardId"], properties: ["dashboardId": string(), "revision": string()])
        case "update_dashboard":
            return object(
                required: ["name", "files"],
                properties: [
                    "dashboardId": string(),
                    "name": string(),
                    "baseRevision": string(),
                    "files": .object(["type": .string("array")]),
                    "target": .object(["type": .string("object")]),
                    "connections": .object(["type": .string("array")]),
                    "pages": .object(["type": .string("array"), "description": .string("Approved pages inside this dashboard: objects with id, name and packaged HTML path. Omit to preserve existing pages; [] resets to the entrypoint. See docs/event-navigation.md.")]),
                    "defaultPageId": string("Author starting page ID; device settings may select another approved page."),
                    "eventRules": .object(["type": .string("array"), "description": .string("Author-declared approved connection sources, conditions, page targets, defaults and permitted overrides. Omit to preserve; [] removes all rules. Never grants connection permissions.")])
                ]
            )
        case "preview_dashboard", "interact_preview":
            return object(
                required: ["dashboardId"],
                properties: [
                    "dashboardId": string(),
                    "revision": string(),
                    "live": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                        "description": .string(HelpCatalog.livePreviewLabel)
                    ]),
                    "kind": string(),
                    "x": number(),
                    "y": number(),
                    "text": string(),
                    "dy": number()
                ]
            )
        case "describe_connection", "inspect_connection":
            return object(required: ["alias"], properties: [
                "alias": string("Use home for Home Assistant."),
                "query": string("Optional entity ID or name filter (up to 200 entities). Use services: for the live Home Assistant service catalog, or services:light for one domain. Read-only.")
            ])
        case "get_help":
            return object(
                required: [],
                properties: [
                    "topic": string("home-assistant, unlink, preview, pairing, deploy, or onboarding")
                ]
            )
        case "discover_services":
            return object(
                required: [],
                properties: [
                    "host": string("Optional manual host to remember for pairing (no scanning)."),
                    "port": integer("Optional manual TLS port shown on the device's unpaired screen.")
                ]
            )
        case "request_pairing":
            return object(
                required: [],
                properties: [
                    "deviceId": string("Advertised or previously paired device id."),
                    "host": string("Manual host when the device is not advertised."),
                    "port": integer("Manual TLS port when the device is not advertised.")
                ]
            )
        case "confirm_pairing":
            return object(
                required: ["deviceId"],
                properties: [
                    "deviceId": string("Device id returned by request_pairing.")
                ]
            )
        case "get_device":
            return object(
                required: ["deviceId"],
                properties: [
                    "deviceId": string(),
                    "probe": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                        "description": .string("Query the device over TLS for reachability and active revision.")
                    ])
                ]
            )
        case "forget_device":
            return object(
                required: ["deviceId"],
                properties: ["deviceId": string()]
            )
        case "deploy_dashboard":
            return object(
                required: ["deviceId", "dashboardId", "revision", "approved"],
                properties: [
                    "deviceId": string(),
                    "dashboardId": string(),
                    "revision": string("Exact previewed revision the user approved."),
                    "approved": .object([
                        "type": .string("boolean"),
                        "description": .string("True only after the user approved this previewed revision in chat.")
                    ]),
                    "deploymentId": string("Optional idempotency key; reuse it to retry safely.")
                ]
            )
        case "rollback_dashboard":
            return object(
                required: ["deviceId", "revision", "approved"],
                properties: [
                    "deviceId": string(),
                    "dashboardId": string(),
                    "revision": string("A revision from the device's history."),
                    "approved": .object([
                        "type": .string("boolean"),
                        "description": .string("True only after the user chose this revision in chat.")
                    ]),
                    "deploymentId": string("Optional idempotency key.")
                ]
            )
        case "get_deployment":
            return object(
                required: ["deploymentId"],
                properties: ["deploymentId": string()]
            )
        case "list_versions":
            return object(
                required: ["dashboardId"],
                properties: ["dashboardId": string()]
            )
        default:
            return object(
                required: [],
                properties: [
                    "dashboardId": string(),
                    "revision": string(),
                    "deviceId": string()
                ]
            )
        }
    }

    private static func object(required: [String], properties: [String: JSONValue]) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if required.isEmpty == false {
            schema["required"] = .array(required.map(JSONValue.string))
        }
        return .object(schema)
    }

    private static func string(_ description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string")]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    private static func integer(_ description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("integer")]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    private static func number() -> JSONValue {
        .object(["type": .string("number")])
    }
}
