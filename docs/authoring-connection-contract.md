# Screen connection declaration contract

Native Settings discovers a provider from the installed manifest's `connections`.
Calling its JavaScript API is not a declaration. A previously configured native
host can also make Settings visible; its visibility is not evidence that an older
screen declared the connection. The individual Google TV package/version
comparison is owned separately from this change.

The MCP initialize instructions and source-save tool describe the supported
native aliases (`home`, `googleTV`, `googleCalendar`, `appleMaps`), public-read
requirements, optional versus required setup, and preservation across edits.
`googleTV` needs `{ "alias": "googleTV", "required": false }`; optional still
means declared. Runtime flags are not a manifest `capabilities` field. Native
schema/semantic validation continues to govern provider-specific fields.

## Validation placement

- Browser compilation checks the captured source program before bundling.
- Cloud repository check-in, controller import and controller archive retrieval
  check executable package files independently of the client. The pinned transport
  codec remains unchanged; these gates run on its verified snapshot. This is the authoritative cloud gate
  for recognized executable calls, not a trusted-client receipt.
- Client check-in also compares the full connections value from strict source
  metadata with the validated package, then scans submitted source against those
  declarations. A disagreement fails before source publication. It never merges
  old metadata silently or uses saved device permissions as declarations.
- The companion native authoring change checks the captured local React program
  before output publication and teaches the same contract through MCP help and
  the shipped authoring README. Old installed authoring kits are immutable and
  do not gain checks until a separately qualified kit/app update. Local raw web
  packages use the app-owned package validator described below. Raw packages
  reaching Cloud are independently checked there.

The AST checker recognizes injected `screenpunk`, `window.screenpunk`,
`globalThis.screenpunk`, optional and literal bracket access, immutable local
client/method aliases, and imported `useScreenpunk`, `usePublicRead` and
`useConnectionSubscription`. Literal connection calls require their exact alias;
Home Assistant convenience service/camera calls require `home`. Comments,
strings, ordinary local objects, state and audio APIs do not create requirements.
It does not infer provider operations, entity targets, or permissions from code.

Computed aliases, destructuring, mutable aliases, custom wrappers/factories,
runtime code generation and arbitrary interprocedural data flow are outside the
check. Minification can rewrite a recognizable const alias to a mutable variable;
checking both source and package reduces this gap but cannot prove arbitrary JS.
Passing validation is not proof that every runtime path was analyzed, or that a
provider is paired/authorized. Do not replace native runtime enforcement.

Server parsing uses the existing authoring TypeScript 5.9.3 version under a
separate runtime alias, leaving the root TypeScript toolchain version unchanged. The typecheck command
selects that root binary explicitly because npm aliases also expose tsc binaries.
It executes no screen code and has no filesystem resolver. Each scan is isolated
in a worker, limited to 5 MiB total executable JavaScript and HTML bytes, 256 MiB old-generation heap and
five seconds; failure is actionable and does not publish. This introduces a
narrower script-analysis bound than the archive's total transport budget.

The AST module is byte-identical to the companion native authoring module.
Keep its test cases synchronized when extending recognition; pinned vendored
SDK/authoring sources and release qualification hashes are intentionally unchanged.

## Rollout

The cloud patch is stacked on the existing conversational MCP workflow. A merge
to main may trigger the repository's staging deployment workflow; the parent
must resolve that approval coupling before merging. This task does not merge,
deploy, update release pins, install packages on devices, or change pairings.

The new runtime parser changes package-lock.json. Linux materializer/native
assembly pins that lock; qualification is blocked until a separately authorized
lock-pin update. No pin is updated by this patch.

## App-owned plain-web package validation

The companion native implementation now validates captured plain-web package
files and legacy decoded package writes before publication using an app-owned
validation-only Node/parser closure. No separate authoring kit is required.
Existing native HTML/CSP compatibility checks and runtime permissions remain.
Cloud and native share byte-identical HTML5 extraction logic using parse5 7.3.0
and the existing shared AST checker. Supported inline JS script bodies are parsed,
never executed; HTML comments, attributes and data script types are not treated
as JS. Event attributes, javascript: URLs, nonstandard legacy MIME aliases and
dynamic patterns remain outside analysis. Native CSP continues to reject inline
scripts independently; this checker does not make those packages installable.

The helper packaging scripts emit measured assets, licenses and SBOM; release
signing/installation and accepted qualification pin updates remain separate.
Executable JS plus HTML is limited to 5 MiB; inline extraction including location
padding to 10 MiB, at most 512 scripts per package. Native subprocess limits are
256 MiB old-generation heap, 1 MiB stack, 5 seconds and 2 concurrent processes.
