import SwiftUI

/// Presentation value only: complete configuration does not imply enrollment.
struct CloudAccountSheet: Identifiable {
    let id = UUID()
    let availability: CloudJourneyAvailability
    static func requested(configuration: () throws -> CloudNativeConfiguration = { try .load() }) -> Self {
        do {
            _ = try configuration() // Pure configuration validation, never SDK construction.
            return .init(availability: .qualified)
        } catch {
            return .init(availability: .unavailable("Cloud account access is not configured for this build. Contact the test organizer."))
        }
    }
}

/// The same scene owner survives kiosk redraws; URL delivery never constructs a session.
struct CloudSceneRoot: View {
    @StateObject private var cloud = CloudHumanSessionLifecycle()
    @StateObject private var presentation = CloudProviderPresentation()
    @State private var accountSheet: CloudAccountSheet?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        KioskLaunchView(onCloudAccountRequested: {
            guard accountSheet == nil else { return }
            accountSheet = .requested()
        })
            .environmentObject(cloud)
            .sheet(item: $accountSheet) { sheet in
                CloudAccountJourneyView(lifecycle: cloud, presentation: presentation, availability: sheet.availability)
            }
            .onOpenURL { _ = cloud.dispatchGoogleCallback($0) }
            .onChange(of: scenePhase) { phase in
                cloud.scenePhaseChanged(phase)
            }
    }
}
