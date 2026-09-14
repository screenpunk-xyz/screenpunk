import Foundation
import MCP
import ScreenpunkController

enum OfficialMCPServer {
    static func run(service: ControllerService) async throws {
        _ = service.ensureHelper()
        let presence = AgentPresenceSession(root: service.store.root)
        defer { presence.stop() }
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
            presence.activate()
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
            presence.activate()
            let arguments = jsonValue(params.arguments)
            let result = router.call(name: params.name, arguments: arguments)
            return .init(content: mcpContent(result.content), isError: result.isError)
        }

        await server.withMethodHandler(ListResources.self) { _ in
            .init(
                resources: [
                    Resource(name: "Onboarding", uri: "screenpunk://help/onboarding", description: "MCP setup and live preview"),
                    Resource(name: "Unlink recovery", uri: "screenpunk://help/unlink", description: "Two-finger ten-second Unlink gesture"),
                    Resource(name: "Live preview", uri: "screenpunk://help/preview", description: HelpCatalog.livePreviewLabel),
                    Resource(name: "Pairing", uri: "screenpunk://help/pairing", description: "SAS matching code, one owner per device, never self-approves"),
                    Resource(name: "Deploy", uri: "screenpunk://help/deploy", description: "Deploy the previewed revision the user approved; failed transfer keeps the current dashboard")
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
        toValue(MCPToolSchemas.inputSchema(for: name))
    }

    private static func toValue(_ json: JSONValue) -> Value {
        switch json {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .array(let values): return .array(values.map(toValue))
        case .object(let values): return .object(values.mapValues(toValue))
        }
    }
}
