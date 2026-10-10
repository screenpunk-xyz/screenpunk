import AppKit
import SwiftUI
import ScreenpunkApple
import ScreenpunkController
import ScreenpunkCore

/// The installed broker owns selection, identity and mutations. This consumer only
/// keeps an authenticated connection and renders a verified local package copy.
@MainActor
final class BrokerWorkbench: ObservableObject {
    @Published private(set) var workspace: WorkbenchWorkspaceStatus?
    @Published private(set) var projects: [WorkspaceProject] = []
    @Published private(set) var packages: [WorkbenchWorkspacePackageSummary] = []
    @Published private(set) var screenSymbols: [String: String] = [:]
    @Published private(set) var iconMutationInProgress = false
    @Published private(set) var screenMutationInProgress = false
    @Published private(set) var devices: [WorkbenchDeviceRead] = []
    @Published private(set) var selectedDeviceId: String?
    @Published private(set) var deviceDetail: WorkbenchDeviceRead?
    @Published private(set) var deviceSettings: DeviceSettingsSnapshot?
    @Published private(set) var deviceInventory: DeviceConnectionInventory?
    @Published var draftDeviceName = "" { didSet { deviceSettingsDraftGate.edited() } }
    @Published var draftBrightnessMode: DeviceBrightnessMode = .system {
        didSet { deviceSettingsDraftGate.edited() }
    }
    @Published var draftBrightnessLevel = 0.5 { didSet { deviceSettingsDraftGate.edited() } }
    @Published private(set) var preview: PackageAssetStore?
    @Published private(set) var previewRevision = ""
    @Published private(set) var pendingPairing: WorkbenchPairingRead?
    @Published var selectedDashboard: String?
    @Published private(set) var selectedProject: WorkbenchSourceProject?
    @Published private(set) var projectBuild: WorkbenchBuildRead?
    @Published private(set) var sourceVersions: [WorkbenchSourceHistoryEntry] = []
    @Published private(set) var packageHistory: [WorkbenchPackageHistoryRead] = []
    @Published var editor = BrokerSourceDraftState()
    @Published private(set) var copiedMigrationPlan: WorkbenchMigrationPlanRead?
    @Published private(set) var copiedMigrationBusy = false
    @Published private(set) var guiLeaseStatus = "GUI identity not yet verified"
    @Published private(set) var reviewInProgress = false
    @Published var error: String?
    @Published var notice: String?
    private var client: WorkbenchBrokerClient?
    var cloudServiceInvocation: CloudScreenServiceInvocation {
        let dashboardId = packages.first(where: { Self.packageKey($0) == selectedDashboard })?.dashboardId ?? ""
        return CloudControllerIntegration.previewInvocation(dashboardId: dashboardId,
            client: { [weak self] in self?.client },
            currentDashboard: { [weak self] in
                guard let self else { return "" }
                return self.packages.first(where: { Self.packageKey($0) == self.selectedDashboard })?.dashboardId ?? ""
            })
    }
    private var loading = false
    private var previewRequest = UUID()
    private var projectGate = BrokerProjectReadGate()
    private var requestedProjectId: String? { projectGate.projectId }
    private var sourceRequest = UUID()
    private var saveRequest = UUID()
    private var buildRequest = UUID()
    private var createRequest = UUID()
    private var iconRequest = UUID()
    private var sendScreenIcon: ((WorkbenchScreenIconRequest) throws -> WorkbenchScreenIconResult)?
    private var screenMutationRequest = UUID()
    private var sendSourceRename: ((WorkbenchScreenRenameRequest) throws -> WorkbenchScreenRenameResult)?
    private var sendPackageRename: ((WorkbenchScreenPackageRenameRequest) throws -> WorkbenchScreenPackageRenameResult)?
    private var sendPackageDuplicate: ((WorkbenchScreenPackageDuplicateRequest) throws -> WorkbenchScreenPackageDuplicateResult)?
    private var sendPackageOrientation: ((WorkbenchScreenPackageOrientationRequest) throws -> WorkbenchScreenPackageOrientationResult)?
    private var sendScreenArchive: ((WorkbenchScreenArchiveRequest) throws -> WorkbenchScreenArchiveResult)?
    private var sendReactAssociation: ((WorkbenchReactSourceAssociationRequest) throws -> WorkbenchReactSourceAssociationResult)?
    private var deviceGate = BrokerDeviceReadGate()
    private var deviceSettingsDraftGate = BrokerDeviceSettingsDraftGate()
    private var leaseClient: WorkbenchBrokerClient?
    private var leaseTask: Task<Void, Never>?
    private var leaseSchedule: BrokerGUILeaseSchedule?
    private var leaseGeneration = UUID()
    private var leaseEnvironment: WorkbenchBrokerEnvironment?
    private var leaseExpectedHome: String?
    var deviceSettingsHasUnsavedEdits: Bool { deviceSettingsDraftGate.hasUnsavedEdits }
    var canChangeScreenIcon: Bool { sendScreenIcon != nil && !iconMutationInProgress }
    var canRenameSource: Bool { sendSourceRename != nil && !screenMutationInProgress }
    var canRenamePackage: Bool { sendPackageRename != nil && !screenMutationInProgress }
    var canDuplicatePackage: Bool { sendPackageDuplicate != nil && !screenMutationInProgress }
    var canSetPackageOrientation: Bool { sendPackageOrientation != nil && !screenMutationInProgress }
    var canArchiveScreen: Bool { sendScreenArchive != nil && !screenMutationInProgress }
    var canAssociateReactSource: Bool { sendReactAssociation != nil && !screenMutationInProgress }
    func screenSymbol(_ dashboardId: String) -> String {
        let candidate = screenSymbols[dashboardId] ?? "star"
        return NSImage(systemSymbolName: candidate, accessibilityDescription: nil) == nil
            ? "star" : candidate
    }

    private static func copiedMigrationDestination(home: URL) -> URL {
        home.deletingLastPathComponent().appendingPathComponent("migrated-workspace-gui", isDirectory: true)
    }

    func dismissCopiedMigrationPlan() { copiedMigrationPlan = nil }

