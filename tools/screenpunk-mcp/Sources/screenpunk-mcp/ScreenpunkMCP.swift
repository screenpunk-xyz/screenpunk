import Foundation
import ScreenpunkController
import ScreenpunkCore
import ScreenpunkBrokerMCP

@main
enum ScreenpunkMCP {
    static func main() async {
        do {
            let broker = try LegacyBrokerAdapter()
            if ProcessInfo.processInfo.environment["SCREENPUNK_MCP_TRANSPORT"] == "jsonrpc" {
                JSONRPCFallback.run(broker: broker)
            } else {
                try await OfficialMCPServer.run(broker: broker)
            }
        } catch {
            FileHandle.standardError.write(
                Data("screenpunk-mcp failed \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }
}
