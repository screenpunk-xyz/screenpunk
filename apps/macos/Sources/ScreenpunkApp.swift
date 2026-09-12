import SwiftUI
import ScreenpunkCore

/// Compile stub. No first-party designed workbench in Milestone 0 bootstrap.
@main
struct ScreenpunkApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Screenpunk")
                .font(.body)
                .padding()
                .frame(minWidth: 480, minHeight: 320)
                .accessibilityLabel("Screenpunk \(PlatformRequirements.macOSMinimum)")
        }
    }
}
