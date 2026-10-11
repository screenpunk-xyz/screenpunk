#if os(macOS)
import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

private struct HABrokerDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

private final class HABrokerSecrets: WorkbenchSecretProvider {
    var values: [String: Data] = [:]
    var beforeInstall: (() throws -> Void)?
    var beforeLoad: (() throws -> Void)?
    var removeFails=false
    func install(_ secret: Data, for authRef: String) throws { try beforeInstall?(); values[authRef] = secret }
    func load(authRef: String) throws -> Data {
        try beforeLoad?()
        guard let value = values[authRef] else { throw ConnectionFailure.permissionRequired }
        return value
    }
    func remove(authRef: String) throws { if removeFails { throw ConnectionFailure.permissionRequired }; values[authRef] = nil }
}

private final class HABrokerHTTP: HTTPTransport, @unchecked Sendable {
    var requests: [AuthorizedHTTPRequest] = []
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        return .init(status: 200, body: Data("{\"message\":\"API running.\"}".utf8))
    }
}

private struct HABrokerResolver: DestinationResolver {
    func addresses(for host: String) throws -> [String] { ["192.168.1.20"] }
}

private struct HABrokerLinkFactory: DeviceLinkFactory {
    let device: FakeLANDevice
    let controllerIdentity: PairingIdentity
    func makeLink() throws -> DeviceLink {
        FakeLANLink(device: device, controllerPin: controllerIdentity.publicKey)
    }
}

private final class HABrokerProvisioning: @unchecked Sendable {
    var sends = 0
    var fail = false
    var receivedToken: String?
    func provision(_ device: String, _ configuration: HomeAssistantProvisioning) throws
        -> HomeAssistantProvisioningReceipt {
        sends += 1
        receivedToken = configuration.token
        if fail { throw ConnectionFailure.deviceOffline }
        return .init(deviceId: device, dashboardId: configuration.dashboardId,
            revision: configuration.revision, connectionId: configuration.connectionId,
            provisioningId: configuration.provisioningId)
    }
}

