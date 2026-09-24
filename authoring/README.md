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