    /// This only plans recovery of the disposable legacy package copy. The
    /// separate personal editable-source archive is not a migration input.
    func planCopiedLibraryMigration() {
        guard let paths = MacGUIRuntime.isolatedTestPaths,
              workspace?.state != "selected", !copiedMigrationBusy else { return }
        copiedMigrationBusy = true
        let destination = Self.copiedMigrationDestination(home: paths.home)
        Task.detached { [weak self] in
            do {
                let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: paths.runtime,
                    limits: .init(timeout: 120))
                let client = WorkbenchBrokerClient(environment: environment)
                try client.connect(); defer { client.close() }
                guard try client.hello().controllerHomePath == paths.home.path,
                      try client.workspaceStatus().state != "selected" else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                let result = try client.performAuthoring(method: .migrationPlan,
                    params: ["schemaVersion": 1, "path": paths.home.path,
                             "destination": destination.path])
                guard let plan = result.migrationPlan,
                      plan.sourcePath == paths.home.path,
                      plan.destinationPath == destination.path else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                await MainActor.run {
                    self?.copiedMigrationBusy = false
                    self?.copiedMigrationPlan = plan
                }
            } catch {
                await MainActor.run {
                    self?.copiedMigrationBusy = false
                    self?.error = "Copied-library plan failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func applyCopiedLibraryMigration() {
        guard let paths = MacGUIRuntime.isolatedTestPaths,
              let plan = copiedMigrationPlan, plan.applyAvailable,
              plan.unsupportedPortablePaths.isEmpty,
              plan.sourcePath == paths.home.path,
              plan.destinationPath == Self.copiedMigrationDestination(home: paths.home).path,
              workspace?.state != "selected", !copiedMigrationBusy else { return }
        let alert = NSAlert()
        alert.messageText = "Recover copied package library?"
        alert.informativeText = "This copies package history into the disposable test workspace. Editable personal source remains in its separate archive. Device records and authority are not imported."
        alert.addButton(withTitle: "Recover Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        copiedMigrationBusy = true
        // The pending plan is one-use. An uncertain result requires a new plan
        // and inspection of the destination before another attempt.
        copiedMigrationPlan = nil
        Task.detached { [weak self] in
            let client: WorkbenchBrokerClient
            do {
                let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: paths.runtime,
                    limits: .init(timeout: 120))
                client = WorkbenchBrokerClient(environment: environment,
                    credentialScope: .localReview)
                try client.connect()
                defer {
                    _ = try? client.releaseGUIConsumer()
                    client.close()
                }
                guard try client.hello().controllerHomePath == paths.home.path else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                _ = try client.registerGUIConsumer()
                guard try client.workspaceStatus().state != "selected",
                      try client.performAuthoring(method: .migrationReview,
                          params: ["schemaVersion": 1,
                                   "migrationId": plan.migrationId]).migrationPlan == plan else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                let result = try client.performAuthoring(method: .migrationApply,
                    params: ["schemaVersion": 1, "migrationId": plan.migrationId])
                guard result.migrationApplied?.state == "selected",
                      result.migrationApplied?.path == plan.destinationPath else {
                    throw WorkbenchIPCError(.publicationOutcomeUnknown)
                }
                await MainActor.run {
                    self?.copiedMigrationBusy = false
                    self?.notice = "Copied package library recovered. Editable personal source remains in its separate archive."
                    self?.refresh()
                }
            } catch {
                await MainActor.run {
                    self?.copiedMigrationBusy = false
                    self?.error = "Migration outcome needs inspection before any retry: \(error.localizedDescription)"
                    self?.refresh()
                }
            }
        }
    }

    /// B installs its typed client call after registering the central route.
    /// The GUI only submits a closed selection-bound request and never opens
    /// portable settings for writing.
    func installScreenIconSender(_ sender: @escaping (WorkbenchScreenIconRequest) throws
        -> WorkbenchScreenIconResult) {
        sendScreenIcon = sender
    }

    func installScreenMutationSenders(
        sourceRename: @escaping (WorkbenchScreenRenameRequest) throws -> WorkbenchScreenRenameResult,
        packageRename: @escaping (WorkbenchScreenPackageRenameRequest) throws -> WorkbenchScreenPackageRenameResult,
        packageDuplicate: @escaping (WorkbenchScreenPackageDuplicateRequest) throws -> WorkbenchScreenPackageDuplicateResult,
        packageOrientation: @escaping (WorkbenchScreenPackageOrientationRequest) throws -> WorkbenchScreenPackageOrientationResult) {
        sendSourceRename = sourceRename
        sendPackageRename = packageRename
        sendPackageDuplicate = packageDuplicate
        sendPackageOrientation = packageOrientation
    }

    /// B supplies these after registering both additional closed routes.
    func installScreenArchiveAssociationSenders(
        archive: @escaping (WorkbenchScreenArchiveRequest) throws -> WorkbenchScreenArchiveResult,
        reactAssociation: @escaping (WorkbenchReactSourceAssociationRequest) throws -> WorkbenchReactSourceAssociationResult) {
        sendScreenArchive = archive
        sendReactAssociation = reactAssociation
    }

    func archivePackageScreen(_ package: WorkbenchWorkspacePackageSummary) {
        guard !screenMutationInProgress, let sendScreenArchive,
              let selected = workspace, let workspaceId = selected.workspaceId,
              let selection = selected.selectionGeneration,
              let generation = selected.generation, packages.contains(package) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(package.name) from the Library?"
        alert.informativeText = "Its source and package history remain available for recovery. This does not remove installed copies from devices."
        alert.addButton(withTitle: "Remove from Library")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let request: WorkbenchScreenArchiveRequest
        do { request = try .parse(["schemaVersion": 1,
            "expectedWorkspaceId": workspaceId,
            "expectedSelectionGeneration": selection,
            "expectedCatalogGeneration": generation,
            "dashboardId": package.dashboardId,
            "expectedRevision": package.revision,
            "expectedDigest": package.digest]) }
        catch { self.error = error.localizedDescription; return }
        let token = UUID(); screenMutationRequest = token; screenMutationInProgress = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let receipt = try sendScreenArchive(request)
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    if self.workspace?.workspaceId == workspaceId,
                       self.workspace?.selectionGeneration == selection,
                       receipt.workspaceId == workspaceId,
                       receipt.selectionGeneration == selection,
                       receipt.catalogGeneration == generation + 1,
                       receipt.dashboardId == package.dashboardId,
                       receipt.packageHistoryRetained,
                       receipt.deviceContentsUntouched {
                        self.notice = "Screen removed from the Library. History remains available."
                    } else { self.notice = "Removal result needs a workspace refresh before display." }
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    self.error = "Removal may have applied. Refresh the Library before retrying: \(error.localizedDescription)"
                }
            }
        }
    }

    func archiveSelectedSourceScreen() {
        guard !screenMutationInProgress, let sendScreenArchive, let selectedProject,
              let selected = workspace, let workspaceId = selected.workspaceId,
              let selection = selected.selectionGeneration,
              let generation = selected.generation else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(selectedProject.project.name) from the Library?"
        alert.informativeText = "Editable source and its history remain in the workspace. This does not remove installed copies from devices."
        alert.addButton(withTitle: "Remove from Library")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let request: WorkbenchScreenArchiveRequest
        do { request = try .parse(["schemaVersion": 1,
            "expectedWorkspaceId": workspaceId,
            "expectedSelectionGeneration": selection,
            "expectedCatalogGeneration": generation,
            "dashboardId": selectedProject.project.dashboardId,
            "projectId": selectedProject.project.projectId,
            "expectedSourceVersion": selectedProject.sourceVersion]) }
        catch { self.error = error.localizedDescription; return }
        let token = UUID(); screenMutationRequest = token; screenMutationInProgress = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let receipt = try sendScreenArchive(request)
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    if self.workspace?.workspaceId == workspaceId,
                       self.workspace?.selectionGeneration == selection,
                       receipt.workspaceId == workspaceId,
                       receipt.selectionGeneration == selection,
                       receipt.catalogGeneration == generation + 1,
                       receipt.dashboardId == request.dashboardId,
                       receipt.sourceRetained, receipt.deviceContentsUntouched {
                        self.notice = "Screen removed from the Library. Editable source remains available."
                    } else { self.notice = "Removal result needs a workspace refresh before display." }
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    self.error = "Removal may have applied. Refresh the Library before retrying: \(error.localizedDescription)"
                }
            }
        }
    }

    func associateSelectedReactSource() {
        guard !screenMutationInProgress, let sendReactAssociation,
              let selectedProject, let selectedKey = selectedDashboard,
              let package = packages.first(where: { Self.packageKey($0) == selectedKey }),
              let selected = workspace, let workspaceId = selected.workspaceId,
              let selection = selected.selectionGeneration,
              let generation = selected.generation else { return }
        let request: WorkbenchReactSourceAssociationRequest
        do { request = try .parse(["schemaVersion": 1,
            "expectedWorkspaceId": workspaceId,
            "expectedSelectionGeneration": selection,
            "expectedCatalogGeneration": generation,
            "projectId": selectedProject.project.projectId,
            "expectedSourceVersion": selectedProject.sourceVersion,
            "dashboardId": package.dashboardId,
            "expectedRevision": package.revision,
            "expectedDigest": package.digest]) }
        catch { self.error = error.localizedDescription; return }
        let token = UUID(); screenMutationRequest = token; screenMutationInProgress = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let receipt = try sendReactAssociation(request)
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    if self.workspace?.workspaceId == workspaceId,
                       self.workspace?.selectionGeneration == selection,
                       receipt.workspaceId == workspaceId,
                       receipt.selectionGeneration == selection,
                       receipt.project.project.projectId == request.projectId,
                       receipt.project.project.dashboardId == request.dashboardId,
                       receipt.packageRevision == package.revision,
                       receipt.packageDigest == package.digest,
                       !receipt.authorityRestored {
                        self.notice = "React source attached to this screen. Build again to publish source changes."
                    } else { self.notice = "Attachment result needs a workspace refresh before display." }
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    self.error = "Attachment may have applied. Refresh source and package history before retrying: \(error.localizedDescription)"
                }
            }
        }
    }

    private func screenNamePrompt(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func renameSelectedSource() {
        guard !screenMutationInProgress, let selectedProject,
              let sendSourceRename, let selected = workspace,
              let raw = screenNamePrompt(title: "Rename Screen",
                  initial: selectedProject.project.name) else { return }
        let intent: BrokerScreenRenameGate.SourceIntent
        do { intent = try BrokerScreenRenameGate.source(workspace: selected,
            project: selectedProject, name: raw) }
        catch { self.error = error.localizedDescription; return }
        let request: WorkbenchScreenRenameRequest
        do { request = try .parse(intent.fields) }
        catch { self.error = error.localizedDescription; return }
        let token = UUID(); screenMutationRequest = token; screenMutationInProgress = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let receipt = try sendSourceRename(request)
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    if let current = self.workspace,
                       intent.accepts(receipt, current: current,
                           displayedProjectId: self.selectedProject?.project.projectId) {
                        self.notice = "Source renamed. Build to create a package with the new name."
                    } else {
                        self.notice = "Rename result needs a workspace refresh before display."
                    }
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    self.error = "Rename may have applied. Refresh the project and source version before retrying: \(error.localizedDescription)"
                }
            }
        }
    }

    func renamePackage(_ package: WorkbenchWorkspacePackageSummary) {
        guard !screenMutationInProgress, let sendPackageRename,
              let selected = workspace,
              let raw = screenNamePrompt(title: "Rename Screen", initial: package.name) else { return }
        let intent: BrokerScreenRenameGate.PackageIntent
        do { intent = try BrokerScreenRenameGate.package(workspace: selected,
            package: package, name: raw) }
        catch { self.error = error.localizedDescription; return }
        let request: WorkbenchScreenPackageRenameRequest
        do { request = try .parse(intent.fields) }
        catch { self.error = error.localizedDescription; return }
        let token = UUID(); screenMutationRequest = token; screenMutationInProgress = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let receipt = try sendPackageRename(request)
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    if let current = self.workspace,
                       intent.accepts(receipt, current: current,
                           displayedPackageKey: self.packages.contains(package)
                               ? Self.packageKey(package) : nil) {
                        self.notice = "Renamed package saved as a new revision. Select it to preview."
                    } else {
                        self.notice = "Rename result needs a workspace refresh before display."
                    }
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    self.error = "Rename may have applied. Refresh package history before retrying: \(error.localizedDescription)"
                }
            }
        }
    }

    func duplicatePackage(_ package: WorkbenchWorkspacePackageSummary) {
        guard !screenMutationInProgress, let sendPackageDuplicate,
              let selected = workspace,
              let raw = screenNamePrompt(title: "Duplicate Screen",
                  initial: package.name + " Copy") else { return }
        let intent: BrokerScreenRenameGate.PackageIntent
        do { intent = try BrokerScreenRenameGate.package(workspace: selected,
            package: package, name: raw) }
        catch { self.error = error.localizedDescription; return }
        let request: WorkbenchScreenPackageDuplicateRequest
        do { request = try .parse(intent.fields) }
        catch { self.error = error.localizedDescription; return }
        let token = UUID(); screenMutationRequest = token; screenMutationInProgress = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let receipt = try sendPackageDuplicate(request)
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    if let current = self.workspace,
                       intent.acceptsDuplicate(receipt, current: current,
                           displayedPackageKey: self.packages.contains(package)
                               ? Self.packageKey(package) : nil) {
                        self.notice = "Duplicate saved with a new screen ID. Connections need their own grants."
                    } else {
                        self.notice = "Duplicate result needs a workspace refresh before display."
                    }
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    self.error = "Duplicate may have applied. Refresh package history before retrying: \(error.localizedDescription)"
                }
            }
        }
    }

    func setPackageOrientation(_ package: WorkbenchWorkspacePackageSummary,
                               support: ScreenOrientationSupport) {
        guard !screenMutationInProgress, let sendPackageOrientation,
              let selected = workspace, let workspaceId = selected.workspaceId,
              let selection = selected.selectionGeneration,
              let generation = selected.generation,
              packages.contains(package) else { return }
        let request: WorkbenchScreenPackageOrientationRequest
        do { request = try .parse(["schemaVersion": 1,
            "expectedWorkspaceId": workspaceId,
            "expectedSelectionGeneration": selection,
            "expectedCatalogGeneration": generation,
            "dashboardId": package.dashboardId,
            "expectedRevision": package.revision,
            "expectedDigest": package.digest,
            "support": support.rawValue]) }
        catch { self.error = error.localizedDescription; return }
        let token = UUID(); screenMutationRequest = token; screenMutationInProgress = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let receipt = try sendPackageOrientation(request)
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    if self.workspace?.workspaceId == workspaceId,
                       self.workspace?.selectionGeneration == selection,
                       self.packages.contains(package),
                       receipt.workspaceId == workspaceId,
                       receipt.selectionGeneration == selection,
                       receipt.dashboardId == package.dashboardId,
                       receipt.priorRevision == package.revision,
                       receipt.support == support,
                       (receipt.catalogGeneration == generation + 1 &&
                        receipt.revision != package.revision ||
                        receipt.catalogGeneration == generation &&
                        receipt.revision == package.revision &&
                        receipt.digest == package.digest) {
                        self.notice = "Orientation support saved. Select the new revision to preview."
                    } else {
                        self.notice = "Orientation result needs a workspace refresh before display."
                    }
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    guard let self = owner, self.screenMutationRequest == token else { return }
                    self.screenMutationInProgress = false
                    self.error = "Orientation change may have applied. Refresh package history before retrying: \(error.localizedDescription)"
                }
            }
        }
    }

    func changeScreenIcon(dashboardId: String, symbol: String) {
        guard !iconMutationInProgress, let sendScreenIcon, let selected = workspace,
              let workspaceId = selected.workspaceId,
              let selection = selected.selectionGeneration,
              let generation = selected.generation,
              packages.contains(where: { $0.dashboardId == dashboardId }),
              NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else {
            error = "Refresh the selected workspace before changing this icon."
            return
        }
        guard screenSymbol(dashboardId) != symbol else { return }
        let request: WorkbenchScreenIconRequest
        do {
            request = try .parse(["schemaVersion": 1,
                "expectedWorkspaceId": workspaceId,
                "expectedSelectionGeneration": selection,
                "expectedCatalogGeneration": generation,
                "dashboardId": dashboardId, "symbol": symbol])
        } catch { self.error = error.localizedDescription; return }
        let token = UUID(); iconRequest = token; iconMutationInProgress = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let receipt = try sendScreenIcon(request)
                await MainActor.run {
                    guard let self = owner, self.iconRequest == token else { return }
                    self.iconMutationInProgress = false
                    guard self.workspace?.workspaceId == workspaceId,
                          self.workspace?.selectionGeneration == selection,
                          receipt.workspaceId == workspaceId,
                          receipt.selectionGeneration == selection,
                          receipt.catalogGeneration == generation + 1,
                          receipt.dashboardId == dashboardId,
                          receipt.symbol == symbol else {
                        self.notice = "Icon result needs a workspace refresh before display."
                        self.refresh()
                        return
                    }
                    self.screenSymbols[dashboardId] = symbol
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    guard let self = owner, self.iconRequest == token else { return }
                    self.iconMutationInProgress = false
                    self.error = "Icon outcome may be unknown. Refresh portable workspace settings before retrying: \(error.localizedDescription)"
                }
            }
        }
    }

    func attach() {
        guard !loading, client == nil else { return }
        loading = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: MacGUIRuntime.runtimeDirectory)
                let connection = WorkbenchBrokerClient(environment: environment)
                try connection.connect()
                let home = DashboardPackageStore.defaultRoot().resolvingSymlinksInPath()
                guard try connection.hello().controllerHomePath == home.path else {
                    connection.close(); throw BrokerConsumerError.controllerHomeMismatch
                }
                await MainActor.run {
                    owner?.client = connection
                    owner?.installScreenMutationSenders(
                        sourceRename: { try connection.renameScreenSource($0) },
                        packageRename: { try connection.renameScreenPackage($0) },
                        packageDuplicate: { try connection.duplicateScreenPackage($0) },
                        packageOrientation: { try connection.setScreenPackageOrientation($0) })
                    owner?.installScreenIconSender { try connection.setScreenIcon($0) }
                    owner?.installScreenArchiveAssociationSenders(
                        archive: { try connection.archiveScreen($0) },
                        reactAssociation: { try connection.associateReactSource($0) })
                    owner?.loading = false
                    owner?.startGUILease(environment: environment, expectedHome: home.path)
                    owner?.refresh()
                }
            } catch {
                await MainActor.run {
                    owner?.loading = false
                    owner?.error = "Workbench service unavailable: \(error.localizedDescription). Start the installed Screenpunk service; this app will not start a second controller."
                }
            }
        }
    }

    private func startGUILease(environment: WorkbenchBrokerEnvironment, expectedHome: String) {
        stopGUILease()
        leaseEnvironment = environment; leaseExpectedHome = expectedHome
        let generation = UUID(); leaseGeneration = generation
        guiLeaseStatus = "Checking signed GUI identity with the broker…"
        leaseTask = Task.detached { [weak self] in
            let leaseConnection = WorkbenchBrokerClient(environment: environment,
                credentialScope: .ordinary)
            var didRegister = false
            do {
                try leaseConnection.connect()
                guard try leaseConnection.hello().controllerHomePath == expectedHome else {
                    throw BrokerConsumerError.controllerHomeMismatch
                }
                let registered = try leaseConnection.registerGUIConsumer()
                didRegister = true
                let now = ProcessInfo.processInfo.systemUptime
                var schedule = try BrokerGUILeaseSchedule(consumerId: registered.consumerId,
                    leaseSeconds: registered.leaseSeconds, now: now)
                guard !Task.isCancelled else {
                    _ = try? leaseConnection.releaseGUIConsumer()
                    leaseConnection.close()
                    return
                }
                let registeredSchedule = schedule
                Task { @MainActor [weak self] in
                    guard let self, self.leaseGeneration == generation else { return }
                    self.leaseClient = leaseConnection
                    self.leaseSchedule = registeredSchedule
                    self.guiLeaseStatus = "Verified GUI lease active"
                }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if Task.isCancelled { break }
                    let tick = ProcessInfo.processInfo.systemUptime
                    if schedule.expired(at: tick) { throw BrokerGUILeaseError.invalidLease }
                    guard schedule.due(at: tick) else { continue }
                    let renewed = try leaseConnection.renewGUIConsumer()
                    let renewalNow = ProcessInfo.processInfo.systemUptime
                    try schedule.renewed(consumerId: renewed.consumerId,
                                         leaseSeconds: renewed.leaseSeconds, now: renewalNow)
                    let renewedSchedule = schedule
                    Task { @MainActor [weak self] in
                        guard let self, self.leaseGeneration == generation else { return }
                        self.leaseSchedule = renewedSchedule
                        self.guiLeaseStatus = "Verified GUI lease active"
                    }
                }
                _ = try? leaseConnection.releaseGUIConsumer()
                leaseConnection.close()
            } catch {
                if didRegister { _ = try? leaseConnection.releaseGUIConsumer() }
                leaseConnection.close()
                await MainActor.run {
                    guard let self, self.leaseGeneration == generation else { return }
                    self.leaseClient = nil; self.leaseSchedule = nil
                    self.guiLeaseStatus = "GUI identity or lease unavailable; broker reliance remains unknown"
                }
            }
        }
    }

    func stopGUILease() {
        leaseGeneration = UUID()
        leaseTask?.cancel(); leaseTask = nil
        // The worker owns its socket and releases the lease after cancellation.
        // Closing it here could race an in-flight renewal on that worker.
        leaseClient = nil; leaseSchedule = nil
        guiLeaseStatus = "GUI lease not active"
    }

    func retryGUILease() {
        guard leaseClient == nil, let leaseEnvironment, let leaseExpectedHome else { return }
        startGUILease(environment: leaseEnvironment, expectedHome: leaseExpectedHome)
    }

    func detach() {
        stopGUILease()
        leaseEnvironment = nil; leaseExpectedHome = nil
        client?.close(); client = nil
        sendScreenIcon = nil; sendSourceRename = nil; sendPackageRename = nil
        sendPackageDuplicate = nil; sendPackageOrientation = nil
        iconRequest = UUID(); screenMutationRequest = UUID()
        iconMutationInProgress = false; screenMutationInProgress = false
        previewRequest = UUID(); projectGate.invalidate()
    }

    func refresh() {
        guard let client, !loading else { return }
        loading = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let workspace = try client.workspaceStatus()
                let projects = workspace.state == "selected" ? try client.listProjects() : []
                let packages = workspace.state == "selected" ? try client.listWorkspacePackages(in: workspace) : []
                let icons: [String: String]
                if workspace.state == "selected",
                   let configured = try? client.performAuthoring(method: .workspaceConfigGet,
                       params: ["schemaVersion": 1]).configuration,
                   configured.workspaceId == workspace.workspaceId,
                   configured.generation == workspace.generation {
                    icons = configured.screenIcons
                } else { icons = [:] }
                let devices = try client.listDevices()
                await MainActor.run {
                    guard let self = owner else { return }
                    let selectionChanged = self.workspace?.workspaceId != workspace.workspaceId ||
                        self.workspace?.selectionGeneration != workspace.selectionGeneration
                    self.workspace = workspace; self.projects = projects
                    self.packages = packages; self.devices = devices
                    self.screenSymbols = icons
                    self.loading = false; self.error = nil
                    if let selectedDeviceId = self.selectedDeviceId,
                       !devices.contains(where: { $0.deviceId == selectedDeviceId }) {
                        if self.deviceSettingsDraftGate.hasUnsavedEdits {
                            self.deviceGate.select(selectedDeviceId)
                            self.deviceDetail = nil; self.deviceInventory = nil
                            self.notice = "Device unavailable; unsaved settings edits are retained."
                        } else {
                            self.deviceGate.select(nil); self.selectedDeviceId = nil
                            self.deviceDetail = nil; self.deviceSettings = nil; self.deviceInventory = nil
                        }
                    }
                    if selectionChanged {
                        self.previewRequest = UUID(); self.selectedDashboard = nil
                        self.projectGate.invalidate()
                        self.sourceRequest = UUID(); self.saveRequest = UUID(); self.buildRequest = UUID()
                        self.createRequest = UUID()
                        self.preview = nil; self.previewRevision = ""
                        self.selectedProject = nil; self.projectBuild = nil
                        self.sourceVersions = []; self.packageHistory = []
                        self.editor.invalidateBinding(preserveDraft: true)
                    }
                    if let selected = self.selectedDashboard {
                        if !packages.contains(where: { Self.packageKey($0) == selected }) {
                            self.previewRequest = UUID(); self.selectedDashboard = nil
                            self.preview = nil; self.previewRevision = ""
                        }
                    }
                    if let id = self.selectedProject?.project.projectId,
                       projects.contains(where: { $0.projectId == id }) {
                        self.inspectProject(id)
                    }
                }
            } catch {
                client.close()
                await MainActor.run {
                    owner?.client = nil; owner?.loading = false
                    owner?.sendScreenIcon = nil; owner?.sendSourceRename = nil
                    owner?.sendPackageRename = nil; owner?.sendPackageDuplicate = nil
                    owner?.sendPackageOrientation = nil
                    owner?.iconRequest = UUID(); owner?.screenMutationRequest = UUID()
                    owner?.iconMutationInProgress = false
                    owner?.screenMutationInProgress = false
                    owner?.previewRequest = UUID(); owner?.preview = nil; owner?.previewRevision = ""
                    owner?.error = "Workbench connection lost: \(error.localizedDescription). Reconnect before making changes."
                }
            }
        }
    }

    static func packageKey(_ package: WorkbenchWorkspacePackageSummary) -> String {
        package.dashboardId + ":" + package.revision
    }

    func select(_ key: String) {
        guard let client, let selected = workspace,
              let summary = packages.first(where: { Self.packageKey($0) == key }) else { return }
        let request = UUID(); previewRequest = request
        selectedDashboard = key; preview = nil; previewRevision = ""; notice = nil
        Task.detached { [weak self] in
            let owner = self
            do {
                let assets = try WorkspacePackagePreviewLoader.load(client: client, selected: selected, summary: summary)
                let currentWorkspace = try client.workspaceStatus()
                guard currentWorkspace.workspaceId == selected.workspaceId,
                      currentWorkspace.selectionGeneration == selected.selectionGeneration else {
                    throw BrokerConsumerError.previewRequired
                }
                await MainActor.run {
                    guard owner?.selectedDashboard == key, owner?.previewRequest == request else { return }
                    owner?.preview = assets; owner?.previewRevision = summary.revision
                    owner?.notice = "Offline preview from selected-workspace history. Live connections require native approval."
                }
            } catch {
                await MainActor.run {
                    guard owner?.selectedDashboard == key, owner?.previewRequest == request else { return }
                    owner?.notice = "preview_required: Selected-workspace package bytes are unavailable or invalid: \(error.localizedDescription)"
                }
            }
        }
    }

    func openWorkspace() {
        guard !loading, let client else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Open Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if editor.requiresDiscard {
            guard confirmDiscardSourceDraft(reason: "open another workspace") else { return }
            editor.discardDraft()
        }
        loading = true
        Task.detached { [weak self] in
            let owner = self
            do {
                _ = try client.openWorkspace(path: url.path)
                await MainActor.run {
                    owner?.loading = false; owner?.previewRequest = UUID()
                    owner?.selectedDashboard = nil; owner?.preview = nil; owner?.previewRevision = ""
                    owner?.refresh()
                }
            } catch {
                await MainActor.run { owner?.loading = false; owner?.error = error.localizedDescription }
            }
        }
    }

    func createProject() {
        guard !loading, let client, let selected = workspace, selected.state == "selected",
              let workspaceId = selected.workspaceId,
              let selectionGeneration = selected.selectionGeneration else {
            error = "Select a visible workspace before creating a project."
            return
        }
        let alert = NSAlert()
        alert.messageText = "New web project"
        alert.informativeText = "Create a contained source project in the selected workspace."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "New Screen")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "A project name is required."; return }
        let request = UUID(); createRequest = request
        loading = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let created = try client.performAuthoring(method: .projectCreate,
                    params: ["schemaVersion": 1, "name": name, "kind": "web",
                             "expectedWorkspaceId": workspaceId,
                             "expectedSelectionGeneration": selectionGeneration])
                var cloudBackupNeedsAttention = false
                if let project = created.project {
                    do { try await CloudControllerIntegration.linkCreated(project, client: client, kind: "web") }
                    catch { cloudBackupNeedsAttention = true }
                }
                await MainActor.run {
                    guard owner?.createRequest == request else { return }
                    owner?.loading = false
                    guard
                          owner?.workspace?.workspaceId == workspaceId,
                          owner?.workspace?.selectionGeneration == selectionGeneration else { return }
                    owner?.refresh()
                    if let name = created.project?.project.name { owner?.notice = cloudBackupNeedsAttention ? "Created \(name). Cloud backup needs attention; your source is retained." : "Created \(name). Select it to edit or build." }
                }
            } catch {
                await MainActor.run {
                    guard owner?.createRequest == request else { return }
                    owner?.loading = false
                    owner?.error = "Project creation rejected; refresh workspace selection: \(error.localizedDescription)"
                }
            }
        }
    }

    func inspectProject(_ id: String) {
        guard !loading, let client, let selected = workspace, selected.state == "selected",
              let workspaceId = selected.workspaceId,
              let selectionGeneration = selected.selectionGeneration else { return }
        if editor.needsDiscardBeforeNavigating(
            from: selectedProject?.project.projectId, to: id) {
            guard confirmDiscardSourceDraft(reason: "select another project") else { return }
            editor.discardDraft()
        }
        let request = projectGate.begin(projectId: id, workspaceId: workspaceId,
                                        selectionGeneration: selectionGeneration)
        if selectedProject?.project.projectId != id {
            selectedProject = nil; projectBuild = nil
            sourceVersions = []; packageHistory = []
            sourceRequest = UUID(); saveRequest = UUID(); buildRequest = UUID()
            editor.invalidateBinding(preserveDraft: false)
        }
        Task.detached { [weak self] in
            let owner = self
            do {
                try Self.assertSelection(client: client, expected: selected)
                let inspected = try client.performAuthoring(method: .projectInspect,
                    params: ["schemaVersion": 1, "projectId": id,
                             "expectedWorkspaceId": workspaceId,
                             "expectedSelectionGeneration": selectionGeneration])
                let versions = try client.projectVersions(id)
                let history = try client.performAuthoring(method: .packageHistory,
                    params: ["schemaVersion": 1, "expectedWorkspaceId": workspaceId,
                             "expectedSelectionGeneration": selectionGeneration])
                try Self.assertSelection(client: client, expected: selected)
                let matchingHistory = history.packages?.filter {
                    $0.dashboardId == inspected.project?.project.dashboardId
                } ?? []
                let head = matchingHistory.isEmpty ? nil : try? client.performAuthoring(
                    method: .buildHead, params: ["schemaVersion": 1, "projectId": id,
                        "expectedWorkspaceId": workspaceId,
                        "expectedSelectionGeneration": selectionGeneration])
                if head != nil {
                    try Self.assertSelection(client: client, expected: selected)
                }
                await MainActor.run {
                    guard owner?.workspace?.workspaceId == selected.workspaceId,
                          owner?.workspace?.selectionGeneration == selected.selectionGeneration,
                          owner?.projectGate.accepts(request, projectId: id,
                              workspaceId: workspaceId,
                              selectionGeneration: selectionGeneration) == true else { return }
                    if owner?.selectedProject?.project.projectId != id {
                        owner?.editor.invalidateBinding(preserveDraft: false)
                    }
                    owner?.selectedProject = inspected.project
                    owner?.projectBuild = head?.build
                    owner?.sourceVersions = versions
                    owner?.packageHistory = history.packages ?? []
                    owner?.error = nil
                    if !matchingHistory.isEmpty && head == nil {
                        owner?.client = nil
                        owner?.attach()
                    }
                }
            } catch {
                await MainActor.run {
                    guard owner?.projectGate.accepts(request, projectId: id,
                        workspaceId: workspaceId,
                        selectionGeneration: selectionGeneration) == true else { return }
                    owner?.error = "Project inspection unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadSource() {
        guard !loading, let client, let project = selectedProject, let selected = workspace,
              let workspaceId = selected.workspaceId,
              let selectionGeneration = selected.selectionGeneration else { return }
        let path = editor.requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let startingDraftRevision = editor.draftRevision
        let request = UUID(); sourceRequest = request
        Task.detached { [weak self] in
            let owner = self
            do {
                let read = try client.sourceText(projectId: project.project.projectId, path: path,
                    expectedWorkspaceId: workspaceId,
                    expectedSelectionGeneration: selectionGeneration)
                let current = try client.workspaceStatus()
                guard current.workspaceId == workspaceId,
                      current.selectionGeneration == selectionGeneration else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                await MainActor.run {
                    guard owner?.workspace?.workspaceId == workspaceId,
                          owner?.workspace?.selectionGeneration == selectionGeneration,
                          owner?.selectedProject?.project.projectId == project.project.projectId,
                          owner?.requestedProjectId == project.project.projectId,
                          owner?.sourceRequest == request,
                          owner?.editor.requestedPath.trimmingCharacters(in: .whitespacesAndNewlines) == path else { return }
                    if owner?.editor.needsExplicitReplacement(since: startingDraftRevision) == true {
                        guard owner?.confirmDiscardSourceDraft(reason: "reload source from the workspace") == true else {
                            owner?.notice = "Newer source draft retained; reload was not applied."
                            return
                        }
                    }
                    owner?.editor.load(workspaceId: workspaceId, projectId: read.projectId, path: read.path,
                                       version: read.sourceVersion, text: read.text)
                    owner?.error = nil
                }
            } catch {
                await MainActor.run {
                    guard owner?.sourceRequest == request,
                          owner?.requestedProjectId == project.project.projectId else { return }
                    owner?.client = nil
                    owner?.error = "Source read unavailable; draft retained: \(error.localizedDescription)"
                    owner?.attach()
                }
            }
        }
    }

    func discardSourceDraft() {
        guard confirmDiscardSourceDraft(reason: "discard this retained draft") else { return }
        editor.discardDraft()
    }

    private func confirmDiscardSourceDraft(reason: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard unsaved source draft?"
        alert.informativeText = "To \(reason), this unsaved text must be discarded. Copy anything you need before continuing."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Draft")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func saveSource() {
        guard !loading, let client, let project = selectedProject, let selected = workspace,
              let workspaceId = selected.workspaceId,
              let selectionGeneration = selected.selectionGeneration,
              editor.loadedProjectId == project.project.projectId, editor.canSave else {
            error = "Load this source file before saving."
            return
        }
        let bytes = Data(editor.draft.utf8)
        guard bytes.count <= 2_048 else {
            error = "Source edits are limited to 2,048 UTF-8 bytes per save."
            return
        }
        let path = editor.loadedPath, version = editor.version
        let savedText = editor.draft
        let request = UUID(); saveRequest = request; sourceRequest = UUID()
        loading = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let result = try client.performAuthoring(method: .projectPatch, params: [
                    "schemaVersion": 1, "projectId": project.project.projectId,
                    "expectedSourceVersion": version,
                    "changes": [["path": path, "bytesBase64": bytes.base64EncodedString()]],
                    "expectedWorkspaceId": workspaceId,
                    "expectedSelectionGeneration": selectionGeneration])
                await MainActor.run {
                    guard owner?.saveRequest == request,
                          owner?.requestedProjectId == project.project.projectId else { return }
                    owner?.loading = false
                    guard
                          owner?.workspace?.workspaceId == workspaceId,
                          owner?.workspace?.selectionGeneration == selectionGeneration,
                          owner?.editor.loadedPath == path else { return }
                    _ = owner?.editor.saveSucceeded(expectedVersion: version,
                        submittedText: savedText, newVersion: result.project?.sourceVersion ?? "")
                    owner?.notice = "Source saved. Build to create a new package revision."
                    owner?.refresh()
                }
            } catch {
                await MainActor.run {
                    guard owner?.saveRequest == request,
                          owner?.requestedProjectId == project.project.projectId else { return }
                    owner?.loading = false
                    owner?.editor.saveFailed()
                    owner?.client = nil
                    owner?.error = "Source save conflicted or failed; draft retained. Reload source explicitly after reviewing it: \(error.localizedDescription)"
                    owner?.attach()
                }
            }
        }
    }

    func buildSelectedProject() {
        guard !editor.dirty, !editor.conflict else {
            error = "Save the source draft or reload the conflicted file before building."
            return
        }
        guard !loading, let client, let project = selectedProject, let selected = workspace,
              let workspaceId = selected.workspaceId,
              let selectionGeneration = selected.selectionGeneration else { return }
        let expectedSourceVersion = editor.loadedProjectId == project.project.projectId &&
            !editor.version.isEmpty ? editor.version : project.sourceVersion
        let request = UUID(); buildRequest = request
        loading = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let built = try client.performAuthoring(method: .buildRun, params: [
                    "schemaVersion": 1, "projectId": project.project.projectId,
                    "expectedSourceVersion": expectedSourceVersion,
                    "expectedWorkspaceId": workspaceId,
                    "expectedSelectionGeneration": selectionGeneration])
                await MainActor.run {
                    guard owner?.buildRequest == request,
                          owner?.requestedProjectId == project.project.projectId else { return }
                    owner?.loading = false
                    guard
                          owner?.workspace?.workspaceId == workspaceId,
                          owner?.workspace?.selectionGeneration == selectionGeneration else { return }
                    owner?.projectBuild = built.build
                    owner?.notice = built.build?.diagnostics
                    owner?.refresh()
                }
            } catch {
                await MainActor.run {
                    guard owner?.buildRequest == request,
                          owner?.requestedProjectId == project.project.projectId else { return }
                    owner?.loading = false
                    owner?.error = "Build rejected; reload the workspace and source version: \(error.localizedDescription)"
                }
            }
        }
    }

    func reviewConnectionIntent() {
        guard !reviewInProgress else { return }
        let prompt = NSAlert()
        prompt.messageText = "Review a pending connection"
        prompt.informativeText = "Enter the exact pending intent ID. The broker will freeze a redacted scope for this review."
        prompt.addButton(withTitle: "Review")
        prompt.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "Intent ID"
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 26)
        prompt.accessoryView = field
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        let intentId = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intentId.isEmpty else {
            error = "A pending intent ID is required."
            return
        }
        reviewInProgress = true
        Task.detached { [weak self] in
            let reviewClient: WorkbenchBrokerClient
            do {
                let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: MacGUIRuntime.runtimeDirectory)
                reviewClient = WorkbenchBrokerClient(environment: environment,
                                                     credentialScope: .localReview)
            } catch {
                await MainActor.run {
                    self?.reviewInProgress = false
                    self?.error = "Trusted local review is unavailable. Nothing was approved."
                }
                return
            }
            var decisionSent = false
            do {
                try reviewClient.connect()
                let expectedHome = DashboardPackageStore.defaultRoot().resolvingSymlinksInPath().path
                guard try reviewClient.hello().controllerHomePath == expectedHome else {
                    throw BrokerConsumerError.controllerHomeMismatch
                }
                let review = try reviewClient.beginConnectionReview(intentId: intentId)
                var reviewState = try BrokerLocalReviewState(intentId: review.intentId,
                    reviewHandle: review.reviewHandle, expiresAt: review.reviewExpiresAt)
                let facts = BrokerConnectionReviewPresentation.facts(review)
                let completeScope = try BrokerConnectionReviewPresentation.render(facts)
                let decision = await MainActor.run { () -> BrokerReviewDecision in
                    guard let self else { return .leavePending }
                    return self.presentConnectionReview(completeScope)
                }
                switch decision {
                case .approve:
                    try reviewState.consume(.approve, at: Date())
                    decisionSent = true
                    let result = try reviewClient.confirmConnectionReview(review)
                    reviewClient.close()
                    await MainActor.run {
                        self?.reviewInProgress = false
                        self?.notice = "Connection approved: \(result.summary.alias). Refresh the device inventory."
                    }
                case .deny:
                    try reviewState.consume(.deny, at: Date())
                    decisionSent = true
                    let result = try reviewClient.resolveConnectionIntent(intentId, approve: false)
                    guard result.denied == true else { throw WorkbenchIPCError(.remoteOutcomeUnknown) }
                    reviewClient.close()
                    await MainActor.run {
                        self?.reviewInProgress = false
                        self?.notice = "Connection intent denied."
                    }
                case .leavePending:
                    reviewState.close()
                    reviewClient.close()
                    await MainActor.run {
                        self?.reviewInProgress = false
                        self?.notice = "Review closed without approval; the intent may remain pending until expiry."
                    }
                }
            } catch {
                reviewClient.close()
                await MainActor.run {
                    self?.reviewInProgress = false
                    if decisionSent || (error as? WorkbenchIPCError)?.code == .remoteOutcomeUnknown {
                        self?.error = "Connection review outcome is unknown. Inspect the intent and device before any retry."
                    } else {
                        self?.error = "Trusted review failed or became stale. Nothing can be assumed approved; inspect the intent before retrying."
                    }
                }
            }
        }
    }

    func selectDevice(_ id: String) {
        guard devices.contains(where: { $0.deviceId == id }) else { return }
        if selectedDeviceId == id { loadDeviceStatus(refresh: false); return }
        if deviceSettingsDraftGate.hasUnsavedEdits, deviceSettings != nil {
            guard confirmDiscardDeviceSettings() else { return }
        }
        deviceGate.select(id)
        selectedDeviceId = id
        deviceDetail = nil; deviceSettings = nil; deviceInventory = nil
        deviceSettingsDraftGate.markLoaded()
        loadDeviceStatus(refresh: false)
    }

    func loadDeviceStatus(refresh: Bool) {
        guard let client, let request = deviceGate.begin(.status) else { return }
        let id = request.deviceId
        Task.detached { [weak self] in
            let owner = self
            do {
                let value = try client.deviceStatus(id, refresh: refresh)
                await MainActor.run {
                    guard owner?.deviceGate.accepts(request) == true,
                          value.deviceId == id else { return }
                    owner?.deviceDetail = value
                    owner?.error = nil
                }
            } catch {
                await MainActor.run {
                    guard owner?.deviceGate.accepts(request) == true else { return }
                    owner?.client = nil
                    owner?.error = "Device status unavailable; reconnect before retrying: \(error.localizedDescription)"
                    owner?.attach()
                }
            }
        }
    }

    func loadDeviceSettings() {
        guard let client, let request = deviceGate.begin(.settings) else { return }
        let id = request.deviceId
        let startingDraftRevision = deviceSettingsDraftGate.revision
        Task.detached { [weak self] in
            let owner = self
            do {
                let snapshot = try client.deviceSettings(id)
                await MainActor.run {
                    guard owner?.deviceGate.accepts(request) == true else { return }
                    let changed = owner?.deviceSettingsDraftGate.requiresReplacementChoice(
                        since: startingDraftRevision) == true
                    let confirmed = changed && owner?.confirmReplaceDeviceSettings() == true
                    guard owner?.deviceSettingsDraftGate.acceptsReload(
                        since: startingDraftRevision, explicitlyConfirmed: confirmed) == true else {
                        owner?.notice = "Newer device settings edits retained; reload was not applied."
                        return
                    }
                    guard owner?.deviceGate.accepts(request) == true else { return }
                    owner?.deviceSettings = snapshot
                    owner?.draftDeviceName = snapshot.value.displayName ?? ""
                    owner?.draftBrightnessMode = snapshot.value.brightness.mode
                    owner?.draftBrightnessLevel = snapshot.value.brightness.fixedLevel
                    owner?.deviceSettingsDraftGate.markLoaded()
                    owner?.error = nil
                }
            } catch {
                await MainActor.run {
                    guard owner?.deviceGate.accepts(request) == true else { return }
                    owner?.client = nil
                    owner?.error = "Device settings unavailable; reconnect before retrying: \(error.localizedDescription)"
                    owner?.attach()
                }
            }
        }
    }

    private func confirmReplaceDeviceSettings() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace newer device settings edits?"
        alert.informativeText = "You changed these settings after the reload started. Keep your edits or explicitly replace them with the device response."
        alert.addButton(withTitle: "Keep Edits")
        alert.addButton(withTitle: "Replace with Device Settings")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func confirmDiscardDeviceSettings() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard unsaved device settings?"
        alert.informativeText = "Selecting another device will discard these unsaved settings edits."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Edits")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func saveDeviceSettings() {
        guard let client, let id = selectedDeviceId, let snapshot = deviceSettings,
              deviceDetail?.deviceId == id else { return }
        var changed = snapshot.value
        let name = draftDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        changed.displayName = name.isEmpty ? nil : name
        changed.brightness.mode = draftBrightnessMode
        changed.brightness.fixedLevel = draftBrightnessLevel
        do { try changed.validate() }
        catch { self.error = "Device settings are invalid: \(error.localizedDescription)"; return }
        let submittedDraftRevision = deviceSettingsDraftGate.revision
        guard let request = deviceGate.begin(.settings) else { return }
        Task.detached { [weak self] in
            let owner = self
            do {
                let updated = try client.updateDeviceSettings(id,
                    expectedRevision: snapshot.revision, value: changed)
                await MainActor.run {
                    guard owner?.deviceGate.accepts(request) == true else { return }
                    owner?.deviceSettings = updated
                    owner?.deviceSettingsDraftGate.markSaved(submittedRevision: submittedDraftRevision)
                    if owner?.deviceSettingsDraftGate.hasUnsavedEdits == true {
                        owner?.notice = "Submitted settings saved; newer edits remain unsaved."
                    } else {
                        owner?.notice = updated.isApplied
                            ? "Device settings saved and applied." : "Device settings saved; device application is pending."
                    }
                }
            } catch {
                await MainActor.run {
                    guard owner?.deviceGate.accepts(request) == true else { return }
                    owner?.client = nil
                    owner?.error = "Device settings may be stale or outcome unknown. Reconnect and reload before retrying."
                    owner?.attach()
                }
            }
        }
    }

    func loadDeviceInventory() {
        guard let client, let request = deviceGate.begin(.inventory) else { return }
        let id = request.deviceId
        Task.detached { [weak self] in
            let owner = self
            do {
                let inventory = try client.deviceConnections(id)
                await MainActor.run {
                    guard owner?.deviceGate.accepts(request) == true else { return }
                    owner?.deviceInventory = inventory
                    owner?.error = nil
                }
            } catch {
                await MainActor.run {
                    guard owner?.deviceGate.accepts(request) == true else { return }
                    owner?.client = nil
                    owner?.error = "Device inventory unavailable; reconnect before retrying: \(error.localizedDescription)"
                    owner?.attach()
                }
            }
        }
    }

    private func presentConnectionReview(_ completeScope: String) -> BrokerReviewDecision {
        let alert = NSAlert()
        alert.messageText = "Review complete connection scope"
        alert.informativeText = "Read to the end before approving. Deny resolves the intent; Leave Pending closes this review."
        alert.addButton(withTitle: "Approve Exact Scope")
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Leave Pending")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 400))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.contentView.postsBoundsChangedNotifications = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = completeScope
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            textView.frame.size.height = max(400, layout.usedRect(for: container).height + 24)
        }
        scroll.documentView = textView
        alert.accessoryView = scroll
        let approve = alert.buttons[0]
        approve.isEnabled = false
        let updateApproval: () -> Void = {
            let visible = scroll.contentView.documentVisibleRect
            approve.isEnabled = visible.maxY >= textView.bounds.maxY - 2
        }
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { _ in
                updateApproval()
            }
        updateApproval()
        let response = alert.runModal()
        NotificationCenter.default.removeObserver(observer)
        if response == .alertFirstButtonReturn && approve.isEnabled { return .approve }
        if response == .alertSecondButtonReturn { return .deny }
        return .leavePending
    }

    nonisolated private static func assertSelection(client: WorkbenchBrokerClient,
                                                     expected: WorkbenchWorkspaceStatus) throws {
        let current = try client.workspaceStatus()
        guard current.state == "selected", current.workspaceId == expected.workspaceId,
              current.selectionGeneration == expected.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
    }

    func beginPairing() {
        guard let client, !loading else { return }
        let alert = NSAlert()
        alert.messageText = "Pair a device"
        alert.informativeText = "Enter the device's advertised host and port. Compare the code shown here with the device before confirming."
        alert.addButton(withTitle: "Request Code")
        alert.addButton(withTitle: "Cancel")
        let fields = NSStackView(views: [NSTextField(string: ""), NSTextField(string: "")])
        fields.orientation = .vertical; fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        (fields.views[0] as? NSTextField)?.placeholderString = "Host"
        (fields.views[1] as? NSTextField)?.placeholderString = "Port"
        alert.accessoryView = fields
        guard alert.runModal() == .alertFirstButtonReturn,
              let hostField = fields.views[0] as? NSTextField,
              let portField = fields.views[1] as? NSTextField else { return }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portField.stringValue), (1...65535).contains(port), !host.isEmpty else {
            error = "Enter a host and port from 1 to 65535."
            return
        }
        loading = true
        Task.detached { [weak self] in
            let owner = self
            do {
                let request = try client.beginPairing(host: host, port: port)
                await MainActor.run { owner?.loading = false; owner?.pendingPairing = request; owner?.error = nil }
            } catch {
                await MainActor.run { owner?.loading = false; owner?.error = error.localizedDescription }
            }
        }
    }

    func confirmPairing() {
        guard let client, let request = pendingPairing, !loading else { return }
        loading = true
        Task.detached { [weak self] in
            let owner = self
            do {
                _ = try client.confirmPairing(pendingId: request.pendingId, matchingCode: request.matchingCode)
                await MainActor.run { owner?.pendingPairing = nil; owner?.loading = false; owner?.refresh() }
            } catch {
                await MainActor.run { owner?.loading = false; owner?.error = error.localizedDescription }
            }
        }
    }

    func cancelPairing() {
        guard let client, let request = pendingPairing, !loading else { return }
        loading = true
        Task.detached { [weak self] in
            let owner = self
            do {
                try client.cancelPairing(pendingId: request.pendingId)
                await MainActor.run { owner?.pendingPairing = nil; owner?.loading = false }
            } catch {
                await MainActor.run { owner?.loading = false; owner?.error = error.localizedDescription }
            }
        }
    }
}

