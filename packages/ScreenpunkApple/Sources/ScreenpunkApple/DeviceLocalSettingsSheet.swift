import SwiftUI
import ScreenpunkCore

#if canImport(Network) && canImport(Security)
/// Device-local edits use the same revision check as remote Mac edits.
struct DeviceLocalSettingsSheet: View {
    @ObservedObject var host: DeviceLANHost
    @Environment(\.dismiss) private var dismiss
    @State private var value: DeviceSettings
    @State private var base: DeviceSettingsSnapshot?
    @State private var message: String?
    @State private var saveFailed = false
    @State private var showGoogleTV = false
    var embedded = false

    init(host: DeviceLANHost, embedded: Bool = false) {
        self.embedded = embedded
        self.host = host
        _value = State(initialValue: host.settingsSnapshot?.value ?? .init())
        _base = State(initialValue: host.settingsSnapshot)
    }

    private var manifest: DashboardManifest? {
        guard let data = host.activePackage?.assets["manifest.json"]?.data else { return nil }
        return try? JSONDecoder().decode(DashboardManifest.self, from: data)
    }
    private var conflict: Bool { base?.revision != host.settingsSnapshot?.revision }
    private var valid: Bool { (try? value.validate()) != nil }

    var body: some View {
        if embedded { editor } else { NavigationStack { editor } }
    }
    private var editor: some View {
            VStack(spacing: 0) {
                if conflict {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Settings changed on another editor. Review the saved device values before editing again.")
                        Button("Use Device Values") {
                            base = host.settingsSnapshot
                            value = base?.value ?? .init()
                            message = nil; saveFailed = false
                        }
                    }.font(.callout).padding()
                }
                if !embedded { Button("Google TV Connection") { showGoogleTV = true }.padding() }
                DeviceSettingsEditor(settings: $value, manifest: manifest).disabled(conflict)
                if let message { Text(message).font(.callout).foregroundStyle(saveFailed ? Color.red : Color.secondary).padding() }
                if let snapshot = host.settingsSnapshot {
                    Text(snapshot.isApplied ? "Applied while Screenpunk is active" : "Saved on this device · waiting for runtime application")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom)
                }
            }
            .sheet(isPresented: $showGoogleTV) { GoogleTVConnectionSheet() }
            .navigationTitle(embedded ? "Display and behavior" : "\(host.runtime.profile.name) Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { if !embedded { Button("Close") { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let base else { return }
                        do {
                            let snapshot = try host.saveSettings(.init(expectedRevision: base.revision, value: value))
                            self.base = snapshot; self.value = snapshot.value
                            message = "Saved on this device. The Mac does not need to be connected."
                            saveFailed = false
                        } catch {
                            message = "Could not save settings. \(String(describing: error))"
                            saveFailed = true
                        }
                    }.disabled(base == nil || conflict || !valid)
                }
            }
    }
}
#endif
