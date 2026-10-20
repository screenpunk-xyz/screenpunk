import ScreenpunkApple
import ScreenpunkCore
import SwiftUI
import UIKit

/// Caller qualification is separate from configuration completeness. Production is unmounted.
enum CloudJourneyAvailability { case unavailable(String), qualified }

/// Explicit user actions only; this retains the scene's existing owner, never creates another one.
@MainActor
struct CloudAccountJourneyActions {
    let lifecycle: CloudHumanSessionLifecycle
    let presentation: CloudProviderPresentation
    let availability: CloudJourneyAvailability
    let makeSession: ((CloudProviderPresentation) throws -> CloudHumanSession)?
    var enrollDevice: ((UUID, UUID?, String) -> Void)?
    var enrollmentState: NativeEnrollmentSceneController.State = .idle
    var deliveryMessage: String?
    var retainedDeviceName: String?
    var retainedAccountID: UUID?
    var retainedLocationID: UUID?
    var suggestedDeviceName: String?
    var deviceProfile: String?
    var enrollmentProgressMessage: String?
    var viewScreen: (() throws -> Void)?
    var connectionCompletion: CloudConnectionPresentationCompletion?
    var enabled: Bool { if case .qualified = availability { return true }; return false }
    init(lifecycle: CloudHumanSessionLifecycle, presentation: CloudProviderPresentation,
         availability: CloudJourneyAvailability,
         makeSession: ((CloudProviderPresentation) throws -> CloudHumanSession)? = nil) {
        self.lifecycle = lifecycle; self.presentation = presentation; self.availability = availability; self.makeSession = makeSession
    }
    @discardableResult func signIn(_ provider: CloudNativeSignInProvider) throws -> Task<Void, Never>? {
        guard enabled else { throw CloudNativeIdentityError.notConfigured }
        switch lifecycle.accountEntryState {
        case .occupiedElsewhere: throw CloudHumanSessionBroker.Failure.occupied
        case .retired: throw CloudHumanSessionLifecycle.Failure.retired
        case .available, .ownedHere: break
        }
        if lifecycle.coordinator == nil { try lifecycle.installExplicit(presentation: presentation, testFactory: makeSession) }
        guard let coordinator = lifecycle.coordinator else { throw CloudNativeIdentityError.providerFailed }
        return coordinator.signIn(provider: provider)
    }
    @discardableResult func chooseAccount(_ id: UUID) -> Task<Void, Never>? {
        enabled ? lifecycle.coordinator?.discoverLocations(accountID: id) : nil
    }
    @discardableResult func create(workspace: String, location: String) -> Task<Void, Never>? {
        guard enabled, lifecycle.coordinator?.canCreateFirstWorkspace == true else { return nil }
        return lifecycle.coordinator?.createFirstWorkspace(workspaceName: workspace, locationName: location)
    }
    @discardableResult func recover() -> Task<Void, Never>? { enabled ? lifecycle.coordinator?.recoverWorkspaceSetup() : nil }
    @discardableResult func retry() -> Task<Void, Never>? { enabled ? lifecycle.coordinator?.retryWorkspaceSetup() : nil }
    @discardableResult func signOut() -> Task<Void, Never>? { lifecycle.signOut() }
    @discardableResult func retrySignOut() -> Task<Void, Never>? { lifecycle.retrySignOut() }
    @discardableResult func retryRetiredCleanup(_ handle: CloudHumanSessionBroker.RetiredCleanupHandle) -> Task<Void, Never>? {
        lifecycle.retryRetiredCleanup(handle)
    }
    func cancel() { lifecycle.cancelPresentation() }

    /// A retry uses the saved intent even when a redraw has newer editable inputs.
    func connectDevice(accountID: UUID, locationID: UUID?, name: String) {
        guard enabled, enrollmentState != .enrolling,
              retainedAccountID == nil || retainedAccountID == accountID else { return }
        enrollDevice?(retainedAccountID ?? accountID,
            retainedAccountID != nil ? retainedLocationID : locationID,
            retainedDeviceName ?? name)
    }
}

/// The suggestion is applied once, including when it arrives after the form mounts.
/// A deliberate edit (even clearing the field) wins over later OS suggestions.
struct CloudEnrollmentNameDraft {
    private(set) var name = ""
    private var appliedSuggestion = false
    private var manuallyEdited = false
    init(suggestedName: String? = nil) { applySuggestion(suggestedName) }
    mutating func applySuggestion(_ suggestion: String?) {
        guard !manuallyEdited, !appliedSuggestion, let suggestion, !suggestion.isEmpty else { return }
        name = suggestion; appliedSuggestion = true
    }
    mutating func edit(_ value: String) { name = value; manuallyEdited = true }
    func displayedName(retainedName: String?) -> String { retainedName ?? name }
}

