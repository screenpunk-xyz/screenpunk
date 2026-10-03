import Foundation
import CoreFoundation
import ScreenpunkController
import ScreenpunkBrokerMCP

/// Bounded stdio MCP framing around the same closed SDK-free broker adapter
/// and catalog used by the legacy executable. The client has only the
/// ordinary broker credential; local review is not a tool route.
enum WorkbenchMCPBridge {
    static var names: [String] { BrokerMCPToolCatalog.tools().map(\.name) }

    static func run(environment: WorkbenchBrokerEnvironment, home: URL) throws {
        let client = WorkbenchBrokerClient(environment: environment, credentialScope: .ordinary)
        defer { client.close() }
        try client.connect()
        let adapter = try LegacyBrokerAdapter(client: client,
            expectedControllerHomePath: home.resolvingSymlinksInPath().path)
        let expectedHome = home.resolvingSymlinksInPath().path
        let catalog = BrokerMCPToolCatalog.tools()
        let allowed = Set(catalog.map(\.name))
        let input = BoundedMCPInput()
        while let line = input.next() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let id = object["id"], id is String ||
                  ((id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true) else { continue }
            guard object["jsonrpc"] as? String == "2.0", let method = object["method"] as? String else {
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Invalid Request."]])
                continue
            }
            if method.hasPrefix("notifications/") { continue }
            let result: [String: Any]
            switch method {
            case "initialize":
                result = ["protocolVersion": "2025-03-26",
                          "capabilities": ["tools": ["listChanged": false],
                                           "resources": ["listChanged": false, "subscribe": false]],
                          "serverInfo": ["name": "screenpunk-workbench", "version": WorkbenchCommand.version]]
            case "ping": result = [:]
            case "tools/list": result = ["tools": catalog.map(BrokerMCPJSONRPC.toolJSON)]
            case "tools/call":
                guard let params = object["params"] as? [String: Any],
                      let name = params["name"] as? String, allowed.contains(name),
                      let arguments = (params["arguments"] ?? [:]) as? [String: Any] else {
                    result = toolError("Unsupported tool or arguments.")
                    break
                }
                do {
                    if try client.reconnectIfPeerClosed() {
                        guard try client.health().controllerHomePath == expectedHome else {
                            client.close()
                            throw WorkbenchIPCError(.instanceMismatch)
                        }
                    }
                    result = BrokerMCPJSONRPC.toolCall(adapter, name: name, arguments: arguments)
                } catch { result = toolError("Broker connection unavailable; request was not submitted.") }
            case "resources/list":
                result = ["resources": LegacyBrokerAdapter.resourceURIs.map { uri in
                    ["name": uri, "uri": uri,
                     "description": "Typed broker workspace, project or deployment metadata"]
                }]
            case "resources/read":
                guard let params = object["params"] as? [String: Any],
                      let uri = params["uri"] as? String else {
                    result = ["contents": []]
                    break
                }
                let read: (text: String, isError: Bool)
                do {
                    if try client.reconnectIfPeerClosed() {
                        guard try client.health().controllerHomePath == expectedHome else {
                            client.close()
                            throw WorkbenchIPCError(.instanceMismatch)
                        }
                    }
                    read = adapter.resource(uri)
                } catch { read = ("Broker connection unavailable; request was not submitted.", true) }
                result = ["contents": [["uri": uri,
                    "mimeType": uri.hasPrefix("screenpunk://help/") ? "text/plain" : "application/json",
                    "text": read.text]]]
            default:
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found."]])
                continue
            }
            write(["jsonrpc": "2.0", "id": id, "result": result])
        }
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
    private static func write(_ object: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
}

private final class BoundedMCPInput {
    private var buffer = Data()
    private var discarding = false
    private let maximum = 8 * 1024 * 1024

    func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if discarding || line.count > maximum { discarding = false; continue }
                return String(data: line, encoding: .utf8)
            }
            if buffer.count > maximum { buffer.removeAll(keepingCapacity: true); discarding = true }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil } // EOF never executes a partial frame.
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
}
