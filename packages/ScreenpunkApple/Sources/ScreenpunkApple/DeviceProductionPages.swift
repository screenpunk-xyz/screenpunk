#if os(iOS)
import SwiftUI
import ScreenpunkCore

@MainActor
struct DeviceProductionGeneral: View {
    @ObservedObject var host: DeviceLANHost
    var connect: () -> Void = {}
    @State private var disconnecting = false
    @State private var failure: String?
    var body: some View {
        DeviceLocalSettingsSheet(host: host, embedded: true, generalConnection: .init(
            title: host.runtime.isPaired ? "Local" : "Disconnected",
            detail: host.runtime.isPaired ? "Connected to Screenpunk on your Mac" : "Screens on this device remain available offline.",
            actionTitle: host.runtime.isPaired ? "Disconnect" : "Connect",
            action: host.runtime.isPaired ? { disconnecting = true } : connect))
        .confirmationDialog("Disconnect this device?", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("Keep screens on this device") { disconnect(keep: true) }
            Button("Remove screens from this device", role: .destructive) { disconnect(keep: false) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Choose whether your installed screens stay available offline.") }
        .alert("Could not disconnect", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func disconnect(keep: Bool) {
        do { try host.disconnect(keepScreens: keep) } catch { failure = "The change could not be saved. Unlock this device and try again." }
    }
}

@MainActor
struct DeviceProductionScreens: View {
    @ObservedObject var host: DeviceLANHost
    let opened: () -> Void
    @State private var removal: String?
    @State private var removeAll = false
    @State private var failure: String?
    var body: some View {
        DeviceScreensView(installed: items, available: [], catalog: .unavailable(message: "The Cloud screen catalog is not available in this version."),
            destination: { $0.id }, open: { id in host.selectScreen(id); if host.errorMessage == nil { opened() } else { failure = host.errorMessage } },
            remove: { removal = $0 }, removeAll: { removeAll = true }, retryCatalog: {})
        .confirmationDialog("Remove this screen?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove screen", role: .destructive) { if let removal { perform { try host.removeScreen(removal) } }; removal = nil }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: { Text("This removes the installed copy from this device.") }
        .confirmationDialog("Remove all screens?", isPresented: $removeAll, titleVisibility: .visible) {
            Button("Remove all screens", role: .destructive) { perform { try host.removeAllScreens() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Could not update screens", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private var items: [DeviceScreensItem] {
        let manifests = host.server?.installedManifests ?? []
        let order = host.screenSet?.screens.map { $0.entry.dashboardId } ?? []
        return manifests.sorted { (order.firstIndex(of: $0.dashboardId) ?? Int.max) < (order.firstIndex(of: $1.dashboardId) ?? Int.max) }.map {
            .init(id: $0.dashboardId, title: $0.name, subtitle: $0.dashboardId == host.screenSet?.selectedDashboardId ? "Current screen" : "Installed on this device")
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action(); if !host.runtime.isPaired && (host.server?.installedManifests.isEmpty ?? true) { opened() } } catch { failure = "The change could not be saved. Unlock this device and try again." } }
}
#endif
