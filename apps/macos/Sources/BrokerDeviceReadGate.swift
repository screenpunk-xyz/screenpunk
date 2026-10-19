import Foundation

/// Owns the selected device and the newest request of each independent kind.
/// Responses from a previous selection or an older same-device request cannot
/// publish into the current device card.
struct BrokerDeviceReadGate {
    enum Kind { case status, settings, inventory }
    struct Ticket {
        let id: UUID
        let deviceId: String
        let kind: Kind
    }

    private(set) var selectedDeviceId: String?
    private var statusRequest = UUID()
    private var settingsRequest = UUID()
    private var inventoryRequest = UUID()

    mutating func select(_ id: String?) {
        selectedDeviceId = id
        statusRequest = UUID(); settingsRequest = UUID(); inventoryRequest = UUID()
    }

    mutating func begin(_ kind: Kind) -> Ticket? {
        guard let selectedDeviceId else { return nil }
        let id = UUID()
        switch kind {
        case .status: statusRequest = id
        case .settings: settingsRequest = id
        case .inventory: inventoryRequest = id
        }
        return Ticket(id: id, deviceId: selectedDeviceId, kind: kind)
    }

    func accepts(_ ticket: Ticket) -> Bool {
        guard selectedDeviceId == ticket.deviceId else { return false }
        switch ticket.kind {
        case .status: return statusRequest == ticket.id
        case .settings: return settingsRequest == ticket.id
        case .inventory: return inventoryRequest == ticket.id
        }
    }
}
