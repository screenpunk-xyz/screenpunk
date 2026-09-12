# Screenpunk

Local Apple dashboards: a thin iOS/iPadOS 16+ wrapper and a macOS 26+ Apple
silicon companion. Agents author bundled HTML/CSS/JavaScript; devices run
independently after deploy.

No Screenpunk account, cloud service, or telemetry: the Mac and the device
talk to each other over your network and to the services you approve. To
reset a device, hold two fingers on its screen for ten seconds and tap
**Unlink**.

This repository is the implementation monorepo. Planning lives in
`screenpunk-xyz/Planning-Files`. Visual identity is copied from approved
assets in `screenpunk-xyz/Brand` (Codex Brand & App Guide at
`Brand/Style-Guide/`). Shipped apps do not check out Brand at runtime.

## Status

Alpha in progress. See
[docs/implementation-status.md](docs/implementation-status.md) for the
current milestone, branches, and evidence.

## Documentation

| Guide | Covers |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Install the Mac and iPhone/iPad apps, pair, approve connections, deploy, keep a device displaying |
| [docs/mcp-install.md](docs/mcp-install.md) | Connect Codex, Claude Desktop, or Cursor to the bundled `screenpunk-mcp`; tools, approvals, errors |
| [docs/unlink-and-recovery.md](docs/unlink-and-recovery.md) | Two-finger ten-second Unlink, Forget, Offline ring, failure recovery |
| [docs/release-workflow.md](docs/release-workflow.md) | CI jobs, Apple secrets, signed and notarized Mac DMG, iOS TestFlight boundary |
| [docs/help/](docs/help/README.md) | Text returned by MCP `get_help` and shown in-app |
| [docs/contracts.md](docs/contracts.md), [docs/toolchain.md](docs/toolchain.md) | Wire contracts; pinned tools and runners |
| [docs/brand-policy.md](docs/brand-policy.md), [docs/apple-review-position.md](docs/apple-review-position.md) | Brand terms; App Review position |

## Layout

```text
apps/ios/ apps/macos/
packages/ScreenpunkCore/ ScreenpunkApple/ ScreenpunkController/
tools/screenpunk-mcp/ tools/preview-host/
sdk/ schemas/ examples/ tests/ scripts/
assets/brand/ docs/ .github/workflows/
```

## Commands

```sh
./scripts/ci/linux.sh          # schema, SDK, package validator, HTTP/WS fixture adapters
./scripts/generate-xcode.sh    # install pinned XcodeGen 2.46.0; regenerate projects
./scripts/ci/apple.sh          # macOS: Core/Apple/Controller tests + iOS 16 compile
./scripts/ci/preview.sh        # macOS: hidden WKWebView probe (no fake PNG)
```

## License

Apache 2.0 for software. Copyright 2026 Screenpunk, Inc. Brand artwork is separate — see
[docs/brand-policy.md](docs/brand-policy.md).
