import Foundation
import SwiftUI
import ScreenpunkCore
import ScreenpunkApple
import ScreenpunkController

/// A Mac draft retains the revision it was based on. Reconnecting cannot turn
/// that draft into an unconditional write over device-local edits.
private struct MacSettingsDraft: Codable {
    var baseRevision: String?
    var value: DeviceSettings
}

@MainActor
final class MacDeviceSettingsModel: ObservableObject {
    let deviceID: String
    let deviceName: String
    @Published var value: DeviceSettings
    @Published private(set) var snapshot: DeviceSettingsSnapshot?
    @Published private(set) var manifest: DashboardManifest?
    @Published private(set) var busy = false
    @Published private(set) var reachable = false
    @Published private(set) var error: String?
    @Published private(set) var savedDraft = false
    @Published private(set) var conflict = false
    private var baseRevision: String?
    private var baseline: DeviceSettings
    private let service: ControllerService
    private let device: PairedDeviceRecord
    private let queue = DispatchQueue(label: "xyz.screenpunk.device-settings", qos: .userInitiated)
    private var preferenceKey: String { "device-settings-draft.\(deviceID)" }
    var hasChanges: Bool { value != baseline || savedDraft }
    var valid: Bool { (try? value.validate()) != nil }
    var canApply: Bool { valid && !busy && !conflict && baseRevision != nil && reachable }
    var status: String {
        if conflict { return "Device settings changed. Your draft is preserved; review the current device values before editing again." }
        if savedDraft || value != baseline { return "Pending on this Mac · not applied to the device" }
        guard let snapshot else { return "Device settings have not been read yet" }
        if !reachable { return "Device unreachable · showing last known saved settings" }
        return snapshot.isApplied ? "Confirmed applied by the active device" : "Saved on device · awaiting application by the active device"
    }

    init(device: PairedDeviceRecord, service: ControllerService, package: PackageAssetStore?) {
        self.device = device; deviceID = device.id; self.service = service
        deviceName = DeviceDisplayName.label(name: device.displayName ?? device.device.profile.name, deviceId: device.id, fallback: "Device")
        snapshot = device.settingsSnapshot
        baseline = device.settingsSnapshot?.value ?? .init()
        let key = "device-settings-draft.\(device.id)"
        let draft = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(MacSettingsDraft.self, from: $0) }
        value = draft?.value ?? baseline
        baseRevision = draft == nil ? device.settingsSnapshot?.revision : draft?.baseRevision
        savedDraft = draft != nil
        if let data = package?.assets["manifest.json"]?.data { manifest = try? JSONDecoder().decode(DashboardManifest.self, from: data) }
    }

    func refresh() {
        guard !busy else { return }
        busy = true; error = nil
        let id = deviceID, device = device, service = service
        queue.async {
            let result = Result { try service.devices.fetchDeviceSettings(deviceId: id) }
            let current = (try? service.devices.device(id, probe: true)) ?? device
            let manifest = Self.installedManifest(service: service, device: current)
            Task { @MainActor in
                self.busy = false
                // Never expose options from a newer unpublished draft or a different screen.
                self.manifest = manifest
                switch result {
                case .success(let snapshot):
                    self.reachable = true
                    if self.hasChanges {
                        self.conflict = self.baseRevision != snapshot.revision
                    } else {
                        self.value = snapshot.value; self.baseline = snapshot.value
                        self.baseRevision = snapshot.revision; self.conflict = false
                    }
                    self.snapshot = snapshot
                case .failure(let error):
                    self.reachable = false
                    self.error = "Could not read settings from the device. Your Mac draft is preserved. \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private static func installedManifest(service: ControllerService, device: PairedDeviceRecord) -> DashboardManifest? {
        guard let revision = device.device.activeRevision,
              let dashboardID = device.selectedDashboardId ?? device.device.history.first(where: { $0.revision == revision })?.dashboardId else { return nil }
        if let manifest = try? service.getDashboard(dashboardId: dashboardID, revision: revision).manifest { return manifest }
        let folder = service.store.root.appendingPathComponent("device-packages")
        let roots = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var paths = roots.map { $0.appendingPathComponent("dashboards/\(dashboardID)/revisions/\(revision)/manifest.json") }
        if let cached = (UserDefaults.standard.dictionary(forKey: "appliedPackagePaths") as? [String: String])?[device.id] {
            paths.append(URL(fileURLWithPath: cached).appendingPathComponent("manifest.json"))
        }
        for path in paths {
            guard let data = try? Data(contentsOf: path), let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: data),
                  manifest.dashboardId == dashboardID, manifest.revision == revision else { continue }
            return manifest
        }
        return nil
    }

    func saveDraft() {
        do {
            try value.validate()
            let data = try JSONEncoder().encode(MacSettingsDraft(baseRevision: baseRevision, value: value))
            UserDefaults.standard.set(data, forKey: preferenceKey)
            savedDraft = true; error = nil
        } catch { self.error = "Check the schedule times and brightness levels before saving." }
    }

    func useDeviceValues() {
        guard let snapshot, reachable else { return }
        value = snapshot.value; baseline = snapshot.value; baseRevision = snapshot.revision
        savedDraft = false; conflict = false; error = nil
        UserDefaults.standard.removeObject(forKey: preferenceKey)
    }

    func apply() {
        guard canApply, let baseRevision else { return }
        saveDraft()
        let update = DeviceSettingsUpdate(expectedRevision: baseRevision, value: value)
        busy = true; error = nil
        let service = service, deviceID = deviceID
        queue.async {
            let result = Result { try service.devices.updateDeviceSettings(deviceId: deviceID, update: update) }
            Task { @MainActor in
                self.busy = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot; self.baseline = snapshot.value; self.value = snapshot.value
                    self.baseRevision = snapshot.revision; self.reachable = true
                    self.savedDraft = false; self.conflict = false
                    UserDefaults.standard.removeObject(forKey: self.preferenceKey)
                    self.refresh()
                case .failure(let error):
                    self.error = "Settings were not confirmed. Your Mac draft is preserved. Refresh to check for changes on the device. \(error.localizedDescription)"
                    // Never automatically retry a write: it might have succeeded before a connection broke.
                    self.reachable = false
                }
            }
        }
    }
}

struct MacDeviceSettingsSheet: View {
    @ObservedObject var editor: MacDeviceSettingsModel
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(editor.deviceName) Settings").font(.title2.weight(.semibold))
                    Text("Settings for this device").foregroundStyle(.secondary)
                }
                Spacer()
                if editor.busy { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 24).padding(.top, 24)
            Text(editor.status).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24)
            DeviceSettingsEditor(settings: $editor.value, manifest: editor.manifest)
                .disabled(editor.busy || editor.conflict)
            if let error = editor.error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 24) }
            HStack {
                Button("Refresh from Device") { editor.refresh() }.disabled(editor.busy)
                if editor.conflict { Button("Use Device Values") { editor.useDeviceValues() }.disabled(!editor.reachable || editor.busy) }
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save Draft") { editor.saveDraft() }.disabled(!editor.valid || editor.busy)
                Button("Apply to Device") { editor.apply() }.keyboardShortcut(.defaultAction).disabled(!editor.canApply)
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(width: 660, height: 710).interactiveDismissDisabled(editor.busy)
            .task { editor.refresh() }
    }
}
