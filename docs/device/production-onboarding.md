# Device onboarding and screen management

## Accepted experience

- A fresh empty device opens Welcome to Screenpunk with explicit Screenpunk Cloud and Local Screenpunk choices. Cancel never requires another connection.
- Cloud uses Apple or Google provider authentication. The approved layout places provider buttons directly on the Cloud connection screen, with Cancel below. Native Cloud configuration, enrollment credentials and service contracts are a separate integration dependency; this source must never simulate successful enrollment.
- Local pairing waits for a real authenticated Mac request, compares the matching code, and distinguishes local approval from durable controller completion. Done opens General so the device can be renamed.
- General contains device name, Screenpunk connection, and display/behavior on one page. Starting page within screen appears only for multi-page content.
- Your screens is one Settings destination. Installed screens appear first with thumbnails and red minus removal actions. Authorized installable Cloud content belongs below, with a single native disclosure arrow. Direct entry from the Connected placeholder presents this same destination with Close rather than a fabricated back stack.
- The connected empty placeholder has a primary Your screens action and asks the user to keep Screenpunk open to receive screens.
- Disconnect offers keeping or removing local screens. It preserves device preferences and separately stored integration credentials. Retained content keeps only its previously approved execution authority; future managers never inherit it. Removal revokes the removed content's execution eligibility without deleting cloud projects.

## Production boundaries

The first native integration is based on public main and existing real Local services. Preview fixtures, identities, sample content, timers and fake success callbacks are not production inputs. Native Cloud auth, catalog, approval and install APIs are not frozen or implemented as of this integration's start. UI must represent that unavailability accurately. Google Calendar OAuth is not Screenpunk Cloud account authentication.

Cloud work owns account/device enrollment, installation-scoped credentials, authorized immutable catalog versions and thumbnails, exact install plans, on-device human approval receipts, ordered-set and authority generation checks, and reviewer account examples. Real Cloud integration must use those reviewed contracts rather than browser session cookies or permanent use of a user identity token.

## Review and qualification

Review local persistence/IO failure boundaries, stale management requests, pairing cancellation/expiry and terminal completion, retained exact-package grants, removal, relaunch and replacement-manager behavior. Run Core and Apple runtime tests, Controller handshake/transport tests, and unsigned iOS build. Inspect iPhone/iPad navigation, dark/light appearance and constrained layouts. Simulator source validation does not qualify real identity sessions, live Cloud delivery, physical-device networking, VoiceOver, maximum Dynamic Type or App Store submission.

No signing-config, provisioning, marketplace publication, live device reset or personal credential changes are part of this source integration. Existing CLI/Mac worktrees remain preserved.

## Initial implementation verification

Local review exercised the real Core/Apple/Controller sources, not the design fixture. Core:127 tests passed. Controller:106 executed, one existing test skipped, zero failures. Targeted Apple settings/name/pairing/screen-set tests:18 passed; an expanded same-pin repair case separately passed and verifies an old management channel remains revoked. iOS16 and macOS13 package builds passed. Generated iOS simulator app built unsigned for compile qualification and ad hoc signed for simulator Keychain execution; no signing project configuration was changed. Signed iPhone simulator welcome/Local waiting/Cancel smoke checks passed. Hosted PR checks and physical-device/live-provider qualification remain separate.