/// Visibility never assigns a location. Hidden choices leave the original nil default intact.
struct CloudEnrollmentChoices {
    let accounts: [CloudNativeAccount]
    let locations: [CloudNativeLocation]
    let retainedAccountID: UUID?
    let retainedLocationID: UUID?
    private let retainedLocationName: String?
    init(accounts: [CloudNativeAccount], locations: [CloudNativeLocation], retainedAccountID: UUID?,
         retainedLocationID: UUID?, enrollment: Bool) {
        self.accounts = enrollment ? accounts.filter { $0.capabilities.canEnroll } : accounts
        self.locations = enrollment ? locations.filter { $0.capabilities.canEnroll } : locations
        self.retainedAccountID = retainedAccountID; self.retainedLocationID = retainedLocationID
        retainedLocationName = locations.first(where: { $0.id == retainedLocationID })?.name
    }
    var showsWorkspaceSelector: Bool { retainedAccountID == nil && accounts.count > 1 }
    var showsLocationSelector: Bool { retainedAccountID == nil && locations.count > 1 }
    var retainedLocationSummary: String? {
        guard retainedAccountID != nil, retainedLocationID != nil else { return nil }
        return retainedLocationName ?? "Saved location"
    }
    func unassignedPermissionMessage(accountID: UUID?, selectedLocationID: UUID?) -> String? {
        guard retainedAccountID == nil, selectedLocationID == nil,
              let account = accounts.first(where: { $0.id == accountID }), !account.capabilities.canEnrollUnassigned else { return nil }
        return showsLocationSelector ? "Choose a location to connect this device."
            : "This workspace requires a location. Choose another workspace or ask a workspace administrator to connect this device."
    }
}

private enum CloudJourneyPanelPart: Hashable { case header, body, footer }
private struct CloudJourneyPanelHeightKey: PreferenceKey {
    static var defaultValue: [CloudJourneyPanelPart: CGFloat] = [:]
    static func reduce(value: inout [CloudJourneyPanelPart: CGFloat], nextValue: () -> [CloudJourneyPanelPart: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
private extension View {
    func measureCloudPanel(_ part: CloudJourneyPanelPart) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: CloudJourneyPanelHeightKey.self, value: [part: proxy.size.height])
        })
    }
}
private struct CloudJourneyPanelPresentation: ViewModifier {
    let height: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.presentationSizing(.fitted.fitted(horizontal: true, vertical: true))
        } else if #available(iOS 16.4, *) {
            content.background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .presentationBackground(.clear).presentationDragIndicator(.hidden)
                .presentationDetents([.height(height)])
        } else {
            content.presentationDetents([.height(height)])
        }
    }
}

private struct CloudJourneyPanelSizing: ViewModifier {
    let height: CGFloat
    let width: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
        } else {
            content.frame(minWidth: 0, idealWidth: width, maxWidth: width,
                          minHeight: 0, idealHeight: height, maxHeight: height)
                .modifier(CloudJourneyPanelPresentation(height: height))
        }
    }
}

/// Actual rendered element bounds support whole-presentation layout qualification.
enum CloudJourneyRenderedElement: Hashable { case header, close, footer, primaryAction, appleCTA, googleCTA, bodyViewport, progress }
private struct CloudJourneyRenderedBoundsObserverKey: EnvironmentKey {
    static let defaultValue: ((CloudJourneyRenderedElement, CGRect) -> Void)? = nil
}
extension EnvironmentValues {
    var cloudJourneyRenderedBoundsObserver: ((CloudJourneyRenderedElement, CGRect) -> Void)? {
        get { self[CloudJourneyRenderedBoundsObserverKey.self] }
        set { self[CloudJourneyRenderedBoundsObserverKey.self] = newValue }
    }
}
extension View {
    func recordCloudJourneyBounds(_ element: CloudJourneyRenderedElement) -> some View {
        modifier(CloudJourneyRecordRenderedBounds(element: element))
    }
}
private struct CloudJourneyRecordRenderedBounds: ViewModifier {
    let element: CloudJourneyRenderedElement
    @Environment(\.cloudJourneyRenderedBoundsObserver) private var observer
    @ViewBuilder func body(content: Content) -> some View {
        if let observer {
            content.background(CloudJourneyRenderedBoundsProbe(element: element, observer: observer).accessibilityHidden(true))
        } else { content }
    }
}
private struct CloudJourneyRenderedBoundsProbe: UIViewRepresentable {
    let element: CloudJourneyRenderedElement
    let observer: (CloudJourneyRenderedElement, CGRect) -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.record = { observer(element, $0) }; view.setNeedsLayout()
    }
    final class Probe: UIView {
        var record: ((CGRect) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.record?(self.convert(self.bounds, to: window))
            }
        }
    }
}

