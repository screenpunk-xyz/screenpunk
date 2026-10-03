# React screen authoring

React screens are ordinary schema-1 web packages. They use the same native grants,
validator, previews and device deployment as HTML/JavaScript screens. No React
Native renderer, CDN, development server or device-side Node runtime is included.

## Installed Mac workflow

The authoring-enabled Mac app includes Node, TypeScript, esbuild and local dependencies.
Read `screenpunk://authoring/catalog` for pinned versions and verification status.

1. `create_screen_project` with `starter: "earthquakes"` or `"gallery"`.
2. `get_screen_project` with the project ID and optional `paths` to read source.
3. `update_screen_project` with `projectId`, returned `sourceVersion`, and `files`
   entries containing `path` and `text`/`base64`, or `delete: true`.
4. `build_screen_project` with the current `sourceVersion`. After the first build,
   also pass the current dashboard `baseRevision` from `get_dashboard`.
5. Use `validate_dashboard`, then `preview_dashboard` for that exact revision.
6. Inspect and approve the public connection declaration before live reads. The
   earthquake starter defaults to synthetic fixtures and never treats fixtures as live data.
7. Deploy the previewed revision through the existing deployment approval workflow.

Source files live outside the app, in the controller's authoring/projects store.
Reveal Source supports external editors; reread the source version before building.
Build failures keep the previous valid dashboard. Builds snapshot source and reject
concurrent changes. Each project pins kit version 1.0.0. Kits are retained locally;
missing versions fail explicitly. To upgrade, create a new project with the desired
kit and migrate/review source explicitly. Never modify an existing published kit.

The Mac Screens menu includes React Screen and Component Gallery. Source and Rebuild
are available on project screen context menus. Preview and device controls are unchanged.

## Developer checkout

From the repository root, with Node 24:

```
npm --prefix authoring ci --ignore-scripts
npm --prefix authoring run build
npm --prefix authoring run gallery
npm --prefix authoring test
```

Output is in authoring/dist/{earthquakes,gallery}. The build emits assets, not an
invented device manifest: the controller assigns hashes, revisions and digests.
For MCP development, generate the kit and set SCREENPUNK_AUTHORING_KIT to its path.
The kit command requires SCREENPUNK_NODE_ARCHIVE pointing at the exact archive in
toolchain.json and verifies SHA-256. Release packaging uses scripts/bundle-authoring.sh.

## Component imports

