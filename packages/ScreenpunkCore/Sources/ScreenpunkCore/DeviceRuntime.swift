import Foundation

/// Phone-side pairing and package slots. Failed transfer keeps `activeRevision`.
public struct DeviceRuntime: Sendable, Equatable {
    public var identity: PairingIdentity
    public var pairing: DevicePairingState
    public var profile: DeviceProfile
    public var advertisement: AdvertisedDevice
    public var activeRevision: String?
    public var stagedRevision: String?
    public var lastDeployment: DeploymentRecord?

    public init(
        identity: PairingIdentity,
        profile: DeviceProfile,
        advertisement: AdvertisedDevice,
        pairing: DevicePairingState = DevicePairingState()
    ) {
        self.identity = identity
        self.pairing = pairing
        self.profile = profile
        self.advertisement = advertisement
    }

    public var isPaired: Bool { pairing.owner != nil }
    public var pairingCode: String? { pairing.session?.expectedCode }

    public mutating func advertise(on hub: LoopbackDiscovery) {
        hub.advertise(advertisement)
    }

    public mutating func beginPairing(
        transcript: PairingTranscript,
        expectedCode: String,
        candidateOwner: PairingIdentity,
        clock: PairingClock
    ) throws {
        try pairing.begin(
            transcript: transcript,
            expectedCode: expectedCode,
            candidateOwner: candidateOwner,
            clock: clock
        )
    }

    public mutating func confirmPairing(
        code: String,
        presentedOwner: PairingIdentity,
        clock: PairingClock
    ) throws {
        try pairing.confirm(code: code, presentedOwner: presentedOwner, clock: clock)
    }

    public mutating func receiveDeployment(
        _ record: DeploymentRecord,
        revision: StoredRevision,
        failAt: DeploymentPhase? = nil
    ) throws -> DeploymentRecord {
        guard pairing.owner != nil else { throw TransferFailure.notPaired }
        if let last = lastDeployment, last.deploymentId == record.deploymentId {
            return last
        }
        var next = record
        next.phase = .queued
        if failAt == .queued {
            return fail(next, error: TransferFailure.interrupted)
        }
        next.phase = .transferring
        stagedRevision = revision.revision
        if failAt == .transferring {
            return fail(next, error: TransferFailure.interrupted)
        }
        next.phase = .validating
        // A saved screen can use either orientation of this device's viewport.
        // Commit the orientation only after activation, so a failure is atomic.
        var targetProfile = profile
        targetProfile.apply(orientation: revision.orientation)
        if failAt == .validating || revision.matches(profile: targetProfile) == false {
            return fail(next, error: TransferFailure.targetMismatch)
        }
        if failAt == .activating {
            next.phase = .activating
            return fail(next, error: TransferFailure.interrupted)
        }
        next.phase = .activating
        profile = targetProfile
        activeRevision = revision.revision
        stagedRevision = nil
        next.phase = .active
        lastDeployment = next
        return next
    }

    public mutating func unlink() {
        pairing = DevicePairingState()
        activeRevision = nil
        stagedRevision = nil
        lastDeployment = nil
    }

    private mutating func fail(_ record: DeploymentRecord, error: TransferFailure) -> DeploymentRecord {
        stagedRevision = nil
        var failed = record
        failed.phase = .failed
        failed.error = error.rawValue
        lastDeployment = failed
        return failed
    }
}
