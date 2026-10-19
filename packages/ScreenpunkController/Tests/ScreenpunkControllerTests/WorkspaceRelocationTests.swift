#if os(macOS)
import XCTest
import Foundation
@testable import ScreenpunkController

private struct RelocationDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

final class WorkspaceRelocationTests: XCTestCase {
    func testOrdinaryBrokerSocketRelocationSwitchesSelection() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-relocate-socket-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: RelocationDocuments(root: root),
            machineRootPath: machine.path)
        let original = root.appendingPathComponent("original")
        _ = try workspace.create(at: original.path)
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"),
            deviceDirectoryURL: machine.appendingPathComponent("devices.json"),
            rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            mutationGate: {})
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect(); defer { client.close() }
        let selected = try client.workspaceStatus()
        let destination = root.appendingPathComponent("copy")
        let result = try client.performAuthoring(method: .workspaceRelocate,
            params: ["schemaVersion": 1, "path": destination.path,
                "expectedWorkspaceId": try XCTUnwrap(selected.workspaceId),
                "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)])
        XCTAssertEqual(result.relocation?.path, destination.path)
        XCTAssertEqual(try client.workspaceStatus().path, destination.path)
        XCTAssertNoThrow(try workspace.inspect(at: original.path))
    }

    func testSelectionBoundDomainRelocationAndClosedRequest() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-relocate-domain-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: RelocationDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("original").path)
        let selected = try XCTUnwrap(workspace.current())
        let destination = root.appendingPathComponent("copy")
        let fields: [String: Any] = ["schemaVersion": 1, "path": destination.path,
            "expectedWorkspaceId": selected.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)]
        let request = try WorkbenchAuthoringRecoveryRequest.parse(method: .workspaceRelocate,
            params: fields)
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace,
            timeout: 300, mutationGate: {})
        var measured: [WorkspaceCopyProgress] = []
        let receipt = try XCTUnwrap(domain.perform(request,
            progress: { measured.append($0) }).relocation)
        XCTAssertEqual(receipt.path, destination.path)
        XCTAssertEqual(measured.last?.phase, .complete)
        XCTAssertEqual(measured.last?.copiedFiles, receipt.fileCount)
        XCTAssertThrowsError(try domain.perform(request)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        var invalid = fields
        invalid["rogue"] = true
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryRequest.parse(
            method: .workspaceRelocate, params: invalid))
    }

    func testExternalProjectRemainsOutsideCopyAndBindingBecomesUnresolved() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-relocate-external-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: RelocationDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        let original = root.appendingPathComponent("original")
        _ = try workspace.create(at: original.path)
        let seed = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Seed", kind: "web", trustedKitVersion: "kit-1")
        let external = root.appendingPathComponent("external")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: seed.path), to: external)
        let descriptor = external.appendingPathComponent("screenpunk.project.json")
        let source = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptor))
        let independent = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "External", kind: source.kind, kitVersion: source.kitVersion,
            entry: source.entry, screenConfig: source.screenConfig)
        try WorkspaceJSON.encode(independent).write(to: descriptor)
        let beforeExternal = try Data(contentsOf: descriptor)
        let (registered, sourceVersion) = try WorkbenchPortableSourceArchive(workspace: workspace)
            .openExternalVersioned(at: external.path, explicitExternal: true)
        XCTAssertEqual(try workspace.resolveProject(registered.projectId), external.path)
        let destination = root.appendingPathComponent("copy")
        let receipt = try WorkspaceRelocation(workspace: workspace).relocate(to: destination.path)
        XCTAssertEqual(receipt.unresolvedExternalProjectIds, [registered.projectId])
        XCTAssertNil(try workspace.resolveProject(registered.projectId))
        XCTAssertEqual(try Data(contentsOf: descriptor), beforeExternal)
        XCTAssertEqual(try workspace.current()?.catalog.projects.first {
            $0.projectId == registered.projectId
        }?.location.kind, "external")
        XCTAssertNoThrow(try workspace.inspect(at: original.path))
        let selected = try XCTUnwrap(workspace.current())
        XCTAssertThrowsError(try workspace.rebindExternal(registered.projectId, to: external.path,
            expectedSourceVersion: String(repeating: "0", count: 64),
            expectedSelectionGeneration: try XCTUnwrap(selected.selectionGeneration)))
        XCTAssertNil(try workspace.resolveProject(registered.projectId))
        _ = try workspace.rebindExternal(registered.projectId, to: external.path,
            expectedSourceVersion: sourceVersion,
            expectedSelectionGeneration: try XCTUnwrap(selected.selectionGeneration))
        XCTAssertEqual(try workspace.resolveProject(registered.projectId), external.path)
        XCTAssertEqual(try Data(contentsOf: descriptor), beforeExternal)
    }

    func testCopiesCompleteRootVerifiesThenSelectsAndRetainsOriginal() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-relocate-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: RelocationDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        let original = root.appendingPathComponent("original")
        _ = try workspace.create(at: original.path)
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let created = try authoring.create(name: "Seed", kind: "web", trustedKitVersion: "kit-1")
        let notes = original.appendingPathComponent("Extra")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let auxiliary = notes.appendingPathComponent("notes.txt")
        try Data("keep this user file".utf8).write(to: auxiliary)
        let executable = notes.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
            ofItemAtPath: executable.path)
        let originalDescriptor = try Data(contentsOf: original.appendingPathComponent("workspace.json"))
        let initial = try XCTUnwrap(workspace.current())
        let destination = root.appendingPathComponent("relocated")
        XCTAssertThrowsError(try WorkspaceRelocation(workspace: workspace).relocate(
            to: original.appendingPathComponent("nested").path))
        var measured: [WorkspaceCopyProgress] = []
        let receipt = try WorkspaceRelocation(workspace: workspace).relocate(
            to: destination.path, progress: { measured.append($0) })
        XCTAssertEqual(measured.first?.phase, .copying)
        XCTAssertEqual(measured.first?.copiedFiles, 0)
        XCTAssertEqual(measured.last?.phase, .complete)
        XCTAssertEqual(measured.last?.copiedFiles, receipt.fileCount)
        XCTAssertEqual(measured.last?.copiedBytes, receipt.copiedBytes)
        XCTAssertTrue(zip(measured, measured.dropFirst()).allSatisfy {
            $0.copiedFiles <= $1.copiedFiles && $0.copiedBytes <= $1.copiedBytes
        })
        XCTAssertEqual(receipt.originalPath, original.path)
        XCTAssertEqual(receipt.path, destination.path)
        XCTAssertEqual(receipt.workspaceId, initial.descriptor.workspaceId)
        XCTAssertTrue(receipt.unresolvedExternalProjectIds.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Extra/notes.txt")),
            Data("keep this user file".utf8))
        let copiedMode = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("Extra/run.sh").path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(copiedMode.intValue & 0o700, 0o700)
        XCTAssertEqual(copiedMode.intValue & 0o7000, 0)
        XCTAssertEqual(copiedMode.intValue & 0o077, 0)
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("workspace.json")),
            originalDescriptor)
        let selected = try XCTUnwrap(workspace.current())
        XCTAssertEqual(selected.path, destination.path)
        XCTAssertGreaterThan(try XCTUnwrap(selected.selectionGeneration),
            try XCTUnwrap(initial.selectionGeneration))
        XCTAssertEqual(selected.descriptor, initial.descriptor)
        XCTAssertEqual(selected.catalog, initial.catalog)
        XCTAssertEqual(selected.settings, initial.settings)
        XCTAssertEqual(try workspace.resolveProject(created.project.projectId),
            destination.appendingPathComponent(created.project.location.path!).path)
        XCTAssertNoThrow(try workspace.inspect(at: original.path))
        XCTAssertThrowsError(try WorkspaceRelocation(workspace: workspace).relocate(to: original.path))
    }
}
#endif
