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

enum WorkbenchSheet: String, Identifiable { case manual, editor, agents, homeAssistant, rename, renameScreen, screenIcon; var id: String { rawValue } }

@MainActor
final class MacWorkbenchModel: ObservableObject {
    @Published var section = "Devices"
    @Published var selection: String?
    @Published var devices: [PairedDeviceRecord] = []
    @Published var nearby: [WorkbenchSidebar.NearbyEntry] = []
    @Published var screens: [DashboardSummary] = []
    @Published var agents: [AgentPresence] = []
    @Published var selectedScreen: String?
    @Published var preview: PackageAssetStore?
    @Published var previewKey = UUID()
    @Published var screenPreviewProfile: ScreenPreviewProfile = .defaultProfile {
        didSet { UserDefaults.standard.set(screenPreviewProfile.id, forKey: "screenPreviewProfile") }
    }
    @Published var orientation: DeviceOrientation = .portrait
    @Published var pairing: PairingRequestResult?
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var sheet: WorkbenchSheet?
    @Published var draft: ScreenDraft?
    @Published var symbols: [String: String] = [:]
    private(set) var service: ControllerService?
    private let transport = LANTransport()
    private let queue = DispatchQueue(label: "xyz.screenpunk.workbench", qos: .userInitiated)
    private var timer: Timer?
    private var pairingTimer: Timer?
    private var pairingPollInFlight = false
    private var refreshing = false
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
    var canApply: Bool { device != nil && selectedScreen != nil && preview != nil && !busy }
    var hasUnappliedScreen: Bool {
        guard let device, selectedScreen != nil else { return false }
        if previewIsApplied { return orientation != device.device.profile.orientation }
        return appliedScreens[device.id] != selectedScreen || appliedOrientations[device.id] != orientation.rawValue || (record != nil && appliedSourceRevisions[device.id] != record?.manifest.revision)
    }
    func symbol(for id: String) -> String { symbols[id] ?? "star" }
    func deviceSymbol(_ name: String, landscape: Bool = false) -> String {
        name.localizedCaseInsensitiveContains("ipad") ? (landscape ? "ipad.landscape" : "ipad") : (landscape ? "iphone.gen3.landscape" : "iphone.gen3")
    }

