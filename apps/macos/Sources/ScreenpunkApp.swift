import SwiftUI
import ScreenpunkApple
import ScreenpunkCore

@main
struct ScreenpunkApp: App {
    var body: some Scene {
        WindowGroup {
            AppleHostRoot()
                .frame(minWidth: 390, minHeight: 844)
        }
    }
}

private struct AppleHostRoot: View {
    var body: some View {
        if let view = try? DashboardRuntimeView.offlineFixture() {
            view
                .accessibilityLabel(
                    "Screenpunk \(PlatformRequirements.macOSMinimum) \(WebIsolation.customScheme)"
                )
        } else {
            Text("Offline fixture missing")
                .padding()
        }
    }
}
