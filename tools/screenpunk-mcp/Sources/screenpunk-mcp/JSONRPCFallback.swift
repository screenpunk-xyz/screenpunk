import Foundation
import ScreenpunkController
import ScreenpunkBrokerMCP

/// Stdio JSON-RPC fallback when SCREENPUNK_MCP_TRANSPORT=jsonrpc.
enum JSONRPCFallback {
    static func run(broker: LegacyBrokerAdapter) {
        let input = FileHandle.standardInput
        var buffer = Data()
        while let chunk = try? input.read(upToCount: 4096), !chunk.isEmpty {
            buffer.append(chunk)
            if buffer.count > 8 * 1024 * 1024 {
                FileHandle.standardError.write(Data("mcp_error frame_limit\n".utf8))
                return
            }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let reply = brokerReply(line, broker: broker) { FileHandle.standardOutput.write(reply + Data([10])) }
            }
        }
        if !buffer.isEmpty, let reply = brokerReply(buffer, broker: broker) {
            FileHandle.standardOutput.write(reply + Data([10]))
        }
    }

    private static func brokerReply(_ line: Data, broker: LegacyBrokerAdapter) -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
              let id = request["id"] else { return nil }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": "2025-03-26", "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "screenpunk", "version": "1.0.0"]]
        case "ping": result = [:]
        case "tools/list":
            result = ["tools": BrokerMCPToolCatalog.tools().map(BrokerMCPJSONRPC.toolJSON)]
        case "tools/call":
            guard let params = request["params"] as? [String: Any], let name = params["name"] as? String,
                  let arguments = (params["arguments"] ?? [:]) as? [String: Any] else {
                result = ["content": [["type": "text", "text": "Invalid tool arguments."]], "isError": true]
                break
            }
            result = BrokerMCPJSONRPC.toolCall(broker, name: name, arguments: arguments)
        case "resources/list":
            result = ["resources": LegacyBrokerAdapter.resourceURIs.map { uri in
                ["name": uri, "uri": uri, "description": "Typed broker workspace, project or deployment metadata"]
            }]
        case "resources/read":
            guard let params = request["params"] as? [String: Any], let uri = params["uri"] as? String else {
                result = ["contents": []]
                break
            }
            let read = broker.resource(uri)
            result = ["contents": [["uri": uri,
                "mimeType": uri.hasPrefix("screenpunk://help/") ? "text/plain" : "application/json",
                "text": read.text]]]
        default:
            return encode(["jsonrpc": "2.0", "id": id,
                           "error": ["code": -32601, "message": "Method not found."]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(_ value: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func run(service: ControllerService) {
        _ = service.ensureHelper()
        let rpc = MCPJSONRPC(router: MCPToolRouter(service: service))
        FileHandle.standardError.write(
            Data("screenpunk-mcp jsonrpc helperStarted=\(service.helperStarted)\n".utf8)
        )
        while let line = readLine(strippingNewline: true) {
            do {
                if let reply = try rpc.handle(line: line) {
                    FileHandle.standardOutput.write(Data((reply + "\n").utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("mcp_error \(error.localizedDescription)\n".utf8))
            }
        }
    }
}
