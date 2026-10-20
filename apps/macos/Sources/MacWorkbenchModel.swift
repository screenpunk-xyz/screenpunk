import AppKit
import SwiftUI
import ScreenpunkCore
import ScreenpunkApple
import ScreenpunkController

struct ScreenDraft: Codable, Identifiable {
    var id = UUID().uuidString
    var dashboardId: String?
    var baseRevision: String?
    var name = "New Screen"
    var symbol = "star"
    var files: [String: Data] = [:]
    var target: ManifestTarget
    var connections: [ManifestConnection] = []
}

enum WorkbenchSheet: String, Identifiable { case manual, editor, agents, homeAssistant, googleTV, rename, renameScreen, screenIcon, deviceSettings, deviceConnections; var id: String { rawValue } }

@MainActor
final class MacWorkbenchModel: ObservableObject {
    @Published var section = "Devices"
    @Published var selection: String?
    @Published var devices: [PairedDeviceRecord] = []
    @Published var nearby: [WorkbenchSidebar.NearbyEntry] = []
    @Published var screens: [DashboardSummary] = []
    @Published var agents: [AgentPresence] = []
    @Published var selectedScreen: String?
    @Published private(set) var deviceScreens = DeviceScreenSelection()
    private var screenSelections: [String: DeviceScreenSelection] = [:]
    private var appliedSetSources: [String: [String: String]] = [:]
    private let previewThumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24; cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var thumbnailRequests: [String: Task<NSImage?, Never>] = [:]
    private let thumbnailQueue = DispatchQueue(label: "xyz.screenpunk.thumbnail", qos: .utility)
    private var previewRequest = UUID()
    private var brokerDeviceRequest = UUID()
    @Published var isReactProject = false
    @Published var preview: PackageAssetStore?
    @Published var previewKey = UUID()
    @Published var screenPreviewProfile: ScreenPreviewProfile = .defaultProfile {
        didSet { UserDefaults.standard.set(screenPreviewProfile.id, forKey: "screenPreviewProfile") }
    }
    @Published var orientation: DeviceOrientation = .portrait
    @Published var pairing: PairingRequestResult?
    /// The person compared the code on this Mac with the device and pressed
    /// Codes Match. Only then does the Mac send `pair.confirm`; a device that
    /// self-confirms cannot pair itself to this Mac.
    @Published private(set) var pairingConfirmedOnMac = false
    /// A reachability probe of saved devices is running on the workbench queue.
    @Published private(set) var checkingDevices = false
    @Published private(set) var manuallyRefreshingDevices = false
    /// At least one probe has finished since launch. Until then the saved
    /// `reachable` flag is last session's answer, not this network's.
    @Published private(set) var devicesChecked = false
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var controllerBlockedReason: String?
    @Published private(set) var compatibleBrokerAvailable = false
    @Published private(set) var brokerMode = false
    @Published private(set) var brokerWorkspace: WorkbenchWorkspaceStatus?
    @Published private(set) var brokerPackages: [WorkbenchWorkspacePackageSummary] = []
    @Published private(set) var brokerDevices: [WorkbenchDeviceRead] = []
    @Published private(set) var brokerPendingPairing: WorkbenchPairingRead?
    @Published private(set) var brokerDeviceStates: [String: String] = [:]
    @Published private(set) var brokerDeviceMessage: String?
    @Published private(set) var brokerScreenSet: WorkbenchDeviceScreenSetRead?
    @Published private(set) var brokerDraftScreens: [LANScreenSetEntry] = []
    @Published private(set) var brokerMultipleScreens = false
    private var brokerDrafts: [String: (screens: [LANScreenSetEntry], multiple: Bool, baseline: String)] = [:]
    @Published private(set) var brokerSelectedPackage: WorkbenchWorkspacePackageSummary?
    @Published private(set) var brokerPreviewManifest: DashboardManifest?
    @Published private(set) var brokerApplyVerified = false
    @Published private(set) var brokerApplyState = "Apply unavailable until GUI verification"
    @Published private(set) var brokerApplyRecord: MacBrokerApplyJournal.Record?
    @Published var sheet: WorkbenchSheet?
    @Published var connectionsDeviceID: String?
    @Published var settingsEditor: MacDeviceSettingsModel?
    @Published var draft: ScreenDraft?
    @Published var symbols: [String: String] = [:]
    private(set) var service: ControllerService?
    private var legacyLease: LegacyControllerLease?
    private var brokerClient: WorkbenchBrokerClient?
    var cloudServiceInvocation: CloudScreenServiceInvocation {
        CloudControllerIntegration.previewInvocation(dashboardId: previewDashboardId,
            client: { [weak self] in self?.brokerClient },
            currentDashboard: { [weak self] in self?.previewDashboardId ?? "" })
    }
    private var brokerEnvironment: WorkbenchBrokerEnvironment?
    var brokerConnectionEnvironment: WorkbenchBrokerEnvironment? {
        brokerMode ? brokerEnvironment : nil
    }
    private let transport = LANTransport()
    private let queue = DispatchQueue(label: "xyz.screenpunk.workbench", qos: .userInitiated)
    private var timer: Timer?
    private var pairingTimer: Timer?
    private var pairingPollInFlight = false
    private var brokerPreviewTask: Task<Void, Never>?
    private var refreshing = false
    private var pendingProbe = false
    private var pendingManualProbe = false
    private var ticks = 0
    private var appliedScreens: [String: String] = [:]
    private var appliedOrientations: [String: String] = [:]
    private var previewIsApplied = false
    private var record: DashboardRevisionRecord?
    private var appliedSourceRevisions: [String: String] = [:]
    private var appliedPackagePaths: [String: String] = [:]
    private var root: URL { DashboardPackageStore.defaultRoot() }
    private var draftURL: URL { root.appendingPathComponent("workbench-draft.json") }

    var previewDashboardId: String { brokerMode ? brokerPreviewManifest?.dashboardId ?? "" : record?.manifest.dashboardId ?? "" }
    var previewRevision: String { brokerMode ? brokerPreviewManifest?.revision ?? "" : record?.manifest.revision ?? "" }
    var previewManifest: DashboardManifest? { brokerMode ? brokerPreviewManifest : record?.manifest }
    var previewUsesHomeAssistant: Bool { previewManifest?.connections.contains { $0.alias == "home" } ?? false }
    var device: PairedDeviceRecord? { devices.first { $0.id == selection } }
    var detected: WorkbenchSidebar.NearbyEntry? { nearby.first { $0.id == selection } }
    var screenName: String {
        brokerMode ? brokerSelectedPackage?.name ?? "Choose Screen" :
            screens.first { $0.dashboardId == selectedScreen }?.name ?? record?.manifest.name ?? "Choose Screen"
    }
    var title: String {
        if brokerMode {
            return section == "Screens" ? brokerSelectedPackage?.name ?? "Screens" :
                brokerDevices.first(where: { $0.deviceId == selection })?.name ?? "Devices"
        }
        if section == "Screens" { return screens.first { $0.dashboardId == selection }?.name ?? "Screens" }
        if let device { return DeviceDisplayName.label(name: device.displayName ?? device.device.profile.name, deviceId: device.id, fallback: "Paired device") }
        return detected?.title ?? "Devices"
    }
    var previewSize: CGSize {
        if brokerMode {
            let target = brokerPreviewManifest?.target
            let profile = section == "Devices" ? brokerScreenSet?.profile : nil
            let width = profile?.width ?? target?.width ?? screenPreviewProfile.width
            let height = profile?.height ?? target?.height ?? screenPreviewProfile.height
            return orientation == .portrait ? CGSize(width: min(width,height), height: max(width,height)) :
                CGSize(width: max(width,height), height: min(width,height))
        }
        let width = section == "Screens" ? screenPreviewProfile.width : device?.device.profile.width ?? record?.manifest.target.width ?? 390
        let height = section == "Screens" ? screenPreviewProfile.height : device?.device.profile.height ?? record?.manifest.target.height ?? 844
        return orientation == .portrait ? CGSize(width: min(width,height), height: max(width,height)) : CGSize(width: max(width,height), height: min(width,height))
    }
    var screenSupport: ScreenOrientationSupport {
        if brokerMode {
            return brokerPreviewManifest?.target.orientation == "landscape" ? .landscape : .portrait
        }
        return (try? record.map { try ScreenDesignSettings.read(files: $0.files).orientations }) ?? .both
    }
    func supports(_ orientation: DeviceOrientation) -> Bool { screenSupport.allows(orientation) }
    var canDuplicate: Bool { record != nil }
    var screenSelectorTitle: String { deviceScreens.multiple ? "\(deviceScreens.ids.count) \(deviceScreens.ids.count == 1 ? "Screen" : "Screens")" : screenName }
    var applyLabel: String { brokerMode ? (brokerDraftScreens.count > 1 ? "Apply Screens" : "Apply Screen") : deviceScreens.ids.count > 1 ? "Apply Screens" : "Apply Screen" }
    var canApply: Bool {
        if brokerMode {
            return MacBrokerApplyButtonGate.allows(verifiedGUI: brokerApplyVerified,
                busy: busy, selectedDeviceMatches: brokerScreenSet?.deviceId == selection,
                hasExactOfflinePackage: !brokerDraftScreens.isEmpty && brokerDraftScreens.count <= 12 && brokerSelectedPackage != nil &&
                    brokerPreviewManifest?.connections.isEmpty == true &&
                    brokerPreviewManifest?.target.orientation == orientation.rawValue,
                prior: brokerApplyRecord)
        }
        return device != nil && !deviceScreens.ids.isEmpty &&
            deviceScreens.ids.allSatisfy { id in screens.contains { $0.dashboardId == id } } && !busy
    }
    var canRollbackBrokerApply: Bool {
        guard brokerMode, brokerApplyVerified, !busy,
              let selected = brokerWorkspace, let record = brokerApplyRecord,
              record.phase == .active, record.operationId != nil,
              record.workspaceId == selected.workspaceId,
              record.selectionGeneration == selected.selectionGeneration,
              record.deviceId == selection,
              brokerScreenSet?.deviceId == record.deviceId else { return false }
        return true
    }
    var hasUnappliedScreen: Bool {
        guard let device else { return false }
        let installed = device.screenSet?.map(\.dashboardId) ?? appliedScreens[device.id].map { [$0] } ?? []
        if deviceScreens.ids != installed { return true }
        if orientation != device.device.profile.orientation { return true }
        if let sources = appliedSetSources[device.id] {
            return deviceScreens.ids.contains { id in
                guard let screen = screens.first(where: { $0.dashboardId == id }), let source = sources[id] else { return false }
                return source != screen.draftRevision
            }
        }
        if previewIsApplied { return false }
        return record != nil && appliedSourceRevisions[device.id] != record?.manifest.revision
    }
    private func rememberScreenSelection() {
        guard section == "Devices", let device else { return }
        screenSelections[device.id] = deviceScreens
    }
    func setMultipleScreens(_ enabled: Bool) {
        deviceScreens.setMultiple(enabled, preferred: selectedScreen)
        rememberScreenSelection()
        if let id = deviceScreens.ids.first, !deviceScreens.ids.contains(selectedScreen ?? "") { focusScreen(id) }
    }
    private func installedSelection(_ device: PairedDeviceRecord) -> DeviceScreenSelection {
        let ids = device.screenSet?.map(\.dashboardId) ?? selectedScreen.map { [$0] } ?? []
        return DeviceScreenSelection(ids: ids, multiple: ids.count > 1)
    }
    func symbol(for id: String) -> String { symbols[id] ?? "star" }
    func deviceStatus(_ device: PairedDeviceRecord) -> String {
        guard devicesChecked else { return "Checking…" }
        return device.device.reachable ? "Connected" : "Offline"
    }
    func deviceSymbol(_ name: String, landscape: Bool = false) -> String {
        name.localizedCaseInsensitiveContains("ipad") ? (landscape ? "ipad.landscape" : "ipad") : (landscape ? "iphone.gen3.landscape" : "iphone.gen3")
    }

