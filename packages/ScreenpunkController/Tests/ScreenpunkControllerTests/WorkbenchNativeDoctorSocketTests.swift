#if os(macOS)
import XCTest
import Foundation
@testable import ScreenpunkController

final class WorkbenchNativeDoctorSocketTests: XCTestCase {
    func testOwnerObservationDoesNotActivateNativeAndSeparatesOSAuthorization() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-native-doctor-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"),
            deviceDirectoryURL: root.appendingPathComponent("devices.json"), rendererFactory: { nil })
        func observed(_ provider: WorkbenchNativeDiagnosticProvider?) throws -> WorkbenchNativeDoctorRead {
            let domain = WorkbenchBrokerDomain(controller: controller,
                native: WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("Doctor must not activate native transport") },
                    deactivate: {}), nativeDiagnostics: provider)
            let server = WorkbenchBrokerServer(environment: environment, domain: domain)
            try server.start(); defer { server.stop() }
            let client = WorkbenchBrokerClient(environment: environment)
            try client.connect(); defer { client.close() }
            return try client.nativeDoctor()
        }
        let unassessed = try observed(nil)
        XCTAssertEqual(unassessed.identityState, "not_loaded")
        XCTAssertEqual(unassessed.identityPersistence, "not_assessed")
        XCTAssertEqual(unassessed.networkTransport, "not_attached")
        XCTAssertEqual(unassessed.networkAuthorization, .notAssessed)
        XCTAssertFalse(unassessed.complete)
        let injected = try observed(.init(networkAuthorization: { .authorized }))
        XCTAssertEqual(injected.networkAuthorization, .authorized)
        XCTAssertEqual(injected.identityState, "not_loaded")
        XCTAssertEqual(injected.networkTransport, "not_attached")
    }
}
#endif
