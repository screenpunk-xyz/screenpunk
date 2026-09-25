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
    private let discoveryLock = NSLock()
    private var discoveryCache: [String: (hello: LANHello, pin: [UInt8], seen: Date)] = [:]
    /// Endpoints whose last identity probe failed, with the failure time. Any
    /// LAN peer can advertise `_screenpunk._tcp`; without these bounds a few
    /// dead or hostile advertisements would stall every discovery pass (and
    /// the workbench queue behind it) for the full connect timeout each.
    private var discoveryFailures: [String: Date] = [:]
    static let discoveryConnectTimeout: TimeInterval = 5
    static let discoveryRetryInterval: TimeInterval = 30
    static let discoveryProbesPerPass = 8

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
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        guard let factory = try? requireFactory() else { return hub.browse() }
        let advertisements = hub.browse()
        let addresses = Set(advertisements.map { "\($0.host):\($0.port)" })
        discoveryCache = discoveryCache.filter { addresses.contains($0.key) }
        discoveryFailures = discoveryFailures.filter {
            addresses.contains($0.key) && now().timeIntervalSince($0.value) < Self.discoveryRetryInterval
        }
        var probes = 0
        var resolved: [String: AdvertisedDevice] = [:]
        for var advertisement in advertisements {
            if advertisement.source == .loopback {
                resolved[advertisement.deviceId] = advertisement
                continue
            }
            let address = "\(advertisement.host):\(advertisement.port)"
            do {
                let identity: (hello: LANHello, pin: [UInt8], seen: Date)
                if let cached = discoveryCache[address], now().timeIntervalSince(cached.seen) < 10 {
                    identity = cached
                } else {
                    guard let port = UInt16(exactly: advertisement.port), port > 0 else { continue }
                    // A recently failed endpoint waits out the retry interval, and one
                    // pass probes only a handful of unknown endpoints; the rest are
                    // reconsidered next pass so a burst of advertisements stays cheap.
                    guard discoveryFailures[address] == nil, probes < Self.discoveryProbesPerPass else { continue }
                    probes += 1
                    let link = try factory.makeLink()
                    defer { link.cancel() }
                    // Read-only identity discovery; no pairing, deployment or credentials.
                    try link.connect(host: advertisement.host, port: port, pinnedDevice: nil, timeout: Self.discoveryConnectTimeout)
                    let hello = try link.hello()
                    guard hello.protocolMajor == DiscoveryService.protocolMajor,
                          let pin = link.devicePin, pin.count == PairingLimits.identityByteCount,
                          PeerPin.matches(expected: pin, presentedHex: hello.pinHex) else { continue }
                    identity = (hello, pin, now())
                    discoveryCache[address] = identity
                }
                let known = directory.list().first { $0.devicePin == identity.pin }
                let id = try verifiedDeviceId(hello: identity.hello, pin: identity.pin)
                advertisement.deviceId = id
                advertisement.name = DeviceDisplayName.sanitize(identity.hello.name) ?? advertisement.name
                if let known {
                    // Only a verified match to the saved TLS pin can move a paired endpoint.
                    if known.host != advertisement.host || known.port != advertisement.port ||
                        known.id != id || known.device.profile.model != identity.hello.profile?.model {
                        _ = try directory.update(known.id) { current in
                            current.host = advertisement.host
                            current.port = advertisement.port
                            current.device.profile.deviceId = id
                            for index in current.device.deployments.indices { current.device.deployments[index].deviceId = id }
                            if var profile = identity.hello.profile {
                                profile.deviceId = id
                                if let name = current.displayName { profile.name = name }
                                current.device.profile = profile
                            }
                        }
                    }
                }
                if resolved[id]?.source != .advertised { resolved[id] = advertisement }
            } catch {
                // An unreachable or foreign-owned endpoint is not a verified pairing candidate.
                discoveryCache[address] = nil
                discoveryFailures[address] = now()
            }
        }
        return resolved.values.sorted { $0.deviceId < $1.deviceId }
    }

    /// Forget a failed probe so the next `discover()` tries the endpoint again
    /// at once (a device the person just brought back, or a manual address).
    public func forgetDiscoveryFailure(host: String, port: Int) {
        discoveryLock.lock()
        discoveryFailures["\(host):\(port)"] = nil
        discoveryLock.unlock()
    }

    private func verifiedDeviceId(hello: LANHello, pin: [UInt8]) throws -> String {
        guard !hello.deviceId.isEmpty, hello.deviceId != "phone-local",
              hello.profile == nil || hello.profile?.deviceId == hello.deviceId else {
            throw ControllerError(code: .unsupportedVersion, detail: "Update Screenpunk on this device before pairing.")
        }
        if let existing = directory.get(hello.deviceId), existing.devicePin != pin { throw PairingFailure.identityChanged }
        if let existing = directory.list().first(where: { $0.devicePin == pin }),
           existing.id != hello.deviceId, existing.id != "phone-local" {
            throw PairingFailure.identityChanged
        }
        return hello.deviceId
    }

    @discardableResult
    public func addManual(host: String, port: Int) -> AdvertisedDevice {
        forgetDiscoveryFailure(host: host, port: port)
        return hub.addManual(host: host, port: port)
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
            let resolvedId = try verifiedDeviceId(hello: hello, pin: devicePin)
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
            let matched = directory.list().first { $0.devicePin == devicePin }
            var profile = hello.profile
            profile?.deviceId = resolvedId
            let entry = PendingPairing(
                deviceId: resolvedId,
                deviceName: matched?.displayName ?? name,
                host: target.host,
                port: Int(target.port),
                devicePin: devicePin,
                code: begin.code,
                startedAt: started,
                rePairing: matched != nil,
                link: link,
                profile: profile
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
                rePairing: matched != nil
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
            guard existing.devicePin == entry.devicePin else { throw PairingFailure.identityChanged }
            device = existing.device
            if let profile = entry.profile { device.profile = profile }
            if let name = existing.displayName { device.profile.name = name }
            device.owner = factory.controllerIdentity
            device.reachable = true
            device.pairingCode = nil
        }
        if let active = try? entry.link.queryActive() { device.activeRevision = active }
        let record = PairedDeviceRecord(
            device: device,
            host: entry.host,
            port: entry.port,
            devicePinHex: PeerPin.hex(entry.devicePin),
            pairedAt: pairedAt,
            lastSeenAt: pairedAt,
            displayName: directory.get(deviceId)?.displayName
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
            let active = try withLink(record) { try $0.queryActiveState() }
            let seen = now()
            return try directory.update(deviceId) { current in
                current.device.reachable = true
                current.device.activeRevision = active.revision
                if let screens = active.screens {
                    current.screenSet = screens
                    current.selectedDashboardId = active.selectedDashboardId
                }
                current.lastSeenAt = seen
            } ?? record
        } catch {
            return try directory.update(deviceId) { current in
                current.device.reachable = false
            } ?? record
        }
    }

    /// Forget on the Mac only. The device keeps its dashboard and pairing until
    /// its owner opens the device menu and confirms Disconnect on the device itself.
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
            deviceId: record.id,
            phase: .queued
        )
        let body = LANDeployBody(deployment: queued, revision: revision, files: files)
        let encoded = try LANCodec.encodePayload(body)
        let envelope = LANEnvelope(requestId: UUID().uuidString, method: LANMethod.deploy.rawValue, payloadJSON: encoded)
        let hello = try withLink(record) { try $0.hello() }
        try checkTransferSize(try LANCodec.encode(envelope).count, advertised: hello.maxTransferBytes)

        let outcome: DeploymentRecord
        do {
            outcome = try withLink(record) { try $0.deploy(body) }
            guard outcome.deviceId == record.id else { throw TransferFailure.targetMismatch }
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

    private func checkTransferSize(_ bytes: Int, advertised: Int?) throws {
        let limit = LANProtocolLimits.transferLimit(advertised: advertised)
        guard bytes <= limit else {
            let size = String(format: "%.2f", Double(bytes) / 1_048_576)
            let maximum = String(format: "%.2f", Double(limit) / 1_048_576)
            let action = limit < LANProtocolLimits.maxMessageBytes
                ? "Update Screenpunk on this device to allow transfers up to 32 MiB."
                : "Choose fewer screens or reduce their assets."
            throw ControllerError.validationFailed(detail: "Selected screens need \(size) MiB encoded (\(bytes) bytes); the transfer limit is \(maximum) MiB (\(limit) bytes). \(action) The device's current screens have been kept.")
        }
    }

    /// No package or credential is sent until the current peer advertises atomic sets.
    @discardableResult
    public func requireScreenSetSupport(deviceId: String, serviceCalls: Bool = false, cameras: Bool = false, publicReads: Bool = false, dynamicPublicPaths: Bool = false) throws -> LANHello {
        let record = try ownedRecord(deviceId)
        let hello: LANHello
        do { hello = try withLink(record) { try $0.hello() } }
        catch { throw mapTransfer(error) }
        guard hello.deviceId == deviceId, hello.capabilities?.contains("screen-set-v1") == true,
              (!serviceCalls || hello.capabilities?.contains("home-assistant-services-v1") == true),
              (!cameras || hello.capabilities?.contains("camera-playback-v1") == true),
              (!publicReads || hello.capabilities?.contains("public-read-http-v1") == true),
              (!dynamicPublicPaths || hello.capabilities?.contains("public-read-dynamic-path-v1") == true) else {
            throw ControllerError(code: .unsupportedVersion, detail: "Update Screenpunk on this device before applying screens. Its current screens have been kept.")
        }
        return hello
    }

    public func deployScreenSet(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt {
        let record = try ownedRecord(body.deviceId)
        try body.validate()
        let hello = try requireScreenSetSupport(deviceId: body.deviceId,
            serviceCalls: body.screens.contains { ($0.homeAssistant?.schemaVersion ?? 1) >= 2 },
            cameras: body.screens.contains { $0.homeAssistant?.cameraEntities != nil },
            publicReads: body.screens.contains { $0.publicReads != nil },
            dynamicPublicPaths: body.screens.contains { $0.publicReads?.requiresDynamicPaths == true })
        let encoded = try LANCodec.encodePayload(body)
        let envelope = LANEnvelope(requestId: UUID().uuidString, method: LANMethod.deploySet.rawValue, payloadJSON: encoded)
        try checkTransferSize(try LANCodec.encode(envelope).count, advertised: hello.maxTransferBytes)
        let receipt: LANScreenSetReceipt
        do { receipt = try withLink(record) { try $0.deployScreenSet(body) } }
        catch {
            if (error as? TransferFailure) == .targetMismatch, body.screens.count == 1 {
                var failed = body.screens[0].deployment.deployment
                failed.phase = .failed; failed.error = TransferFailure.targetMismatch.rawValue
                try directory.update(record.id) { current in
                    if !current.device.deployments.contains(where: { $0.deploymentId == failed.deploymentId }) {
                        current.device.deployments.append(failed)
                    }
                }
            }
            throw mapTransfer(error)
        }
        let expected = body.screens.map { LANScreenSetEntry(dashboardId: $0.deployment.revision.dashboardId, revision: $0.deployment.revision.revision, name: $0.name) }
        guard receipt.schemaVersion == 1, receipt.deploymentId == body.deploymentId,
              receipt.deviceId == body.deviceId, receipt.screens == expected,
              receipt.selectedDashboardId == body.selectedDashboardId,
              let visible = receipt.screens.first(where: { $0.dashboardId == receipt.selectedDashboardId }) else {
            throw ControllerError.validationFailed(detail: "The device returned an invalid screen-set receipt. Refresh its status before applying again.")
        }
        try directory.update(record.id) { current in
            current.screenSet = receipt.screens
            current.selectedDashboardId = receipt.selectedDashboardId
            current.device.activeRevision = visible.revision
            if let selected = body.screens.first(where: { $0.deployment.revision.dashboardId == visible.dashboardId }) {
                current.device.profile.apply(orientation: selected.deployment.revision.orientation)
            }
            current.device.draftRevision = nil
            current.device.reachable = true
            current.lastSeenAt = now()
            for item in body.screens {
                var deployment = item.deployment.deployment
                deployment.phase = .active
                if !current.device.deployments.contains(where: { $0.deploymentId == deployment.deploymentId }) {
                    current.device.deployments.append(deployment)
                }
                if !current.device.history.contains(where: { $0.revision == item.deployment.revision.revision }) {
                    current.device.history.append(item.deployment.revision)
                }
            }
        }
        return receipt
    }

    /// Check support before replacing the current screen or transmitting credentials.
    public func requireHomeAssistantSupport(deviceId: String) throws {
        let record = try ownedRecord(deviceId)
        let hello = try withLink(record) { try $0.hello() }
        guard hello.deviceId == record.id, hello.capabilities?.contains("home-assistant-http-v1") == true else {
            throw ControllerError(code: .unsupportedVersion, detail: "Update Screenpunk on the phone to use Home Assistant. The current screen has been kept.")
        }
    }

    /// Explicit native approval only. A changed active dashboard/revision is rejected by the device.
    /// No durable queue: a transport retry uses the same idempotent provisioning identifier.
    public func connectionInventory(deviceId: String) throws -> DeviceConnectionInventory {
        let record = try ownedRecord(deviceId)
        let inventory = try withLink(record) { try $0.connectionInventory() }
        guard inventory.deviceId == deviceId else { throw ConnectionFailure.validationFailed }
        return inventory
    }
    public func updateHomeConnection(deviceId: String, update: DeviceHomeAssistantUpdate) throws -> DeviceConnectionInventory {
        let record = try ownedRecord(deviceId)
        let inventory = try withLink(record) { try $0.updateHomeConnection(update) }
        guard inventory.deviceId == deviceId, update.entries.allSatisfy({ expected in
            inventory.entries.contains { $0.id == expected.id && $0.screen == expected.screen && $0.origin == update.origin && $0.operations == expected.operations && $0.configurationVersion != expected.configurationVersion }
        }) else { throw ConnectionFailure.validationFailed }
        return inventory
    }

    public func provisionConnections(deviceId: String, configuration: ConnectionProvisioning) throws -> ConnectionProvisioningReceipt {
        let record = try ownedRecord(deviceId)
        try configuration.validate()
        let receipt = try withLink(record) { try $0.provisionConnections(configuration) }
        guard receipt.installed, receipt.deviceId == record.id,
              receipt.dashboardId == configuration.dashboardId, receipt.revision == configuration.revision,
              receipt.provisioningId == configuration.provisioningId else {
            throw ControllerError.validationFailed(detail: "The device returned an invalid connection installation receipt.")
        }
        return receipt
    }

    public func provisionHomeAssistant(deviceId: String, configuration: HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt {
        let record = try ownedRecord(deviceId)
        try configuration.validate()
        let receipt = try withLink(record) { try $0.provisionHomeAssistant(configuration) }
        guard receipt.installed, receipt.deviceId == record.id,
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

    /// Synchronize the controller's user-assigned label without replacing other device settings.
    @discardableResult
    public func syncDeviceDisplayName(deviceId: String) throws -> DeviceSettingsSnapshot {
        let record = try ownedRecord(deviceId)
        let snapshot = try fetchDeviceSettings(deviceId: deviceId)
        guard let name = record.displayName.flatMap(DeviceDisplayName.sanitize), snapshot.value.displayName != name else { return snapshot }
        var value = snapshot.value
        value.displayName = name
        return try updateDeviceSettings(deviceId: deviceId, update: .init(expectedRevision: snapshot.revision, value: value))
    }

    public func fetchDeviceSettings(deviceId: String) throws -> DeviceSettingsSnapshot {
        let record = try ownedRecord(deviceId)
        let snapshot = try withLink(record) { try $0.getSettings() }
        try snapshot.value.validate()
        guard !snapshot.revision.isEmpty else { throw DeviceSettingsFailure.invalidSettings }
        _ = try directory.update(deviceId) { $0.settingsSnapshot = snapshot }
        return snapshot
    }

    /// Explicit apply only. No queued/reconnect replay, and a conflict must be
    /// resolved from a fresh snapshot rather than silently overwriting the device.
    public func updateDeviceSettings(deviceId: String, update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot {
        let record = try ownedRecord(deviceId)
        try update.value.validate()
        let snapshot = try withLink(record) { try $0.updateSettings(update) }
        guard !snapshot.revision.isEmpty, snapshot.revision != update.expectedRevision, snapshot.value == update.value else {
            throw DeviceSettingsFailure.invalidSettings
        }
        _ = try directory.update(deviceId) { $0.settingsSnapshot = snapshot }
        return snapshot
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
        if let advertised = discover().first(where: { $0.deviceId == deviceId })
            ?? hub.browse().first(where: { $0.deviceId == deviceId }) {
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
            let advertised = discover().first { $0.deviceId == record.id }
            try link.connect(host: advertised?.host ?? record.host, port: UInt16(exactly: advertised?.port ?? Int(port)) ?? port, pinnedDevice: record.devicePin)
            let hello = try link.hello()
            guard let pin = link.devicePin, pin == record.devicePin,
                  hello.deviceId == record.id,
                  PeerPin.matches(expected: pin, presentedHex: hello.pinHex) else { throw PairingFailure.identityChanged }
            if var profile = hello.profile {
                profile.deviceId = record.id
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
        if error is PairingFailure || error is DeviceSettingsFailure { return true }
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
                    "second_owner: the device already belongs to another Mac. On the device, hold two fingers for five seconds to open the device menu, then choose Disconnect and confirm."
                )
            case .identityChanged:
                return .notPaired("identity_changed: the device presented a different identity than the one pinned; forget_device and pair again only if you replaced the device")
            case .codeMismatch:
                return .notPaired("code_mismatch: the matching codes disagree; cancel on both sides and call request_pairing again")
            case .expired:
                return .notPaired("expired: the matching code expired; call request_pairing again")
            case .rateLimited:
                return .notPaired("rate_limited: too many failed confirmations; the device paused pairing")
            case .busy:
                return .notPaired("busy: the device is showing a code for a different controller; wait for it to expire (\(Int(PairingLimits.expirySeconds)) s) or cancel it on the device, then call request_pairing again")
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
                return .deviceOffline("Transfer interrupted. Refresh the device status before trying again.")
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
