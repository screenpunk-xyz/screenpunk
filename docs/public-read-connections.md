# Public HTTPS JSON and raster connections

Contract: `public-read-http-v1`; package and bridge schema major remain `1`.
Requires updated Mac app, bundled MCP, preview helper and device app. This is a
native read-only facility. Existing Home Assistant, camera and screen-set APIs
remain available. Provider configuration belongs to screen packages, never app binaries.

## Declare

Pass a `connections` array to `update_dashboard`, or include it in a package
manifest. The exact machine-readable schema is in
[`dashboard-manifest.schema.json`](../schemas/dashboard-manifest.schema.json).
Example with only synthetic coordinates:

```json
{
  "alias": "publicData",
  "required": true,
  "publicHTTP": {
    "origin": "https://data.example.org",
    "userAgent": "Screenpunk/1 (public data reader)",
    "operations": [
      {
        "name": "timeline",
        "path": "/timeline",
        "response": "json",
        "parameters": {},
        "maxAgeSeconds": 60,
        "staleSeconds": 3600
      },
      {
        "name": "frame",
        "path": "/frames/{timestamp}/{z}/{x}/{y}.png",
        "response": "raster",
        "parameters": {
          "timestamp": {"location": "path", "minimum": 0, "maximum": 9007199254740991},
          "z": {"location": "path", "minimum": 0, "maximum": 12},
          "x": {"location": "path", "minimum": 0, "maximum": 4095},
          "y": {"location": "path", "minimum": 0, "maximum": 4095},
          "bbox": {"location": "query", "values": ["-10.25,20.5,30.25,40.5"]},
          "format": {"location": "query", "values": ["png"]}
        },
        "maxAgeSeconds": 3600,
        "staleSeconds": 86400
      }
    ]
  }
}
```

All fields shown inside an operation are required. No authentication, custom
headers or arbitrary URLs are accepted. The identifying User-Agent is native
metadata approved with the declaration. No Home Assistant credentials are read
or attached; optional authenticated providers are not part of this version.

Bounds:

- Up to 8 public connections per screen, 16 operations per connection, 12 parameters
  per operation. Public aliases cannot be `home`, or declare legacy operations,
  service calls or camera entities.
- HTTPS origin only, default port or 443, no userinfo, path, query or fragment.
  Resolved loopback, private LAN, link-local and metadata destinations are denied
  through the shared `ConnectionPolicy`. Redirects are rejected.
- Fixed path, or named `{parameter}` substitutions. No traversal, slash injection,
  percent encoding, query or fragment in path templates. Path values use letters,
  numbers, underscore, period, comma and hyphen; `.` and `..` segments are denied.
- Every declared parameter must be supplied as a string; undeclared keys are denied.
  Use either inclusive integer `minimum`/`maximum` (safe-integer range), or 1–64
  distinct `values` of 1–256 printable ASCII characters. Ranges and enums cannot mix.
  Integers must be canonical, e.g. `"1000"`, not `"01000"` or `"1e3"`.
- Query enums support fixed decimal coordinates, comma-separated bounds, image size,
  field lists, booleans and format constants. For example, `values:["640,480"]` or
  `values:["first,second"]`. A path enum can express a decimal coordinate pair such
  as `values:["12.5,-40.5"]`. Free-form decimal input is deliberately unavailable.
- `maxAgeSeconds`: 1–86400. `staleSeconds`: 0–604800, measured after max age.

## Inspect, approve, preview, deploy

```js
// After update_dashboard returns an immutable revision:
inspect_public_connections({dashboardId, revision})
// Review returned origins, paths, parameter bounds and operation response types.
approve_public_connections({dashboardId, revision, approved: true})
preview_dashboard({dashboardId, revision, live: true})
// After the owner reviews the native PNG and selects this revision:
deploy_dashboard({deviceId, dashboardId, revision, approved: true})
```

`approved:true` represents the agent's statement that the owner approved the exact
permissions. It is not a cryptographic approval. A new revision requires fresh
approval. Approval records are local controller state, not package files.
The Mac preview canvas shows the destinations and bounds with an explicit
**Allow reads for this revision** control. MCP clients can use the tools above
without bringing the workbench to the foreground. `get_help({topic:"public-connections"})`
provides the same workflow summary.

To enable JSON before raster access, put them in separate aliases and approve
only the JSON alias:

```js
approve_public_connections({dashboardId, revision, aliases: ["forecast"], approved: true})
```

Approval calls merge aliases for that same revision. Inspection returns
`approvedAliases`; `approved` is true only when all declarations are approved.
Live preview receives only approved aliases. An unapproved raster alias returns
`permission_required`; the screen should continue displaying authorized JSON.
All **required** aliases must be approved before deployment. Make a raster alias
optional when its absence should not block deployment.

