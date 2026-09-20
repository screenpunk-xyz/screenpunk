# Unlink and recovery

How to reset a device, what the Mac can and cannot do for it, and what
survives failures. The gesture on the device is the only way to erase a
device that the Mac cannot reach.

## Disconnect on the device

Hold two fingers on the screen for five seconds to open the native device menu.
Choose **Disconnect…**, then confirm **Disconnect** to erase the device.

- Lift either finger before five seconds: nothing happens.
- **Close** or tapping outside dismisses the menu without erasing anything.
- **Cancel** on confirmation returns to the device menu.
- The menu lists installed screens; two-finger swipes also switch between them.
- Ordinary one-finger taps and scrolls keep working in the dashboard.
- The native menu works over loading, error, and crashed web content.
- VoiceOver exposes the **Device menu** action.

What Disconnect removes:

| Removed | Notes |
| --- | --- |
| Active and staged dashboard packages | Including anything mid-transfer |
| Cache and saved state | All dashboard namespaces |
| Provisioned credentials | The device's Keychain copies only. Tokens keep working upstream until you revoke them in Home Assistant or the API provider |
| Pairing | The owner identity is cleared; any Mac may pair again |
| Pending operations | In-flight deployments are cancelled |

The device returns to **Ready to pair**. Nothing is sent to the Mac; if the
Mac still lists the device, Forget it there.

## From the Mac: Forget Device

**Forget Device** removes the Mac's saved record. It does not erase screens
or credentials on the device and does not revoke upstream tokens. Use the
device menu to disconnect and erase its local content.

## Re-pair

After Disconnect, forget any old Mac entry. Select the device under **Ready
to pair** and start pairing on the Mac, compare both codes, and confirm on
the device. A second Mac can pair only after the device is disconnected.

## Reinstalling the device app

Deleting and reinstalling Screenpunk on the device does not restore the old
pairing. On first launch after a fresh install, leftover Keychain items are
cleared rather than reused, and the device starts at **Ready to pair**.
Forget it on the Mac and pair again.

## Offline ring

A ring around the visible edge of the screen with a raised **Offline** tab
at the bottom means a required connection of the current dashboard failed
or its data is older than the dashboard allows. Last successful data stays
on screen.

| It is | It is not |
| --- | --- |
| Drawn by Screenpunk, above the dashboard, in the style guide's danger color | Something the dashboard can show, hide, or restyle |
| Cleared when every required connection is healthy again | A blinking alert or a blocking layer; taps pass through |
| Triggered by required connections only | Triggered by the Mac being off, asleep, or away |
| Absent for dashboards with no connections | Shown for optional connection failures; those stay in their widgets |

Recovery: check the network the device is on, the upstream service, and
whether a token expired or was revoked. If the connection's settings changed
on the Mac, deploy again so the device receives the new grant.

## Failure scenarios

| Scenario | What happens | What you do |
| --- | --- | --- |
| Transfer interrupted | The staged package is discarded; the active dashboard is untouched | Retry after the device reconnects. The same deployment ID reports the existing outcome rather than deploying twice |
| Activation acknowledgment lost | The active revision is durable on the device before it is ever acknowledged | Read `get_deployment` or the device's active revision before retrying |
| Deployed dashboard is broken | The device shows it; the gesture still works over it | Roll back or redeploy from the Mac, or Unlink on the device |
| Web-content process terminated | The host reloads the last package | Nothing. If it repeats, inspect the package with a preview |
| Device rebooted or iOS updated | Screenpunk is not running until you unlock and reopen it | Reopen it. The dashboard loads locally and reconnects; the Mac is not needed |
| Mac asleep, off, or elsewhere | No effect on deployed dashboards | Nothing |
| Local Network permission denied | Discovery and pairing fail | iOS: Settings > Privacy & Security > Local Network > Screenpunk. macOS: System Settings > Privacy & Security > Local Network > Screenpunk |
| Connection edited on the Mac | The device keeps its last authorized grant until a new deployment or grant sync reaches it | Deploy again |
| Different dashboard deployed | Obsolete grants, credentials, and state for the old dashboard are removed from the device | Nothing |
| Second Mac tries to pair | Rejected | Unlink on the device first if you intend to move it |

## What is never automatic

- Erasing a device from the Mac when the device is unreachable.
- Revoking Home Assistant or API tokens upstream.
- Restoring a pairing after a fresh install of the device app.
- Re-launching Screenpunk after a reboot.

## Automatic connection recovery

The Mac checks paired devices when it launches, becomes active, or wakes, and
continues checking while running. Bonjour discovery retries failed browsing and
address resolution every five seconds. Saved pairing identities are still
verified when reconnecting, including after a device's address or port changes.

The device checks its listener every five seconds while running and recreates
it after a failure. Returning to the foreground restarts its listener and Bonjour
advertisement. Recovery preserves pairing, installed screens, and credentials;
it does not require force-quitting or re-pairing. iOS can suspend the app in the
background, so keep Screenpunk visible when using the device as a display.
