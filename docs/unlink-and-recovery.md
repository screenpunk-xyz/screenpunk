# Unlink and recovery

How to reset a device, what the Mac can and cannot do for it, and what
survives failures. The gesture on the device is the only way to erase a
device that the Mac cannot reach.

## Unlink on the device

Hold two fingers anywhere on the screen for ten continuous seconds. A small
native panel appears with the text "Unlinking removes the dashboard and
connection credentials." and exactly one button: **Unlink**.

- Lift either finger before ten seconds: nothing happens.
- Tap outside the panel: it closes and nothing changes.
- Tap **Unlink**: the reset happens immediately. There is no second
  confirmation.
- Ordinary one-finger taps and scrolls keep working in the dashboard; the
  gesture does not interfere with them.
- The gesture works over a loading page, an error page, and a crashed
  web-content process. The panel is native and sits above the web view;
  dashboard code cannot draw, block, or dismiss it.
- VoiceOver: focus the dashboard, swipe up or down to the **Unlink**
  custom action, and double-tap. The same panel opens.

What Unlink removes:

| Removed | Notes |
| --- | --- |
| Active and staged dashboard packages | Including anything mid-transfer |
| Cache and saved state | All dashboard namespaces |
| Provisioned credentials | The device's Keychain copies only. Tokens keep working upstream until you revoke them in Home Assistant or the API provider |
| Pairing | The owner identity is cleared; any Mac may pair again |
| Pending operations | In-flight deployments are cancelled |

The device returns to **Ready to pair**. Nothing is sent to the Mac; if the
Mac still lists the device, Forget it there.

## From the Mac: Unlink or Forget

| Device reachable | Action | Result |
| --- | --- | --- |
| Yes | **Unlink** | The Mac asks the device to erase itself, waits for the acknowledgment, then removes its own record. It reports the actual acknowledgment, not an assumption |
| No | **Forget** | The Mac removes its record immediately. The device is unchanged. The Mac shows: "This Mac has forgotten the device. To remove its dashboard and pairing, hold two fingers on its screen for 10 seconds, then tap Unlink." |

Forget is not a remote wipe. Neither action revokes upstream tokens.

## Re-pair

After Unlink, pair from the Mac again. If the Mac still lists the device
under **Devices**, select it and press **Pair Again**; otherwise it
reappears under **Add Device** and you press **Pair**. Fresh identities and
a fresh code are used. If the Mac still has an old record for the device,
the device now presents a different identity; the Mac treats that as an
identity change and requires re-pairing, so Forget the old record first if
Pair Again is refused. A second Mac can pair only after the device has been
unlinked.

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
