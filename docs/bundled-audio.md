# Bundled sound effects

Screenpunk's macOS and iOS/iPadOS 16+ hosts support package-local HTML audio.
Use relative asset paths and include the files in the package's normal integrity
manifest. No new connection, remote URL, credential, or capability is needed.
Use short PCM WAV files for predictable compatibility; MP3, AAC/M4A, AIFF and
CAF receive audio MIME types, but the OS must support the actual codec. File
extensions alone do not make a codec playable. Normal package transfer limits
still apply; ship only the sounds the screen uses.

```js
const feedback = new Audio('sounds/confirm.wav');
button.addEventListener('click', () => {
  feedback.currentTime = 0;
  feedback.play().catch(error => {
    status.textContent = `Sound could not play: ${error.name}`;
  });
});
```

Call `play()` directly in the tap/click handler, before awaiting other work.
Autoplay remains blocked. The host permits `media-src 'self'` only; remote
HTTP(S), other package hosts, file URLs and traversal remain denied. The custom
scheme serves media with Content-Type, Content-Length and byte-range responses.
No local HTTP server or unrestricted network media access is introduced.

On iOS the host configures a playback audio session that mixes with other audio.
Feedback is intended to play in Silent mode; device volume and the selected
output route still apply. WebKit owns playback activation; the host does not
start an always-active audio session or request background audio. A completed
JavaScript play promise is not proof of audible output. Check output volume,
Bluetooth/AirPlay routing, interruptions and speakers on the actual device.

The host reports failed play promises before rethrowing them, so even an empty
screen catch does not hide diagnostics. It preserves the normal rejecting
promise. Observe `screenpunk:audio-error` on `window` for `{code, message}`,
inspect the WebKit console, or filter native Console logs by subsystem
`xyz.screenpunk`, category `BundledAudio`. The native log accepts fixed codes
only; it does not record screen URLs, page content or arbitrary error strings.

| Code | Action |
| --- | --- |
| AUDIO_GESTURE_REQUIRED | Start play synchronously from the user's tap. |
| AUDIO_UNSUPPORTED | Check the relative path, included file and codec; try PCM WAV. |
| AUDIO_LOAD_FAILED | Check the bundled asset path and package integrity. |
| AUDIO_DECODE_FAILED | Re-export the sound as PCM WAV. |
| AUDIO_ABORTED | Check for pause, load, source changes or navigation. |
| AUDIO_POLICY_BLOCKED | Bundle the file; external media is forbidden. |
| AUDIO_PLAY_FAILED | Check the asset, volume and system output route. |
| AUDIO_SESSION_FAILED | Native session setup failed; check the system audio route. |

## Regression checks and physical acceptance

`swift test --package-path packages/ScreenpunkApple --filter BundledAudioTests`
runs a real WKWebView on macOS. The fixture is a generated 440 Hz PCM tone,
with no private screens or third-party audio. It checks MIME types, range
responses, autoplay rejection, timeline advancement/completion, external-media
blocking, and diagnostics after a swallowed missing-file error.

If an older device exits inside Apple's XCTest/Swift Testing bootstrap before
any test starts, record the harness failure separately and use manual native
playback acceptance; do not report the build as a passed device test.

The same test source is included in the generated iOS project's
`ScreenpunkAudioTests` target. Generate projects using
`./scripts/generate-xcode.sh`, then run the `ScreenpunkiOS` scheme's tests on a
connected development device using your local signing settings. The test
briefly displays a generic WebView and does not change pairing, deployed
packages, or Home Assistant entities. An iOS 16 deployment target establishes
compile compatibility, not physical iOS 16 execution evidence.

For audible acceptance on Mac and iPad: use a generic bundled PCM WAV screen,
tap its sound button, confirm sound from the expected output, then repeat with
Silent mode on/off, after background/foreground, and after an interruption.
Test repeat taps and a missing asset, and confirm remote audio remains blocked.
Record the device/OS and human listening result separately from automated
playback timeline results. Do not invoke device-control actions just to test a
screen's feedback sound.