private enum BrokerConsumerError: LocalizedError {
    case controllerHomeMismatch, previewRequired
    var errorDescription: String? {
        switch self {
        case .controllerHomeMismatch: "Broker controller home does not match this app's configured home."
        case .previewRequired: "preview_required"
        }
    }
}

private enum BrokerReviewDecision { case approve, deny, leavePending }

/// Reads only broker-verified, selection-bound chunks; never follows workspace paths.
enum WorkspacePackagePreviewLoader {
    private static let previewByteLimit = 4 * 1024 * 1024
    static func load(client: WorkbenchBrokerClient, selected: WorkbenchWorkspaceStatus,
                     summary: WorkbenchWorkspacePackageSummary) throws -> PackageAssetStore {
        let detail = try client.workspacePackage(dashboardId: summary.dashboardId,
                                                 revision: summary.revision, in: selected)
        guard detail == summary, summary.fileCount <= PackageLimits.maxFiles,
              summary.storage == "selected-workspace-history" else { throw BrokerConsumerError.previewRequired }
        let manifestBytes = try read(client: client, selected: selected, summary: summary,
                                     path: "", limit: 4 * 1024 * 1024)
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestBytes)
        guard manifest.dashboardId == summary.dashboardId, manifest.revision == summary.revision,
              manifest.digest == summary.digest, manifest.files.count == summary.fileCount,
              try DeploymentDigest.digest(for: manifest) == summary.digest else {
            throw BrokerConsumerError.previewRequired
        }
        try PackageValidator.validate(manifest)
        var assets = ["manifest.json": PackageAsset(path: "manifest.json", data: manifestBytes,
                                                       mime: "application/json")]
        var remaining = previewByteLimit - manifestBytes.count
        guard remaining >= 0 else { throw BrokerConsumerError.previewRequired }
        for file in manifest.files {
            guard file.bytes >= 0, file.bytes <= remaining, assets[file.path] == nil else {
                throw BrokerConsumerError.previewRequired
            }
            let bytes = try read(client: client, selected: selected, summary: summary,
                                 path: file.path, limit: file.bytes)
            guard bytes.count == file.bytes, DeploymentDigest.sha256Hex(bytes) == file.sha256 else {
                throw BrokerConsumerError.previewRequired
            }
            assets[file.path] = PackageAsset(path: file.path, data: bytes,
                                              mime: PackageAssetStore.mime(for: file.path))
            remaining -= bytes.count
        }
        return PackageAssetStore(assets: assets)
    }

    private static func read(client: WorkbenchBrokerClient, selected: WorkbenchWorkspaceStatus,
                             summary: WorkbenchWorkspacePackageSummary, path: String,
                             limit: Int) throws -> Data {
        var bytes = Data()
        var expectedSize: Int?
        var expectedHash: String?
        repeat {
            let chunk = try client.workspacePackageFile(dashboardId: summary.dashboardId,
                revision: summary.revision, path: path, offset: bytes.count, in: selected)
            guard chunk.totalBytes <= limit, chunk.totalBytes >= 0,
                  expectedSize == nil || expectedSize == chunk.totalBytes,
                  expectedHash == nil || expectedHash == chunk.sha256,
                  chunk.offset == bytes.count,
                  !chunk.bytes.isEmpty || bytes.count == chunk.totalBytes else {
                throw BrokerConsumerError.previewRequired
            }
            expectedSize = chunk.totalBytes; expectedHash = chunk.sha256
            bytes.append(chunk.bytes)
        } while bytes.count < (expectedSize ?? 0)
        guard DeploymentDigest.sha256Hex(bytes) == expectedHash else {
            throw BrokerConsumerError.previewRequired
        }
        return bytes
    }
}

