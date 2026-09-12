import Foundation

/// Minimal MCP stdio JSON-RPC (newline delimited). Used by tests and as a
/// fallback if the official Swift SDK cannot start. Production `screenpunk-mcp`
/// prefers the official SDK.
public struct MCPJSONRPC: Sendable {
    public let router: MCPToolRouter
    public let catalog: MCPCatalogFile

    public init(router: MCPToolRouter) {
        self.router = router
        self.catalog = router.catalog
    }

    public func handle(line: String) throws -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let value = try JSONValue.parse(Data(trimmed.utf8))
        if value["method"]?.string?.hasPrefix("notifications/") == true {
            return nil
        }
        guard let id = value["id"] else {
            return nil
        }
        let method = value["method"]?.string ?? ""
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": catalog.tools.isEmpty ? "2025-03-26" : "2025-03-26",
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": false, "listChanged": false]
                ],
                "serverInfo": ["name": "screenpunk", "version": "1.0.0"],
                "instructions": HelpCatalog.topic(id: "onboarding").body
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = [
                "tools": catalog.tools.map { tool -> [String: Any] in
                    var annotations: [String: Any] = [
                        "readOnlyHint": tool.readOnlyHint,
                        "destructiveHint": tool.destructiveHint,
                        "openWorldHint": tool.openWorldHint
                    ]
                    if let idempotent = tool.idempotentHint {
                        annotations["idempotentHint"] = idempotent
                    }
                    return [
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": inputSchema(for: tool.name),
                        "annotations": annotations
                    ]
                }
            ]
        case "tools/call":
            let params = value["params"] ?? .null
            let name = params["name"]?.string ?? ""
            let args = params["arguments"] ?? .object([:])
            let call = router.call(name: name, arguments: args)
            result = call.jsonObject()
        case "resources/list":
            result = [
                "resources": [
                    resource("screenpunk://help/onboarding", "Onboarding"),
                    resource("screenpunk://help/unlink", "Unlink recovery"),
                    resource("screenpunk://help/preview", "Live preview")
                ]
            ]
        case "resources/read":
            let uri = value["params"]?["uri"]?.string ?? "screenpunk://help/onboarding"
            let topicId = uri.split(separator: "/").last.map(String.init) ?? "onboarding"
            let topic = HelpCatalog.topic(id: topicId)
            result = [
                "contents": [[
                    "uri": uri,
                    "mimeType": "text/plain",
                    "text": "\(topic.title)\n\n\(topic.body)"
                ]]
            ]
        default:
            return encode([
                "jsonrpc": "2.0",
                "id": id.jsonObject(),
                "error": ["code": -32601, "message": "method not found: \(method)"]
            ])
        }
        return encode([
            "jsonrpc": "2.0",
            "id": id.jsonObject(),
            "result": result
        ])
    }

    private func resource(_ uri: String, _ name: String) -> [String: String] {
        ["uri": uri, "name": name, "mimeType": "text/plain"]
    }

    private func inputSchema(for name: String) -> [String: Any] {
        switch name {
        case "update_dashboard":
            return [
                "type": "object",
                "properties": [
                    "dashboardId": ["type": "string"],
                    "name": ["type": "string"],
                    "baseRevision": ["type": "string"],
                    "files": ["type": "array"],
                    "target": ["type": "object"],
                    "connections": ["type": "array"]
                ],
                "required": ["name", "files"]
            ]
        case "preview_dashboard", "interact_preview":
            return [
                "type": "object",
                "properties": [
                    "dashboardId": ["type": "string"],
                    "revision": ["type": "string"],
                    "live": ["type": "boolean", "default": true],
                    "kind": ["type": "string"],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "text": ["type": "string"],
                    "dy": ["type": "number"]
                ],
                "required": ["dashboardId"]
            ]
        case "get_help":
            return [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "unlink, preview, pairing, or onboarding"]
                ]
            ]
        default:
            return [
                "type": "object",
                "properties": [
                    "dashboardId": ["type": "string"],
                    "revision": ["type": "string"],
                    "deviceId": ["type": "string"]
                ]
            ]
        }
    }

    private func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
