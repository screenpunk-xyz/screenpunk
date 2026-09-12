import SwiftUI
import ScreenpunkApple

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
        if let view = try? AppleHostRootView.offlineFixture() {
            view
        } else {
            Text("Offline fixture missing")
                .padding()
        }
    }
}
