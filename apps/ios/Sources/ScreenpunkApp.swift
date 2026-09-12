import SwiftUI
import ScreenpunkApple

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
        if let view = try? AppleHostRootView.offlineFixture() {
            view.ignoresSafeArea()
        } else {
            Text("Offline fixture missing")
                .padding()
        }
    }
}
