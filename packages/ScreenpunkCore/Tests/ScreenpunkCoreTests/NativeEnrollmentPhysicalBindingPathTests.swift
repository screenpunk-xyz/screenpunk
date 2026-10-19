import XCTest
@_spi(NativeFilesystem) @testable import ScreenpunkCore

final class NativeEnrollmentPhysicalBindingPathTests: XCTestCase {
    func testVersionOneRecordedContainerLocatorMapsOnlySameOSParentAndRelativeSubtree() throws {
        let currentID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let oldID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        let relative = "Library/Application Support/xyz.screenpunk.native-managed/enrollment"
        for parent in ["/private/var/mobile/Containers/Data/Application", "/Users/test/Library/Developer/CoreSimulator/Devices/CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC/data/Containers/Data/Application"] {
            let current = parent + "/" + currentID, old = parent + "/" + oldID
            let system = current.replacingOccurrences(of: "/private/var/", with: "/var/")
            for recorded in [old + "/" + relative, current + "/" + relative,
                             "screenpunk-app-home:v1/" + relative] {
                XCTAssertEqual(try DeviceFilesystemTraversal.currentRecordedPath(recorded, systemHome: system, physicalHome: current), current + "/" + relative)
            }
            // A second normal update uses the same original locator, never a chain of aliases.
            let next = parent + "/DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
            XCTAssertEqual(try DeviceFilesystemTraversal.currentRecordedPath(old + "/" + relative, systemHome: next, physicalHome: next), next + "/" + relative)
            for bad in [parent + "/not-a-uuid/" + relative,
                        old + "/../" + relative, old + "//" + relative, old + "/" + relative + "/.",
                        "/other" + old + "/" + relative,
                        "screenpunk-app-home:v2/" + relative, "screenpunk-app-home:v1/../" + relative] {
                XCTAssertThrowsError(try DeviceFilesystemTraversal.currentRecordedPath(bad, systemHome: system, physicalHome: current), bad)
            }
            let different = try DeviceFilesystemTraversal.currentRecordedPath(old + "/" + relative + "-foreign", systemHome: system, physicalHome: current)
            XCTAssertNotEqual(different, current + "/" + relative)
            XCTAssertThrowsError(try DeviceFilesystemTraversal.confined(path: old + "/" + relative, systemHome: system, physicalHome: current), "Live traversal must still reject old container paths")
        }
    }
    func testOnlyExactSystemHomeSpellingMapsToSamePhysicalBindingDescendant() throws {
        let system = "/var/mobile/Containers/Data/Application/owned"
        let physical = "/private/var/mobile/Containers/Data/Application/owned"
        let relative = "/Library/Application Support/xyz.screenpunk.native-managed/enrollment"
        for home in [system, physical] {
            let plan = try DeviceFilesystemTraversal.confined(path: home + relative, systemHome: system, physicalHome: physical)
            XCTAssertTrue(NativeEnrollmentPhysicalDirectory.mappedBindingPathMatches(plan, physicalPath: physical + relative))
            XCTAssertFalse(NativeEnrollmentPhysicalDirectory.mappedBindingPathMatches(plan, physicalPath: physical + relative + "-other"))
        }
        for path in [system + "-other" + relative, "/var/mobile/Containers/Data/Application/other" + relative,
                     system + "/../other", system + "//Library", system + "/Library/."] {
            XCTAssertThrowsError(try DeviceFilesystemTraversal.confined(path: path, systemHome: system, physicalHome: physical))
        }
        let appAlias = try DeviceFilesystemTraversal.confined(path: system + "/app-created-alias/enrollment", systemHome: system, physicalHome: physical)
        XCTAssertFalse(NativeEnrollmentPhysicalDirectory.mappedBindingPathMatches(appAlias, physicalPath: physical + relative))
    }
}
