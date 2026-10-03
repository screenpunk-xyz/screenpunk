import XCTest
import Foundation
@testable import WorkbenchCommand
import ScreenpunkController

final class AuthoringRecoveryCLITests: XCTestCase {
    func testMigrationReviewNeverTruncatesDestinationOrControlEscapes() throws {
        func result(destination: String) throws -> WorkbenchAuthoringRecoveryResult {
            let object: [String: Any] = ["schemaVersion": 1, "kind": "migrationPlan",
                "migrationPlan": ["migrationId": "plan-one", "sourcePath": "/private/tmp/legacy",
                    "destinationPath": destination, "projectIds": ["project-one"],
                    "packageRevisions": [String](), "portableBytes": 1,
                    "expandedBytes": 2, "plannedMembers": 3,
                    "unsupportedPortablePaths": [String](),
                    "excludedClasses": ["machine identity"], "applyAvailable": true]]
            return try JSONDecoder().decode(WorkbenchAuthoringRecoveryResult.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        let destination = "/" + String(repeating: "scope-", count: 600)
        let rendered = try WorkbenchAuthoringRecoveryCLI.human(result(destination: destination))
        XCTAssertTrue(rendered.contains("Destination: " + destination))
        XCTAssertFalse(rendered.contains("[truncated]"))
        let unsafe = "/" + String(repeating: "\u{202E}", count: 600)
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.human(result(destination: unsafe))) {
            XCTAssertEqual(($0 as? CommandFailure)?.code, "migration_review_too_large")
        }
    }

    func testClosedCommandRoutesAndBoundedExplicitInput() throws {
        let base = URL(fileURLWithPath: "/private/tmp/sp-authoring-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let input = base.appendingPathComponent("input.html")
        let html = Data("<html>cli</html>".utf8)
        try html.write(to: input)
        let id = UUID().uuidString.lowercased()
        let hash = String(repeating: "a", count: 64)
        let edit = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route(
            ["project", "edit", id, hash, "web/index.html", input.path]))
        XCTAssertEqual(edit.method, .projectPatch)
        guard case .projectPatch(_, _, let changes) = try WorkbenchAuthoringRecoveryRequest.parse(
            method: edit.method, params: edit.params) else { return XCTFail("Expected patch") }
        XCTAssertEqual(changes.first?.bytes, html)
        XCTAssertEqual(try WorkbenchAuthoringRecoveryCLI.route(["project", "create", "Web"])?.method,
                       .projectCreate)
        XCTAssertEqual(try WorkbenchAuthoringRecoveryCLI.route(
            ["workspace", "export", base.appendingPathComponent("backup").path])?.method,
            .snapshotCreate)
        XCTAssertEqual(try WorkbenchAuthoringRecoveryCLI.route(["migration", "plan", base.path])?.method,
                       .migrationPlan)
        XCTAssertNil(try WorkbenchAuthoringRecoveryCLI.route(["project", "list"]))
        try Data(repeating: 65, count: 2_049).write(to: input)
        XCTAssertNoThrow(try WorkbenchAuthoringRecoveryCLI.route(
            ["project", "edit", id, hash, "web/index.html", input.path]))
        try Data(repeating: 65, count: 5 * 1024 * 1024).write(to: input)
        XCTAssertNoThrow(try WorkbenchAuthoringRecoveryCLI.route(
            ["project", "edit", id, hash, "web/index.html", input.path]))
        try Data(repeating: 65, count: 5 * 1024 * 1024 + 1).write(to: input)
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route(
            ["project", "edit", id, hash, "web/index.html", input.path]))
    }

    func testSnapshotPresentationDisclosesAuthoringScopeAndOmittedAuxiliaryPath() throws {
        let data = Data("""
        {"schemaVersion":1,"kind":"workspaceSnapshot","snapshot":{
          "path":"/private/tmp/backup","workspaceId":"workspace","generation":2,
          "fileCount":5,"includedBytes":100,"complete":true,"scope":"authoring",
          "excludedExternalProjectIds":[],"unregisteredScreenPaths":[],
          "omittedAuxiliaryPaths":["notes.txt"]}}
        """.utf8)
        let result = try JSONDecoder().decode(WorkbenchAuthoringRecoveryResult.self, from: data)
        try result.validate(for: .snapshotCreate)
        let human = try WorkbenchAuthoringRecoveryCLI.human(result)
        XCTAssertTrue(human.contains("Scope: portable authoring content"))
        XCTAssertTrue(human.contains("Portable coverage complete: true"))
        XCTAssertTrue(human.contains("Omitted auxiliary paths (1): notes.txt"))
        let encoded = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["omittedAuxiliaryPaths"] as? [String], ["notes.txt"])
    }
}
