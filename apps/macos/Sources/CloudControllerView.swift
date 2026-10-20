import AppKit
import SwiftUI
import ScreenpunkController
import ScreenpunkApple

enum CloudControllerIntegration {
    static func linkCreated(_ project: WorkbenchSourceProject, client: WorkbenchBrokerClient, kind: String) async throws {
        guard let text = Bundle.main.infoDictionary?["ScreenpunkCloudAPIOrigin"] as? String,
              let base = URL(string: text), base.scheme == "https",
              try ControllerCloudKeychain(server: base, clientID: "screenpunk-mac").load() != nil else { return }
        let configuration = try await ControllerCloudConfiguration.deployment(clientID: "screenpunk-mac", environment: [:], machineRoot: MacGUIRuntime.runtimeDirectory.appendingPathComponent("machine"))
        let cloud = try ControllerCloudWorkbench(configuration: configuration, client: client,
            machineRoot: MacGUIRuntime.runtimeDirectory.appendingPathComponent("machine"))
        _ = try await cloud.linkCreatedProjectIfConnected(localProjectId: project.project.projectId, name: project.project.name, kind: kind)
    }
    @MainActor static func previewInvocation(dashboardId: String,
                                            client: @escaping @MainActor () -> WorkbenchBrokerClient?,
                                            currentDashboard: @escaping @MainActor () -> String) -> CloudScreenServiceInvocation {
        return { invocationId, bindingId, operation, input in
            guard !dashboardId.isEmpty, currentDashboard() == dashboardId, let client = client() else { throw NSError(domain: "ScreenpunkServices", code: 1, userInfo: [NSLocalizedDescriptionKey: "service_disconnected"]) }
            let projects = try await Task.detached { try client.listProjects() }.value
            guard let local = projects.first(where: { $0.dashboardId == dashboardId }) else { throw ControllerCloudError.invalidSource }
            let configuration = try await ControllerCloudConfiguration.deployment(clientID: "screenpunk-mac", environment: [:], machineRoot: MacGUIRuntime.runtimeDirectory.appendingPathComponent("machine"))
            let facade = try ControllerCloudWorkbench(configuration: configuration, client: client,
                machineRoot: MacGUIRuntime.runtimeDirectory.appendingPathComponent("machine"))
            let response = try await facade.invokeService(localProjectId: local.projectId, invocationId: invocationId,
                bindingId: bindingId, operation: operation, input: input)
            guard currentDashboard() == dashboardId else { throw NSError(domain: "ScreenpunkServices", code: 1, userInfo: [NSLocalizedDescriptionKey: "service_disconnected"]) }
            return response
        }
    }
}

@MainActor
final class CloudControllerModel: ObservableObject {
    @Published private(set) var status: ControllerCloudWorkbenchStatus?
    @Published private(set) var localSyncStatus: ControllerCloudScreenSyncLocalStatus?
    @Published private(set) var wantsScreenSync = false
    @Published private(set) var selectedWorkspaceID = ""
    @Published private(set) var busy = false
    @Published private(set) var showProgress = false
    @Published private(set) var loaded = false
    @Published var error: String?
    private var awaitingWorkspaceChoice = false
    private var cloud: ControllerCloudWorkbench?
    private var client: WorkbenchBrokerClient?
    private var operation: Task<Void, Never>?
    private var pendingLibraryEvents: [(ControllerCloudScreenSyncTrigger, String?)] = []

