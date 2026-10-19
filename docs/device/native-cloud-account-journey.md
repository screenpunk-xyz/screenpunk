# Native Cloud account journey components

These four app files provide an unmounted account journey and scene-bound provider presenter. The production scene and launch routes do not mount this view yet. Provider configuration, entitlements, live sign-in, installation enrollment and account deletion remain separate release requirements.

Only an explicit provider action constructs the complete retained human session through an injected factory. Rendering does not initialize a provider. The view shows account/workspace discovery, explicit first-workspace creation when permitted, exact pending-request recovery, and pending/failed sign-out with explicit retry. A human identity or workspace receipt never claims that the device is connected to Cloud.

The presenter resolves an attached controller and window in the same foreground scene. Official provider controls preserve their labels and disabled behavior. Provider full-screen presentation must not revoke the in-progress sign-in. Explicit Close and actual UIKit dismissal share one cancellation guard; generic SwiftUI disappearance is not used as a cancellation signal. The existing scene lifecycle owns background revocation.

Qualification used exact be2d63af plus the four files: 72 iPhone iOS 17.5 tests, 19 iPad iOS 26.5 tests and a generic Simulator build passed. A fake full-screen provider regression reproduced cancellation on generic disappearance before the repair. The final controls verify provider-cover survival, actual dismissal revocation and duplicate cancellation suppression without live SDK authentication or network access.

Accessibility-size screenshots cover provider entry at phone and tablet dimensions. Signed-in, pending recovery and sign-out states have control tests, not visual qualification. No claim is made for a mounted production journey, iOS 16 runtime, physical devices, VoiceOver or configured provider interoperability.