final class WorkbenchHomeAssistantBrokerTests: XCTestCase {
    func testLocalReviewInstallsAndUnknownNeverResends() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-ha-broker-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"),
            withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: HABrokerDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html>Home</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "ha-dashboard", name: "Home", revision: "ha-revision",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"),
            connections: [.init(alias: "home", required: true)],
            files: [.init(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let device = FakeLANDevice(deviceId: "ha-device", name: "Fixture iPad")
        let owner = PairingIdentityFactory.make(role: .controller)
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("home"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        try controller.devices.directory.upsert(.init(
            device: PairedDevice(profile: device.runtime.profile, owner: owner, reachable: false),
            host: device.host, port: Int(device.port),
            devicePinHex: PeerPin.hex(device.identityPin), pairedAt: Date()))
        let secrets = HABrokerSecrets()
        let http = HABrokerHTTP()
        let provisioning = HABrokerProvisioning()
        let attempts = try WorkbenchHomeAssistantAttemptFileStore(path:
            root.appendingPathComponent("machine/home-assistant").path)
        let native = WorkbenchNativeComposition(activate: {
            $0.devices.attach(HABrokerLinkFactory(device: device, controllerIdentity: owner))
        }, deactivate: { controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native, machineAuthorityPath: root.appendingPathComponent("machine/authority").path,
            secrets: secrets, mutationGate: {}, homeAssistantAttempts: attempts,
            homeAssistantTransport: http, homeAssistantResolver: HABrokerResolver(),
            homeAssistantProvisioner: { try provisioning.provision($0, $1) })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:
            root.appendingPathComponent("runtime"), limits: .init(timeout: 1))
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }

        let ordinary = WorkbenchBrokerClient(environment: environment)
        try ordinary.connect(); defer { ordinary.close() }
        XCTAssertThrowsError(try ordinary.beginHomeAssistantReview(deviceId: "ha-device",
            dashboardId: "ha-dashboard", revision: "ha-revision",
            origin: "https://home.example.test:8123")) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertEqual(provisioning.sends, 0)

        let local = WorkbenchBrokerClient(environment: environment,
            credentialScope: .localReview)
        try local.connect(); defer { local.close() }
        let review = try local.beginHomeAssistantReview(deviceId: "ha-device",
            dashboardId: "ha-dashboard", revision: "ha-revision",
            origin: "https://home.example.test:8123")
        XCTAssertEqual(review.declaration.alias, "home")
        XCTAssertEqual(review.packageDigest, manifest.digest)
        XCTAssertEqual(review.devicePin, PeerPin.hex(device.identityPin))
        Thread.sleep(forTimeInterval: 1.2)
        let installed = try local.confirmHomeAssistantReview(review,
            secret: Data("private-token".utf8))
        XCTAssertEqual(installed.phase, "installed")
        XCTAssertEqual(provisioning.sends, 1)
        XCTAssertEqual(provisioning.receivedToken, "private-token")
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests[0].url.absoluteString, "https://home.example.test:8123/api/")
        XCTAssertEqual(try local.homeAssistantStatus(intentId: review.intentId), installed)
        try ordinary.connect()
        XCTAssertThrowsError(try ordinary.homeAssistantStatus(intentId: review.intentId)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        try ordinary.connect()
        XCTAssertThrowsError(try ordinary.cancelHomeAssistantPrepared(intentId: review.intentId)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        let encodedStatus = try JSONEncoder().encode(installed)
        XCTAssertFalse(String(decoding: encodedStatus, as: UTF8.self).contains("private-token"))
        for authRef in secrets.values.keys {
            XCTAssertFalse(String(decoding: encodedStatus, as: UTF8.self).contains(authRef))
        }

        provisioning.fail = true
        let second = try local.beginHomeAssistantReview(deviceId: "ha-device",
            dashboardId: "ha-dashboard", revision: "ha-revision",
            origin: "https://home.example.test:8123")
        XCTAssertThrowsError(try local.confirmHomeAssistantReview(second,
            secret: Data("second-private-token".utf8))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .remoteOutcomeUnknown)
        }
        try local.connect()
        XCTAssertEqual(try local.homeAssistantStatus(intentId: second.intentId).phase, "unknown")
        XCTAssertEqual(provisioning.sends, 2)
        XCTAssertThrowsError(try local.confirmHomeAssistantReview(second,
            secret: Data("second-private-token".utf8)))
        XCTAssertEqual(provisioning.sends, 2)
        let reopened = try WorkbenchHomeAssistantAttemptFileStore(path:
            root.appendingPathComponent("machine/home-assistant").path)
        XCTAssertEqual(try reopened.load(intentId: second.intentId)?.phase, .unknown)
    }
}
extension WorkbenchHomeAssistantBrokerTests {
    func testReviewerConcurrentCancelLeavesInstalledSecretUnrecoverable() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-ha-broker-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"),
            withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: HABrokerDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html>Home</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "ha-dashboard", name: "Home", revision: "ha-revision",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"),
            connections: [.init(alias: "home", required: true)],
            files: [.init(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let device = FakeLANDevice(deviceId: "ha-device", name: "Fixture iPad")
        let owner = PairingIdentityFactory.make(role: .controller)
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("home"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        try controller.devices.directory.upsert(.init(
            device: PairedDevice(profile: device.runtime.profile, owner: owner, reachable: false),
            host: device.host, port: Int(device.port),
            devicePinHex: PeerPin.hex(device.identityPin), pairedAt: Date()))
        let secrets = HABrokerSecrets()
        let http = HABrokerHTTP()
        let provisioning = HABrokerProvisioning()
        let attempts = try WorkbenchHomeAssistantAttemptFileStore(path:
            root.appendingPathComponent("machine/home-assistant").path)
        let native = WorkbenchNativeComposition(activate: {
            $0.devices.attach(HABrokerLinkFactory(device: device, controllerIdentity: owner))
        }, deactivate: { controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native, machineAuthorityPath: root.appendingPathComponent("machine/authority").path,
            secrets: secrets, mutationGate: {}, homeAssistantAttempts: attempts,
            homeAssistantTransport: http, homeAssistantResolver: HABrokerResolver(),
            homeAssistantProvisioner: { try provisioning.provision($0, $1) })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:
            root.appendingPathComponent("runtime"), limits: .init(timeout: 1))
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }


        let local=WorkbenchBrokerClient(environment:environment,credentialScope:.localReview)
        try local.connect();defer { local.close() }
        let review=try local.beginHomeAssistantReview(deviceId:"ha-device",dashboardId:"ha-dashboard",
            revision:"ha-revision",origin:"https://home.example.test:8123")

        let entered=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
        secrets.beforeInstall={ entered.signal();guard resume.wait(timeout:.now()+5) == .success else {throw ConnectionFailure.permissionRequired} }
        let outcome=ReviewerHAOutcome()
        DispatchQueue.global().async {
            do { _ = try local.confirmHomeAssistantReview(review,secret:Data("reviewer-race-token".utf8)) }
            catch { outcome.error=error }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout:.now()+3),.success)
        let cancel=WorkbenchBrokerClient(environment:environment,credentialScope:.localReview)
        try cancel.connect();defer {cancel.close()}
        let cancelDone=DispatchSemaphore(value:0)
        let cancelOutcome=ReviewerHAOutcome()
        DispatchQueue.global().async {
            do { _ = try cancel.cancelHomeAssistantPrepared(intentId:review.intentId) }
            catch { cancelOutcome.error=error }
            cancelDone.signal()
        }
        resume.signal()
        XCTAssertEqual(done.wait(timeout:.now()+3),.success)
        XCTAssertEqual(cancelDone.wait(timeout:.now()+3),.success)
        let final=try XCTUnwrap(attempts.load(intentId:review.intentId))
        if final.phase == .cancelled {
            XCTAssertTrue(secrets.values.isEmpty, "cancelled must mean no credential remains")
            XCTAssertEqual(provisioning.sends,0)
        } else {
            XCTAssertNotEqual(final.phase,.cleanupPending)
            XCTAssertNotEqual(final.phase,.preparing)
            XCTAssertNotNil(cancelOutcome.error, "cancellation cannot claim success while credential is retained")
        }
        print("REVIEWER_HA_CANCEL_RACE journal=\(final.phase) secret_count=\(secrets.values.count) device_sends=\(provisioning.sends)")
    }
    func testReviewerContextChangeDuringCredentialLoadCrossesDeviceSend() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-ha-broker-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"),
            withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: HABrokerDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html>Home</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "ha-dashboard", name: "Home", revision: "ha-revision",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"),
            connections: [.init(alias: "home", required: true)],
            files: [.init(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let device = FakeLANDevice(deviceId: "ha-device", name: "Fixture iPad")
        let owner = PairingIdentityFactory.make(role: .controller)
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("home"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        try controller.devices.directory.upsert(.init(
            device: PairedDevice(profile: device.runtime.profile, owner: owner, reachable: false),
            host: device.host, port: Int(device.port),
            devicePinHex: PeerPin.hex(device.identityPin), pairedAt: Date()))
        let secrets = HABrokerSecrets()
        let http = HABrokerHTTP()
        let provisioning = HABrokerProvisioning()
        let attempts = try WorkbenchHomeAssistantAttemptFileStore(path:
            root.appendingPathComponent("machine/home-assistant").path)
        let native = WorkbenchNativeComposition(activate: {
            $0.devices.attach(HABrokerLinkFactory(device: device, controllerIdentity: owner))
        }, deactivate: { controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native, machineAuthorityPath: root.appendingPathComponent("machine/authority").path,
            secrets: secrets, mutationGate: {}, homeAssistantAttempts: attempts,
            homeAssistantTransport: http, homeAssistantResolver: HABrokerResolver(),
            homeAssistantProvisioner: { try provisioning.provision($0, $1) })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:
            root.appendingPathComponent("runtime"), limits: .init(timeout: 1))
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }


        let local=WorkbenchBrokerClient(environment:environment,credentialScope:.localReview)
        try local.connect();defer { local.close() }
        let review=try local.beginHomeAssistantReview(deviceId:"ha-device",dashboardId:"ha-dashboard",
            revision:"ha-revision",origin:"https://home.example.test:8123")

        secrets.beforeLoad={ _ = try workspace.create(at:root.appendingPathComponent("changed-selection").path) }
        XCTAssertThrowsError(try local.confirmHomeAssistantReview(review,
            secret:Data("reviewer-context-token".utf8))) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code,.workspaceConflict)
        }
        XCTAssertNotEqual(try workspace.current()?.descriptor.workspaceId,review.workspaceId)
        XCTAssertEqual(provisioning.sends,0)
        XCTAssertEqual(try attempts.load(intentId:review.intentId)?.phase,.prepared)
        print("REVIEWER_HA_CONTEXT_RACE changed_workspace_before_device_send=true sends=0")
    }
    func testReviewerActualCoordinatorReplaysAcceptedHARequest() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-ha-broker-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"),
            withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: HABrokerDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html>Home</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "ha-dashboard", name: "Home", revision: "ha-revision",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"),
            connections: [.init(alias: "home", required: true)],
            files: [.init(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let device = FakeLANDevice(deviceId: "ha-device", name: "Fixture iPad")
        let owner = PairingIdentityFactory.make(role: .controller)
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("home"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        try controller.devices.directory.upsert(.init(
            device: PairedDevice(profile: device.runtime.profile, owner: owner, reachable: false),
            host: device.host, port: Int(device.port),
            devicePinHex: PeerPin.hex(device.identityPin), pairedAt: Date()))
        let secrets = HABrokerSecrets()
        let http = HABrokerHTTP()
        let attempts = try WorkbenchHomeAssistantAttemptFileStore(path:
            root.appendingPathComponent("machine/home-assistant").path)
        let replay=ReviewerHADropState()
        device.supportsHomeAssistant=true
        let native = WorkbenchNativeComposition(activate: {
            $0.devices.attach(ReviewerHADropFactory(device:device,controllerIdentity:owner,state:replay))
        }, deactivate: { controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native, machineAuthorityPath: root.appendingPathComponent("machine/authority").path,
            secrets: secrets, mutationGate: {}, homeAssistantAttempts: attempts,
            homeAssistantTransport: http, homeAssistantResolver: HABrokerResolver(),
            homeAssistantProvisioner: { try controller.devices.provisionHomeAssistant(deviceId:$0,configuration:$1) })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:
            root.appendingPathComponent("runtime"), limits: .init(timeout: 1))
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }


        let local=WorkbenchBrokerClient(environment:environment,credentialScope:.localReview)
        try local.connect();defer { local.close() }
        let review=try local.beginHomeAssistantReview(deviceId:"ha-device",dashboardId:"ha-dashboard",
            revision:"ha-revision",origin:"https://home.example.test:8123")

        try controller.devices.requireHomeAssistantSupport(deviceId:"ha-device")
        XCTAssertThrowsError(try local.confirmHomeAssistantReview(review,
            secret:Data("reviewer-native-token".utf8))) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code,.remoteOutcomeUnknown)
        }
        XCTAssertEqual(replay.calls,1)
        XCTAssertEqual(Set(replay.ids).count,1)
        XCTAssertEqual(try attempts.load(intentId:review.intentId)?.phase,.unknown)
        print("REVIEWER_HA_NATIVE_REPLAY accepted_then_drop=true native_calls=1 outcome=unknown")
    }
}
#endif


