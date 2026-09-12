# Contributing to Screenpunk

## Developer Certificate of Origin

Every commit must include a DCO sign-off:

```text
Signed-off-by: Your Name <you@example.com>
```

Use `git commit -s`. The [DCO](https://developercertificate.org/) records that
you have the right to submit the contribution. It does not assign copyright.

## License

Software in this repository is Apache 2.0. Brand artwork in `assets/brand/`
has separate terms. Do not recolor, redraw, or replace approved identity
assets without an operator decision recorded in Planning-Files.

## Branches

Use the `asher/codex/` prefix unless repository instructions change.

## Checks

From a clean checkout:

```sh
./scripts/ci/linux.sh          # includes tests/mcp catalog and unlink help
```

Apple generation (macOS). `./scripts/generate-xcode.sh` installs pinned
XcodeGen 2.46.0 when it is not already on PATH:

```sh
./scripts/generate-xcode.sh
./scripts/ci/apple.sh      # macOS CI: Core tests, iOS 16 compile
./scripts/ci/preview.sh    # hidden WKWebView probe; no fake PNG
```

Do not hand-edit generated `.xcodeproj` files. Change `project.yml` and regenerate.
