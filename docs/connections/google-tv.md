# Google TV test connector

Status: experimental implementation for local hardware testing. Mac and iOS share the same native Android TV Remote v2 connector. This is not an official Google API and is not a guarantee of HDMI-CEC or YouTube TV channel behavior.

## Hardware and purpose

Build a very simple channel selector for an elderly user who cannot navigate modern TV menus. The test setup is an iPad, Google TV Streamer (4K), Samsung UN40D6400UFXZA (2011), built-in TV speakers, and a signed-in YouTube TV account. The eventual Samsung model is unknown. No Home Assistant, Screenpunk Cloud, or continuously running Mac is required.

## Native setup

1. Keep Google TV and the controlling Mac/iPad on the same LAN. Allow Screenpunk Local Network access. Find Google TV's IP address in its network settings; manual host entry is used in this first test version.
2. Mac: Connections → Services → Google TV. iPad: two-finger hold → device settings → Google TV Connection.
3. Enter the host, Start Pairing, then enter the six-character code displayed on the TV. Each Mac/iPad pairs separately; no private keys are copied into a screen or transferred between devices.
4. Under Screen permissions, enter the exact manifest `dashboardId`, one ID per line. Save. This grants the listed screen and future updates with the same ID the bounded remote controls below.
5. Optionally approve exact `https://tv.youtube.com/...` links, one per line, and save. These links are candidates to test, not guaranteed live-channel deep links. Do not invent channel URLs.
6. Use native Check Connection / Wake / Sleep / Volume / Mute Toggle to test the hardware before testing a screen.

Changing the TV's identity clears previous screen/link approvals. Forget removes this connector's local settings only. It does not reset Screenpunk device pairing or delete other Keychain items. The Google TV RSA identity is separate from Screenpunk's controller/device identity. Established connections pin the TV's public key obtained during successful PIN pairing.

## Screen API

Uses the already available JavaScript SDK; no new external library or manifest HTTP grant is needed. The native app looks up the active package's `dashboardId`; JavaScript cannot supply a different identity, host, pairing code, certificate, or permission grant.

```js
const { value: status } = await screenpunk.connections.request('googleTV', 'status', {});
const { value: result } = await screenpunk.connections.request('googleTV', 'key', { key: 'wake' });
await screenpunk.connections.request('googleTV', 'launchLink', {
  url: 'https://tv.youtube.com/' // Native owner must approve this exact URL first.
});
```

Operations:

- `status`: connects if needed; returns `connected`, `streamerAwake`, and optional `currentApp`, `streamerVolume`, `streamerVolumeMax`, `streamerMuted`. `tvPower` and `playingChannel` are explicitly `unknown`. Offline/permission failures reject the promise; show a clear offline/setup message.
- `key`: one short key press. Allowed values: `wake`, `sleep`, `volumeUp`, `volumeDown`, `muteToggle`, `home`, `back`, `up`, `down`, `left`, `right`, `select`, `playPause`.
- `launchLink`: sends an exact native-approved HTTPS YouTube TV link.
- Command response: `{sent: true, effectVerified: false}`. This confirms transport delivery, not the visual result or playback.

No generic socket, shell, ADB, arbitrary intent, credential access, background control, or automatic side-effect retries. Requests are serialized; concurrent requests reject as busy. Space commands at least 150 ms apart. A connection attempt times out in 12 seconds; sending in 5 seconds. The SDK may itself time out earlier, so do not automatically repeat commands. On background, package replacement, or connection failure the session closes; the next foreground request reconnects. Poll status conservatively (e.g. every 10 seconds while visible), pause during commands, and use single-flight actions with disabled buttons. Reconnection does not replay commands.

## TV behavior to verify

- Enable Samsung Anynet+ / HDMI-CEC and corresponding Google TV HDMI controls.
- `wake`/`sleep` control the streamer. Verify whether they also turn this Samsung on/off and wake selects the correct HDMI input. There is no independently verified TV input-selection operation in this connector.
- Check physical TV speaker volume and mute. Streamer volume telemetry is not necessarily TV speaker volume. A physical remote configured for IR may work when this LAN path does not; this connector cannot emit IR.
- Opening YouTube TV is distinct from selecting a live channel. Test exact links while already playing, from another app, from standby, and across a program boundary. Do not substitute sequences of D-pad presses or label an unverified link as a reliable channel action.
- If CEC speaker control fails or stable channel links cannot be established, record the failed capability rather than hiding it behind a success message. A TV-specific connector, IR hardware, or another supported launch method would be separate work.

## Test screen handoff

