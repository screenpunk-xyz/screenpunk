# Screen transfer limits

The updated Mac and device apps support a **32 MiB (33,554,432 bytes)** encoded
LAN message, increased from 2 MiB. One screen-set deployment sends all selected
screens together, so they share that budget. The limit covers the complete JSON
envelope, including base64 asset data and JSON escaping. It is not a raw-file
budget: binary assets alone consume approximately four encoded bytes for each
three source bytes, plus metadata and escaping. Actual raw capacity is less
than approximately 24 MiB and varies by content.

This affects deployment, not live camera streaming bandwidth. The existing
per-package validation limits (25 MiB compressed, 50 MiB expanded) are separate;
passing package validation does not guarantee an entire selected set fits in
one transfer. This change does not add compression or chunked transfers.

Devices advertise `maxTransferBytes` in the backward-compatible `hello` reply.
A missing or invalid advertisement retains the old 2 MiB limit. The controller
uses the smaller of its own bound and the advertised bound, measures the actual
encoded envelope, and reports the required size and permitted size before
sending assets. A device with the old app receives an update instruction. Both
Mac and device apps must be updated to use the larger limit. Existing pairing
and deployed screens survive the app updates.

Only the pinned paired owner can send frames over 2 MiB. Other connections keep
the previous 2 MiB bound, checked from the length header before receiving the
body. All connections retain the absolute 32 MiB cap. Paired transfer bodies and
deployment requests have a 60-second timeout; other connections keep a maximum
15-second body timeout. Normal package hash/path validation and atomic screen-set
activation still apply; oversized or failed transfers keep the current screens.

Regression coverage includes negotiated legacy limits, exact encoded-envelope
size preflight, frame-length boundaries, and a real TLS screen-set deployment
with an original generated 3 MiB fixture that survives a device-runtime reload.
