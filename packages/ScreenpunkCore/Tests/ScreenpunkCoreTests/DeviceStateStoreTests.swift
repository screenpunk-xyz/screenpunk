import XCTest
@testable import ScreenpunkCore

/// Device pairing and package state survive a relaunch; Unlink erases both.
final class DeviceStateStoreTests: XCTestCase {
    private let owner = PairingIdentityFactory.make(role: .controller, bytes: [UInt8](repeating: 0x02, count: 32))
    private let stranger = PairingIdentityFactory.make(role: .controller, bytes: [UInt8](repeating: 0x99, count: 32))

    private func makeStore() -> DeviceStateStore {
        DeviceStateStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-device-\(UUID().uuidString)", isDirectory: true))
    }

    private func makePhone() -> DeviceRuntime {
        DeviceRuntime(
            identity: PairingIdentityFactory.make(role: .device, bytes: [UInt8](repeating: 0x01, count: 32)),
            profile: DeviceProfile(deviceId: "phone-1", name: "iPhone"),
            advertisement: AdvertisedDevice(deviceId: "phone-1", host: "127.0.0.1", port: 7843, source: .advertised)
        )
    }

    func testStateRoundTripsAndSecondSaveReplacesAtomically() throws {
        let store = makeStore()
        defer { try? store.erase() }
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasState)

        let first = DevicePersistedState(owner: owner, activeRevision: nil, activeStoredRevision: nil, lastDeployment: nil)
        try store.save(first)
        XCTAssertEqual(store.load()?.owner, owner)
        XCTAssertNil(store.load()?.activeRevision)

