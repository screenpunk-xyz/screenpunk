# Milestone 0 feasibility

1. Hidden AppKit/WKWebView helper — `tools/preview-host` plus
   `./scripts/ci/preview.sh`. Linux cannot produce this image. A missing or
   failed capture is `SNAPSHOT_UNAVAILABLE`, never a placeholder PNG.
2. iOS 16 host isolation — `packages/ScreenpunkCore` + `ScreenpunkApple`
   plus `isolation/attacks.json` (fetch/XHR/WS, remote code, navigation,
   iframe, traversal, file URL, bridge spoof, content-process failure).
3. Pairing identity pin + matching-code SAS — `pairing/vectors.json`.
   HMAC-SHA256 transcript MAC, 2 minute expiry, 5 failures, MITM / key-change
   / second-owner rejection. No real credentials.

Apple compile and the first `apple-*` jobs install pinned XcodeGen 2.46.0
on the macOS runner. macOS 26 SDK absence is recorded, not faked.
