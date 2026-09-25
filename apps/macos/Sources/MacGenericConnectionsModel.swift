import Foundation
import SwiftUI
import ScreenpunkCore
import ScreenpunkController
import ScreenpunkApple

@MainActor
final class MacGenericConnectionsModel: ObservableObject {
    struct Connection: Identifiable {
        var id: String
        var entries: [DeviceConnectionEntry]
        var first: DeviceConnectionEntry { entries[0] }
        var screens: String { Array(Set(entries.map { $0.screen.name })).sorted().joined(separator: " · ") }
    }
    @Published private(set) var connections: [Connection] = []
    @Published var selected: String?
    @Published private(set) var deviceName = "Device"
    @Published private(set) var busy = false
    @Published private(set) var online = false
    @Published private(set) var message: String?
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var diagnostics: [String: String] = [:]
    @Published var configuring: Connection?
    @Published var address = ""
    @Published var token = ""
    @Published var saveError: String?
    private var service: ControllerService?
    private var deviceID = ""
    private let queue = DispatchQueue(label: "xyz.screenpunk.connection-management", qos: .userInitiated)

    var current: Connection? { connections.first { $0.id == selected } }
    func load(model: MacWorkbenchModel, deviceID: String) async {
        guard service == nil else { return }
        service = model.service; self.deviceID = deviceID
        if let record = model.devices.first(where: { $0.id == deviceID }) {
            deviceName = DeviceDisplayName.label(name: record.displayName ?? record.device.profile.name, deviceId: deviceID, fallback: "Device")
        }
        await refresh()
    }
    private func accept(_ inventory: DeviceConnectionInventory) {
        let groups = Dictionary(grouping: inventory.entries) { entry in
            if let source = entry.publicConnection?.publicHTTP { return "public|\(source.origin)|\(source.userAgent)" }
            // Credentials may differ between screens even when their server addresses match.
            return "\(entry.kind)|\(entry.screen.dashboardId)|\(entry.id)"
        }
        connections = groups.map { Connection(id: $0.key, entries: $0.value) }.sorted { $0.first.name.localizedStandardCompare($1.first.name) == .orderedAscending }
        if !connections.contains(where: { $0.id == selected }) { selected = connections.first?.id }
        online = true; message = nil
    }
    func refresh() async {
        guard let service, !busy else { return }
        busy = true
        let id = deviceID
        let result: Result<DeviceConnectionInventory, Error> = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Result { try service.devices.connectionInventory(deviceId: id) }) }
        }
        busy = false
        switch result {
        case .success(let inventory): accept(inventory)
        case .failure(let error):
            online = false
            message = (error as? LocalNetworkAccessFailure)?.errorDescription
                ?? (error as? ControllerError)?.detail ?? "Cannot load connections. Connect the iPad and ensure Screenpunk is up to date."
            if !connections.isEmpty { message = (message ?? "iPad unavailable.") + " Showing last known connections." }
        }
    }
    func configure(_ connection: Connection) {
        address = connection.first.origin; token = ""; saveError = nil; configuring = connection
    }
    func save() async {
        guard online, !busy, let connection = configuring, let service else { return }
        let origin: String
        do {
            var components = URLComponents(url: try HomeAssistantClient.baseURL(address), resolvingAgainstBaseURL: false)!
            components.path = ""; origin = components.string!
            if origin != connection.first.origin && token.isEmpty {
                saveError = "Enter a new token when changing the server address."; return
            }
        } catch { saveError = error.localizedDescription; return }
        busy = true; saveError = nil
        let update = DeviceHomeAssistantUpdate(entries: connection.entries, origin: origin, token: token.isEmpty ? nil : token)
        let id = deviceID
        let result: Result<DeviceConnectionInventory, Error> = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Result { try service.devices.updateHomeConnection(deviceId: id, update: update) }) }
        }
        busy = false; token = ""
        switch result {
        case .success(let inventory):
            accept(inventory); statuses[connection.id] = nil; diagnostics[connection.id] = nil; configuring = nil
        case .failure:
            saveError = "The iPad did not confirm the update. Nothing is queued. Reconnect and reload before trying again."
            online = false
        }
    }
    func test(_ connection: Connection) async {
        guard statuses[connection.id] != "Testing" else { return }
        statuses[connection.id] = "Testing"
        do {
            if let declaration = connection.first.publicConnection, let source = declaration.publicHTTP {
                guard let operation = source.operations.first(where: { $0.parameters.isEmpty }) else {
                    statuses[connection.id] = "Test needs parameters"
                    diagnostics[connection.id] = "This source requires values supplied by its screen. No request was sent."; return
                }
                let provisioning = try PublicReadProvisioning(dashboardId: connection.first.screen.dashboardId, revision: connection.first.screen.revision, connections: [declaration])
                try provisioning.validate()
                let runtime = try PublicReadRuntime(provisioning: provisioning)
                let result = try await runtime.request(alias: declaration.alias, operation: operation.name, parameters: [:])
                guard result.state == "fresh" else { throw ConnectionFailure.deviceOffline }
                diagnostics[connection.id] = "\(operation.name) checked from this Mac at \(Date().formatted(date: .omitted, time: .shortened)). This does not test the iPad."
            } else if connection.first.kind == "Service integration" {
                let config = try MacHomeAssistantConnection.provisioning(dashboardId: connection.first.screen.dashboardId, revision: connection.first.screen.revision, provisioningId: UUID().uuidString)
                guard config.origin == connection.first.origin, config.connectionId == connection.first.id else {
                    statuses[connection.id] = "Test unavailable"
                    diagnostics[connection.id] = "This Mac has no matching Home Assistant credentials. Device credentials stay on the iPad."; return
                }
                try await HomeAssistantClient.verify(baseURL: HomeAssistantClient.baseURL(config.origin), token: config.token)
                diagnostics[connection.id] = "Checked from this Mac using its saved token at \(Date().formatted(date: .omitted, time: .shortened)). The iPad may have a different token."
            } else {
                statuses[connection.id] = "Test unavailable"
                diagnostics[connection.id] = "Custom connections cannot be tested from this Mac without their device credentials and request parameters."; return
            }
            statuses[connection.id] = "Source reachable"
        } catch {
            statuses[connection.id] = "Test failed"
            diagnostics[connection.id] = "The source could not be verified from this Mac. Check its address, network access, and authentication."
        }
    }
}