#if os(macOS)
private final class ReviewerHAOutcome: @unchecked Sendable { var error:Error? }
private final class ReviewerHADropState: @unchecked Sendable {
    var calls=0;var ids:[String]=[]
}
private final class ReviewerHADropLink: DeviceLink {
    let inner:FakeLANLink;let state:ReviewerHADropState
    init(device:FakeLANDevice,owner:PairingIdentity,state:ReviewerHADropState) {
        inner=FakeLANLink(device:device,controllerPin:owner.publicKey);self.state=state
    }
    var devicePin:[UInt8]? {inner.devicePin}
    func connect(host:String,port:UInt16,pinnedDevice:[UInt8]?) throws {try inner.connect(host:host,port:port,pinnedDevice:pinnedDevice)}
    func hello() throws -> LANHello {try inner.hello()}
    func beginPairing(nonce:[UInt8]) throws -> LANPairBeginResult {try inner.beginPairing(nonce:nonce)}
    func confirmPairing(code:String) throws {try inner.confirmPairing(code:code)}
    func deploy(_ body:LANDeployBody) throws -> DeploymentRecord {try inner.deploy(body)}
    func queryActive() throws -> String? {try inner.queryActive()}
    func provisionHomeAssistant(_ value:HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt {
        try value.validate()
        state.calls+=1;state.ids.append(value.provisioningId)
        if state.calls==1 {throw TransferFailure.interrupted}
        return .init(deviceId:inner.device.runtime.profile.deviceId,dashboardId:value.dashboardId,
            revision:value.revision,connectionId:value.connectionId,provisioningId:value.provisioningId)
    }
    func cancel(){inner.cancel()}
}
private struct ReviewerHADropFactory: DeviceLinkFactory {
    let device:FakeLANDevice;let controllerIdentity:PairingIdentity;let state:ReviewerHADropState
    func makeLink() throws -> DeviceLink {ReviewerHADropLink(device:device,owner:controllerIdentity,state:state)}
}
#endif


extension WorkbenchHomeAssistantBrokerTests {
    func testReviewerSocketTicketReplacementAndChangedSelectionFailClosed() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-ha-broker-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"),
            withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: HABrokerDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html>Home</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "ha-dashboard", name: "Home", revision: "ha-revision",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"),
            connections: [.init(alias: "home", required: true)],
            files: [.init(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let device = FakeLANDevice(deviceId: "ha-device", name: "Fixture iPad")
        let owner = PairingIdentityFactory.make(role: .controller)
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("home"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        try controller.devices.directory.upsert(.init(
            device: PairedDevice(profile: device.runtime.profile, owner: owner, reachable: false),
            host: device.host, port: Int(device.port),
            devicePinHex: PeerPin.hex(device.identityPin), pairedAt: Date()))
        let secrets = HABrokerSecrets()
        let http = HABrokerHTTP()
        let provisioning = HABrokerProvisioning()
        let attempts = try WorkbenchHomeAssistantAttemptFileStore(path:
            root.appendingPathComponent("machine/home-assistant").path)
        let native = WorkbenchNativeComposition(activate: {
            $0.devices.attach(HABrokerLinkFactory(device: device, controllerIdentity: owner))
        }, deactivate: { controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native, machineAuthorityPath: root.appendingPathComponent("machine/authority").path,
            secrets: secrets, mutationGate: {}, homeAssistantAttempts: attempts,
            homeAssistantTransport: http, homeAssistantResolver: HABrokerResolver(),
            homeAssistantProvisioner: { try provisioning.provision($0, $1) })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:
            root.appendingPathComponent("runtime"), limits: .init(timeout: 1))
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }

        let local = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview)
        try local.connect(); defer { local.close() }
        func begin() throws -> WorkbenchHomeAssistantReview {
            try local.beginHomeAssistantReview(deviceId: "ha-device", dashboardId: "ha-dashboard",
                revision: "ha-revision", origin: "https://home.example.test:8123")
        }
        let first = try begin()
        let replacement = try begin()
        XCTAssertThrowsError(try local.confirmHomeAssistantReview(first, secret: Data("fixture-token".utf8)))
        try local.connect()
        XCTAssertThrowsError(try local.confirmHomeAssistantReview(replacement, secret: Data("fixture-token".utf8)))
        try local.connect()
        let review = try begin()
        let other = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview)
        try other.connect(); defer { other.close() }
        XCTAssertThrowsError(try other.confirmHomeAssistantReview(review, secret: Data("fixture-token".utf8)))
        _ = try workspace.create(at: root.appendingPathComponent("changed-before-confirm").path)
        XCTAssertThrowsError(try local.confirmHomeAssistantReview(review, secret: Data("fixture-token".utf8)))
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertEqual(http.requests.count, 0)
        XCTAssertEqual(provisioning.sends, 0)
        print("REVIEWER_HA_TICKETS replacement_cross_socket_replay_changed_selection=rejected api_calls=0 secrets=0 device_sends=0")
    }
}
