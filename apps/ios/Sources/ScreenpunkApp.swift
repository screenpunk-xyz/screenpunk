import SwiftUI
import ScreenpunkApple
import ScreenpunkCore

/// Compile stub. Isolation policy is wired; no first-party designed UI.
@main
struct ScreenpunkApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Screenpunk")
                .font(.body)
                .padding()
                .accessibilityLabel(
                    "Screenpunk \(PlatformRequirements.iosMinimum) \(WebIsolation.customScheme)"
                )
                .accessibilityValue(WebIsolation.nativeNetworkingOnly ? "native-network" : "open")
        }
    }
}
