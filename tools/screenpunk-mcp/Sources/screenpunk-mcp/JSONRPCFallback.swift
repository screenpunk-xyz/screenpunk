import Foundation
import ScreenpunkController

/// Stdio JSON-RPC fallback when SCREENPUNK_MCP_TRANSPORT=jsonrpc.
enum JSONRPCFallback {
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
