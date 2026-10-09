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
    var enrollDevice: ((UUID, UUID, String, String) -> Void)?
    var enrollmentState: NativeEnrollmentSceneController.State = .idle
    var deliveryMessage: String?
    var retainedDeviceName: String?
    var retainedDeviceProfile: String?
    var viewScreen: (() throws -> Void)?
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
}

/// Human identity/workspace UI and an injected explicit device intent.
/// Human receipts never grant installation/enrollment authority.
struct CloudAccountJourneyView: View {
    @ObservedObject private var lifecycle: CloudHumanSessionLifecycle
    private let actions: CloudAccountJourneyActions
    @Environment(\.dismiss) private var dismiss
    @State private var actionMessage: String?
    @State private var dismissalCancellation = CloudJourneyDismissalCancellation()
    init(lifecycle: CloudHumanSessionLifecycle, presentation: CloudProviderPresentation,
         availability: CloudJourneyAvailability = .unavailable("Cloud sign-in is not available in this version."),
         makeSession: ((CloudProviderPresentation) throws -> CloudHumanSession)? = nil,
         enrollDevice: ((UUID, UUID, String, String) -> Void)? = nil,
         enrollmentState: NativeEnrollmentSceneController.State = .idle,
         deliveryMessage: String? = nil, viewScreen: (() throws -> Void)? = nil,
         retainedDeviceName: String? = nil, retainedDeviceProfile: String? = nil) {
        self.lifecycle = lifecycle
        var actions = CloudAccountJourneyActions(lifecycle: lifecycle, presentation: presentation, availability: availability, makeSession: makeSession)
        actions.enrollDevice = enrollDevice; actions.enrollmentState = enrollmentState
        actions.deliveryMessage = deliveryMessage; actions.viewScreen = viewScreen
        actions.retainedDeviceName = retainedDeviceName; actions.retainedDeviceProfile = retainedDeviceProfile
        self.actions = actions
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    signInHeader
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
                                CloudAccountJourneyContent(coordinator: coordinator, actions: actions, signIn: signIn)
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
                }.frame(maxWidth: 420, alignment: .leading).padding(.horizontal, 28)
                    .padding(.top, 28).padding(.bottom, 32).frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismissalCancellation.cancel(actions.cancel); dismiss() }.accessibilityIdentifier("cloud.close") }
                ToolbarItem(placement: .primaryAction) {
                    if let viewScreen = actions.viewScreen {
                        Button("View screen") {
                            do { try dismissalCancellation.preserveCompletedTransition(viewScreen); dismiss() }
                            catch { actionMessage = "Screen connection needs verification. Check again." }
                        }.accessibilityIdentifier("cloud.viewScreen")
                    }
                }
            }
            .background(CloudPresentationAnchor(presentation: actions.presentation).frame(width: 0, height: 0).accessibilityHidden(true))
            .background(CloudJourneyDismissalObserver(cancel: { dismissalCancellation.cancel(actions.cancel) }).frame(width: 0, height: 0).accessibilityHidden(true))
        }
        .onAppear { dismissalCancellation.reset() }
        .onChange(of: lifecycle.accountEntryState) { _ in actionMessage = nil }
    }
    private var signInHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to Screenpunk cloud")
                .font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Sign in to view your workspaces.")
                .font(.body).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var providerEntry: some View {
        VStack(alignment: .leading, spacing: 20) {
            CloudNativeProviderButtons(enabled: actions.enabled,
                apple: { signIn(.apple) }, google: { signIn(.google) })
            CloudSignInLegalDisclaimer()
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

private struct CloudAccountJourneyContent: View {
    @ObservedObject var coordinator: CloudConnectionCoordinator
    let actions: CloudAccountJourneyActions
    let signIn: (CloudNativeSignInProvider) -> Void
    init(coordinator: CloudConnectionCoordinator, actions: CloudAccountJourneyActions, signIn: @escaping (CloudNativeSignInProvider) -> Void) {
        self.coordinator = coordinator; self.actions = actions; self.signIn = signIn
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch coordinator.signOutState {
            case .pending:
                ProgressView("Signing out…")
                Text("Sign-out is waiting for the current sign-in to finish.").foregroundStyle(.secondary)
            case .failed:
                Text("Sign-out could not finish.")
                Button("Retry sign-out") { actions.retrySignOut() }.buttonStyle(.borderedProminent).accessibilityIdentifier("cloud.retrySignOut")
            case .idle, .succeeded:
                if let identity = coordinator.humanIdentity {
                    Text(identity.user.displayName).font(.title2.bold())
                    if let email = identity.user.email { Text(email).foregroundStyle(.secondary) }
                    Button("Sign out") { actions.signOut() }.buttonStyle(.bordered).accessibilityIdentifier("cloud.signOut")
                    CloudWorkspaceJourney(coordinator: coordinator, actions: actions)
                } else {
                    if coordinator.signOutState == .succeeded { Text("Signed out.") }
                    if case .unavailable(let message) = actions.availability { Text(message).foregroundStyle(.secondary) }
                    CloudNativeProviderButtons(enabled: actions.enabled && !coordinator.isWorking,
                        apple: { signIn(.apple) }, google: { signIn(.google) })
                    CloudSignInLegalDisclaimer()
                }
            }
            if coordinator.isWorking { ProgressView("Working…").accessibilityIdentifier("cloud.progress") }
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
    @State private var deviceName = ""
    @State private var deviceProfile = ""
    init(coordinator: CloudConnectionCoordinator, actions: CloudAccountJourneyActions) {
        self.coordinator = coordinator; self.actions = actions
        _deviceName = State(initialValue: actions.retainedDeviceName ?? "")
        _deviceProfile = State(initialValue: actions.retainedDeviceProfile ?? "")
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
            if !coordinator.accounts.isEmpty {
                Text("Workspaces").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(coordinator.accounts, id: \.id) { account in
                    Button { actions.chooseAccount(account.id) } label: {
                        HStack { Text(account.name).multilineTextAlignment(.leading); Spacer(); if coordinator.selectedAccountID == account.id { Image(systemName: "checkmark") } }
                    }.buttonStyle(.bordered).disabled(!enabled).accessibilityLabel("View locations in \(account.name)")
                }
            }
            if coordinator.selectedAccountID != nil {
                Text("Locations").font(.headline).accessibilityAddTraits(.isHeader)
                if actions.enrollDevice != nil {
                    TextField("Device name", text: $deviceName).textFieldStyle(.roundedBorder).disabled(actions.retainedDeviceName != nil)
                    TextField("Device type", text: $deviceProfile).textFieldStyle(.roundedBorder).disabled(actions.retainedDeviceProfile != nil)
                    switch actions.enrollmentState {
                    case .idle: EmptyView()
                    case .enrolling: ProgressView("Preparing this device and screen…")
                    case .needsAttention: Text("Device or screen setup needs attention. Retry the original selection and name.").foregroundStyle(.secondary)
                    case .currentInstallation: Text(actions.deliveryMessage ?? "Current installation verified.").foregroundStyle(.secondary)
                    }
                }
                ForEach(coordinator.locations, id: \.id) { item in
                    VStack(alignment: .leading) {
                        Text(item.name)
                        if let enroll = actions.enrollDevice, let accountID = coordinator.selectedAccountID,
                            item.capabilities.canEnroll, coordinator.accounts.contains(where: { $0.id == accountID && $0.capabilities.canEnroll }) {
                            Button(actions.enrollmentState == .currentInstallation ? "Check for screens" : "Enroll this device") { enroll(accountID, item.id, actions.retainedDeviceName ?? deviceName, actions.retainedDeviceProfile ?? deviceProfile) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!enabled || (actions.retainedDeviceName ?? deviceName).isEmpty || (actions.retainedDeviceProfile ?? deviceProfile).isEmpty || actions.enrollmentState == .enrolling)
                                .accessibilityLabel("Enroll this device in \(item.name)")
                        }
                    }
                }
                if !coordinator.isWorking && coordinator.locations.isEmpty && coordinator.failure == nil { Text("No locations in this workspace.").foregroundStyle(.secondary) }
                if coordinator.failure == .discovery, let id = coordinator.selectedAccountID {
                    Button("Reload locations") { actions.chooseAccount(id) }.disabled(!enabled)
                }
            }
            if case .api(status: 401, error: _)? = coordinator.workspaceSetupFailure {
                Button("Sign in again") { actions.cancel() }.disabled(!enabled)
            }
        }
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
