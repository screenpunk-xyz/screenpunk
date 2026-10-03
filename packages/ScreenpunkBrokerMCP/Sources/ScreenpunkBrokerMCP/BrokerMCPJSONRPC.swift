import Foundation

/// SDK-free JSON-RPC tool formatting shared by installed CLI and legacy stdio.
/// Framing remains the caller's responsibility; tools always use the same
/// closed catalog and adapter dispatch.
public enum BrokerMCPJSONRPC {
    public static func toolJSON(_ item: BrokerMCPToolDescriptor) -> [String: Any] {
        var annotations: [String: Any] = ["title": item.name,
            "readOnlyHint": item.readOnly, "destructiveHint": item.destructive,
            "openWorldHint": item.openWorld]
        if let idempotent = item.idempotent { annotations["idempotentHint"] = idempotent }
        return ["name": item.name, "description": item.description,
            "inputSchema": item.schema.jsonObject(), "annotations": annotations]
    }

    public static func toolCall(_ adapter: LegacyBrokerAdapter, name: String,
                                arguments: [String: Any]) -> [String: Any] {
        let result = adapter.call(name: name, arguments: arguments)
        return ["content": [["type": "text", "text": result.text]],
                "isError": result.isError]
    }
}