Import hooks from `@screenpunk/react`, and controls from `@screenpunk/ui`.
The UI module exports Card, Button, Input, TabGroup, InfoDialog, Choice, TrendChart,
DataTable, Carousel, Reveal and selected Lucide icons. UI CSS is automatically emitted.
The catalog includes examples. Only used output and dependencies enter each package.
Plain JavaScript authors may copy ui/theme.css and icons/*.svg; React controls require React.

All source imports must remain in the project or kit. New npm dependencies, build
plugins and lifecycle scripts are not supported by the managed pipeline. No secrets
belong in source. Calls go through the host SDK; direct browser networking is blocked.
Runtime code splitting, server routes and server rendering are not supported.

## Compatibility

Targets iPadOS 16.0 / macOS 14. Components use static CSS instead of Tailwind v4
requirements. Radix overlay behavior and charts must be checked under native WebKit;
check catalog status and docs/react-authoring-verification.md before claiming support.
Native app builds remain necessary to test the runtime active status on devices.


## Compiler input and runtime boundary

`buildProject(source, output)` and the CLI keep the existing result (`bytes`, `files`, `dependencies`) and package format. Node >=24.11.1 <25 remains supported on macOS and Linux. The exact official esbuild-wasm0.28.2 dependency is locked; browser, WASM, TypeScript bootstrap and approved kit configuration hashes are checked before compiler use. Kit assembly includes tsconfig.json, the WASM dependency and its MIT notice, verifies these pins and qualifies its manifest metadata capacity.

Compilation captures regular project files and a fixed locked dependency catalog once, then runs TypeScript and the unchanged maintained esbuild resolver/linker in sequential child processes. Only manifest-addressed captured bytes reach compiler hosts. No caller tsconfig/jsconfig, shell hook, plugin, package URL or command executes. Only the approved kit tsconfig is exposed to esbuild configuration discovery; no global strict directive or hand-written package resolver is used. Package exports, browser mappings and mixed module/main coalescing remain upstream behavior. The pinned Radix Select static stylesheet adapter reads captured bytes through the same boundary, including CSS imports and URL assets.

Source remains bounded at2000 regular files/50MiB total; the separate existing Mac preprocessing per-file bounds are unchanged. A symlink at the selected final project root entry is rejected. Caller-selected parent aliases may resolve (including Darwin /var/folders); canonical root dev/inode/type is bound to the original directory and revalidated before capture. Internal source symlinks, special files, paths longer than4096 UTF8 bytes, source mutations and visible path replacement are rejected. The trusted catalog remains bounded at100000 files/512MiB of captured content. Runtime compiler bootstrap bytes are separately fixed trusted assets. Captured data and successful output have independent allowances; output remains2000 files/50MiB.

Captured backing is private temporary state under the launcher's operator-controlled OS temporary location (`os.tmpdir()`), separate from the output stage and never inventoried as an emitted asset. Deployment may set a fixed supervisor TMPDIR to its separate capture mount; child environments do not inherit TMPDIR. The packed backing needs at most562MiB (512MiB trusted +50MiB source), plus an independently bounded64MiB streamed manifest and filesystem overhead. Each path is at most4096 UTF8 bytes; an escaped JSON record is bounded at24832 bytes. Reserving2000 source records plus a64KiB header leaves17,379,328 bytes for qualified kit metadata. Assembly and capture reject a kit installation/catalog exceeding that metadata quota; captured-content/source entitlements are not reduced. Both descriptor passes hash the exact manifest bytes before any inventory capability is returned. Record shape, UTF8, counts, byte totals, contiguous offsets and captured inode/size/content hashes are checked. The manifest is never allocated as one buffer.

A proposed private capture mount of640MiB plus the existing64MiB output and32MiB general temporary mounts has capacity for these independent limits; this public implementation does not change the private harness. Tmpfs/cache/process memory is charged on demand within the outer cgroup, and filesystem capacity does not guarantee worst-case CPU or memory viability.

The supervisor uses a120-second monotonic publication-commit deadline covering initial work, snapshot, typecheck, bundle, notices, output inventory and replacement. Checks before and after awaited filesystem operations prevent an observed late rename from committing successfully; the previous output is restored before rejection. Captured-state cleanup finishes before publication. All phase exits and stdio/IPC closure are awaited, including spawn errors and forced kills. Stage ownership ends immediately after successful rename; rollback uses the published output state. Remaining cleanup failures are collected with the original failure preserved as cause rather than masked. Kernel filesystem calls cannot be cancelled by a JavaScript timer. Owned rollback/final cleanup is awaited and may extend response time beyond120 seconds; the operator's separate170-second whole-process/container kill is the ultimate bound. After an on-time irreversible commit, backup-cleanup failure is explicitly reported as committed cleanup failure; it is not described as preserving the old output.

Only the fixed bundling child starts without `--jitless` to enable the exact trusted WASM compiler; snapshot and typecheck retain `--jitless`. The public supervisor preserves its launch flags; deployment must launch it with `--jitless` as in the reviewed candidate profile. Every child starts with fixed SP_PHASE/TZ=UTC/LANG=C.UTF-8/UV_USE_IO_URING=0 and rejects extra, missing or changed values. Darwin also receives and checks `__CF_USER_TEXT_ENCODING=0xUID:0x0:0x0`, with UID derived from the trusted running process, never ambient encoding. Node24.11.1 and24.21.0 exact-startup controls passed on the qualified Darwin host. The explicit UV value suppresses libuv filesystem SQPOLL; it does not promise all io_uring is disabled. Published [CoreFoundation source](https://api.github.com/repos/apple-oss-distributions/CF/git/blobs/876e204ed8dfdd782a1eddcf4deffec72eb72d11) provides the UID-prefixed encoding rationale, not proof of the current macOS binary. No inherited NODE_OPTIONS, caller executable or dynamic compiler option exists.

The WASM runtime receives an inventory-only filesystem, synthetic metadata, readonly descriptors and bounded128MiB protocol input/output. Controller packets have closed shapes and bounded counts/bytes; diagnostics are capped at20 messages/16000 characters. stdin/stdout descriptors remain separate from captured file descriptors. The compiler VM receives no Node module loader or network/native filesystem capability. The adapter relies on the pinned upstream Go/browser syscall interface; dependency updates require regression qualification.

These JavaScript guards are not a kernel filesystem sandbox. The VM is capability shaping for trusted compiler code, not isolation for hostile JavaScript; source is parsed, never executed during compilation. Permissions0400/0700 are not same-UID isolation, and portable Node path checks cannot promise elimination of all malicious concurrent ancestor races. Operator-installed kit/bootstrap must remain immutable. Cloud activation still requires readonly/nonroot/no-network process isolation, CPU/RSS/PID/deadline enforcement and the external sandbox qualification. Earlier arm64-host/amd64-guest timing is emulated feasibility evidence, not native cloud sizing or production cost acceptance.
