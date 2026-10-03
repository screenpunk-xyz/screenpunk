# Native human sign-out settlement

Explicit sign-out immediately revokes admitted human identity, token access and provider callbacks. It retains one in-memory intent while an existing provider or Firebase exchange finishes. A late exchange result cannot publish a user, and SDK clearing runs only after that flow exits so the exchange cannot repopulate the session after clearing.

Both Firebase and Google clearing are attempted. Any failure retains a failed intent and blocks new sign-in until an explicit retry succeeds. Repeated requests join the same settlement. Backgrounding, presentation cancellation and cancellation of an awaiting task do not abandon this explicit intent. An SDK operation that ignores cancellation indefinitely leaves sign-out pending; there is no timeout-success path.

The scene retains the same identity/coordinator pair. The coordinator publishes pending, failed and succeeded state separately from cancelable discovery work, clears human-dependent presentation immediately, and preserves workspace operation recovery context. Captured flow and sign-out attempt identifiers prevent stale completions from affecting a subsequent flow.

This intent is process-local, with no restart durability claim. Installed-screen authority, reset, provider configuration, entitlements and Cloud UI activation are outside this change. The application still requires a complete production Cloud journey before release.

## Qualification

The exact accepted main commit `86974e7845177ccae7c22eb7ccb3795453f6653c` plus seven source/test paths passed 53 isolated app tests and an unsigned iOS Simulator build. Tests use injected fake provider results and SDK clear operations: ignored cancellation for both providers, exchange-before-clear ordering, partial clearing and explicit retry, repeated/background sign-out, delayed cancellation from a previous flow, and preserved workspace recovery requests. These tests do not qualify live provider behavior or physical devices.
