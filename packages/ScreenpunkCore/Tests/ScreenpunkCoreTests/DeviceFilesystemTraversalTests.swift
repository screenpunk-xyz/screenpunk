import XCTest
@_spi(NativeFilesystem) @testable import ScreenpunkCore

final class DeviceFilesystemTraversalTests: XCTestCase {
    func testOnlyExactSystemHomeOrItsPhysicalSpellingMapsToContainerRoot() throws {
        let system = "/var/mobile/Containers/Data/Application/fixture", physical = "/private/var/mobile/Containers/Data/Application/fixture"
        for root in [system, physical] {
            let plan = try DeviceFilesystemTraversal.confined(path: root + "/Library/Application Support/store", systemHome: system, physicalHome: physical)
            XCTAssertEqual(plan.rootPath, physical)
            XCTAssertEqual(plan.components, ["Library", "Application Support", "store"])
        }
        for path in ["/", "/private/var", system + "-other/Library", system + "/../other", system + "//Library", system + "/Library/.", system + "/Library/", system + "/bad\0node"] {
            XCTAssertThrowsError(try DeviceFilesystemTraversal.confined(path: path, systemHome: system, physicalHome: physical))
        }
    }
    func testRootItselfHasNoTraversalComponentsAndBoundsAreNotRelaxed() throws {
        let home = "/owned/home"
        let plan = try DeviceFilesystemTraversal.confined(path: home, systemHome: home, physicalHome: home)
        XCTAssertEqual(plan.components, []); XCTAssertEqual(plan.rootPath, home)
        XCTAssertThrowsError(try DeviceFilesystemTraversal.confined(path: home + "/" + String(repeating: "a/", count: 129) + "b", systemHome: home, physicalHome: home))
        XCTAssertThrowsError(try DeviceFilesystemTraversal.confined(path: home + "/" + String(repeating: "b", count: 4096), systemHome: home, physicalHome: home))
    }
}
