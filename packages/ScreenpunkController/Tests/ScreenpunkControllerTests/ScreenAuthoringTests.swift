import XCTest
@testable import ScreenpunkController
import ScreenpunkCore

final class ScreenAuthoringTests: XCTestCase {
    func fixture() throws -> (URL, ScreenAuthoring, ControllerService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let kit = root.appendingPathComponent("kit")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("templates/gallery/src"), withIntermediateDirectories: true)
        try Data("{\"version\":\"test-1\"}".utf8).write(to: kit.appendingPathComponent("kit.json"))
        try Data("export const greeting = 'hello'".utf8).write(to: kit.appendingPathComponent("templates/gallery/src/main.tsx"))
        try Data("{\"name\":\"Gallery\",\"connections\":[]}".utf8).write(to: kit.appendingPathComponent("templates/gallery/screen.json"))
        let service = ControllerService(store: try DashboardPackageStore(root: root.appendingPathComponent("controller")))
        return (root, ScreenAuthoring(root: service.store.root, kit: kit), service)
    }
    func testPackageUpdateOmittingConnectionsPreservesExactBaseDeclarations() throws {
        let (root, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try service.store.putDashboard(dashboardId: nil, name: "TV", baseRevision: nil,
            target: ManifestTarget(profileId: "phone", width: 390, height: 844, scale: 3, orientation: "portrait", safeArea: nil),
            connections: [ManifestConnection(alias: "googleTV", required: false)],
            files: [.init(path: "index.html", text: "<p>TV</p>", base64: nil)])
        var args: [String: JSONValue] = ["dashboardId": .string(first.manifest.dashboardId),
            "baseRevision": .string(first.manifest.revision), "name": .string("Renamed TV"),
            "target": try JSONValue.parse(JSONEncoder().encode(first.manifest.target)),
            "files": .array([.object(["path": .string("index.html"), "text": .string("<p>New title</p>")])])]
        let next = try service.updateDashboard(arguments: .object(args))
        XCTAssertEqual(next.manifest.connections, first.manifest.connections)
        args["baseRevision"] = .string(next.manifest.revision)
        args["connections"] = .array([])
        XCTAssertTrue(try service.updateDashboard(arguments: .object(args)).manifest.connections.isEmpty)
    }

    func testAppearanceEditPreservesConnectionMetadataExactly() throws {
        let (root, authoring, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let project = try authoring.create(starter: "gallery")
        let id = project["projectId"]!.string!
        let metadata = #"{"name":"TV","connections":[{"alias":"googleTV","required":false},{"alias":"home","required":false,"cameraEntities":["camera.room"]}]}"#
        let configured = try authoring.update(id: id, expected: project["sourceVersion"]!.string!, edits: [.object(["path": .string("screen.json"), "text": .string(metadata)])])
        _ = try authoring.update(id: id, expected: configured["sourceVersion"]!.string!, edits: [.object(["path": .string("src/main.tsx"), "text": .string("export const title = 'Changed'")])])
        let read = try authoring.get(id: id, paths: ["screen.json"])
        XCTAssertEqual(read["files"]!.array!.first!["base64"]!.string, Data(metadata.utf8).base64EncodedString())
    }

    func testSourceConflictsAndUnsafePathsLeaveSourceIntact() throws {
        let (root, authoring, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let project = try authoring.create(starter: "gallery")
        let id = project["projectId"]!.string!, version = project["sourceVersion"]!.string!
        let updated = try authoring.update(id: id, expected: version, edits: [.object(["path": .string("src/main.tsx"), "text": .string("export const greeting = 'new'")])])
        XCTAssertNotEqual(updated["sourceVersion"], project["sourceVersion"])
        XCTAssertThrowsError(try authoring.update(id: id, expected: version, edits: []))
        for path in ["../escape.ts", "/tmp/escape.ts", "node_modules/a.ts", "src//bad.ts", "src/.hidden.ts"] {
            XCTAssertThrowsError(try authoring.update(id: id, expected: updated["sourceVersion"]!.string!, edits: [.object(["path": .string(path), "text": .string("bad")])]))
        }
        XCTAssertEqual(try authoring.get(id: id)["sourceVersion"], updated["sourceVersion"])
    }
    func testMissingKitAndSourceSymlinksAreRejected() throws {
        let (root, authoring, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try authoring.create(starter: "gallery", catalogVersion: "not-installed"))
        let p = try authoring.create(starter: "gallery")
        let source = URL(fileURLWithPath: p["sourceLocation"]!.string!)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside.ts"), withDestinationURL: root.appendingPathComponent("kit/kit.json"))
        XCTAssertThrowsError(try authoring.get(id: p["projectId"]!.string!))
    }
    func testInterruptedBuildDoesNotPublishARevision() throws {
        let (root, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let kit = root.appendingPathComponent("kit")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let executable = kit.appendingPathComponent("bin/node")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let authoring = ScreenAuthoring(root: service.store.root, kit: kit, buildTimeoutSeconds: 0.1)
        let project = try authoring.create(starter: "gallery")
        XCTAssertThrowsError(try authoring.build(id: project["projectId"]!.string!, expected: project["sourceVersion"]!.string!, baseRevision: nil, service: service)) { error in
            XCTAssertTrue((error as? ControllerError)?.detail.contains("timed out") == true)
        }
        XCTAssertTrue(try service.listDashboards().isEmpty)
    }

    func testRealOfflineKitBuildAndFailedRebuildPreserveRevision() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENPUNK_TEST_AUTHORING_KIT"] else { throw XCTSkip("Set SCREENPUNK_TEST_AUTHORING_KIT for real bundled runtime integration") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ControllerService(store: try DashboardPackageStore(root: root))
        let authoring = ScreenAuthoring(root: root, kit: URL(fileURLWithPath: path))
        let p = try authoring.create(starter: "gallery"), id = p["projectId"]!.string!
        let built = try authoring.build(id: id, expected: p["sourceVersion"]!.string!, baseRevision: nil, service: service)
        let dashboard = built["dashboardId"]!.string!, revision = built["revision"]!.string!
        let manifest = try service.validateDashboard(dashboardId: dashboard, revision: revision)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertTrue(manifest.files.contains { $0.path == "screen.js" })
        let record = try service.getDashboard(dashboardId: dashboard, revision: revision)
        for file in manifest.files { XCTAssertEqual(DeploymentDigest.sha256Hex(record.files[file.path]!), file.sha256) }
        let updated = try authoring.update(id: id, expected: p["sourceVersion"]!.string!, edits: [.object(["path": .string("src/main.tsx"), "text": .string("const bad: number = 'text'")])])
        XCTAssertThrowsError(try authoring.build(id: id, expected: updated["sourceVersion"]!.string!, baseRevision: revision, service: service))
        XCTAssertEqual(try service.getDashboard(dashboardId: dashboard, revision: nil).manifest.revision, revision)
    }
}
