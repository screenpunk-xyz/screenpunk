# Toolchain

Pinned here so a clean checkout has a documented recipe. First GitHub run
must confirm runner labels, Xcode, and simulators. Do not treat this pin as
executed Apple evidence.

| Tool | Pin | Notes |
| --- | --- | --- |
| Xcode | 26+ | Required to compile the shared Icon Composer app icon; does not raise deployment targets. Apple CI/release builds select a compatible installed Xcode through `scripts/select-icon-xcode.sh`. |
| XcodeGen | 2.46.0 | Generate app projects from `project.yml`. CI installs the GitHub release zip (`sha256:4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`) via `scripts/ci/install-xcodegen.sh`. Do not commit `.xcodeproj`. |
| Node.js | 22 | SDK and Linux contract jobs |
| TypeScript | 5.9.2 | SDK compile |
| Swift (packages) | 5.9+ tools, Swift 6 language mode where hosts allow | ScreenpunkCore is Linux-testable |
| iOS deployment | 16.0 | Universal iPhone/iPad |
| macOS deployment | 14.0 | Apple silicon only; built with Xcode 26+ |
| Copyright owner | Screenpunk, Inc. | NOTICE, LICENSE appendix, XcodeGen `NSHumanReadableCopyright` |
| Bundle IDs | `xyz.screenpunk.*` | Operator-chosen: `xyz.screenpunk.ios`, `xyz.screenpunk.macos`, `xyz.screenpunk.preview-host`. Apple Developer portal registration is a later signing step |
| GitHub Linux | `ubuntu-24.04` | `contracts-and-sdk`, `core-linux`, `security-and-hygiene`, `required-checks` |
| Swift on Linux | 6.1.3 (`swift:6.1.3-noble@sha256:ed778a717c778240aa72f50e6c58e002d993fd445bc2516b484ba99c480dc25b`) | `core-linux` runs `./scripts/ci/core-linux.sh` (ScreenpunkCore `swift test`) in the official image. CryptoKit-only tests compile out here and run in `apple-build-and-unit`. Not Apple UI evidence |
| GitHub macOS | `macos-15` | Candidate image; availability and Xcode version unverified until CI runs |

## Actions (SHA-pinned)

| Action | Tag | SHA |
| --- | --- | --- |
| actions/checkout | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| actions/setup-node | v7.0.0 | `820762786026740c76f36085b0efc47a31fe5020` |
| actions/upload-artifact | v7.0.1 | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` |
| swift-actions/setup-swift | v2.4.0 | `7ca6abe6b3b0e8b5421b88be48feee39cbf52c6a` |

`macos-latest` is not used. The `macos-15` image's default Xcode may be
older than 26. `scripts/ci/apple.sh` and the signed archive helpers source
`scripts/select-icon-xcode.sh`: they honor an explicit compatible
`DEVELOPER_DIR`, use the selected Xcode when compatible, or select an installed
Xcode 26+ for that process. They fail clearly when none is available.
The system-wide `xcode-select` setting is never changed.

The unsigned DMG script already selects a macOS 26+ SDK through
`DEVELOPER_DIR`. Both product apps compile the shared
`assets/brand/app-icon/Screenpunk.icon`; Xcode generates legacy flat icons for
iOS/iPadOS 16+ and macOS 14+, while supported systems use Liquid Glass.
The preview helper deploys to macOS 14 and does not use this app icon. A failed
snapshot is `SNAPSHOT_UNAVAILABLE`, not a placeholder PNG.
