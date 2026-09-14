# Mac workbench — September 13, 2026

This checkout implements the local Mac design lab as a native Apple-silicon macOS 14+ app. It was isolated from the existing checkout so the original project remains available. Its starting content was synchronized through the GitHub plugin to upstream `e84c434686bc5895dd70fc4cb74872a6cd7d9e7f` in local snapshot commit `c2c2745`. Work is on `guy/codex/mac-design-workbench`; no remote changes have been published.

## Product behavior

- Device-first navigation, with a Devices/Screens segmented sidebar. Nearby devices sit above the paired-device count; manual address entry is available through Add.
- The shared Devices/Screens orientation control uses native extra-large sizing (72 × 36 points). Background windows lighten the sidebar and continuous canvas and soften sidebar/header text, using native window and application focus notifications.
- Device hardware-model headers in regular body type (no screen detail title), a searchable full SF Symbol picker with persisted per-screen icons, context-neutral “Screen saved.” feedback, and native SF typography and symbols, desktop-blurred sidebar vibrancy, a continuous toolbar/canvas, consistent glass controls with retained inactive-window contours and 36-point circle actions, and a primary blue Apply Screen pill with white icon and label.
- Start pairing on the Mac, compare the security code, and confirm on the phone. The Mac polls the authenticated handshake and finishes automatically. The device still enforces local user approval.
- A reusable screen library supports creating/editing local HTML/CSS/JavaScript, persistent drafts, validated package import, saving, selecting, explicitly applying, and deleting. Applying creates a device-sized package without changing the library source. Deleting a screen does not stop a device's running content.
- Screens use a single header row with Rename/Change Icon/Edit Code/Duplicate/Delete in the selected sidebar row’s trailing overflow menu, the centered device picker, and orientation/support controls on the right. Screens have frameless previews with a centered searchable catalog of 237 device viewport presets and portable Portrait/Landscape/Both support settings. Unsupported orientation is rejected during package updates and Apply. Device headers show a hardware-model subtitle only when reported; their preview uses the reported viewport.
- The centered selector distinguishes a pending preview from the applied screen. The preview scales with its viewport, and the applied package is restored when the app restarts.
- Rename Device and Forget Device live in the circular glass device-name overflow menu. A custom name persists across reconnects. Duplicate Screen opens an independent draft in both the screen selector and Screens options menu. No per-device history, information footer, inspector toggle, or Pair Again appears in the Mac UI. Immutable package revisions remain internal for protocol and agent compatibility.
- The bottom Agents area reflects actual MCP sessions after a tools request, with a connection-configuration sheet when no agent is attached. The DMG bundles the MCP executable and its hidden preview helper.

## Build and test

Run `SCREENPUNK_MARKETING_VERSION=0.2.0 scripts/build-unsigned-dmg.sh` from this checkout. The script builds the Mac app, embedded MCP executable, and preview helper, signs the bundle ad hoc, creates the DMG, verifies its signature and mounted contents, and writes a SHA-256 checksum and BUILD-INFO.txt. The pinned MCP SDK is compiled in Swift 5 compatibility mode because its Network transport does not compile under this toolchain's Swift 6 strict-concurrency checks.

Validation completed on this Mac:

- 78 ScreenpunkCore tests, 31 ScreenpunkController tests, and 29 ScreenpunkApple tests pass.
- Companion iOS simulator-target compilation succeeds.
- Native UI: created and saved a Clock screen; confirmed the preview renders; restarted and recovered the paired device and current screen.
- Real phone: Bonjour discovery, matching code, phone-only confirmation, automatic Mac completion, and Apply Screen. The user confirmed the Clock appeared on the phone.
- Packaged MCP: initialization, 22 tools, package creation, and a real PNG produced by the bundled helper.

The app uses the shared store at `~/Library/Application Support/xyz.screenpunk.controller`. Screen symbols and display selections use the app's preferences. The old workbench's separate `~/Library/Application Support/Screenpunk` file is preserved. Old records without the device's TLS pin cannot safely become authenticated records in the new store; pair once in the new workbench when needed.

## Testing notes

- Apple silicon; macOS 14 or newer. macOS 26+ uses native Liquid Glass; macOS 14–15 uses native bordered controls. Availability and deployment metadata are build-validated; an older macOS runtime was not available for interactive testing. This local test build is ad-hoc signed and not notarized. If Gatekeeper blocks first launch, use System Settings → Privacy & Security → Open Anyway.
- Move Screenpunk to Applications before copying its agent configuration so the executable path stays stable.
- macOS may ask to use the saved pairing key. Answer the Keychain prompt yourself; Screenpunk never asks for or stores your login password. The first connection allows time for that prompt.
- The existing phone app was verified for portrait pairing and deployment. New landscape deployment and accurate iPad/phone viewport reporting require the companion iOS source changes in this checkout; they are not installed by a Mac DMG. The Mac handles rejection from an older phone without replacing its active screen.
- Older phone builds do not advertise a friendly name, so they may appear as Nearby device / Paired device. Newer builds report the name and viewport through the backwards-compatible hello fields.

## Design references

The authoritative Mac contract is in `Brand/Style-Guide/dist/mac-app-guide.md`. The interactive local guide is served on port 4321; the browser prototype remains on port 4318. Neither was republished as part of this native build.

Selected Devices and Screens sidebar rows expose their 36-point glass overflow menu at the trailing edge; detail titles have no adjacent menu. Unselected rows omit the action.

Sidebar refinement: both item types share a 42-point content height and 5-point vertical padding. Section headers have a 17-point bottom inset before rows. Overflow buttons only exist while the window is active. Screen-picker rows use a shared 24-point icon slot, 10-point gap, and reserved 18-point checkmark slot. Icon selection includes all 9,184 names in the installed Apple SF Symbols 7.2 catalog, filtered once per launch through public NSImage availability; no private API or runtime catalog path is required.

The screen editor uses Cancel and primary Save at the bottom right, with no Keep Draft/Discard Draft actions. Cancel (Escape) removes the unsaved working copy and closes without touching the saved screen; Save (default action) writes the screen and closes only after success. Both controls and editing fields disable while saving, and blank screen names cannot be saved. Working-copy recovery remains internal.

Sidebar overflow visibility now changes via an immediate, nonanimated opacity/hit-testing/accessibility state while retaining its layout slot, avoiding the retiring native glass surface on a previously selected row. The editor has an unlabeled 36-point glass symbol button before the name. It opens the same full Symbol Picker as Change Icon in a nested modal; Save updates the working-copy symbol and returns to the editor, Cancel returns with the original symbol. Only the editor’s Save commits the screen.

Latest sidebar supersedes compact native-list spacing: custom SwiftUI rows are 64 points tall with 12-point selection corners and 8-point gaps, 16-point labels/14-point subtitles, and consistent 16-point outer insets. The 42-point full-width Devices/Screens capsule has a neutral selected segment. Active row selection, primary action tint, and symbol selections share one blue (0, 0.48, 1). Arrow-key navigation and selected accessibility traits remain. Agent-specific setup is documented in agent-setup.md.


Latest sidebar/header refinement (build 26): device and screen overflow menus now occupy the leading detail toolbar position, and sidebar titles share a 14-point system font. Agent presence currently lists live MCP sessions, so Cursor desktop and agent-worker connections appear as separate rows with the same name.
