import SwiftUI
import ScreenpunkApple

@main
struct ScreenpunkApp: App {
    var body: some Scene {
        WindowGroup {
            DeviceRuntimeRootView.unpairedLoopback()
        }
    }
}
