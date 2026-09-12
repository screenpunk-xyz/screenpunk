# MCP protocol fixtures

Linux `./scripts/ci/linux.sh` checks the committed catalog, help text, and
`docs/mcp.md`. It does not compile Swift or take WKWebView snapshots.

Apple `swift test` in `packages/ScreenpunkController` exercises authoring,
revision conflict, live-default preview image content, and failed-render
honesty. `./scripts/ci/preview.sh` still attempts a real hidden helper PNG
and never writes a placeholder.
