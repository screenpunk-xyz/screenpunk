import SwiftUI
import UIKit
import ScreenpunkApple

/// Public accessibility APIs report an active session, not the Settings toggle.
/// Remember explicit setup confirmation so subsequent launches show activation help.
struct KioskLaunchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("guidedAccessSetupConfirmed") private var setupConfirmed = false
    @State private var showingHelp = false
    @State private var checkedLaunch = false
    @State private var guidedAccessActive = UIAccessibility.isGuidedAccessEnabled

    var body: some View {
        DeviceRuntimeRootView.unpairedLoopback()
            .statusBarHidden(true)
            .onAppear { updateActivity(scenePhase) }
            .onChange(of: scenePhase) { phase in
                updateActivity(phase)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
                guidedAccessActive = UIAccessibility.isGuidedAccessEnabled
                if guidedAccessActive {
                    setupConfirmed = true
                    showingHelp = false
                }
            }
            .sheet(isPresented: $showingHelp) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Image(systemName: "lock.display").font(.largeTitle).accessibilityHidden(true)
                            Text(guidedAccessActive ? "Guided Access is active" : setupConfirmed ? "Start Guided Access" : "Keep Screenpunk on screen")
                                .font(.title.bold())
                            if guidedAccessActive {
                                Text("This device is already locked to Screenpunk. Continue to your screen.")
                            } else {
                                Text("Guided Access keeps this device in Screenpunk and helps prevent accidental exits.")
                                if !setupConfirmed {
                                    instruction("1. Turn it on", "Open Settings → Accessibility → Guided Access. Turn it on and set a passcode under Passcode Settings. For an always-on display, set Display Auto-Lock to Never if available.")
                                }
                                instruction(setupConfirmed ? "Activate it" : "2. Start it in Screenpunk", "Dismiss this guide first. Triple-click the side button on iPhone, the top button on iPad, or the Home button on older devices. Choose Guided Access if prompted, then tap Start if the setup screen appears. Leave Touch enabled to use screen controls and scrolling.")
                                instruction("End a session", "Use the Guided Access button shortcut, authenticate, then tap End. On iOS 18 or earlier, the authentication shortcut may use a double-click.")
                                if !setupConfirmed {
                                    Button("I’ve turned on Guided Access") { setupConfirmed = true }
                                        .buttonStyle(.bordered)
                                } else {
                                    Button("Show setup instructions") { setupConfirmed = false }
                                }
                            }
                            Button("Continue to Screenpunk") { showingHelp = false }
                                .buttonStyle(.borderedProminent)
                        }.padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingHelp = false } } }
                }.statusBarHidden(true)
            }
    }

    private func updateActivity(_ phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase == .active
        guard phase == .active else { return }
        guidedAccessActive = UIAccessibility.isGuidedAccessEnabled
        if !checkedLaunch {
            checkedLaunch = true
            showingHelp = true
        }
    }

    private func instruction(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
