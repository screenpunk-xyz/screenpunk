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
bootstrap is in progress. Feasibility spikes (hidden Mac preview, iOS isolation,
pairing) are not done.

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
./scripts/ci/linux.sh          # schema, SDK, brand provenance (Linux)
./scripts/generate-xcode.sh    # regenerate Xcode projects (macOS)
```

## License

Apache 2.0 for software. Brand artwork is separate — see
[docs/brand-policy.md](docs/brand-policy.md).
