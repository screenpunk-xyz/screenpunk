# React authoring implementation and verification

Local implementation on `guy/codex/react-authoring`, based on recovery commit
`eaa7682` and GitHub main `5a45f2c`. The recovery commit is preserved. React work
has not been merged or released. No installed device application was replaced.

## Delivered

- [Authoring workflow and starter](../authoring/README.md): bundled Node 24.21.0,
  esbuild 0.28.2, React 19.3.0 and exact locked dependencies. Devices receive only
  built local assets. Kit version 1.0.0 is retained per source project.
- Four MCP project tools and catalog/instruction resources, on both transports.
  Source snapshots, conflict checks and failed-build preservation feed the existing
  package store; no new renderer category or manifest field.
- Small Mac UI: React starter/gallery, Reveal Source and Rebuild; managed React
  screens reveal editable source instead of opening generated JavaScript in Edit Code.
- All seven requested integrations, including a local SVG icon set and static CSS
  for plain JavaScript authors. [Catalog](../authoring/catalog.json) contains exact
  versions, imports, examples, notices, measured sizes and support status.
- Fixture-first earthquake dashboard with optional approved USGS public JSON reads.
  No private services or credentials are required for fixture mode.
- React lifecycle hooks, subscription cleanup, cancellation, retry timing and native
  active status. [Renderer ADR](react-renderer-decision.md) documents deferred native support.

Radix's default select/scroll-lock styles violated the existing content policy.
The pinned select viewport style is extracted into packaged CSS, and scrollbar
styling uses DOM style properties while retaining the library's event isolation.
The native CSP is unchanged. Both patches are scoped to the pinned library versions.

## Checks performed on 2026-09-21

Host: Apple silicon, macOS 26.6.2; Xcode SDK macOS 26.5.

| Check | Result |
| --- | --- |
| Clean `npm ci --ignore-scripts`, starter/gallery production builds | Passed |
| Authoring tests, including SDK structural typing, Strict Mode, cancellation, stale/error/unavailable states and Retry-After | 7 passed |
| Controller regression suite | 63 passed, including real bundled builds and source conflicts |
| Additional timed-out build test | Passed; no dashboard published |
| Existing SDK regression tests | 115 passed |
| MCP catalog tests | 4 passed |
| Apple package tests | 80 executed, 1 opt-in live-camera test skipped, 0 failures |
| Mac app, MCP helper, native preview helper | Compiled |
| iOS simulator app with existing iOS 16 deployment target | Compiled |
| Ad-hoc-signed assembled Mac candidate, strict signature verification | Passed |
| Bundled kit with network denied, empty temporary HOME and only bundled Node on PATH | Built complete gallery successfully |
| Packaged official MCP: initialize, create/build/validate React project, native PNG preview | Passed |
| Existing HTML package through packaged MCP/native preview | Passed |
| Native gallery controls, tabs, dialog focus/restore, select, table sort and carousel | Passed in 1024×768 light and 768×1024 dark; zero CSP violations |
| Earthquake fixture native snapshot | Passed |

The existing Apple LAN receiver regression tests include rejecting corrupted file
hashes and retaining the current screen after failed transfer. New controller
integration tests check every emitted asset against its generated manifest hash.
No weakening of integrity, grants or deployment review requirements was introduced.

## Observations, not performance guarantees

- Earthquake example: approximately 824 KB expanded, including notices.
- Full component gallery: approximately 989 KB expanded, including notices.
- Local debug Mac candidate: approximately 314 MiB on disk; its offline kit accounts
  for approximately 285 MiB. This is a substantial authoring-distribution increase.
- Mac gallery document readiness observed at 59–61 ms in two native probe runs.
  Interaction probes finish around 1 second because they deliberately pause between
  actions. These are Mac observations, not cold-start or iPad performance claims.
- A separate earthquake preview process took 0.34 seconds wall time and reported
  126,500,864 bytes maximum resident set size. This is the helper process measurement;
  it does not account for all WebKit subprocess memory and is not device memory usage.
- Per-module standalone-import sizes are in the catalog. They include shared
  dependencies and notices and must not be added together as incremental costs.

## Physical fixture smoke test on 2026-09-21

The React earthquake assets were deployed to Theater iPad as a separate test
screen at 1112×834 landscape. The fixture-only package omitted the optional USGS
connection declaration; no network grant was approved. The device reported
revision `0f8f44c0-6956-469e-a4a3-3dce9d531696` active. Prior revision history was
retained, but the deployment selected a single-screen active set.

The user reported that everything worked and confirmed that two-finger hold
opened the Screenpunk menu. This is user-reported physical smoke-test evidence,
not an instrumented device run. Swiping could not test screen switching because
only one screen was in the active set. Device OS version and per-control timing
were not recorded. This does not establish acceptance for every gallery library.

## Remaining acceptance and release work

- Multiple-screen switching, carousel gestures, reduced-motion OS behavior,
  explicit background/foreground and offline cold-launch checks, live grant
  approval, service failure and network recovery remain pending.
- Actual iPadOS 16 and macOS 14 runtime checks were not performed. Compile targets alone do not establish complete runtime compatibility.
  Catalog status explicitly records Mac verification and pending device acceptance.
- No personal service credentials were used and no production USGS connection was
  approved for a user's device. Live endpoint behavior remains a physical acceptance step.
- Supplemental license provenance, including one published gitHead no longer
  resolvable upstream, is recorded in [license provenance](../authoring/licenses/PROVENANCE.md).
- Developer ID signing/notarization, CI execution on GitHub, merge, and release
  publication were not performed. Release scripts now assemble the authoring kit,
  MCP and preview helper; local ad-hoc packaging is the evidence available here.
- No React Native runtime, native renderer, App Store/TestFlight submission or iPhone
  rollout is included.

Local candidate: `.build/react-mac/Build/Products/Debug/Screenpunk.app`.
Native screenshots: `.build/react-verification/earthquakes.png` and `gallery.png`.
