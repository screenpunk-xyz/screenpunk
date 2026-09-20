import Foundation
import SwiftUI
import ScreenpunkCore
import ScreenpunkController

/// Ephemeral native consent state. Neither proposed grants nor credentials are saved on the Mac.
@MainActor
final class MacGenericConnectionsModel: ObservableObject {
    struct Approval: Identifiable {
        var id: UUID { grant.id }
        var grant: ConnectionGrant
        var placement: ConnectionAuthPlacement = .none
        var fieldName = ""
        var secret = ""
        var entry: ConnectionProvisioning.Entry {
            .init(grant: grant, binding: .init(authRef: grant.authRef, placement: placement,
                  fieldName: placement == .header || placement == .query ? fieldName : nil),
                  secret: placement == .none ? nil : Data(secret.utf8))
        }
    }
    @Published var proposal = ""
    @Published var approvals: [Approval] = []
    @Published private(set) var deviceName = "Device"
    @Published private(set) var dashboardID: String?
    @Published private(set) var revision: String?
    @Published private(set) var busy = false
    @Published private(set) var reviewed = false
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    private var service: ControllerService?
    private var deviceID = ""
    private let queue = DispatchQueue(label: "xyz.screenpunk.connection-approval", qos: .userInitiated)

    var canApprove: Bool {
        guard reviewed, !busy, let configuration else { return false }
        return (try? configuration.validate()) != nil
    }
    private var configuration: ConnectionProvisioning? {
        guard let dashboardID, let revision else { return nil }
        return .init(dashboardId: dashboardID, revision: revision, entries: approvals.map(\.entry))
    }

    func load(model: MacWorkbenchModel, deviceID: String) {
        guard service == nil else { return }
        self.service = model.service; self.deviceID = deviceID
        if let record = model.devices.first(where: { $0.id == deviceID }) {
            deviceName = DeviceDisplayName.label(name: record.displayName ?? record.device.profile.name, deviceId: deviceID, fallback: "Device")
        }
        refreshTarget()
    }

    func refreshTarget() {
        guard let service, !busy else { return }
        busy = true; dashboardID = nil; revision = nil; message = nil
        let deviceID = self.deviceID
        queue.async {
            let result = Result { try service.devices.device(deviceID, probe: true) }
            Task { @MainActor in
                self.busy = false
                guard case .success(let record) = result, record.device.reachable,
                      let revision = record.device.activeRevision,
                      let dashboard = record.selectedDashboardId
                        ?? record.device.history.first(where: { $0.revision == revision })?.dashboardId else {
                    self.failed = true
                    self.message = "The current dashboard could not be confirmed. Open Screenpunk on the paired device, apply a dashboard, then refresh. Nothing is queued."
                    return
                }
                self.dashboardID = dashboard; self.revision = revision; self.failed = false
            }
        }
    }

    func review() {
        do {
            guard let data = proposal.data(using: .utf8), data.count <= 128 * 1024 else { throw ConnectionFailure.sizeLimit }
            let grants: [ConnectionGrant]
            if proposal.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
                grants = try JSONDecoder().decode([ConnectionGrant].self, from: data)
            } else { grants = [try ConnectionGrantValidator.decode(data)] }
            guard grants.count <= 32, Set(grants.map(\.id)).count == grants.count,
                  Set(grants.map(\.alias)).count == grants.count,
                  Set(grants.map(\.authRef)).count == grants.count else { throw ConnectionFailure.validationFailed }
            for grant in grants { try ConnectionGrantValidator.validate(grant) }
            approvals = grants.map { Approval(grant: $0) }
            reviewed = true; proposal = ""; message = nil; failed = false
        } catch {
            failed = true
            message = "Enter a valid ConnectionGrant object or array (at most 32 distinct grants). Credentials belong in the secure fields after review, never in the JSON."
        }
    }

    func editProposal() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        proposal = (try? encoder.encode(approvals.map(\.grant))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        approvals = []; reviewed = false; message = nil
    }

    func approve() {
        guard canApprove, let service, let configuration else { return }
        busy = true; message = nil
        let deviceID = self.deviceID
        queue.async {
            let result = Result { try service.devices.provisionConnections(deviceId: deviceID, configuration: configuration) }
            Task { @MainActor in
                self.busy = false
                switch result {
                case .success:
                    self.approvals = []; self.reviewed = false; self.proposal = ""; self.failed = false
                    self.message = "Device confirmed these connection permissions were installed. Endpoint connectivity has not been tested. Credentials are stored in the device’s Keychain."
                case .failure:
                    self.failed = true
                    self.message = "Installation was not confirmed. No update is queued. Check that the device is online and still showing this dashboard revision, then refresh and explicitly approve again."
                }
            }
        }
    }
}
