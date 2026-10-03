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
            case .resetting: ProgressView("Removing saved device data…")
            case .localReady(let host): DeviceRuntimeRootView(host: host, onLocalReset: bootstrap.requestLocalReset).id(bootstrap.rootGeneration)
            case .blocked(let snapshot): VStack {
                if let message = bootstrap.statusMessage { Text(message).multilineTextAlignment(.center).padding() }
                DeviceManagementBlockedView(snapshot: snapshot, retry: bootstrap.retry)
            }
            }
        }
            .task { bootstrap.start() }
            .statusBarHidden(true)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = scenePhase == .active }
            .onChange(of: scenePhase) { UIApplication.shared.isIdleTimerDisabled = $0 == .active }
    }
}
