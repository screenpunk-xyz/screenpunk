# Screenpunk

Local Apple dashboards: a thin iOS/iPadOS 16+ wrapper and a macOS 26+ Apple
silicon companion. Agents author bundled HTML/CSS/JavaScript; devices run
independently after deploy.

This repository is the implementation monorepo. Planning lives in
`screenpunk-xyz/Planning-Files`. Visual identity is copied from approved
assets in `screenpunk-xyz/Brand` (Codex Brand & App Guide at
`Brand/Style-Guide/`). Shipped apps do not check out Brand at runtime.

## Status

See [docs/implementation-status.md](docs/implementation-status.md). Milestone 0
continues on `asher/codex/milestone-0-bootstrap` (PR #1). Isolation and pairing
fixtures are in-tree; hidden Mac snapshot evidence requires a real macOS
toolchain and is not faked.

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
./scripts/ci/linux.sh          # schema, SDK, brand, isolation/pairing fixtures
./scripts/generate-xcode.sh    # install pinned XcodeGen 2.46.0; regenerate projects
./scripts/ci/apple.sh          # macOS: Core tests + iOS 16 compile
./scripts/ci/preview.sh        # macOS: hidden WKWebView probe (no fake PNG)
```

## License

Apache 2.0 for software. Brand artwork is separate — see
[docs/brand-policy.md](docs/brand-policy.md).
