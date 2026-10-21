import SwiftUI
import Foundation
import UIKit
@_spi(ManagedRender) @_spi(NativeInstallation) import ScreenpunkCore
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

/// The app-owned phone journey is full screen; iPad keeps the shared modal family.
struct CloudAccountPresentation<Journey: View>: ViewModifier {
    @Binding var item: CloudAccountSheet?
    let journey: (CloudAccountSheet) -> Journey
    @ViewBuilder func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.fullScreenCover(item: $item) { sheet in journey(sheet).id(sheet.id) }
        } else {
            content.sheet(item: $item) { sheet in journey(sheet).id(sheet.id) }
        }
    }
}

/// Keeps the presentation owner independent of kiosk/runtime branch replacement.
struct CloudSceneAccountPresentationRoot<Root: View, Journey: View>: View {
    @Binding var item: CloudAccountSheet?
    let root: Root
    let journey: (CloudAccountSheet) -> Journey
    init(item: Binding<CloudAccountSheet?>, @ViewBuilder root: () -> Root,
         @ViewBuilder journey: @escaping (CloudAccountSheet) -> Journey) {
        _item = item; self.root = root(); self.journey = journey
    }
    var body: some View {
        ZStack { root }
            .modifier(CloudAccountPresentation(item: $item, journey: journey))
    }
}

extension CloudAccountJourneyActions {
    /// Keep all scene-owned metadata together when rebuilding the presented form.
    static func enrollment(lifecycle: CloudHumanSessionLifecycle, presentation: CloudProviderPresentation,
                           availability: CloudJourneyAvailability, controller: NativeEnrollmentSceneController,
                           connect: @escaping (UUID, UUID?, String) -> Void,
                           viewScreen: (() throws -> Void)? = nil,
                           makeSession: ((CloudProviderPresentation) throws -> CloudHumanSession)? = nil) -> Self {
        var actions = Self(lifecycle: lifecycle, presentation: presentation, availability: availability, makeSession: makeSession)
        actions.enrollDevice = connect; actions.viewScreen = viewScreen
        actions.enrollmentState = controller.state; actions.deliveryMessage = controller.deliveryMessage
        actions.enrollmentProgressMessage = controller.enrollmentProgressMessage
        actions.retainedDeviceName = controller.retainedDeviceName
        actions.suggestedDeviceName = controller.suggestedDeviceName
        actions.retainedAccountID = controller.retainedAccountID; actions.retainedLocationID = controller.retainedLocationID
        actions.deviceProfile = controller.retainedDeviceProfile ?? controller.suggestedDeviceProfile
        return actions
    }
}

/// A completion is offered only to the mounted sheet that admitted this explicit Connect.
struct CloudConnectPresentationIntent {
    private(set) var operationID: UUID?
    mutating func captureAdmission(previous: UUID?, admitted: UUID?) {
        guard let admitted, admitted != previous else { return }
        operationID = admitted
    }
    func matchingCompletion(_ completed: UUID?) -> UUID? {
        guard let operationID, completed == operationID else { return nil }
        return operationID
    }
}
struct CloudConnectionPresentationCompletion {
    let operationID: UUID
    let verify: () throws -> Void
}

