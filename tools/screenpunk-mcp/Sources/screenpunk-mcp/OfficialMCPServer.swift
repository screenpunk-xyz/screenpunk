import Foundation
import MCP
import ScreenpunkController
import ScreenpunkBrokerMCP

enum OfficialMCPServer {
    static func run(broker: LegacyBrokerAdapter) async throws {
        let server = Server(name: "screenpunk", version: "1.0.0",
                            instructions: HelpCatalog.topic(id: "onboarding").body,
                            capabilities: .init(resources: .init(subscribe: false, listChanged: false),
                                                tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: BrokerMCPToolCatalog.tools().map { item in
                Tool(name: item.name, description: item.description,
                     inputSchema: toValue(item.schema),
                     annotations: .init(title: item.name, readOnlyHint: item.readOnly,
                                        destructiveHint: item.destructive,
                                        idempotentHint: item.idempotent,
                                        openWorldHint: item.openWorld))
            })
        }
        await server.withMethodHandler(CallTool.self) { params in
            let arguments = jsonValue(params.arguments).object?.mapValues { $0.jsonObject() } ?? [:]
            let result = broker.call(name: params.name, arguments: arguments)
            return .init(content: [.text(result.text)], isError: result.isError)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: LegacyBrokerAdapter.resourceURIs.map { uri in
                Resource(name: uri, uri: uri, description: "Typed broker workspace, project or deployment metadata")
            }, nextCursor: nil)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            let result = broker.resource(params.uri)
            return .init(contents: [Resource.Content.text(result.text, uri: params.uri,
                mimeType: params.uri.hasPrefix("screenpunk://help/") ? "text/plain" : "application/json")])
        }
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

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
                    Resource(name: "Component catalog", uri: "screenpunk://authoring/catalog", description: "Versioned local component catalog and compatibility evidence"),
                    Resource(name: "React authoring", uri: "screenpunk://authoring/instructions", description: "Offline source, build, preview and deployment workflow"),
                    Resource(name: "Onboarding", uri: "screenpunk://help/onboarding", description: "MCP setup and live preview"),
                    Resource(name: "Disconnect recovery", uri: "screenpunk://help/unlink", description: "Five-second two-finger device menu gesture and confirmed Disconnect"),
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
            let authoringText = params.uri.hasPrefix("screenpunk://authoring/") ? try service.authoring.resource(topicId) : nil
            return .init(
                contents: [
                    Resource.Content.text(authoringText ?? "\(topic.title)\n\n\(topic.body)", uri: params.uri, mimeType: params.uri == "screenpunk://authoring/catalog" ? "application/json" : "text/plain")
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

    static func mcpContent(_ content: [MCPContent]) -> [Tool.Content] {
        content.map { item in
            switch item {
            case .text(let text):
                return .text(text: text, annotations: nil, _meta: nil)
            case .image(let data, let mime, let metadata):
                let fields = metadata?.mapValues { Value.string($0) }
                return .image(data: data, mimeType: mime, annotations: nil,
                    _meta: fields.map { Metadata(additionalFields: $0) })
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
