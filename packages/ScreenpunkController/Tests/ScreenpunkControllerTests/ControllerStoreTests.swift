import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class ControllerStoreTests: XCTestCase {
    func testAtomicSaveAndReload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenpunk-controller-\(UUID().uuidString)")
        let store = ControllerStore(directory: dir)
        var session = WorkbenchSession(
            controllerIdentity: PairingIdentityFactory.make(
                role: .controller,
                bytes: [UInt8](repeating: 0x02, count: 32)
            )
        )
        session.importDraft(StoredRevision.offlineFixture)
        session.devices.append(
            PairedDevice(
                profile: DeviceProfile(deviceId: "phone-1", name: "iPhone"),
                owner: session.controllerIdentity,
                activeRevision: StoredRevision.offlineFixture.revision,
                history: [StoredRevision.offlineFixture]
            )
        )
        session.selectedDeviceId = "phone-1"
        try store.save(session)
        let loaded = try store.load()
        XCTAssertEqual(loaded.selectedDeviceId, "phone-1")
        XCTAssertEqual(loaded.drafts.first?.digest, StoredRevision.offlineFixture.digest)
        XCTAssertEqual(loaded.devices.first?.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertEqual(ControllerPlaceholder.socketName, "screenpunk-controller.sock")
    }
}
