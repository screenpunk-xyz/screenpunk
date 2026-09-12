import XCTest
@testable import ScreenpunkCore

final class WorkbenchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let deviceKey = [UInt8](repeating: 0x01, count: 32)
    private let controllerKey = [UInt8](repeating: 0x02, count: 32)
    private let attackerKey = [UInt8](repeating: 0x99, count: 32)
    private let nonce = [UInt8](repeating: 0x03, count: 16)
    private let honestCode = "833492"

    private func makePhone(hub: LoopbackDiscovery) -> DeviceRuntime {
        let identity = PairingIdentityFactory.make(role: .device, bytes: deviceKey)
        let profile = DeviceProfile(deviceId: "phone-1", name: "iPhone")
        let ad = AdvertisedDevice(
            deviceId: "phone-1",
            host: "127.0.0.1",
            port: 7843,
            source: .loopback
        )
        var phone = DeviceRuntime(identity: identity, profile: profile, advertisement: ad)
        phone.advertise(on: hub)
        return phone
    }

    private func makeWorkbench() -> WorkbenchSession {
        WorkbenchSession(
            controllerIdentity: PairingIdentityFactory.make(role: .controller, bytes: controllerKey)
        )
    }

    private func pair(
        _ workbench: inout WorkbenchSession,
        phone: inout DeviceRuntime,
        hub: LoopbackDiscovery
    ) throws {
        workbench.refreshDiscovery(hub)
        let advertised = try XCTUnwrap(workbench.advertisements.first)
        try workbench.beginPairing(
            advertised: advertised,
            phone: &phone,
            expectedCode: honestCode,
            clock: FixedClock(start),
            nonce: nonce
        )
        try workbench.confirmPairing(
            deviceId: advertised.deviceId,
            code: honestCode,
            phone: &phone,
            clock: FixedClock(start)
        )
    }

    func testDiscoveryHasNoSecretsAndSupportsManual() {
        let hub = LoopbackDiscovery()
        hub.reset()
        var phone = makePhone(hub: hub)
        phone.advertise(on: hub)
        var workbench = makeWorkbench()
        workbench.refreshDiscovery(hub)
        XCTAssertEqual(workbench.advertisements.count, 1)
        XCTAssertEqual(DiscoveryService.type, "_screenpunk._tcp")
        XCTAssertFalse(workbench.advertisements[0].publishesSecrets)
        workbench.addManual(host: "10.0.0.8", port: 7843, hub: hub)
        XCTAssertTrue(workbench.advertisements.contains { $0.source == .manual })
        XCTAssertEqual(WorkbenchCopy.livePreview, "Live preview — actions control your devices")
    }

    func testPairingOneOwnerAndSecondMacRejected() throws {
        let hub = LoopbackDiscovery()
        hub.reset()
        var phone = makePhone(hub: hub)
        var workbench = makeWorkbench()
        try pair(&workbench, phone: &phone, hub: hub)
        XCTAssertTrue(phone.isPaired)
        XCTAssertEqual(workbench.devices.count, 1)

        var attacker = WorkbenchSession(
            controllerIdentity: PairingIdentityFactory.make(role: .controller, bytes: attackerKey)
        )
        attacker.refreshDiscovery(hub)
        XCTAssertThrowsError(
            try attacker.beginPairing(
                advertised: workbench.advertisements[0],
                phone: &phone,
                expectedCode: "287900",
                clock: FixedClock(start),
                nonce: nonce
            )
        ) { error in
            XCTAssertEqual(error as? PairingFailure, .secondOwner)
        }
    }

    func testDeployPreviewRollbackAndFailedTransferKeepsCurrent() throws {
        let hub = LoopbackDiscovery()
        hub.reset()
        var phone = makePhone(hub: hub)
        var workbench = makeWorkbench()
        try pair(&workbench, phone: &phone, hub: hub)
        workbench.importDraft(StoredRevision.offlineFixture)
        XCTAssertEqual(workbench.livePreviewLabel, WorkbenchCopy.livePreview)
        XCTAssertEqual(workbench.selectedDraft?.revision, StoredRevision.offlineFixture.revision)

        let first = try workbench.deploy(
            deploymentId: "deploy-1",
            revision: StoredRevision.offlineFixture,
            deviceId: "phone-1",
            phone: &phone
        )
        XCTAssertEqual(first.phase, .active)
        XCTAssertEqual(phone.activeRevision, StoredRevision.offlineFixture.revision)

        let replay = try workbench.deploy(
            deploymentId: "deploy-1",
            revision: StoredRevision.offlineFixture,
            deviceId: "phone-1",
            phone: &phone
        )
        XCTAssertEqual(replay.deploymentId, "deploy-1")
        XCTAssertEqual(phone.activeRevision, StoredRevision.offlineFixture.revision)

        var landscape = StoredRevision.offlineFixture
        landscape.revision = "33333333-3333-4333-8333-333333333333"
        landscape.orientation = .landscape
        landscape.width = 844
        landscape.height = 390
        workbench.importDraft(landscape)
        let failed = try workbench.deploy(
            deploymentId: "deploy-fail",
            revision: landscape,
            deviceId: "phone-1",
            phone: &phone,
            failAt: .validating
        )
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(phone.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertNil(phone.stagedRevision)

        workbench.setOrientation(.landscape, deviceId: "phone-1")
        XCTAssertEqual(workbench.selectedDevice?.profile.orientation, .landscape)
        XCTAssertFalse(StoredRevision.offlineFixture.matches(profile: workbench.selectedDevice!.profile))
        XCTAssertTrue(landscape.matches(profile: workbench.selectedDevice!.profile))

        workbench.setOrientation(.portrait, deviceId: "phone-1")
        let rolled = try workbench.rollback(
            to: StoredRevision.offlineFixture,
            deviceId: "phone-1",
            phone: &phone,
            deploymentId: "deploy-rollback"
        )
        XCTAssertEqual(rolled.phase, .active)
        XCTAssertEqual(phone.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertEqual(workbench.selectedDevice?.history.count, 1)
    }

    func testForgetUnreachableLeavesPhoneAndInterruptedTransferKeepsCurrent() throws {
        let hub = LoopbackDiscovery()
        hub.reset()
        var phone = makePhone(hub: hub)
        var workbench = makeWorkbench()
        try pair(&workbench, phone: &phone, hub: hub)
        workbench.importDraft(StoredRevision.offlineFixture)
        _ = try workbench.deploy(
            deploymentId: "deploy-1",
            revision: StoredRevision.offlineFixture,
            deviceId: "phone-1",
            phone: &phone
        )
        var next = StoredRevision.offlineFixture
        next.revision = "44444444-4444-4444-8444-444444444444"
        let interrupted = try workbench.deploy(
            deploymentId: "deploy-2",
            revision: next,
            deviceId: "phone-1",
            phone: &phone,
            failAt: .transferring
        )
        XCTAssertEqual(interrupted.phase, .failed)
        XCTAssertEqual(phone.activeRevision, StoredRevision.offlineFixture.revision)

        workbench.forgetUnreachable(deviceId: "phone-1")
        XCTAssertTrue(workbench.devices.isEmpty)
        XCTAssertEqual(workbench.lastForgetMessage, WorkbenchCopy.forgetUnreachable)
        XCTAssertEqual(phone.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertTrue(phone.isPaired)
    }
}
