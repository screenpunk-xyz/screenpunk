# Connecting local agents

The native Connect an Agent sheet provides Cursor, Claude Desktop, Codex, and Generic / Local Models profiles. Changing profile changes its numbered instructions, configuration format, documentation link, and SCREENPUNK_AGENT_NAME. Copy exports only the displayed configuration (or the launch command for Codex); the app never overwrites client settings. Install the app in Applications and reopen the sheet before copying its executable path.

- Cursor: Customize → MCPs → + New MCP Server; global ~/.cursor/mcp.json or project .cursor/mcp.json; stdio command/args/env JSON.
- Claude Desktop: Claude menu → Settings → Developer → Edit Config; merge mcpServers JSON in ~/Library/Application Support/Claude/claude_desktop_config.json, then restart. Remote web connectors are a separate transport; this profile uses the local developer configuration.
- Codex: Open Plugins → MCPs → Connect to a custom MCP. Set Name to Screenpunk and Type to STDIO. Use Copy Command in Screenpunk to copy the resolved bundled screenpunk-mcp executable path, then paste it into Command to launch. Leave Arguments empty. Add environment variable SCREENPUNK_AGENT_NAME with value Codex. Leave Environment variable passthrough and Working directory empty. Click Save, start a local task, and ask Codex to use Screenpunk’s tools; enable the server or restart Codex if needed. This desktop setup does not require Finder or editing config.toml.
- Generic: a local agent host must support MCP STDIO and the chosen model must support tool use. The executable, empty arguments, and environment are given in conventional mcpServers JSON; host schemas can vary. An HTTP-only host needs an adapter. A bare model inference server is not an MCP client.

Grok Bot is not presented as a working local option. Its documented cloud-computer/plugin execution model needs a separate integration check; marketplace presence alone does not establish local access. Grok web custom URL connectors are a different product path and would require a reachable HTTP service/bridge; this app currently bundles a local STDIO server. No bridge, tunnel, marketplace publication, or new agent connection was created by this UI change.

Verified September 13, 2026:
- https://cursor.com/docs/mcp (Customize, configuration paths, STDIO schema); user supplied the current MCPs → New MCP Server screenshot.
- User-supplied Codex desktop screenshot (September 13, 2026) verifies Plugins → MCPs → Connect to a custom MCP and the STDIO command, arguments, environment, working directory, and Save fields. https://developers.openai.com/codex/mcp/ remains the general MCP reference.
- https://modelcontextprotocol.io/docs/develop/connect-local-servers (Claude Desktop developer configuration).
- https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp (local vs remote connector distinction).
- https://cursor.com/docs/grok-bot/work (cloud computer and local execution distinction).
- https://docs.x.ai/grok/connectors (Grok web custom URLs, separate from local STDIO).


## Connections page (build 27)

The bottom sidebar entry opens Connections in the detail pane. Installed remembers agent types that have actually connected, grouping concurrent sessions by canonical name. Cursor appears once as long as any Cursor session is active, and shows Not connected when none remain. Agents includes Claude Desktop, Codex, Cursor, and Generic / Local Models; selecting a card opens the existing setup sheet preselected for that profile.

Services currently contains Home Assistant. Its sheet validates the entered server with an authenticated GET to /api/ and persists settings only after a successful test and Keychain write. UserDefaults contains only the address and opaque Keychain reference, never the token. Redirects are rejected; validation responses are bounded. Test Connection does not save credentials. A new typed token is not treated as verification of the previously saved credential.

Home Assistant status is explicitly Verified on this Mac, not a continuous online monitor. On relaunch it is Configured · not checked. Phone-side connection provisioning, entity permissions, and independent runtime transport are still pending and explicitly disclosed in the modal. No Home Assistant entities are read or controlled by setup verification.

Validation: native navigation, one installed Cursor row with multiple real sessions, direct Codex setup, search, and Home Assistant form/error recovery were checked. A local fake API verifies success, bad addresses, 401, redirects (no follow), invalid JSON content, response bounds, and agent name grouping. The app’s loopback form test timed out in this host environment; recent app logs also show local-network-prohibited errors. No real Home Assistant token was used, no service settings saved during UI QA, and no device control was attempted.
