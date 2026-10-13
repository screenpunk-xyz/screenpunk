import XCTest
import Darwin
@testable import ScreenpunkApple

final class DeviceFactoryResetManifestTests: XCTestCase {
    private func manifest(roots: [[String: Any]] = [], containers: [[String: Any]] = [], credentials: [[String: Any]] = []) throws -> DeviceFactoryResetManifest {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 4,
            "resetID": UUID().uuidString, "originalInstallationID": UUID().uuidString,
            "roots": roots, "containers": containers, "credentials": credentials,
            "baseScopeDigest": String(repeating: "a", count: 64)])
        return try JSONDecoder().decode(DeviceFactoryResetManifest.self, from: data)
    }
    private func root(_ path: String, id: UUID = UUID()) -> [String: Any] {
        ["rootID": id.uuidString, "path": path, "device": 1, "inode": 1]
    }
    func testDecodedManifestRejectsAliasedRootOwnership() throws {
        let id = UUID()
        XCTAssertThrowsError(try manifest(roots: [root("/owned/a", id: id)], containers: [root("/owned/b", id: id)]).validateStructure())
        XCTAssertThrowsError(try manifest(roots: [root("/owned/a/../b")]).validateStructure())
    }
    func testDecodedManifestRejectsDuplicateCredentialReference() throws {
        let reference = Data([1, 2, 3]).base64EncodedString()
        let a: [String: Any] = ["service": "device-owned", "account": "a", "persistentReference": reference, "byteCount": 48, "valueSHA256": String(repeating: "a", count: 64)]
        let b: [String: Any] = ["service": "device-owned", "account": "b", "persistentReference": reference, "byteCount": 48, "valueSHA256": String(repeating: "a", count: 64)]
        XCTAssertThrowsError(try manifest(credentials: [a, b]).validateStructure())
        var missing = a; missing.removeValue(forKey: "valueSHA256")
        XCTAssertThrowsError(try manifest(credentials: [missing]))
        var invalid = a; invalid["valueSHA256"] = String(repeating: "A", count: 64)
        XCTAssertThrowsError(try manifest(credentials: [invalid]).validateStructure())
    }
    func testImmutableSidecarCannotRetargetOriginalReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try manifest()
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        let store = DeviceFactoryResetManifestStore(directory: URL(fileURLWithPath: String(cString: physical), isDirectory: true))
        try store.save(original)
        XCTAssertEqual(try store.load(resetID: original.resetID)?.canonicalBytes, try original.canonicalBytes)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original.canonicalBytes) as? [String: Any])
        object["originalInstallationID"] = UUID().uuidString
        let changed = try JSONDecoder().decode(DeviceFactoryResetManifest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try store.save(changed))
        XCTAssertEqual(try store.load(resetID: original.resetID)?.canonicalBytes, try original.canonicalBytes)
    }
    func testNestedContainersRejectNewChildAfterScopeFreeze() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = temporary.appendingPathComponent("incoming", isDirectory: true)
        let store = child.appendingPathComponent("packages", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func pinned(_ url: URL) throws -> [String: Any] {
            let pointer = try XCTUnwrap(realpath(url.path, nil)); defer { free(pointer) }
            let path = String(cString: pointer)
            var value = stat(); XCTAssertEqual(lstat(path, &value), 0)
            return ["rootID": UUID().uuidString, "path": path,
                "device": UInt64(value.st_dev), "inode": UInt64(value.st_ino)]
        }
        let original = try manifest(roots: [pinned(store)], containers: [pinned(child), pinned(temporary)])
        try original.validateStructure(); try original.validateContainerMembership()
        let foreign = child.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        XCTAssertThrowsError(try original.validateContainerMembership())
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

}
