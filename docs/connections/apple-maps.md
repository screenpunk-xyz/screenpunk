# Apple Maps previews

The Apple native runtime supports address-only static previews on macOS and
independently on iOS/iPadOS 16+. It uses CLGeocoder and MKMapSnapshotter on the
executing device. No Mac proxy, account, API key, device location permission,
external iframe, or screen network permission is needed.

## Manifest and approval

Declare exactly this optional connection (existing schema v1):

```json
{"alias":"appleMaps","required":false,"operations":[{"name":"snapshot","kind":"http"}]}
```

`http` identifies a one-shot connection operation in the existing protocol; it
does not grant HTTP access. No publicHTTP, cameraEntities, or serviceCalls may
accompany it. Only the operations documented here are supported. Subscriptions, URLs,
coordinates, headers, and unknown parameters are rejected. Devices advertise `apple-maps-v1`; the Mac
rejects screen-set deployments needing it to older devices before mutation.
The screen can detect `appleMaps: 1` in runtime status.

Before any geocoding, a visible native host asks whether this screen revision
may send supplied addresses to Apple. Approval is local to that device and
revision. The first request returns `permission_required`; after Allow, the
user retries the preview. Do not loop on permission errors or auto-retry a
refusal. A changed revision requires approval again. Approvals contain only a
hashed dashboard/revision identifier, never the address.

On Mac, approve from the visible authoring canvas first. The hidden preview
helper shares the Mac map approval preferences and cannot present a hidden
approval dialog. An unapproved hidden preview returns `permission_required`.
Offline/document previews do not perform map requests.

## Screen API

Use the existing cancellable raster connection API, with string parameters:

```js
const abort = new AbortController();
let resourceURL;
let closed = false;
try {
  const result = await screenpunk.connections.read("appleMaps", "snapshot", {
    address: "5 Avenue Anatole France, 75007 Paris, France",
    width: "640",
    height: "360"
  }, { signal: abort.signal });
  if (closed) {
    if (result.resourceURL) screenpunk.connections.release(result.resourceURL);
  } else if (result.state === "fresh") {
    resourceURL = result.resourceURL;
    image.src = resourceURL;
    image.alt = "Map of the supplied event address";
  } else if (result.code === "ambiguous") {
    showMessage("Please provide a more specific street address.");
  } else {
    showMessage("No map was found for this address.");
  }
} catch (error) {
  if (!closed && error.name !== "AbortError") showMessage("Map unavailable. You can retry.");
}
// On modal close: abort pending work, clear the image, release its raster lease.
function closeMap() {
  closed = true;
  abort.abort();
  image.removeAttribute("src");
  if (resourceURL) screenpunk.connections.release(resourceURL);
}
```

Guard against the modal closing between request completion and image assignment
in a real UI. Show a loading state while pending and retain the event's textual
address on all failures. Do not obscure/crop the map or its Apple Maps label.

- `address`: trimmed, 1–512 UTF-8 bytes; no embedded control characters or URL.
- `width`: optional integer string, 160–1024; default 640.
- `height`: optional integer string, 120–768; default 360 (map area).
- Output includes a red location marker and an additional 24-point attribution
  strip; macOS backing scale may yield a higher pixel density.
- `fresh`, `code: ready`: `resourceURL` is a per-WebView opaque PNG lease.
- `unavailable`, `code: not_found`: no geocoding match.
- `unavailable`, `code: ambiguous`: multiple matches or only an area-level match
  without a street. No candidates or guessed coordinates are returned.
- Errors: `permission_required`, `validation_failed`, `size_limit` (busy/rate
  limit), `device_offline` (Apple service/network/cancelled deadline failure).

One map request may run per WebView, with at least two seconds between starts.
Native work is cancelled after 12 seconds, on AbortSignal, document replacement,
or screen deactivation. Results from replaced documents are discarded. Raster
bytes and leases use the existing bounded memory-only resource store (4 MiB per
image, aggregate 24 MiB/16,777,216 pixels/64 assets). No screen disk cache or
address logging is added. App upgrades preserve existing device data and Calendar
credentials; the feature does not modify them.

## Verification

`swift test --package-path packages/ScreenpunkApple --filter MapPreview` checks
parameter and manifest boundaries. Setting `SCREENPUNK_TEST_LIVE_MAPS=1` opts
into a real public-address geocode/snapshot test and raster lease/release check;
its sanitized image is written to `/tmp/screenpunk-map-smoke.png`. The existing
PublicReadRuntime tests cover raster validation, lease isolation and revocation.
No personal calendar fixtures are used.

