import SwiftUI
import UIKit
import ScreenpunkApple

struct KioskLaunchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bootstrap = DeviceManagementBootstrap()
    var body: some View {
        Group {
            switch bootstrap.state {
            case .checking: ProgressView()
            case .localReady(let host): DeviceRuntimeRootView(host: host)
            case .blocked(let snapshot): DeviceManagementBlockedView(snapshot: snapshot, retry: bootstrap.start)
            }
        }
            .task { bootstrap.start() }
            .statusBarHidden(true)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = scenePhase == .active }
            .onChange(of: scenePhase) { UIApplication.shared.isIdleTimerDisabled = $0 == .active }
    }
}
