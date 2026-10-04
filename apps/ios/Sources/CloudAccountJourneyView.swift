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
    var enabled: Bool { if case .qualified = availability { return true }; return false }
    init(lifecycle: CloudHumanSessionLifecycle, presentation: CloudProviderPresentation,
         availability: CloudJourneyAvailability,
         makeSession: ((CloudProviderPresentation) throws -> CloudHumanSession)? = nil) {
        self.lifecycle = lifecycle; self.presentation = presentation; self.availability = availability; self.makeSession = makeSession
    }
    @discardableResult func signIn(_ provider: CloudNativeSignInProvider) throws -> Task<Void, Never>? {
        guard enabled else { throw CloudNativeIdentityError.notConfigured }
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

/// Human identity and workspace setup only. A receipt is never installation/enrollment authority.
struct CloudAccountJourneyView: View {
    @ObservedObject private var lifecycle: CloudHumanSessionLifecycle
    private let actions: CloudAccountJourneyActions
    @Environment(\.dismiss) private var dismiss
    @State private var actionMessage: String?
    @State private var dismissalCancellation = CloudJourneyDismissalCancellation()
    init(lifecycle: CloudHumanSessionLifecycle, presentation: CloudProviderPresentation,
         availability: CloudJourneyAvailability = .unavailable("Cloud sign-in is not available in this version."),
         makeSession: ((CloudProviderPresentation) throws -> CloudHumanSession)? = nil) {
        self.lifecycle = lifecycle
        actions = .init(lifecycle: lifecycle, presentation: presentation, availability: availability, makeSession: makeSession)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("Screenpunk Cloud", systemImage: "cloud").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("Sign in to view your workspaces.").font(.title3).foregroundStyle(.secondary)
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
                        if let coordinator = lifecycle.coordinator {
                            CloudAccountJourneyContent(coordinator: coordinator, actions: actions, signIn: signIn)
                        } else { providerEntry }
                    }
                    if let actionMessage { Text(actionMessage).foregroundStyle(.secondary).accessibilityIdentifier("cloud.actionError") }
                    Text("Cloud device connection is unavailable in this version.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: 580, alignment: .leading).padding(20).frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismissalCancellation.cancel(actions.cancel); dismiss() }.accessibilityIdentifier("cloud.close") } }
            .background(CloudPresentationAnchor(presentation: actions.presentation).frame(width: 0, height: 0).accessibilityHidden(true))
            .background(CloudJourneyDismissalObserver(cancel: { dismissalCancellation.cancel(actions.cancel) }).frame(width: 0, height: 0).accessibilityHidden(true))
        }
        .onAppear { dismissalCancellation.reset() }
    }
    private var providerEntry: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .unavailable(let message) = actions.availability { Text(message).foregroundStyle(.secondary) }
            CloudNativeProviderButtons(enabled: actions.enabled, apple: { signIn(.apple) }, google: { signIn(.google) })
        }
    }
    private func signIn(_ provider: CloudNativeSignInProvider) {
        actionMessage = nil
        do { try actions.signIn(provider) }
        catch {
            actionMessage = (error as? CloudNativeIdentityError) == .notConfigured
                ? "Cloud sign-in is not configured on this device." : "Sign-in could not start. Please try again."
        }
    }
}

private struct CloudAccountJourneyContent: View {
    @ObservedObject var coordinator: CloudConnectionCoordinator
    let actions: CloudAccountJourneyActions
    let signIn: (CloudNativeSignInProvider) -> Void
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
                ForEach(coordinator.locations, id: \.id) { item in Text(item.name) }
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
    func reset() { cancelled = false }
}
