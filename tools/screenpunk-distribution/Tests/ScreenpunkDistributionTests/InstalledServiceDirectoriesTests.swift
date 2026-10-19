import Foundation
import XCTest
@testable import ScreenpunkDistribution

final class InstalledServiceDirectoriesTests: XCTestCase {
    func testFreshDirectoryURLFormsMatchFixedServicePaths() throws {
        let home = URL(fileURLWithPath: "/private/tmp/screenpunk-new-user-" + UUID().uuidString)
        let paths = InstallationPaths(home: home)
        let controller = URL(fileURLWithPath: paths.machineState.path + "/Controller", isDirectory: true)
        let runtime = URL(fileURLWithPath: paths.machineState.path + "/Runtime", isDirectory: true)
        // The old guard rejected these on first activation, before Controller
        // existed, because one URL carried the directory trailing slash.
        XCTAssertNotEqual(controller.standardizedFileURL,
                          paths.machineState.appendingPathComponent("Controller").standardizedFileURL)
        XCTAssertNoThrow(try paths.validateServiceDirectories(controllerHome: controller,
                                                              runtimeDirectory: runtime))
    }

    func testDifferentServiceDirectoriesRemainUntrusted() throws {
        let paths = InstallationPaths(home: URL(fileURLWithPath: "/private/tmp/screenpunk-user"))
        let controller = paths.machineState.appendingPathComponent("Controller", isDirectory: true)
        let runtime = paths.machineState.appendingPathComponent("Runtime", isDirectory: true)
        XCTAssertThrowsError(try paths.validateServiceDirectories(
            controllerHome: paths.machineState.appendingPathComponent("OtherController"),
            runtimeDirectory: runtime)) { XCTAssertEqual($0 as? DistributionError, .untrustedRelease) }
        XCTAssertThrowsError(try paths.validateServiceDirectories(controllerHome: controller,
            runtimeDirectory: URL(fileURLWithPath: "/private/tmp/other-runtime"))) {
            XCTAssertEqual($0 as? DistributionError, .untrustedRelease)
        }
    }
}
