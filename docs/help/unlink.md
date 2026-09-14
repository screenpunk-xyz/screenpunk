# Disconnect a device

Hold two fingers on the device screen for five seconds to open the native
device menu. Choose **Disconnect…**, then confirm **Disconnect**.

- Opening the menu does not erase anything. **Close** or tapping outside
  dismisses it; **Cancel** returns from confirmation to the menu.
- Lift either finger before five seconds: nothing changes.
- The menu also lets you choose among installed screens. Two-finger swipes
  switch screens without opening the menu; ordinary one-finger controls keep working.
- The gesture works over a loading page, an error page, and a crashed
  dashboard. Dashboard code cannot block or hide the native menu.
- VoiceOver exposes a **Device menu** action that opens the same menu.

Confirming Disconnect removes all deployed screens, cached data and saved
state, connection credentials stored on the device, and pairing with its Mac.
The device returns to **Ready to pair**.

Disconnect does not revoke tokens upstream. To stop a Home Assistant or API
token from working everywhere, revoke it in that service as well.

**Forget Device** on the Mac removes its saved record. It does not erase
screens or credentials on the device. To erase those, use the device menu.
The MCP help topic and resource retain the stable `unlink` identifier.
