import SwiftUI

/// The same scene owner survives kiosk redraws; URL delivery never constructs a session.
struct CloudSceneRoot: View {
    @StateObject private var cloud = CloudHumanSessionLifecycle()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        KioskLaunchView()
            .environmentObject(cloud)
            .onOpenURL { _ = cloud.handleCallback($0) }
            .onChange(of: scenePhase) { phase in
                cloud.scenePhaseChanged(phase)
            }
    }
}
