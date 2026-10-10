#if os(macOS)
import XCTest
import Foundation
@testable import ScreenpunkController

private struct SnapshotOptionDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

final class WorkbenchSnapshotOptionsTests: XCTestCase {
    func testClosedFlagsAndExternalCoverageThroughAuthoringDomain() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-snapshot-options-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: SnapshotOptionDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let source = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Seed", kind: "web", trustedKitVersion: "kit-1")
        let external = root.appendingPathComponent("external")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path), to: external)
        let descriptorURL = external.appendingPathComponent("screenpunk.project.json")
        let original = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptorURL))
        let independent = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "External", kind: original.kind, kitVersion: original.kitVersion,
            entry: original.entry, screenConfig: original.screenConfig)
        try WorkspaceJSON.encode(independent).write(to: descriptorURL)
        let registered = try WorkbenchPortableSourceArchive(workspace: workspace)
            .openExternal(at: external.path, explicitExternal: true)
        let selected = try XCTUnwrap(workspace.current())
        let bound: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": selected.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)]
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace,
            timeout: 120, mutationGate: {})
        func request(_ path: URL, include: Bool, allow: Bool) throws -> WorkbenchAuthoringRecoveryRequest {
            try WorkbenchAuthoringRecoveryRequest.parse(method: .snapshotCreate,
                params: bound.merging(["path": path.path,
                    "includeExternal": include, "allowIncomplete": allow]) { _, new in new })
        }
        let required = root.appendingPathComponent("required")
        XCTAssertThrowsError(try domain.perform(request(required, include: false, allow: false))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceIncomplete)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: required.path))
        let partial = try XCTUnwrap(domain.perform(request(
            root.appendingPathComponent("partial"), include: false, allow: true)).snapshot)
        XCTAssertFalse(partial.complete)
        XCTAssertEqual(partial.excludedExternalProjectIds, [registered.projectId])
        let complete = try XCTUnwrap(domain.perform(request(
            root.appendingPathComponent("complete"), include: true, allow: false)).snapshot)
        XCTAssertTrue(complete.complete)
        XCTAssertTrue(complete.excludedExternalProjectIds.isEmpty)
        XCTAssertEqual(try Data(contentsOf: descriptorURL), try WorkspaceJSON.encode(independent))
        XCTAssertEqual(try workspace.resolveProject(registered.projectId), external.path)
        let copied = try workspace.inspect(at: complete.path)
        XCTAssertEqual(copied.catalog.projects.first(where: { $0.projectId == registered.projectId })?
            .location.kind, "workspace")
        var measured: [WorkspaceCopyProgress] = []
        let measuredCopy = try WorkspaceSnapshot(workspace: workspace).create(
            at: root.appendingPathComponent("measured").path,
            includeExternal: true, progress: { measured.append($0) })
        XCTAssertEqual(measured.first?.phase, .copying)
        XCTAssertEqual(measured.first?.copiedFiles, 0)
        XCTAssertEqual(measured.last?.phase, .complete)
        XCTAssertEqual(measured.last?.totalFiles, measuredCopy.fileCount)
        XCTAssertEqual(measured.last?.copiedFiles, measuredCopy.fileCount)
        XCTAssertEqual(measured.last?.totalBytes, measuredCopy.includedBytes)
        XCTAssertEqual(measured.last?.copiedBytes, measuredCopy.includedBytes)
        XCTAssertTrue(zip(measured, measured.dropFirst()).allSatisfy {
            $0.copiedFiles <= $1.copiedFiles && $0.copiedBytes <= $1.copiedBytes
        })
        var extra: [String: Any] = ["schemaVersion": 1, "path": required.path,
            "includeExternal": true, "allowIncomplete": true, "rogue": true]
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryRequest.parse(
            method: .snapshotCreate, params: extra))
        extra.removeValue(forKey: "rogue")
        extra["allowIncomplete"] = 1
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryRequest.parse(
            method: .snapshotCreate, params: extra))
    }
}
#endif
