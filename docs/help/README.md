# Help topics

## Preserve user data across updates

Every screen that accepts user-entered data or preferences should persist them
with native `screenpunk.state.get/set/remove`. Keep dashboardId and versioned keys
stable, restore before defaults, save user edits, and preserve data on read or
migration failure. Check persistentState/persistentStateWritable; report unsupported
or read-only hosts. Verify values survive a screen update and app relaunch.
Device-local state is not remote agent access or cross-device sync; app deletion,
device reset and confirmed Disconnect can erase it. See [the authoring default](../../docs/screen-authoring-persistence.md).


Canonical user-help text for the alpha. The bundled `screenpunk-mcp`
executable returns these files verbatim for `get_help(topic:)` and exposes
them as MCP onboarding resources; the device's unpaired screen, the Unlink
panel, and the Mac's Forget dialog reuse the same wording. Edit the text
here, then update the copy constants that quote it.

| Topic | File | Also shown in |
| --- | --- | --- |
| `service` | [service.md](service.md) | CLI setup/service help, MCP onboarding, activation troubleshooting |
| `unlink` | [unlink.md](unlink.md) | Unlink panel, Forget dialog, unpaired screen, onboarding |
| `pairing` | [pairing.md](pairing.md) | Unpaired screen, Add Device |
| `offline` | [offline.md](offline.md) | Offline ring accessibility announcement |
| `diagnostics` | [diagnostics.md](diagnostics.md) | Tool error responses, `get_logs` |

Rules for every topic:

- Plain language. One heading, short paragraphs, no more than 2 KiB so the
  text fits bounded MCP output.
- No secrets, hostnames, entity names, or anything copied from a user's
  services.
- Never say the Mac can erase a device remotely, or that Unlink revokes
  tokens in Home Assistant or any other upstream service. It does not.
- Every topic that mentions resetting a device states the gesture exactly:
  hold two fingers on the screen for five seconds, open the device menu, choose **Disconnect**, and confirm.

An unknown topic returns this list of topics, not an error.