/// Presentation owns a live subscription; sheet builders alone do not subscribe
/// the mounted journey to the scene controller's later progress and failures.
struct CloudEnrollmentAccountJourneyView: View {
    let lifecycle: CloudHumanSessionLifecycle
    let presentation: CloudProviderPresentation
    let availability: CloudJourneyAvailability
    @ObservedObject var controller: NativeEnrollmentSceneController
    let connect: (UUID, UUID?, String) -> Void
    var makeSession: ((CloudProviderPresentation) throws -> CloudHumanSession)? = nil
    var connectedSettings: (() -> AnyView)? = nil
    @State private var openedExistingInstallation: Bool
    @State private var connectionIntent = CloudConnectPresentationIntent()
    init(lifecycle: CloudHumanSessionLifecycle, presentation: CloudProviderPresentation,
         availability: CloudJourneyAvailability, controller: NativeEnrollmentSceneController,
         connect: @escaping (UUID, UUID?, String) -> Void,
         makeSession: ((CloudProviderPresentation) throws -> CloudHumanSession)? = nil,
         connectedSettings: (() -> AnyView)? = nil) {
        self.lifecycle = lifecycle; self.presentation = presentation; self.availability = availability
        self.controller = controller; self.connect = connect; self.makeSession = makeSession
        self.connectedSettings = connectedSettings
        // This is a presentation decision, not a live enrollment-state branch. Marking
        // a fresh installation must never tear down its still-owned human selection.
        _openedExistingInstallation = State(initialValue: controller.hasRecordedCloudInstallation)
    }
    private var actions: CloudAccountJourneyActions {
        var actions = CloudAccountJourneyActions.enrollment(lifecycle: lifecycle,
            presentation: presentation, availability: availability, controller: controller, connect: { account, location, name in
                let previous = controller.explicitConnectionOperationID
                connect(account, location, name)
                connectionIntent.captureAdmission(previous: previous, admitted: controller.explicitConnectionOperationID)
            }, makeSession: makeSession)
        if let operationID = connectionIntent.matchingCompletion(controller.completedExplicitConnectionOperationID) {
            actions.connectionCompletion = .init(operationID: operationID,
                verify: { try controller.requireExplicitConnectionCompletion(operationID: operationID) })
        }
        return actions
    }
    var body: some View {
        Group {
            if openedExistingInstallation, let connectedSettings { connectedSettings() }
            else { CloudAccountJourneyView(lifecycle: lifecycle, actions: actions) }
        }
    }
}

