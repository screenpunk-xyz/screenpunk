import Foundation
import MCP
import ScreenpunkController

enum OfficialMCPServer {
    static func run(service: ControllerService) async throws {
        _ = service.ensureHelper()
        let router = MCPToolRouter(service: service)
        let catalog = router.catalog
        let onboarding = HelpCatalog.topic(id: "onboarding").body

        let server = Server(
            name: "screenpunk",
            version: "1.0.0",
            instructions: onboarding,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            let tools = catalog.tools.map { tool in
                Tool(
                    name: tool.name,
                    description: tool.description,
                    inputSchema: schema(for: tool.name),
                    annotations: .init(
                        title: tool.name,
                        readOnlyHint: tool.readOnlyHint,
                        destructiveHint: tool.destructiveHint,
                        idempotentHint: tool.idempotentHint,
                        openWorldHint: tool.openWorldHint
                    )
                )
            }
            return .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            let arguments = jsonValue(params.arguments)
            let result = router.call(name: params.name, arguments: arguments)
            return .init(content: mcpContent(result.content), isError: result.isError)
        }

        await server.withMethodHandler(ListResources.self) { _ in
            .init(
                resources: [
                    Resource(name: "Onboarding", uri: "screenpunk://help/onboarding", description: "MCP setup and live preview"),
                    Resource(name: "Unlink recovery", uri: "screenpunk://help/unlink", description: "Two-finger ten-second Unlink gesture"),
                    Resource(name: "Live preview", uri: "screenpunk://help/preview", description: HelpCatalog.livePreviewLabel)
                ],
                nextCursor: nil
            )
        }

        await server.withMethodHandler(ReadResource.self) { params in
            let topicId = params.uri.split(separator: "/").last.map(String.init) ?? "onboarding"
            let topic = HelpCatalog.topic(id: topicId)
            return .init(
                contents: [
                    Resource.Content.text("\(topic.title)\n\n\(topic.body)", uri: params.uri, mimeType: "text/plain")
                ]
            )
        }

        FileHandle.standardError.write(
            Data("screenpunk-mcp official-sdk helperStarted=\(service.helperStarted)\n".utf8)
        )
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    private static func mcpContent(_ content: [MCPContent]) -> [Tool.Content] {
        content.map { item in
            switch item {
            case .text(let text):
                return .text(text)
            case .image(let data, let mime, let metadata):
                return .image(data: data, mimeType: mime, metadata: metadata)
            }
        }
    }

    private static func jsonValue(_ arguments: [String: Value]?) -> JSONValue {
        guard let arguments else { return .object([:]) }
        return .object(arguments.mapValues(from(value:)))
    }

    private static func from(value: Value) -> JSONValue {
        if let string = value.stringValue { return .string(string) }
        if let bool = value.boolValue { return .bool(bool) }
        if let int = value.intValue { return .int(int) }
        if let double = value.doubleValue { return .double(double) }
        if let array = value.arrayValue { return .array(array.map(from(value:))) }
        if let object = value.objectValue { return .object(object.mapValues(from(value:))) }
        return .null
    }

    private static func schema(for name: String) -> Value {
        switch name {
        case "update_dashboard":
            return .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("files")]),
                "properties": .object([
                    "dashboardId": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "baseRevision": .object(["type": .string("string")]),
                    "files": .object(["type": .string("array")]),
                    "target": .object(["type": .string("object")]),
                    "connections": .object(["type": .string("array")])
                ])
            ])
        case "preview_dashboard", "interact_preview":
            return .object([
                "type": .string("object"),
                "required": .array([.string("dashboardId")]),
                "properties": .object([
                    "dashboardId": .object(["type": .string("string")]),
                    "revision": .object(["type": .string("string")]),
                    "live": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                        "description": .string(HelpCatalog.livePreviewLabel)
                    ]),
                    "kind": .object(["type": .string("string")]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                    "text": .object(["type": .string("string")]),
                    "dy": .object(["type": .string("number")])
                ])
            ])
        case "get_help":
            return .object([
                "type": .string("object"),
                "properties": .object([
                    "topic": .object([
                        "type": .string("string"),
                        "description": .string("unlink, preview, pairing, or onboarding")
                    ])
                ])
            ])
        default:
            return .object([
                "type": .string("object"),
                "properties": .object([
                    "dashboardId": .object(["type": .string("string")]),
                    "revision": .object(["type": .string("string")]),
                    "deviceId": .object(["type": .string("string")])
                ])
            ])
        }
    }
}
