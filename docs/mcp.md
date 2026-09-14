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

## Pair and deploy from an agent

`screenpunk-mcp` speaks to devices over the same TLS 1.3 LAN link as the Mac
workbench (`ControllerLANClient`), and shares the workbench's controller
identity from the login keychain, so a device sees one owner whichever client
paired it. If macOS asks whether `screenpunk-mcp` may use the
`xyz.screenpunk.tls.controller` key, allow it. Paired devices are stored in
`devices.json` under the controller home. Devices fetch their own HTTP and
WebSocket data; the Mac is not a runtime proxy.

1. `discover_services` lists `_screenpunk._tcp` advertisements. If Bonjour is
   blocked, pass `host` and `port` from the device's unpaired screen.
2. `request_pairing` opens the pinned channel, runs SAS pairing, checks the
   code against its own transcript, and returns the six-digit matching code.
   Show it to the user. The device shows its own code. Both sides compute the
   transcript from the certificate pins observed in the TLS handshake; a peer
   that claims a different identity in a message is rejected before any code
   is shown.
3. Only if both codes match, the user taps **Confirm** on the device. Then call
   `confirm_pairing`. Until the device owner has confirmed there, it returns
   `permission_required`; the agent cannot approve on the device's behalf. Codes
   expire after two minutes. One owner per device: a device that already
   belongs to another Mac returns `not_paired` (`second_owner`) until it is
   unlinked on the device.
4. Author with `update_dashboard`, then `preview_dashboard`. Ask the user in
   chat whether the previewed revision should go to the device.
5. `deploy_dashboard` with `deviceId`, `dashboardId`, the exact `revision` the
   user saw, and `approved: true`. Revisions this controller never previewed
   return `permission_required`. This is agent-mediated chat approval, not a
   cryptographic guarantee. Pass a `deploymentId` to retry idempotently.

The device hash-checks every file and its target orientation and size before
activating. A failed or interrupted transfer returns an error result with
`phase: "failed"` and `currentDashboardKept: true`; the device keeps its
current dashboard. The device stores its owner, active revision, and package
bytes on disk, so it comes back paired and rendering after a relaunch; only
the two-finger Unlink erases them. `get_deployment` correlates by `deploymentId`.
`rollback_dashboard` redeploys a revision from the device's history through
the same path. `forget_device` removes the device from this Mac only and does
not erase it.

Without a paired device the delivery tools still answer honestly:
`list_devices` is empty, `deploy_dashboard` returns `not_paired`, and a
controller without the LAN transport returns `device_offline`.

## Unlink recovery

Hold two fingers on the device screen for five seconds, open the device menu, choose Disconnect, and confirm.
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

Then, with the iPhone on **Ready to pair**: `discover_services`,
`request_pairing`, compare the codes, tap **Confirm** on the phone,
`confirm_pairing`, `deploy_dashboard` with `approved: true`. The phone must
show the deployed package. Unplug the network mid-transfer once and confirm
the phone keeps its previous dashboard.
