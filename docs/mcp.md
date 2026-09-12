# Screenpunk MCP

The bundled `screenpunk-mcp` executable speaks stdio MCP (official Swift SDK
0.10.2). It starts the local controller and hidden preview helper automatically.
The Mac workbench does not need to be visibly open. The Mac must be awake and
logged in.

Preview is **live by default**. Live preview — actions control your devices.
`preview_dashboard` returns PNG image content rendered by Screenpunk, plus
revision digest, target size, `macOS-preview` platform, connection health, and
diagnostics. It never returns only a filesystem path. Failed captures are
`render_timeout` / `snapshot_unavailable` (`SNAPSHOT_UNAVAILABLE`); Screenpunk
does not substitute a placeholder image.

This is agent-mediated approval, not a cryptographic guarantee that a chat
statement matches the rendered revision.

## Install

End users install the Mac app, not a language runtime. Point the agent client at
the **absolute** path of `screenpunk-mcp`. If you move the app, update that path
yourself. Screenpunk does not silently edit Codex, Claude Desktop, or Cursor
config.

Typical bundled locations after a Screenpunk Mac install:

```text
/Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp
/Applications/Screenpunk.app/Contents/Helpers/ScreenpunkPreviewHost.app/Contents/MacOS/ScreenpunkPreviewHost
```

Set `SCREENPUNK_PREVIEW_HOST` to the helper binary if it is not next to the MCP
executable. Set `SCREENPUNK_CONTROLLER_HOME` only for tests or a non-default
store.

### Codex

```toml
[mcp_servers.screenpunk]
command = "/Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp"
```

### Claude Desktop

```json
{
  "mcpServers": {
    "screenpunk": {
      "command": "/Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp"
    }
  }
}
```

### Cursor

```json
{
  "mcpServers": {
    "screenpunk": {
      "command": "/Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp"
    }
  }
}
```

Developer checkout (macOS, after compiling the helper):

```sh
export SCREENPUNK_PREVIEW_HOST="$PWD/tools/preview-host/ScreenpunkPreviewHost.app/Contents/MacOS/ScreenpunkPreviewHost"
swift run --package-path tools/screenpunk-mcp screenpunk-mcp
```

`SCREENPUNK_MCP_TRANSPORT=jsonrpc` selects the newline JSON-RPC fallback used by
protocol tests. Production clients should use the official SDK transport
(default).

## Unlink recovery

Hold two fingers on the device screen for ten seconds, then tap Unlink.
Dashboard, credentials, and pairing are erased.

Forgetting an unreachable device on the Mac does not erase it. The phone still
requires the gesture above.

`get_help` topic `unlink` and the `screenpunk://help/unlink` resource repeat
these instructions.

## Brand

Identity follows the Codex Brand & App Guide
(https://screenpunk-style-guide.gsuter.chatgpt.site). Default lockup is stacked.
Danger/error treatment uses guide `danger` tokens. MCP itself is not a visual
surface.

## Operator smoke

With the workbench closed, start a real MCP client, `update_dashboard`,
`validate_dashboard`, then `preview_dashboard`. Confirm an inline PNG whose
metadata revision matches the created revision. Make a second revision and
preview again. Do not treat a missing image as success.