    func start() {
        guard timer == nil, !brokerMode else { return }
        do {
            let lease = try LegacyControllerLease(home: DashboardPackageStore.defaultRoot())
            service = try ControllerService.bootstrap()
            legacyLease = lease
            if let service { let status = transport.attach(to: service); if !service.devices.transportAvailable { error = status } }
            appliedSetSources = UserDefaults.standard.dictionary(forKey: "appliedSetSources") as? [String: [String: String]] ?? [:]
            symbols = UserDefaults.standard.dictionary(forKey: "screenSymbols") as? [String:String] ?? [:]
            appliedSourceRevisions = UserDefaults.standard.dictionary(forKey: "appliedSourceRevisions") as? [String:String] ?? [:]
            appliedPackagePaths = UserDefaults.standard.dictionary(forKey: "appliedPackagePaths") as? [String:String] ?? [:]
            appliedScreens = UserDefaults.standard.dictionary(forKey: "appliedScreens") as? [String:String] ?? [:]
            appliedOrientations = UserDefaults.standard.dictionary(forKey: "appliedOrientations") as? [String:String] ?? [:]
            if let saved = UserDefaults.standard.string(forKey: "screenPreviewProfile"), let profile = ScreenPreviewProfile.all.first(where: { $0.id == saved }) { screenPreviewProfile = profile }
            draft = try? JSONDecoder().decode(ScreenDraft.self, from: Data(contentsOf: draftURL))
            // Populate the workbench from disk before discovery or offline-device
            // timeouts. Selecting now also queues the saved preview ahead of probes.
            if let service {
                devices = service.devices.listDevices()
                screens = (try? service.listDashboards()) ?? []
                agents = AgentPresence.active(in: service.store.root)
                if selection == nil {
                    select(section == "Devices" ? devices.first?.id : screens.first?.dashboardId)
                }
            }
            refresh(probe: true)
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; self.ticks += 1; self.refresh(probe: self.ticks % 5 == 0, periodic: true) }
            }
        } catch {
            if case LegacyControllerLeaseError.brokerActive = error {
                controllerBlockedReason = error.localizedDescription
                probeCompatibleBroker(homePath: root.resolvingSymlinksInPath().path)
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    /// The separately identified GUI test app only connects to its isolated
    /// broker. It must never fall through to the legacy controller bootstrap.
    func startBrokerOnly() {
        guard !brokerMode, !busy, MacGUIRuntime.isolatedTestPaths != nil else { return }
        controllerBlockedReason = "Waiting for the isolated Screenpunk service."
        probeCompatibleBroker(homePath: root.resolvingSymlinksInPath().path)
    }

    /// A lock holder is not proof that it is the compatible broker. Only an
    /// authenticated hello for this exact controller home enables the opt-in
    /// limited service preview; it never starts another controller.
    private func probeCompatibleBroker(homePath: String) {
        Task.detached { [weak self] in
            let available: Bool
            do {
                let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: MacGUIRuntime.runtimeDirectory)
                let client = WorkbenchBrokerClient(environment: environment, reconnectClosedConnections: true)
                try client.connect()
                defer { client.close() }
                available = try client.hello().controllerHomePath == homePath
            } catch { available = false }
            await MainActor.run {
                guard let self else { return }
                self.compatibleBrokerAvailable = available
                if available, self.controllerBlockedReason != nil {
                    self.activateCompatibleBroker()
                }
            }
        }
    }

    func activateCompatibleBroker() {
        guard compatibleBrokerAvailable, !brokerMode, !busy else { return }
        busy = true
        Task.detached { [weak self] in
            let client: WorkbenchBrokerClient
            let environment: WorkbenchBrokerEnvironment
            do {
                environment = try WorkbenchBrokerEnvironment(runtimeDirectory: MacGUIRuntime.runtimeDirectory)
                client = WorkbenchBrokerClient(environment: environment, reconnectClosedConnections: true)
                try client.connect()
                let expectedHome = DashboardPackageStore.defaultRoot().resolvingSymlinksInPath().path
                guard try client.hello().controllerHomePath == expectedHome else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                let selected = try client.workspaceStatus()
                let packages = selected.state == "selected"
                    ? try client.listWorkspacePackages(in: selected) : []
                let devices = try client.listDevices()
                let previousApply = try Self.applyJournal().load()
                var verified = false
                if let session = try? MacBrokerApplySession.open(environment: environment,
                    expectedControllerHome: expectedHome) {
                    verified = true
                    await session.close()
                }
                await MainActor.run {
                    guard let self else { client.close(); return }
                    self.brokerClient = client; self.brokerEnvironment = environment
                    self.brokerWorkspace = selected; self.brokerPackages = packages
                    self.brokerDevices = devices; self.brokerApplyVerified = verified
                    self.brokerApplyRecord = previousApply
                    self.brokerApplyState = previousApply.map {
                        $0.operationId == nil && $0.blocksNewApply
                            ? "Previous Apply outcome unresolved without an operation ID; use service recovery before another Apply."
                            : "Previous Apply \($0.phase.rawValue); inspect its durable status before another Apply."
                    } ?? (verified ? "Verified GUI Apply available" :
                        "GUI verification unavailable; Apply disabled")
                    self.brokerMode = true; self.controllerBlockedReason = nil
                    self.busy = false; self.error = nil
                    self.section = devices.isEmpty ? "Screens" : "Devices"
                    if let first = devices.first { self.selectBrokerDevice(first.deviceId) }
                    else if let first = packages.first { self.selectBrokerPackage(first) }
                }
            } catch {
                await MainActor.run {
                    self?.busy = false
                    self?.error = "Compatible service unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    func detachCompatibleBroker() {
        brokerPreviewTask?.cancel(); previewRequest = UUID(); brokerDeviceRequest = UUID()
        brokerClient?.close(); brokerClient = nil
        brokerMode = false; brokerWorkspace = nil
        brokerPackages = []; brokerDevices = []; brokerScreenSet = nil
        brokerDraftScreens = []; brokerDrafts = [:]
        brokerSelectedPackage = nil; brokerPreviewManifest = nil
        brokerApplyVerified = false
        brokerApplyRecord = nil
    }

    nonisolated private static func applyJournal() -> MacBrokerApplyJournal {
        return MacBrokerApplyJournal(url: MacGUIRuntime.guiStateDirectory
            .appendingPathComponent("apply-attempt.json"))
    }

    func recoverExistingScreens() {
        guard brokerMode, !busy, brokerWorkspace?.state == "unconfigured" else { return }
        busy = true
        notice = "Copying and verifying existing screens. Originals and settings are retained."
        Task.detached { [weak self] in
            do {
                let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: MacGUIRuntime.runtimeDirectory)
                let client = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview)
                try client.connect(); defer { client.close() }
                let source = DashboardPackageStore.defaultRoot().resolvingSymlinksInPath().path
                guard try client.hello().controllerHomePath == source else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                let documents = try SystemWorkspaceDocumentsResolver().documentsDirectory()
                let destination = documents.appendingPathComponent("Screenpunk Workspace", isDirectory: true).path
                _ = try WorkbenchLegacyWorkspaceRecovery.recover(client: client,
                    source: source, destination: destination)
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.notice = "Existing screens restored. The original library and settings are retained."
                    // Recheck the GUI session against the newly selected workspace.
                    self.detachCompatibleBroker()
                    self.activateCompatibleBroker()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.notice = nil
                    self.error = "Screen recovery could not finish. Originals were retained. Refresh before retrying. \(error.localizedDescription)"
                    self.refreshCompatibleBroker()
                }
            }
        }
    }

    private func refreshCompatibleBroker() {
        guard let environment = brokerEnvironment, !refreshing, !busy else { return }
        refreshing = true
        let needsVerification = !brokerApplyVerified
        Task.detached { [weak self] in
            do {
                // Reauthenticate a closed idle socket before sending a new request.
                // Never replay a request whose outcome may already be committed.
                let client = try Self.openBrokerReadClient(environment)
                defer { client.close() }
                let selected = try client.workspaceStatus()
                let packages = selected.state == "selected"
                    ? try client.listWorkspacePackages(in: selected) : []
                let devices = try client.listDevices()
                var verified = false
                if needsVerification, let session = try? MacBrokerApplySession.open(environment: environment,
                    expectedControllerHome: DashboardPackageStore.defaultRoot().resolvingSymlinksInPath().path) {
                    verified = true
                    await session.close()
                }
                await MainActor.run {
                    guard let self else { return }
                    let switched = self.brokerWorkspace?.workspaceId != selected.workspaceId ||
                        self.brokerWorkspace?.selectionGeneration != selected.selectionGeneration
                    self.refreshing = false
                    if verified {
                        self.brokerApplyVerified = true
                        if self.brokerApplyState == "Service connection unavailable; Apply disabled" {
                            self.brokerApplyState = "Verified GUI Apply available"
                        }
                    }
                    self.brokerWorkspace = selected; self.brokerPackages = packages
                    self.brokerDevices = devices
                    if switched {
                        self.previewRequest = UUID(); self.preview = nil
                        self.brokerDeviceRequest = UUID()
                        self.brokerPreviewManifest = nil; self.brokerSelectedPackage = nil
                        self.brokerScreenSet = nil; self.selection = nil; self.selectedScreen = nil
                        self.brokerDraftScreens = []; self.brokerDrafts = [:]
                        self.notice = "Workspace selection changed; choose a screen and device again."
                    } else {
                        if let package = self.brokerSelectedPackage,
                           !packages.contains(package),
                           self.brokerScreenSet?.screens.contains(where: {
                               $0.dashboardId == package.dashboardId && $0.revision == package.revision
                           }) != true {
                            self.previewRequest = UUID(); self.preview = nil
                            self.brokerPreviewManifest = nil; self.brokerSelectedPackage = nil
                            self.selectedScreen = nil
                        }
                        if let deviceId = self.brokerScreenSet?.deviceId,
                           !devices.contains(where: { $0.deviceId == deviceId }) {
                            self.brokerDeviceRequest = UUID(); self.brokerScreenSet = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.refreshing = false
                    self?.brokerApplyVerified = false
                    self?.brokerApplyState = "Service connection unavailable; Apply disabled"
                    self?.error = error.localizedDescription
                }
            }
        }
    }

    /// Each UI read workflow owns its connection so a slow/offline device cannot
    /// invalidate the socket used by preview or refresh. No failed mutation is replayed.
    nonisolated private static func openBrokerReadClient(_ environment: WorkbenchBrokerEnvironment) throws -> WorkbenchBrokerClient {
        let readEnvironment = try WorkbenchBrokerEnvironment(runtimeDirectory: environment.runtimeDirectory,
                                                              limits: .init(timeout: 45))
        let client = WorkbenchBrokerClient(environment: readEnvironment, reconnectClosedConnections: true)
        try client.connect()
        do {
            guard try client.hello().controllerHomePath == DashboardPackageStore.defaultRoot().resolvingSymlinksInPath().path else {
                throw MacBrokerApplyWorkflow.Failure.staleSelection
            }
            return client
        } catch { client.close(); throw error }
    }

    func brokerDeviceSubtitle(_ device: WorkbenchDeviceRead) -> String {
        brokerDeviceStates[device.deviceId] ?? (device.cachedReachability == "reachable" ? "Last seen online · select to connect" : "Select to connect")
    }

    func selectBrokerDevice(_ id: String) {
        guard brokerMode, let environment = brokerEnvironment, let selected = brokerWorkspace,
              brokerDevices.contains(where: { $0.deviceId == id }) else { return }
        if selection == id, brokerDeviceStates[id] == "Connecting…" { return }
        if let previous = selection, brokerDeviceStates[previous] == "Connecting…" {
            brokerDeviceStates[previous] = nil
        }
        brokerPreviewTask?.cancel()
        section = "Devices"; selection = id; brokerScreenSet = nil; brokerDraftScreens = []
        brokerDeviceStates[id] = "Connecting…"; brokerDeviceMessage = nil
        previewRequest = UUID(); preview = nil; brokerSelectedPackage = nil; brokerPreviewManifest = nil
        notice = nil; error = nil
        let request = UUID(); brokerDeviceRequest = request
        Task.detached { [weak self] in
            do {
                // Reauthenticate a closed idle socket before sending a new request.
                // Never replay a request whose outcome may already be committed.
                let client = try Self.openBrokerReadClient(environment)
                defer { client.close() }
                let observed = try client.freshDeviceScreenSet(deviceId: id)
                let current = try client.workspaceStatus()
                guard current.workspaceId == selected.workspaceId,
                      current.selectionGeneration == selected.selectionGeneration else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                await MainActor.run {
                    guard let self, self.brokerMode, self.selection == id,
                          self.brokerDeviceRequest == request, observed.deviceId == id,
                          self.brokerWorkspace?.workspaceId == selected.workspaceId,
                          self.brokerWorkspace?.selectionGeneration == selected.selectionGeneration else { return }
                    self.brokerScreenSet = observed
                    if let draft = self.brokerDrafts[id], draft.baseline == observed.installedSetHash {
                        self.brokerDraftScreens = draft.screens; self.brokerMultipleScreens = draft.multiple
                    } else {
                        self.brokerDraftScreens = observed.screens
                        self.brokerMultipleScreens = observed.screens.count > 1
                    }
                    self.brokerDeviceStates[id] = "Connected"
                    self.orientation = observed.profile.orientation
                    if let active = self.brokerDraftScreens.first(where: { $0.dashboardId == observed.selectedDashboardId }) ?? self.brokerDraftScreens.first {
                        self.selectBrokerInstalledScreen(active.dashboardId, revision: active.revision)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.brokerMode, self.selection == id,
                          self.brokerDeviceRequest == request else { return }
                    self.brokerDeviceStates[id] = "Unavailable"
                    self.brokerDeviceMessage = "Could not read this device. Keep Screenpunk open on it and check that it is on the same network, then try again."
                }
            }
        }
    }

    func selectBrokerInstalledScreen(_ dashboardId: String, revision: String) {
        guard let environment = brokerEnvironment, let selected = brokerWorkspace,
              let observed = brokerScreenSet,
              (observed.screens + brokerDraftScreens).contains(where: { $0.dashboardId == dashboardId && $0.revision == revision }) else { return }
        let deviceRequest = brokerDeviceRequest
        let packageRequest = UUID(); previewRequest = packageRequest
        selectedScreen = dashboardId; preview = nil; brokerPreviewManifest = nil; brokerSelectedPackage = nil; notice = nil
        brokerPreviewTask?.cancel()
        brokerPreviewTask = Task.detached { [weak self] in
            do {
                let client = try Self.openBrokerReadClient(environment); defer { client.close() }
                let package = try client.workspacePackage(dashboardId: dashboardId, revision: revision, in: selected)
                await MainActor.run {
                    guard let self, self.brokerDeviceRequest == deviceRequest, self.previewRequest == packageRequest,
                          self.section == "Devices", self.selection == observed.deviceId else { return }
                    self.selectBrokerPackage(package)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.brokerDeviceRequest == deviceRequest, self.previewRequest == packageRequest,
                          self.section == "Devices", self.selection == observed.deviceId else { return }
                    self.notice = "Device screens loaded. This installed revision has no available local preview."
                }
            }
        }
    }

    func archiveBrokerPackage(_ package: WorkbenchWorkspacePackageSummary) {
        guard brokerMode, !busy, let environment = brokerEnvironment,
              let selected = brokerWorkspace, let workspaceId = selected.workspaceId,
              let selectionGeneration = selected.selectionGeneration,
              brokerPackages.contains(package) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(package.name) from the Library?"
        alert.informativeText = "Its source and package history remain available for recovery. Installed copies on devices remain unchanged."
        alert.addButton(withTitle: "Remove from Library")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task { [weak self] in
            do {
                let receipt = try await Task.detached {
                    let client = try Self.openBrokerReadClient(environment)
                    defer { client.close() }
                    let current = try client.workspaceStatus()
                    guard current.workspaceId == workspaceId,
                          current.selectionGeneration == selectionGeneration,
                          let generation = current.generation else {
                        throw MacBrokerApplyWorkflow.Failure.staleSelection
                    }
                    let request = try WorkbenchScreenArchiveRequest.parse([
                        "schemaVersion": 1, "expectedWorkspaceId": workspaceId,
                        "expectedSelectionGeneration": selectionGeneration,
                        "expectedCatalogGeneration": generation,
                        "dashboardId": package.dashboardId,
                        "expectedRevision": package.revision,
                        "expectedDigest": package.digest])
                    // Never replay a mutation after an uncertain connection failure.
                    return try client.archiveScreen(request)
                }.value
                guard let self else { return }
                self.busy = false
                if self.brokerWorkspace?.workspaceId == workspaceId,
                   self.brokerWorkspace?.selectionGeneration == selectionGeneration,
                   receipt.workspaceId == workspaceId,
                   receipt.selectionGeneration == selectionGeneration,
                   receipt.dashboardId == package.dashboardId,
                   receipt.packageHistoryRetained, receipt.deviceContentsUntouched {
                    self.brokerPackages.removeAll { $0.dashboardId == package.dashboardId }
                    if self.section == "Screens", self.brokerSelectedPackage?.dashboardId == package.dashboardId {
                        self.brokerPreviewTask?.cancel(); self.previewRequest = UUID()
                        self.preview = nil; self.brokerPreviewManifest = nil
                        self.brokerSelectedPackage = nil; self.selectedScreen = nil
                    }
                    self.notice = "Screen removed from the Library. Source and history are retained."
                }
                self.refreshCompatibleBroker()
            } catch {
                guard let self else { return }
                self.busy = false
                self.error = "Removal may have completed. Refresh the Library before trying again."
                self.refreshCompatibleBroker()
            }
        }
    }

    func selectBrokerPackage(_ package: WorkbenchWorkspacePackageSummary) {
        guard brokerMode, let environment = brokerEnvironment, let selected = brokerWorkspace,
              (brokerPackages.contains(package) || brokerScreenSet?.screens.contains(where: {
                  $0.dashboardId == package.dashboardId && $0.revision == package.revision
              }) == true || brokerDraftScreens.contains(where: {
                  $0.dashboardId == package.dashboardId && $0.revision == package.revision
              })) else { return }
        brokerSelectedPackage = package; selectedScreen = package.dashboardId
        if section == "Screens" { selection = package.dashboardId + ":" + package.revision }
        let request = UUID(); previewRequest = request
        preview = nil; brokerPreviewManifest = nil; notice = nil
        brokerPreviewTask?.cancel()
        brokerPreviewTask = Task.detached { [weak self] in
            do {
                // Reauthenticate a closed idle socket before sending a new request.
                // Never replay a request whose outcome may already be committed.
                let client = try Self.openBrokerReadClient(environment)
                defer { client.close() }
                let assets = try WorkspacePackagePreviewLoader.load(client: client,
                    selected: selected, summary: package)
                guard let manifestBytes = assets.assets["manifest.json"]?.data else {
                    throw MacBrokerApplyWorkflow.Failure.noPackages
                }
                let manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestBytes)
                let current = try client.workspaceStatus()
                guard current.workspaceId == selected.workspaceId,
                      current.selectionGeneration == selected.selectionGeneration else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                await MainActor.run {
                    guard let self, self.brokerMode, self.previewRequest == request,
                          self.brokerSelectedPackage == package,
                          self.brokerWorkspace?.workspaceId == selected.workspaceId,
                          self.brokerWorkspace?.selectionGeneration == selected.selectionGeneration else { return }
                    self.brokerPreviewManifest = manifest
                    if self.section == "Screens",
                       let packageOrientation = DeviceOrientation(rawValue: manifest.target.orientation) {
                        self.orientation = packageOrientation
                    }
                    // Rendering a verified package does not grant provider access.
                    // The canvas reuses existing native credentials and exact approvals.
                    self.preview = assets; self.previewKey = UUID()
                }
            } catch {
                await MainActor.run {
                    guard self?.previewRequest == request else { return }
                    self?.notice = "Verified package preview unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    func revealBrokerSource() {
        guard brokerMode, let environment = brokerEnvironment, let selected = brokerWorkspace,
              let package = brokerSelectedPackage else { return }
        Task.detached { [weak self] in
            do {
                // Reauthenticate a closed idle socket before sending a new request.
                // Never replay a request whose outcome may already be committed.
                let client = try Self.openBrokerReadClient(environment)
                defer { client.close() }
                let before = try client.workspaceStatus()
                guard before.workspaceId == selected.workspaceId,
                      before.selectionGeneration == selected.selectionGeneration else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                let matches = try client.listProjects().filter {
                    $0.dashboardId == package.dashboardId
                }
                guard matches.count == 1, let project = matches.first else {
                    let assets = try WorkspacePackagePreviewLoader.load(client: client, selected: selected, summary: package)
                    await MainActor.run {
                        guard let self, self.brokerSelectedPackage == package else { return }
                        self.exportBrokerScreenFiles(assets, package: package)
                    }
                    return
                }
                let path = try client.projectPath(project.projectId)
                let after = try client.workspaceStatus()
                guard after.workspaceId == selected.workspaceId,
                      after.selectionGeneration == selected.selectionGeneration else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                await MainActor.run {
                    guard self?.brokerSelectedPackage == package else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    self?.notice = "Edit source in its folder, then build with the compatible CLI."
                }
            } catch {
                await MainActor.run {
                    self?.error = "Screen files unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportBrokerScreenFiles(_ assets: PackageAssetStore, package: WorkbenchWorkspacePackageSummary) {
        let panel = NSSavePanel()
        panel.title = "Export Screen Files"
        panel.message = "No source folder is linked to this saved screen. Export its HTML, scripts, and assets to a new folder. The installed screen and original library stay unchanged."
        panel.nameFieldStringValue = package.name.replacingOccurrences(of: "/", with: "-") + " Files"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw NSError(domain: "ScreenpunkExport", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Choose a new folder name; existing files will not be replaced."])
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for (path, asset) in assets.assets {
                let file = destination.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try asset.data.write(to: file, options: .withoutOverwriting)
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            notice = "Screen files exported. Editing this copy does not change the installed screen."
        } catch { self.error = "Screen-file export could not finish: \(error.localizedDescription)" }
    }

    func rollbackBrokerScreen() { applyBrokerScreen(rollback: true) }

    private func applyBrokerScreen(rollback: Bool = false) {
        guard (rollback ? canRollbackBrokerApply : canApply),
              let selected = brokerWorkspace, let environment = brokerEnvironment,
              let deviceId = brokerScreenSet?.deviceId else { return }
        let draftScreens = brokerDraftScreens
        let focusedDashboard = draftScreens.first(where: { $0.dashboardId == selectedScreen })?.dashboardId ?? draftScreens.first?.dashboardId
        let targetOrientation = orientation
        let prior = brokerApplyRecord
        guard rollback || (!draftScreens.isEmpty && focusedDashboard != nil) else { return }
        busy = true; error = nil
        let verifiedGUI = brokerApplyVerified
        Task.detached { [weak self] in
            var workflow: MacBrokerApplyWorkflow?
            var submissionStarted = false
            do {
                let expectedHome = DashboardPackageStore.defaultRoot().resolvingSymlinksInPath().path
                if rollback {
                    guard let prior else { throw MacBrokerApplyWorkflow.Failure.staleSelection }
                    workflow = try await MacBrokerApplyWorkflow.prepareRollback(
                        environment: environment, expectedControllerHome: expectedHome,
                        selected: selected, deviceId: deviceId, prior: prior)
                } else {
                    let client = try Self.openBrokerReadClient(environment)
                    let packages: [WorkbenchWorkspacePackageSummary]
                    do {
                        packages = try draftScreens.map {
                            try client.workspacePackage(dashboardId: $0.dashboardId, revision: $0.revision, in: selected)
                        }
                        client.close()
                    } catch { client.close(); throw error }
                    guard let focusedDashboard else { throw MacBrokerApplyWorkflow.Failure.noPackages }
                    let request = MacBrokerApplyWorkflow.Request(selected: selected, deviceId: deviceId,
                        packages: packages, selectedDashboardId: focusedDashboard,
                        orientation: targetOrientation, bindingIds: [])
                    workflow = try await MacBrokerApplyWorkflow.prepare(environment: environment,
                        expectedControllerHome: expectedHome, request: request)
                }
                guard let workflow else { throw MacBrokerApplyWorkflow.Failure.noPackages }
                let scope = try workflow.reviewText()
                try workflow.revalidateForReview()
                let approved = await MainActor.run { () -> Bool in
                    guard let self, self.brokerMode,
                          self.brokerWorkspace?.workspaceId == selected.workspaceId,
                          self.brokerWorkspace?.selectionGeneration == selected.selectionGeneration,
                          self.selection == deviceId,
                          (rollback ? self.brokerApplyRecord == prior :
                              self.brokerDraftScreens == draftScreens && self.orientation == targetOrientation) else { return false }
                    return MacBrokerReviewDialog.approve(scope)
                }
                guard approved else {
                    await workflow.close()
                    await MainActor.run { self?.busy = false; self?.notice = "Deployment review closed without approval." }
                    return
                }
                try workflow.revalidateForReview()
                guard let workspaceId = selected.workspaceId,
                      let generation = selected.selectionGeneration else {
                    throw MacBrokerApplyWorkflow.Failure.staleSelection
                }
                let attempt = MacBrokerApplyJournal.Record(workspaceId: workspaceId,
                    selectionGeneration: generation, deviceId: deviceId,
                    planId: workflow.review.plan.planId, planHash: workflow.review.planHash,
                    idempotencyKey: workflow.idempotencyKey, operationId: nil, phase: .submitting)
                let journal = Self.applyJournal()
                submissionStarted = true
                await MainActor.run {
                    self?.brokerApplyRecord = attempt
                    self?.brokerApplyState = "Submitting exact plan; do not start another deployment."
                }
                let persisted = try MacBrokerApplyAction.submit(journal: journal,
                    attempt: attempt, verifiedGUI: verifiedGUI) { markSubmissionBoundary in
                    let operation = try workflow.applyAfterExplicitReview(willSubmit: markSubmissionBoundary)
                    return .init(operationId: operation.operationId,
                        phase: MacBrokerApplyJournal.Record.Phase(rawValue: operation.state.rawValue) ?? .unknown)
                }
                await workflow.close()
                await MainActor.run {
                    self?.busy = false; self?.brokerApplyRecord = persisted
                    self?.brokerApplyState = "Apply operation \(persisted.phase.rawValue)."
                    self?.notice = persisted.phase == .active
                        ? (rollback ? "Previous screen set restored on device." : "Screen active on device.")
                        : "Deployment \(persisted.phase.rawValue); check durable status before another attempt."
                }
            } catch {
                await workflow?.close()
                let saved = try? Self.applyJournal().load()
                let matchingAttempt = saved?.planId == workflow?.review.plan.planId &&
                    saved?.idempotencyKey == workflow?.idempotencyKey
                await MainActor.run {
                    self?.busy = false
                    if let saved, (!submissionStarted || matchingAttempt ||
                        (error as? MacBrokerApplyJournal.Failure) == .conflict) {
                        self?.brokerApplyRecord = saved
                    }
                    if (error as? MacBrokerApplyJournal.Failure) == .conflict,
                       let saved, saved.blocksNewApply {
                        self?.brokerApplyState = "Another GUI Apply is pending; inspect its durable status."
                        self?.error = "Apply is already in progress for this Mac. No package was sent by this attempt."
                    } else if submissionStarted && !matchingAttempt {
                        self?.brokerApplyVerified = false
                        self?.brokerApplyState = "Apply journal unavailable; another Apply is disabled."
                        self?.error = "Apply status cannot be read safely. No automatic resend occurred. \(error.localizedDescription)"
                    } else if saved?.blocksNewApply == true {
                        self?.brokerApplyState = "Apply outcome unknown or pending; inspect durable status."
                        self?.error = "Apply may have reached the device. No automatic resend occurred. \(error.localizedDescription)"
                    } else {
                        self?.error = "Apply unavailable: \(error.localizedDescription)"
                        if (error as? WorkbenchIPCError)?.code == .incompatibleOwner {
                            self?.brokerApplyVerified = false
                            self?.brokerApplyState = "GUI verification unavailable; Apply disabled"
                        }
                    }
                }
            }
        }
    }

    func inspectBrokerApply(reconcile: Bool = false) {
        guard brokerMode, !busy, let client = brokerClient, let selected = brokerWorkspace,
              let record = brokerApplyRecord,
              selected.workspaceId == record.workspaceId,
              selected.selectionGeneration == record.selectionGeneration else { return }
        busy = true
        Task.detached { [weak self] in
            do {
                // Reauthenticate a closed idle socket before sending a new request.
                // Never replay a request whose outcome may already be committed.
                _ = try client.reconnectIfPeerClosed()
                let method: WorkbenchDeploymentMethod = record.operationId == nil ? .lookup :
                    (reconcile ? .reconcile : .status)
                var params: [String: Any] = [
                    "schemaVersion": 1, "expectedWorkspaceId": record.workspaceId,
                    "expectedSelectionGeneration": record.selectionGeneration]
                if let operationId = record.operationId {
                    params["operationId"] = operationId
                } else {
                    params["planId"] = record.planId
                }
                let result = try client.performDeployment(method: method, params: params)
                guard let operation = result.operation,
                      record.operationId == nil || operation.operationId == record.operationId,
                      operation.planId == record.planId,
                      operation.planHash == record.planHash,
                      operation.idempotencyKey == record.idempotencyKey else {
                    throw MacBrokerDeploymentAdapter.Error.changedPlan
                }
                let outcome = MacBrokerApplyAction.Outcome(operationId: operation.operationId,
                    phase: MacBrokerApplyJournal.Record.Phase(rawValue: operation.state.rawValue) ?? .unknown)
                let updated = try MacBrokerApplyAction.observed(journal: Self.applyJournal(),
                    record: record, outcome: outcome)
                await MainActor.run {
                    self?.busy = false; self?.brokerApplyRecord = updated
                    self?.brokerApplyState = "Apply operation \(updated.phase.rawValue)."
                    self?.notice = updated.phase == .active ? "Screen active on device." :
                        "Apply \(updated.phase.rawValue); no new package was sent by this check."
                }
            } catch {
                let current = try? Self.applyJournal().load()
                await MainActor.run {
                    self?.busy = false
                    if let current { self?.brokerApplyRecord = current }
                    self?.error = "Apply status remains uncertain: \(error.localizedDescription)"
                }
            }
        }
    }

    func run<T: Sendable>(_ operation: @escaping @Sendable (ControllerService) throws -> T, completion: @escaping (T) -> Void) {
        guard let service, !busy else { return }
        busy = true; notice = nil
        queue.async {
            let result = Result { try operation(service) }
            Task { @MainActor in
                self.busy = false
                switch result {
                case .success(let value): completion(value); self.refresh()
                case .failure(let error): self.error = (error as? ControllerError)?.detail ?? error.localizedDescription
                }
            }
        }
    }
    func refresh(probe: Bool = false, manual: Bool = false, periodic: Bool = false) {
        if brokerMode { refreshCompatibleBroker(); return }
        if manual { manuallyRefreshingDevices = true; pendingManualProbe = true }
        // A wake, foreground, or manual probe that arrives while a refresh or
        // operation holds the queue is deferred, not dropped.
        if probe, !periodic, refreshing || busy || pairing != nil { pendingProbe = true }
        guard let service, !refreshing, !busy, pairing == nil else { return }
        let probe = probe || pendingProbe || pendingManualProbe
        let manualProbe = pendingManualProbe
        pendingManualProbe = false
        pendingProbe = false
        refreshing = true
        if probe { checkingDevices = true }
        queue.async {
            let advertisements = service.devices.discover()
            if probe { for device in service.devices.listDevices() { _ = try? service.devices.device(device.id, probe: true) } }
            let devices = service.devices.listDevices()
            let nearby = WorkbenchSidebar.nearby(advertisements: advertisements, devices: devices.map(\.device), developer: false)
            let screens = Result { try service.listDashboards() }
            let agents = AgentPresence.active(in: service.store.root)
            Task { @MainActor in
                let previousDevice = self.device
                let hadDraft = self.hasUnappliedScreen
                self.refreshing = false; self.devices = devices; self.nearby = nearby; self.agents = agents
                if probe { self.checkingDevices = false; self.devicesChecked = true }
                if manualProbe { self.manuallyRefreshingDevices = self.pendingManualProbe }
                if self.section == "Devices", let previousDevice,
                   let current = devices.first(where: { $0.devicePin == previousDevice.devicePin }), current.id != previousDevice.id {
                    self.select(current.id)
                }
                if self.section == "Devices", !hadDraft, let current = self.device,
                   current.id == previousDevice?.id,
                   (current.screenSet != previousDevice?.screenSet || current.selectedDashboardId != previousDevice?.selectedDashboardId || current.device.activeRevision != previousDevice?.device.activeRevision) {
                    self.screenSelections[current.id] = nil
                    self.select(current.id)
                }
                if case .success(let value) = screens {
                    let changed = value != self.screens
                    self.screens = value
                    if changed, !self.previewIsApplied, let selected = self.selectedScreen, value.contains(where: { $0.dashboardId == selected }) { self.loadPreview(selected) }
                }
                if self.selection == nil { self.select(self.section == "Devices" ? devices.first?.id ?? nearby.first?.id : self.screens.first?.dashboardId) }
                if self.pendingProbe { self.refresh(probe: true) }
            }
        }
    }
    func select(_ id: String?) {
        if brokerMode {
            if section == "Devices", let id { selectBrokerDevice(id) }
            else if let id, let package = brokerPackages.first(where: {
                $0.dashboardId + ":" + $0.revision == id
            }) { selectBrokerPackage(package) }
            return
        }
        previewRequest = UUID()
        selection = id; notice = nil; preview = nil; record = nil; previewIsApplied = false
        if section == "Screens" { selectedScreen = id }
        else if let device {
            selectedScreen = device.selectedDashboardId ?? device.device.history.first(where: { $0.revision == device.device.activeRevision })?.dashboardId
                ?? appliedScreens[device.id]
            orientation = DeviceOrientation(rawValue: appliedOrientations[device.id] ?? "") ?? device.device.profile.orientation
        } else { selectedScreen = nil }
        if let device, section == "Devices" {
            let installed = installedSelection(device)
            deviceScreens = screenSelections[device.id] ?? installed
            if !deviceScreens.ids.contains(selectedScreen ?? "") { selectedScreen = deviceScreens.ids.first }
            if deviceScreens.ids == installed.ids, device.device.activeRevision != nil { loadAppliedPreview(device) }
            else if let selectedScreen { loadPreview(selectedScreen) }
        } else if let selectedScreen { loadPreview(selectedScreen) }
    }
    private func loadAppliedPreview(_ device: PairedDeviceRecord) {
        guard let service, let active = device.device.activeRevision else { return }
        let request = UUID(); previewRequest = request
        let dashboardId = selectedScreen
        let cachedPath = appliedPackagePaths[device.id]
        queue.async {
            var applied: DashboardRevisionRecord?
            if let dashboardId { applied = try? service.getDashboard(dashboardId: dashboardId, revision: active) }
            if applied == nil, dashboardId == nil {
                for screen in (try? service.listDashboards()) ?? [] {
                    if let match = try? service.getDashboard(dashboardId: screen.dashboardId, revision: active) { applied = match; break }
                }
            }
            if applied == nil {
                var paths: [URL] = cachedPath.map { [URL(fileURLWithPath: $0)] } ?? []
                let folder = service.store.root.appendingPathComponent("device-packages")
                let roots = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                if let dashboardId { paths += roots.map { $0.appendingPathComponent("dashboards/\(dashboardId)/revisions/\(active)") } }
                else {
                    for root in roots {
                        let dashboards = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("dashboards"), includingPropertiesForKeys: nil)) ?? []
                        paths += dashboards.map { $0.appendingPathComponent("revisions/\(active)") }
                    }
                }
                for path in paths {
                    guard let data = try? Data(contentsOf: path.appendingPathComponent("manifest.json")),
                          let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: data), manifest.revision == active,
                          let assets = try? PackageAssetStore.load(directory: path) else { continue }
                    applied = DashboardRevisionRecord(manifest: manifest, files: assets.assets.filter { $0.key != "manifest.json" }.mapValues(\.data), createdAt: Date(), packageDirectory: path)
                    break
                }
            }
            let appliedPackageMissing = applied == nil
            if applied == nil, let dashboardId {
                applied = try? service.getDashboard(dashboardId: dashboardId, revision: nil)
            }
            let assets = applied.flatMap { try? PackageAssetStore.load(directory: $0.packageDirectory) }
                ?? (active == StoredRevision.offlineFixture.revision ? try? PackageAssetStore.bundledOfflineFixture() : nil)
            Task { @MainActor in
                guard self.previewRequest == request, self.selection == device.id, self.section == "Devices" else { return }
                self.record = applied; self.preview = assets; self.previewIsApplied = !appliedPackageMissing; self.previewKey = UUID()
                if appliedPackageMissing, applied != nil {
                    self.notice = "Showing the saved screen. The applied version is not available on this Mac."
                }
                if let applied {
                    self.selectedScreen = applied.manifest.dashboardId
                    if self.deviceScreens.ids.isEmpty { self.deviceScreens = DeviceScreenSelection(ids: [applied.manifest.dashboardId]) }
                    self.orientation = DeviceOrientation(rawValue: applied.manifest.target.orientation) ?? .portrait }
            }
        }
    }
    func switchSection() {
        if brokerMode {
            if section == "Devices", let first = brokerDevices.first { selectBrokerDevice(first.deviceId) }
            else if let first = brokerPackages.first { selectBrokerPackage(first) }
            return
        }
        select(section == "Devices" ? devices.first?.id ?? nearby.first?.id : screens.first?.dashboardId)
    }
    func chooseScreen(_ id: String) {
        guard !busy else { return }
        guard deviceScreens.choose(id) else { error = "Choose up to twelve screens for this device."; return }
        rememberScreenSelection()
        if deviceScreens.ids.contains(id) { focusScreen(id) }
        else if selectedScreen == id {
            if let next = deviceScreens.ids.first { focusScreen(next) }
            else { previewRequest = UUID(); selectedScreen = nil; preview = nil; record = nil; previewIsApplied = false }
        }
    }
    private func thumbnailKey(_ id: String, revision: String, size: CGSize) -> String {
        "\(id):\(revision):\(Int(size.width))x\(Int(size.height))"
    }
    func cachedPreviewThumbnail(_ id: String, revision: String, size: CGSize) -> NSImage? {
        previewThumbnails.object(forKey: thumbnailKey(id, revision: revision, size: size) as NSString)
            ?? previewThumbnails.object(forKey: thumbnailKey(id, revision: "last", size: size) as NSString)
    }
    func previewThumbnail(_ id: String, revision: String, size: CGSize) async -> NSImage? {
        if brokerMode { return await brokerPreviewThumbnail(id, revision: revision, size: size) }
        let key = thumbnailKey(id, revision: revision, size: size)
        if let image = previewThumbnails.object(forKey: key as NSString) { return image }
        if let request = thumbnailRequests[key] { return await request.value }
        guard let service, let renderer = service.helper.makeRenderer(), !Task.isCancelled else { return nil }
        let request = Task { @MainActor [weak self] () -> NSImage? in
            guard let self else { return nil }
            // Share in-flight work across carousel view recreation. Only static, credential-free
            // captures use document readiness; strict MCP review captures are unchanged.
            let data: Data? = await withCheckedContinuation { continuation in
                self.thumbnailQueue.async {
                    let capture = try? { () throws -> PreviewCapture in
                        let record = try service.getDashboard(dashboardId: id, revision: revision.isEmpty ? nil : revision)
                        return try renderer.render(PreviewRequest(dashboardId: id, revision: record.manifest.revision,
                            digest: record.manifest.digest ?? "", packageDirectory: record.packageDirectory,
                            width: Int(size.width), height: Int(size.height), live: false,
                            waitsForRuntimeReady: false, timeoutSeconds: 6))
                    }()
                    continuation.resume(returning: capture?.png)
                }
            }
            defer { self.thumbnailRequests[key] = nil }
            guard let data, let image = NSImage(data: data) else { return nil }
            let cost = Int(image.size.width * image.size.height * 4)
            self.previewThumbnails.setObject(image, forKey: key as NSString, cost: cost)
            self.previewThumbnails.setObject(image, forKey: self.thumbnailKey(id, revision: "last", size: size) as NSString, cost: cost)
            return image
        }
        thumbnailRequests[key] = request
        return await request.value
    }

    private func brokerPreviewThumbnail(_ id: String, revision: String, size: CGSize) async -> NSImage? {
        let key = thumbnailKey(id, revision: revision, size: size)
        if let image = previewThumbnails.object(forKey: key as NSString) { return image }
        if let task = thumbnailRequests[key] { return await task.value }
        guard let environment = brokerEnvironment, let selected = brokerWorkspace,
              let renderer = HelperSupervisor().makeRenderer() else { return nil }
        let task = Task { @MainActor [weak self] () -> NSImage? in
            guard let self else { return nil }
            let png: Data? = await withCheckedContinuation { continuation in
                self.thumbnailQueue.async {
                    let data = try? { () throws -> Data in
                        let client = try Self.openBrokerReadClient(environment); defer { client.close() }
                        let package = try client.workspacePackage(dashboardId: id, revision: revision, in: selected)
                        let assets = try WorkspacePackagePreviewLoader.load(client: client, selected: selected, summary: package)
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-carousel-" + UUID().uuidString)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                               attributes: [.posixPermissions: 0o700])
                        defer { try? FileManager.default.removeItem(at: directory) }
                        // Only verified, bounded package files; no credentials or live runtimes.
                        for (path, asset) in assets.assets {
                            let file = directory.appendingPathComponent(path)
                            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try asset.data.write(to: file)
                        }
                        return try renderer.render(PreviewRequest(dashboardId: id, revision: revision,
                            digest: package.digest, packageDirectory: directory, width: Int(size.width), height: Int(size.height),
                            live: false, waitsForRuntimeReady: false, timeoutSeconds: 6)).png
                    }()
                    continuation.resume(returning: data)
                }
            }
            defer { self.thumbnailRequests[key] = nil }
            guard let png, let image = NSImage(data: png) else { return nil }
            self.previewThumbnails.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
            return image
        }
        thumbnailRequests[key] = task
        return await task.value
    }

    func createReactScreen(starter: String) {
        guard let service, !busy else { return }
        busy = true
        queue.async {
            let result = Result { () -> JSONValue in
                let project = try service.authoring.create(starter: starter)
                return try service.authoring.build(id: project["projectId"]!.string!, expected: project["sourceVersion"]!.string!, baseRevision: nil, service: service)
            }
            Task { @MainActor in
                self.busy = false
                switch result {
                case .success(let build):
                    self.section = "Screens"; self.screens = (try? service.listDashboards()) ?? []
                    if let id = build["dashboardId"]?.string { self.select(id) }
                case .failure(let failure): self.error = (failure as? ControllerError)?.detail ?? failure.localizedDescription
                }
            }
        }
    }
    func revealReactSource(_ dashboardId: String) {
        guard let service else { return }
        do {
            guard let project = try service.authoring.project(for: dashboardId), let location = project["sourceLocation"]?.string else {
                notice = "This Screen has no editable React source."; return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location)])
        } catch { self.error = (error as? ControllerError)?.detail ?? error.localizedDescription }
    }
    func rebuildReactScreen(_ dashboardId: String) {
        guard let service, !busy else { return }
        busy = true
        queue.async {
            let result = Result { () -> Void in
                guard let project = try service.authoring.project(for: dashboardId) else { throw ControllerError.validationFailed(detail: "This Screen has no editable React source.") }
                let current = try service.getDashboard(dashboardId: dashboardId, revision: nil)
                _ = try service.authoring.build(id: project["projectId"]!.string!, expected: project["sourceVersion"]!.string!, baseRevision: current.manifest.revision, service: service)
            }
            Task { @MainActor in
                self.busy = false
                switch result {
                case .success: self.screens = (try? service.listDashboards()) ?? []; self.loadPreview(dashboardId)
                case .failure(let failure): self.error = (failure as? ControllerError)?.detail ?? failure.localizedDescription
                }
            }
        }
    }

    var brokerPickerScreens: [LANScreenSetEntry] {
        var choices = brokerPackages.map { LANScreenSetEntry(dashboardId: $0.dashboardId, revision: $0.revision, name: $0.name) }
        for selected in brokerDraftScreens {
            if let index = choices.firstIndex(where: { $0.dashboardId == selected.dashboardId }) { choices[index] = selected }
            else { choices.append(selected) }
        }
        return choices
    }
    private func rememberBrokerDraft() {
        guard let observed = brokerScreenSet else { return }
        brokerDrafts[observed.deviceId] = (brokerDraftScreens, brokerMultipleScreens, observed.installedSetHash)
    }
    func setBrokerMultipleScreens(_ enabled: Bool) {
        guard !busy else { return }
        var draft = DeviceScreenSelection(ids: brokerDraftScreens.map(\.dashboardId), multiple: brokerMultipleScreens)
        draft.setMultiple(enabled, preferred: selectedScreen)
        brokerMultipleScreens = draft.multiple
        brokerDraftScreens = draft.ids.compactMap { id in brokerDraftScreens.first { $0.dashboardId == id } }
        if let focused = brokerDraftScreens.first, !brokerDraftScreens.contains(where: { $0.dashboardId == selectedScreen }) {
            selectBrokerInstalledScreen(focused.dashboardId, revision: focused.revision)
        }
        rememberBrokerDraft()
    }
    func chooseBrokerScreen(_ screen: LANScreenSetEntry) {
        guard !busy, brokerPickerScreens.contains(screen) else { return }
        let candidates = brokerDraftScreens + [screen]
        var draft = DeviceScreenSelection(ids: brokerDraftScreens.map(\.dashboardId), multiple: brokerMultipleScreens)
        guard draft.choose(screen.dashboardId) else { return }
        brokerDraftScreens = draft.ids.compactMap { id in candidates.first { $0.dashboardId == id } }
        if draft.ids.isEmpty {
            brokerPreviewTask?.cancel(); previewRequest = UUID()
            preview = nil; brokerPreviewManifest = nil; brokerSelectedPackage = nil; selectedScreen = nil
        } else if draft.ids.contains(screen.dashboardId) {
            selectBrokerInstalledScreen(screen.dashboardId, revision: screen.revision)
        } else if selectedScreen == screen.dashboardId, let first = brokerDraftScreens.first {
            selectBrokerInstalledScreen(first.dashboardId, revision: first.revision)
        }
        rememberBrokerDraft()
    }

    func brokerPreviewNeighbor(_ offset: Int) -> LANScreenSetEntry? {
        let screens = brokerDraftScreens
        guard section == "Devices", screens.count > 1,
              let index = screens.firstIndex(where: { $0.dashboardId == selectedScreen }) else { return nil }
        return screens[(index + offset % screens.count + screens.count) % screens.count]
    }

    func browseScreen(_ offset: Int) {
        if brokerMode {
            guard section == "Devices", let screen = brokerPreviewNeighbor(offset) else { return }
            selectBrokerInstalledScreen(screen.dashboardId, revision: screen.revision)
            return
        }
        guard section == "Devices", device != nil, !busy,
              let id = deviceScreens.previewNeighbor(of: selectedScreen, offset: offset) else { return }
        focusScreen(id)
    }
    private func focusScreen(_ id: String) { previewIsApplied = false; selectedScreen = id; loadPreview(id) }
    func loadPreview(_ id: String) {
        guard let service else { return }
        let request = UUID(); previewRequest = request
        queue.async {
            let result = Result { () -> (DashboardRevisionRecord, PackageAssetStore, Bool) in
                let record = try service.getDashboard(dashboardId: id, revision: nil)
                var assets = try PackageAssetStore.load(directory: record.packageDirectory)
                if let entry = assets.assets[record.manifest.entrypoint] { assets.assets["index.html"] = entry }
                return (record, assets, try service.authoring.project(for: id) != nil)
            }
            Task { @MainActor in
                guard self.previewRequest == request, self.selectedScreen == id else { return }
                switch result {
                case .success(let (record, assets, managed)):
                    self.isReactProject = managed
                    self.record = record; self.preview = assets; self.previewKey = UUID()
                    if !self.supports(self.orientation) { self.orientation = self.screenSupport == .landscape ? .landscape : .portrait }
                    if self.section == "Screens" { self.orientation = DeviceOrientation(rawValue: record.manifest.target.orientation) ?? .portrait }
                case .failure(let error): self.preview = nil; self.error = (error as? ControllerError)?.detail ?? error.localizedDescription
                }
            }
        }
    }
    func pair(_ entry: WorkbenchSidebar.NearbyEntry) {
        selection = entry.id
        let ad = entry.advertisement
        run({ try $0.devices.requestPairing(deviceId: ad.deviceId, host: ad.host, port: ad.port) }) { result in
            self.pairingTimer?.invalidate(); self.pairingTimer = nil
            self.pairingConfirmedOnMac = false
            self.pairing = result
        }
    }
    /// The Mac's half of the mutual confirmation. Until this runs no
    /// `pair.confirm` leaves the Mac, so the device's answer alone cannot
    /// complete pairing.
    func confirmPairingCodesMatch() {
        guard pairing != nil, !pairingConfirmedOnMac else { return }
        pairingConfirmedOnMac = true
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPairing() }
        }
        pollPairing()
    }
    private func pollPairing() {
        guard let pairing, pairingConfirmedOnMac, let service, !pairingPollInFlight else { return }
        pairingPollInFlight = true
        queue.async {
            let result = Result { try service.devices.confirmPairing(deviceId: pairing.deviceId) }
            Task { @MainActor in
                self.pairingPollInFlight = false
                guard self.pairing?.deviceId == pairing.deviceId else { return }
                switch result {
                case .success(let record):
                    self.pairingTimer?.invalidate(); self.pairingTimer = nil; self.pairing = nil; self.pairingConfirmedOnMac = false
                    self.nearby.removeAll { $0.id == record.id }
                    self.devices.removeAll { $0.id == record.id }; self.devices.append(record)
                    self.select(record.id); self.refresh()
                    self.notice = record.device.activeRevision == nil ? "Paired. Choose a screen to put on this device." : "Device connected."
                case .failure(let error):
                    if (error as? ControllerError)?.code == .permissionRequired { return }
                    self.cancelPairing(); self.error = (error as? ControllerError)?.detail ?? error.localizedDescription
                }
            }
        }
    }
    func cancelPairing() {
        pairingTimer?.invalidate(); pairingTimer = nil
        if let pairing { service?.devices.cancelPending(pairing.deviceId) }
        pairing = nil
        pairingConfirmedOnMac = false
    }
    func discoverPairableDevices() async throws -> [AdvertisedDevice] {
        guard brokerMode, let environment = brokerEnvironment else { return nearby.map(\.advertisement) }
        let discovered = try await Task.detached {
            let client = try Self.openBrokerReadClient(environment); defer { client.close() }
            return try client.discoverDevices()
        }.value
        try Task.checkCancellation()
        let paired = Set(brokerDevices.map(\.deviceId))
        return discovered.filter { !paired.contains($0.deviceId) && $0.source == .advertised }
            .sorted { ($0.name ?? $0.host).localizedStandardCompare($1.name ?? $1.host) == .orderedAscending }
    }

    func finishBrokerPairing(cancel: Bool) {
        guard !busy, let pending = brokerPendingPairing, let environment = brokerEnvironment else { return }
        busy = true
        Task {
            do {
                try await Task.detached {
                    let client = try Self.openBrokerReadClient(environment); defer { client.close() }
                    if cancel { try client.cancelPairing(pendingId: pending.pendingId) }
                    else { _ = try client.confirmPairing(pendingId: pending.pendingId, matchingCode: pending.matchingCode) }
                }.value
                busy = false; brokerPendingPairing = nil; sheet = nil
                if !cancel { notice = "Device connected."; refreshCompatibleBroker() }
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }

    func addManual(host: String, port: String) {
        guard let host = WorkbenchSidebar.normalizeHost(host), let port = WorkbenchSidebar.parsePort(port) else { error = WorkbenchCopy.invalidAddress; return }
        if brokerMode {
            guard !busy, let environment = brokerEnvironment else { return }
            busy = true
            Task {
                do {
                    let pending = try await Task.detached {
                        let client = try Self.openBrokerReadClient(environment); defer { client.close() }
                        return try client.beginPairing(host: host, port: port)
                    }.value
                    busy = false; brokerPendingPairing = pending
                } catch { busy = false; self.error = error.localizedDescription }
            }
            return
        }
        let ad = service?.devices.addManual(host: host, port: port)
        sheet = nil; refresh(); if let ad { selection = ad.deviceId }
    }
    func openDeviceSettings(_ id: String) {
        guard let target = devices.first(where: { $0.id == id }), let service else { return }
        let installedPackage = selection == id && previewIsApplied ? preview : nil
        settingsEditor = MacDeviceSettingsModel(device: target, service: service, package: installedPackage)
        sheet = .deviceSettings
    }

    func renameDevice(_ raw: String) {
        if brokerMode {
            guard !busy, let id = selection,
                  brokerDevices.contains(where: { $0.deviceId == id }),
                  let client = brokerClient else { return }
            busy = true
            Task.detached { [weak self] in
                let outcome = Result {
                    _ = try client.reconnectIfPeerClosed()
                    return try WorkbenchDeviceNameForwarder.rename(client: client,
                        deviceId: id, rawName: raw)
                }
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    guard self.brokerMode else { return }
                    switch outcome {
                    case .success:
                        self.sheet = nil
                        self.notice = "Device name saved through the service."
                        self.refreshCompatibleBroker()
                    case .failure:
                        self.error = "Device rename may be stale or its outcome unknown. Reload device settings before retrying."
                    }
                }
            }
            return
        }
        guard let device, let name = DeviceDisplayName.sanitize(raw) else { return }
        run({ service in
            let record = try service.devices.directory.update(device.id) { $0.displayName = name; $0.device.profile.name = name }
            try service.devices.syncDeviceDisplayName(deviceId: device.id)
            return record
        }) { record in
            if let record, let index = self.devices.firstIndex(where: { $0.id == record.id }) { self.devices[index] = record }
            self.sheet = nil
        }
    }
    func renameScreen(_ raw: String) {
        guard let record, section == "Screens", let name = DeviceDisplayName.sanitize(raw) else { return }
        run({ service in
            try service.store.putDashboard(dashboardId: record.manifest.dashboardId, name: name,
                baseRevision: record.manifest.revision, target: record.manifest.target,
                connections: record.manifest.connections,
                files: record.files.map { DashboardFileInput(path: $0.key, base64: $0.value.base64EncodedString()) })
        }) { updated in
            self.record = updated
            if let index = self.screens.firstIndex(where: { $0.dashboardId == updated.manifest.dashboardId }) {
                self.screens[index].name = name
            }
            if self.draft?.dashboardId == updated.manifest.dashboardId,
               self.draft?.baseRevision == record.manifest.revision {
                self.draft?.name = name
                self.draft?.baseRevision = updated.manifest.revision
                self.persistDraft()
            }
            self.sheet = nil
        }
    }
    func changeScreenIcon(_ symbol: String) {
        guard section == "Screens", let id = selectedScreen,
              NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else { return }
        symbols[id] = symbol
        persistPreferences()
        if draft?.dashboardId == id {
            draft?.symbol = symbol
            persistDraft()
        }
        sheet = nil
    }
    func forgetDevice() {
        if brokerMode {
            guard !busy, let id = selection,
                  brokerDevices.contains(where: { $0.deviceId == id }),
                  let client = brokerClient else { return }
            busy = true
            Task.detached { [weak self] in
                let outcome = Result {
                    _ = try client.reconnectIfPeerClosed()
                    return try client.forgetDevice(id)
                }
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    guard self.brokerMode else { return }
                    switch outcome {
                    case .success(let removed):
                        if self.selection == id {
                            self.selection = nil; self.brokerScreenSet = nil
                        }
                        self.notice = removed
                            ? "Device removed from this Mac. Its installed screen remains until the device is disconnected locally."
                            : "Device was already absent from this Mac."
                        self.refreshCompatibleBroker()
                    case .failure:
                        self.error = "Forget outcome unknown. Refresh devices before trying again."
                    }
                }
            }
            return
        }
        guard let device else { return }
        run({ try $0.devices.forget(deviceId: device.id) }) { _ in
            self.devices.removeAll { $0.id == device.id }; self.appliedScreens[device.id] = nil
            self.persistPreferences(); self.select(nil)
            self.notice = "Device forgotten. To pair it with a different Mac, hold two fingers on its screen for five seconds to open the device menu, then choose Disconnect and confirm."
        }
    }
    func setScreenSupport(_ support: ScreenOrientationSupport) {
        guard let record, section == "Screens", support != screenSupport else { return }
        run({ service in
            var files = record.files
            files[ScreenDesignSettings.path] = try ScreenDesignSettings(orientations: support).data()
            var target = record.manifest.target
            if let orientation = DeviceOrientation(rawValue: target.orientation), !support.allows(orientation) {
                let width = target.width, height = target.height
                target.orientation = support == .landscape ? "landscape" : "portrait"
                target.width = support == .landscape ? max(width,height) : min(width,height)
                target.height = support == .landscape ? min(width,height) : max(width,height)
            }
            return try service.store.putDashboard(dashboardId: record.manifest.dashboardId, name: record.manifest.name, baseRevision: record.manifest.revision, target: target, connections: record.manifest.connections, files: files.map { DashboardFileInput(path: $0.key, base64: $0.value.base64EncodedString()) })
        }) { updated in
            self.record = updated
            if !self.supports(self.orientation) { self.orientation = support == .landscape ? .landscape : .portrait }
            self.loadPreview(updated.manifest.dashboardId)
        }
    }
    func applyScreen() {
        if brokerMode { applyBrokerScreen(); return }
        guard let device, canApply else { return }
        let ids = deviceScreens.ids
        let visible = selectedScreen.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]
        let orientation = orientation
        let deviceTitle = title
        run({ service in
            let sources = try ids.map { try service.getDashboard(dashboardId: $0, revision: nil) }
            let prepared = try sources.map { source in
                do { return try service.prepareDashboardForDevice(dashboardId: source.manifest.dashboardId, revision: source.manifest.revision, device: device.device.profile, orientation: orientation) }
                catch { throw ControllerError.validationFailed(detail: "\(source.manifest.name): \((error as? ControllerError)?.detail ?? error.localizedDescription) No screens have been changed on the device.") }
            }
            let receipt = try service.shipSet(records: prepared, deviceId: device.id, selectedDashboardId: visible)
            return (receipt, sources, prepared, try service.devices.device(device.id, probe: false))
        }) { (receipt, sources, prepared, updated) in
            self.appliedSetSources[device.id] = Dictionary(uniqueKeysWithValues: sources.map { ($0.manifest.dashboardId, $0.manifest.revision) })
            self.appliedSourceRevisions[device.id] = sources.first { $0.manifest.dashboardId == visible }?.manifest.revision
            self.appliedPackagePaths[device.id] = prepared.first { $0.manifest.dashboardId == visible }?.packageDirectory.path
            self.appliedScreens[device.id] = visible
            self.appliedOrientations[device.id] = orientation.rawValue
            if let index = self.devices.firstIndex(where: { $0.id == device.id }) { self.devices[index] = updated }
            self.persistPreferences()
            if self.selection == device.id, self.section == "Devices" { self.loadAppliedPreview(updated) }
            self.notice = receipt.screens.count > 1 ? "\(receipt.screens.count) screens applied to \(deviceTitle). Swipe left or right with two fingers on the device to switch screens." : "Screen applied to \(deviceTitle)."
        }
    }
    private func persistPreferences() {
        UserDefaults.standard.set(appliedSetSources, forKey: "appliedSetSources")
        UserDefaults.standard.set(appliedSourceRevisions, forKey: "appliedSourceRevisions")
        UserDefaults.standard.set(appliedPackagePaths, forKey: "appliedPackagePaths")
        UserDefaults.standard.set(symbols, forKey: "screenSymbols")
        UserDefaults.standard.set(appliedScreens, forKey: "appliedScreens")
        UserDefaults.standard.set(appliedOrientations, forKey: "appliedOrientations")
    }
    func newScreen() {
        if draft == nil { draft = ScreenDraft(files: Self.starterFiles, target: service?.defaultTarget() ?? ManifestTarget(profileId: "phone", width: 390, height: 844, scale: 1, orientation: "portrait", safeArea: SafeAreaInsets(top: 0,right: 0,bottom: 0,left: 0))) }
        sheet = .editor
    }
    func duplicateScreen() {
        guard let record else { return }
        if draft != nil { sheet = .editor; error = "Save or cancel your current edits before duplicating another screen."; return }
        draft = ScreenDraft(name: record.manifest.name + " Copy", symbol: symbol(for: record.manifest.dashboardId), files: record.files, target: record.manifest.target, connections: record.manifest.connections)
        persistDraft(); sheet = .editor
    }
    func editScreen() {
        guard let record else { return }
        if isReactProject { revealReactSource(record.manifest.dashboardId); return }
        if draft != nil { sheet = .editor; return }
        draft = ScreenDraft(dashboardId: record.manifest.dashboardId, baseRevision: record.manifest.revision, name: record.manifest.name, symbol: symbol(for: record.manifest.dashboardId), files: record.files, target: record.manifest.target, connections: record.manifest.connections)
        sheet = .editor
    }
    func persistDraft() {
        guard let draft else { return }
        do { try JSONEncoder().encode(draft).write(to: draftURL, options: .atomic) } catch { self.error = error.localizedDescription }
    }
    func discardDraft() { draft = nil; try? FileManager.default.removeItem(at: draftURL); sheet = nil }
    func saveDraft() {
        guard let draft else { return }
        let files = draft.files.map { DashboardFileInput(path: $0.key, base64: $0.value.base64EncodedString()) }
        run({ try $0.store.putDashboard(dashboardId: draft.dashboardId, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), baseRevision: draft.baseRevision, target: draft.target, connections: draft.connections, files: files) }) { record in
            self.symbols[record.manifest.dashboardId] = draft.symbol; self.persistPreferences(); self.discardDraft()
            self.previewIsApplied = false
            self.selectedScreen = record.manifest.dashboardId
            if self.section == "Devices" {
                if !self.deviceScreens.ids.contains(record.manifest.dashboardId) {
                    if !self.deviceScreens.choose(record.manifest.dashboardId) { self.notice = "Screen saved. The device already has twelve screens selected." }
                }
                self.rememberScreenSelection()
            }
            if self.section == "Screens" { self.selection = record.manifest.dashboardId }
            self.loadPreview(record.manifest.dashboardId); self.notice = "Screen saved."
        }
    }
    func deleteScreen() {
        guard let id = selectedScreen else { return }
        run({ try $0.store.deleteDashboard(dashboardId: id) }) { _ in
            self.screens.removeAll { $0.dashboardId == id }; self.selectedScreen = nil; self.preview = nil; self.record = nil
            if self.section == "Screens" { self.select(self.screens.first?.dashboardId) }
        }
    }
    func importScreen() {
        if draft != nil { sheet = .editor; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose a screen package folder containing manifest.json and its local assets."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
            try PackageValidator.validate(manifest)
            var files: [String:Data] = [:]
            for file in manifest.files {
                let path = try PackagePath.normalize(file.path)
                let assetURL = url.appendingPathComponent(path).resolvingSymlinksInPath()
                guard assetURL.path.hasPrefix(url.resolvingSymlinksInPath().path + "/") else { throw PackageAssetError.denied }
                let bytes = try Data(contentsOf: assetURL)
                guard bytes.count == file.bytes, DeploymentDigest.sha256Hex(bytes) == file.sha256 else { throw TransferFailure.validationFailed }
                files[path] = bytes
            }
            guard files["index.html"] != nil else { throw ControllerError.validationFailed(detail: "Screen packages must contain index.html.") }
            draft = ScreenDraft(name: manifest.name, files: files, target: manifest.target, connections: manifest.connections)
            persistDraft(); sheet = .editor
        } catch { self.error = (error as? ControllerError)?.detail ?? error.localizedDescription }
    }
    static let starterFiles: [String: Data] = [
        "index.html": Data("<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"stylesheet\" href=\"style.css\"></head><body><main><p id=\"date\"></p><h1 id=\"clock\">Hello.</h1><p>A little more life for your screen.</p></main><script src=\"script.js\"></script></body></html>".utf8),
        "style.css": Data("html,body{margin:0;width:100%;height:100%;background:#141414;color:#fff;font-family:-apple-system,BlinkMacSystemFont,sans-serif}body{display:grid;place-items:center}main{text-align:center;padding:24px}h1{font-size:clamp(48px,16vw,110px);font-weight:600;letter-spacing:-.06em;margin:16px 0}p{color:#aaa;font-size:17px}".utf8),
        "script.js": Data("function tick(){document.getElementById('clock').textContent=new Date().toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});document.getElementById('date').textContent=new Date().toLocaleDateString([],{weekday:'long',month:'long',day:'numeric'})}tick();setInterval(tick,1000);window.screenpunk?.runtime?.ready?.();".utf8)
    ]
}
