# Local connections in Cloud-delivered screens

Cloud screen packages may declare local connections. The unified device inventory preserves those declarations and renders the package through the managed runtime. A declaration does not carry credentials or grant access by itself.

For Home Assistant, open the device's Settings → Local connections → Home Assistant for the installed screen. Review its requested state reads, services, entities, and cameras, then enter the Home Assistant URL and access token. Enable local HTTP explicitly if needed. The token is stored in the device Keychain and is never sent to Screenpunk Cloud or screen JavaScript.

Approval binds to the installation, dashboard, revision, and manifest digest. A changed package needs fresh approval. Removing access blocks subsequent requests, including cached reads. Disconnect cleanup and factory reset remove these device approvals. Runtime requests still require the exact active mounted presentation and existing destination, service, entity, and camera policy checks.

Other local integrations continue to use their existing device permission flows. Declaring an unsupported integration does not create a credential or permission automatically. The legacy exclusive static-delivery path retains its capability restriction; this support uses the qualified unified-inventory path.

A terminal failed Cloud delivery cannot be restarted by reconnecting the device or replaying its operation ID. Correct the failure, review a deployment with a new operation ID, and confirm it. Existing screens remain installed unless the reviewed deployment explicitly removes them.
