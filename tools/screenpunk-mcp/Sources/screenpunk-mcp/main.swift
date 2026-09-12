import Foundation
import ScreenpunkCore

/// Stdio MCP entry. Milestone 0 ships the target only; the Swift MCP SDK
/// is pinned after a compatibility build in the feasibility spike.
@main
enum ScreenpunkMCP {
    static func main() {
        FileHandle.standardError.write(
            Data("screenpunk-mcp bootstrap \(PackageLimits.schemaMajor)\n".utf8)
        )
        FileHandle.standardError.write(
            Data("hidden preview helper is not implemented yet\n".utf8)
        )
    }
}