private struct CloudJourneyScrollBehavior: ViewModifier {
    let overflows: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.scrollBounceBehavior(.basedOnSize, axes: .vertical)
        } else {
            content.scrollDisabled(!overflows)
        }
    }
}

private struct CloudJourneyObservedHeader: View {
    @ObservedObject var coordinator: CloudConnectionCoordinator
    let close: () -> Void
    var body: some View { CloudJourneyHeader(showsSubtitle: coordinator.humanIdentity == nil, close: close) }
}
private struct CloudJourneyHeader: View {
    let showsSubtitle: Bool
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            closeButton
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to Screenpunk Cloud").font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("cloud.header").recordCloudJourneyBounds(.header)
                if showsSubtitle {
                    Text("Sign in to view your workspaces.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 28).padding(.vertical, 24)
            .frame(minHeight: 128, alignment: .top)
    }
    private var closeLabel: some View {
        Image(systemName: "xmark").font(.system(size: 17, weight: .regular)).foregroundStyle(Color.primary)
    }
    @ViewBuilder private var closeButton: some View {
        if #available(iOS 26, *) {
            Button(action: close) { closeLabel }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                .frame(width: 44, height: 44).tint(.primary)
                .accessibilityLabel("Close").accessibilityIdentifier("cloud.close").recordCloudJourneyBounds(.close)
        } else {
            Button(action: close) {
                closeLabel.frame(width: 44, height: 44)
                    .background(Color(uiColor: .secondarySystemFill), in: Circle())
            }.buttonStyle(.plain).tint(.primary)
                .accessibilityLabel("Close").accessibilityIdentifier("cloud.close").recordCloudJourneyBounds(.close)
        }
    }
}

private struct CloudAccountJourneyFooter: View {
    @ObservedObject var coordinator: CloudConnectionCoordinator
    let actions: CloudAccountJourneyActions
    let name: String
    let locationID: UUID?
    var body: some View {
        if coordinator.humanIdentity == nil, coordinator.signOutState == .idle || coordinator.signOutState == .succeeded {
            CloudSignInLegalDisclaimer()
        } else if coordinator.humanIdentity != nil, actions.enrollDevice != nil {
            Button {
                if let accountID = coordinator.selectedAccountID {
                    actions.connectDevice(accountID: accountID, locationID: locationID, name: name)
                }
            } label: {
                Text(title).frame(maxWidth: .infinity).padding(.vertical, 4)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!canConnect).accessibilityIdentifier("cloud.connectDevice").recordCloudJourneyBounds(.primaryAction)
        }
    }
    private var title: String {
        switch actions.enrollmentState {
        case .currentInstallation: return "Connecting device…"
        case .needsAttention, .screenDeliveryNeedsAttention: return actions.retainedAccountID == nil ? "Connect device" : "Retry connection"
        case .idle, .enrolling: return "Connect device"
        }
    }
    private var canConnect: Bool {
        guard actions.enabled, !coordinator.isWorking, coordinator.signOutState == .idle,
              actions.enrollmentState != .enrolling, actions.enrollmentState != .currentInstallation, let accountID = coordinator.selectedAccountID,
              actions.retainedAccountID == nil || actions.retainedAccountID == accountID,
              !(actions.retainedDeviceName ?? name).isEmpty else { return false }
        let selectedLocation = actions.retainedAccountID != nil ? actions.retainedLocationID : locationID
        return coordinator.accounts.contains { $0.id == accountID && $0.capabilities.canEnroll && (selectedLocation != nil || $0.capabilities.canEnrollUnassigned) }
            && (selectedLocation == nil || coordinator.locations.contains { $0.id == selectedLocation && $0.capabilities.canEnroll })
    }
}

