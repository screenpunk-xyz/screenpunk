import SwiftUI
import UIKit
import ScreenpunkApple
import ScreenpunkCore

@MainActor
struct KioskLaunchView: View {
    let automaticStartup: Bool
    let cloudRestoreInProgress: Bool
    let localScreenRestoreInProgress: Bool
    let hasUnfinishedCloudEnrollment: Bool
    let onLocalStartupRequested: (() async -> String?)?
    let onCloudAccountRequested: (() -> Void)?
    init(bootstrap: DeviceManagementBootstrap? = nil, automaticStartup: Bool = true, cloudRestoreInProgress: Bool = false, localScreenRestoreInProgress: Bool = false, hasUnfinishedCloudEnrollment: Bool = false, onCloudAccountRequested: (() -> Void)? = nil, onLocalStartupRequested: (() async -> String?)? = nil) {
        _bootstrap = StateObject(wrappedValue: bootstrap ?? DeviceManagementBootstrap())
        self.automaticStartup = automaticStartup
        self.cloudRestoreInProgress = cloudRestoreInProgress
        self.localScreenRestoreInProgress = localScreenRestoreInProgress
        self.hasUnfinishedCloudEnrollment = hasUnfinishedCloudEnrollment
        self.onCloudAccountRequested = onCloudAccountRequested
        self.onLocalStartupRequested = onLocalStartupRequested
    }
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bootstrap: DeviceManagementBootstrap
    @State private var enteredLocalStartup = false
    @State private var localStartupInProgress = false
    @State private var localStartupFailure: String?
    @State private var visibleOnboarding: Set<UUID> = []
    private var showsWelcome: Bool {
        if localScreenRestoreInProgress { return false }
        if hasUnfinishedCloudEnrollment && !enteredLocalStartup { return true }
        if case .cloudReady = bootstrap.state { return !cloudRestoreInProgress }
        return false
    }
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

    private var startupRetryCount: Int {
        let attempt: UInt = bootstrap.startupAttempt
        let retries: UInt = attempt > 0 ? attempt - 1 : 0
        return Int(clamping: retries)
    }

    private var blockedResetAction: (() -> Void)? {
        guard bootstrap.canResetBlockedLocalData else { return nil }
        return { bootstrap.requestBlockedLocalReset() }
    }

    private func blockedView(_ snapshot: DeviceRetainedContentSnapshot) -> DeviceManagementBlockedView {
        DeviceManagementBlockedView(snapshot: snapshot, message: bootstrap.statusMessage,
                                    diagnosticDetails: startupDetails, retryCount: startupRetryCount,
                                    resetLocalData: blockedResetAction,
                                    retry: { bootstrap.retry() })
    }

    private func requestLocalStartup() {
        guard !localStartupInProgress else { return }
        enteredLocalStartup = true
        localStartupFailure = nil
        guard let onLocalStartupRequested else { bootstrap.retry(); return }
        localStartupInProgress = true
        Task { @MainActor in
            localStartupFailure = await onLocalStartupRequested()
            localStartupInProgress = false
        }
    }

    var body: some View {
        Group {
            if localScreenRestoreInProgress {
                ProgressView("Starting local connection…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("device.localScreenRestoring")
            } else if hasUnfinishedCloudEnrollment, !enteredLocalStartup, let onCloudAccountRequested {
                DeviceOnboardingWelcomeView(cloud: onCloudAccountRequested, local: requestLocalStartup)
            } else {
                switch bootstrap.state {
                case .checking: ProgressView()
                case .resetting: ProgressView("Removing saved device data…")
                case .cloudReady:
                    if cloudRestoreInProgress {
                        ProgressView("Connecting device…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if enteredLocalStartup {
                        if localStartupInProgress {
                            ProgressView("Starting local connection…").frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            DeviceOnboardingLocalView(state: .failed(message: localStartupFailure ?? bootstrap.statusMessage ?? "The local connection could not start. Try again."),
                                confirm: {}, decline: {}, retry: requestLocalStartup,
                                cancel: { enteredLocalStartup = false }, done: { enteredLocalStartup = false })
                        }
                    } else if let onCloudAccountRequested {
                        DeviceOnboardingWelcomeView(cloud: onCloudAccountRequested, local: requestLocalStartup)
                    }
                case .localReady(let host): DeviceRuntimeRootView(host: host, onLocalReset: bootstrap.requestLocalReset,
                    onCloudAccountRequested: onCloudAccountRequested, startWithLocalPairing: enteredLocalStartup, onOnboardingVisibilityChanged: { id, visible in
                        if visible { visibleOnboarding.insert(id) } else { visibleOnboarding.remove(id) }
                    }).id(bootstrap.rootGeneration)
                case .blocked(let snapshot):
                    blockedView(snapshot)
                }
            }
        }
            .background(ScreenpunkOnboardingWindowProbe(portraitActive: showsWelcome || !visibleOnboarding.isEmpty, sizeChanged: { _ in })
                .frame(width: 0, height: 0).accessibilityHidden(true))
            .task { if automaticStartup { bootstrap.start() } }
            .statusBarHidden(true)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = scenePhase == .active }
            .onChange(of: scenePhase) { UIApplication.shared.isIdleTimerDisabled = $0 == .active }
    }
}
