import SwiftUI
import ScreenpunkApple
import ScreenpunkCore

@main
struct ScreenpunkApp: App {
    var body: some Scene {
        WindowGroup {
            AppleHostRoot()
        }
    }
}

private struct AppleHostRoot: View {
    var body: some View {
        if let view = try? DashboardRuntimeView.offlineFixture() {
            view
                .ignoresSafeArea()
                .accessibilityLabel(
                    "Screenpunk \(PlatformRequirements.iosMinimum) \(WebIsolation.customScheme)"
                )
        } else {
            Text("Offline fixture missing")
                .padding()
        }
    }
}
