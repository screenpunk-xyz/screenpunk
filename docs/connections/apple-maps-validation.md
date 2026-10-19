# Apple Maps local validation — 2026-09-28

Implementation and local development installs: Screenpunk 0.2.0 (2026092802).
These are local builds, not a public release or TestFlight upload.

- Mac application, native preview helper, and signed iOS application built
  successfully with Xcode. Mac app signature verified after a clean bundle
  replacement; a rollback app copy remains at
  `/tmp/Screenpunk-before-maps-2026092802.app`.
- A real Apple geocode and MapKit snapshot of a public Paris street address
  succeeded on Mac. The PNG was inspected: correct area, marker and complete map,
  plus Apple Maps attribution. No private calendar data was used.
- 26 focused Apple tests: 25 passed, 1 opt-in live-network test skipped in the
  final offline run. The live test passed separately. Coverage includes the
  actual hidden WKWebView/bundled SDK permission response, parameter/manifest
  bounds, raster isolation/release/revocation, and Google Calendar regressions.
- 23 controller pairing/deployment tests passed. Mac, iOS and preview-helper
  compilation succeeded. `git diff --check` passed.
- Mac app updated and opened. Theater, Office, Bathroom and Desk iPads updated
  in place to build 2026092802, confirmed by their installed app version queries.
  All four were reachable through the authenticated Screenpunk device inventory
  after installation. Desk uses the legacy iOS 16 USB installer; its automated
  debugger launch was unreliable, and the user opened the app directly before
  successful connectivity verification.
- Existing saved device pins/identities, screen history and active revisions
  matched the pre-update inventory. No uninstall, disconnect, credential reset,
  calendar-selection change, or private screen deployment was performed.
- iPhone Air and iPhone Mini were skipped at the user's request. Apple Watch is
  not a compatible Screenpunk target. No simulator was updated or claimed as
  physical-device evidence.

Physical iPad installation, app execution and authenticated connectivity were
verified. Map rendering inside an iPad event modal has not yet been verified:
private Calendar integration/deployment belongs to the Screens chat. That screen
must declare the connection and use the contract in [apple-maps.md](apple-maps.md).
The first valid map request prompts for local native approval of that screen
revision; retry after Allow. A tap can request the bounded static snapshot; no
external Maps URL-opening operation is exposed.

## Interactive maps and Calendar inventory — build 2026092804

- Added `appleMaps.present/update/close` and a bounded native MKMapView surface,
  with pan/zoom, rounded clipping, three-second heartbeat expiry, lifecycle
  cancellation, and a native Open in Maps button. Snapshot API remains supported.
  Device carousel two-finger gestures yield to touches within MKMapView.
- Added `value.calendars` containing the exact selected calendar inventory,
  including calendars with zero events and saved calendar titles. No credentials
  or unselected calendars are added to the screen response.
- 24 Apple tests passed, including 17 Calendar cases and seven map cases. Opt-in
  live tests exercised a real Apple snapshot and a visible native map using a
  public address. The native test checked pan/zoom enabled, preserving a changed
  region across a geometry update, and removal on close. It did not simulate
  physical touch gestures on an iPad.
- 24 controller deployment tests passed, including rejecting a map screen on an
  older device before any deployment mutation. Signed iOS, Mac, native preview
  helper, and bundled MCP builds succeeded. `git diff --check` passed.
- Mac installed at 2026092804; signature verified. Prior Mac bundle retained at
  `/tmp/Screenpunk-before-interactive-maps-2026092804.app`.
- Desk reconnected over USB and received combined build 2026092804 in place.
  The installer reported InstallComplete and the device app inventory confirmed
  CFBundleVersion 2026092804. The legacy iOS 16 launcher reported success but
  exited without a reachable app. After manual reopening, an authenticated probe
  confirmed Desk reachable at 2026-09-28T18:21:13Z. Physical map interaction on
  Desk has not been verified.
- Private screen integration and deployment remain in the Screens chat.

## Native tap expansion and opt-in location — build 2026092805

- Added `screenpunk:appleMapsTap` with only the current map ID, native single/
  double gesture distinction, simultaneous MapKit gestures, control exclusion,
  and cancellation on region changes, hiding, replacement, and close.
- Added bounded `mode: embedded|fullscreen` on present/update. Rectangle/mode
  changes preserve the same map surface. Fullscreen exposes native Show/Hide my
  location controls; JavaScript cannot request permission or obtain coordinates.
  Added iOS/Mac usage descriptions. Only When In Use is requested, by a native
  button. Collapse/close/hiding stops location; inactivity suspends it.
- All 24 map/Calendar tests passed, including live public-address map/snapshot,
  preserving the map/camera across expansion, location remaining disabled on
  expansion alone, and delayed tap delivery/cancellation on double activation
  and close. Tap tests invoke the recognizer target; they do not establish
  physical tap/drag/pinch behavior. No OS location grant was made or location
  fix/denial dialog exercised.
- Signed iOS, Mac, and native preview helper builds succeeded. Mac build
  2026092805 installed, signature verified, and UI opened. Prior app retained at
  `/tmp/Screenpunk-before-map-tap-2026092805.app`.
- Desk in-place installation completed and device inventory confirmed
  CFBundleVersion 2026092805. Pairing, screen set, and selection match the local
  pre-install baseline. After manual reopening, an authenticated probe confirmed
  Desk reachable at 2026-09-28T18:42:02Z.
- Screen integration remains separate; the final contract is documented in
  `apple-maps.md` under “Native tap expansion and optional location”.
