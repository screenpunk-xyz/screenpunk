import Foundation

public struct PairedDevice: Sendable, Equatable, Codable, Identifiable {
    public var id: String { profile.deviceId }
    public var profile: DeviceProfile
    public var owner: PairingIdentity
    public var reachable: Bool
    public var activeRevision: String?
    public var draftRevision: String?
    public var history: [StoredRevision]
    public var deployments: [DeploymentRecord]
    public var pairingCode: String?

    public init(
        profile: DeviceProfile,
        owner: PairingIdentity,
        reachable: Bool = true,
        activeRevision: String? = nil,
        draftRevision: String? = nil,
        history: [StoredRevision] = [],
        deployments: [DeploymentRecord] = [],
        pairingCode: String? = nil
    ) {
        self.profile = profile
        self.owner = owner
        self.reachable = reachable
        self.activeRevision = activeRevision
        self.draftRevision = draftRevision
        self.history = history
        self.deployments = deployments
        self.pairingCode = pairingCode
    }
}

/// Mac workbench state: discovery, one-owner pairing, preview, deploy, history.
public struct WorkbenchSession: Sendable, Equatable {
    public var controllerIdentity: PairingIdentity
    public var advertisements: [AdvertisedDevice]
    public var devices: [PairedDevice]
    public var drafts: [StoredRevision]
    public var selectedDeviceId: String?
    public var selectedRevision: String?
    public var lastForgetMessage: String?

    public init(controllerIdentity: PairingIdentity) {
        self.controllerIdentity = controllerIdentity
        self.advertisements = []
        self.devices = []
        self.drafts = []
    }

    public var livePreviewLabel: String { WorkbenchCopy.livePreview }

    public var selectedDevice: PairedDevice? {
        devices.first { $0.profile.deviceId == selectedDeviceId }
    }

    public var selectedDraft: StoredRevision? {
        let revision = selectedRevision
        return drafts.first { $0.revision == revision }
            ?? selectedDevice?.history.first { $0.revision == revision }
    }

    public mutating func refreshDiscovery(_ hub: LoopbackDiscovery) {
        advertisements = hub.browse()
    }

    public mutating func addManual(host: String, port: Int, hub: LoopbackDiscovery) {
        _ = hub.addManual(host: host, port: port)
        refreshDiscovery(hub)
    }

    public mutating func importDraft(_ revision: StoredRevision) {
        if drafts.contains(where: { $0.revision == revision.revision }) == false {
            drafts.append(revision)
        }
        selectedRevision = revision.revision
    }

    public mutating func beginPairing(
        advertised: AdvertisedDevice,
        phone: inout DeviceRuntime,
        expectedCode: String,
        clock: PairingClock,
        nonce: [UInt8]? = nil
    ) throws {
        let transcript = PairingTranscript(
            devicePublicKey: phone.identity.publicKey,
            controllerPublicKey: controllerIdentity.publicKey,
            sessionNonce: PairingIdentityFactory.nonce(nonce)
        )
        try phone.beginPairing(
            transcript: transcript,
            expectedCode: expectedCode,
            candidateOwner: controllerIdentity,
            clock: clock
        )
        var pending = PairedDevice(
            profile: phone.profile,
            owner: controllerIdentity,
            pairingCode: expectedCode
        )
        pending.profile.deviceId = advertised.deviceId
        phone.profile.deviceId = advertised.deviceId
        devices.removeAll { $0.profile.deviceId == advertised.deviceId }
        devices.append(pending)
        selectedDeviceId = advertised.deviceId
    }

    public mutating func confirmPairing(
        deviceId: String,
        code: String,
        phone: inout DeviceRuntime,
        clock: PairingClock
    ) throws {
        try phone.confirmPairing(code: code, presentedOwner: controllerIdentity, clock: clock)
        guard let index = devices.firstIndex(where: { $0.profile.deviceId == deviceId }) else {
            throw TransferFailure.notPaired
        }
        devices[index].owner = controllerIdentity
        devices[index].pairingCode = nil
        devices[index].reachable = true
    }

    public mutating func setOrientation(_ orientation: DeviceOrientation, deviceId: String) {
        guard let index = devices.firstIndex(where: { $0.profile.deviceId == deviceId }) else { return }
        devices[index].profile.apply(orientation: orientation)
    }

    @discardableResult
    public mutating func deploy(
        deploymentId: String,
        revision: StoredRevision,
        deviceId: String,
        phone: inout DeviceRuntime,
        failAt: DeploymentPhase? = nil
    ) throws -> DeploymentRecord {
        guard let index = devices.firstIndex(where: { $0.profile.deviceId == deviceId }) else {
            throw TransferFailure.notPaired
        }
        if devices[index].owner != controllerIdentity {
            throw TransferFailure.notPaired
        }
        if devices[index].reachable == false {
            throw TransferFailure.deviceOffline
        }
        if let existing = devices[index].deployments.first(where: { $0.deploymentId == deploymentId }) {
            return existing
        }
        phone.profile = devices[index].profile
        let queued = DeploymentRecord(
            deploymentId: deploymentId,
            revision: revision.revision,
            dashboardId: revision.dashboardId,
            deviceId: deviceId,
            phase: .queued
        )
        let outcome = try phone.receiveDeployment(queued, revision: revision, failAt: failAt)
        devices[index].deployments.append(outcome)
        if outcome.phase == .active {
            devices[index].activeRevision = revision.revision
            devices[index].draftRevision = nil
            if devices[index].history.contains(where: { $0.revision == revision.revision }) == false {
                devices[index].history.append(revision)
            }
        }
        return outcome
    }

    @discardableResult
    public mutating func rollback(
        to revision: StoredRevision,
        deviceId: String,
        phone: inout DeviceRuntime,
        deploymentId: String
    ) throws -> DeploymentRecord {
        try deploy(
            deploymentId: deploymentId,
            revision: revision,
            deviceId: deviceId,
            phone: &phone
        )
    }

    public mutating func applyRemoteDeployment(
        _ outcome: DeploymentRecord,
        revision: StoredRevision,
        deviceId: String
    ) {
        guard let index = devices.firstIndex(where: { $0.profile.deviceId == deviceId }) else { return }
        if devices[index].deployments.contains(where: { $0.deploymentId == outcome.deploymentId }) == false {
            devices[index].deployments.append(outcome)
        }
        if outcome.phase == .active {
            devices[index].activeRevision = revision.revision
            devices[index].draftRevision = nil
            if devices[index].history.contains(where: { $0.revision == revision.revision }) == false {
                devices[index].history.append(revision)
            }
        }
    }

    public mutating func recordPairedDevice(profile: DeviceProfile, pairingCode: String?) {
        var device = PairedDevice(profile: profile, owner: controllerIdentity, pairingCode: pairingCode)
        devices.removeAll { $0.profile.deviceId == profile.deviceId }
        devices.append(device)
        selectedDeviceId = profile.deviceId
    }

    public mutating func markPaired(deviceId: String) {
        guard let index = devices.firstIndex(where: { $0.profile.deviceId == deviceId }) else { return }
        devices[index].pairingCode = nil
        devices[index].reachable = true
    }

    public mutating func forgetUnreachable(deviceId: String) {
        guard let index = devices.firstIndex(where: { $0.profile.deviceId == deviceId }) else { return }
        devices.remove(at: index)
        if selectedDeviceId == deviceId {
            selectedDeviceId = devices.first?.profile.deviceId
        }
        lastForgetMessage = WorkbenchCopy.forgetUnreachable
    }
}
