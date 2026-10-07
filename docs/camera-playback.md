# Camera playback

Camera screens now have a native playback surface shared by macOS and iOS/iPadOS. The first source adapter resolves Home Assistant camera entities into HLS streams. Direct camera credentials, discovery and RTSP decoding are not implemented yet.

## Screen contract

Declare exactly which cameras the screen may open:

```json
{"alias":"home","required":true,"cameraEntities":["camera.example_one"]}
```

Then mount a native video layer into an empty, rectangular element:

```js
const camera = screenpunk.cameras.mount(tile, {
  kind: "homeAssistant", connection: "home", entityId: "camera.example_one"
}, ({state, code}) => {
  status.textContent = state; // loading, playing, stopped, failed
});
// Reconnect after a failure:
retry.onclick = () => camera.retry();
// Dispose when leaving the screen:
addEventListener("pagehide", () => camera.stop());
```

Use `screenpunk.cameras` feature detection for older hosts. At most three tiles play concurrently. Playback is muted. HTML controls must stay outside the video rectangle: the native layer is above web content. Use the optional native gallery presentation for controls over the feed. Rounded masks, overlapping HTML on video, CSS transforms, and partially visible tiles are not supported in this first version. Fully visible tiles follow resize/scroll changes every 750ms; clipped, detached and hidden-document tiles stop. Stop the mount before hiding it behind another screen or modal.

## Native gallery presentation

Pass a fourth mount argument to opt into shared native controls:

```js
screenpunk.cameras.mount(tile, source, onState, {
  controls: "gallery", label: "Camera One", order: 0
});
```

Gallery feeds fill their rectangles, cropping to cover. Native overlays provide a white-on-green Live pill (orange Connecting, red Offline, gray Paused) and a 44-point refresh control, inset 16 points. Refresh resolves a new stream and resets playback status. Tapping the feed expands it to the runtime viewport; the top-right collapse control returns to the grid. Horizontal swipes cycle through mounted gallery cameras by `order`, wrapping in both directions. Other players remain running while expanded for immediate switching.

The controls use Liquid Glass on iOS/macOS 26 and material-backed circles on older systems. The connected iPad runs iPadOS 17 and uses this fallback. This presentation lives beside the source-independent player, so future direct camera adapters can reuse it.

## Native boundaries and lifecycle

- `CameraSource` identifies a source without credentials or URLs.
- `CameraStreamResolver` resolves an authorized source to a native-only `CameraStream` and revocable lease.
- `HomeAssistantDeviceRuntime` implements that resolver, validating exact entities, owner, dashboard, revision and credential generation.
- HA's `/api/websocket` authenticates natively, then `camera/stream` negotiates an HLS endpoint. Only relative `/api/hls/<id>/master_playlist.m3u8` endpoints from the configured HA origin are accepted. The bearer token is not sent with media requests.
- `CameraPlaybackController` owns AVPlayer/AVPlayerLayer, bounded startup, layout and teardown. It does not know HA authentication details.
- Heartbeat expiry (4 seconds), revocation, hidden windows, app backgrounding and screen teardown stop playback. Camera failures do not mark unrelated HA controls offline.
- Native provisioning schema 3 binds `cameraEntities` outside page JavaScript. Devices advertise `camera-playback-v1`; the controller rejects unsupported devices before transferring a camera screen.
- Existing web content isolation/CSP is unchanged; stream URLs are not returned through the bridge.

Future direct HLS sources can implement `CameraStreamResolver` and reuse playback, layout and lease handling. RTSP sources need an additional native decoder or a relay that produces supported HLS; AVPlayer is not an RTSP decoder. Do not add raw camera URLs/passwords to screen packages to bypass this boundary.

## Example and checks

`examples/home-assistant-cameras` contains three placeholder camera entities, in a full-bleed 2×2 grid with the fourth cell black. It is named Cameras and uses native expand/collapse, endless swiping, and refresh controls. Generate its package with:

```
cd sdk
npm run build
node --import tsx scripts/build-camera-example.ts
```

Native SDK resource must be synchronized from `sdk/dist/screenpunk.js` when changing the client. Mac app, preview helper, MCP and device runtime should be rebuilt together.

Tests cover grant validation, unprovisioned/wrong-source rejection, endpoint confinement, SDK mounting/disposal, and an opt-in native playback integration check:

```
SCREENPUNK_TEST_CAMERA_ENTITIES=camera.example_one SCREENPUNK_LIVE_CAMERA_TEST=1 swift test --package-path packages/ScreenpunkApple --filter CameraTests/testLiveCameraPlayback
```

The live test uses Screenpunk's existing native HA provisioning path; it does not log tokens or capability URLs. It runs all three cameras for 75 seconds and requires more than 20 distinct decoded frames during the final 30 seconds. All three produced 30 distinct frames in that interval.

The playback fix restores AVPlayer's normal live buffering: forcing immediate playback with a one-second buffer caused playback to stop after the first partial HLS segment. Initial buffering on these cameras can take about 20–30 seconds. The Live state now requires fresh decoded frame timestamps, becomes Connecting when frames stop arriving, and fails after a sustained stall. The earlier short playback-clock test could not detect frozen video and has been replaced.

Personal screen source, deployment records, and device-specific verification notes belong outside the app repository.

HA protocol reference: https://github.com/home-assistant/core/blob/dev/homeassistant/components/camera/__init__.py (`camera/stream`). Apple rendering: https://developer.apple.com/documentation/avfoundation/avplayerlayer.
