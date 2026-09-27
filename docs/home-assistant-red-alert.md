# Home Assistant Red Alert

Apple device apps listen directly to Home Assistant while foreground, independently
of the selected dashboard. The Mac need not stay open. Existing installations and
older apps remain compatible; older apps ignore this native behavior.

## Participation and permission

Install exactly one screen named **Red Alert** (case-insensitive, surrounding
whitespace ignored) in the device's screen set. Its ID is arbitrary. Provision
its normal native `home` Home Assistant connection through the existing approval
flow. This name plus the approved connection opts that installed screen in. No
other dashboard receives its credentials or permission. Missing screen, ambiguous
names, revoked grant, replacement installation or unlink disables the listener.
No screens, connections, lighting automations or audio automations are installed
by this feature. Install screen sets while retaining the previous selected ID.

## State contract, version 1

HA owns `sensor.screenpunk_red_alert`. Publish the complete state atomically:

```json
{
  "entity_id": "sensor.screenpunk_red_alert",
  "state": "on",
  "attributes": {
    "alert_id": "unique-run-id",
    "started_at": "2026-09-27T20:00:00Z",
    "expires_at": "2026-09-27T20:05:00Z"
  }
}
```

`alert_id` must be a new nonempty string of at most 128 UTF-8 bytes for each run.
Dates must be ISO8601 with timezone; fractional seconds are accepted. Duration
must be positive and at most 300 seconds. Synchronize clocks; a start over five
seconds in the future is rejected. To cancel or complete, publish `off` with the
same `alert_id`. Missing/unavailable/malformed state does not mean cancellation;
the local expiry still restores the screen. There are no app-originated HA writes.
A future dashboard Cancel can call an explicitly approved HA cancellation script;
that script and HA lighting/audio behavior are outside this change.

An active snapshot after reconnect immediately joins an unexpired run. Repeated
IDs never extend a deadline. A newer start replaces the current run but retains
the original return screen; older starts and mismatched clears are ignored.
On matching clear or expiry the prior screen is restored if still installed and
the user has not manually navigated away. Manual navigation dismisses that run
locally; a later run can still interrupt. Checkpoints survive app restarts without
credentials and are bound to the paired owner, installed screen set and target.

The subscription and expiry checks stop while backgrounded and resume on activation.
This does not wake/unlock a device or launch a terminated app. Expired alerts are
restored on foreground entry even without network access. Removing the target or
replacing the screen set invalidates the checkpoint rather than undoing deployment.

## Screen audio and lifecycle

Only the native Red Alert package with a HA runtime permits bundled audio autoplay;
normal dashboards retain gesture requirements. The screen must read fresh HA state
and validate identity/expiry before playing, so manual opening or deployment does
not sound an alarm. `screenpunk.runtime.onStatus(callback)` includes `active`;
stop/reset audio on false, `pagehide`, clear, expiry and identity replacement.
The native WebView also pauses media when suspended or disposed. The package
sandbox continues to block remote media. Physical output volume and route apply.
