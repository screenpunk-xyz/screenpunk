# Hidden preview snapshot

`tools/preview-host` can take a WKWebView `takeSnapshot` of
`SCREENPUNK_PREVIEW_FIXTURE_V1` when a macOS toolchain and window server
are actually available.

This worker environment is Linux. Do not check in a placeholder PNG.

MCP preview uses the same helper. `SCREENPUNK_PACKAGE_DIR` renders a
validated dashboard package through `screenpunk://` and waits for
`runtime.ready()`. The feasibility fixture path (`SCREENPUNK_SNAPSHOT=1`
without a package dir) is unchanged.

On GitHub `macos-15`, `./scripts/ci/preview.sh` compiles the helper and
attempts a snapshot. If WebKit cannot produce a PNG it writes
`SNAPSHOT_UNAVAILABLE` to `last-attempt.txt` and exits 0. That is a recorded
gap, not screenshot evidence.

Never replace a failed capture with a generated stand-in image.
