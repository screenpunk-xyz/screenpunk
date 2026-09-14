import Foundation

enum AgentSetupProfile: String, CaseIterable, Identifiable {
    case cursor = "Cursor"
    case claude = "Claude Desktop"
    case codex = "Codex"
    case generic = "Generic / Local Models"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .claude: return "sun.max"
        case .codex: return "curlybraces"
        case .cursor: return "cursorarrow"
        case .generic: return "sparkles"
        }
    }
    static func connectionName(_ name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch clean.lowercased() {
        case "cursor": return cursor.rawValue
        case "claude", "claude desktop", "claude code": return claude.rawValue
        case "codex": return codex.rawValue
        case "local agent", "mcp agent", "generic / local models": return generic.rawValue
        default: return clean.isEmpty ? generic.rawValue : clean
        }
    }
    static func profile(forConnectionName name: String) -> Self? {
        allCases.first { $0.rawValue == connectionName(name) }
    }
    var agentName: String { self == .generic ? "Local Agent" : rawValue }
    var configurationLabel: String { self == .codex ? "Command to launch" : "MCP configuration · JSON" }
    var instructions: [String] {
        switch self {
        case .cursor:
            return ["Open Cursor Settings → Tools & MCP → Add new global MCP server. In versions with Customize, use Customize → MCPs → + New MCP Server.",
                    "In the configuration file that opens, merge the screenpunk entry below into the existing mcpServers object, preserving other servers. Choose Local / STDIO if asked. As a fallback, open ~/.cursor/mcp.json directly.",
                    "Save, enable Screenpunk, and restart Cursor if it does not appear. Start a local Agent chat and allow its tools when prompted."]
        case .claude:
            return ["In Claude Desktop, open Claude → Settings → Developer → Edit Config.",
                    "Merge the screenpunk entry below into claude_desktop_config.json, keeping your existing servers. On Mac, this file is in ~/Library/Application Support/Claude/.",
                    "Quit and reopen Claude Desktop. Start a chat and enable Screenpunk’s tools. This setup is for local Claude Desktop MCP, not a web connector URL."]
        case .codex:
            return ["In Codex, open Plugins → MCPs and choose Connect to a custom MCP.",
                    "Set Name to Screenpunk and Type to STDIO. Paste the command below into Command to launch. Leave Arguments empty.",
                    "Under Environment variables, add key SCREENPUNK_AGENT_NAME with value Codex. Leave Environment variable passthrough and Working directory empty.",
                    "Click Save, then start a local task and ask Codex to use Screenpunk’s tools. Enable the server or restart Codex if needed."]
        case .generic:
            return ["Use an agent app on this Mac that supports local MCP (STDIO) and tool calling. A model server alone is not an MCP client.",
                    "Add a server named screenpunk. Set its command to the executable below, leave arguments empty, and add the environment variable. For clients using mcpServers JSON, merge this example into their configuration.",
                    "Choose your local model, enable Screenpunk’s tools, and start a chat. Clients that accept only HTTP server URLs need a separate adapter; this build provides STDIO."]
        }
    }
    var documentationURL: URL {
        let address: String
        switch self {
        case .cursor: address = "https://cursor.com/docs/mcp"
        case .claude: address = "https://modelcontextprotocol.io/docs/develop/connect-local-servers"
        case .codex: address = "https://developers.openai.com/codex/mcp/"
        case .generic: address = "https://modelcontextprotocol.io/docs/learn/architecture"
        }
        return URL(string: address)!
    }
    func configuration(executable: String) -> String {
        if self == .codex {
            return executable
        }
        var server: [String: Any] = ["command": executable, "args": [String](), "env": ["SCREENPUNK_AGENT_NAME": agentName]]
        if self != .claude { server["type"] = "stdio" }
        let value: [String: Any] = ["mcpServers": ["screenpunk": server]]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