/// Human identity/workspace UI and an injected explicit device intent.
/// Human receipts never grant installation/enrollment authority.
struct CloudAccountJourneyView: View {
    @ObservedObject private var lifecycle: CloudHumanSessionLifecycle
    private let actions: CloudAccountJourneyActions
    @Environment(\.dismiss) private var dismiss
    @State private var actionMessage: String?
    @State private var deviceName = CloudEnrollmentNameDraft()
    @State private var selectedLocationID: UUID?
    @State private var panelHeights: [CloudJourneyPanelPart: CGFloat] = [:]
    @State private var windowSize = CGSize(width: 800, height: 1000)
    @State private var dismissalCancellation = CloudJourneyDismissalCancellation()
    @State private var dismissedConnectionOperationID: UUID?
    init(lifecycle: CloudHumanSessionLifecycle, presentation: CloudProviderPresentation,
         availability: CloudJourneyAvailability = .unavailable("Cloud sign-in is not available in this version."),
         makeSession: ((CloudProviderPresentation) throws -> CloudHumanSession)? = nil,
         enrollDevice: ((UUID, UUID?, String) -> Void)? = nil,
         enrollmentState: NativeEnrollmentSceneController.State = .idle,
         deliveryMessage: String? = nil, viewScreen: (() throws -> Void)? = nil,
         retainedDeviceName: String? = nil, suggestedDeviceName: String? = nil,
         retainedAccountID: UUID? = nil, retainedLocationID: UUID? = nil,
         deviceProfile: String? = nil, enrollmentProgressMessage: String? = nil) {
        self.lifecycle = lifecycle
        var actions = CloudAccountJourneyActions(lifecycle: lifecycle, presentation: presentation, availability: availability, makeSession: makeSession)
        actions.enrollDevice = enrollDevice; actions.enrollmentState = enrollmentState
        actions.deliveryMessage = deliveryMessage; actions.viewScreen = viewScreen
        actions.retainedDeviceName = retainedDeviceName
        actions.suggestedDeviceName = suggestedDeviceName
        actions.retainedAccountID = retainedAccountID; actions.retainedLocationID = retainedLocationID
        actions.deviceProfile = deviceProfile; actions.enrollmentProgressMessage = enrollmentProgressMessage
        self.actions = actions
        _deviceName = State(initialValue: CloudEnrollmentNameDraft(suggestedName: actions.suggestedDeviceName))
        _selectedLocationID = State(initialValue: actions.retainedLocationID)
    }
    init(lifecycle: CloudHumanSessionLifecycle, actions: CloudAccountJourneyActions) {
        self.lifecycle = lifecycle; self.actions = actions
        _deviceName = State(initialValue: CloudEnrollmentNameDraft(suggestedName: actions.suggestedDeviceName))
        _selectedLocationID = State(initialValue: actions.retainedLocationID)
    }
    private var preferredHeight: CGFloat {
        // One ordinary panel size for both app-owned sign-in and confirmation.
        // Additional choices, diagnostics and large text can request more room.
        min(max(500, (panelHeights[.header] ?? 128) + (panelHeights[.body] ?? 180) + (panelHeights[.footer] ?? 112) + 1),
            max(200, windowSize.height - 96))
    }
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                signInHeader.fixedSize(horizontal: false, vertical: true).measureCloudPanel(.header)
                Divider().opacity(0.5)
                GeometryReader { viewport in
                    if let coordinator = lifecycle.coordinator, lifecycle.accountEntryState == .ownedHere {
                        CloudJourneyLoadingOverlay(coordinator: coordinator, actions: actions) {
                            scrollContent(viewport: viewport.size)
                        }
                    } else {
                        scrollContent(viewport: viewport.size)
                    }
                }
                footer.fixedSize(horizontal: false, vertical: true).measureCloudPanel(.footer)
                    .recordCloudJourneyBounds(.footer)
            }.frame(width: container.size.width, height: container.size.height)
        }
        .background(CloudPresentationAnchor(presentation: actions.presentation).frame(width: 0, height: 0).accessibilityHidden(true))
        .background(CloudJourneyDismissalObserver(cancel: { dismissalCancellation.cancel(actions.cancel) }).frame(width: 0, height: 0).accessibilityHidden(true))
        .background(ScreenpunkOnboardingWindowProbe(portraitActive: true, sizeChanged: { windowSize = $0 })
            .frame(width: 0, height: 0).accessibilityHidden(true))
        .modifier(CloudJourneyPanelSizing(height: preferredHeight, width: min(580, windowSize.width - 32)))
        .onPreferenceChange(CloudJourneyPanelHeightKey.self) { panelHeights = $0 }
        .onAppear {
            dismissalCancellation.reset()
            deviceName.applySuggestion(actions.suggestedDeviceName)
        }
        .onChange(of: actions.suggestedDeviceName) { deviceName.applySuggestion($0) }
        .onChange(of: lifecycle.accountEntryState) { _ in actionMessage = nil }
        .task(id: actions.connectionCompletion?.operationID) { completeExplicitConnection() }
    }
    private func scrollContent(viewport: CGSize) -> some View {
        ScrollView {
            middleContent.fixedSize(horizontal: false, vertical: true)
                .measureCloudPanel(.body)
                .frame(minHeight: viewport.height, alignment: .center)
        }.modifier(CloudJourneyScrollBehavior(overflows: (panelHeights[.body] ?? 0) > viewport.height + 1))
            .accessibilityIdentifier("cloud.scrollContent")
            .recordCloudJourneyBounds(.bodyViewport)
    }
    private var middleContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch lifecycle.retiredCleanupState {
            case .pending:
                ProgressView("Finishing previous sign-out…").accessibilityIdentifier("cloud.retiredCleanupPending")
            case .failed(let handle):
                VStack(alignment: .leading, spacing: 12) {
                    Text("Previous sign-out could not finish.")
                    Button("Retry sign-out") { actions.retryRetiredCleanup(handle) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("cloud.retryRetiredCleanup")
                }
            case .none:
                switch lifecycle.accountEntryState {
                case .available: providerEntry
                case .ownedHere:
                    if let coordinator = lifecycle.coordinator {
                        CloudAccountJourneyContent(coordinator: coordinator, actions: actions, signIn: signIn, deviceName: $deviceName, selectedLocationID: $selectedLocationID)
                    } else {
                        Text("Cloud account access is already active in this window.").foregroundStyle(.secondary)
                    }
                case .occupiedElsewhere:
                    Text(CloudJourneyCopy.occupiedWindow).foregroundStyle(.secondary).accessibilityIdentifier("cloud.occupiedWindow")
                case .retired:
                    Text(CloudJourneyCopy.retiredWindow).foregroundStyle(.secondary).accessibilityIdentifier("cloud.retiredWindow")
                }
            }
            if let actionMessage { Text(actionMessage).foregroundStyle(.secondary).accessibilityIdentifier("cloud.actionError") }
        }.padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var signInHeader: some View {
        if let coordinator = lifecycle.coordinator {
            CloudJourneyObservedHeader(coordinator: coordinator, close: close)
        } else {
            CloudJourneyHeader(showsSubtitle: true, close: close)
        }
    }
    private func completeExplicitConnection() {
        guard actions.enrollmentState == .currentInstallation, let completion = actions.connectionCompletion,
              dismissedConnectionOperationID != completion.operationID else { return }
        do {
            try dismissalCancellation.preserveCompletedTransition(completion.verify)
            dismissedConnectionOperationID = completion.operationID
            dismiss()
        } catch {
            actionMessage = "Screen connection needs verification. Check again."
        }
    }
    private func close() {
        dismissalCancellation.cancel(actions.cancel); dismiss()
    }
    @ViewBuilder private var footer: some View {
        if let viewScreen = actions.viewScreen {
            Button {
                do { try dismissalCancellation.preserveCompletedTransition(viewScreen); dismiss() }
                catch { actionMessage = "Screen connection needs verification. Check again." }
            } label: { Text("View screen").frame(maxWidth: .infinity).padding(.vertical, 4) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("cloud.viewScreen").recordCloudJourneyBounds(.primaryAction).padding(.horizontal, 28).padding(.vertical, 24)
                .frame(minHeight: 112)
        } else if lifecycle.accountEntryState == .ownedHere, let coordinator = lifecycle.coordinator {
            CloudAccountJourneyFooter(coordinator: coordinator, actions: actions, name: deviceName.name, locationID: selectedLocationID)
                .padding(.horizontal, 28).padding(.vertical, 24).frame(minHeight: 112)
        } else if lifecycle.accountEntryState == .available, lifecycle.retiredCleanupState == .none {
            CloudSignInLegalDisclaimer().padding(.horizontal, 28).padding(.vertical, 24).frame(minHeight: 112)
        }
    }
    private var providerEntry: some View {
        VStack(alignment: .leading, spacing: 20) {
            CloudNativeProviderButtons(enabled: actions.enabled,
                apple: { signIn(.apple) }, google: { signIn(.google) })
                .frame(maxWidth: 420).frame(maxWidth: .infinity)
            if case .unavailable(let message) = actions.availability {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sign-in unavailable").font(.subheadline.weight(.semibold))
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
    private func signIn(_ provider: CloudNativeSignInProvider) {
        actionMessage = nil
        do { try actions.signIn(provider) }
        catch {
            actionMessage = CloudJourneyCopy.signInFailure(error)
        }
    }
}

private struct CloudSignInLegalDisclaimer: View {
    var body: some View {
        Text("By continuing, you agree to Screenpunk’s [Terms of Use](https://screenpunk.xyz/terms) and acknowledge its [Privacy Policy](https://screenpunk.xyz/privacy).")
            .font(.footnote).foregroundStyle(.secondary)
            .tint(.accentColor).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("cloud.signIn.legal")
    }
}

/// Keep the form mounted while progress replaces its visible body. Drafts and
/// pending intent survive authentication/discovery and enrollment redraws.
private struct CloudJourneyLoadingOverlay<Content: View>: View {
    @ObservedObject var coordinator: CloudConnectionCoordinator
    let actions: CloudAccountJourneyActions
    @ViewBuilder let content: () -> Content
    private var enrolling: Bool { actions.enrollmentState == .enrolling || actions.enrollmentState == .currentInstallation }
    private var busy: Bool { enrolling || coordinator.isWorking }
    private var message: String {
        if enrolling { return "Connecting device…" }
        return coordinator.humanIdentity == nil ? "Signing in…" : "Loading your workspace…"
    }
    var body: some View {
        content().opacity(busy ? 0 : 1).accessibilityHidden(busy).allowsHitTesting(!busy)
            .overlay {
                if busy {
                    ProgressView(message).multilineTextAlignment(.center)
                        .accessibilityIdentifier(enrolling ? "cloud.enrollmentProgress" : "cloud.progress")
                        .recordCloudJourneyBounds(.progress)
                        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
    }
}

private struct CloudAccountJourneyContent: View {
    @ObservedObject var coordinator: CloudConnectionCoordinator
    let actions: CloudAccountJourneyActions
    let signIn: (CloudNativeSignInProvider) -> Void
    @Binding var deviceName: CloudEnrollmentNameDraft
    @Binding var selectedLocationID: UUID?
    init(coordinator: CloudConnectionCoordinator, actions: CloudAccountJourneyActions, signIn: @escaping (CloudNativeSignInProvider) -> Void,
         deviceName: Binding<CloudEnrollmentNameDraft>, selectedLocationID: Binding<UUID?>) {
        self.coordinator = coordinator; self.actions = actions; self.signIn = signIn
        _deviceName = deviceName; _selectedLocationID = selectedLocationID
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch coordinator.signOutState {
            case .pending:
                ProgressView("Signing out…")
                Text("Sign-out is waiting for the current sign-in to finish.").foregroundStyle(.secondary)
            case .failed:
                Text("Sign-out could not finish.")
                Button("Retry sign-out") { actions.retrySignOut() }.buttonStyle(.borderedProminent).accessibilityIdentifier("cloud.retrySignOut")
            case .idle, .succeeded:
                if let identity = coordinator.humanIdentity {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(identity.user.email ?? identity.user.displayName).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2).accessibilityIdentifier("cloud.signedInIdentity")
                        Spacer(minLength: 0)
                        Button("Sign out") { actions.signOut() }.font(.subheadline).accessibilityIdentifier("cloud.signOut")
                    }
                    CloudWorkspaceJourney(coordinator: coordinator, actions: actions, deviceName: $deviceName, selectedLocationID: $selectedLocationID)
                } else {
                    if coordinator.signOutState == .succeeded { Text("Signed out.") }
                    if case .unavailable(let message) = actions.availability { Text(message).foregroundStyle(.secondary) }
                    CloudNativeProviderButtons(enabled: actions.enabled && !coordinator.isWorking,
                        apple: { signIn(.apple) }, google: { signIn(.google) })
                }
            }
            if let message = CloudJourneyCopy.failure(coordinator.failure, setup: coordinator.workspaceSetupFailure) {
                Text(message).foregroundStyle(.secondary).accessibilityIdentifier("cloud.failure")
            }
        }
    }
}

private struct CloudWorkspaceJourney: View {
    @ObservedObject var coordinator: CloudConnectionCoordinator
    let actions: CloudAccountJourneyActions
    @State private var workspace = ""
    @State private var location = ""
    @Binding var deviceName: CloudEnrollmentNameDraft
    @Binding var selectedLocationID: UUID?
    @State private var attemptedDefaultWorkspace = false
    @AppStorage("screenpunk.lastEnrollmentWorkspace") private var lastEnrollmentWorkspace = ""
    init(coordinator: CloudConnectionCoordinator, actions: CloudAccountJourneyActions,
         deviceName: Binding<CloudEnrollmentNameDraft>, selectedLocationID: Binding<UUID?>) {
        self.coordinator = coordinator; self.actions = actions
        _deviceName = deviceName; _selectedLocationID = selectedLocationID
    }
    private var enabled: Bool { actions.enabled && !coordinator.isWorking }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let receipt = coordinator.workspaceSetupReceipt {
                Label("Workspace setup completed", systemImage: "checkmark.circle").accessibilityIdentifier("cloud.setupCompleted")
                // Receipt IDs stay out of the product copy; they do not prove device connection.
                Text("Your workspace setup has been saved.").foregroundStyle(.secondary).id(receipt.requestId)
            }
            if let pending = coordinator.pendingWorkspaceSetup {
                Text("Workspace setup awaiting confirmation").font(.headline)
                LabeledContent("Workspace", value: pending.request.workspaceName)
                LabeledContent("Location", value: pending.request.locationName)
                recoveryButtons
            } else if coordinator.failure == .persistence {
                Text("Workspace setup needs recovery before another workspace can be created.")
                recoveryButtons
            } else if coordinator.canCreateFirstWorkspace {
                Text("Create your first workspace").font(.headline)
                TextField("Workspace name", text: $workspace).textFieldStyle(.roundedBorder).accessibilityIdentifier("cloud.workspaceName")
                TextField("Location name", text: $location).textFieldStyle(.roundedBorder).accessibilityIdentifier("cloud.locationName")
                Button("Create workspace") { actions.create(workspace: workspace, location: location) }
                    .buttonStyle(.borderedProminent).disabled(!enabled || workspace.isEmpty || location.isEmpty).accessibilityIdentifier("cloud.createWorkspace")
            }
            if actions.enrollDevice != nil, !coordinator.accounts.isEmpty {
                enrollmentConfirmation
            } else {
                workspaceSelection
                if actions.enrollDevice != nil { enrollmentStatus }
                if coordinator.selectedAccountID != nil {
                    locationSelection
                    locationDiscoveryStatus
                }
            }
            if case .api(status: 401, error: _)? = coordinator.workspaceSetupFailure {
                Button("Sign in again") { actions.cancel() }.disabled(!enabled)
            }
        }
        .onAppear {
            deviceName.applySuggestion(actions.suggestedDeviceName)
            selectDefaultWorkspace()
        }
        .onChange(of: actions.suggestedDeviceName) { deviceName.applySuggestion($0) }
        .onChange(of: actions.retainedAccountID) { _ in
            selectedLocationID = actions.retainedLocationID
            selectDefaultWorkspace()
        }
        .onChange(of: coordinator.isWorking) { _ in selectDefaultWorkspace() }
        .onChange(of: coordinator.selectedAccountID) { id in
            selectedLocationID = actions.retainedLocationID
            if let id, coordinator.accounts.contains(where: { $0.id == id && $0.capabilities.canEnroll }) { lastEnrollmentWorkspace = id.uuidString }
        }
    }
    private var enrollmentConfirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Device name").font(.headline)
                TextField("Device name", text: Binding(
                    get: { deviceName.displayedName(retainedName: actions.retainedDeviceName) },
                    set: { deviceName.edit($0) }))
                    .textFieldStyle(.roundedBorder).disabled(actions.retainedDeviceName != nil || actions.enrollmentState == .enrolling)
                    .accessibilityIdentifier("cloud.deviceName")
            }
            workspaceSelection
            if coordinator.selectedAccountID != nil {
                locationSelection
                locationDiscoveryStatus
                if let message = choices.unassignedPermissionMessage(accountID: coordinator.selectedAccountID, selectedLocationID: selectedLocationID) {
                    Text(message).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("cloud.locationPermission")
                }
            }
            enrollmentStatus
        }.accessibilityIdentifier("cloud.enrollmentConfirmation")
    }
    @ViewBuilder private var enrollmentStatus: some View {
        switch actions.enrollmentState {
        case .idle: EmptyView()
        case .enrolling: EmptyView() // The modal body owns the centered progress view.
        case .needsAttention, .screenDeliveryNeedsAttention:
            Text(actions.deliveryMessage ?? "Device setup could not finish. Try connecting again.")
                .foregroundStyle(.secondary).accessibilityIdentifier("cloud.enrollmentError")
        case .currentInstallation:
            Text(actions.deliveryMessage ?? "Current installation verified.")
                .foregroundStyle(.secondary).accessibilityIdentifier("cloud.enrollmentStatus")
        }
    }
    private var choices: CloudEnrollmentChoices {
        .init(accounts: coordinator.accounts, locations: coordinator.locations,
              retainedAccountID: actions.retainedAccountID, retainedLocationID: actions.retainedLocationID,
              enrollment: actions.enrollDevice != nil)
    }
    @ViewBuilder private var workspaceSelection: some View {
        if choices.showsWorkspaceSelector {
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace").font(.headline).accessibilityAddTraits(.isHeader)
                Menu {
                    ForEach(choices.accounts, id: \.id) { account in
                        Button(account.name) { actions.chooseAccount(account.id) }
                    }
                } label: {
                    selectorLabel(coordinator.accounts.first(where: { $0.id == coordinator.selectedAccountID })?.name ?? "Choose workspace")
                }.accessibilityIdentifier("cloud.enrollmentWorkspace")
                    .disabled(!enabled || actions.enrollmentState == .enrolling)
            }
        } else if let retainedID = actions.retainedAccountID, coordinator.accounts.count > 1 {
            LabeledContent("Workspace", value: coordinator.accounts.first(where: { $0.id == retainedID })?.name ?? "Saved workspace")
                .font(.subheadline).accessibilityIdentifier("cloud.retainedWorkspace")
        }
    }
    @ViewBuilder private var locationSelection: some View {
        if let summary = choices.retainedLocationSummary {
            LabeledContent("Location", value: summary).font(.subheadline).accessibilityIdentifier("cloud.retainedLocation")
        } else if choices.showsLocationSelector {
            VStack(alignment: .leading, spacing: 6) {
                Text("Location").font(.headline).accessibilityAddTraits(.isHeader)
                Menu {
                    Button("Unassigned") { selectedLocationID = nil }
                        .disabled(!coordinator.accounts.contains(where: { $0.id == coordinator.selectedAccountID && $0.capabilities.canEnrollUnassigned }))
                    ForEach(choices.locations, id: \.id) { item in
                        Button(item.name) { selectedLocationID = item.id }
                    }
                } label: {
                    selectorLabel(choices.locations.first(where: { $0.id == selectedLocationID })?.name ?? "Unassigned")
                }.accessibilityIdentifier("cloud.enrollmentLocation")
                    .disabled(!enabled || actions.enrollmentState == .enrolling)
            }
        }
    }
    private func selectorLabel(_ text: String) -> some View {
        HStack {
            Text(text).multilineTextAlignment(.leading)
            Spacer(minLength: 12)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var locationDiscoveryStatus: some View {
        if coordinator.failure == .discovery, let id = coordinator.selectedAccountID {
            Button("Reload locations") { actions.chooseAccount(id) }.disabled(!enabled)
        }
    }
    private func selectDefaultWorkspace() {
        if enabled, let retainedID = actions.retainedAccountID,
           coordinator.selectedAccountID != retainedID,
           coordinator.accounts.contains(where: { $0.id == retainedID && $0.capabilities.canEnroll }) {
            actions.chooseAccount(retainedID)
            return
        }
        guard enabled, !attemptedDefaultWorkspace, coordinator.selectedAccountID == nil,
              let accountID = actions.retainedAccountID
                ?? coordinator.accounts.first(where: { $0.id == UUID(uuidString: lastEnrollmentWorkspace) && $0.capabilities.canEnroll })?.id
                ?? coordinator.accounts.first(where: { $0.capabilities.canEnroll })?.id else { return }
        attemptedDefaultWorkspace = true
        actions.chooseAccount(accountID)
    }
    private var recoveryButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Check setup status") { actions.recover() }.buttonStyle(.bordered).accessibilityIdentifier("cloud.recoverWorkspace")
            Button("Retry setup") { actions.retry() }.buttonStyle(.bordered).accessibilityIdentifier("cloud.retryWorkspace")
        }.disabled(!enabled || coordinator.failure == .pendingOtherUser)
    }
}