        let deployment = DeploymentRecord(
            deploymentId: "dep-1",
            revision: StoredRevision.offlineFixture.revision,
            dashboardId: StoredRevision.offlineFixture.dashboardId,
            deviceId: "phone-1",
            phase: .active
        )
        let second = DevicePersistedState(
            owner: owner,
            activeRevision: StoredRevision.offlineFixture.revision,
            activeStoredRevision: StoredRevision.offlineFixture,
            lastDeployment: deployment
        )
        try store.save(second)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertEqual(loaded.activeStoredRevision, StoredRevision.offlineFixture)
        XCTAssertEqual(loaded.lastDeployment, deployment)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "no temp files remain after save")
    }

    func testPackageIsStagedThenSwappedAndFailedStagingLeavesCurrentPackage() throws {
        let store = makeStore()
        defer { try? store.erase() }
        XCTAssertEqual(try store.loadPackageFiles().count, 0)

        let staged = try store.stagePackage([
            ("index.html", Data("<p>ONE</p>".utf8)),
            ("assets/app.js", Data("console.log(1)".utf8))
        ])
        XCTAssertFalse(store.hasPackage, "staging does not touch the active package")
        try store.activatePackage(staged: staged)
        XCTAssertTrue(store.hasPackage)
        var files = try store.loadPackageFiles()
        XCTAssertEqual(files.map(\.path), ["assets/app.js", "index.html"])
        XCTAssertEqual(files.first { $0.path == "index.html" }?.data, Data("<p>ONE</p>".utf8))

        XCTAssertThrowsError(try store.stagePackage([("../escape.html", Data("x".utf8))])) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues, [.pathTraversal])
        }
        XCTAssertThrowsError(try store.stagePackage([("/etc/passwd", Data("x".utf8))]))
        files = try store.loadPackageFiles()
        XCTAssertEqual(files.map(\.path), ["assets/app.js", "index.html"], "rejected staging leaves the current package")
        let stagingLeftovers = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix("package.staging") }
        XCTAssertTrue(stagingLeftovers.isEmpty, "rejected staging directories are removed")

        let discarded = try store.stagePackage([("index.html", Data("<p>NEVER</p>".utf8))])
        store.discardStaged(discarded)
        XCTAssertEqual(try store.loadPackageFiles().first { $0.path == "index.html" }?.data, Data("<p>ONE</p>".utf8))

        let next = try store.stagePackage([("index.html", Data("<p>TWO</p>".utf8))])
        try store.activatePackage(staged: next)
        files = try store.loadPackageFiles()
        XCTAssertEqual(files.map(\.path), ["index.html"], "old files do not leak into the new package")
        XCTAssertEqual(files.first?.data, Data("<p>TWO</p>".utf8))
        let previousLeftovers = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix("package.previous") }
        XCTAssertTrue(previousLeftovers.isEmpty)
    }

    func testRestoreRebuildsOwnerAndActiveRevisionAndKeepsOneOwner() throws {
        let store = makeStore()
        defer { try? store.erase() }
        var phone = makePhone()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = PairingTranscript(
            devicePublicKey: phone.identity.publicKey,
            controllerPublicKey: owner.publicKey,
            sessionNonce: [UInt8](repeating: 0x03, count: 16)
        )
        try phone.beginPairing(transcript: transcript, expectedCode: "833492", candidateOwner: owner, clock: clock)
        try phone.confirmPairing(code: "833492", presentedOwner: owner, clock: clock)
        let deployed = try phone.receiveDeployment(
            DeploymentRecord(
                deploymentId: "dep-1",
                revision: StoredRevision.offlineFixture.revision,
                dashboardId: StoredRevision.offlineFixture.dashboardId,
                deviceId: "phone-1",
                phase: .queued
            ),
            revision: StoredRevision.offlineFixture
        )
        XCTAssertEqual(deployed.phase, .active)
        try store.save(DevicePersistedState(runtime: phone, activeStoredRevision: StoredRevision.offlineFixture))

        var relaunched = makePhone()
        XCTAssertFalse(relaunched.isPaired)
        relaunched.restore(try XCTUnwrap(store.load()))
        XCTAssertTrue(relaunched.isPaired)
        XCTAssertEqual(relaunched.pairing.owner, owner)
        XCTAssertNil(relaunched.pairing.session, "pairing sessions never persist")
        XCTAssertEqual(relaunched.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertEqual(relaunched.lastDeployment?.deploymentId, "dep-1")

        XCTAssertThrowsError(
            try relaunched.beginPairing(transcript: transcript, expectedCode: "000000", candidateOwner: stranger, clock: clock)
        ) { error in
            XCTAssertEqual(error as? PairingFailure, .secondOwner)
        }
        XCTAssertNoThrow(
            try relaunched.beginPairing(transcript: transcript, expectedCode: "833492", candidateOwner: owner, clock: clock),
            "the same owner may re-pair after a relaunch"
        )

        let replay = try relaunched.receiveDeployment(
            DeploymentRecord(
                deploymentId: "dep-1",
                revision: StoredRevision.offlineFixture.revision,
                dashboardId: StoredRevision.offlineFixture.dashboardId,
                deviceId: "phone-1",
                phase: .queued
            ),
            revision: StoredRevision.offlineFixture
        )
        XCTAssertEqual(replay.deploymentId, "dep-1", "deployment idempotency survives a relaunch")
    }

    func testEraseRemovesStateAndPackage() throws {
        let store = makeStore()
        try store.save(DevicePersistedState(owner: owner, activeRevision: "r1", activeStoredRevision: nil, lastDeployment: nil))
        let staged = try store.stagePackage([("index.html", Data("x".utf8))])
        try store.activatePackage(staged: staged)
        _ = try store.stagePackage([("index.html", Data("leftover".utf8))])
        XCTAssertTrue(store.hasState)
        XCTAssertTrue(store.hasPackage)

        try store.erase()
        XCTAssertFalse(store.hasState)
        XCTAssertFalse(store.hasPackage)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path), "leftover staging goes with it")
        XCTAssertNoThrow(try store.erase(), "erase is idempotent")

        var phone = makePhone()
        phone.restore(DevicePersistedState(owner: owner, activeRevision: "r1", activeStoredRevision: nil, lastDeployment: nil))
        phone.unlink()
        XCTAssertFalse(phone.isPaired)
        XCTAssertNil(phone.activeRevision)
    }

    func testDefaultRootHonorsOverride() {
        let override = FileManager.default.temporaryDirectory.appendingPathComponent("sp-device-override").path
        setenv("SCREENPUNK_DEVICE_HOME", override, 1)
        defer { unsetenv("SCREENPUNK_DEVICE_HOME") }
        XCTAssertEqual(DeviceStateStore.defaultRoot().path, override)
    }
}
