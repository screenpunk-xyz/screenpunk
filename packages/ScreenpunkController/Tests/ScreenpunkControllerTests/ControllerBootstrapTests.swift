import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class ControllerBootstrapTests: XCTestCase {
    func testPackageAndSourceOperationsDoNotResolveHelperOrAttachTransport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-domain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = root.appendingPathComponent("kit")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("templates/gallery/src"), withIntermediateDirectories: true)
        try Data("{\"version\":\"test-1\"}".utf8).write(to: kit.appendingPathComponent("kit.json"))
        try Data("export const message = 'offline'".utf8).write(to: kit.appendingPathComponent("templates/gallery/src/main.tsx"))
        try Data("{\"name\":\"Gallery\",\"connections\":[]}".utf8).write(to: kit.appendingPathComponent("templates/gallery/screen.json"))
        let resolutions = ResolutionCounter()
        let service = try ControllerService.bootstrap(
            root: root.appendingPathComponent("portable"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"),
            rendererFactory: { resolutions.increment(); return nil },
            authoringKit: kit
        )
        XCTAssertFalse(service.helperStarted)
        XCTAssertFalse(service.devices.transportAvailable)
        XCTAssertNil(service.homeAssistantConfiguration)
        XCTAssertEqual(service.devices.directory.url, root.appendingPathComponent("machine/devices.json"))
        let screen = try service.authoring.create(starter: "gallery")
        let screenID = try XCTUnwrap(screen["projectId"]?.string)
        let sourceVersion = try XCTUnwrap(screen["sourceVersion"]?.string)
        let updatedScreen = try service.authoring.update(id: screenID, expected: sourceVersion, edits: [
            .object(["path": .string("src/main.tsx"), "text": .string("export const message = 'changed'")])
        ])
        XCTAssertNotEqual(updatedScreen["sourceVersion"], screen["sourceVersion"])
        let record = try service.updateDashboard(arguments: .object([
            "name": .string("Offline"),
            "files": .array([.object(["path": .string("index.html"), "text": .string("<p>Offline</p>")])])
        ]))
        _ = try service.validateDashboard(dashboardId: record.manifest.dashboardId, revision: record.manifest.revision)
        XCTAssertEqual(try service.listDashboards().count, 1)
        XCTAssertEqual(resolutions.count, 0)

        // Legacy deployment still requires review and consent, even without a helper.
        XCTAssertThrowsError(try service.deployDashboard(deviceId: "unpaired", dashboardId: record.manifest.dashboardId,
                                                        revision: record.manifest.revision, deploymentId: nil, approved: true)) {
            XCTAssertEqual(($0 as? ControllerError)?.code, .permissionRequired)
        }
        XCTAssertEqual(resolutions.count, 0)
        XCTAssertThrowsError(try service.previewDashboard(dashboardId: record.manifest.dashboardId, revision: nil)) {
            XCTAssertEqual(($0 as? ControllerError)?.code, .snapshotUnavailable)
        }
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertFalse(service.hasReviewed(revision: record.manifest.revision))
    }

    func testExplicitLegacyHelperResolutionIsLazyAndReusesRenderer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-domain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolutions = ResolutionCounter()
        let service = try ControllerService.bootstrap(root: root, deviceDirectoryURL: root.appendingPathComponent("devices.json"),
            rendererFactory: { resolutions.increment(); return InjectedPreviewRenderer(error: .snapshotUnavailable(reason: "fixture")) })
        XCTAssertEqual(resolutions.count, 0)
        XCTAssertTrue(service.ensureHelper())
        XCTAssertTrue(service.ensureHelper())
        XCTAssertEqual(resolutions.count, 1)
        service.replaceRenderer(nil)
        XCTAssertFalse(service.helperStarted)
        XCTAssertTrue(service.ensureHelper())
        XCTAssertEqual(resolutions.count, 2)
    }
}

private final class ResolutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