    private func connect() async throws -> ControllerCloudWorkbench {
        if let cloud, let client {
            try await prepareBroker(client)
            return cloud
        }
        let configuration = try await ControllerCloudConfiguration.deployment(clientID: "screenpunk-mac", environment: [:], machineRoot: MacGUIRuntime.runtimeDirectory.appendingPathComponent("machine"))
        let client = WorkbenchBrokerClient(environment: try .init(runtimeDirectory: MacGUIRuntime.runtimeDirectory, limits: .init(timeout: 120)))
        try await prepareBroker(client)
        let facade = try ControllerCloudWorkbench(configuration: configuration, client: client,
            machineRoot: MacGUIRuntime.runtimeDirectory.appendingPathComponent("machine"))
        self.client = client; self.cloud = facade
        return facade
    }
    private func prepareBroker(_ client: WorkbenchBrokerClient) async throws {
        let expectedHome = MacGUIRuntime.isolatedTestPaths?.home ?? DashboardPackageStore.defaultRoot().resolvingSymlinksInPath()
        try await Task.detached {
            _ = try client.reconnectIfPeerClosed()
            guard try client.hello().controllerHomePath == expectedHome.path else {
                client.close(); throw ControllerCloudError.invalidConfiguration
            }
        }.value
    }
    private func reload(_ cloud: ControllerCloudWorkbench) async throws {
        let updated = try await cloud.status()
        if status?.accountId != updated.accountId { awaitingWorkspaceChoice = false }
        status = updated
        if !awaitingWorkspaceChoice {
            wantsScreenSync = updated.screenSyncEnabled
            selectedWorkspaceID = updated.selectedWorkspaceId ?? ""
        }
        loaded = true
    }
    func refresh() { perform { model, cloud in try await model.reload(cloud) } }
    // Local progress reads never construct an OAuth session or contact the cloud.
    // Only explicit user/lifecycle events enqueue work for the persistent service.
    func refreshLibraryStatus(trigger: ControllerCloudScreenSyncTrigger? = nil, dashboardId: String? = nil) {
        if busy {
            if let trigger { pendingLibraryEvents.append((trigger, dashboardId)) }
            return
        }
        busy = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                busy = false; operation = nil
                if !pendingLibraryEvents.isEmpty {
                    let next = pendingLibraryEvents.removeFirst()
                    refreshLibraryStatus(trigger: next.0, dashboardId: next.1)
                }
            }
            do {
                guard let text = Bundle.main.infoDictionary?["ScreenpunkCloudAPIOrigin"] as? String,
                      let base = URL(string: text), base.scheme == "https" else {
                    throw ControllerCloudError.invalidConfiguration
                }
                let broker = try client ?? WorkbenchBrokerClient(environment: .init(runtimeDirectory: MacGUIRuntime.runtimeDirectory, limits: .init(timeout: 10)))
                try await prepareBroker(broker)
                client = broker
                let machine = MacGUIRuntime.runtimeDirectory.appendingPathComponent("machine")
                if let trigger {
                    try await ControllerCloudWorkbench.requestScreenSync(baseURL: base, client: broker,
                        machineRoot: machine, trigger: trigger, dashboardId: dashboardId)
                }
                localSyncStatus = try await ControllerCloudWorkbench.localScreenSyncStatus(
                    baseURL: base, client: broker, machineRoot: machine)
                error = nil
            } catch {
                localSyncStatus = nil
                self.error = "Sync status is unavailable."
                client?.close(); client = nil
            }
        }
    }

    func login() {
        perform { model, cloud in
            try await cloud.signIn { url in
                guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else { throw ControllerCloudError.invalidConfiguration }
            }
            try await model.reload(cloud)
        }
    }
    func logout() {
        perform { model, cloud in
            try await cloud.signOut()
            model.status = nil; model.wantsScreenSync = false
            model.selectedWorkspaceID = ""; model.awaitingWorkspaceChoice = false
        }
    }
    private func defaultWorkspacePath() throws -> String {
        let standard = try SystemWorkspaceDocumentsResolver().documentsDirectory().appendingPathComponent("Screenpunk", isDirectory: true)
        if FileManager.default.fileExists(atPath: standard.path),
           !FileManager.default.fileExists(atPath: standard.appendingPathComponent("workspace.json").path) {
            return standard.deletingLastPathComponent().appendingPathComponent("Screenpunk Workspace").path
        }
        return standard.path
    }
    func setSync(_ enabled: Bool) {
        guard !busy else { return }
        if enabled {
            // Turning on exposes the choice; it does not silently select a destination.
            wantsScreenSync = true; awaitingWorkspaceChoice = true; selectedWorkspaceID = ""; error = nil
        } else {
            perform { model, cloud in
                try await cloud.setScreenSyncEnabled(false)
                model.awaitingWorkspaceChoice = false
                try await model.reload(cloud)
            }
        }
    }
    func chooseWorkspace(_ id: String) {
        guard !id.isEmpty, status?.workspaces.contains(where: { $0.id == id }) == true else { return }
        selectedWorkspaceID = id
        perform { model, cloud in
            try await cloud.setScreenSyncEnabled(true, workspaceId: id, creatingLocalWorkspaceAt: model.defaultWorkspacePath())
            model.awaitingWorkspaceChoice = false
            try await model.reload(cloud)
        }
    }
    func retry() {
        if awaitingWorkspaceChoice && !selectedWorkspaceID.isEmpty { chooseWorkspace(selectedWorkspaceID) }
        else { refresh() }
    }
    var syncSummary: String {
        guard wantsScreenSync else { return "Screens stay on this Mac. Turn syncing on to share them with a cloud workspace." }
        if awaitingWorkspaceChoice { return "Choose a workspace to start syncing." }
        if status?.automaticSyncState == "needs_attention" { return "Some Screens could not sync yet. Your existing Screens are preserved." }
        if status?.automaticSyncState == "paused" { return "Syncing will resume when the connection is available." }
        return status?.screenSyncMessage ?? "Getting your Screens ready to sync…"
    }
    private func perform(quiet: Bool = false, _ action: @escaping @MainActor (CloudControllerModel, ControllerCloudWorkbench) async throws -> Void) {
        guard operation == nil else { return }
        busy = true; showProgress = !quiet
        if !quiet { error = nil }
        operation = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; showProgress = false; operation = nil; loaded = true }
            do { try await action(self, connect()) }
            catch ControllerCloudError.signedOut {
                status = nil; wantsScreenSync = false; awaitingWorkspaceChoice = false
            } catch is CancellationError { }
            catch ControllerCloudError.invalidConfiguration {
                error = "Cloud is temporarily unavailable. Your Screens are still on this Mac."
            } catch ControllerCloudError.accountMismatch {
                error = "The account or workspace changed. Refresh and choose the workspace again."
            } catch let failure as WorkbenchIPCError where [.disconnected, .unavailable, .timedOut, .instanceMismatch].contains(failure.code) {
                client?.close(); client = nil; cloud = nil
                error = "The local connection was interrupted. Retry to reconnect; your Screens are preserved."
            } catch {
                self.error = "Couldn’t update cloud settings. Check your connection and try again. Your Screens are preserved."
            }
        }
    }
    deinit { operation?.cancel(); client?.close() }
}

