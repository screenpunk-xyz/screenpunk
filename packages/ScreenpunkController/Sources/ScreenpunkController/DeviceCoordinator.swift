import Foundation
import ScreenpunkCore

public struct PairingRequestResult: Sendable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var host: String
    public var port: Int
    public var code: String
    public var devicePinHex: String
    public var startedAt: Date
    public var expiresAt: Date
    public var rePairing: Bool
}

public struct PendingPairingSummary: Sendable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var host: String
    public var port: Int
    public var expiresAt: Date
}

/// Pairing, deploy, and device bookkeeping for the local controller. Talks to
/// devices only through `DeviceLink`; the Mac never relays dashboard traffic.
public final class DeviceCoordinator: @unchecked Sendable {
    public let directory: DeviceDirectory
    public let hub: LoopbackDiscovery
    public private(set) var linkFactory: DeviceLinkFactory?
    private var pending: [String: PendingPairing] = [:]
    private var links: [String: DeviceLink] = [:]
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    private struct PendingPairing {
        var deviceId: String
        var deviceName: String
        var host: String
        var port: Int
        var devicePin: [UInt8]
        var code: String
        var startedAt: Date
        var rePairing: Bool
        var link: DeviceLink
        var profile: DeviceProfile?
    }

    public init(
        directory: DeviceDirectory,
        hub: LoopbackDiscovery = LoopbackDiscovery(),
        linkFactory: DeviceLinkFactory? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.hub = hub
        self.linkFactory = linkFactory
        self.now = now
    }

    public func attach(_ factory: DeviceLinkFactory?) {
        lock.lock()
        linkFactory = factory
        lock.unlock()
    }

