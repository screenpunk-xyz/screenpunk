import SwiftUI
import UIKit
import ScreenpunkApple

@MainActor
struct KioskLaunchView: View {
    let onCloudAccountRequested: (() -> Void)?
    init(bootstrap: DeviceManagementBootstrap? = nil, onCloudAccountRequested: (() -> Void)? = nil) {
        _bootstrap = StateObject(wrappedValue: bootstrap ?? DeviceManagementBootstrap())
        self.onCloudAccountRequested = onCloudAccountRequested
    }
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bootstrap: DeviceManagementBootstrap
    private var startupDetails: String {
        var lines = ["Startup attempt: \(bootstrap.startupAttempt)"]
        if let diagnostic = bootstrap.startupDiagnostic {
            lines.append("Startup stage: \(diagnostic.stage.rawValue)")
            if let code = diagnostic.systemError { lines.append("System error code: \(code)") }
            if diagnostic.retryChecksOriginalStateOnly {
                lines.append("Retry checks saved state only; no reset or recovery is guaranteed.")
            }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Group {
            switch bootstrap.state {
            case .checking: ProgressView()
            case .resetting: ProgressView("Removing saved device data…")
            case .localReady(let host): DeviceRuntimeRootView(host: host, onLocalReset: bootstrap.requestLocalReset, onCloudAccountRequested: onCloudAccountRequested).id(bootstrap.rootGeneration)
            case .blocked(let snapshot):
                DeviceManagementBlockedView(snapshot: snapshot, message: bootstrap.statusMessage,
                                            diagnosticDetails: startupDetails,
                                            retryCount: Int(clamping: bootstrap.startupAttempt > 0 ? bootstrap.startupAttempt - 1 : 0),
                                            resetLocalData: bootstrap.canResetBlockedLocalData ? bootstrap.requestBlockedLocalReset : nil,
                                            retry: bootstrap.retry)
            }
        }
            .task { bootstrap.start() }
            .statusBarHidden(true)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = scenePhase == .active }
            .onChange(of: scenePhase) { UIApplication.shared.isIdleTimerDisabled = $0 == .active }
    }
}