struct CloudControllerView: View {
    @StateObject private var model = CloudControllerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Screenpunk Cloud").font(.title2.bold())
                Text("Your Screens, on this Mac and in the cloud.").foregroundStyle(.secondary)
            }
            if !model.loaded {
                ProgressView("Loading account…").frame(maxWidth: .infinity, alignment: .leading)
            } else if let status = model.status {
                HStack {
                    Label("Account connected", systemImage: "person.crop.circle.badge.checkmark")
                    Spacer()
                    Button("Sign Out") { model.logout() }.disabled(model.busy)
                }
                Divider()
                Toggle("Screen syncing", isOn: Binding(get: { model.wantsScreenSync }, set: { model.setSync($0) }))
                    .toggleStyle(.switch).disabled(model.busy)
                if model.wantsScreenSync {
                    Picker("Workspace", selection: Binding(get: { model.selectedWorkspaceID }, set: { model.chooseWorkspace($0) })) {
                        Text("Choose a workspace…").tag("")
                        ForEach(status.workspaces) { Text($0.name).tag($0.id) }
                    }.disabled(model.busy)
                    if status.workspaces.isEmpty {
                        Text("No workspaces are available for this account.").foregroundStyle(.secondary)
                    }
                    Text("Screens are added to this Mac and the selected workspace, then changes stay in sync. Existing Screens aren’t matched or merged.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(model.syncSummary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Connect Cloud Account") { model.login() }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
                Text("Sign in securely in your browser. Screen syncing is optional.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.showProgress && model.loaded { ProgressView("Updating…").controlSize(.small) }
            if let error = model.error {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Retry") { model.retry() }.disabled(model.busy)
                }.font(.callout)
            }
        }
        .padding(24).frame(width: 520, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .task { model.refresh() }
    }
}
