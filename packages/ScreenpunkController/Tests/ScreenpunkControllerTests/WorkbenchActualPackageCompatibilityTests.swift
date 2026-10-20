import XCTest
import Foundation
import ScreenpunkCore

/// Opt-in private-package acceptance. Paths arrive only from the local runner;
/// no private package bytes or paths are checked into source control.
final class WorkbenchActualPackageCompatibilityTests: XCTestCase {
    func testActualPreparedPackagePassesExactDeviceChecksWithoutChangingBytes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let packagePath = env["SCREENPUNK_TEST_PREPARED_PACKAGE"],
              let profilePath = env["SCREENPUNK_TEST_DEVICE_PROFILE_RECEIPT"] else {
            throw XCTSkip("Requires explicit local read-only package and device receipt paths")
        }
        let root = URL(fileURLWithPath: packagePath)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: original)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: profilePath))) as? [String: Any])
        let result = try XCTUnwrap(receipt["result"] as? [String: Any])
        let profileObject = try XCTUnwrap(result["profile"])
        let profile = try JSONDecoder().decode(DeviceProfile.self, from: JSONSerialization.data(withJSONObject: profileObject))
        var files: [String: Data] = [:]
        for entry in manifest.files {
            _ = try PackagePath.normalize(entry.path)
            XCTAssertNil(files[entry.path])
            files[entry.path] = try Data(contentsOf: root.appendingPathComponent("files").appendingPathComponent(entry.path))
        }
        let revision = StoredRevision(revision: manifest.revision, dashboardId: manifest.dashboardId,
            name: manifest.name, digest: try XCTUnwrap(manifest.digest),
            orientation: try XCTUnwrap(DeviceOrientation(rawValue: manifest.target.orientation)),
            width: manifest.target.width, height: manifest.target.height)
        try DevicePackageCompatibilityPreflight.validate(revision: revision, manifest: original,
            files: files, profile: profile, profileID: profile.deviceId)
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
        for (path, bytes) in files { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("files").appendingPathComponent(path)), bytes) }
        XCTAssertEqual(manifest.target.profileId, profile.deviceId)
    }
}
