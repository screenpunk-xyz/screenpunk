# Unified control qualification

Shipping app builds keep concurrent control disabled. A device build that has passed physical-device qualification may add `SCREENPUNK_CONCURRENT_CONTROL_QUALIFIED` to the app target's Swift compilation conditions. `CloudSceneRoot` supplies this build-owned value to `DeviceManagementBootstrap`; no account, pairing, or remote setting enables it.

Both enabled and disabled builds configure the durable device command coordinator under the existing device state root's `command-intents` directory. Factory reset owns that root. Disabling the compilation condition blocks new concurrent local commands and advertises capability version zero. It does not discard or reinterpret common inventory, command receipts, source roots, or mount history; retained inventory recovery and rendering remain available.

Qualification must exercise cloud and two separately approved local controllers, new package installation, duplicate delivery, stale generations, delayed preparation, disconnected cloud, restart recovery, mount failure, and the distinction between configured and actually mounted screens. A structural commit alone is not proof of visible activation. Cloud activation receipts follow the bound WebKit mount callback; authenticated LAN status reads the durable mounted receipt.

No connected physical device was available during the 2026-10-10 integration session. The existing iOS 26.5 simulator was reused. The production gate remains disabled until physical qualification has recorded its device/build identity and results.
