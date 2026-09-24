import SwiftUI
import UIKit
import ScreenpunkApple

struct KioskLaunchView: View {
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        DeviceRuntimeRootView.unpairedLoopback()
            .statusBarHidden(true)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = scenePhase == .active }
            .onChange(of: scenePhase) { UIApplication.shared.isIdleTimerDisabled = $0 == .active }
    }
}
