# ADR: React is a web authoring option

Status: implemented web authoring; native renderer deferred.

React/TypeScript is compiled ahead of time into the existing schema-1 web package.
WKWebView owns its rendering surface. The package store owns revisions, hashes,
digests and validation; the native connection runtimes own networking and grants.
React components never receive credentials. Plain JavaScript packages remain valid.

The production-only esbuild pipeline emits a classic script and static CSS. It
inlines dynamic imports into that script and retains local assets. There is no
runtime npm resolver, development server, SSR, server routes or runtime code splitting.
No renderer field or manifest migration was introduced.

The host's runtime status now includes an optional `active` Boolean. The existing
SDK event delivers it without a protocol change; old consumers ignore it and the
React adapter treats its absence as active, combined with document visibility.
Readiness describes the mounted interface, not live-data availability. Effects
cancel and subscriptions detach on suspension, then read-only work resumes. Actions
are never automatically replayed.

A future renderer contract should accept a *validated package* and a restricted
host-capability interface. It mounts one surface, reports ready/error, and handles
activate, suspend and dispose. Installation, identity, grants, persistence, screen
switching and native services stay in the host. This is an interface sketch, not an
unused production abstraction.

A React Native renderer would be a separate surface selected per package, with
explicit runtime/module compatibility. Native modules ship with an app update;
package deployment cannot add arbitrary native modules. Its isolation model differs
from WKWebView and requires a separate trust assessment. UI trees do not automatically
port; only suitable data models and business logic can be shared.

Swift Codable currently ignores unknown manifest keys. Consequently, adding an
optional `renderer: react-native` field would NOT make older clients reject native
packages. Before native implementation, introduce and test explicit version/capability
negotiation with deterministic rejection. Packages without a selector remain web.

Revisit only for a concrete measured use case that cannot meet requirements with
web rendering plus a targeted host capability. Assess memory, startup, app size,
platform support, preview parity, isolation, dependency maintenance and distribution.
Bluetooth/camera access alone is not sufficient justification, and React Native
cannot bypass OS background restrictions. No React Native runtime is shipped here.
