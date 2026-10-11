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
    @StateObject private var bootstrap = DeviceManagementBootstrap(concurrentControlQualified: ScreenpunkDeviceReleaseQualification.concurrentControl)
    @StateObject private var enrollment = NativeEnrollmentSceneController()
    @StateObject private var presentation = CloudProviderPresentation()
    @State private var accountSheet: CloudAccountSheet?
    @State private var confirmFactoryReset = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        GeometryReader { geometry in
        Group {
            if let generation = enrollment.emptyDisplayGeneration {
                Color.black.ignoresSafeArea().id(generation)
                    .onAppear { Task { await enrollment.reportEmptyDisplayMounted(expectedGeneration: generation) } }
            } else if enrollment.content != nil, enrollment.presentationLifetime != nil {
                ZStack {
                    ForEach(enrollment.presentationFrames) { frame in
                        Group {
                            if let runtime = frame.runtime {
                                DeviceManagedRuntimeView(runtime: runtime, lifetime: frame.lifetime,
                                    serviceInvocation: { invocationID, bindingID, operation, input in
                                        try await enrollment.invokeService(expectedContent: frame.content, expectedLifetime: frame.lifetime, invocationID: invocationID, bindingID: bindingID, operation: operation, input: input)
                                    }, mounted: { try await enrollment.reportMountedContent(expectedContent: frame.content, expectedLifetime: frame.lifetime) },
                                    failed: { code in await enrollment.reportMountFailed(expectedContent: frame.content, expectedLifetime: frame.lifetime, code: code) })
                            } else {
                        DeviceManagedRenderView(content: frame.content, lifetime: frame.lifetime,
                            serviceInvocation: { invocationID, bindingID, operation, input in
                                try await enrollment.invokeService(expectedContent: frame.content, expectedLifetime: frame.lifetime, invocationID: invocationID, bindingID: bindingID, operation: operation, input: input)
                            }, serviceMounted: {
                                try await enrollment.reportMountedContent(expectedContent: frame.content, expectedLifetime: frame.lifetime)
                            }, serviceMountFailed: { code in
                                await enrollment.reportMountFailed(expectedContent: frame.content, expectedLifetime: frame.lifetime, code: code)
                            })
                            }
                        }
                            .opacity(!frame.candidate || enrollment.candidateMounted || enrollment.retainedDisplayContent == nil ? 1 : 0)
                    }
                }
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
            .overlay {
                if let host = enrollment.commonHost { ConcurrentControllerApprovalOverlay(host: host) }
            }
            .overlay(alignment: .topTrailing) {
                if enrollment.emptyDisplayGeneration != nil {
                    Button("Cloud account") { if accountSheet == nil { accountSheet = .requested() } }
                        .buttonStyle(.bordered).padding().accessibilityIdentifier("cloud.openAccount")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if enrollment.canFactoryReset {
                    Button("Reset this device", role: .destructive) { confirmFactoryReset = true }
                        .buttonStyle(.bordered).padding().accessibilityIdentifier("device.factoryReset")
                } else if let message = enrollment.factoryResetRecoveryMessage {
                    VStack(alignment: .trailing) {
                        Text(message).font(.caption).multilineTextAlignment(.trailing)
                        Button(enrollment.intentRetirementPending ? "Recover reset" : "Recover enrollment") {
                            if enrollment.intentRetirementPending { enrollment.reconnectInstallation(bootstrap: bootstrap) }
                            else if accountSheet == nil { accountSheet = .requested() }
                        }
                            .buttonStyle(.bordered).accessibilityIdentifier("device.recoverBeforeReset")
                    }.padding().frame(maxWidth: 320)
                }
            }
            .confirmationDialog("Reset this device?", isPresented: $confirmFactoryReset, titleVisibility: .visible) {
                Button("Reset this device", role: .destructive) { Task { await enrollment.factoryReset(lifecycle: cloud) } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes this device’s downloaded screens, local controller pairings, and cloud installation credentials. Your cloud account, projects, and cloud device record remain. Cloud disconnect and local unpairing are separate actions.")
            }
            .environmentObject(cloud)
            .sheet(item: $accountSheet) { sheet in
                CloudAccountJourneyView(lifecycle: cloud, presentation: presentation, availability: sheet.availability,
                    enrollDevice: { account, location, name in
                        enrollment.enroll(lifecycle: cloud, bootstrap: bootstrap, accountID: account, locationID: location, name: name, viewport: geometry.size)
                    }, enrollmentState: enrollment.state, deliveryMessage: enrollment.deliveryMessage,
                    viewScreen: enrollment.content == nil ? nil : { try enrollment.requireCurrentPresentation() },
                    retainedDeviceName: enrollment.retainedDeviceName)
            }
            .onOpenURL { _ = cloud.dispatchGoogleCallback($0) }
            .onChange(of: bootstrap.rootGeneration) { _ in enrollment.reconnectInstallation(bootstrap: bootstrap) }
            .onAppear { enrollment.reconnectInstallation(bootstrap: bootstrap) }
            .onChange(of: scenePhase) { phase in
                cloud.scenePhaseChanged(phase)
                if phase == .background { enrollment.didEnterBackground() }
                else if phase == .active { enrollment.reconnectInstallation(bootstrap: bootstrap) }
            }
        }
    }
}

/// Compile-time release qualification owned by the app build. Human sign-in and
/// remote account settings cannot enable a device protocol that has not qualified.
private enum ScreenpunkDeviceReleaseQualification {
    static var concurrentControl: Bool {
        #if SCREENPUNK_CONCURRENT_CONTROL_QUALIFIED
        true
        #else
        false
        #endif
    }
}

/// The common host remains observable while a cloud screen is displayed.
private struct ConcurrentControllerApprovalOverlay: View {
    @ObservedObject var host: DeviceLANHost
    @State private var unpairError = false
    var body: some View {
        ZStack(alignment: .topLeading) {
        if !host.runtime.pairing.approvedControllers.isEmpty {
            Menu("Local controllers") {
                ForEach(Array(host.runtime.pairing.approvedControllers.enumerated()), id: \.offset) { index, controller in
                    Button("Unpair controller \(index + 1)", role: .destructive) {
                        do { try host.server?.revokeLocalController(controller); host.refresh() }
                        catch { unpairError = true }
                    }
                }
            }.buttonStyle(.bordered).padding()
        }
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
        .alert("The controller could not be unpaired. Try again.", isPresented: $unpairError) {
            Button("OK", role: .cancel) {}
        }
    }
}