## Interactive native surface (build 2026092804+)

Runtime status `appleMapsInteractive: 1` and device capability
`apple-maps-interactive-v1` advertise native pan/pinch-zoom support. Screen-set
deployment checks this capability when interactive operations are declared.
Keep `snapshot` declared for static fallback; declare all four operations:

```json
{"alias":"appleMaps","required":false,"operations":[
  {"name":"snapshot","kind":"http"},
  {"name":"present","kind":"http"},
  {"name":"update","kind":"http"},
  {"name":"close","kind":"http"}
]}
```

Use `screenpunk.connections.request` for interactive operations (not `read`).
Each resolves to the usual `{value, stale}` envelope; `value.state` is one of
`loading`, `ready`, `not_found`, `ambiguous`, `failed`, or `stopped`.

| Operation | String parameters | Behavior |
| --- | --- | --- |
| `present` | `id`, `address`, `rect` | Approve and resolve a supplied address, then mount one native MKMapView. Returns `loading` immediately. Repeating the same ID/address preserves the map. |
| `update` | `id`, `rect` | Update layout and return current state. Does not geocode, recenter, or reset user pan/zoom. |
| `close` | `id` | Cancel pending geocoding and remove that native surface. Idempotent. |

`id` must match `[A-Za-z0-9_-]{1,128}`. Use a new unique ID for each modal
lifetime. Only one interactive map is allowed per WebView; presenting a different
ID or address replaces it, at most once every two seconds. Approval and address
validation match snapshots. No URL, coordinate, map style, credential or network
options are accepted. The native **Open in Maps** button opens the originally
resolved destination through MapKit when the user taps that button. There is no
JavaScript `open` operation; a tap/drag elsewhere on the map remains native map
interaction. Device location access stays disabled.

`rect` is a JSON-encoded object with exactly these numeric fields:

```js
JSON.stringify({
  x: bounds.left, y: bounds.top,
  width: bounds.width, height: bounds.height,
  viewportWidth: document.documentElement.clientWidth,
  radius: 16, visible: 1
})
```

Coordinates are viewport-relative CSS pixels from `getBoundingClientRect()`.
Native code scales them to WebView points, including Mac authoring zoom. Values
must be finite and bounded by 10,000 in magnitude, dimensions 0–2048, positive
viewportWidth, radius 0–64, and visible exactly 0 or 1. A visible map needs at
least 160×120 CSS pixels. Native clipping rounds the **entire** map to `radius`;
CSS `border-radius` alone cannot clip this native surface. Apple map attribution
remains visible. A partly off-WebView, undersized or invisible rectangle hides
the surface without discarding its pan/zoom; a valid update restores it.

### Mounting and modal lifecycle

1. Reserve an empty rectangular DOM element in the modal's right column. Keep
   essential controls and text outside it: native views render above the DOM.
2. Call `present` once with its address/rectangle. A first-use native prompt
   returns `permission_required`; offer an explicit retry after Allow. Do not
   automatically retry refused permission.
3. While mounted, call `update` whenever its rectangle changes, plus a heartbeat
   at least once a second. Polling `update` reports geocode/map failures. Coalesce
   geometry changes with requestAnimationFrame and keep only one update request
   in flight. Layout updates must **not** call `present` with a new ID.
4. Observe element resize, window resize, viewport changes and **captured** scroll
   events so nested modal scrolling updates the map. Check ancestor clipping:
   if any overflow-hidden/auto/scroll ancestor partially clips the anchor, send
   `visible: 0` until the whole anchor is visible again. Also hide when display,
   visibility, opacity, document visibility or another modal occludes it. Native
   code cannot infer arbitrary DOM occlusion or CSS ancestor clipping. Avoid
   rotation/skew transforms on the anchor.
5. Call `close` immediately on modal close, event change, tab change, anchor
   removal, pagehide, or disposal. Stop observers/RAF/timers and ignore any late
   result from the old modal. Send `visible: 0` during dismissal animations if
   cleanup is not immediate. Do not leave an overlay covering another dialog.

A minimal invocation sequence (the screen supplies the lifecycle/geometry loop):

```js
const id = `map-${crypto.randomUUID()}`;
const request = (operation, parameters) =>
  screenpunk.connections.request('appleMaps', operation, {id, ...parameters});
await request('present', {address: event.location, rect: measureMapRectangle()});
// Each geometry change / heartbeat:
const {value} = await request('update', {rect: measureMapRectangle()});
// Closing this modal also cancels its pending geocode:
await request('close', {});
```

