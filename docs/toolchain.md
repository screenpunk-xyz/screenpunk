# Toolchain

Pinned here so a clean checkout has a documented recipe. First GitHub run
must confirm runner labels, Xcode, and simulators. Do not treat this pin as
executed Apple evidence.

| Tool | Pin | Notes |
| --- | --- | --- |
| XcodeGen | 2.46.0 | Generate app projects from `project.yml`. Do not commit `.xcodeproj`. |
| Node.js | 22 | SDK and Linux contract jobs |
| TypeScript | 5.9.2 | SDK compile |
| Swift (packages) | 5.9+ tools, Swift 6 language mode where hosts allow | ScreenpunkCore is Linux-testable |
| iOS deployment | 16.0 | Universal iPhone/iPad |
| macOS deployment | 26.0 | Apple silicon only |
| Proposed bundle IDs | `xyz.screenpunk.ios`, `xyz.screenpunk.macos` | Not claimed as registered |
| GitHub Linux | `ubuntu-24.04` | `contracts-and-sdk`, `security-and-hygiene`, `required-checks` |
| GitHub macOS | `macos-15` | Candidate image; availability and Xcode version unverified until CI runs |

## Actions (SHA-pinned)

| Action | Tag | SHA |
| --- | --- | --- |
| actions/checkout | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| actions/setup-node | v7.0.0 | `820762786026740c76f36085b0efc47a31fe5020` |
| actions/upload-artifact | v7.0.1 | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` |
| swift-actions/setup-swift | v2.4.0 | `7ca6abe6b3b0e8b5421b88be48feee39cbf52c6a` |

`macos-latest` is not used. If `macos-15` cannot compile the macOS 26
deployment target, record the runner gap and keep Linux jobs green.
