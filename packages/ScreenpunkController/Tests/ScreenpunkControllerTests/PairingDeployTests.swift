import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class PairingDeployTests: XCTestCase {
    private let controllerIdentity = PairingIdentityFactory.make(role: .controller)

    func testTwoDevicesRemainDistinctAcrossPairingDiscoveryAndRestart() throws {
        let phone = FakeLANDevice(deviceId: "device-iphone-mini", name: "iPhone mini")
        let tablet = FakeLANDevice(deviceId: "device-ipad-air", name: "iPad Air")
        tablet.host = "192.168.4.21"
        let harness = try makeHarness(device: phone)
        let coordinator = harness.service.devices
        let factory = MultipleDevicesFactory(devices: [phone, tablet], controllerIdentity: controllerIdentity)
        coordinator.attach(factory)
        coordinator.hub.reset()
        for (name, device) in [("bonjour:phone-local", phone), ("bonjour:phone-local (2)", tablet)] {
            coordinator.hub.advertise(AdvertisedDevice(deviceId: name, host: device.host, port: Int(device.port), source: .advertised))
        }
        let nearby = coordinator.discover()
        XCTAssertEqual(nearby.count, 2)
        XCTAssertEqual(Set(nearby.map(\.deviceId)).count, 2)
        let first = try coordinator.requestPairing(deviceId: nearby.first { $0.name == "iPhone mini" }!.deviceId, host: nil, port: nil)
        phone.confirmLocally()
        let pairedPhone = try coordinator.confirmPairing(deviceId: first.deviceId)
        let second = try coordinator.requestPairing(deviceId: nearby.first { $0.name == "iPad Air" }!.deviceId, host: nil, port: nil)
        tablet.confirmLocally()
        let pairedTablet = try coordinator.confirmPairing(deviceId: second.deviceId)
        XCTAssertNotEqual(pairedPhone.id, pairedTablet.id)
        XCTAssertEqual(coordinator.listDevices().count, 2)
        XCTAssertEqual(pairedPhone.device.profile.name, "iPhone mini")
        XCTAssertEqual(pairedTablet.device.profile.name, "iPad Air")
        let ads = coordinator.discover()
        XCTAssertTrue(WorkbenchSidebar.nearby(advertisements: ads, devices: coordinator.listDevices().map(\.device), developer: false).isEmpty)
        // A duplicate manual address must collapse to the same authenticated identity.
        coordinator.addManual(host: phone.host, port: Int(phone.port))
        XCTAssertEqual(coordinator.discover().count, 2)
        // Reboot changes both Bonjour names and ports; trust follows the saved pin.
        phone.port = 8001; tablet.port = 8002
        coordinator.hub.reset()
        coordinator.hub.advertise(AdvertisedDevice(deviceId: "bonjour:renamed-a", host: phone.host, port: Int(phone.port), source: .advertised))
        coordinator.hub.advertise(AdvertisedDevice(deviceId: "bonjour:renamed-b", host: tablet.host, port: Int(tablet.port), source: .advertised))
        let reopened = DeviceCoordinator(directory: DeviceDirectory(url: harness.directoryURL), hub: coordinator.hub, linkFactory: factory)
        XCTAssertEqual(reopened.discover().count, 2)
        XCTAssertTrue(try reopened.device(pairedPhone.id, probe: true).device.reachable)
        XCTAssertTrue(try reopened.device(pairedTablet.id, probe: true).device.reachable)
        XCTAssertEqual(reopened.directory.get(pairedPhone.id)?.port, 8001)
        XCTAssertEqual(reopened.directory.get(pairedTablet.id)?.port, 8002)
    }

    /// Anyone on the LAN can advertise `_screenpunk._tcp`. A burst of dead
    /// advertisements must cost a bounded number of probes per pass, and a
    /// failed endpoint must not be probed again on every pass.
    func testDiscoveryBoundsProbesAndBacksOffFailedEndpoints() throws {
        let phone = FakeLANDevice(deviceId: "device-real", name: "Real iPhone")
        phone.online = false
        let clock = MutableClock()
        let harness = try makeHarness(device: phone, now: { clock.now })
        let coordinator = harness.service.devices
        coordinator.hub.reset()
        // More dead advertisements than the per-pass probe budget.
        for index in 0..<(DeviceCoordinator.discoveryProbesPerPass + 4) {
            coordinator.hub.advertise(AdvertisedDevice(deviceId: "bonjour:ghost-\(index)", host: "192.168.9.\(100 + index)", port: 7843, source: .advertised))
        }

        XCTAssertTrue(coordinator.discover().isEmpty)
        XCTAssertEqual(phone.connectAttempts, DeviceCoordinator.discoveryProbesPerPass, "one pass probes a bounded number of unknown endpoints")

        // The next pass probes only the not-yet-tried endpoints; failed ones back off.
        let afterFirst = phone.connectAttempts
        XCTAssertTrue(coordinator.discover().isEmpty)
        XCTAssertEqual(phone.connectAttempts, afterFirst + 4, "already-failed endpoints are not retried within the interval")

        // Fully inside the retry interval: nothing is re-probed.
        clock.now = clock.now.addingTimeInterval(DeviceCoordinator.discoveryRetryInterval - 1)
        let afterSecond = phone.connectAttempts
        XCTAssertTrue(coordinator.discover().isEmpty)
        XCTAssertEqual(phone.connectAttempts, afterSecond, "every endpoint is still inside its retry interval")

        // A real device advertised at a fresh address is probed and returned.
        phone.host = "192.168.9.50"; phone.port = 7843; phone.online = true
        phone.runtime.advertisement = AdvertisedDevice(deviceId: "device-real", host: phone.host, port: Int(phone.port), source: .advertised)
        coordinator.hub.advertise(phone.runtime.advertisement)
        XCTAssertEqual(coordinator.discover().map(\.deviceId), ["device-real"])

        // Past the identity cache window and the ghosts' retry interval: the ghosts
        // become candidates again (bounded per pass) and the now-offline device is
        // re-probed instead of answered from the stale cache.
        phone.online = false
        clock.now = clock.now.addingTimeInterval(11)
        XCTAssertTrue(coordinator.discover().isEmpty, "the stale identity is not reused once the device stops answering")
        XCTAssertTrue(coordinator.discover().isEmpty)
        // Every endpoint has now failed inside the current interval; a pass costs nothing.
        let settled = phone.connectAttempts
        XCTAssertTrue(coordinator.discover().isEmpty)
        XCTAssertEqual(phone.connectAttempts, settled, "all endpoints are backed off")

        // A manual address entered by the person is never held back by an old failure.
        phone.online = true
        coordinator.addManual(host: phone.host, port: Int(phone.port))
        XCTAssertEqual(coordinator.discover().count, 1)
        XCTAssertEqual(phone.connectAttempts, settled + 1, "addManual clears the endpoint's back-off so it is probed at once")
    }

    func testLegacySavedPairingSurvivesNativeIdentityUpgrade() throws {
        let phone = FakeLANDevice(deviceId: "device-native-id", name: "iPhone")
        let harness = try makeHarness(device: phone)
        let coordinator = harness.service.devices
        let request = try coordinator.requestPairing(deviceId: nil, host: phone.host, port: Int(phone.port))
        phone.confirmLocally()
        var original = try coordinator.confirmPairing(deviceId: request.deviceId)
        _ = try coordinator.directory.remove(original.id)
        original.device.profile.deviceId = "phone-local"
        original.displayName = "Desk phone"
        original.device.profile.name = "Desk phone"
        try coordinator.directory.upsert(original)
        phone.runtime.profile.deviceId = "device-new-native-id"
        phone.port = 9001
        coordinator.hub.reset()
        coordinator.hub.advertise(AdvertisedDevice(deviceId: "new-bonjour-name", host: phone.host, port: Int(phone.port), source: .advertised))
        let reopened = DeviceCoordinator(directory: DeviceDirectory(url: harness.directoryURL), hub: coordinator.hub, linkFactory: coordinator.linkFactory)
        XCTAssertEqual(reopened.discover().first?.deviceId, "device-new-native-id")
        XCTAssertNil(reopened.directory.get("phone-local"))
        let refreshed = try reopened.device("device-new-native-id", probe: true)
        XCTAssertTrue(refreshed.device.reachable)
        XCTAssertEqual(refreshed.displayName, "Desk phone")
        XCTAssertEqual(refreshed.device.profile.name, "Desk phone")
        XCTAssertEqual(refreshed.id, "device-new-native-id")
        XCTAssertEqual(refreshed.devicePin, phone.identityPin)
    }

    func testSharedLegacyIdentityRequiresAppUpdate() throws {
        let phone = FakeLANDevice(deviceId: "phone-local", name: "Phone")
        let harness = try makeHarness(device: phone)
        XCTAssertTrue(harness.service.devices.discover().isEmpty)
        XCTAssertThrowsError(try harness.service.devices.requestPairing(deviceId: nil, host: phone.host, port: Int(phone.port))) { error in
            XCTAssertEqual((error as? ControllerError)?.code, .unsupportedVersion)
        }
        XCTAssertNil(phone.pairingCode)
        XCTAssertTrue(harness.service.devices.listDevices().isEmpty)
    }

    func testDirectoryCannotOverwriteDifferentIdentity() throws {
        let phone = FakeLANDevice(deviceId: "same-id", name: "Phone")
        let harness = try makeHarness(device: phone)
        try pair(harness.router, device: phone, deviceId: "same-id")
        let original = try XCTUnwrap(harness.service.devices.directory.get("same-id"))
        var impostor = original
        impostor.devicePinHex = PeerPin.hex(PairingIdentityFactory.make(role: .device).publicKey)
        XCTAssertThrowsError(try harness.service.devices.directory.upsert(impostor))
        XCTAssertEqual(harness.service.devices.directory.get("same-id"), original)
    }

    func testPairedDeviceKeepsActiveScreenAndCanProvisionHomeAssistant() throws {
        let device = FakeLANDevice(deviceId: "device-native-phone", name: "Phone")
        device.supportsHomeAssistant = true
        let harness = try makeHarness(device: device)
        let request = try harness.service.devices.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()
        device.runtime.activeRevision = "already-running"
        let paired = try harness.service.devices.confirmPairing(deviceId: request.deviceId)
        XCTAssertEqual(paired.device.activeRevision, "already-running")
        let screen = try harness.service.updateDashboard(arguments: .object([
            "name": .string("Lights"),
            "connections": .array([
                .object([
                    "alias": .string("home"),
                    "required": .bool(true),
                    "operations": .array([
                        .object(["name": .string("getStates"), "kind": .string("http")])
                    ])
                ])
            ]),
            "files": .array([.object(["path": .string("index.html"), "text": .string("<p>Lights</p>")])])
        ]))
        harness.service.homeAssistantConfiguration = { dashboard, revision, id in
            HomeAssistantProvisioning(dashboardId: dashboard, connectionId: "connection", provisioningId: id,
                revision: revision, origin: "http://192.168.1.2:8123", allowInsecureHTTP: true, token: "test-token")
        }
        let outcome = try harness.service.ship(record: screen, deviceId: paired.id, deploymentId: "legacy-install")
        XCTAssertEqual(outcome.phase, .active)
        XCTAssertEqual(outcome.deviceId, paired.id)
        XCTAssertEqual(device.runtime.lastDeployment?.deviceId, paired.id)
        XCTAssertEqual(device.installedHomeAssistant?.revision, outcome.revision)
    }

    func testHomeAssistantPreflightPreservesScreenAndBindsInstalledRevision() throws {
        let device = FakeLANDevice(deviceId: "ha-phone", name: "HA Phone")
        let harness = try makeHarness(device: device)
        try pair(harness.router, device: device, deviceId: "ha-phone")
        let record = try harness.service.updateDashboard(arguments: .object([
            "name": .string("Lights"),
            "connections": .array([
                .object([
                    "alias": .string("home"),
                    "required": .bool(true),
                    "operations": .array([
                        .object(["name": .string("getStates"), "kind": .string("http")])
                    ])
                ])
            ]),
            "files": .array([.object(["path": .string("index.html"), "text": .string("<p>Lights</p>")])])
        ]))
        XCTAssertEqual(record.manifest.connections.first?.operations?.first?.name, "getStates")
        XCTAssertThrowsError(try harness.service.ship(record: record, deviceId: "ha-phone", deploymentId: "install-1"))
        XCTAssertEqual(device.deployAttempts, 0, "Missing configuration must not replace the screen")
        harness.service.homeAssistantConfiguration = { dashboard, revision, id in
            HomeAssistantProvisioning(dashboardId: dashboard, connectionId: "connection", provisioningId: id,
                revision: revision, origin: "http://192.168.1.2:8123", allowInsecureHTTP: true, token: "test-token")
        }
        XCTAssertThrowsError(try harness.service.ship(record: record, deviceId: "ha-phone", deploymentId: "install-1"))
        XCTAssertEqual(device.deployAttempts, 0, "Older phones must keep the current screen")
        device.supportsHomeAssistant = true
        let outcome = try harness.service.ship(record: record, deviceId: "ha-phone", deploymentId: "install-1")
        XCTAssertEqual(outcome.phase, .active)
        XCTAssertEqual(device.installedHomeAssistant?.revision, outcome.revision)
        XCTAssertEqual(device.installedHomeAssistant?.dashboardId, outcome.dashboardId)
        XCTAssertEqual(device.installedHomeAssistant?.provisioningId, "install-1")
        XCTAssertFalse(device.receivedFiles.values.contains { String(decoding: $0, as: UTF8.self).contains("test-token") })
        device.failProvisioning = true
        XCTAssertThrowsError(try harness.service.ship(record: record, deviceId: "ha-phone", deploymentId: "install-2"))
        XCTAssertEqual(device.runtime.activeRevision, outcome.revision)
        XCTAssertEqual(device.installedHomeAssistant?.provisioningId, "install-1")
        XCTAssertEqual(device.deployAttempts, 1, "Credential failure must preserve the previous screen and grant together")
    }

    func testConnectionInspectionIsReadOnlyAndScopedByAlias() throws {
        let harness = try makeHarness(device: FakeLANDevice(deviceId: "inspect", name: "Phone"))
        harness.service.connectionInspection = { query in
            XCTAssertEqual(query, "Game lights")
            return Data("{\"entities\":[{\"entity_id\":\"light.game_lights\"}]}".utf8)
        }
        let result = harness.router.call(name: "inspect_connection", arguments: .object(["alias": .string("home"), "query": .string("Game lights")]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(try payload(result)["entities"]?.array?.first?["entity_id"]?.string, "light.game_lights")
        XCTAssertTrue(harness.router.call(name: "inspect_connection", arguments: .object(["alias": .string("other")])).isError)
    }

    func testCustomDeviceNameSurvivesReconnectionAndViewportRefresh() throws {
        let device = FakeLANDevice(deviceId: "phone-rename", name: "iPhone")
        let harness = try makeHarness(device: device)
        try pair(harness.router, device: device, deviceId: "phone-rename")
        try harness.service.devices.directory.update("phone-rename") { $0.displayName = "Desk iPhone"; $0.device.profile.name = "Desk iPhone" }
        let reopened = DeviceCoordinator(directory: DeviceDirectory(url: harness.directoryURL), hub: harness.service.devices.hub, linkFactory: harness.service.devices.linkFactory)
        let record = try reopened.device("phone-rename", probe: true)
        XCTAssertTrue(record.device.reachable)
        XCTAssertEqual(record.displayName, "Desk iPhone")
        XCTAssertEqual(record.device.profile.name, "Desk iPhone")
    }

    func testDiscoverRequestConfirmPairsOneOwnerAndPersists() throws {
        let device = FakeLANDevice(deviceId: "phone-a", name: "Kitchen iPhone")
        let harness = try makeHarness(device: device)
        let router = harness.router

        let discovered = try payload(router.call(name: "discover_services", arguments: .object([:])))
        XCTAssertEqual(discovered["services"]?.array?.first?["deviceId"]?.string, "phone-a")
        XCTAssertEqual(discovered["services"]?.array?.first?["paired"]?.bool, false)
        XCTAssertEqual(discovered["serviceType"]?.string, DiscoveryService.type)

        let requested = router.call(name: "request_pairing", arguments: .object(["deviceId": .string("phone-a")]))
        XCTAssertFalse(requested.isError, requested.content.description)
        let pending = try payload(requested)
        XCTAssertEqual(pending["status"]?.string, "pending")
        XCTAssertEqual(pending["selfApproved"]?.bool, false)
        let code = try XCTUnwrap(pending["code"]?.string)
        XCTAssertEqual(code.count, PairingLimits.codeDigits)
        XCTAssertEqual(code, device.runtime.pairingCode, "controller shows the same SAS code the device shows")
        XCTAssertFalse(device.isPaired)

        let listed = try payload(router.call(name: "list_devices", arguments: .object([:])))
        XCTAssertEqual(listed["devices"]?.array?.count, 0)
        XCTAssertEqual(listed["pendingPairings"]?.array?.first?["deviceId"]?.string, "phone-a")
        XCTAssertEqual(listed["transportAvailable"]?.bool, true)

        let early = router.call(name: "confirm_pairing", arguments: .object(["deviceId": .string("phone-a")]))
        XCTAssertTrue(early.isError)
        XCTAssertEqual(early.errorCode, "permission_required")
        XCTAssertFalse(device.isPaired, "MCP cannot approve on the device's behalf")

        device.confirmLocally()
        let confirmed = router.call(name: "confirm_pairing", arguments: .object(["deviceId": .string("phone-a")]))
        XCTAssertFalse(confirmed.isError, confirmed.content.description)
        let paired = try payload(confirmed)
        XCTAssertEqual(paired["status"]?.string, "paired")
        XCTAssertEqual(paired["selfApproved"]?.bool, false)
        XCTAssertEqual(paired["devicePinHex"]?.string, PeerPin.hex(device.identityPin))
        XCTAssertTrue(device.isPaired)
        XCTAssertEqual(device.ownerPin, controllerIdentity.publicKey)

        let one = try payload(router.call(name: "list_devices", arguments: .object([:])))
        XCTAssertEqual(one["devices"]?.array?.count, 1)
        XCTAssertEqual(one["pendingPairings"]?.array?.count, 0)

        let probed = try payload(router.call(name: "get_device", arguments: .object(["deviceId": .string("phone-a")])))
        XCTAssertEqual(probed["reachable"]?.bool, true)
        XCTAssertEqual(probed["activeRevision"], .null)
        XCTAssertEqual(probed["capabilities"]?["runtimeProxy"]?.bool, false)

        let reloaded = DeviceDirectory(url: harness.directoryURL)
        XCTAssertEqual(reloaded.list().map(\.id), ["phone-a"])
        XCTAssertEqual(reloaded.get("phone-a")?.device.owner, controllerIdentity)

        let secondMac = try makeHarness(device: device, identity: PairingIdentityFactory.make(role: .controller))
        let rejected = secondMac.router.call(name: "request_pairing", arguments: .object(["deviceId": .string("phone-a")]))
        XCTAssertTrue(rejected.isError)
        XCTAssertEqual(rejected.errorCode, "not_paired")
        XCTAssertEqual(device.ownerPin, controllerIdentity.publicKey, "one owner per device")
        XCTAssertTrue(secondMac.service.devices.listDevices().isEmpty)
    }

    func testDeployNeedsApprovedPreviewedRevisionThenActivatesIdempotently() throws {
        let device = FakeLANDevice(deviceId: "phone-b", name: "Desk iPad")
        let harness = try makeHarness(device: device)
        let router = harness.router
        try pair(router, device: device, deviceId: "phone-b")

        let created = try createDashboard(harness.service, marker: "ONE")
        let id = created.manifest.dashboardId
        let revision = created.manifest.revision

        let unapproved = router.call(
            name: "deploy_dashboard",
            arguments: .object(["deviceId": .string("phone-b"), "dashboardId": .string(id), "revision": .string(revision)])
        )
        XCTAssertEqual(unapproved.errorCode, "permission_required")

        let unreviewed = router.call(
            name: "deploy_dashboard",
            arguments: .object([
                "deviceId": .string("phone-b"), "dashboardId": .string(id), "revision": .string(revision), "approved": .bool(true)
            ])
        )
        XCTAssertEqual(unreviewed.errorCode, "permission_required")
        if case .text(let text) = unreviewed.content[0] {
            XCTAssertTrue(text.contains("preview"))
        }
        XCTAssertNil(device.runtime.activeRevision)
        XCTAssertEqual(device.deployAttempts, 0)

        let preview = router.call(name: "preview_dashboard", arguments: .object(["dashboardId": .string(id)]))
        XCTAssertFalse(preview.isError)
        XCTAssertTrue(harness.service.hasReviewed(revision: revision))

        let deployed = router.call(
            name: "deploy_dashboard",
            arguments: .object([
                "deviceId": .string("phone-b"),
                "dashboardId": .string(id),
                "revision": .string(revision),
                "approved": .bool(true),
                "deploymentId": .string("dep-1")
            ])
        )
        XCTAssertFalse(deployed.isError, deployed.content.description)
        let outcome = try payload(deployed)
        XCTAssertEqual(outcome["phase"]?.string, "active")
        XCTAssertEqual(outcome["deploymentId"]?.string, "dep-1")
        XCTAssertEqual(outcome["activeRevision"]?.string, revision)
        XCTAssertEqual(outcome["currentDashboardKept"]?.bool, false)
        XCTAssertEqual(device.runtime.activeRevision, revision)
        XCTAssertEqual(device.receivedFiles["index.html"], created.files["index.html"])
        XCTAssertNotNil(device.receivedFiles["manifest.json"], "device receives the manifest with the package")
        XCTAssertEqual(device.deployAttempts, 1)

        let replay = try payload(router.call(
            name: "deploy_dashboard",
            arguments: .object([
                "deviceId": .string("phone-b"),
                "dashboardId": .string(id),
                "revision": .string(revision),
                "approved": .bool(true),
                "deploymentId": .string("dep-1")
            ])
        ))
        XCTAssertEqual(replay["phase"]?.string, "active")
        XCTAssertEqual(device.deployAttempts, 1, "idempotent on deploymentId without another transfer")

        let status = try payload(router.call(name: "get_deployment", arguments: .object(["deploymentId": .string("dep-1")])))
        XCTAssertEqual(status["phase"]?.string, "active")
        XCTAssertEqual(status["activeRevision"]?.string, revision)
        XCTAssertEqual(status["queuedSilently"]?.bool, false)

        let versions = try payload(router.call(name: "list_versions", arguments: .object(["dashboardId": .string(id)])))
        XCTAssertEqual(versions["revisions"]?.array?.first?["reviewed"]?.bool, true)
        XCTAssertEqual(versions["revisions"]?.array?.first?["activeOn"]?.array?.first?.string, "phone-b")

        let listed = try payload(router.call(name: "list_devices", arguments: .object([:])))
        XCTAssertEqual(listed["devices"]?.array?.first?["activeRevision"]?.string, revision)
        XCTAssertEqual(listed["devices"]?.array?.first?["history"]?.array?.count, 1)
    }

    func testFailedTransferKeepsCurrentDashboardAndRollbackRedeploys() throws {
        let device = FakeLANDevice(deviceId: "phone-c", name: "Hall iPhone")
        let harness = try makeHarness(device: device)
        let router = harness.router
        try pair(router, device: device, deviceId: "phone-c")

        let first = try createDashboard(harness.service, marker: "FIRST")
        let id = first.manifest.dashboardId
        try deploy(router, harness: harness, dashboardId: id, revision: first.manifest.revision, deviceId: "phone-c", deploymentId: "dep-first")
        XCTAssertEqual(device.runtime.activeRevision, first.manifest.revision)

        let landscape = try harness.service.updateDashboard(
            arguments: .object([
                "dashboardId": .string(id),
                "name": .string("Alpha"),
                "baseRevision": .string(first.manifest.revision),
                "target": .object(["orientation": .string("landscape"), "width": .int(1024), "height": .int(768)]),
                "files": .array([.object(["path": .string("index.html"), "text": .string("<p>WIDE</p>")])])
            ])
        )
        _ = router.call(name: "preview_dashboard", arguments: .object(["dashboardId": .string(id)]))
        let mismatch = router.call(
            name: "deploy_dashboard",
            arguments: .object([
                "deviceId": .string("phone-c"),
                "dashboardId": .string(id),
                "revision": .string(landscape.manifest.revision),
                "approved": .bool(true),
                "deploymentId": .string("dep-wide")
            ])
        )
        XCTAssertTrue(mismatch.isError)
        XCTAssertEqual(mismatch.errorCode, "validation_failed")
        let failed = try payload(mismatch)
        XCTAssertEqual(failed["phase"]?.string, "failed")
        XCTAssertEqual(failed["error"]?.string, TransferFailure.targetMismatch.rawValue)
        XCTAssertEqual(failed["currentDashboardKept"]?.bool, true)
        XCTAssertEqual(failed["activeRevision"]?.string, first.manifest.revision)
        XCTAssertEqual(device.runtime.activeRevision, first.manifest.revision)
        XCTAssertEqual(device.receivedFiles["index.html"], first.files["index.html"])

        let recorded = try payload(router.call(name: "get_deployment", arguments: .object(["deploymentId": .string("dep-wide")])))
        XCTAssertEqual(recorded["phase"]?.string, "failed")
        XCTAssertEqual(recorded["activeRevision"]?.string, first.manifest.revision)

        var corrupted = try harness.service.transferBlobs(for: first)
        corrupted[0].sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(
            try harness.service.devices.deploy(
                deviceId: "phone-c",
                revision: try harness.service.storedRevision(for: first.manifest),
                files: corrupted,
                deploymentId: "dep-corrupt"
            )
        ) { error in
            XCTAssertEqual((error as? ControllerError)?.code, .validationFailed)
        }
        XCTAssertEqual(device.runtime.activeRevision, first.manifest.revision)

        let second = try harness.service.updateDashboard(
            arguments: .object([
                "dashboardId": .string(id),
                "name": .string("Alpha"),
                "baseRevision": .string(landscape.manifest.revision),
                "files": .array([.object(["path": .string("index.html"), "text": .string("<p>SECOND</p>")])])
            ])
        )
        try deploy(router, harness: harness, dashboardId: id, revision: second.manifest.revision, deviceId: "phone-c", deploymentId: "dep-second")
        XCTAssertEqual(device.runtime.activeRevision, second.manifest.revision)

        let notApproved = router.call(
            name: "rollback_dashboard",
            arguments: .object(["deviceId": .string("phone-c"), "revision": .string(first.manifest.revision)])
        )
        XCTAssertEqual(notApproved.errorCode, "permission_required")

        let neverActive = router.call(
            name: "rollback_dashboard",
            arguments: .object([
                "deviceId": .string("phone-c"), "revision": .string(landscape.manifest.revision), "approved": .bool(true)
            ])
        )
        XCTAssertEqual(neverActive.errorCode, "validation_failed")

        let rolled = router.call(
            name: "rollback_dashboard",
            arguments: .object([
                "deviceId": .string("phone-c"), "revision": .string(first.manifest.revision), "approved": .bool(true)
            ])
        )
        XCTAssertFalse(rolled.isError, rolled.content.description)
        XCTAssertEqual(try payload(rolled)["phase"]?.string, "active")
        XCTAssertEqual(device.runtime.activeRevision, first.manifest.revision)
        XCTAssertEqual(device.receivedFiles["index.html"], first.files["index.html"])
        XCTAssertEqual(harness.service.devices.listDevices().first?.device.history.count, 2)
    }

    func testOfflineDeviceAndUnknownDeviceAreHonestErrors() throws {
        let device = FakeLANDevice(deviceId: "phone-d", name: "Offline iPhone")
        let harness = try makeHarness(device: device)
        let router = harness.router
        try pair(router, device: device, deviceId: "phone-d")
        let created = try createDashboard(harness.service, marker: "OFF")
        _ = router.call(name: "preview_dashboard", arguments: .object(["dashboardId": .string(created.manifest.dashboardId)]))

        device.online = false
        let offline = router.call(
            name: "deploy_dashboard",
            arguments: .object([
                "deviceId": .string("phone-d"),
                "dashboardId": .string(created.manifest.dashboardId),
                "revision": .string(created.manifest.revision),
                "approved": .bool(true)
            ])
        )
        XCTAssertEqual(offline.errorCode, "device_offline")
        XCTAssertNil(device.runtime.activeRevision)
        let probed = try payload(router.call(name: "get_device", arguments: .object(["deviceId": .string("phone-d")])))
        XCTAssertEqual(probed["reachable"]?.bool, false)

        device.online = true
        let back = try payload(router.call(name: "get_device", arguments: .object(["deviceId": .string("phone-d")])))
        XCTAssertEqual(back["reachable"]?.bool, true)

        XCTAssertEqual(router.call(name: "get_device", arguments: .object(["deviceId": .string("ghost")])).errorCode, "not_paired")
        XCTAssertEqual(
            router.call(
                name: "deploy_dashboard",
                arguments: .object([
                    "deviceId": .string("ghost"),
                    "dashboardId": .string(created.manifest.dashboardId),
                    "revision": .string(created.manifest.revision),
                    "approved": .bool(true)
                ])
            ).errorCode,
            "not_paired"
        )
        XCTAssertEqual(
            router.call(name: "get_deployment", arguments: .object(["deploymentId": .string("nope")])).errorCode,
            "validation_failed"
        )
    }

    func testWithoutTransportListingWorksAndPairingIsOffline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-ctrl-\(UUID().uuidString)")
        let store = try DashboardPackageStore(root: root)
        let service = ControllerService(store: store, renderer: InjectedPreviewRenderer(capture: sampleCapture()))
        let router = MCPToolRouter(service: service)

        let listed = try payload(router.call(name: "list_devices", arguments: .object([:])))
        XCTAssertEqual(listed["devices"]?.array?.count, 0)
        XCTAssertEqual(listed["transportAvailable"]?.bool, false)
        XCTAssertEqual(
            router.call(name: "request_pairing", arguments: .object(["host": .string("10.0.0.5"), "port": .int(7843)])).errorCode,
            "device_offline"
        )
        XCTAssertEqual(
            router.call(name: "request_pairing", arguments: .object(["host": .string("10.0.0.5")])).errorCode,
            "validation_failed"
        )
        let manual = try payload(router.call(name: "discover_services", arguments: .object(["host": .string("10.0.0.5"), "port": .int(7843)])))
        XCTAssertEqual(manual["services"]?.array?.first?["source"]?.string, "manual")
        XCTAssertEqual(service.devices.directory.url.lastPathComponent, "devices.json")
    }

    func testForgetDeviceIsMacOnlyAndSameOwnerCanRePair() throws {
        let device = FakeLANDevice(deviceId: "phone-e", name: "Bedroom iPhone")
        let harness = try makeHarness(device: device)
        let router = harness.router
        try pair(router, device: device, deviceId: "phone-e")

        let forgotten = try payload(router.call(name: "forget_device", arguments: .object(["deviceId": .string("phone-e")])))
        XCTAssertEqual(forgotten["forgotten"]?.bool, true)
        XCTAssertEqual(forgotten["deviceErased"]?.bool, false)
        XCTAssertTrue(forgotten["detail"]?.string?.contains("two fingers") == true)
        XCTAssertTrue(forgotten["detail"]?.string?.contains("Disconnect") == true)
        XCTAssertTrue(device.isPaired, "forget on the Mac never erases the device")
        XCTAssertEqual(try payload(router.call(name: "list_devices", arguments: .object([:])))["devices"]?.array?.count, 0)

        try pair(router, device: device, deviceId: "phone-e")
        XCTAssertEqual(device.ownerPin, controllerIdentity.publicKey)
        XCTAssertEqual(harness.service.devices.listDevices().count, 1)
    }

    func testPairingCodeExpiresAndMismatchedCodeIsRejected() throws {
        let device = FakeLANDevice(deviceId: "phone-f", name: "Slow iPhone")
        let clock = MutableClock()
        let harness = try makeHarness(device: device, now: { clock.now })
        let router = harness.router

        let requested = router.call(name: "request_pairing", arguments: .object(["deviceId": .string("phone-f")]))
        XCTAssertFalse(requested.isError, requested.content.description)
        clock.now = clock.now.addingTimeInterval(PairingLimits.expirySeconds + 1)
        device.confirmLocally()
        let expired = router.call(name: "confirm_pairing", arguments: .object(["deviceId": .string("phone-f")]))
        XCTAssertEqual(expired.errorCode, "not_paired")
        if case .text(let text) = expired.content[0] {
            XCTAssertTrue(text.contains("expired"))
        }
        XCTAssertTrue(harness.service.devices.pendingPairings().isEmpty)

        #if canImport(CryptoKit)
        device.lieAboutCode = true
        let lying = router.call(name: "request_pairing", arguments: .object(["deviceId": .string("phone-f")]))
        XCTAssertEqual(lying.errorCode, "not_paired")
        if case .text(let text) = lying.content[0] {
            XCTAssertTrue(text.contains("code_mismatch"))
        }
        XCTAssertTrue(harness.service.devices.pendingPairings().isEmpty)
        #endif
    }

    func testHelloClaimingAnotherIdentityNeverReachesSAS() throws {
        let device = FakeLANDevice(deviceId: "phone-h", name: "Impostor iPhone")
        device.claimedHelloPin = PairingIdentityFactory.make(role: .device).publicKey
        let harness = try makeHarness(device: device)
        let router = harness.router

        let rejected = router.call(name: "request_pairing", arguments: .object(["deviceId": .string("phone-h")]))
        XCTAssertTrue(rejected.isError)
        XCTAssertEqual(rejected.errorCode, "not_paired")
        if case .text(let text) = rejected.content[0] {
            XCTAssertTrue(text.contains("identity_changed"), text)
        }
        XCTAssertNil(device.runtime.pairingCode, "pair.begin was never sent")
        XCTAssertTrue(harness.service.devices.pendingPairings().isEmpty)

        device.claimedHelloPin = nil
        let honest = try payload(router.call(name: "request_pairing", arguments: .object(["deviceId": .string("phone-h")])))
        XCTAssertEqual(honest["devicePinHex"]?.string, PeerPin.hex(device.identityPin), "the SAS binds to the handshake pin")
        XCTAssertEqual(honest["code"]?.string, device.runtime.pairingCode)
    }

    func testJSONRPCListsPairingAndDeployToolsWithApprovalSchema() throws {
        let device = FakeLANDevice(deviceId: "phone-g", name: "RPC iPhone")
        let harness = try makeHarness(device: device)
        let rpc = MCPJSONRPC(router: harness.router)
        let line = try rpc.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#) ?? ""
        let tools = try JSONValue.parse(Data(line.utf8))["result"]?["tools"]?.array ?? []
        let names = Set(tools.compactMap { $0["name"]?.string })
        for required in ["request_pairing", "confirm_pairing", "forget_device", "deploy_dashboard", "rollback_dashboard", "get_deployment"] {
            XCTAssertTrue(names.contains(required), required)
        }
        let deploy = try XCTUnwrap(tools.first { $0["name"]?.string == "deploy_dashboard" })
        let required = deploy["inputSchema"]?["required"]?.array?.compactMap(\.string) ?? []
        XCTAssertTrue(required.contains("approved"))
        XCTAssertTrue(required.contains("revision"))
        XCTAssertEqual(deploy["annotations"]?["destructiveHint"]?.bool, true)
        XCTAssertTrue(deploy["description"]?.string?.contains("previewed") == true)

        let help = try rpc.handle(
            line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_help","arguments":{"topic":"deploy"}}}"#
        ) ?? ""
        XCTAssertTrue(help.contains("current dashboard"))
        XCTAssertTrue(help.contains("not a runtime proxy"))
        let pairing = try rpc.handle(
            line: #"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"screenpunk://help/pairing"}}"#
        ) ?? ""
        XCTAssertTrue(pairing.contains("one owner"))
        XCTAssertTrue(pairing.contains("confirm_pairing"))
    }

    // MARK: Helpers

    private struct Harness {
        var service: ControllerService
        var router: MCPToolRouter
        var directoryURL: URL
    }

    private final class MutableClock: @unchecked Sendable {
        var now = Date()
    }

    func testScreenSetCommitFailureRetryAndSingleReplacement() throws {
        let device = FakeLANDevice(deviceId: "set-phone", name: "Phone")
        let harness = try makeHarness(device: device)
        try pair(harness.router, device: device, deviceId: "set-phone")
        let first = try createDashboard(harness.service, marker: "FIRST")
        let second = try createDashboard(harness.service, marker: "SECOND")
        _ = try harness.service.ship(record: first, deviceId: "set-phone", deploymentId: "initial")
        let before = harness.service.devices.directory.get("set-phone")
        device.failSetAtIndex = 1
        XCTAssertThrowsError(try harness.service.shipSet(records: [first, second], deviceId: "set-phone",
            selectedDashboardId: first.manifest.dashboardId, deploymentId: "set"))
        XCTAssertEqual(device.runtime.activeRevision, first.manifest.revision)
        XCTAssertEqual(device.installedSet?.count, 1)
        XCTAssertEqual(harness.service.devices.directory.get("set-phone")?.screenSet, before?.screenSet)
        device.failSetAtIndex = nil
        let receipt = try harness.service.shipSet(records: [first, second], deviceId: "set-phone",
            selectedDashboardId: first.manifest.dashboardId, deploymentId: "set")
        XCTAssertEqual(receipt.screens.map(\.dashboardId), [first.manifest.dashboardId, second.manifest.dashboardId])
        let attempts = device.deployAttempts
        let retry = try harness.service.shipSet(records: [first, second], deviceId: "set-phone",
            selectedDashboardId: first.manifest.dashboardId, deploymentId: "set")
        XCTAssertEqual(receipt, retry)
        XCTAssertEqual(device.deployAttempts, attempts)
        XCTAssertThrowsError(try harness.service.shipSet(records: [second, first], deviceId: "set-phone",
            selectedDashboardId: second.manifest.dashboardId, deploymentId: "set"))
        let reopened = DeviceDirectory(url: harness.directoryURL)
        XCTAssertEqual(reopened.get("set-phone")?.screenSet, receipt.screens)
        device.selectedDashboardId = second.manifest.dashboardId
        device.runtime.activeRevision = second.manifest.revision
        let queried = try harness.service.devices.device("set-phone", probe: true)
        XCTAssertEqual(queried.selectedDashboardId, second.manifest.dashboardId)
        XCTAssertEqual(queried.device.activeRevision, second.manifest.revision)
        _ = try harness.service.ship(record: second, deviceId: "set-phone", deploymentId: "single")
        XCTAssertEqual(device.installedSet?.map(\.dashboardId), [second.manifest.dashboardId])
        XCTAssertEqual(harness.service.devices.directory.get("set-phone")?.screenSet?.count, 1)
    }

    func testScreenSetPreflightRejectsDuplicatesAndUnsupportedPeersBeforeCredentials() throws {
        let device = FakeLANDevice(deviceId: "set-preflight", name: "Phone")
        let harness = try makeHarness(device: device)
        try pair(harness.router, device: device, deviceId: "set-preflight")
        let screen = try createDashboard(harness.service, marker: "BASE")
        XCTAssertThrowsError(try harness.service.shipSet(records: [screen, screen], deviceId: device.runtime.profile.deviceId,
            selectedDashboardId: screen.manifest.dashboardId))
        device.supportsScreenSets = false
        XCTAssertThrowsError(try harness.service.shipSet(records: [screen], deviceId: device.runtime.profile.deviceId,
            selectedDashboardId: screen.manifest.dashboardId)) { error in
                XCTAssertEqual((error as? ControllerError)?.code, .unsupportedVersion)
        }
        XCTAssertEqual(device.deployAttempts, 0)
        XCTAssertNil(device.installedSet)
    }

    func testEscapedEnvelopeSizeIsRejectedBeforeSending() throws {
        let device = FakeLANDevice(deviceId: "size-phone", name: "Phone")
        device.maxTransferBytes = nil // Legacy peers retain the 2 MiB wire limit.
        let harness = try makeHarness(device: device)
        try pair(harness.router, device: device, deviceId: "size-phone")
        let screen = try createDashboard(harness.service, marker: "SMALL")
        let revision = try harness.service.storedRevision(for: screen.manifest)
        let deployment = DeploymentRecord(deploymentId: "size", revision: revision.revision,
            dashboardId: revision.dashboardId, deviceId: "size-phone", phase: .queued)
        let item = LANScreenSetItem(name: String(repeating: "\"", count: 600_000),
            deployment: LANDeployBody(deployment: deployment, revision: revision, files: try harness.service.transferBlobs(for: screen)))
        let body = LANScreenSetDeployBody(deploymentId: "size", deviceId: "size-phone", screens: [item], selectedDashboardId: revision.dashboardId)
        XCTAssertLessThan(try LANCodec.encodePayload(body).utf8.count + 512, LANProtocolLimits.maxMessageBytes,
            "The old estimate would have accepted this escaped payload")
        XCTAssertThrowsError(try harness.service.devices.deployScreenSet(body)) { error in
            let detail = (error as? ControllerError)?.detail ?? ""
            XCTAssertTrue(detail.contains("transfer limit"))
            XCTAssertTrue(detail.contains("2097152 bytes"))
            XCTAssertTrue(detail.contains("Update Screenpunk"))
        }
        XCTAssertEqual(device.deployAttempts, 0)
        XCTAssertNil(device.installedSet)
    }

    func testDynamicPathsRequireNewCapabilityBeforeDeploy() throws {
        let device = FakeLANDevice(deviceId: "dynamic-assets", name: "Fixture")
        device.supportsPublicReads = true
        let harness = try makeHarness(device: device)
        try pair(harness.router, device: device, deviceId: "dynamic-assets")
        var connection = ManifestConnection(alias: "photos", required: true)
        connection.publicHTTP = .init(origin: "https://images.example.org", operations: [
            .init(name: "photo", path: "/photos/{filename}", response: "raster", parameters: ["filename": .init(location: "path", pathSegment: .init(maxLength: 128))])])
        let screen = try harness.service.store.putDashboard(dashboardId: nil, name: "Dynamic assets", baseRevision: nil,
            target: harness.service.defaultTarget(), connections: [connection], files: [.init(path: "index.html", text: "<p>Synthetic</p>")])
        _ = try harness.service.approvePublicConnections(dashboardId: screen.manifest.dashboardId, revision: screen.manifest.revision, approved: true)
        XCTAssertThrowsError(try harness.service.shipSet(records: [screen], deviceId: "dynamic-assets", selectedDashboardId: screen.manifest.dashboardId)) {
            XCTAssertEqual(($0 as? ControllerError)?.code, .unsupportedVersion)
        }
        XCTAssertEqual(device.deployAttempts, 0)
        XCTAssertNil(device.installedSet)
        XCTAssertNoThrow(try harness.service.devices.requireScreenSetSupport(deviceId: "dynamic-assets", publicReads: true))
        device.supportsDynamicPublicPaths = true
        XCTAssertNoThrow(try harness.service.devices.requireScreenSetSupport(deviceId: "dynamic-assets", publicReads: true, dynamicPublicPaths: true))
    }

    private func makeHarness(
        device: FakeLANDevice,
        identity: PairingIdentity? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-ctrl-\(UUID().uuidString)")
        let store = try DashboardPackageStore(root: root)
        let hub = LoopbackDiscovery()
        hub.advertise(device.runtime.advertisement)
        let directoryURL = DeviceDirectory.defaultURL(controllerHome: root)
        let coordinator = DeviceCoordinator(
            directory: DeviceDirectory(url: directoryURL),
            hub: hub,
            linkFactory: FakeLANLinkFactory(device: device, controllerIdentity: identity ?? controllerIdentity),
            now: now
        )
        let service = ControllerService(store: store, renderer: InjectedPreviewRenderer(capture: sampleCapture()), devices: coordinator)
        return Harness(service: service, router: MCPToolRouter(service: service), directoryURL: directoryURL)
    }

    private func pair(_ router: MCPToolRouter, device: FakeLANDevice, deviceId: String) throws {
        let requested = router.call(name: "request_pairing", arguments: .object(["deviceId": .string(deviceId)]))
        XCTAssertFalse(requested.isError, requested.content.description)
        device.confirmLocally()
        let confirmed = router.call(name: "confirm_pairing", arguments: .object(["deviceId": .string(deviceId)]))
        XCTAssertFalse(confirmed.isError, confirmed.content.description)
        XCTAssertTrue(device.isPaired)
    }

    private func deploy(
        _ router: MCPToolRouter,
        harness: Harness,
        dashboardId: String,
        revision: String,
        deviceId: String,
        deploymentId: String
    ) throws {
        let preview = router.call(
            name: "preview_dashboard",
            arguments: .object(["dashboardId": .string(dashboardId), "revision": .string(revision)])
        )
        XCTAssertFalse(preview.isError, preview.content.description)
        let deployed = router.call(
            name: "deploy_dashboard",
            arguments: .object([
                "deviceId": .string(deviceId),
                "dashboardId": .string(dashboardId),
                "revision": .string(revision),
                "approved": .bool(true),
                "deploymentId": .string(deploymentId)
            ])
        )
        XCTAssertFalse(deployed.isError, deployed.content.description)
        XCTAssertEqual(try payload(deployed)["phase"]?.string, "active")
    }

    private func createDashboard(_ service: ControllerService, marker: String) throws -> DashboardRevisionRecord {
        try service.updateDashboard(
            arguments: .object([
                "name": .string("Alpha"),
                "files": .array([
                    .object(["path": .string("index.html"), "text": .string("<!doctype html><p>\(marker)</p><script src=\"app.js\"></script>")]),
                    .object(["path": .string("app.js"), "text": .string("console.log('\(marker)')")])
                ])
            ])
        )
    }

    private func payload(_ result: MCPToolResult) throws -> JSONValue {
        guard case .text(let text) = result.content.first else {
            throw ControllerError.validationFailed(detail: "expected text content")
        }
        return try JSONValue.parse(Data(text.utf8))
    }

    private func sampleCapture() -> PreviewCapture {
        PreviewCapture(
            png: testPNG(),
            width: 390,
            height: 844,
            revision: "pending",
            digest: "pending",
            live: true,
            connectionHealth: "none",
            diagnostics: ["injected"]
        )
    }
}

private struct MultipleDevicesFactory: DeviceLinkFactory {
    let devices: [FakeLANDevice]
    let controllerIdentity: PairingIdentity
    func makeLink() throws -> DeviceLink { MultipleDevicesLink(devices: devices, controllerPin: controllerIdentity.publicKey) }
}

private final class MultipleDevicesLink: DeviceLink {
    let devices: [FakeLANDevice]
    let controllerPin: [UInt8]
    var connected: FakeLANLink?
    var devicePin: [UInt8]? { connected?.devicePin }
    init(devices: [FakeLANDevice], controllerPin: [UInt8]) { self.devices = devices; self.controllerPin = controllerPin }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws {
        guard let device = devices.first(where: { $0.host == host && $0.port == port }) else { throw TransferFailure.deviceOffline }
        let link = FakeLANLink(device: device, controllerPin: controllerPin)
        try link.connect(host: host, port: port, pinnedDevice: pinnedDevice)
        connected = link
    }
    func hello() throws -> LANHello { try connected!.hello() }
    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult { try connected!.beginPairing(nonce: nonce) }
    func confirmPairing(code: String) throws { try connected!.confirmPairing(code: code) }
    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord { try connected!.deploy(body) }
    func queryActive() throws -> String? { try connected!.queryActive() }
    func cancel() { connected?.cancel(); connected = nil }
}

extension PairingDeployTests {
    func testGeneralServiceDeclarationsSurviveAuthoringAndRejectOlderDevice() throws {
        let device = FakeLANDevice(deviceId: "services-phone", name: "Services")
        device.supportsHomeAssistant = true
        let harness = try makeHarness(device: device)
        try pair(harness.router, device: device, deviceId: "services-phone")
        let record = try harness.service.updateDashboard(arguments: .object([
            "name": .string("General service control"),
            "connections": .array([.object(["alias": .string("home"), "required": .bool(true),
                "serviceCalls": .array([.object(["domain": .string("climate"), "service": .string("set_temperature"),
                    "entityIds": .array([.string("climate.room")])])])])]),
            "files": .array([.object(["path": .string("index.html"), "text": .string("<p>Thermostat</p>")])])]))
        XCTAssertEqual(record.manifest.connections.first?.serviceCalls?.first?.service, "set_temperature")
        harness.service.homeAssistantConfiguration = { dashboard, revision, id in
            HomeAssistantProvisioning(dashboardId: dashboard, connectionId: "connection", provisioningId: id,
                revision: revision, origin: "https://ha.example", token: "test-token")
        }
        XCTAssertThrowsError(try harness.service.ship(record: record, deviceId: "services-phone", deploymentId: "general-1"))
        XCTAssertEqual(device.deployAttempts, 0)
        XCTAssertNil(device.installedHomeAssistant)
        device.supportsGeneralServices = true
        let outcome = try harness.service.ship(record: record, deviceId: "services-phone", deploymentId: "general-1")
        XCTAssertEqual(device.installedHomeAssistant?.schemaVersion, 2)
        XCTAssertEqual(device.installedHomeAssistant?.revision, outcome.revision)
        XCTAssertEqual(device.installedHomeAssistant?.serviceCalls, record.manifest.connections.first?.serviceCalls)
    }
}


extension PairingDeployTests {
    func testCameraDeclarationsSurviveAuthoringAndProvisioningScope() throws {
        let device = FakeLANDevice(deviceId: "camera-phone", name: "Cameras")
        let harness = try makeHarness(device: device)
        let args: JSONValue = .object([
            "name": .string("Cameras"),
            "connections": .array([.object(["alias": .string("home"), "required": .bool(true),
                "cameraEntities": .array([.string("camera.deck")])])]),
            "files": .array([.object(["path": .string("index.html"), "text": .string("<p>Cameras</p>")])])])
        let record = try harness.service.updateDashboard(arguments: args)
        let stored = try harness.service.getDashboard(dashboardId: record.manifest.dashboardId, revision: record.manifest.revision)
        XCTAssertEqual(stored.manifest.connections.first?.cameraEntities, ["camera.deck"])
        let configuration = try HomeAssistantProvisioning(dashboardId: stored.manifest.dashboardId,
            connectionId: "home", provisioningId: "fixture", revision: stored.manifest.revision,
            origin: "https://ha.example", token: "test-token").scoped(to: stored.manifest)
        XCTAssertEqual(configuration.schemaVersion, 3)
        XCTAssertEqual(configuration.cameraEntities, ["camera.deck"])
        try configuration.validate()
        var invalid = args.object!
        invalid["connections"] = .array([.object(["alias": .string("home"),
            "cameraEntities": .array([.string("camera.*")])])])
        XCTAssertThrowsError(try harness.service.updateDashboard(arguments: .object(invalid)))
    }
}