/// The same scene owner survives kiosk redraws; URL delivery never constructs a session.
struct CloudSceneRoot: View {
    @StateObject private var cloud: CloudHumanSessionLifecycle
    @StateObject private var bootstrap: DeviceManagementBootstrap
    @StateObject private var enrollment: NativeEnrollmentSceneController
    @StateObject private var presentation: CloudProviderPresentation
    @State private var accountSheet: CloudAccountSheet?
    private let connectDevice: ((UUID, UUID?, String) -> Void)?
    private let emptyMountReported: ((UUID) -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @MainActor init(cloud: CloudHumanSessionLifecycle? = nil,
         bootstrap: DeviceManagementBootstrap? = nil,
         enrollment: NativeEnrollmentSceneController? = nil,
         presentation: CloudProviderPresentation? = nil,
         accountSheet: CloudAccountSheet? = nil,
         connectDevice: ((UUID, UUID?, String) -> Void)? = nil,
         emptyMountReported: ((UUID) -> Void)? = nil) {
        _cloud = StateObject(wrappedValue: cloud ?? CloudHumanSessionLifecycle())
        _bootstrap = StateObject(wrappedValue: bootstrap ?? DeviceManagementBootstrap(concurrentControlQualified: ScreenpunkDeviceReleaseQualification.concurrentControl))
        _enrollment = StateObject(wrappedValue: enrollment ?? NativeEnrollmentSceneController())
        _presentation = StateObject(wrappedValue: presentation ?? CloudProviderPresentation())
        _accountSheet = State(initialValue: accountSheet); self.connectDevice = connectDevice
        self.emptyMountReported = emptyMountReported
    }
    var body: some View {
        GeometryReader { geometry in
        CloudSceneAccountPresentationRoot(item: $accountSheet) {
        Group {
            if hasCurrentDetachedManagedPresentation || enrollment.cloudLogoutCleanupPending || (!enrollment.isCloudLoggedOut &&
                (enrollment.hasRecordedCloudInstallation || enrollment.content != nil || enrollment.emptyDisplayGeneration != nil)) {
                DeviceCloudDisplayView(host: enrollment.commonHost, cloud: menuContent,
                    installationIdentity: enrollment.cloudConnectionIdentity, emptyGeneration: enrollment.emptyDisplayGeneration,
                    hasDisplayContent: enrollment.content != nil && enrollment.presentationLifetime != nil,
                    menuEnabled: accountSheet == nil,
                    emptyMounted: { generation in Task {
                        await enrollment.reportEmptyDisplayMounted(expectedGeneration: generation)
                        emptyMountReported?(generation)
                    } }) {
                    renderedContent
                }
            } else {
                KioskLaunchView(bootstrap: bootstrap, automaticStartup: false,
                    cloudRestoreInProgress: enrollment.state == .enrolling,
                    localScreenRestoreInProgress: localScreenRestoreInProgress,
                    hasUnfinishedCloudEnrollment: enrollment.hasUnfinishedCloudEnrollment,
                    onCloudAccountRequested: {
                        guard accountSheet == nil else { return }
                        accountSheet = .requested()
                    }, onLocalStartupRequested: {
                        await enrollment.requestLocalConnection(bootstrap: bootstrap)
                    })
            }
        }
        .overlay {
            if let host = enrollment.commonHost { ConcurrentControllerApprovalOverlay(host: host) }
        }
            .environmentObject(cloud)
        } journey: { sheet in
                CloudEnrollmentAccountJourneyView(lifecycle: cloud,
                    presentation: presentation, availability: sheet.availability, controller: enrollment,
                    connect: { account, location, name in
                        if let connectDevice { connectDevice(account, location, name) }
                        else { enrollment.enroll(lifecycle: cloud, bootstrap: bootstrap, accountID: account, locationID: location, name: name, viewport: geometry.size) }
                    }, connectedSettings: {
                        AnyView(DeviceCloudMenuView(host: enrollment.commonHost, cloud: menuContent,
                            page: .cloud, availableSize: geometry.size))
                    })
        }
            .onOpenURL { _ = cloud.dispatchGoogleCallback($0) }
            .onChange(of: bootstrap.rootGeneration) { _ in enrollment.reconnectInstallation(bootstrap: bootstrap) }
            .onChange(of: bootstrap.cloudAuthorityGeneration) { generation in
                if generation != nil && scenePhase == .active { enrollment.reconnectInstallation(bootstrap: bootstrap) }
            }
            .onChange(of: bootstrap.readyToValidateRecordedDetachedRestore) { ready in
                if ready && enrollment.isCloudLoggedOut && scenePhase == .active {
                    enrollment.reconnectInstallation(bootstrap: bootstrap)
                }
            }
            .onAppear {
                if enrollment.requiresDeviceOwnedStartup { bootstrap.useRecordedNativeCloudStartup() }
                bootstrap.start()
                enrollment.reconnectInstallation(bootstrap: bootstrap)
            }
            .onChange(of: scenePhase) { phase in
                cloud.scenePhaseChanged(phase)
                if phase == .background { enrollment.sceneDidEnterBackground() }
                else if phase == .active { enrollment.reconnectInstallation(bootstrap: bootstrap) }
            }
        }
    }
    /// A detached Local frame uses the same managed renderer without implying Cloud sign-in.
    /// This is pure routing state; asset loading and mount retain their existing authority checks.
    private var hasCurrentDetachedManagedPresentation: Bool {
        guard enrollment.isCloudLoggedOut, let content = enrollment.content,
              let lifetime = enrollment.presentationLifetime, !lifetime.isRetired else { return false }
        return enrollment.presentationFrames.contains { frame in
            guard frame.candidate, frame.content === content, frame.lifetime === lifetime,
                  let runtime = frame.runtime else { return false }
            return runtime.content === content
        }
    }
    private var localScreenRestoreInProgress: Bool {
        guard enrollment.localScreenRestoreInProgress else { return false }
        switch bootstrap.state {
        case .checking: return true
        case .resetting, .blocked: return false
        case .cloudReady, .localReady:
            return enrollment.hasActiveEnrollmentWork || bootstrap.readyForRecordedNativeRestore ||
                bootstrap.readyToValidateRecordedDetachedRestore
        }
    }
    private var menuContent: DeviceCloudMenuContent {
        let inventory = CloudDeviceScreenList(inventory: enrollment.displayScreenInventory)
        return .init(deviceName: enrollment.retainedDeviceName ?? enrollment.suggestedDeviceName ?? "Screenpunk",
            connectionDescription: CloudDeviceSettingsContent.description(enrollment.cloudConnectionState),
            connectionNeedsAttention: enrollment.cloudConnectionState == .needsAttention || enrollment.cloudConnectionState == .notConnected,
            screenSummary: inventory.summary, screenCount: inventory.count,
            installedManifests: enrollment.displayInstalledManifests,
            connectionInstallationID: enrollment.cloudLocalConnectionInstallationID,
            connectionManifests: enrollment.displayCloudInstalledManifests,
            activeManifest: enrollment.content?.manifest,
            settings: CloudDeviceSettingsView(enrollment: enrollment, lifecycle: cloud, bootstrap: bootstrap),
            screens: CloudDeviceScreensView(inventory: inventory))
    }
    private func presentationActivityCheck(for frame: NativeEnrollmentSceneController.PresentationFrame) -> @Sendable () -> Bool {
        switch frame.activityDomain {
        case .ordinary: return { true }
        case .detachedLocal: return frame.host?.retainedSceneActivityCheck() ?? { false }
        }
    }
    private var renderedContent: some View {
        ZStack {
            ForEach(enrollment.presentationFrames) { frame in
                Group {
                    if let runtime = frame.runtime {
                        DeviceManagedRuntimeView(runtime: runtime, lifetime: frame.lifetime,
                            presentationAllowed: presentationActivityCheck(for: frame),
                            serviceInvocation: { invocationID, bindingID, operation, input in
                                try await enrollment.invokeService(expectedContent: frame.content, expectedLifetime: frame.lifetime,
                                    invocationID: invocationID, bindingID: bindingID, operation: operation, input: input)
                            }, mounted: { try await enrollment.reportMountedContent(expectedContent: frame.content, expectedLifetime: frame.lifetime) },
                            failed: { code in await enrollment.reportMountFailed(expectedContent: frame.content, expectedLifetime: frame.lifetime, code: code) })
                    } else {
                        DeviceManagedRenderView(content: frame.content, lifetime: frame.lifetime,
                            serviceInvocation: { invocationID, bindingID, operation, input in
                                try await enrollment.invokeService(expectedContent: frame.content, expectedLifetime: frame.lifetime,
                                    invocationID: invocationID, bindingID: bindingID, operation: operation, input: input)
                            }, serviceMounted: { try await enrollment.reportMountedContent(expectedContent: frame.content, expectedLifetime: frame.lifetime) },
                            serviceMountFailed: { code in await enrollment.reportMountFailed(expectedContent: frame.content, expectedLifetime: frame.lifetime, code: code) })
                    }
                }.opacity(!frame.candidate || enrollment.candidateMounted || enrollment.retainedDisplayContent == nil ? 1 : 0)
            }
        }
    }
}

/// The common host remains observable while a cloud screen is displayed.
private struct ConcurrentControllerApprovalOverlay: View {
    @ObservedObject var host: DeviceLANHost
    var body: some View {
        ZStack(alignment: .topLeading) {
        if let request = host.pendingPairingRequest {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                PairingCodeView(code: request.code, waiting: host.awaitingControllerConfirm,
                    onCancel: { host.cancelPairing(expectedSessionNonceHex: request.sessionNonceHex) }) {
                        host.confirm(expectedSessionNonceHex: request.sessionNonceHex)
                    }.frame(maxWidth: 420).padding(24)
            }.accessibilityAddTraits(.isModal)
        }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Settings reads the current installation; it never creates a human sign-in session.
struct CloudDeviceSettingsView: View {
    @ObservedObject var enrollment: NativeEnrollmentSceneController
    let lifecycle: CloudHumanSessionLifecycle
    let bootstrap: DeviceManagementBootstrap
    var body: some View {
        CloudDeviceSettingsContent(state: enrollment.cloudConnectionState,
            deviceName: enrollment.retainedDeviceName ?? enrollment.suggestedDeviceName ?? "Screenpunk",
            connectionMessage: enrollment.cloudConnectionMessage,
            cloudLogoutCleanupPending: enrollment.cloudLogoutCleanupPending,
            disconnectInProgress: enrollment.disconnectInProgress,
            disconnectMessage: enrollment.disconnectMessage,
            canReset: enrollment.canFactoryReset, resetInProgress: enrollment.factoryResetInProgress,
            resetMessage: enrollment.factoryResetRecoveryMessage ?? enrollment.deliveryMessage,
            resetRecoveryPending: enrollment.intentRetirementPending,
            retry: { enrollment.retryCloudConnection(bootstrap: bootstrap) },
            logOut: { Task { await enrollment.disconnectCloudDevice(lifecycle: lifecycle) } },
            reset: { Task { await enrollment.factoryReset(lifecycle: lifecycle) } },
            localControllers: enrollment.commonHost.map { AnyView(CloudLocalControllerSettings(host: $0)) })
    }
}

struct CloudDeviceSettingsContent: View {
    let state: NativeEnrollmentSceneController.CloudConnectionState
    let deviceName: String
    var connectionMessage: String?
    var cloudLogoutCleanupPending = false
    var disconnectInProgress = false
    var disconnectMessage: String?
    var canReset = false
    var resetInProgress = false
    var resetMessage: String?
    var resetRecoveryPending = false
    let retry: () -> Void
    let logOut: () -> Void
    let reset: () -> Void
    var localConnections: AnyView? = nil
    var localControllers: AnyView? = nil
    @State private var confirmLogOut = false
    @State private var confirmReset = false
    @State private var resetRequested = false
    private var busy: Bool { disconnectInProgress || resetInProgress }
    static func description(_ state: NativeEnrollmentSceneController.CloudConnectionState) -> String {
        switch state {
        case .connected: return "Connected to Screenpunk Cloud"
        case .connecting: return "Connecting to Screenpunk Cloud…"
        case .needsAttention: return "Connection needs attention"
        case .notConnected: return "Not connected"
        }
    }
    var body: some View {
        Form {
            Section("Screenpunk Cloud") {
                Label(Self.description(state), systemImage: state == .connected ? "checkmark.icloud" : "cloud")
                    .accessibilityIdentifier("cloud.device.status")
                LabeledContent("Device name", value: deviceName)
                if state == .connecting {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Connecting to Cloud…").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                        .accessibilityElement(children: .combine).accessibilityLabel("Connecting to Cloud")
                        .accessibilityIdentifier("cloud.device.connecting")
                }
                if state == .needsAttention, let connectionMessage {
                    Text(connectionMessage).foregroundStyle(.secondary).accessibilityIdentifier("cloud.device.connectionMessage")
                }
                if state == .needsAttention || state == .connected {
                    Button(state == .connected ? "Check connection" : "Retry connection", action: retry)
                        .disabled(busy || cloudLogoutCleanupPending)
                        .accessibilityIdentifier("cloud.device.retry")
                }
            }
            Section {
                Button(cloudLogoutCleanupPending ? "Retry log out" : "Log out", role: .destructive) {
                    if cloudLogoutCleanupPending { logOut() }
                    else { confirmLogOut = true }
                }.disabled(busy || (state == .notConnected && !cloudLogoutCleanupPending))
                    .accessibilityIdentifier("cloud.device.logOut")
                if cloudLogoutCleanupPending {
                    Text("Finish logging out to remove this device’s Cloud credentials.")
                        .foregroundStyle(.secondary).accessibilityIdentifier("cloud.device.logOutCleanup")
                }
                if disconnectInProgress { ProgressView("Logging out…").accessibilityIdentifier("cloud.device.loggingOut") }
                if let disconnectMessage {
                    Text(disconnectMessage).foregroundStyle(.secondary).accessibilityIdentifier("cloud.device.logOutMessage")
                }
            } footer: {
                Text("Log out disconnects this device from Screenpunk Cloud. Local controller pairings, local screens, and your Cloud account are kept.")
            }
            if let localConnections { localConnections }
            if let localControllers { localControllers }
            Section {
                Button("Reset this device", role: .destructive) { confirmReset = true }
                    .disabled(busy || !canReset).accessibilityIdentifier("device.settings.reset")
                if resetInProgress { ProgressView("Resetting this device…") }
                if resetRequested || resetRecoveryPending, let resetMessage {
                    Text(resetMessage).foregroundStyle(.secondary).accessibilityIdentifier("device.settings.resetMessage")
                }
            } footer: {
                Text(canReset ? "Reset removes this device’s downloaded screens, local pairings, and connection credentials."
                    : "Reset is unavailable while device checks are incomplete.")
            }
        }
        .confirmationDialog("Log out of Screenpunk Cloud?", isPresented: $confirmLogOut, titleVisibility: .visible) {
            Button("Log out", role: .destructive, action: logOut)
            Button("Cancel", role: .cancel) {}
        } message: { Text("This disconnects the device. Local pairings, local screens, and your Cloud account stay unchanged.") }
        .confirmationDialog("Reset this device?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset this device", role: .destructive) { resetRequested = true; reset() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes downloaded screens, local controller pairings, and connection credentials from this device. Your Cloud account and projects remain.") }
    }
}

private struct CloudLocalControllerSettings: View {
    @ObservedObject var host: DeviceLANHost
    @State private var failed = false
    var body: some View {
        if !host.runtime.pairing.approvedControllers.isEmpty {
            Section("Local controllers") {
                ForEach(Array(host.runtime.pairing.approvedControllers.enumerated()), id: \.offset) { index, controller in
                    Button("Unpair controller \(index + 1)", role: .destructive) {
                        do { try host.server?.revokeLocalController(controller); host.refresh() }
                        catch { failed = true }
                    }
                }
                if failed { Text("The controller could not be unpaired. Try again.").foregroundStyle(.secondary) }
            }
        }
    }
}

enum CloudDeviceScreenList {
    struct Item: Identifiable { let id: UUID; let name: String }
    case available([Item], selected: UUID?)
    case unavailable
    /// Construction during layout consumes display metadata only.
    @MainActor init(enrollment: NativeEnrollmentSceneController) {
        self.init(inventory: enrollment.displayScreenInventory)
    }
    init(inventory: NativeEnrollmentSceneController.CloudScreenInventory?) {
        if let inventory {
            self = .available(inventory.entries.map { .init(id: $0.id, name: $0.name) }, selected: inventory.selectedEntryID)
        } else { self = .unavailable }
    }
    var count: Int? { if case .available(let items, _) = self { return items.count }; return nil }
    var summary: String {
        switch self {
        case .unavailable: return "Screen list unavailable"
        case .available(let items, let selected):
            return items.first { $0.id == selected }?.name ?? (items.isEmpty ? "No screens installed" : "No screen selected")
        }
    }
}

struct CloudDeviceScreensView: View {
    let inventory: CloudDeviceScreenList
    var body: some View {
        List {
            Section("On this device") {
                switch inventory {
                case .unavailable:
                    Text("The screen list is unavailable. View the Cloud connection status in Settings.").foregroundStyle(.secondary)
                case .available(let items, let selected):
                    if items.isEmpty { Text("No screens on this device").foregroundStyle(.secondary) }
                    ForEach(items) { item in
                        HStack {
                            Label(item.name, systemImage: "rectangle")
                            Spacer()
                            if item.id == selected { Image(systemName: "checkmark").accessibilityLabel("Current screen") }
                        }
                    }
                }
            }
            Section {
                Text("Assign and manage screens in Screenpunk Cloud.").foregroundStyle(.secondary)
            }
        }
    }
}
