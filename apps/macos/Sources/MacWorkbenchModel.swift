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
    @Published var sheet: WorkbenchSheet?
    @Published var connectionsDeviceID: String?
    @Published var settingsEditor: MacDeviceSettingsModel?
    @Published var draft: ScreenDraft?
    @Published var symbols: [String: String] = [:]
    private(set) var service: ControllerService?
    private let transport = LANTransport()
    private let queue = DispatchQueue(label: "xyz.screenpunk.workbench", qos: .userInitiated)
    private var timer: Timer?
    private var pairingTimer: Timer?
    private var pairingPollInFlight = false
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

    var previewDashboardId: String { record?.manifest.dashboardId ?? "" }
    var previewRevision: String { record?.manifest.revision ?? "" }
    var previewManifest: DashboardManifest? { record?.manifest }
    var previewUsesHomeAssistant: Bool { record?.manifest.connections.contains { $0.alias == "home" } ?? false }
    var device: PairedDeviceRecord? { devices.first { $0.id == selection } }
    var detected: WorkbenchSidebar.NearbyEntry? { nearby.first { $0.id == selection } }
    var screenName: String { screens.first { $0.dashboardId == selectedScreen }?.name ?? record?.manifest.name ?? "Choose Screen" }
    var title: String {
        if section == "Screens" { return screens.first { $0.dashboardId == selection }?.name ?? "Screens" }
        if let device { return DeviceDisplayName.label(name: device.displayName ?? device.device.profile.name, deviceId: device.id, fallback: "Paired device") }
        return detected?.title ?? "Devices"
    }
    var previewSize: CGSize {
        let width = section == "Screens" ? screenPreviewProfile.width : device?.device.profile.width ?? record?.manifest.target.width ?? 390
        let height = section == "Screens" ? screenPreviewProfile.height : device?.device.profile.height ?? record?.manifest.target.height ?? 844
        return orientation == .portrait ? CGSize(width: min(width,height), height: max(width,height)) : CGSize(width: max(width,height), height: min(width,height))
    }
    var screenSupport: ScreenOrientationSupport { (try? record.map { try ScreenDesignSettings.read(files: $0.files).orientations }) ?? .both }
    func supports(_ orientation: DeviceOrientation) -> Bool { screenSupport.allows(orientation) }
    var canDuplicate: Bool { record != nil }
    var screenSelectorTitle: String { deviceScreens.multiple ? "\(deviceScreens.ids.count) \(deviceScreens.ids.count == 1 ? "Screen" : "Screens")" : screenName }
    var applyLabel: String { deviceScreens.ids.count > 1 ? "Apply Screens" : "Apply Screen" }
    var canApply: Bool { device != nil && !deviceScreens.ids.isEmpty && deviceScreens.ids.allSatisfy { id in screens.contains { $0.dashboardId == id } } && !busy }
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
        guard timer == nil else { return }
        do {
            service = try ControllerService.bootstrap()
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
        } catch { self.error = error.localizedDescription }
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
    func switchSection() { select(section == "Devices" ? devices.first?.id ?? nearby.first?.id : screens.first?.dashboardId) }
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
                notice = "This screen has no managed React source project."; return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location)])
        } catch { self.error = (error as? ControllerError)?.detail ?? error.localizedDescription }
    }
    func rebuildReactScreen(_ dashboardId: String) {
        guard let service, !busy else { return }
        busy = true
        queue.async {
            let result = Result { () -> Void in
                guard let project = try service.authoring.project(for: dashboardId) else { throw ControllerError.validationFailed(detail: "This screen has no managed React source project.") }
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

    func browseScreen(_ offset: Int) {
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
    func addManual(host: String, port: String) {
        guard let host = WorkbenchSidebar.normalizeHost(host), let port = WorkbenchSidebar.parsePort(port) else { error = WorkbenchCopy.invalidAddress; return }
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
