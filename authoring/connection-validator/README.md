# App-owned package connection validator

This validation-only closure is packaged with Screenpunk, not installed as an
authoring kit. `scripts/bundle-connection-validator.sh DESTINATION [NODE_ARCHIVE]`
verifies the existing Node archive pin and TypeScript parser pin, bundles the
shared AST validator with exact parse5 7.3.0, and emits licenses, SBOM and measured
inventory. `unsignedNodeSha256` measures the pre-signing image: release signing
changes it; the outer signed release manifest binds final bytes. Qualification
pins are not updated by packaging this closure.

Native package writes validate the frozen decoded files before any revision/head
publication. Plain-web never invokes the React compiler or selects a toolchain.
The runner uses its app-owned Node only, restricted filesystem reads, no child
process permission, a 256 MiB old-generation heap, 1 MiB stack, five seconds and
at most two concurrent processes. UTF-8 JavaScript plus HTML is limited to 5 MiB;
inline extraction is additionally limited to 512 scripts per package and 10 MiB
including preserved location padding. Parser failures preserve the previous head.

`validate.mjs` is byte-identical to cloud's `package-connections.mjs`. Both use the
same AST recognition implementation through their closed in-memory TypeScript
host. parse5 handles HTML tokenizer/tree semantics, including comments, quoted
attributes, raw script text and inert data script types. Diagnostics identify an
HTML member with `.inline-N.js` and original line/column. JavaScript script types
supported here are absent/empty, `module`, text/javascript, application/javascript,
text/ecmascript and application/ecmascript. Other legacy MIME aliases, event-handler
attributes, javascript: URLs, dynamically generated code, mutable aliases,
wrappers/factories and arbitrary interprocedural flow are not analyzed. Template
script content is conservatively scanned. Passing is not a runtime authorization
proof. Existing native CSP still rejects inline-script packages; parsing does not
relax that compatibility check.

Tests use a measured helper closure copied into the SwiftPM resource bundle after
building tests, then `swift test --skip-build`. Source checkout placeholders fail
closed with an actionable repair error; they do not fall back to system Node or a
user-installed kit. Keep source checkouts, test receipts and final measurements;
helper outputs and dependency trees are disposable after qualification.
