# @screenpunk/sdk

TypeScript package tools plus a small **browser** dashboard client. Devices
load a locally bundled IIFE. End users do not install Node or Python.

## Browser client

`src/client.ts` is compiled to `dist/screenpunk.js` (copied into example
packages as `screenpunk.js`).

```html
<script src="screenpunk.js"></script>
<script>
  const sdk = globalThis.screenpunk;
  const reading = await sdk.connections.request("status", "getStatus", {});
  sdk.runtime.ready();
</script>
```

The page never fetches. It posts JSON bridge messages to
`webkit.messageHandlers.screenpunk`. The native host injects replies with
`globalThis.__screenpunkDispatch(message)`.

Pinned methods: `connections.request` / `subscribe`, `state.get` / `set` /
`remove`, `runtime.ready` / `onStatus`. Request results are
`{ value, stale }`. Auth-looking parameter keys are rejected in the page.

## Authoring / CI

```sh
npm test                 # typecheck, bundle, Node tests
npm run sync-examples    # refresh example screenpunk.js, lockup assets, manifests
```

## Home Assistant services

Use `screenpunk.homeAssistant.callService({domain, service, target, serviceData})` with service declarations in the screen manifest. See [the contract and migration guide](../docs/home-assistant-services.md) and [runnable controls](../examples/home-assistant-services/).

## Public HTTPS JSON and raster frames

Native hosts advertising `public-read-http-v1` support revision-approved
`connections[].publicHTTP` declarations, `connections.read(alias, operation,
parameters, {signal})`, and `connections.release(resourceURL)`. The result includes
explicit fresh/stale/unavailable/error state and either parsed JSON or an opaque
local raster handle. See [the contract and approval workflow](../docs/public-read-connections.md)
and [the synthetic animation example](../examples/public-read-animation).

### Native Google TV synthesized voice

Native builds advertising `googleTVVoice: 1` accept
`connections.request('googleTV', 'voice', { text: 'Watch CNBC on YouTube TV' })`
directly inside an explicit click handler. Native settings must approve the screen
ID and exact phrase. Do not send on load, poll, or retry. The response
`{ sent: true, effectVerified: false }` confirms delivery only. Voice allows 45
seconds; timeout sends native cancellation. Update privately bundled SDKs.
See [permissions and hardware testing](../docs/connections/google-tv.md).

Voice delivery diagnostics include `audioSeconds` (speech PCM),
`streamedPCMSeconds` (including final padding), `streamSeconds` (elapsed sending),
and `audioPackets`. Build 2026092104 adds `pcmPeak`, `pcmRMS`, and
`pcmNonzeroFrames`, and restores reference unpaced prerecorded delivery after
2026092103 regressed on hardware. These are transport diagnostics, not evidence
of recognized words or channel playback. No SDK or screen update is required.

Build2026092105 adds experimental `endHoldSeconds`: after the unchanged burst
writes, native keeps the voice session open for the transmitted PCM duration
before end. Recognition and playback still require hardware observation.