    func start() {
        guard timer == nil else { return }
        do {
            service = try ControllerService.bootstrap()
            if let service { let status = transport.attach(to: service); if !service.devices.transportAvailable { error = status } }
            symbols = UserDefaults.standard.dictionary(forKey: "screenSymbols") as? [String:String] ?? [:]
            appliedSourceRevisions = UserDefaults.standard.dictionary(forKey: "appliedSourceRevisions") as? [String:String] ?? [:]
            appliedPackagePaths = UserDefaults.standard.dictionary(forKey: "appliedPackagePaths") as? [String:String] ?? [:]
            appliedScreens = UserDefaults.standard.dictionary(forKey: "appliedScreens") as? [String:String] ?? [:]
            appliedOrientations = UserDefaults.standard.dictionary(forKey: "appliedOrientations") as? [String:String] ?? [:]
            if let saved = UserDefaults.standard.string(forKey: "screenPreviewProfile"), let profile = ScreenPreviewProfile.all.first(where: { $0.id == saved }) { screenPreviewProfile = profile }
            draft = try? JSONDecoder().decode(ScreenDraft.self, from: Data(contentsOf: draftURL))
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; self.ticks += 1; self.refresh(probe: self.ticks % 5 == 0) }
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
    func refresh(probe: Bool = false) {
        guard let service, !refreshing, !busy, pairing == nil else { return }
        refreshing = true
        queue.async {
            if probe { for device in service.devices.listDevices() { _ = try? service.devices.device(device.id, probe: true) } }
            let devices = service.devices.listDevices()
            let nearby = WorkbenchSidebar.nearby(advertisements: service.devices.discover(), devices: devices.map(\.device), developer: false)
            let screens = Result { try service.listDashboards() }
            let agents = AgentPresence.active(in: service.store.root)
            Task { @MainActor in
                self.refreshing = false; self.devices = devices; self.nearby = nearby; self.agents = agents
                if case .success(let value) = screens {
                    let changed = value != self.screens
                    self.screens = value
                    if changed, !self.previewIsApplied, let selected = self.selectedScreen, value.contains(where: { $0.dashboardId == selected }) { self.loadPreview(selected) }
                }
                if self.selection == nil { self.select(self.section == "Devices" ? devices.first?.id ?? nearby.first?.id : self.screens.first?.dashboardId) }
            }
        }
    }
    func select(_ id: String?) {
        selection = id; notice = nil; preview = nil; record = nil; previewIsApplied = false
        if section == "Screens" { selectedScreen = id }
        else if let device {
            selectedScreen = device.device.history.first(where: { $0.revision == device.device.activeRevision })?.dashboardId
                ?? appliedScreens[device.id]
            orientation = DeviceOrientation(rawValue: appliedOrientations[device.id] ?? "") ?? device.device.profile.orientation
        } else { selectedScreen = nil }
        if let device, section == "Devices", device.device.activeRevision != nil { loadAppliedPreview(device) }
        else if let selectedScreen { loadPreview(selectedScreen) }
    }
    private func loadAppliedPreview(_ device: PairedDeviceRecord) {
        guard let service, let active = device.device.activeRevision else { return }
        let dashboardId = selectedScreen
        let cachedPath = appliedPackagePaths[device.id]
        queue.async {
            var applied: DashboardRevisionRecord?
            if let dashboardId { applied = try? service.getDashboard(dashboardId: dashboardId, revision: active) }
            if applied == nil {
                var paths: [URL] = cachedPath.map { [URL(fileURLWithPath: $0)] } ?? []
                let folder = service.store.root.appendingPathComponent("device-packages")
                let roots = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                if let dashboardId { paths += roots.map { $0.appendingPathComponent("dashboards/\(dashboardId)/revisions/\(active)") } }
                for path in paths {
                    guard let data = try? Data(contentsOf: path.appendingPathComponent("manifest.json")),
                          let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: data), manifest.revision == active,
                          let assets = try? PackageAssetStore.load(directory: path) else { continue }
                    applied = DashboardRevisionRecord(manifest: manifest, files: assets.assets.filter { $0.key != "manifest.json" }.mapValues(\.data), createdAt: Date(), packageDirectory: path)
                    break
                }
            }
            let assets = applied.flatMap { try? PackageAssetStore.load(directory: $0.packageDirectory) }
                ?? (active == StoredRevision.offlineFixture.revision ? try? PackageAssetStore.bundledOfflineFixture() : nil)
            Task { @MainActor in
                guard self.selection == device.id, self.section == "Devices" else { return }
                self.record = applied; self.preview = assets; self.previewIsApplied = true; self.previewKey = UUID()
                if let applied { self.selectedScreen = applied.manifest.dashboardId; self.orientation = DeviceOrientation(rawValue: applied.manifest.target.orientation) ?? .portrait }
            }
        }
    }
    func switchSection() { select(section == "Devices" ? devices.first?.id ?? nearby.first?.id : screens.first?.dashboardId) }
    func chooseScreen(_ id: String) { previewIsApplied = false; selectedScreen = id; loadPreview(id) }
    func loadPreview(_ id: String) {
        guard let service else { return }
        queue.async {
            let result = Result { () -> (DashboardRevisionRecord, PackageAssetStore) in
                let record = try service.getDashboard(dashboardId: id, revision: nil)
                var assets = try PackageAssetStore.load(directory: record.packageDirectory)
                if let entry = assets.assets[record.manifest.entrypoint] { assets.assets["index.html"] = entry }
                return (record, assets)
            }
            Task { @MainActor in
                guard self.selectedScreen == id else { return }
                switch result {
                case .success(let (record, assets)):
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
            self.pairing = result
            self.pairingTimer?.invalidate()
            self.pairingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollPairing() }
            }
        }
    }
    private func pollPairing() {
        guard let pairing, let service, !pairingPollInFlight else { return }
        pairingPollInFlight = true
        queue.async {
            let result = Result { try service.devices.confirmPairing(deviceId: pairing.deviceId) }
            Task { @MainActor in
                self.pairingPollInFlight = false
                guard self.pairing?.deviceId == pairing.deviceId else { return }
                switch result {
                case .success(let record):
                    self.pairingTimer?.invalidate(); self.pairingTimer = nil; self.pairing = nil
                    self.devices.removeAll { $0.id == record.id }; self.devices.append(record)
                    self.select(record.id); self.refresh()
                    self.notice = "Paired. Choose a screen to put on this device."
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
    }
    func addManual(host: String, port: String) {
        guard let host = WorkbenchSidebar.normalizeHost(host), let port = WorkbenchSidebar.parsePort(port) else { error = WorkbenchCopy.invalidAddress; return }
        let ad = service?.devices.addManual(host: host, port: port)
        sheet = nil; refresh(); if let ad { selection = ad.deviceId }
    }
    func renameDevice(_ raw: String) {
        guard let device, let name = DeviceDisplayName.sanitize(raw) else { return }
        run({ try $0.devices.directory.update(device.id) { $0.displayName = name; $0.device.profile.name = name } }) { record in
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
            self.notice = "Device forgotten. To pair it with a different Mac, hold two fingers on its screen for 10 seconds, then tap Unlink."
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
        guard let device, let record else { return }
        let orientation = orientation
        run({ service in
            let prepared = try ScreenPackagePreparation.prepare(record, for: device.device.profile, orientation: orientation, root: service.store.root)
            let outcome = try service.ship(record: prepared, deviceId: device.id, deploymentId: nil)
            guard outcome.phase == .active else {
                throw ControllerError.validationFailed(detail: outcome.error == "targetMismatch" ? "This phone build does not support changing orientation yet. Apply in its current orientation, or install the updated iPhone app." : outcome.error ?? "The device could not activate this screen. Its current screen is unchanged.")
            }
            return (outcome, prepared.packageDirectory.path)
        }) { (_, path) in
            self.appliedSourceRevisions[device.id] = record.manifest.revision
            self.appliedPackagePaths[device.id] = path
            self.appliedScreens[device.id] = record.manifest.dashboardId
            self.appliedOrientations[device.id] = orientation.rawValue
            self.persistPreferences(); self.notice = "\(record.manifest.name) applied to \(self.title)."
        }
    }
    private func persistPreferences() {
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