Transfer uses the existing atomic `deploySet` protocol. Each screen carries its
own optional `publicReads` provisioning, checked against the transferred manifest,
screen ID and revision. Native grants are staged with the existing credential-vault
generation, bound to the paired owner, then committed with the screen set.
Capability negotiation refuses older devices before mutation. Selection, replacement,
failed staging, restart and unlink preserve the existing screen-set transaction model.
Deploying a set replaces its membership: use the Mac screen-set selector to retain
existing screens; never deploy this example over a personal screen.

## SDK

```ts
const controller = new AbortController();
const timeline = await screenpunk.connections.read("publicData", "timeline", {}, {
  signal: controller.signal
});
const frame = await screenpunk.connections.read("publicData", "frame", {
  timestamp: "1000", z: "1", x: "0", y: "0",
  bbox: "-10.25,20.5,30.25,40.5", format: "png"
}, {signal: controller.signal});
if (frame.resourceURL) image.src = frame.resourceURL;
// On disposal, after removing the image from use:
if (frame.resourceURL) screenpunk.connections.release(frame.resourceURL);
controller.abort();
```

`read` returns:

```ts
{
  state: "fresh" | "stale" | "unavailable" | "error";
  status: number;              // HTTP status, or 0 for transport/local failures
  data?: unknown;             // parsed JSON only
  resourceURL?: string;       // opaque per-WebView screenpunk://package handle
  fetchedAt?: string;         // native successful fetch time, ISO 8601
  lastModified?: string;      // raw upstream Last-Modified, if supplied
  retryAfterSeconds?: number;
  code?: string;
}
```

`lastModified` is resource modification metadata, **not** observation or forecast
valid time. Read actual validity from provider JSON/timeline fields. Request
parameters stay available to the screen, so it can label timestamped frames.
A 204/404 returns `unavailable` / `no_coverage` with no image. A valid transparent
PNG remains `fresh`: an empty frame and absent coverage are distinct. Non-2xx HTTP
responses and offline failures return a bounded-age stale value when available,
otherwise `error`. Honor `retryAfterSeconds`; do not retry in a tight loop.
Authorization and invalid parameter errors reject the promise.

Local scheduling and provider failures have different diagnostics. Native per-origin
throttling returns `status:429`, `code:"throttled"` and `retryAfterSeconds`; it does
**not** queue or automatically retry the request. An upstream HTTP 429 returns
`status:429`, `code:"http_error"`. Four already-running distinct fetches return
`status:0`, `code:"busy"` with a short retry delay. These can accompany `state:"stale"`
when usable cached data exists; otherwise the state is `error`. Serialize or space
initial same-origin calls by at least 100 ms, and honor `retryAfterSeconds` before
retrying. Simultaneous observation, hourly and daily JSON requests to the same
origin may therefore allow the first request and locally throttle the others.

`connections.request` remains compatible and returns `{value,stale}`; for public
aliases its `value` is the metadata object above. Prefer `read` for typed metadata
and cancellation. Existing service and camera results retain their old shapes.

## Runtime and retention

- Four native fetches maximum per screen runtime, sixteen pending bridge calls;
  identical in-flight requests share a fetch. Cancellation removes a waiter and
  cancels the shared request when no waiter remains.
- At least 100 ms between distinct starts to one origin. HTTP failures use bounded
  exponential backoff; Retry-After seconds and HTTP dates are honored up to one hour.
  No command writes or background retry loops are introduced.
- Complete cache identity includes immutable scope/declarations, alias, operation
  and all parameters, including timestamps. Fresh cached replay makes no network call.
- Cache: 96 entries / 24 MiB encoded bytes. Resource leases: 64 images / 24 MiB /
  16,777,216 total pixels. Oldest resources may be evicted under pressure: keep a
  bounded animation window and request a frame again if a handle no longer loads.
  Repeated identical resources share bytes and use reference-counted release.
- Per response: JSON 1 MiB; raster 4 MiB, 4096 pixels per side and 4,194,304 total
  pixels. PNG/JPEG MIME, signature and ImageIO decode are required; animated images,
  SVG, HTML and mismatches are denied. Normal TLS verification, no redirects/cookies.
- Memory-only retention; **zero disk retention**, so offline replay lasts only for
  the active runtime. Leaving a screen, changing revision, WebView termination or
  unlink cancels work and invalidates resources. Re-entering a screen creates a new
  runtime. No global remote, data or blob image permission is added; CSP stays unchanged.

## Synthetic example and native preview verification

[`examples/public-read-animation`](../examples/public-read-animation) uses only
`data.example.org`, synthetic feed-discovered filenames and generated circle frames.
It demonstrates JSON, two raster frames, local-handle playback, stale handling,
abort and cleanup. It is not a weather dashboard or a real provider configuration.

