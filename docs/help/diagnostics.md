# Diagnostics

Where to look when something does not work.

| Result | Meaning | What to do |
| --- | --- | --- |
| `not_paired` | The device is not paired with this Mac | Pair it (`get_help` topic `pairing`) |
| `permission_required` | A connection or operation is not approved yet | Approve it in Screenpunk on the Mac. Agents cannot approve |
| `revision_conflict` | The dashboard changed since your base revision | Read the current revision and retry from it |
| `unsupported_version` | Package schema or bridge version is not supported | Use schema major 1 and the bundled SDK |
| `device_offline` | The device is unreachable for deploy | Bring it to the foreground on the same network and retry. Its current dashboard is untouched |
| `render_timeout` | The preview page never signaled ready | Read the returned diagnostics: missing asset, JavaScript error, or `runtime.ready()` never called |
| `validation_failed` | The package was rejected before transfer | Read the reasons: size limits, paths, missing files, credential-like strings |

Logs from `get_logs` contain status codes, operation IDs, timestamps, and
redacted host labels, never request bodies or secrets. They are bounded to
5 MiB per host and are never uploaded anywhere.

Preview renders on the Mac and identifies itself as a Mac preview; it is
not an iOS simulator. Preview needs the Mac awake and logged in. A preview
that shows a loading or error page is not a successful preview.

If a deployment's outcome is uncertain, call `get_deployment` or read the
device's active revision before retrying. Retrying the same deployment ID
reports the existing outcome instead of deploying twice.

To reset a device completely, hold two fingers on its screen for ten
seconds, then tap **Unlink** (`get_help` topic `unlink`).
