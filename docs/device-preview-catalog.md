# Device preview presets

## Preserve user data across updates

Every screen that accepts user-entered data or preferences should persist them
with native `screenpunk.state.get/set/remove`. Keep dashboardId and versioned keys
stable, restore before defaults, save user edits, and preserve data on read or
migration failure. Check persistentState/persistentStateWritable; report unsupported
or read-only hosts. Verify values survive a screen update and app relaunch.
Device-local state is not remote agent access or cross-device sync; app deletion,
device reset and confirmed Disconnect can erase it. See [the authoring default](../docs/screen-authoring-persistence.md).


The Screens header has a searchable, centered device picker. The catalog contains 237 presets spanning common Apple and Android families from 2018 through September 2026. It is broad coverage, not a sales ranking or a claim to include every regional variant. Model names, manufacturer and device category are searchable; all query terms must match. Arrow keys move the highlight and Return selects. Choosing a preset only changes the local preview, and the last choice persists.

Apple entries use the logical full-screen canvas and scale from Apple's installed CoreSimulator device capability plists. This correctly preserves the rendered viewport on devices such as iPhone 13 mini, whose logical canvas differs from panel pixels. Duplicate RAM configurations and pre-2018 models are omitted.

Android entries preserve manufacturer display proportions, rounded to a logical width of 412 for phones or 800 for tablet/inner-fold displays. These are aspect-ratio previews, not Android emulation: density settings, system bars, cutouts, hinges and OS behavior are not modeled. Pixel foldables include separate inner and outer displays; Samsung foldables identify the inner or main display. Galaxy Tab S10 Lite was omitted because the emulator-skin page's dimensions appeared inconsistent with the tablet product.

Sources checked September 13, 2026:

- Apple CoreSimulator `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/*/Contents/Resources/capabilities.plist`; public [iPhone comparison](https://www.apple.com/iphone/compare/) and [iPad comparison](https://www.apple.com/ipad/compare/).
- Samsung developer emulator specifications: [Galaxy S](https://developer.samsung.com/galaxy-emulator-skin/galaxy-s.html), [Galaxy A](https://developer.samsung.com/galaxy-emulator-skin/galaxy-a.html), [Galaxy Note](https://developer.samsung.com/galaxy-emulator-skin/galaxy-note.html), [Galaxy Tab](https://developer.samsung.com/galaxy-emulator-skin/galaxy-tab.html), [Galaxy Z](https://developer.samsung.com/galaxy-emulator-skin/galaxy-z.html).
- Google [current Pixel specifications](https://support.google.com/pixelphone/answer/7158570?hl=en) and [earlier Pixel specifications](https://support.google.com/pixelphone/answer/16043605?hl=en-GB).
- [OnePlus 13](https://www.oneplus.com/us/13/specs), [Redmi Note 13](https://www.mi.com/global/product/redmi-note-13/specs/), [Redmi Note 12](https://www.mi.com/global/product/redmi-note-12/specs/), [Motorola moto g power 5G (2023)](https://en-us.support.motorola.com/app/answers/detail/a_id/174789/~/specifications--moto-g-power-5g-%282023%29).

Orientation preview and the saved screen's supported orientations remain separate. The right side of the header holds the unlabeled Portrait/Landscape icons and a support dropdown. Unsupported preview directions stay disabled. Rename Screen lives beside Edit Screen, Duplicate Screen and Delete Screen in the title's overflow menu; renaming retains source files, connections, target and support settings.