Use `dashboardId: google-tv-test`. Build a large, high-contrast minimal main panel and a separate caregiver/test panel. Keep diagnostic D-pad/Home/Back away from the simplified everyday controls. Main controls can include Wake, Sleep, Volume +/−, and Mute Toggle; channel tiles remain clearly unconfigured until real approved links are supplied. Do not claim a command has changed TV state. Provide visible connection/setup/error feedback without exposing credentials.

Preview safely: no commands on load or from a screenshot render. Commands require an explicit tap. First produce a preview and importable package; coordinate pairing and live deployment with the user. Do not overwrite existing Theater/Bathroom screens or reset any pairing.

Acceptance scenarios: TV off → tap channel → TV on, correct HDMI, correct live channel; repeated channel selection; volume/mute with built-in speakers; Wi-Fi outage/recovery; iPad background/foreground; Mac disconnected. Separate confirmed results from unverified ones. The first scenario is a feasibility gate, not an implemented promise.

## Implementation and protocol references

Native implementation lives in `packages/ScreenpunkApple/Sources/ScreenpunkApple/GoogleTV*.swift`. Setup is shared SwiftUI, exposed in Mac Connections and iPad settings. Screen calls use the existing restricted top-level package bridge. Protocol tests cover fragmented/coalesced frames, malformed sizes, RSA pairing challenge, link restrictions, and unauthorized screen rejection. Hardware pairing/CEC/YouTube TV behavior require an actual test and are not established by unit tests.

