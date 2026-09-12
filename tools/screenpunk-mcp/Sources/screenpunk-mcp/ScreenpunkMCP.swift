import Foundation
import ScreenpunkController
import ScreenpunkCore

@main
enum ScreenpunkMCP {
    static func main() async {
        do {
            let service = try ControllerService.bootstrap()
            let transport = LANTransport()
            let lanStatus = transport.attach(to: service)
            FileHandle.standardError.write(
                Data("screenpunk-mcp bootstrap \(PackageLimits.schemaMajor) helper=\(service.helperStarted) \(lanStatus)\n".utf8)
            )
            if ProcessInfo.processInfo.environment["SCREENPUNK_MCP_TRANSPORT"] == "jsonrpc" {
                JSONRPCFallback.run(service: service)
            } else {
                try await OfficialMCPServer.run(service: service)
            }
            // The Bonjour browser must outlive the server loop.
            withExtendedLifetime(transport) {}
        } catch {
            FileHandle.standardError.write(
                Data("screenpunk-mcp failed \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }
}
