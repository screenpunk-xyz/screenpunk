# Device settings redesign

Accepted design requirements — September 21, 2026.

Status: the native Welcome and Settings menu is integrated with the device runtime. The separate interactive design preview uses fixture accounts; Google Calendar authorization remains unimplemented. Physical verification of the combined dynamic-path build is tracked separately from the earlier device builds below.

The full menu supports iOS 16 and later. Only fitted sheet sizing is gated to iOS 18; iOS 16–17 use native sheet detents instead of substituting the old display-settings form. A separate first-presentation flag ensures users previously shown that fallback see the full Welcome menu after updating.

## Connections shown in Settings

- Show one Connections section directly in the main Settings list, without an intermediate connector catalog page.
- Include a connector when any installed screen declares it as required or optionally supported. Compute this across all deployed screens, not only the currently displayed screen.
- Also retain already-configured connections even when no installed screen uses them. Label these “Not used by any screen” and allow the user to manage or disconnect them explicitly.
- Hide unused, unconfigured connectors. Do not silently remove credentials, accounts, pairings, or permissions when a screen is removed.
- Recompute relevance when screens are installed, updated, or removed. Optional support makes a connector discoverable but must not become a blocking setup requirement.
- Use connector declarations and device configuration as the source of truth; do not infer relevance from screen names.

## Initial connectors

- **Google TV:** shared device pairing/connection setup. Basic pairing enables volume and mute; developer pairing enables channel selection and TV power. No per-screen capability toggles or device-side allowed-channel list. Screen authors define channel choices when developing the screen.
- **Google Calendar:** service-specific calendar access, not a generic “Google Accounts” connector. Support multiple Google accounts and selection of calendars from multiple accounts for an individual screen. Calendar selection is independent per screen.
- Future Google Drive and Gmail integrations should be separate service connectors. Calendar sign-in must not imply access to those services.
- Shared connection setup should not require users to repeat account sign-in or TV pairing for each screen. Per-screen grants remain distinct.

## Native presentation

- Prefer native SwiftUI forms, sections, navigation links, toggles, sheets, navigation bars, and Liquid Glass controls throughout setup.
- Support system Light/Dark appearance. Use native large titles that collapse into the navigation bar on subpages.
- Welcome and the two-finger-hold device menu are the same page. Its rows are Come back anytime, Keep Screenpunk on screen, then Current screen.
- Guided Access instructions belong on Welcome; do not duplicate the entry in Settings.
- Welcome has a Settings gear at top left and Close at top right, with no footer. Subpages have native Back and Close controls.
- Keep device-wide Display and behavior separate from Connections, with a subtitle for consistent two-line rows.

## Production acceptance checks

- With only a TV screen installed and no saved calendar accounts, show Google TV but not Google Calendar.
- With a calendar-capable screen installed, show Google Calendar even before connecting an account.
- Optional connector declarations appear without blocking screen use.
- Multiple screens using the same connector produce one connector row.
- Removing the last dependent screen preserves the configured connector, marks it unused, and allows explicit disconnect.
- Removing a screen never revokes another screen’s grants or removes shared accounts.
- One screen can select calendars from two accounts without changing another screen’s calendar selection.

## Preview and remaining implementation

The preview is in `packages/ScreenpunkApple/Sources/ScreenpunkApple/SettingsDesignPreview.swift`; external fixture controls are in `tools/settings-design-preview/server.mjs`.

The preview demonstrates the two connector pages and sample calendar selection. The shipping menu now filters connector visibility from installed manifests, retains saved Google TV setup, and uses real TV pairing sessions. Google Calendar sign-in and calendar selection remain preview-only. The Office iPad build notes below describe the native implementation and its remaining acceptance checks.

## Google TV setup refinement

Require a valid wireless-debugging connection port (1–65535) alongside the TV address before starting or confirming basic pairing, even though the basic protocol does not consume that port. Explain why it is collected early and link to the Developer options / wireless debugging guidance. Keep basic connection and channels/power statuses independent. Basic disconnect must preserve channels/power pairing.

## Adaptive settings presentation

Welcome should fit its content; entering Settings expands the native sheet to nearly the available height and preserves that height on subpages. Return to Welcome animates back to its compact height. On wide windows, use native split navigation with Settings categories in a sidebar and the selected page beside it; narrow windows retain stack navigation. Decide from available window width rather than device identity.

### Contextual setup gate

The gate names the missing connector (for example, Set up Google TV or Set up Google Calendar), rather than the screen. Keep the brief setup explanation, omit individual capability status rows, and use a native Liquid Glass Open settings action that routes directly to the missing connector. Resolve multiple missing requirements in a stable order, reevaluating after setup.

## Office iPad device-test build — September 21, 2026

Installed and launched local development build **0.2.0 (2026092113)** on Office iPad before any commit or push. A physical-device screenshot confirmed the shared Welcome sheet over the existing Google TV test screen.

- Device menu uses the native adaptive sheet, Guided Access detail, screen picker, and device settings editor.
- Google TV form uses the existing real pairing sessions and saved identities. Existing pairings migrate to automatic bounded screen capabilities; command validation, pinned identities, explicit-tap checks, and in-flight revocation remain enforced.
- Connector visibility reads installed manifests, including optional declarations. Existing TV configuration stays accessible when unused. Google Calendar only appears when requested by a manifest and explicitly reports unavailable; it has no production sign-in implementation yet.
- Required Google TV/Calendar declarations route to the relevant settings page. Legacy screens without manifest connection declarations do not receive inferred setup gates.
- Validation: signed iOS Release build passed; Google TV regression suite ran 39 tests with one skipped and zero failures, including automatic access and revocation coverage.
- Physical navigation, pairing, connectivity, TV playback/power, and portrait/landscape interaction acceptance remain for on-device testing. No TV control command was sent during build/install verification.
- All changes remain uncommitted.

### Office iPad follow-up build — September 21, 2026

Installed 0.2.0 (2026092114), preserving app data. Sheet content now accepts the native presentation's available height instead of imposing a fixed minimum; this addresses the clipped navigation controls. Welcome gear and close symbols use regular-weight adaptive primary color. The Guided Access row reads “Lock Screenpunk on screen” / “Guided Access · Kiosk mode.” Welcome uses the controller-assigned name persisted in device settings; Office iPad was synced through its existing paired connection.

Verified the physical iPad Welcome screenshot: Office iPad name, neutral glass controls, new wording, and existing deployed screen. Expanded landscape navigation controls were visible in the actual-app simulator. Expanded pages still need a physical-device portrait/landscape acceptance pass. Core device-settings tests: 5 passed, including legacy settings without a name and name persistence. Signed device build and diff whitespace check passed. No commit or push performed.