The native surface owns pan and pinch gestures within its rectangle; scroll the
modal using the surrounding content. Two-finger screen switching yields to
MapKit for touches inside the map. Updates retain the user's map region.
Without a heartbeat for three seconds, or when the screen/document becomes
inactive, iOS enters the background, or the Mac app is hidden, native code closes the map. After returning to the foreground, use a
new modal/map lifecycle to present it again. Geocoding has a 12-second deadline;
network/geocode/map-loading failures report `failed` without returning a guessed
location. Area-only and multiple geocoding matches report `ambiguous`.

Hidden/headless Mac preview cannot host an interactive map and returns `stopped`.
Use `snapshot` for hidden previews, raster captures, or when the interactive
capability is absent. Retain the address text and a retry option on all failures.

## Native tap expansion and optional location — build 2026092805+

Runtime status advertises `appleMapsTap: 1` and `appleMapsLocation: 1`.
The same declared `present/update/close` operations apply; no subscription or
additional manifest operation is needed.

An embedded native map emits a **window** CustomEvent named
`screenpunk:appleMapsTap`, with exactly `detail: { id: "your-map-id" }`.
Listen before presenting, match the current unique map ID, and ignore events
from a closed modal. Native single-click/tap recognition waits for double-tap
failure, allows MapKit gestures simultaneously, and cancels pending delivery
on region changes, hiding, closing, or native control activation. Annotation
views, controls, and a narrow edge/attribution margin do not trigger expansion.
Native pan, pinch, and double-tap zoom remain available. The event is delayed
briefly to distinguish gestures; it carries no coordinate or address.
This is a UI notification, not an authorization signal (`isTrusted` is false).

`present` and `update` now accept an optional string `mode`: `"embedded"`
(default) or `"fullscreen"`. Fullscreen bounds must be at least 320×240 CSS
pixels and still obey all existing bounds/visibility restrictions. Pass mode
on **every** update, including heartbeat updates. Omission means embedded.

```js
let expanded = false;
const onMapTap = (event) => {
  if (closed || event.detail?.id !== mapId || expanded) return;
  expanded = true;
  renderExpandedLayout(); // Keep a DOM Close/Back control outside native bounds.
  syncMapBounds();
};
window.addEventListener("screenpunk:appleMapsTap", onMapTap);

async function syncMapBounds() {
  // Use the existing coalesced, one-in-flight geometry updater.
  await screenpunk.connections.request("appleMaps", "update", {
    id: mapId,
    rect: JSON.stringify(boundsForCurrentLayout()),
    mode: expanded ? "fullscreen" : "embedded"
  });
}
function collapseMap() {
  expanded = false;
  renderEmbeddedLayout();
  syncMapBounds();
}
// On modal disposal: remove listener, cancel pending updates, then close map.
// window.removeEventListener("screenpunk:appleMapsTap", onMapTap);
```

Expand/collapse by updating the rectangle and mode with the **same map ID**.
Do not close/re-present or change ID/address for this transition. The native
MKMapView and user-adjusted camera are retained; fitting the new viewport may
change its aspect ratio. Fullscreen map taps do not emit expansion events.
Keep the existing one-second heartbeat, clipping checks, and stale-reply guards.

Fullscreen mode exposes a native **Show my location** button alongside the
existing **Open in Maps** button. Merely entering fullscreen never requests
permission or enables location. Only pressing the native location button
requests OS When In Use authorization. Screen JavaScript cannot request
permission, turn location on, query permission state, or read coordinates.
No Always/background authorization or background location mode is added.

If authorized, the native map shows the current-position marker and initially
fits it with the destination. Subsequent updates preserve user panning. The
button becomes **Hide my location**. Denial, restriction, failure, or a
15-second fix timeout leaves the destination map usable and shows **Location
unavailable**; pressing again can retry if OS settings later change. There is
no settings deep link or automatic permission retry. Approximate OS location
is accepted; no precise-location upgrade is requested.

Collapsing, hiding/clipping, closing, heartbeat expiry, or document replacement
stops user-location display and updates. App inactivity suspends updates;
foreground return may resume a still-open, opted-in fullscreen session.
Backgrounding closes the map. Re-entering fullscreen after collapse requires
another native button press even when the OS already granted permission.
Coordinates stay in native MapKit memory and are never bridged, logged, or
persisted by Screenpunk. The hidden preview helper cannot show these controls
or request location. OS permission prompts must be answered by the user.

Usage descriptions follow Apple's [location authorization documentation](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services):
`NSLocationWhenInUseUsageDescription` on iOS and `NSLocationUsageDescription`
on macOS. The runtime calls only `requestWhenInUseAuthorization()`.
