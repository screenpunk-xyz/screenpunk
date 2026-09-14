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

Use the `guy/codex/` prefix for Codex branches unless task instructions specify
otherwise. Give branches a short, descriptive purpose.

## Pull request scope

Keep PRs focused on one coherent change. A Mac-only fix or iOS-only visual
adjustment should be its own PR. A protocol or deployment feature that needs
coordinated changes across applications may land in one cross-app PR; do not
split it into incompatible intermediate states. Separate unrelated fixes,
cleanup, and release preparation.

State the affected applications and shared components, the resulting behavior,
and the relevant validation. Shared protocol, schema, SDK, or package changes
must account for every affected consumer and devices running older versions.
Use the PR template to record compatibility and physical testing when relevant.

The canonical build, merge, versioning, and publication policy is
[Release workflow](docs/release-workflow.md). Applications share this repository
but do not have to ship together. Update the README download row when a public
release becomes available; never advertise an unverified artifact as released.

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
