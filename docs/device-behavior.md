# Declarative device behavior

## Preserve user data across updates

Every screen that accepts user-entered data or preferences should persist them
with native `screenpunk.state.get/set/remove`. Keep dashboardId and versioned keys
stable, restore before defaults, save user edits, and preserve data on read or
migration failure. Check persistentState/persistentStateWritable; report unsupported
or read-only hosts. Verify values survive a screen update and app relaunch.
Device-local state is not remote agent access or cross-device sync; app deletion,
device reset and confirmed Disconnect can erase it. See [the authoring default](../docs/screen-authoring-persistence.md).


Screen packages may opt into reusable native capabilities through the top-level
`deviceBehavior` manifest field. The same field is accepted by `put_dashboard`
and the authoring `screen.json`. Edits that omit it preserve the previous value;
`{}` clears it. Device preparation preserves the complete declaration.

```json
{
  "deviceBehavior": {
    "temporaryActivation": {
      "source": "homeAssistant",
      "entityId": "binary_sensor.delivery",
      "activeState": "ready",
      "inactiveState": "idle",
      "idAttribute": "event_id",
      "startedAtAttribute": "begin",
      "expiresAtAttribute": "end",
      "maxDurationSeconds": 45
    },
    "audio": { "autoplay": true }
  }
}
```

Both sections are optional. Names and arbitrary dashboard IDs have no special
meaning. The package declaring `temporaryActivation` is the target. Exactly one
installed target is supported; multiple targets disable native activation.
The target must have its own approved Home Assistant provisioning bound to the
paired owner, package revision and installed grant set. Other screens' grants
cannot authorize it. This declaration does not grant credentials or service writes.

`source` must be `homeAssistant`. Entity IDs are at most 255 UTF-8 bytes and match
`[a-z0-9_]+.[a-z0-9_]+` (the dot is literal). State strings must be distinct,
nonempty, at most 128 bytes, and contain no control characters. Attribute names
are distinct direct keys of `attributes`, each 1–128 ASCII letters, digits or
underscores. Duration must be an integer from 1 through 3600 seconds.

The selected entity's state must contain a nonempty identifier of at most 128
UTF-8 bytes and ISO8601 start/expiry timestamps. The active state starts a lease
only when the start is no more than five seconds ahead, expiry is later than
start and now, and duration is within the configured maximum. The inactive state
clears only a matching identifier. Missing, malformed or unrelated state does not
clear an active lease. Local expiry continues even when network reads fail.
Repeated identifiers cannot extend the deadline or undo manual dismissal. A
newer lease retains the original return screen; older starts are ignored.

Matching clear or expiry restores the previous screen only when still installed,
still on the target, and not manually dismissed. Foreground polling reads only
the declared entity every two seconds with a 10-second request timeout, 64 KiB
response bound, cancellation, and bounded retries (1–30 seconds). Backgrounding
stops network and expiry tasks; foreground entry applies overdue restoration
before polling. This cannot wake, unlock or launch a device.

Credential-free checkpoints bind the owner, installed grant set, target and full
configuration. Screen-set replacement invalidates them. Selection proposals are
persisted before navigation and replayed after a crash. Manual navigation dismisses
the current lease; a later identifier can activate again.

`audio.autoplay` explicitly permits local packaged media without a gesture,
independently of temporary activation. Absent/false retains gesture requirements.
The package owns its decision to play; it must gate playback using fresh source
state and stop/reset on clear, expiry, replacement, `pagehide`, or
`screenpunk.runtime.onStatus` reporting `active: false`. The host also pauses
media on suspension/disposal, and remote media remains blocked by the sandbox.

Devices implementing this contract advertise `home-assistant-temporary-activation-v1`.
The controller requires this capability before transferring either declared section,
including audio-only permission. Paired `queryActive`
and controller device diagnostics expose `temporaryActivation`, with phase,
foreground flag, target, last receipt/state, sanitized errors, and counters.

## Migration

Use updated authoring tools and compatible native apps together. Rebuild and
redeploy packages with explicit behavior, retaining other installed screens,
settings, grants and current selection. Old manifests do not activate the new
listener or receive autoplay permission. Old native apps do not implement this
contract. There is deliberately no name-based or fixed-entity fallback and no
migration of the old screen-specific checkpoint. Screen-specific entity values,
assets, scripts and operating instructions belong in the separate Screens project.
