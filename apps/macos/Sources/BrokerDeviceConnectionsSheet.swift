import AppKit
import SwiftUI
import ScreenpunkController
import ScreenpunkCore

/// The broker owns connection authority. This sheet keeps one verified local
/// review socket; it never constructs a second ControllerService or reads a
/// device credential. Scope edits start with the broker's nonsecret draft.
@MainActor
final class BrokerDeviceConnectionsModel: ObservableObject {
    @Published private(set) var connections: [WorkbenchConnectionSummary] = []
    @Published private(set) var busy = false
    @Published var selectedBindingId: String?
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var scopeDraft: WorkbenchConnectionScopeDraft?
    @Published var aliasInput = ""
    @Published var operationPaths: [String] = []
    @Published var operationEnabled: [Bool] = []
    private var session: MacBrokerApplySession?
    private var expectedWorkspaceId: String?
    private var expectedSelectionGeneration: Int?
    private var deviceId = ""

    var selected: WorkbenchConnectionSummary? {
        connections.first { $0.bindingId == selectedBindingId }
    }

    func load(environment: WorkbenchBrokerEnvironment?,
              selected: WorkbenchWorkspaceStatus?, deviceId: String) async {
        guard session == nil, !busy, let environment, let selected,
              selected.state == "selected", let workspaceId = selected.workspaceId,
              let generation = selected.selectionGeneration else {
            error = "Select a broker workspace and device before opening connections."
            return
        }
        busy = true; error = nil
        let outcome = await Task.detached { () -> Result<(MacBrokerApplySession, [WorkbenchConnectionSummary]), Error> in
            Result {
                let expectedHome = DashboardPackageStore.defaultRoot()
                    .resolvingSymlinksInPath().path
                let opened = try MacBrokerApplySession.open(environment: environment,
                    expectedControllerHome: expectedHome)
                guard opened.selected.workspaceId == workspaceId,
                      opened.selected.selectionGeneration == generation else {
                    Task { await opened.close() }
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                do { return (opened, try opened.client.listConnections(deviceId: deviceId)) }
                catch { Task { await opened.close() }; throw error }
            }
        }.value
        busy = false
        switch outcome {
        case .success(let (opened, values)):
            session = opened; self.deviceId = deviceId
            expectedWorkspaceId = workspaceId
            expectedSelectionGeneration = generation
            accept(values)
        case .failure(let failure):
            error = "Broker connection review unavailable: \(failure.localizedDescription)"
        }
    }

    func close() async {
        let opened = session; session = nil
        scopeDraft = nil
        await opened?.close()
    }

    func beginScopeEdit(bindingId: String) async -> Bool {
        guard !busy, let opened = session, let item = selected,
              item.bindingId == bindingId,
              let workspaceId = expectedWorkspaceId,
              let generation = expectedSelectionGeneration else { return false }
        busy = true; error = nil; notice = nil
        let outcome = await Task.detached { () -> Result<WorkbenchConnectionScopeDraft, Error> in
            Result {
                let current = try opened.client.workspaceStatus()
                guard current.state == "selected", current.workspaceId == workspaceId,
                      current.selectionGeneration == generation else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                let draft = try opened.client.connectionScopeDraft(bindingId: bindingId,
                    workspaceId: workspaceId, selectionGeneration: generation)
                guard draft.deviceId == item.deviceId, draft.dashboardId == item.dashboardId,
                      draft.revision == item.revision,
                      draft.expectedGrantGeneration == item.grantGeneration,
                      draft.grant.id.uuidString.lowercased() == item.bindingId,
                      draft.grant.authRef.isEmpty, draft.auth.authRef.isEmpty else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                return draft
            }
        }.value
        busy = false
        switch outcome {
        case .success(let draft):
            scopeDraft = draft
            aliasInput = draft.grant.alias
            operationPaths = draft.grant.operations.map(\.path)
            operationEnabled = Array(repeating: true, count: draft.grant.operations.count)
            return true
        case .failure(let failure):
            error = "Cannot open a safe scope draft: \(failure.localizedDescription)"
            return false
        }
    }

    func cancelScopeEdit() { scopeDraft = nil }

    func submitScopeEdit() async -> Bool {
        guard !busy, let opened = session, let draft = scopeDraft,
              let selected, selected.bindingId == draft.bindingId,
              let workspaceId = expectedWorkspaceId,
              let generation = expectedSelectionGeneration,
              operationPaths.count == draft.grant.operations.count,
              operationEnabled.count == operationPaths.count else { return false }
        let proposed: ConnectionGrant
        do { proposed = try BrokerConnectionScopeProposal.prepare(grant: draft.grant,
            alias: aliasInput, paths: operationPaths, enabled: operationEnabled) }
        catch {
            self.error = "The proposed connection scope is invalid or unchanged. Keep at least one valid operation and check its alias and paths."
            return false
        }
        busy = true; error = nil; notice = nil
        let intentResult = await Task.detached { () -> Result<WorkbenchConnectionIntentView, Error> in
            Result {
                let current = try opened.client.workspaceStatus()
                guard current.state == "selected", current.workspaceId == workspaceId,
                      current.selectionGeneration == generation else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                let fresh = try opened.client.connectionScopeDraft(bindingId: draft.bindingId,
                    workspaceId: workspaceId, selectionGeneration: generation)
                guard fresh == draft else { throw WorkbenchIPCError(.workspaceConflict) }
                let intent = try opened.client.updateConnection(bindingId: draft.bindingId,
                    expectedGrantGeneration: draft.expectedGrantGeneration,
                    grant: proposed, auth: draft.auth)
                guard intent.summary.bindingId == draft.bindingId,
                      intent.summary.deviceId == draft.deviceId,
                      intent.summary.dashboardId == draft.dashboardId,
                      intent.summary.revision == draft.revision,
                      intent.state == "pending" else { throw WorkbenchIPCError(.invalidRequest) }
                return intent
            }
        }.value
        let intent: WorkbenchConnectionIntentView
        switch intentResult {
        case .success(let value): intent = value
        case .failure(let failure):
            busy = false
            scopeDraft = nil
            error = "Scope proposal may have been recorded. Inspect current connection and pending intents before retrying: \(failure.localizedDescription)"
            return false
        }
        let reviewResult = await Task.detached { () -> Result<WorkbenchConnectionReview, Error> in
            Result { try opened.client.beginConnectionReview(intentId: intent.intentId) }
        }.value
        let review: WorkbenchConnectionReview
        switch reviewResult {
        case .success(let value): review = value
        case .failure(let failure):
            busy = false; scopeDraft = nil
            error = "Proposal \(intent.intentId) remains pending or needs inspection; review could not start: \(failure.localizedDescription)"
            return false
        }
        let scope: String
        do { scope = try BrokerConnectionReviewPresentation.render(
            BrokerConnectionReviewPresentation.facts(review)) }
        catch {
            busy = false; scopeDraft = nil
            self.error = "Proposal \(intent.intentId) remains pending; its complete review could not be displayed."
            return false
        }
        guard BrokerConnectionScopeReviewDialog.approve(scope) else {
            busy = false; scopeDraft = nil
            notice = "Proposal \(intent.intentId) was not approved and may remain pending until expiry."
            return false
        }
        let applyResult = await Task.detached { () -> Result<WorkbenchConnectionApplyResult, Error> in
            Result { try opened.client.confirmConnectionReview(review) }
        }.value
        busy = false; scopeDraft = nil
        switch applyResult {
        case .success(let applied):
            guard applied.summary.bindingId == draft.bindingId,
                  applied.summary.deviceId == draft.deviceId,
                  applied.summary.dashboardId == draft.dashboardId else {
                error = "Approval reply needs inspection. Reload connection status before another change."
                return false
            }
            notice = "Exact connection scope approved. Reloading broker status."
            await refresh()
            return true
        case .failure(let failure):
            error = "Approval outcome is uncertain. Inspect connection status before another request: \(failure.localizedDescription)"
            return false
        }
    }

    func refresh() async {
        guard !busy, let opened = session else { return }
        busy = true; error = nil
        let id = deviceId
        let expectedId = expectedWorkspaceId
        let expectedGeneration = expectedSelectionGeneration
        let outcome = await Task.detached { () -> Result<[WorkbenchConnectionSummary], Error> in
            Result {
                let selected = try opened.client.workspaceStatus()
                guard selected.workspaceId == expectedId,
                      selected.selectionGeneration == expectedGeneration else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                return try opened.client.listConnections(deviceId: id)
            }
        }.value
        busy = false
        switch outcome {
        case .success(let values): accept(values)
        case .failure(let failure):
            error = "Cannot refresh broker connections: \(failure.localizedDescription)"
        }
    }

    enum Action { case test, revoke, remove }
    func perform(_ action: Action, bindingId: String) async {
        guard !busy, let opened = session,
              let prior = connections.first(where: { $0.bindingId == bindingId }) else { return }
        busy = true; error = nil; notice = nil
        let expectedId = expectedWorkspaceId
        let expectedGeneration = expectedSelectionGeneration
        let outcome = await Task.detached { () -> Result<WorkbenchConnectionSummary, Error> in
            Result {
                let selected = try opened.client.workspaceStatus()
                guard selected.workspaceId == expectedId,
                      selected.selectionGeneration == expectedGeneration else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                let value: WorkbenchConnectionSummary
                switch action {
                case .test: value = try opened.client.testConnection(bindingId)
                case .revoke: value = try opened.client.revokeConnection(bindingId)
                case .remove: value = try opened.client.removeConnection(bindingId)
                }
                guard value.bindingId == prior.bindingId,
                      value.deviceId == prior.deviceId,
                      value.dashboardId == prior.dashboardId else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                return value
            }
        }.value
        busy = false
        switch outcome {
        case .success(let value):
            switch action {
            case .test:
                notice = value.localStatus == "owner_channel_reachable_upstream_untested"
                    ? "Device owner channel reached. The upstream service was not tested."
                    : "Connection test status: \(value.localStatus)."
            case .revoke, .remove:
                guard value.localStatus == "locally_revoked" else {
                    error = "Revocation reply needs inspection before another request."
                    return
                }
                notice = action == .remove
                    ? "Local access and saved credential removal requested. Upstream revocation is unsupported."
                    : "Local access revoked. Upstream revocation is unsupported."
            }
            await refresh()
        case .failure(let failure):
            error = action == .test
                ? "Connection test unavailable: \(failure.localizedDescription)"
                : "Local change may have applied. Refresh connection status before retrying: \(failure.localizedDescription)"
        }
    }

    private func accept(_ values: [WorkbenchConnectionSummary]) {
        guard values.allSatisfy({ $0.deviceId == deviceId }) else {
            error = "Broker returned connections for a different device."
            return
        }
        connections = values.sorted { $0.bindingId < $1.bindingId }
        if !connections.contains(where: { $0.bindingId == selectedBindingId }) {
            selectedBindingId = connections.first?.bindingId
        }
    }
}

struct BrokerDeviceConnectionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MacWorkbenchModel
    let deviceID: String
    @StateObject private var editor = BrokerDeviceConnectionsModel()
    @State private var editingScope = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Device Connections").font(.title2.bold())
                Spacer()
                Button("Reload") { Task { await editor.refresh() } }.disabled(editor.busy)
                Button("Close") { dismiss() }
            }
            Text("Connection authorization is held by the Screenpunk service on this Mac.")
                .foregroundStyle(.secondary)
            if let error = editor.error { Text(error).foregroundStyle(.red) }
            if let notice = editor.notice { Text(notice).foregroundStyle(.secondary) }
            if editor.busy { ProgressView().controlSize(.small) }
            HStack(alignment: .top, spacing: 20) {
                List(selection: $editor.selectedBindingId) {
                    ForEach(editor.connections, id: \.bindingId) { item in
                        VStack(alignment: .leading) {
                            Text(item.alias)
                            Text(item.dashboardId + " · " + item.localStatus)
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(item.bindingId)
                    }
                }.frame(width: 260)
                if let item = editor.selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(item.alias).font(.headline)
                            Text("Origin: \(item.origin)")
                            Text("Authentication: \(item.authenticationPlacement)")
                            Text("Local status: \(item.localStatus)")
                            Text("Remote revocation: \(item.remoteRevocation)")
                            Text("Grant generation: \(item.grantGeneration)")
                            Divider()
                            ForEach(Array(item.operations.enumerated()), id: \.offset) { _, operation in
                                Text("\(operation.method) \(operation.name) · \(operation.address)")
                                    .textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ContentUnavailableView("No local authorizations", systemImage: "link")
                }
            }
            HStack {
                Text("Scope changes use a broker draft, then fresh local review.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let item = editor.selected {
                    Button("Edit Scope…") {
                        Task {
                            if await editor.beginScopeEdit(bindingId: item.bindingId) {
                                editingScope = true
                            }
                        }
                    }.disabled(editor.busy || item.localStatus == "locally_revoked")
                    Button("Check Owner Channel") {
                        Task { await editor.perform(.test, bindingId: item.bindingId) }
                    }.disabled(editor.busy)
                    Button("Revoke Local Access…") { confirm(.revoke, item: item) }
                        .disabled(editor.busy || item.localStatus == "locally_revoked")
                    Button("Remove Saved Credential…") { confirm(.remove, item: item) }
                        .disabled(editor.busy)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 790, minHeight: 530)
        .task { await editor.load(environment: model.brokerConnectionEnvironment,
            selected: model.brokerWorkspace, deviceId: deviceID) }
        .onDisappear { Task { await editor.close() } }
        .sheet(isPresented: $editingScope, onDismiss: { editor.cancelScopeEdit() }) {
            scopeEditor
        }
    }

    private var scopeEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit connection scope").font(.title2.bold())
            Text("The endpoint and saved credential stay fixed. Change the alias, operation paths, or remove operations. The exact proposal requires a separate review.")
                .foregroundStyle(.secondary)
            TextField("Alias", text: $editor.aliasInput)
            if let draft = editor.scopeDraft {
                Text("Operations").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(draft.grant.operations.indices, id: \.self) { index in
                            let operation = draft.grant.operations[index]
                            VStack(alignment: .leading, spacing: 5) {
                                Toggle("\(operation.method.rawValue) \(operation.name)", isOn: Binding(
                                    get: { editor.operationEnabled.indices.contains(index) ? editor.operationEnabled[index] : false },
                                    set: { if editor.operationEnabled.indices.contains(index) { editor.operationEnabled[index] = $0 } }))
                                TextField("Path and query", text: Binding(
                                    get: { editor.operationPaths.indices.contains(index) ? editor.operationPaths[index] : "" },
                                    set: { if editor.operationPaths.indices.contains(index) { editor.operationPaths[index] = $0 } }))
                                    .disabled(!editor.operationEnabled[index])
                            }
                        }
                    }
                }.frame(minHeight: 180)
            }
            if let error = editor.error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { editingScope = false }.disabled(editor.busy)
                Button(editor.busy ? "Reviewing…" : "Review Exact Scope…") {
                    Task {
                        if await editor.submitScopeEdit() { editingScope = false }
                    }
                }.disabled(editor.busy || editor.scopeDraft == nil)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620, height: 460)
            .interactiveDismissDisabled(editor.busy)
    }

    private func confirm(_ action: BrokerDeviceConnectionsModel.Action,
                         item: WorkbenchConnectionSummary) {
        let alert = NSAlert()
        alert.messageText = action == .remove
            ? "Remove saved credential for \(item.alias)?"
            : "Revoke local access for \(item.alias)?"
        alert.informativeText = "This changes authorization on this Mac. Upstream revocation is unsupported; inspect device and service status afterward."
        alert.addButton(withTitle: action == .remove ? "Remove" : "Revoke")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await editor.perform(action, bindingId: item.bindingId) }
    }
}

@MainActor
private enum BrokerConnectionScopeReviewDialog {
    static func approve(_ scope: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Review exact connection scope"
        alert.informativeText = "Read the full broker-frozen scope before approving. Cancel leaves the proposal unapproved."
        alert.addButton(withTitle: "Approve Exact Scope")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 400))
        scroll.hasVerticalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = scope
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.frame.size.height = max(400, layout.usedRect(for: container).height + 24)
        }
        scroll.documentView = view
        alert.accessoryView = scroll
        let approve = alert.buttons[0]
        approve.isEnabled = false
        let update: () -> Void = {
            approve.isEnabled = scroll.contentView.documentVisibleRect.maxY >= view.bounds.maxY - 2
        }
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { _ in update() }
        update()
        let response = alert.runModal()
        NotificationCenter.default.removeObserver(observer)
        return response == .alertFirstButtonReturn && approve.isEnabled
    }
}