struct BrokerWorkbenchView: View {
    @ObservedObject var model: BrokerWorkbench
    @State private var iconDashboardId: String?
    @State private var showingIconPicker = false
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedDashboard) {
                Section("Selected-workspace packages") {
                    ForEach(Array(model.packages.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 9) {
                            Image(systemName: model.screenSymbol(item.dashboardId)).frame(width: 20)
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text(item.revision).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .tag(BrokerWorkbench.packageKey(item))
                        .contextMenu {
                            Button("Rename Screen…") { model.renamePackage(item) }
                                .disabled(!model.canRenamePackage)
                            Button("Duplicate Screen…") { model.duplicatePackage(item) }
                                .disabled(!model.canDuplicatePackage)
                            Menu("Supported Orientations") {
                                ForEach(ScreenOrientationSupport.allCases, id: \.rawValue) { support in
                                    Button(support.rawValue.capitalized) {
                                        model.setPackageOrientation(item, support: support)
                                    }
                                }
                            }.disabled(!model.canSetPackageOrientation)
                            Button("Change Icon…") {
                                iconDashboardId = item.dashboardId
                                showingIconPicker = true
                            }.disabled(!model.canChangeScreenIcon)
                            Divider()
                            Button("Remove from Library…", role: .destructive) {
                                model.archivePackageScreen(item)
                            }.disabled(!model.canArchiveScreen)
                        }
                    }
                }
                Section("Projects") {
                    ForEach(model.projects, id: \.projectId) { item in
                        Button(item.name) { model.inspectProject(item.projectId) }.buttonStyle(.plain)
                    }
                }
                Section("Devices") {
                    ForEach(model.devices, id: \.deviceId) { item in
                        Button(item.name) { model.selectDevice(item.deviceId) }.buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 230)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.workspace?.path ?? "No workspace selected").font(.headline).lineLimit(1)
                    Spacer()
                    Text(model.guiLeaseStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Retry GUI Verification") { model.retryGUILease() }
                    Button("New Project…") { model.createProject() }
                    Button("Pair Device…") { model.beginPairing() }
                    Button("Review Connection…") { model.reviewConnectionIntent() }
                        .disabled(model.reviewInProgress)
                    Button("Open Workspace…") { model.openWorkspace() }
                    if MacGUIRuntime.isTestApp && model.workspace?.state != "selected" {
                        Button("Review Copied Library…") { model.planCopiedLibraryMigration() }
                            .disabled(model.copiedMigrationBusy)
                    }
                    Button("Refresh") { model.refresh() }
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                    Button("Reconnect") { model.attach() }
                }
                if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
                if model.editor.orphaned {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unsaved source draft retained").font(.headline)
                        Text("Workspace \(model.editor.originWorkspaceId) · project \(model.editor.originProjectId) · \(model.editor.originPath)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        TextEditor(text: $model.editor.draft)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100, maxHeight: 180)
                        Button("Discard Draft…") { model.discardSourceDraft() }
                    }.padding().background(.regularMaterial)
                }
                if let pairing = model.pendingPairing {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Compare pairing codes on both devices").font(.headline)
                        Text(pairing.deviceName + " · " + pairing.host + ":\(pairing.port)")
                        Text(pairing.matchingCode).font(.title.monospacedDigit())
                        Text("Device pin: " + pairing.devicePinHex).font(.caption.monospaced())
                        Text("Controller pin: " + pairing.controllerPinHex).font(.caption.monospaced())
                        HStack {
                            Button("Codes Match") { model.confirmPairing() }
                            Button("Cancel Pairing") { model.cancelPairing() }
                        }
                    }.padding().background(.regularMaterial)
                }
                if let deviceId = model.selectedDeviceId {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.deviceDetail?.deviceId == deviceId
                                 ? (model.deviceDetail?.name ?? deviceId) : deviceId).font(.headline)
                            Spacer()
                            Button("Refresh Device") { model.loadDeviceStatus(refresh: true) }
                            Button("Load Settings") { model.loadDeviceSettings() }
                            Button("Load Inventory") { model.loadDeviceInventory() }
                        }
                        if let device = model.deviceDetail, device.deviceId == deviceId {
                            Text("Reachability: \(device.reachability) · active revision: \(device.activeRevision ?? "none")")
                                .font(.caption)
                            Text(device.ownerMatchesCurrent ? "Owner identity matches" : "Owner identity differs")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let settings = model.deviceSettings {
                            Text("Settings revision: \(settings.revision)").font(.caption.monospaced())
                            if model.deviceSettingsHasUnsavedEdits {
                                Text("Unsaved settings edits").font(.caption).foregroundStyle(.orange)
                            }
                            TextField("Display name", text: $model.draftDeviceName)
                                .textFieldStyle(.roundedBorder)
                            Picker("Brightness", selection: $model.draftBrightnessMode) {
                                Text("System").tag(DeviceBrightnessMode.system)
                                Text("Fixed").tag(DeviceBrightnessMode.fixed)
                                Text("Schedule").tag(DeviceBrightnessMode.schedule)
                            }
                            if model.draftBrightnessMode == .fixed {
                                Slider(value: $model.draftBrightnessLevel, in: 0...1)
                            }
                            Button("Save Settings") { model.saveDeviceSettings() }
                                .disabled(model.deviceDetail?.deviceId != deviceId)
                            Text(settings.isApplied ? "Applied on device" : "Saved; device application pending")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let inventory = model.deviceInventory {
                            Text("Device connection inventory (\(inventory.entries.count))")
                                .font(.subheadline)
                            ForEach(inventory.entries) { entry in
                                VStack(alignment: .leading) {
                                    Text(entry.name + " · " + entry.kind)
                                    Text(entry.origin + " · " + entry.authentication +
                                         " · \(entry.operations.count) operations")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.padding().background(.regularMaterial)
                }
                if let project = model.selectedProject {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(project.project.name).font(.headline)
                            Spacer()
                            Button("Rename…") { model.renameSelectedSource() }
                                .disabled(!model.canRenameSource)
                            Button("Attach to Selected Screen") {
                                model.associateSelectedReactSource()
                            }.disabled(!model.canAssociateReactSource)
                            Button("Remove from Library…", role: .destructive) {
                                model.archiveSelectedSourceScreen()
                            }.disabled(!model.canArchiveScreen)
                            Button("Reload Project") { model.inspectProject(project.project.projectId) }
                            Button("Build") { model.buildSelectedProject() }
                        }
                        Text("Source version: " + project.sourceVersion).font(.caption.monospaced()).lineLimit(1)
                        HStack {
                            TextField("Included source path", text: $model.editor.requestedPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Load Source") { model.loadSource() }
                        }
                        if model.editor.loadedProjectId == project.project.projectId {
                            Text("Editing \(model.editor.loadedPath) · \(model.editor.draft.utf8.count)/2048 UTF-8 bytes")
                                .font(.caption.monospaced())
                            TextEditor(text: $model.editor.draft)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 120, maxHeight: 220)
                                .disabled(model.editor.requestedPath != model.editor.loadedPath)
                            HStack {
                                Button("Save Source") { model.saveSource() }
                                    .disabled(!model.editor.canSave)
                                if model.editor.conflict {
                                    Text("Draft retained after conflict. Reload only when ready to replace it.")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        if let build = model.projectBuild {
                            Text("Build revision: " + build.revision).font(.caption.monospaced())
                            Text(build.diagnostics).font(.caption).lineLimit(3)
                        }
                        Text("Source versions: \(model.sourceVersions.count) · workspace package history: \(model.packageHistory.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding().background(.regularMaterial)
                }
                Text(MacGUIRuntime.isTestApp
                     ? "Source edits use broker version checks. Use Device Preview & Apply for reviewed deployment against the isolated service."
                     : "Source edits use a broker read and expected source version. Deployment and live connections await compatible native routes.")
                    .font(.caption).foregroundStyle(.secondary)
                if let preview = model.preview {
                    DashboardWebView(store: preview, revision: model.previewRevision, serviceInvocation: model.cloudServiceInvocation, onUnlinkHold: {})
                        .id(model.previewRevision)
                } else {
                    ContentUnavailableView("Select a Screen", systemImage: "rectangle.on.rectangle",
                                           description: Text("A verified local package opens in the native preview."))
                }
            }.padding()
        }
        .task { model.attach() }
        .onDisappear { model.detach() }
        .onChange(of: model.selectedDashboard) { _, value in if let value { model.select(value) } }
        .sheet(isPresented: $showingIconPicker) {
            SymbolPickerSheet(initialSymbol: iconDashboardId.map(model.screenSymbol) ?? "star",
                onSave: { symbol in
                    if let iconDashboardId {
                        model.changeScreenIcon(dashboardId: iconDashboardId, symbol: symbol)
                    }
                    showingIconPicker = false
                }, onCancel: { showingIconPicker = false })
        }
        .sheet(isPresented: Binding(get: { model.copiedMigrationPlan != nil },
                                    set: { if !$0 { model.dismissCopiedMigrationPlan() } })) {
            if let plan = model.copiedMigrationPlan {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Copied package library recovery").font(.title2.weight(.semibold))
                    Text("Source: \(plan.sourcePath)").font(.caption.monospaced()).textSelection(.enabled)
                    if let destination = plan.destinationPath {
                        Text("Destination: \(destination)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("\(plan.packageRevisions.count) retained package revisions · \(plan.projectIds.count) registered projects · \(plan.plannedMembers) copied members")
                    Text("Editable personal source stays in its separate verified archive and needs later import or adoption. Device records, grants, and local authority are excluded.")
                        .foregroundStyle(.secondary)
                    if !plan.unsupportedPortablePaths.isEmpty {
                        Text("Unsupported entries prevent recovery:").font(.headline)
                        ScrollView {
                            Text(plan.unsupportedPortablePaths.joined(separator: "\n"))
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 140)
                    }
                    if !plan.excludedClasses.isEmpty {
                        Text("Excluded machine state: " + plan.excludedClasses.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Close") { model.dismissCopiedMigrationPlan() }
                        Button("Recover Copy…") { model.applyCopiedLibraryMigration() }
                            .disabled(!plan.applyAvailable || model.copiedMigrationBusy)
                    }
                }.padding(20).frame(minWidth: 620)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            model.refresh(); model.retryGUILease()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.detach()
        }
    }
}
