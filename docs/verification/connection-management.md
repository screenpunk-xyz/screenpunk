# Device connection management

The Mac device Connections sheet replaces raw grant JSON with a sidebar and a stable, scrolling detail area. It reads an owner-authenticated inventory from the iPad, including installed public sources, Home Assistant scopes, and generic grants. Public sources with matching origin and user agent are grouped; operations retain their screen scope. Home Assistant scopes remain separate because matching addresses do not establish matching credentials.

The inventory contains no tokens, headers, or credential values. Public tests execute an installed operation with no required parameters using the existing bounded public-read runtime on the Mac. Sources requiring screen-supplied parameters report that limitation without inventing requests. Home Assistant tests use matching credentials already saved on the Mac and explicitly do not verify the device's token. Generic device credentials are not exported for tests.

Home Assistant Configure changes only server address and token. An unchanged server can retain the device's token; changing the server requires entering a new one. Save sends directly to the paired device and returns success only after its receipt matches the requested scopes, destination, and unchanged permissions. The device uses an atomic Keychain write and rejects stale versions, changed screens, duplicate scopes, and other owners. Nothing is durably queued. A lost response is reported as unconfirmed; reload before retrying. This is device-local configuration and does not change the Mac's global Home Assistant setup or future screen-deployment configuration.

The new protocol capability requires an updated iPad app. Older devices receive an update-required error, not an empty invented inventory. Previously loaded inventory remains visible as last known if reloading fails.

## Validation

- Mac Debug build passed.
- iPad signed Release build passed, version 0.2.0 (2026092501).
- Apple package suite: 122 tests, 2 skipped, zero failures (before new test file was included).
- Focused connection/runtime suite: 26 tests, zero failures, including 4 new inventory/update cases.
- Controller suite: 65 tests, 1 skipped, zero failures.
- Extended TLS pairing/deployment test passed with real inventory/update messages, unauthenticated-access rejection, and stale-update rejection.

The local HTML studio remains a design artifact with simulated network outcomes. Native app tests and inventory use real transports.

## Live loading issue resolved

The actual failure was macOS Local Network privacy denial (`NWPath` reported local network prohibited), not inventory decoding or an unreachable iPad. The System Settings list initially displayed stale toggle values; restarting System Settings revealed the disabled Screenpunk permission. Enabling it restored live inventory loading.

The local Mac Release build is now 0.2.0 (2026092502), signed with the available Apple Development identity rather than an ad-hoc identity. Apple recommends an Apple-issued identity so Local Network privacy reliably identifies a Mac app: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy

The client now detects Local Network denial immediately and the Connections view shows the permission recovery instructions. It also preserves connection-specific device errors instead of converting them to a generic interruption. Temporary diagnostic file logging was removed.

Verified in the installed native app: Bathroom inventory lists archive, basemap, Home Assistant, nasa, radar, and weather. The actual weather hourly operation succeeds from the Mac and the status pill shows Source reachable. Six LAN regression tests pass. No iPad update was needed for this Mac-side recovery.

For future local builds, retain the Apple Development signature when installing. The unsigned distribution packaging script still intentionally produces an ad-hoc-signed artifact; do not overwrite this machine's stable-signed installation with that artifact without signing it appropriately first.