    public var transportAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return linkFactory != nil
    }

    public var controllerIdentity: PairingIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return linkFactory?.controllerIdentity
    }

    // MARK: Discovery

    public func discover() -> [AdvertisedDevice] {
        hub.browse()
    }

    @discardableResult
    public func addManual(host: String, port: Int) -> AdvertisedDevice {
        hub.addManual(host: host, port: port)
    }

    public func pendingPairings() -> [PendingPairingSummary] {
        lock.lock()
        defer { lock.unlock() }
        return pending.values
            .map {
                PendingPairingSummary(
                    deviceId: $0.deviceId,
                    deviceName: $0.deviceName,
                    host: $0.host,
                    port: $0.port,
                    expiresAt: $0.startedAt.addingTimeInterval(PairingLimits.expirySeconds)
                )
            }
            .sorted { $0.deviceId < $1.deviceId }
    }

    // MARK: Pairing

    /// Opens the authenticated channel, runs `pair.begin`, and returns the
    /// matching code for the agent to show. Nothing is stored until the device
    /// confirms natively and `confirmPairing` succeeds.
    public func requestPairing(deviceId: String?, host: String?, port: Int?) throws -> PairingRequestResult {
        let target = try resolveTarget(deviceId: deviceId, host: host, port: port)
        let factory = try requireFactory()
        let known = directory.get(target.deviceId)
            ?? directory.list().first { $0.host == target.host && $0.port == Int(target.port) }

        cancelPending(target.deviceId)

        let link = try factory.makeLink()
        do {
            try link.connect(host: target.host, port: target.port, pinnedDevice: known?.devicePin)
        } catch {
            link.cancel()
            throw mapConnect(error)
        }
        do {
            let hello = try link.hello()
            guard hello.protocolMajor == DiscoveryService.protocolMajor else {
                throw ControllerError(
                    code: .unsupportedVersion,
                    detail: "device speaks protocol \(hello.protocolMajor); this controller speaks \(DiscoveryService.protocolMajor)"
                )
            }
            // The link reports the pin observed in the TLS handshake and has
            // already rejected a hello that claims a different identity.
            guard let devicePin = link.devicePin, devicePin.count == PairingLimits.identityByteCount,
                  PeerPin.matches(expected: devicePin, presentedHex: hello.pinHex)
            else {
                throw PairingFailure.identityChanged
            }
            let nonce = PairingIdentityFactory.nonce()
            let begin = try link.beginPairing(nonce: nonce)
            guard PeerPin.matches(expected: devicePin, presentedHex: begin.devicePinHex) else {
                throw PairingFailure.identityChanged
            }
            try verifySAS(
                code: begin.code,
                devicePin: devicePin,
                controllerPin: factory.controllerIdentity.publicKey,
                nonce: nonce
            )
            let started = now()
            let name = DeviceDisplayName.label(name: hello.name, deviceId: hello.deviceId, fallback: "Paired device")
            let resolvedId = hello.deviceId.isEmpty ? target.deviceId : hello.deviceId
            let entry = PendingPairing(
                deviceId: resolvedId,
                deviceName: known?.device.profile.name ?? name,
                host: target.host,
                port: Int(target.port),
                devicePin: devicePin,
                code: begin.code,
                startedAt: started,
                rePairing: known != nil,
                link: link,
                profile: hello.profile
            )
            lock.lock()
            if resolvedId != target.deviceId {
                pending[target.deviceId] = nil
            }
            pending[resolvedId] = entry
            lock.unlock()
            return PairingRequestResult(
                deviceId: resolvedId,
                deviceName: entry.deviceName,
                host: entry.host,
                port: entry.port,
                code: begin.code,
                devicePinHex: PeerPin.hex(devicePin),
                startedAt: started,
                expiresAt: started.addingTimeInterval(PairingLimits.expirySeconds),
                rePairing: known != nil
            )
        } catch {
            link.cancel()
            throw mapPairing(error)
        }
    }

    /// Sends `pair.confirm`. The device only answers `ok` after its owner tapped
    /// Confirm on the device screen, so MCP cannot self-approve.
    public func confirmPairing(deviceId: String) throws -> PairedDeviceRecord {
        let factory = try requireFactory()
        lock.lock()
        let entry = pending[deviceId]
        lock.unlock()
        guard let entry else {
            throw ControllerError.notPaired("no pending pairing for \(deviceId); call request_pairing first")
        }
        if now().timeIntervalSince(entry.startedAt) > PairingLimits.expirySeconds {
            cancelPending(deviceId)
            throw ControllerError.notPaired("expired: the matching code expired after \(Int(PairingLimits.expirySeconds)) seconds; call request_pairing again")
        }
        do {
            try entry.link.confirmPairing(code: entry.code)
        } catch TransferFailure.interrupted {
            throw ControllerError.permissionRequired(
                "device has not confirmed. Ask the user to compare the code on the device screen and tap Confirm there, then call confirm_pairing again."
            )
        } catch {
            if let failure = error as? PairingFailure, failure == .codeMismatch {
                cancelPending(deviceId)
            }
            throw mapPairing(error)
        }

        let pairedAt = now()
        var device = PairedDevice(
            profile: entry.profile ?? DeviceProfile(deviceId: deviceId, name: entry.deviceName),
            owner: factory.controllerIdentity,
            reachable: true
        )
        if let existing = directory.get(deviceId) {
            device = existing.device
            device.owner = factory.controllerIdentity
            device.reachable = true
            device.pairingCode = nil
        }
        let record = PairedDeviceRecord(
            device: device,
            host: entry.host,
            port: entry.port,
            devicePinHex: PeerPin.hex(entry.devicePin),
            pairedAt: pairedAt,
            lastSeenAt: pairedAt
        )
        try directory.upsert(record)
        lock.lock()
        pending[deviceId] = nil
        links[deviceId]?.cancel()
        links[deviceId] = entry.link
        lock.unlock()
        return record
    }

    public func cancelPending(_ deviceId: String) {
        lock.lock()
        let entry = pending.removeValue(forKey: deviceId)
        lock.unlock()
        entry?.link.cancel()
    }

    // MARK: Devices

    public func listDevices() -> [PairedDeviceRecord] {
        directory.list()
    }

    public func device(_ deviceId: String, probe: Bool) throws -> PairedDeviceRecord {
        guard let record = directory.get(deviceId) else {
            throw ControllerError.notPaired("unknown device \(deviceId)")
        }
        guard probe else { return record }
        do {
            let active = try withLink(record) { try $0.queryActive() }
            let seen = now()
            return try directory.update(deviceId) { current in
                current.device.reachable = true
                current.device.activeRevision = active
                current.lastSeenAt = seen
            } ?? record
        } catch {
            return try directory.update(deviceId) { current in
                current.device.reachable = false
            } ?? record
        }
    }

    /// Forget on the Mac only. The device keeps its dashboard and pairing until
    /// its owner performs the two-finger Unlink gesture on the device itself.
    public func forget(deviceId: String) throws -> Bool {
        cancelPending(deviceId)
        lock.lock()
        links.removeValue(forKey: deviceId)?.cancel()
        lock.unlock()
        return try directory.remove(deviceId)
    }

    // MARK: Deploy

    /// Idempotent on `deploymentId`. A failed or interrupted transfer never
    /// changes the stored active revision; the device keeps its current dashboard.
    public func deploy(
        deviceId: String,
        revision: StoredRevision,
        files: [LANFileBlob],
        deploymentId: String
    ) throws -> DeploymentRecord {
        let factory = try requireFactory()
        guard let record = directory.get(deviceId) else {
            throw ControllerError.notPaired("unknown device \(deviceId); pair it first")
        }
        guard record.device.owner == factory.controllerIdentity else {
            throw ControllerError.notPaired("device \(deviceId) is owned by a different controller identity")
        }
        if let existing = record.device.deployments.first(where: { $0.deploymentId == deploymentId }) {
            return existing
        }
        let queued = DeploymentRecord(
            deploymentId: deploymentId,
            revision: revision.revision,
            dashboardId: revision.dashboardId,
            deviceId: deviceId,
            phase: .queued
        )
        let body = LANDeployBody(deployment: queued, revision: revision, files: files)
        let encoded = try LANCodec.encodePayload(body)
        if encoded.utf8.count + 512 > LANProtocolLimits.maxMessageBytes {
            throw ControllerError.validationFailed(
                detail: "package is \(encoded.utf8.count) bytes encoded; LAN transfer accepts at most \(LANProtocolLimits.maxMessageBytes) bytes per deployment"
            )
        }

        let outcome: DeploymentRecord
        do {
            outcome = try withLink(record) { try $0.deploy(body) }
        } catch {
            _ = try? directory.update(deviceId) { $0.device.reachable = false }
            throw mapTransfer(error)
        }
        let seen = now()
        try directory.update(deviceId) { current in
            current.device.reachable = true
            current.lastSeenAt = seen
            if current.device.deployments.contains(where: { $0.deploymentId == outcome.deploymentId }) == false {
                current.device.deployments.append(outcome)
            }
            if outcome.phase == .active {
                current.device.activeRevision = revision.revision
                current.device.draftRevision = nil
                if current.device.history.contains(where: { $0.revision == revision.revision }) == false {
                    current.device.history.append(revision)
                }
            }
        }
        return outcome
    }

    /// Check support before replacing the current screen or transmitting credentials.
    public func requireHomeAssistantSupport(deviceId: String) throws {
        let record = try ownedRecord(deviceId)
        let hello = try withLink(record) { try $0.hello() }
        guard hello.deviceId == deviceId, hello.capabilities?.contains("home-assistant-http-v1") == true else {
            throw ControllerError(code: .unsupportedVersion, detail: "Update Screenpunk on the phone to use Home Assistant. The current screen has been kept.")
        }
    }

    public func provisionHomeAssistant(deviceId: String, configuration: HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt {
        let record = try ownedRecord(deviceId)
        try configuration.validate()
        let receipt = try withLink(record) { try $0.provisionHomeAssistant(configuration) }
        guard receipt.installed, receipt.deviceId == deviceId,
              receipt.dashboardId == configuration.dashboardId, receipt.revision == configuration.revision,
              receipt.connectionId == configuration.connectionId, receipt.provisioningId == configuration.provisioningId else {
            throw ControllerError.validationFailed(detail: "The phone returned an invalid Home Assistant installation receipt.")
        }
        return receipt
    }

    public func revokeHomeAssistant(deviceId: String) throws {
        let record = try ownedRecord(deviceId)
        try withLink(record) { try $0.revokeHomeAssistant() }
    }

    private func ownedRecord(_ deviceId: String) throws -> PairedDeviceRecord {
        let factory = try requireFactory()
        guard let record = directory.get(deviceId), record.device.owner == factory.controllerIdentity else {
            throw ControllerError.notPaired("Pair this device before managing its connections.")
        }
        return record
    }

    // MARK: Helpers

    private struct Target {
        var deviceId: String
        var host: String
        var port: UInt16
    }

    private func resolveTarget(deviceId: String?, host: String?, port: Int?) throws -> Target {
        if let host, host.isEmpty == false {
            guard let port, let nwPort = UInt16(exactly: port), nwPort > 0 else {
                throw ControllerError.validationFailed(detail: "port must be 1-65535 when host is given")
            }
            let id = deviceId ?? "manual:\(host):\(port)"
            return Target(deviceId: id, host: host, port: nwPort)
        }
        guard let deviceId, deviceId.isEmpty == false else {
            throw ControllerError.validationFailed(detail: "deviceId or host+port required")
        }
        if let advertised = hub.browse().first(where: { $0.deviceId == deviceId }) {
            guard let nwPort = UInt16(exactly: advertised.port), nwPort > 0 else {
                throw ControllerError.deviceOffline("advertised port \(advertised.port) is invalid")
            }
            return Target(deviceId: deviceId, host: advertised.host, port: nwPort)
        }
        if let known = directory.get(deviceId), let nwPort = UInt16(exactly: known.port), nwPort > 0 {
            return Target(deviceId: deviceId, host: known.host, port: nwPort)
        }
        throw ControllerError.deviceOffline(
            "device \(deviceId) is not advertised on this network and is not a known device; pass host and port"
        )
    }

    private func requireFactory() throws -> DeviceLinkFactory {
        lock.lock()
        defer { lock.unlock() }
        guard let linkFactory else {
            throw ControllerError.deviceOffline("LAN transport unavailable in this controller process")
        }
        return linkFactory
    }

    private func verifySAS(code: String, devicePin: [UInt8], controllerPin: [UInt8], nonce: [UInt8]) throws {
        #if canImport(CryptoKit)
        let transcript = PairingTranscript(
            devicePublicKey: devicePin,
            controllerPublicKey: controllerPin,
            sessionNonce: nonce
        )
        if PairingSAS.matchingCode(for: transcript) != code {
            throw PairingFailure.codeMismatch
        }
        #endif
        guard code.count == PairingLimits.codeDigits, code.allSatisfy(\.isNumber) else {
            throw PairingFailure.codeMismatch
        }
    }

    private func withLink<T>(_ record: PairedDeviceRecord, _ body: (DeviceLink) throws -> T) throws -> T {
        let factory = try requireFactory()
        lock.lock()
        let cached = links[record.id]
        lock.unlock()
        if let cached {
            do {
                return try body(cached)
            } catch {
                if isDeviceVerdict(error) { throw error }
                cached.cancel()
                lock.lock()
                if links[record.id] === cached { links[record.id] = nil }
                lock.unlock()
            }
        }
        guard let port = UInt16(exactly: record.port), port > 0 else {
            throw TransferFailure.deviceOffline
        }
        let link = try factory.makeLink()
        do {
            let advertised = hub.browse().first { $0.deviceId == record.id }
            try link.connect(host: advertised?.host ?? record.host, port: UInt16(exactly: advertised?.port ?? Int(port)) ?? port, pinnedDevice: record.devicePin)
            let hello = try link.hello()
            if let profile = hello.profile, profile.deviceId == record.id {
                _ = try directory.update(record.id) { current in
                    current.device.profile = profile
                    if let name = current.displayName { current.device.profile.name = name }
                }
            }
        } catch {
            link.cancel()
            throw error
        }
        lock.lock()
        links[record.id]?.cancel()
        links[record.id] = link
        lock.unlock()
        return try body(link)
    }

    /// Replies the device made on purpose. Reconnecting would not change them.
    private func isDeviceVerdict(_ error: Error) -> Bool {
        if error is PairingFailure { return true }
        if let transfer = error as? TransferFailure {
            return [.validationFailed, .notPaired, .targetMismatch].contains(transfer)
        }
        return false
    }

    private func mapConnect(_ error: Error) -> ControllerError {
        if let controllerError = error as? ControllerError { return controllerError }
        if let failure = error as? PairingFailure { return mapPairing(failure) }
        if let transfer = error as? TransferFailure {
            switch transfer {
            case .notPaired:
                return .notPaired("TLS pin rejected: this device already belongs to another controller, or its identity changed")
            default:
                return .deviceOffline("could not connect: \(transfer.rawValue)")
            }
        }
        return .deviceOffline("could not connect: \(String(describing: error))")
    }

    private func mapPairing(_ error: Error) -> ControllerError {
        if let controllerError = error as? ControllerError { return controllerError }
        if let failure = error as? PairingFailure {
            switch failure {
            case .secondOwner:
                return .notPaired(
                    "second_owner: the device already belongs to another Mac. Unlink it on the device first (hold two fingers for ten seconds, then tap Unlink)."
                )
            case .identityChanged:
                return .notPaired("identity_changed: the device presented a different identity than the one pinned; forget_device and pair again only if you replaced the device")
            case .codeMismatch:
                return .notPaired("code_mismatch: the matching codes disagree; cancel on both sides and call request_pairing again")
            case .expired:
                return .notPaired("expired: the matching code expired; call request_pairing again")
            case .rateLimited:
                return .notPaired("rate_limited: too many failed confirmations; the device paused pairing")
            case .invalidIdentity:
                return .validationFailed(detail: "invalid controller identity")
            }
        }
        return mapTransfer(error)
    }

    private func mapTransfer(_ error: Error) -> ControllerError {
        if let controllerError = error as? ControllerError { return controllerError }
        if let failure = error as? PairingFailure { return mapPairing(failure) }
        if let transfer = error as? TransferFailure {
            switch transfer {
            case .notPaired:
                return .notPaired("device rejected the request: not paired with this controller")
            case .deviceOffline:
                return .deviceOffline("device unreachable")
            case .interrupted:
                return .deviceOffline("transfer interrupted; the device keeps its current dashboard")
            case .validationFailed:
                return .validationFailed(detail: "device rejected the package (hash or path check)")
            case .targetMismatch:
                return .validationFailed(detail: "target_mismatch: revision orientation or size does not match the device")
            }
        }
        return .deviceOffline(String(describing: error))
    }
}

extension ControllerError {
    public static func deviceOffline(_ detail: String) -> ControllerError {
        ControllerError(code: .deviceOffline, detail: detail)
    }
}
