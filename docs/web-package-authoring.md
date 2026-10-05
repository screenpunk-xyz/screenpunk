# Package-local CSS and JavaScript

The native host sends a fixed Content Security Policy containing
`script-src 'self'` and `style-src 'self'`. Author CSS and executable JavaScript
as package files and reference them from HTML:

```html
<link rel="stylesheet" href="styles.css">
<script src="app.js"></script>
```

Include both files in the package. Use classes for styling and `addEventListener`
in `app.js` for event handlers. Inline `<style>`, HTML style attributes, executable
inline `<script>` and inline event handlers are blocked. Inert JSON script data
is different from executable code. Native SDK injection does not grant package
inline code permission. A meta CSP cannot relax the host response header.

Use exact-case relative asset paths without query strings or fragments. Remote
CDNs, `file:` and `data:` URLs are not package assets. Bundle fonts, images and
dependencies locally. React builds emit `screen.css` and `screen.js`; retain CSS
imports and use compiled module code. Do not edit a retained published kit.
See [the plain web example](../examples/local-web-package/index.html).

## Inspect through the shipped broker

Read `tools/list` and use its current schemas. The 1.0.7 broker provides:

- `get_workspace_package({dashboardId, revision})` for the exact immutable
  built package summary.
- `get_workspace_package_file({dashboardId, revision, path: "", offset: 0})`
  for its manifest. Empty path explicitly selects the manifest.
- The same file tool with each manifest member path for HTML/CSS/JS bytes.
  Decode base64, retain offset/totalBytes/SHA256 and fetch subsequent chunks
  until complete. Verify the final file hash; do not combine changing identities.
- `inspect_workspace_project({projectId})` for included source inventory and
  sourceVersion; `get_workspace_source_file({projectId, path,
  expectedSourceVersion, offset: 0})` for bounded source chunks.
- `get_workspace_build({projectId})` for the current built revision and source
  version. Source and built revisions are different identities.

Target-specific Prepared history is distinct from ordinary Packages history.
Use the retained prepare/plan evidence to correlate it; never substitute an
unrelated built revision. Readiness, installed/selected acknowledgment and
cached paired devices do not prove CSS loaded, code ran or device rendering
succeeded. Preserve the actual WebKit console error and a visual observation.

## Repair through the shipped broker

Preserve existing source and package evidence first. If the exact HTML contains
inline CSS/JS that the host blocks, move those same bytes to bundled files, update
the HTML references and replace inline handlers with listeners. Preserve design,
target, connections, screen settings and navigation; avoid speculative redesign.

For a contained plain web project, patch the actual included source members:

```json
{
  "projectId": "<project ID>",
  "expectedSourceVersion": "<current 64-character source hash>",
  "changes": [
    {"path": "web/index.html", "bytesBase64": "<canonical base64>"},
    {"path": "web/styles.css", "bytesBase64": "<canonical base64>"},
    {"path": "web/app.js", "bytesBase64": "<canonical base64>"}
  ]
}
```

Send this to `patch_workspace_project`. Max 16 changed members and 5 MiB per
file; source compare-and-swap, included paths and project quota remain enforced.
For React, patch the actual included `.tsx`/CSS members instead. Do not guess a
path from this example. Web builds strip the `web/` prefix into package members.

Call `run_workspace_build` with projectId, the **new** expectedSourceVersion
returned by patching, and current built baseRevision. Read the new immutable
package and call `validate_dashboard` for that exact revision. New authoring
checks report incompatible inline content and reject it before publication or
preparation; these checks are diagnostics, not a complete HTML sanitizer.
They do not prove linked assets exist or JavaScript runs without errors.
Runtime CSP remains the enforcement boundary.

If the broker reports `preview_required`, its compatible native helper is
unavailable; preserve that result and use the supported review route. Never
fabricate a successful preview. When preview is available, visually inspect the
exact revision. Live previews can control approved devices.

Use `prepare_deployment`, `plan_deployment`, `review_deployment`, then relay
matching human approval through `apply_deployment` for the exact reviewed plan.
Changed bytes require a new review and approval. The previous plan's approval
does not authorize a changed package; MCP does not need a terminal APPROVE step.

The old standalone-router tool names `update_dashboard`, `update_screen_project`
and `build_screen_project` are not a fallback for missing broker capabilities.
Do not edit immutable package history, installation receipts or runtime policy.

## Diagnose the observed failure

Inline deployed content plus matching console CSP refusals establishes an
authoring/policy incompatibility. Bundled content plus missing asset requests
points to package/path/serving failure. Successfully loaded code with an actual
exception points to a script/runtime issue. Source policy alone does not prove
the behavior of an unknown device app build.

Reference: [CSP script-src](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/script-src)
and [CSP style-src](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/style-src).
