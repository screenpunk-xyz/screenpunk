# Screenpunk

Local Apple dashboards: a thin iOS/iPadOS 16+ wrapper and a macOS 14+ Apple
silicon companion. Agents author bundled HTML/CSS/JavaScript; devices run
independently after deploy.

No Screenpunk account, cloud service, or telemetry: the Mac and the device
talk to each other over your network and to the services you approve. To
reset a device, hold two fingers on its screen for five seconds, choose
**Disconnect** in the device menu, and confirm.

This repository is the implementation monorepo. Planning lives in
`screenpunk-xyz/Planning-Files`. Visual identity is copied from approved
assets in `screenpunk-xyz/Brand` (Codex Brand & App Guide at
`Brand/Style-Guide/`). Shipped apps do not check out Brand at runtime.

## Download Screenpunk

Screenpunk is in alpha. No public GitHub Releases are published yet; local
builds and Actions artifacts are testing builds, not public releases.

| Application | Availability | Download or install |
| --- | --- | --- |
| **Mac** · Apple silicon, macOS 14+ | Alpha testing; no public release version yet | [Alpha DMG instructions](docs/macos-unsigned-dmg.md) · [Build and install](docs/setup.md) |
| **iPhone / iPad** · iOS / iPadOS 16+ | Development testing; no public TestFlight or App Store link listed yet | [Install from source on your device](docs/setup.md#from-source-onto-your-own-device) |
| **Windows** | Planned; no build available | Installation instructions will appear here when available |
| **Docker** | Planned; no image available | Image and quickstart will appear here when available |

[All releases and release notes](https://github.com/screenpunk-xyz/screenpunk/releases)
will provide the published release history. When a platform release becomes
available, its row will link directly to that release or installation channel
and show its version and stable/beta status. OS targets above describe intended
compatibility; see [implementation status](docs/implementation-status.md) for
verification evidence and current limitations.

## Documentation

| Guide | Covers |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Install the Mac and iPhone/iPad apps, pair, approve connections, deploy, keep a device displaying |
| [docs/mcp-install.md](docs/mcp-install.md) | Connect Codex, Claude Desktop, or Cursor to the bundled `screenpunk-mcp`; tools, approvals, errors |
| [docs/unlink-and-recovery.md](docs/unlink-and-recovery.md) | Five-second two-finger device menu, Disconnect, Forget, and failure recovery |
| [docs/release-workflow.md](docs/release-workflow.md) | Focused PRs, independent app releases, CI gates, signing, and download publishing |
| [docs/macos-unsigned-dmg.md](docs/macos-unsigned-dmg.md) | Unsigned alpha Mac DMG from Actions: build, download, first launch via Open Anyway |
| [docs/help/](docs/help/README.md) | Text returned by MCP `get_help` and shown in-app |
| [docs/bundled-audio.md](docs/bundled-audio.md) | Package-local sound effects, playback errors, mute behavior, and native test instructions |
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

MCP setup for Codex, Claude Desktop, and Cursor: [docs/mcp.md](docs/mcp.md).
The helper starts automatically; preview is live by default.

## Commands

```sh
./scripts/ci/linux.sh          # schema, SDK, package validator, HTTP/WS fixture adapters, MCP catalog
./scripts/generate-xcode.sh    # install pinned XcodeGen 2.46.0; regenerate projects
./scripts/ci/apple.sh          # macOS: Core/Apple/Controller tests + iOS 16 compile
./scripts/ci/preview.sh        # macOS: hidden WKWebView probe (no fake PNG)
```

## License

Apache 2.0 for software. Copyright 2026 Screenpunk, Inc. Brand artwork is separate — see
[docs/brand-policy.md](docs/brand-policy.md).
