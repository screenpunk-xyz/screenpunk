# Unlink a device

To remove Screenpunk's dashboard from an iPhone or iPad, hold two fingers
anywhere on its screen for ten seconds, then tap **Unlink**.

- Keep both fingers down for the whole ten seconds. Lifting early cancels
  and nothing changes.
- The panel has exactly one button. Tapping outside it closes the panel
  without doing anything.
- The gesture works over a loading page, an error page, and a crashed
  dashboard. The panel is native; dashboard code cannot block or hide it.
- VoiceOver: focus the dashboard, swipe to the **Unlink** custom action,
  and double-tap. It opens the same panel.

Unlink erases the dashboard, its cached data and saved state, the
connection credentials stored on the device, and the pairing with its Mac.
Anything still transferring is cancelled. The device returns to **Ready to
pair**, and any Mac can pair with it again.

Unlink does not revoke tokens upstream. If a Home Assistant or API token
must stop working everywhere, revoke it in that service as well.

From the Mac: if the device is reachable, **Unlink** in its device page
asks the device to erase itself and reports whether it acknowledged. If the
device is unreachable, **Forget** removes only the Mac's record. The device
keeps its dashboard and credentials until someone performs the gesture on
it. The Mac cannot erase a device remotely.