enum CloudJourneyCopy {
    static let occupiedWindow = "Cloud account access is in use in another window."
    static let retiredWindow = "Cloud account access has ended in this window. Close this account view."
    static func signInFailure(_ error: Error) -> String {
        if case .occupied? = error as? CloudHumanSessionBroker.Failure { return occupiedWindow }
        if case .retired? = error as? CloudHumanSessionLifecycle.Failure { return retiredWindow }
        return (error as? CloudNativeIdentityError) == .notConfigured
            ? "Cloud sign-in is not configured on this device." : "Sign-in could not start. Please try again."
    }

    static func failure(_ failure: CloudConnectionCoordinator.Failure?, setup: CloudNativeFailure?) -> String? {
        if case .api(let status, _)? = setup {
            switch status {
            case 401: return "Sign in again to continue workspace setup."
            case 404: return "Setup status is unavailable. Your request has not been discarded."
            case 409: return "The saved setup could not be reconciled. Check its status before continuing."
            case 429: return "Too many requests. Try again later."
            default: return "Workspace setup could not finish. Check its status or retry the saved request."
            }
        }
        switch failure {
        case .authentication: return "Sign-in could not finish. Please try again."
        case .discovery: return "Workspaces or locations could not be loaded. Please try again."
        case .persistence: return "A storage problem is blocking workspace setup. Retry recovery to continue."
        case .workspaceSetup: return "Check the workspace and location names, or retry the saved setup."
        case .pendingOtherUser: return "A saved setup belongs to another account. Sign in with that account to continue."
        case .setupNotEligible: return "Workspace creation is not available right now."
        case .signOut, .none: return nil
        }
    }
}

/// Presenting a provider can hide the journey without dismissing it. Only an actual
/// containing-controller dismissal/removal revokes presentation here; scene lifecycle
/// continues to own background/retirement cancellation.
private struct CloudJourneyDismissalObserver: UIViewControllerRepresentable {
    let cancel: () -> Void
    func makeUIViewController(context: Context) -> Observer { Observer() }
    func updateUIViewController(_ controller: Observer, context: Context) { controller.cancel = cancel }
    final class Observer: UIViewController {
        var cancel: (() -> Void)?
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            var ancestor: UIViewController? = self
            while let controller = ancestor {
                if controller.isBeingDismissed || controller.isMovingFromParent {
                    cancel?(); return
                }
                ancestor = controller.parent
            }
        }
    }
}

/// The explicit Close action and its UIKit disappearance share one revocation.
@MainActor
final class CloudJourneyDismissalCancellation {
    private var cancelled = false
    func cancel(_ action: () -> Void) {
        guard !cancelled else { return }
        cancelled = true; action()
    }
    func preserveCompletedTransition(_ verifiedPresentation: () throws -> Void) throws {
        try verifiedPresentation()
        cancelled = true // Only this verified user transition suppresses UIKit dismissal cancellation.
    }
    func reset() { cancelled = false }
}
