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
    @Published private(set) var projects: [ControllerCloudProject] = []
    @Published private(set) var localProjects: [WorkspaceProject] = []
    @Published private(set) var installations: [ControllerCloudInstallation] = []
    @Published private(set) var publications: [ControllerCloudPublication] = []
    @Published private(set) var pairedDevices: [WorkbenchDeviceRead] = []
    @Published private(set) var freshlyVerifiedDevices: [WorkbenchDeviceRead] = []
    @Published var deploymentReview: ControllerCloudDeploymentReview?
    @Published private(set) var deviceState: String?
    @Published private(set) var busy = false
    @Published private(set) var configured = true
    @Published var error: String?
    @Published var notice: String?
    private var cloud: ControllerCloudWorkbench?
    private var client: WorkbenchBrokerClient?
    private var operation: Task<Void, Never>?
    var unmatchedLocalDevices: [WorkbenchDeviceRead] {
        pairedDevices.filter { local in
            guard let verified = freshlyVerifiedDevices.first(where: { $0.deviceId == local.deviceId }) else { return true }
            return !installations.contains { ControllerCloudDeviceIdentity.matches(local: verified, installationId: $0.installationId) }
        }
    }

    private func connect() async throws -> ControllerCloudWorkbench {
        if let cloud { return cloud }
        let configuration = try await ControllerCloudConfiguration.deployment(clientID: "screenpunk-mac", environment: [:], machineRoot: MacGUIRuntime.runtimeDirectory.appendingPathComponent("machine"))
        let runtime = MacGUIRuntime.runtimeDirectory
        let client = WorkbenchBrokerClient(environment: try .init(runtimeDirectory: runtime, limits: .init(timeout: 120)))
        try await Task.detached { try client.connect() }.value
        let expectedHome = MacGUIRuntime.isolatedTestPaths?.home ?? DashboardPackageStore.defaultRoot().resolvingSymlinksInPath()
        guard try client.hello().controllerHomePath == expectedHome.path else {
            client.close(); throw ControllerCloudError.invalidConfiguration
        }
        let facade = try ControllerCloudWorkbench(configuration: configuration, client: client,
            machineRoot: runtime.appendingPathComponent("machine"))
        self.client = client; self.cloud = facade
        return facade
    }
    func refresh() { perform { model, cloud in try await model.reload(cloud) } }
    private func reload(_ cloud: ControllerCloudWorkbench) async throws {
        let status = try await cloud.status()
        self.status = status
        projects = status.selectedWorkspaceId == nil ? [] : try await cloud.projects()
        installations = status.selectedWorkspaceId == nil ? [] : try await cloud.installations()
        publications = status.selectedWorkspaceId == nil ? [] : try await cloud.publications()
        if let client {
            let local = try await Task.detached { () -> ([WorkspaceProject], [WorkbenchDeviceRead], [WorkbenchDeviceRead]) in
                let projects = try client.listProjects(), devices = try client.listDevices()
                // Dedup requires a fresh pinned local query. A failed query retains a separate local entry.
                let verified = devices.prefix(64).compactMap { try? client.deviceStatus($0.deviceId, refresh: true) }
                return (projects, devices, verified)
            }.value
            localProjects = local.0; pairedDevices = local.1; freshlyVerifiedDevices = local.2
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
            defer { model.status = nil; model.projects = []; model.notice = "Signed out. Your local projects and retained sync drafts are preserved." }
            try await cloud.signOut()
        }
    }
    func selectWorkspace(_ id: String) { perform { model, cloud in try await cloud.selectWorkspace(id); try await model.reload(cloud) } }
    func link(_ local: String, to remote: String) {
        perform { model, cloud in
            try await cloud.link(localProjectId: local, cloudProjectId: remote)
            let result = try await cloud.sync(localProjectId: local)
            model.notice = result.status == .conflict ? "Both projects are preserved. Choose which reviewed version to use below." : "Project linked and synced."
            try await model.reload(cloud)
        }
    }
    func sync(_ id: String, choice: ControllerCloudConflictChoice? = nil) {
        perform { model, cloud in
            let result = try await cloud.sync(localProjectId: id, choice: choice)
            model.notice = "Project status: " + result.status.rawValue
            try await model.reload(cloud)
        }
    }
    func unlink(_ id: String) { perform { model, cloud in try await cloud.unlink(localProjectId: id); try await model.reload(cloud) } }
    func create(_ name: String) { perform { model, cloud in _ = try await cloud.createProject(name: name); try await model.reload(cloud) } }
    func restore(_ id: String, name: String) { perform { model, cloud in _ = try await cloud.restore(cloudProjectId: id, name: name); try await model.reload(cloud) } }
    func publish(_ id: String) { perform { model, cloud in _ = try await cloud.publishLocalBuild(localProjectId: id); model.notice = "Validated local build published. Choose a device and review its screen inventory before deploying."; try await model.reload(cloud) } }
    func review(publication: String, installation: String) { perform { model, cloud in model.deploymentReview = try await cloud.reviewDeployment(publicationId: publication, installationId: installation) } }
    func apply(_ review: ControllerCloudDeploymentReview) {
        perform { model, cloud in
            _ = try await cloud.applyDeployment(review)
            model.deploymentReview = nil
            model.notice = "Screen change requested. The device reports Applied only after successful activation."
            try await model.loadDeviceState(cloud, installation: review.installationId)
        }
    }
    func deviceStatus(_ installation: String) { perform { model, cloud in try await model.loadDeviceState(cloud, installation: installation) } }
    private func loadDeviceState(_ cloud: ControllerCloudWorkbench, installation: String) async throws {
        let result = try await cloud.deviceStatus(installationId: installation)
        guard case .object(let object) = result, case .string(let state) = object["state"] else { throw ControllerCloudError.invalidResponse }
        var lines = ["Device status: " + state.capitalized]
        if case .string(let origin) = object["activeScreenOrigin"] { lines.append("Active screen origin: " + origin) }
        if case .object(let change) = object["lastSuccessfulChange"] {
            if case .string(let entry) = change["entryId"] { lines.append("Active screen: " + entry) }
            if case .string(let changedAt) = change["changedAt"] { lines.append("Last successful change: " + changedAt) }
        }
        deviceState = lines.joined(separator: "\n")
    }
    func cancel() { operation?.cancel() }
    private func perform(_ action: @escaping @MainActor (CloudControllerModel, ControllerCloudWorkbench) async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil; notice = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; operation = nil }
            do { try await action(self, connect()) }
            catch ControllerCloudError.invalidConfiguration {
                configured = false
                error = "Cloud is temporarily unavailable in this build. Your local projects remain available."
            } catch ControllerCloudError.signedOut { status = nil; projects = [] }
            catch is CancellationError { notice = "Cancelled. Inspect project status before retrying a submitted sync." }
            catch { self.error = "Cloud operation failed: \(error). Local edits and sync drafts are retained." }
        }
    }
    deinit { operation?.cancel(); client?.close() }
}

