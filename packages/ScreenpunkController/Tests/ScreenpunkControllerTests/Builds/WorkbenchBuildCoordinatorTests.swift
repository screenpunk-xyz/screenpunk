import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
private struct BuildDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}

final class WorkbenchBuildCoordinatorTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let workspace: WorkspaceStore
        let authoring: WorkbenchContainedAuthoring
        let visible: URL
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/sp-build-coordinator-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let documents = root.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
            workspace = try WorkspaceStore(documents: BuildDocuments(path: documents),
                machineRootPath: root.appendingPathComponent("machine").path)
            visible = root.appendingPathComponent("visible")
            _ = try workspace.create(at: visible.path)
            authoring = WorkbenchContainedAuthoring(workspace: workspace)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func requirement(hashCharacter: String = "a") throws {
            let files = try WorkspaceFiles(path: visible.path)
            let directory = try files.directory(["Workbench", "Toolchains"])
            defer { close(directory) }
            let name = "requirements.json"
            let identity = WorkspaceNodeID(try files.metadata(directory, name))
            let bytes = Data("""
            {"schemaVersion":1,"required":[{"catalogEntryId":"synthetic-kit","kitVersion":"1.0.0",
            "platform":"darwin-arm64","inventoryHash":"\(String(repeating: hashCharacter, count: 64))"}]}
            """.utf8)
            try files.write(directory, name, data: bytes, expected: identity)
        }
    }

    func testPlainWebBuildPublishesVerifiedHistoryAndHeadAcrossReopen() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = try fixture.authoring.create(name: "Web", kind: "web", trustedKitVersion: "1.0.0")
        let coordinator = WorkbenchBuildCoordinator(workspace: fixture.workspace) { _, _, _, _, _, _ in
            XCTFail("Plain-web must not invoke a compiler")
            return ""
        }
        let first = try coordinator.build(projectID: project.project.projectId,
            expectedSourceVersion: project.sourceVersion, baseRevision: nil)
        let read = try XCTUnwrap(coordinator.readHead(projectID: project.project.projectId))
        XCTAssertEqual(read.0, first.head)
        XCTAssertEqual(read.1.files["index.html"], Data("<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>New screen</title><main><h1>New screen</h1></main></html>\n".utf8))
        let edited = try fixture.authoring.patch(project.project.projectId,
            expectedSourceVersion: project.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: Data("<html>second</html>".utf8))])
        XCTAssertThrowsError(try coordinator.build(projectID: project.project.projectId,
            expectedSourceVersion: project.sourceVersion, baseRevision: first.head.revision))
        XCTAssertEqual(try coordinator.readHead(projectID: project.project.projectId)?.0, first.head)
        let second = try coordinator.build(projectID: project.project.projectId,
            expectedSourceVersion: edited.sourceVersion, baseRevision: first.head.revision)
        XCTAssertNotEqual(second.head.revision, first.head.revision)
        XCTAssertEqual(try coordinator.readHead(projectID: project.project.projectId)?.1.files["index.html"],
                       Data("<html>second</html>".utf8))
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.copyItem(at: fixture.visible, to: backup)
        let reopened = try WorkspaceStore(documents: BuildDocuments(path: fixture.root.appendingPathComponent("Documents")),
            machineRootPath: fixture.root.appendingPathComponent("new-machine").path)
        _ = try reopened.open(at: backup.path)
        XCTAssertEqual(try WorkbenchBuildCoordinator(workspace: reopened) { _, _, _, _, _, _ in "" }
            .readHead(projectID: project.project.projectId)?.0, second.head)
    }

    func testReactFailureConflictInvalidOutputAndCancellationPreservePriorHead() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.requirement()
        let project = try fixture.authoring.create(name: "React", kind: "react", trustedKitVersion: "1.0.0")
        var mode = "good"
        let coordinator = WorkbenchBuildCoordinator(workspace: fixture.workspace) {
            _, version, requirement, plan, output, _ in
            XCTAssertEqual(version, project.sourceVersion)
            XCTAssertEqual(requirement.catalogEntryId, "synthetic-kit")
            XCTAssertTrue(plan.files.contains { $0.relativePath == "src/main.tsx" })
            if mode == "fail" { throw OfflineBuildError.buildFailed("synthetic failure") }
            let target = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            if mode == "conflict" {
                _ = try fixture.authoring.patch(project.project.projectId,
                    expectedSourceVersion: project.sourceVersion,
                    changes: [.init(path: "src/main.tsx", bytes: Data("export const changed = 1;".utf8))])
            }
            if mode == "invalid" {
                try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("index.html"),
                    withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
            } else {
                try Data("<html>fixture</html>".utf8).write(to: target.appendingPathComponent("index.html"))
            }
            return ""
        }
        let first = try coordinator.build(projectID: project.project.projectId,
            expectedSourceVersion: project.sourceVersion, baseRevision: nil)
        XCTAssertEqual(try coordinator.readHead(projectID: project.project.projectId)?.0, first.head)
        for failure in ["fail", "invalid"] {
            mode = failure
            XCTAssertThrowsError(try coordinator.build(projectID: project.project.projectId,
                expectedSourceVersion: project.sourceVersion, baseRevision: first.head.revision))
            XCTAssertEqual(try coordinator.readHead(projectID: project.project.projectId)?.0, first.head)
        }
        mode = "good"
        XCTAssertThrowsError(try coordinator.build(projectID: project.project.projectId,
            expectedSourceVersion: project.sourceVersion, baseRevision: "stale"))
        XCTAssertEqual(try coordinator.readHead(projectID: project.project.projectId)?.0, first.head)
        XCTAssertThrowsError(try coordinator.build(projectID: project.project.projectId,
            expectedSourceVersion: project.sourceVersion, baseRevision: first.head.revision,
            cancelled: { true }))
        XCTAssertEqual(try coordinator.readHead(projectID: project.project.projectId)?.0, first.head)
        mode = "conflict"
        XCTAssertThrowsError(try coordinator.build(projectID: project.project.projectId,
            expectedSourceVersion: project.sourceVersion, baseRevision: first.head.revision))
        XCTAssertEqual(try coordinator.readHead(projectID: project.project.projectId)?.0, first.head)
    }

    func testReadHeadRejectsAnotherProjectsVerifiedPackage() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let firstProject = try fixture.authoring.create(name: "One", kind: "web", trustedKitVersion: "1.0.0")
        let secondProject = try fixture.authoring.create(name: "Two", kind: "web", trustedKitVersion: "1.0.0")
        let coordinator = WorkbenchBuildCoordinator(workspace: fixture.workspace) { _, _, _, _, _, _ in "" }
        let first = try coordinator.build(projectID: firstProject.project.projectId,
                                          expectedSourceVersion: firstProject.sourceVersion, baseRevision: nil)
        let second = try coordinator.build(projectID: secondProject.project.projectId,
                                           expectedSourceVersion: secondProject.sourceVersion, baseRevision: nil)
        let path = fixture.visible.appendingPathComponent(
            "Workbench/Library/BuildHeads/\(firstProject.project.projectId).json")
        var head = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        head["dashboardID"] = second.head.dashboardID
        head["revision"] = second.head.revision
        head["digest"] = second.head.digest
        try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys]).write(to: path)
        XCTAssertThrowsError(try coordinator.readHead(projectID: firstProject.project.projectId))
        XCTAssertNotEqual(first.head.dashboardID, second.head.dashboardID)
    }

    func testChangedRequirementDuringCompileCannotPublishHead() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.requirement()
        let project = try fixture.authoring.create(name: "Pin", kind: "react", trustedKitVersion: "1.0.0")
        var changePin = false
        let coordinator = WorkbenchBuildCoordinator(workspace: fixture.workspace) { _, _, _, _, output, _ in
            if changePin { try fixture.requirement(hashCharacter: "b") }
            let target = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try Data("<html>fixture</html>".utf8).write(to: target.appendingPathComponent("index.html"))
            return ""
        }
        let original = try coordinator.build(projectID: project.project.projectId,
            expectedSourceVersion: project.sourceVersion, baseRevision: nil)
        changePin = true
        XCTAssertThrowsError(try coordinator.build(projectID: project.project.projectId,
            expectedSourceVersion: project.sourceVersion, baseRevision: original.head.revision))
        XCTAssertEqual(try coordinator.readHead(projectID: project.project.projectId)?.0, original.head)
    }

    func testPackageAndHeadRecoverTogetherAfterPublicationCheckpoints() throws {
        for point in [WorkbenchTransactionCheckpoint.memberPublished(0), .memberPublished(2), .generationDurable] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let project = try fixture.authoring.create(name: "Crash", kind: "web", trustedKitVersion: "1.0.0")
            let ordinary = WorkbenchBuildCoordinator(workspace: fixture.workspace) { _, _, _, _, _, _ in "" }
            let first = try ordinary.build(projectID: project.project.projectId,
                expectedSourceVersion: project.sourceVersion, baseRevision: nil)
            let edited = try fixture.authoring.patch(project.project.projectId,
                expectedSourceVersion: project.sourceVersion,
                changes: [.init(path: "web/index.html", bytes: Data("<html>next</html>".utf8))])
            let expectedGeneration = try XCTUnwrap(fixture.workspace.current()).descriptor.generation
            let interrupted = WorkbenchBuildCoordinator(workspace: fixture.workspace,
                compiler: { _, _, _, _, _, _ in "" }, checkpoint: { current in
                    if current == point { throw WorkspaceError.unavailable }
                })
            XCTAssertThrowsError(try interrupted.build(projectID: project.project.projectId,
                expectedSourceVersion: edited.sourceVersion, baseRevision: first.head.revision))
            let fresh = try WorkspaceStore(documents: BuildDocuments(path: fixture.root.appendingPathComponent("Documents")),
                machineRootPath: fixture.root.appendingPathComponent("recovered-machine").path)
            XCTAssertThrowsError(try fresh.open(at: fixture.visible.path))
            XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: fresh)
                .recoverContainedBeforeOpen(at: fixture.visible.path).count, 1)
            _ = try fresh.open(at: fixture.visible.path)
            let recovered = try XCTUnwrap(WorkbenchBuildCoordinator(workspace: fresh) { _, _, _, _, _, _ in "" }
                .readHead(projectID: project.project.projectId))
            XCTAssertNotEqual(recovered.0.revision, first.head.revision)
            XCTAssertEqual(recovered.0.sourceVersion, edited.sourceVersion)
            XCTAssertEqual(recovered.1.files["index.html"], Data("<html>next</html>".utf8))
            XCTAssertEqual(try XCTUnwrap(fresh.current()).descriptor.generation, expectedGeneration + 1)
        }
    }
}
#endif
