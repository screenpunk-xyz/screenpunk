import Foundation
import ScreenpunkController
import ScreenpunkCore

@main
enum ScreenpunkMCP {
    static func main() async {
        do {
            let service = try ControllerService.bootstrap()
            FileHandle.standardError.write(
                Data("screenpunk-mcp bootstrap \(PackageLimits.schemaMajor) helper=\(service.helperStarted)\n".utf8)
            )
            if ProcessInfo.processInfo.environment["SCREENPUNK_MCP_TRANSPORT"] == "jsonrpc" {
                JSONRPCFallback.run(service: service)
                return
            }
            try await OfficialMCPServer.run(service: service)
        } catch {
            FileHandle.standardError.write(
                Data("screenpunk-mcp failed \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }
}