struct CloudControllerView: View {
    @StateObject private var model = CloudControllerModel()
    @State private var localId = ""
    @State private var remoteId = ""
    @State private var name = "New Screen"
    @State private var publicationId = ""
    @State private var installationId = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Screenpunk Cloud").font(.title2.bold())
                Text("Connect this Mac to back up and edit linked screen projects. Saving and syncing source never changes the screen displayed on a device.")
                    .foregroundStyle(.secondary)
                if let status = model.status {
                    HStack {
                        Label("Account connected", systemImage: "person.crop.circle.badge.checkmark")
                        Spacer()
                        Button("Sign Out") { model.logout() }
                    }
                    Picker("Cloud workspace", selection: Binding(get: { status.selectedWorkspaceId ?? "" }, set: { if !$0.isEmpty { model.selectWorkspace($0) } })) {
                        Text("Choose workspace").tag("")
                        ForEach(status.workspaces) { workspace in Text(workspace.name).tag(workspace.id) }
                    }
                    if let syncState = status.automaticSyncState { Text("Automatic sync: " + syncState.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.secondary) }
                    if let errors = status.automaticSyncErrors { ForEach(errors.keys.sorted(), id: \.self) { id in Text(errors[id] ?? "").foregroundStyle(.orange) } }
                    if status.selectedWorkspaceId != nil {
                        projectActions
                        Divider()
                        deploymentActions
                        Divider()
                        Text("Linked projects").font(.headline)
                        if status.bindings.isEmpty { Text("Choose an existing local and cloud project to link, or create a project in this cloud workspace.").foregroundStyle(.secondary) }
                        ForEach(status.bindings, id: \.localProjectId) { binding in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(model.localProjects.first(where: { $0.projectId == binding.localProjectId })?.name ?? binding.localProjectId)
                                    Spacer()
                                    Text(binding.status.rawValue.capitalized).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("Sync") { model.sync(binding.localProjectId) }.disabled(binding.status == .deleted)
                                    if binding.status == .conflict {
                                        Button("Use Local Version") { model.sync(binding.localProjectId, choice: .local) }
                                        Button("Use Cloud Version") { model.sync(binding.localProjectId, choice: .remote) }
                                    }
                                    Button("Unlink") { model.unlink(binding.localProjectId) }
                                }
                            }.padding(.vertical, 8)
                        }
                    }
                } else {
                    Button("Connect Cloud Account") { model.login() }.buttonStyle(.borderedProminent).disabled(!model.configured)
                    Text("Your browser opens for secure sign-in. Local device pairing remains independent of this account.").font(.callout).foregroundStyle(.secondary)
                }
                if model.busy {
                    HStack { ProgressView().controlSize(.small); Text("Connecting or syncing…"); Button("Cancel") { model.cancel() } }
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
                Button("Refresh") { model.refresh() }
                }.padding(24)
        }.frame(width: 660, height: 560)
            .task { model.refresh() }
            .sheet(item: $model.deploymentReview) { review in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review Cloud Screen Change").font(.title2.bold())
                    Text("This explicit change activates the reviewed screen and preserves the existing inventory. A changed device state requires a new review.")
                    ScrollView { Text(review.summary).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Button("Cancel") { model.deploymentReview = nil }; Spacer(); Button("Apply Reviewed Change") { model.apply(review) }.buttonStyle(.borderedProminent).disabled(model.busy) }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }.padding(24).frame(width: 600, height: 480)
            }
    }
    private var projectActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Existing local project", selection: $localId) {
                Text("Choose local project").tag("")
                ForEach(model.localProjects, id: \.projectId) { Text($0.name).tag($0.projectId) }
            }
            Picker("Cloud project", selection: $remoteId) {
                Text("Choose cloud project").tag("")
                ForEach(model.projects) { Text($0.name).tag($0.id) }
            }
            HStack {
                Button("Link Existing Projects") { model.link(localId, to: remoteId) }.disabled(localId.isEmpty || remoteId.isEmpty)
                Button("Restore Cloud Project") { model.restore(remoteId, name: name) }.disabled(remoteId.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Publish Local Build") { model.publish(localId) }.disabled(localId.isEmpty)
            }
            HStack {
                TextField("New or restored project name", text: $name)
                Button("Create Linked Project") { model.create(name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Unlink preserves local source. Conflict resolution preserves both reviewed versions in the sync journal.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var deploymentActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloud devices and screens").font(.headline)
            Picker("Published screen", selection: $publicationId) {
                Text("Choose published screen").tag("")
                ForEach(model.publications) { Text($0.name).tag($0.id) }
            }
            Picker("Enrolled device", selection: $installationId) {
                Text("Choose device").tag("")
                ForEach(model.installations) { device in
                    let paired = model.freshlyVerifiedDevices.contains { ControllerCloudDeviceIdentity.matches(local: $0, installationId: device.installationId) }
                    Text(device.name + (paired ? " · Local and cloud" : " · Cloud")).tag(device.installationId)
                }
                ForEach(model.unmatchedLocalDevices, id: \.deviceId) { device in
                    Text(device.name + " · Local connection").tag("local:" + device.deviceId).disabled(true)
                }
            }
            HStack {
                Button("Review Screen Change…") { model.review(publication: publicationId, installation: installationId) }.disabled(publicationId.isEmpty || installationId.isEmpty)
                Button("Refresh Device Status") { model.deviceStatus(installationId) }.disabled(installationId.isEmpty)
            }
            if let state = model.deviceState { Text(state).foregroundStyle(.secondary) }
        }.disabled(model.busy)
    }
}