Reference protocol descriptions: [androidtvremote2](https://github.com/tronikos/androidtvremote2) (`polo.proto`, `remotemessage.proto`, pairing/remote implementation) and [AndroidTVRemoteControl](https://github.com/odyshewroman/AndroidTVRemoteControl). Screenpunk implements its own bounded protocol subset; neither package is shipped as a dependency.

## Synthesized voice (experimental)

```js
// Call directly inside an explicit button click, before awaiting other work.
const { value } = await screenpunk.connections.request('googleTV', 'voice', {
  text: 'Watch CNBC on YouTube TV'
});
// { sent: true, effectVerified: false } — delivery, not recognized text or playback.
```

Apple's local English speech voice renders in memory, converted to signed 16-bit
little-endian mono PCM at 8 kHz. No microphone capture or speaker playback occurs.
The iPad sends it directly through its own pinned, paired Google TV connection.
No running Mac, Home Assistant, or Screenpunk Cloud is required. Google TV/Gemini
and YouTube TV may still require their normal internet services.

In native Google TV settings, save exact **Approved voice phrases**, then use
**Send Test Voice Phrase** to test. Up to 32 phrases, 160 UTF-8 bytes each, no control
characters. All approved screen IDs share this phrase allowlist, including future
updates to those screens. Existing pairing, screen IDs, and link approvals survive
upgrading; old approvals grant no voice phrases. Changing TV identity or forgetting
clears phrase approvals. No microphone permission or manifest HTTP grant is added.

The native bridge requires a recent trusted click from an isolated WebKit content
world, consumes it once, and rejects synthetic clicks. This verifies recent user
interaction, not a relationship between a button label and its command; install
only screens trusted with the approved phrases. Do not send from load, timers,
polling or retry loops. Disable channel buttons while pending. Do not await status
or wake before voice from the same click. Voice does not promise to wake the TV.

Synthesis is bounded to 10 seconds, rendered audio to 12 seconds, and screen
operations to 35 seconds total. The updated bundled SDK allows 45 seconds for
voice and sends native cancellation on timeout. Screens bundling their own SDK
must update it. Background, package replacement, disconnect, cancellation, or a
revoked permission stops further delivery. TLS closes to abort partial sessions;
this cannot undo audio already processed by the TV. No automatic retries/replay.

The protocol negotiates voice bit 8 (feature mask 623), sends Search (84), waits up
to 3 seconds for field 30 with the TV's session ID, echoes field 30, sends PCM in
field 31 in packets of at most 20,480 bytes, padding only the final packet to
a minimum of 8,192 bytes. Prerecorded audio is delivered without artificial pacing
or an added silence tail, matching the reference. Field 32 follows the final
successful transport write and the experimental duration-based end hold described
below. Each transport write is checked. The reference exposes no documented
audio-format negotiation; 8 kHz PCM is its default. `status.voiceSupported` reports
feature negotiation only, not assistant compatibility.

Reference inspected September 21, 2026: androidtvremote2
[remote.py](https://github.com/tronikos/androidtvremote2/blob/main/src/androidtvremote2/remote.py)
(blob `e5a6a0201e1081fb767647db3b5aab75af0545c8`) and
[remotemessage.proto](https://github.com/tronikos/androidtvremote2/blob/main/src/androidtvremote2/remotemessage.proto)
(blob `8925fa97430c828160bdd4bc1017378617cd2d23`). No direct Gemini text API is used.

### Hardware and private-screen handoff

1. Coordinate installation of the prepared build with the owner. Preserve bundle
   IDs and existing app data; do not uninstall/reset any paired device.
2. Save `Watch CNBC on YouTube TV` as a native approved phrase on each device.
   Tap **Send Test Voice Phrase**. Record the assistant UI, recognized text, and
   actual live playback separately. Cancel is available while busy.
3. Update the private `google-tv-test` CNBC button to the API above, bundle the
   updated SDK, preview without commands, then load and test that screen. Installing
   the app does not change its previous failed HTTPS watch-link action.
4. Test repeated selection, another app, standby, a program boundary, Wi-Fi loss,
   cancellation, background/foreground, and iPad operation with the Mac disconnected.
   Verify each channel independently and retain unresolved CEC/volume findings.

Hardware status: the first synthesized-voice build tuned CNBC once in three
attempts, with incomplete or incorrect recognition. Build 2026092103 opened the
assistant but produced no recognized text in three attempts. Reliable recognition
and playback remain unverified. Private hosts, pairings, deployment records, and
screen source remain outside this repository.

### Reference transport restoration (build 2026092104)

Build 2026092103 experimentally added 512 ms packet pacing and trailing silence.
The receiver regressed to no recognition. Those changes are reverted together to
the reference prerecorded-audio behavior; their individual effects are unknown.
The reference [file demo](https://github.com/tronikos/androidtvremote2/blob/main/src/demo.py)
sends prerecorded PCM without pacing or an extra silence packet.

A same-input comparison of the old and revised converters used one local render
of the exact CNBC phrase: 48,176 source frames at 22,050 Hz, producing 17,479
signed little-endian frames at 8 kHz. Outputs were byte-identical (zero differing
bytes), peak 24,075, RMS 6,024.52, and 17,426 nonzero frames. The converter change
therefore did not corrupt or silence that sample. Source consumption and output
duration checks remain. This does not prove receiver consumption or recognition.

The phrase now occupies two packets of 20,480 and 14,478 bytes, with no padding.
The TV-issued session ID remains the readiness signal. No guessed startup or
post-command delay is used. Tests verify packet content, handshake gating,
transport completion before end, and stopping after failed writes/disconnects.

Response fields `audioSeconds`, `streamedPCMSeconds`, `streamSeconds`, and
`audioPackets` describe source duration, transmitted PCM duration including any
final padding, elapsed sending time, and packet count. Build 2026092104 adds
`pcmPeak`, `pcmRMS`, and `pcmNonzeroFrames`. Native unified logs under subsystem
`xyz.screenpunk`, category `GoogleTVVoice`, record aggregate amplitude/frame
counts, handshake timing, completed packet byte counts, delivery totals, and
failure phase. No phrase, raw audio, host, credential, or session ID is logged;
error details use private logging. These diagnostics never establish playback.

Retest with one owner-coordinated tap in the existing private screen, observing
recognized text and actual live playback separately. Capture native delivery
logs for that attempt before deciding on repetitions. Restoration is a regression
rollback and diagnostic build, not a verified fix for the original intermittent
recognition. Never infer recognition from `sent: true` or retry automatically.

### Isolated end timing experiment (build 2026092105)

On build04 the TV captioned only “watch CNBC on” and did not tune. Logs show all
34,958 bytes completed their socket writes and voice-end within 0.000708 seconds,
for 2.184875 seconds of PCM. The owner then spoke the same shortened phrase using
the physical remote while holding its microphone through speech and another
roughly one second; it worked. This supports investigating session end timing,
but neither proves remote-v2 receiver behavior nor excludes dropped packets.

Build05 preserves build04 PCM, packet sizes and unpaced writes. It changes only
voice-end scheduling: after the last successful write it holds the session open
for the transmitted PCM duration, including any final padding, then rechecks
cancellation, permission and session identity before end. No extra audio, startup
delay, per-packet pacing, or key press change is introduced. The maximum hold is
bounded by the existing 12-second source and minimum final packet padding.
Cancellation/disconnection immediately interrupts the hold and closes TLS.

SEARCH84 is still a SHORT key event, followed by the TV-issued session-ID
handshake. The app does not keep SEARCH down. Voice begin/end messages delimit
this protocol session; physical-remote microphone mechanics may differ. There is
no documented audio-consumed acknowledgement. The duration-based hold is an
explicit hardware experiment, not proof of receiver processing or a reliable fix.
The additive result `endHoldSeconds` and log phase `endHold` distinguish the hold
from socket delivery. Coordinate one owner-observed test and correlate logs.