Regenerate after an SDK change:

```sh
npm --prefix sdk run bundle
node --import ./sdk/node_modules/tsx/dist/loader.mjs sdk/scripts/build-public-read-example.ts
```

The debug preview helper has a test-only `SCREENPUNK_PUBLIC_READ_FIXTURE=1` native
transport for this exact synthetic host. Release builds omit it. Supply the approved
`NativePreviewConnections` envelope on stdin, set `SCREENPUNK_PREVIEW_LIVE=1` and
`SCREENPUNK_PACKAGE_DIR`, and run the helper. It emits a real `SNAPSHOT_OK` PNG only
after both images decode and the timeline refresh returns a stale cached value.
No public-provider requests, personal coordinates or installed-device changes are
needed for this check. Passing it is preview evidence, not physical-iPad evidence.

### Device-sized packages

The Mac workbench prepares a new revision for a device viewport. The controller carries existing source approval to that revision only when it loads the exact saved source identity, creates the prepared package itself, and verifies identical file bytes and manifest fields except target, revision and digest. Only previously approved aliases carry forward. Edits, duplicate dashboard identities, altered declarations and independently prepared revisions require their own approval. Device deployment still checks all required aliases.

## Dynamic raster filenames

Updated hosts support `public-read-dynamic-path-v1` in addition to
`public-read-http-v1`. A raster operation can opt into a bounded, single path
segment whose value changes after a JSON feed is read:

```json
{
  "name": "photo",
  "path": "/uploads/{year}/{month}/{filename}",
  "response": "raster",
  "parameters": {
    "year": {"location": "path", "minimum": 2020, "maximum": 2099},
    "month": {"location": "path", "values": ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12"]},
    "filename": {"location": "path", "pathSegment": {"maxLength": 128}}
  },
  "maxAgeSeconds": 3600,
  "staleSeconds": 86400
}
```

Put this operation in a `publicHTTP` declaration with one approved HTTPS origin.
`pathSegment` is mutually exclusive with integer bounds and `values`, is allowed
only in raster path parameters, and requires `maxLength` from 1 to 256 bytes.
Values begin with an ASCII letter, digit or underscore; subsequent characters
may also be period, tilde or hyphen. Whitespace, Unicode, percent encoding,
slashes, backslashes, queries, fragments and dot segments are rejected. The
resolved path is limited to 512 bytes, and the template must begin with a literal
(non-parameterized) top-level directory. Every declared parameter remains required.
For directories with dynamic names, use a separate bounded `pathSegment` parameter,
for example `/image/{asset}/{filename}`. Use separate aliases and approvals for
separate origins. There is no wildcard origin, arbitrary URL or recursive path rule.

The approval covers all matching segment values under that template, not just the
first observed filename. The runtime does not claim to verify that a filename
actually appeared in a feed. Screens can validate/extract provider URLs, but native
validation independently restricts each resulting request. Do not decode or pass a
full URL into a segment; skip URLs that do not match the approved origin/template.
For example, for an approved `https://images.example.org/uploads/...` connection:

```js
const raw = feedItem.imageURL;
const match = /^https:\/\/images\.example\.org\/uploads\/(\d{4})\/(\d{2})\/([A-Za-z0-9_][A-Za-z0-9_.~-]*)$/.exec(raw);
if (match) {
  const result = await screenpunk.connections.read("photos", "photo", {
    year: match[1], month: match[2], filename: match[3]
  });
  if (result.resourceURL) {
    image.src = result.resourceURL;
    // When this image is removed from use:
    // screenpunk.connections.release(result.resourceURL);
  }
}
```

No per-filename package revision or reapproval is needed. Changing the origin,
template, segment bound, or screen revision requires approval as before. Older
devices are refused before transfer unless they advertise the new capability;
existing integer and enum declarations continue to use only the original capability.
Older Mac/preview builds reject the new rule rather than treating it as unrestricted.
The SDK read/release API and native raster handles are unchanged. DNS restrictions,
redirect denial, MIME/signature/ImageIO checks, byte/pixel/cache limits and
cancellation all still apply. A newly discovered provider image above the existing
4 MiB / 4096-per-side / 4,194,304-pixel limit is rejected; choose a provider-supplied
smaller rendition within the same declared bounds when available.

The synthetic `public-read-animation` example now reads two changing filenames
from its fixture JSON feed. The debug native preview decodes both through native
resource handles without allowing direct WebView networking.

Run the rendering regression with a **Debug** preview helper:

```sh
python3 scripts/check-dynamic-raster-preview.py /path/to/ScreenpunkPreviewHost.app/Contents/MacOS/ScreenpunkPreviewHost
```

It verifies two decoded frames, a native raster image source, stale-cache replay,
and a real PNG snapshot using only the synthetic transport.
