# MCP install

Screenpunk's agent interface is a Swift executable bundled inside the Mac
app and spoken to over stdio. Your agent client launches it. It starts the
per-user controller and the hidden preview helper on demand, does the work,
and exits when the client disconnects. Nothing listens on the network, no
account is involved, and you install no Node, Python, or other runtime.

Supported clients: Codex (the CLI, IDE extension, and ChatGPT desktop app
share one configuration), Claude Desktop, and Cursor. Any MCP client that
can launch a local stdio command works the same way.

Status: `tools/screenpunk-mcp` on `main` is still the Milestone 0
bootstrap. It prints a banner to stderr and exits, so a client configured
today will report that the server disconnected. Configure clients once the
Milestone 2 MCP runtime has merged
([implementation-status.md](implementation-status.md)). The configuration
below is what that runtime is built to satisfy.

## 1. Find the executable

Installed from the release DMG:

```text
/Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp
```

Check that it exists and is executable:

```sh
ls -l /Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp
```

The Mac app's settings show the same path with a copyable snippet for each
client. Screenpunk never edits your client's configuration files; you paste
the snippet yourself, and you remove it yourself.

Launch the app once before the first MCP connection so macOS finishes its
first-open verification. If the app lives somewhere else (a second copy, a
build in Xcode's DerivedData), use that absolute path. Do not point a
client at a mounted DMG; the path disappears when the DMG is ejected.

Source build, for development only:

```sh
cd tools/screenpunk-mcp && swift build -c release
echo "$(pwd)/.build/release/screenpunk-mcp"     # absolute path for the client
```

### If you move or rename the app

Configured paths are literal. If `Screenpunk.app` moves or is renamed,
every client fails to launch the server (a "not found" or spawn error)
until you update the path; copy the current snippet from the app's settings
again. Do not keep two copies of the app and point different clients at
each: they would share one controller store, and an older copy may not
understand a newer store. If you want a stable path of your own (a wrapper
script or symlink in your PATH), that is yours to maintain; Screenpunk does
not create one.

## 2. Configure your client

Use the same absolute path in each example, adjusted if yours differs. No
`args` or `env` entries are needed. Clients often have a narrower `PATH`
than your shell, which is one more reason to use the absolute path.

### Codex

```sh
codex mcp add screenpunk -- /Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp
codex mcp list
```

Equivalent entry in `~/.codex/config.toml` (or a trusted project's
`.codex/config.toml`):

```toml
[mcp_servers.screenpunk]
command = "/Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp"
```

This is TOML, not JSON, and the table is `mcp_servers`. If the first call
after a cold start is slow on your Mac, add
`startup_timeout_sec = 30` to the table. Remove with
`codex mcp remove screenpunk`.

### Claude Desktop

Claude menu > Settings… > Developer > Edit Config. This opens (or creates)
`~/Library/Application Support/Claude/claude_desktop_config.json`. Add:

```json
{
  "mcpServers": {
    "screenpunk": {
      "command": "/Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp"
    }
  }
}
```

Quit Claude Desktop fully (⌘Q) and reopen it; the configuration is read at
startup. Logs are under `~/Library/Logs/Claude/` (`mcp*.log`).

### Cursor

Global `~/.cursor/mcp.json`, or `.cursor/mcp.json` inside one project:

```json
{
  "mcpServers": {
    "screenpunk": {
      "type": "stdio",
      "command": "/Applications/Screenpunk.app/Contents/MacOS/screenpunk-mcp"
    }
  }
}
```

Cursor Settings > MCP lists the server and its tools; reload the window if
it does not appear.

## 3. Verify

Ask the agent to call `list_devices` (an empty list before pairing is a
valid answer) and `get_help` with topic `unlink`. If both return, the
controller started. Then pair a device following [setup.md](setup.md#pair).

## What the agent can do

| Group | Tools | Notes |
| --- | --- | --- |
| Discovery | `list_devices`, `get_device`, `discover_services` | Read-only. Redacted capabilities, actual viewport, reachability, advertised LAN services |
| Pairing and settings | `request_pairing`, `propose_connection` | Open a native confirmation on the Mac and return pending, approved, or denied. Never self-approve |
| Authoring | `list_dashboards`, `get_dashboard`, `update_dashboard`, `validate_dashboard` | Bounded files; each update needs the base revision and creates a new immutable revision |
| Connections | `list_connections`, `describe_connection`, `inspect_connection` | Read-only. Approved schemas and permitted live data or entities; no secrets |
| Preview | `preview_dashboard`, `interact_preview` | Real PNG of the exact revision and target, with digest, dimensions, platform, connection health, diagnostics. Interaction is live and performs real actions |
| Delivery | `deploy_dashboard`, `list_versions`, `rollback_dashboard` | Selected revision and target; returns a deployment ID and correlated status. Destructive of the device's current dashboard |
| Diagnostics | `get_deployment`, `get_logs`, `get_help` | Bounded, redacted output and troubleshooting text |

Rules the runtime enforces regardless of what an agent says or is told:

- Agents cannot approve anything. Pairing and new or expanded connections
  are confirmed by you in Screenpunk's native UI.
- `deploy_dashboard` is documented to require your explicit approval of the
  exact previewed revision in the chat. This is agent-mediated approval;
  the app cannot verify what was said in chat and makes no cryptographic
  claim. Read the revision digest the agent reports before you say yes.
- No secrets appear in any response, log, or error. `inspect_connection`
  returns only data the connection is permitted to read.
- Preview is a live render on your Mac: `interact_preview` can trigger real
  actions through approved connections, and screenshots may contain private
  data from your services. Capturing a screenshot clicks nothing.
- Output is bounded and paginated. Tool annotations mark read-only,
  write, and destructive operations, but enforcement is in the controller,
  not in the annotations.

## Errors

| Code | Meaning | Your action |
| --- | --- | --- |
| `not_paired` | Device not paired with this Mac | Pair it |
| `permission_required` | Connection or operation not yet approved | Approve in Screenpunk on the Mac |
| `revision_conflict` | Dashboard changed since the base revision the agent used | Let the agent reload and retry |
| `unsupported_version` | Schema major or bridge version not supported | Schema major 1, bundled SDK |
| `device_offline` | Target unreachable | Device foreground on the same network; retry. Its current dashboard is intact |
| `render_timeout` | Page never became ready in the preview host | Read the diagnostics; fix the package |
| `validation_failed` | Package rejected before transfer | Read the reasons in the response |

## Help topics

`get_help(topic:)` returns the text in [help/](help/README.md): `unlink`,
`pairing`, `offline`, `diagnostics`. The same text is bundled as MCP
onboarding resources so an agent can read it before you ask.

The one every agent should know: to remove Screenpunk from a device, hold
two fingers on its screen for ten seconds, then tap **Unlink**. That erases
the dashboard, its credentials, and the pairing. Forgetting an unreachable
device on the Mac does not erase the device.

## Controller lifecycle

- One controller per macOS user. Several clients share it; Codex and Cursor
  at the same time is fine.
- The controller's IPC is a Unix-domain socket in a user-only directory. It
  is not reachable over the network, and there is no public MCP listener.
- Closing the workbench window does not stop agent work. Quit All in the
  Screenpunk menu stops the controller and helpers; the next MCP request
  starts them again.
- Preview needs the Mac awake and logged in to your account. It does not
  render while the Mac is asleep, at the login window, or switched to
  another user.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Client reports the command was not found or failed to spawn | `ls -l` the path. The app moved, was renamed, or is on an ejected DMG |
| Server starts, then disconnects immediately | Run the path from Terminal and read stderr. On `main` today this is the bootstrap banner |
| Tools do not appear | Restart the client fully. Claude Desktop reads its config only at startup |
| First call times out | Cold start of controller and preview helper. Retry; in Codex raise `startup_timeout_sec` |
| macOS asks about Local Network | Allow it. Discovery and pairing need it |
| "Screenpunk cannot be opened" | Release builds are notarized. A build from source is unsigned and runs only on the Mac that built it |
| Two Screenpunk apps installed | Keep one. Update every client to its path |

## Uninstall

Remove the `screenpunk` entry from each client: `codex mcp remove
screenpunk`; delete the `screenpunk` key from Claude Desktop's and Cursor's
JSON. Screenpunk leaves client configuration alone in both directions.
