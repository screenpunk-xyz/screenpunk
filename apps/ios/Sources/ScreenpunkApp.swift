import SwiftUI
import ScreenpunkCore

/// Compile stub. No first-party designed UI in Milestone 0 bootstrap.
@main
struct ScreenpunkApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Screenpunk")
                .font(.body)
                .padding()
                .accessibilityLabel("Screenpunk \(PlatformRequirements.iosMinimum)")
        }
    }
}
