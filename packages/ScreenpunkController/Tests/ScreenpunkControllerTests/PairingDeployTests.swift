import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class PairingDeployTests: XCTestCase {
    private let controllerIdentity = PairingIdentityFactory.make(role: .controller)

    func testHomeAssistantPreflightPreservesScreenAndBindsInstalledRevision() throws {
        let device = FakeLANDevice(deviceId: "ha-phone", name: "HA Phone")
        let harness = try makeHarness(device: device)
        try pair(harness.router, device: device, deviceId: "ha-phone")
        let record = try harness.service.updateDashboard(arguments: .object([
            "name": .string("Lights"),
            "connections": .array([.object(["alias": .string("home"), "required": .bool(true), "operations": .array([.object(["name": .string("getStates"), "kind": .string("http")])])])]),
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
        XCTAssertThrowsError(try harness.service.ship(record: record, deviceId: "ha-phone", deploymentId: "install-2")) { error in
            XCTAssertTrue((error as? ControllerError)?.detail.contains("screen was applied") == true)
        }
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
        XCTAssertTrue(forgotten["detail"]?.string?.contains("Unlink") == true)
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
