#if os(macOS)
import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

private struct ScreenMutationDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

final class WorkbenchScreenMutationSocketTests: XCTestCase {
    func testArchiveHidesActiveListsButRetainsHistoryAndReactAssociationIsExact() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-archive-socket-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: ScreenMutationDocuments(root: root),
            machineRootPath: machine.path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let hiddenSource = try authoring.create(name: "Hidden", kind: "react", trustedKitVersion: "kit-1")
        let associatedSource = try authoring.create(name: "Associate", kind: "react", trustedKitVersion: "kit-1")
        func package(_ dashboardId: String) throws -> DashboardManifest {
            let bytes = Data("<html>retained</html>".utf8)
            var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
                dashboardId: dashboardId, name: "Retained", revision: UUID().uuidString.lowercased(),
                entrypoint: "index.html", sdkVersion: "1",
                target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1,
                    orientation: "landscape"), connections: [],
                files: [ManifestFile(path: "index.html", bytes: bytes.count,
                    sha256: DeploymentDigest.sha256Hex(bytes))])
            manifest.digest = try DeploymentDigest.digest(for: manifest)
            _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
                .init(manifest: manifest, files: ["index.html": bytes]))
            return manifest
        }
        let hiddenPackage = try package(hiddenSource.project.dashboardId)
        let associationPackage = try package(UUID().uuidString.lowercased())
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"),
            deviceDirectoryURL: machine.appendingPathComponent("devices.json"), rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let server = WorkbenchBrokerServer(environment: environment,
            domain: WorkbenchBrokerDomain(controller: controller, workspace: workspace, mutationGate: {}))
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect(); defer { client.close() }
        func fields(_ extra: [String: Any]) throws -> [String: Any] {
            let selected = try XCTUnwrap(workspace.current())
            return ["schemaVersion": 1, "expectedWorkspaceId": selected.descriptor.workspaceId,
                "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration),
                "expectedCatalogGeneration": selected.descriptor.generation]
                .merging(extra) { _, new in new }
        }
        let archiveFields = try fields(["dashboardId": hiddenPackage.dashboardId,
            "expectedRevision": hiddenPackage.revision,
            "expectedDigest": try XCTUnwrap(hiddenPackage.digest)])
        let archived = try client.archiveScreen(params: archiveFields)
        XCTAssertTrue(archived.sourceRetained)
        XCTAssertTrue(archived.packageHistoryRetained)
        XCTAssertFalse(try client.listProjects().contains { $0.projectId == hiddenSource.project.projectId })
        XCTAssertEqual(try client.getProject(hiddenSource.project.projectId).dashboardId,
            hiddenSource.project.dashboardId)
        let selected = try client.workspaceStatus()
        XCTAssertFalse(try client.listWorkspacePackages(in: selected).contains {
            $0.dashboardId == hiddenPackage.dashboardId
        })
        XCTAssertEqual(try client.workspacePackage(dashboardId: hiddenPackage.dashboardId,
            revision: hiddenPackage.revision, in: selected).digest, hiddenPackage.digest)
        let attachFields = try fields(["projectId": associatedSource.project.projectId,
            "expectedSourceVersion": associatedSource.sourceVersion,
            "dashboardId": associationPackage.dashboardId,
            "expectedRevision": associationPackage.revision,
            "expectedDigest": try XCTUnwrap(associationPackage.digest)])
        let attached = try client.associateReactSource(params: attachFields)
        XCTAssertEqual(attached.project.project.dashboardId, associationPackage.dashboardId)
        XCTAssertNotEqual(attached.project.sourceVersion, associatedSource.sourceVersion)
        XCTAssertFalse(attached.authorityRestored)
        XCTAssertThrowsError(try client.associateReactSource(params: attachFields)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
    }

    func testForgedScreenResultExtraFieldsAreRejectedAfterDecode() throws {
        let value = WorkbenchScreenMutationResult.iconSet(.init(
            workspaceId: "workspace-a", selectionGeneration: 1, catalogGeneration: 2,
            dashboardId: "dashboard-a", symbol: "star.fill"))
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(value)) as? [String: Any])
        try value.validateWireShape(wire)
        var payload = try XCTUnwrap(wire["value"] as? [String: Any])
        payload["authority"] = "admin"
        wire["value"] = payload
        let forged = try JSONSerialization.data(withJSONObject: wire)
        XCTAssertNoThrow(try JSONDecoder().decode(WorkbenchScreenMutationResult.self,
            from: forged), "Synthesized result decoding alone ignores unknown members.")
        XCTAssertThrowsError(try value.validateWireShape(wire)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .invalidRequest)
        }
    }

    func testMissingOwnerGateRefusesScreenWriteWithoutChangingWorkspace() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-screen-no-gate-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: ScreenMutationDocuments(root: root),
            machineRootPath: machine.path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let source = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Original", kind: "web", trustedKitVersion: "kit-1")
        let before = try XCTUnwrap(workspace.current())
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"),
            deviceDirectoryURL: machine.appendingPathComponent("devices.json"), rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let server = WorkbenchBrokerServer(environment: environment,
            domain: WorkbenchBrokerDomain(controller: controller, workspace: workspace))
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect(); defer { client.close() }
        XCTAssertThrowsError(try client.setScreenIcon(params: ["schemaVersion": 1,
            "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": source.project.dashboardId, "symbol": "star.fill"])) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .incompatibleOwner)
        }
        let after = try XCTUnwrap(workspace.current())
        XCTAssertEqual(after.descriptor.generation, before.descriptor.generation)
        XCTAssertTrue(after.settings.screenIcons.isEmpty)
    }

    func testOrdinarySocketRoutesAllFiveClosedMutations() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-screen-socket-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: ScreenMutationDocuments(root: root),
            machineRootPath: machine.path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let source = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Source", kind: "web", trustedKitVersion: "kit-1")
        let bytes = Data("<html>package</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Package",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1,
                orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: bytes.count,
                sha256: DeploymentDigest.sha256Hex(bytes))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let packages = WorkbenchPortablePackages(workspace: workspace)
        _ = try packages.importVerified(.init(manifest: manifest, files: ["index.html": bytes]))
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"),
            deviceDirectoryURL: machine.appendingPathComponent("devices.json"), rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let server = WorkbenchBrokerServer(environment: environment,
            domain: WorkbenchBrokerDomain(controller: controller, workspace: workspace, mutationGate: {}))
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect(); defer { client.close() }
        let selected = try XCTUnwrap(workspace.current())
        let workspaceId = selected.descriptor.workspaceId
        let selection = try XCTUnwrap(selected.selectionGeneration)
        func fields(_ extra: [String: Any]) throws -> [String: Any] {
            ["schemaVersion": 1, "expectedWorkspaceId": workspaceId,
             "expectedSelectionGeneration": selection,
             "expectedCatalogGeneration": try XCTUnwrap(workspace.current()).descriptor.generation]
                .merging(extra) { _, new in new }
        }
        let sourceRequest = try fields(["projectId": source.project.projectId,
            "expectedSourceVersion": source.sourceVersion, "name": "Renamed source"])
        let sourceResult = try client.renameScreenSource(params: sourceRequest)
        XCTAssertEqual(sourceResult.project.project.name, "Renamed source")
        let wrapped = WorkbenchScreenMutationResult.sourceRename(sourceResult)
        var response = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(wrapped)) as? [String: Any])
        try wrapped.validateWireShape(response)
        var payload = try XCTUnwrap(response["value"] as? [String: Any])
        payload["unexpectedAuthority"] = "owner"
        response["value"] = payload
        XCTAssertThrowsError(try wrapped.validateWireShape(response))
        payload.removeValue(forKey: "unexpectedAuthority")
        var sourcePayload = try XCTUnwrap(payload["project"] as? [String: Any])
        sourcePayload["credential"] = "never"
        payload["project"] = sourcePayload
        response["value"] = payload
        XCTAssertThrowsError(try wrapped.validateWireShape(response))
        XCTAssertThrowsError(try client.renameScreenSource(params: sourceRequest)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        try client.connect()
        let iconRequest = try fields(["dashboardId": manifest.dashboardId, "symbol": "star.fill"])
        XCTAssertEqual(try client.setScreenIcon(params: iconRequest).symbol, "star.fill")
        var injected = try fields(["dashboardId": manifest.dashboardId, "symbol": "star"])
        injected["role"] = "owner"
        XCTAssertThrowsError(try client.setScreenIcon(params: injected)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .invalidRequest)
        }
        func packageFields(_ extra: [String: Any]) throws -> [String: Any] {
            try fields(["dashboardId": manifest.dashboardId,
                "expectedRevision": manifest.revision,
                "expectedDigest": try XCTUnwrap(manifest.digest)]).merging(extra) { _, new in new }
        }
        let renamed = try client.renameScreenPackage(params: packageFields(["name": "Renamed package"]))
        XCTAssertEqual(renamed.name, "Renamed package")
        XCTAssertEqual(try packages.get(dashboardId: manifest.dashboardId,
            revision: manifest.revision).manifest, manifest)
        let duplicate = try client.duplicateScreenPackage(params: packageFields(["name": "Copy"]))
        XCTAssertNotEqual(duplicate.dashboardId, manifest.dashboardId)
        XCTAssertEqual(duplicate.sourceRevision, manifest.revision)
        let oriented = try client.setScreenPackageOrientation(params: packageFields(["support": "portrait"]))
        XCTAssertEqual(oriented.support, .portrait)
        XCTAssertEqual(try ScreenDesignSettings.read(files: packages.get(
            dashboardId: manifest.dashboardId, revision: oriented.revision).files).orientations, .portrait)
    }
}
#endif
