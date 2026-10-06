import SwiftUI
@_spi(ManagedRender) @_spi(NativeInstallation) import ScreenpunkApple

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
    @StateObject private var bootstrap = DeviceManagementBootstrap()
    @StateObject private var enrollment = NativeEnrollmentSceneController()
    @StateObject private var presentation = CloudProviderPresentation()
    @State private var accountSheet: CloudAccountSheet?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        GeometryReader { geometry in
        Group {
            if let content = enrollment.content, let lifetime = enrollment.presentationLifetime {
                DeviceManagedRenderView(content: content, lifetime: lifetime)
                    .overlay(alignment: .topTrailing) {
                        Button("Cloud account") { if accountSheet == nil { accountSheet = .requested() } }
                            .buttonStyle(.bordered).padding().accessibilityIdentifier("cloud.openAccount")
                    }
            } else {
        KioskLaunchView(bootstrap: bootstrap, onCloudAccountRequested: {
            guard accountSheet == nil else { return }
            accountSheet = .requested()
        })
            }
        }
            .environmentObject(cloud)
            .sheet(item: $accountSheet) { sheet in
                CloudAccountJourneyView(lifecycle: cloud, presentation: presentation, availability: sheet.availability,
                    enrollDevice: { account, location, name, profile in
                        enrollment.enroll(lifecycle: cloud, bootstrap: bootstrap, accountID: account, locationID: location, name: name, profile: profile, viewport: geometry.size)
                    }, enrollmentState: enrollment.state, deliveryMessage: enrollment.deliveryMessage,
                    viewScreen: enrollment.content == nil ? nil : { try enrollment.requireCurrentPresentation() },
                    retainedDeviceName: enrollment.retainedDeviceName, retainedDeviceProfile: enrollment.retainedDeviceProfile)
            }
            .onOpenURL { _ = cloud.dispatchGoogleCallback($0) }
            .onChange(of: scenePhase) { phase in
                cloud.scenePhaseChanged(phase)
                if phase == .background { enrollment.didEnterBackground() }
            }
        }
    }
}
