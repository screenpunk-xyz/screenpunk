import XCTest
import Foundation
import ScreenpunkCore
import ScreenpunkController
@testable import WorkbenchCommand

final class WorkbenchSnapshotRouteIntegrationTests: XCTestCase {
    func testBuildWatchMultipleVersionsFailureRetentionAndStop() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-watch-sequence-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.path])
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: documents,
            machineRootPath: runtime.appendingPathComponent("machine").path)
        let visible = root.appendingPathComponent("visible")
        _ = try workspace.create(at: visible.path)
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let created = try authoring.create(name: "Watched", kind: "web",
            trustedKitVersion: "builtin-web-1")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime,
            limits: .init(timeout: 1))
        let host = try WorkbenchServiceHost(broker: broker,
            home: root.appendingPathComponent("home"), documents: documents,
            ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("Watch must not activate device transport") },
                    deactivate: {})
            })
        defer { host.stop() }
        let client = WorkbenchBrokerClient(environment: broker)
        try client.connect(); defer { client.close() }
        let headPath = visible.appendingPathComponent(
            "Workbench/Library/BuildHeads/\(created.project.projectId).json")
        var events: [[String: Any]] = []
        var stopped = false
        var fixtureError: Error?
        var latest = created
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        try WorkbenchBuildWatchCLI.run(projectId: created.project.projectId,
            selected: client.workspaceStatus(), client: client,
            presentation: Presentation(json: true),
            cancelled: { stopped || ProcessInfo.processInfo.systemUptime >= deadline },
            onEvent: { event in
                events.append(event)
                do {
                    switch events.count {
                    case 1:
                        XCTAssertEqual(event["state"] as? String, "built")
                        let intermediate = try authoring.patch(created.project.projectId,
                            expectedSourceVersion: latest.sourceVersion,
                            changes: [.init(path: "web/index.html",
                                bytes: Data("<html>intermediate</html>".utf8))])
                        latest = try authoring.patch(created.project.projectId,
                            expectedSourceVersion: intermediate.sourceVersion,
                            changes: [.init(path: "web/index.html",
                                bytes: Data("<html>coalesced</html>".utf8))])
                    case 2:
                        XCTAssertEqual(event["state"] as? String, "built")
                        XCTAssertEqual(event["sourceVersion"] as? String, latest.sourceVersion)
                        latest = try authoring.patch(created.project.projectId,
                            expectedSourceVersion: latest.sourceVersion,
                            changes: [.init(path: "web/unsupported.txt",
                                bytes: Data("unsupported build input".utf8))])
                    case 3:
                        XCTAssertEqual(event["state"] as? String, "failed")
                        XCTAssertEqual(event["sourceVersion"] as? String, latest.sourceVersion)
                        let head = try XCTUnwrap(JSONSerialization.jsonObject(
                            with: Data(contentsOf: headPath)) as? [String: Any])
                        XCTAssertEqual(head["revision"] as? String,
                            events[1]["revision"] as? String)
                        latest = try authoring.patch(created.project.projectId,
                            expectedSourceVersion: latest.sourceVersion,
                            changes: [.init(path: "web/unsupported.txt", bytes: nil),
                                .init(path: "web/index.html",
                                    bytes: Data("<html>recovered</html>".utf8))])
                    case 4:
                        XCTAssertEqual(event["state"] as? String, "built")
                        XCTAssertEqual(event["sourceVersion"] as? String, latest.sourceVersion)
                        stopped = true
                    default:
                        XCTFail("Watcher emitted an unexpected fifth event")
                        stopped = true
                    }
                } catch {
                    fixtureError = error
                    stopped = true
                }
            })
        if let fixtureError { throw fixtureError }
        XCTAssertTrue(stopped, "Watcher timed out before finishing four events")
        XCTAssertEqual(events.map { $0["state"] as? String },
            ["built", "built", "failed", "built"])
        XCTAssertTrue(events.allSatisfy { $0["deployment"] as? String == "not_requested" })
        let finalHead = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: headPath)) as? [String: Any])
        XCTAssertEqual(finalHead["revision"] as? String,
            events[3]["revision"] as? String)
        XCTAssertNotEqual(events[0]["revision"] as? String,
            events[1]["revision"] as? String)
        XCTAssertNotEqual(events[1]["revision"] as? String,
            events[3]["revision"] as? String)
        XCTAssertNoThrow(try client.health(), "Watcher stop must keep broker running")
    }

    func testProcessLocalOperationListThroughLiveBroker() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-operation-list-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.path])
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: documents,
            machineRootPath: runtime.appendingPathComponent("machine").path)
        let selected = try workspace.create(at: root.appendingPathComponent("visible").path)
        let home = root.appendingPathComponent("home")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime,
            limits: .init(timeout: 1))
        var host: WorkbenchServiceHost? = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("copy must not activate device transport") },
                    deactivate: {})
            })
        defer { host?.stop() }
        let client = WorkbenchBrokerClient(environment: broker)
        try client.connect(); defer { client.close() }
        XCTAssertTrue(try client.workspaceOperationList().operations.isEmpty)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["config", "get", "--scope", "machine",
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: [:]), 0)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["config", "path", "--scope", "machine",
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: [:]), 0)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["config", "set", "credential", "unsafe",
            "--scope", "machine", "--home", home.path,
            "--runtime-directory", runtime.path, "--json"], environment: [:]), 8)
        let id = UUID().uuidString.lowercased()
        let destination = root.appendingPathComponent("backup")
        _ = try client.performAuthoring(method: .snapshotCreate, params: [
            "schemaVersion": 1, "path": destination.path,
            "includeExternal": false, "allowIncomplete": false,
            "expectedWorkspaceId": selected.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)
        ], operationId: id)
        let listed = try client.workspaceOperationList()
        XCTAssertEqual(listed.scope, "process-local-workspace-copy")
        XCTAssertFalse(listed.complete)
        XCTAssertEqual(listed.operations.map(\.operationId), [id])
        XCTAssertEqual(listed.operations.first?.state, "applied")
        let combined = try client.operationInventory()
        XCTAssertEqual(combined.scope, "workspace-copy-and-local-deployment")
        XCTAssertFalse(combined.complete)
        XCTAssertEqual(combined.entries.map(\.operationId), [id])
        XCTAssertEqual(combined.entries.first?.durability, "durable-local-journal")
        XCTAssertEqual(try client.operationEntry(operationId: id).state, "applied")
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["operation", "list",
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: [:]), 0)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["operation", "show", id,
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: [:]), 0)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["operation", "cancel", id,
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: [:]), 0)
        XCTAssertEqual(try client.workspaceOperationStatus(operationId: id).state, "applied")
        client.close(); host?.stop(); host = nil
        let restartedHost = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("history read must not activate device transport") },
                    deactivate: {})
            })
        defer { restartedHost.stop() }
        let restartedClient = WorkbenchBrokerClient(environment: broker)
        try restartedClient.connect(); defer { restartedClient.close() }
        XCTAssertTrue(try restartedClient.workspaceOperationList().operations.isEmpty)
        let historical = try restartedClient.operationEntry(operationId: id)
        XCTAssertEqual(historical.state, "applied")
        XCTAssertEqual(historical.durability, "durable-local-journal")
        XCTAssertEqual(historical.workspaceId, selected.descriptor.workspaceId)
        XCTAssertEqual(historical.workspaceCopy?.selectionGeneration,
            selected.selectionGeneration)
        XCTAssertEqual(try restartedClient.operationInventory().entries.map(\.operationId), [id])
        let duplicateDestination = root.appendingPathComponent("duplicate-backup")
        XCTAssertThrowsError(try restartedClient.performAuthoring(method: .snapshotCreate,
            params: ["schemaVersion": 1, "path": duplicateDestination.path,
                "includeExternal": false, "allowIncomplete": false,
                "expectedWorkspaceId": selected.descriptor.workspaceId,
                "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)],
            operationId: id)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicateDestination.path))
        _ = try restartedClient.reconnectIfPeerClosed()
        XCTAssertEqual(try restartedClient.operationEntry(operationId: id).state, "applied")
    }

    func testSnapshotFlagsReachLiveBrokerFromCLI() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-snapshot-cli-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documentsRoot = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documentsRoot, withIntermediateDirectories: false)
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent("home")
        let environment = ["SCREENPUNK_DOCUMENTS_DIRECTORY": documentsRoot.path]
        let documents = CLIWorkspaceDocuments(environment: environment)
        let workspace = try WorkspaceStore(documents: documents,
            machineRootPath: runtime.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html>Exported</html>".utf8)
        let runtimeManifest = Data("{\"runtime\":true}".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "package-export-screen", name: "Exported", revision: "revision-1",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"),
            connections: [],
            files: [.init(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html)),
                .init(path: "manifest.json", bytes: runtimeManifest.count,
                    sha256: DeploymentDigest.sha256Hex(runtimeManifest))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html,
                "manifest.json": runtimeManifest]))
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime,
            limits: .init(timeout: 1))
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("snapshot must not activate device transport") },
                    deactivate: {})
            })
        defer { host.stop() }
        let output = root.appendingPathComponent("backup")
        let packageOutput = root.appendingPathComponent("package-export")
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["screen", "export-package",
            manifest.dashboardId, "--revision", manifest.revision, "--out", packageOutput.path,
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        XCTAssertEqual(try Data(contentsOf: packageOutput.appendingPathComponent("files/index.html")), html)
        XCTAssertEqual(try Data(contentsOf: packageOutput.appendingPathComponent("files/manifest.json")),
            runtimeManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            packageOutput.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            packageOutput.appendingPathComponent("package-archive.json").path))
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["workspace", "snapshot",
            "--out", output.path, "--include-external", "--allow-incomplete",
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        let descriptor = output.appendingPathComponent("workspace.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.path))
        XCTAssertEqual(try WorkspaceSnapshot(workspace: workspace).create(
            at: root.appendingPathComponent("second-backup").path).complete, true)
        let selected = try XCTUnwrap(workspace.current())
        let operationId = UUID().uuidString.lowercased()
        let measured = root.appendingPathComponent("measured-broker-backup")
        let client = WorkbenchBrokerClient(environment: broker)
        try client.connect(); defer { client.close() }
        let requirements = try client.toolchainRequirements()
        XCTAssertTrue(requirements.required.isEmpty)
        XCTAssertEqual(requirements.trust, "not_registered")
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["toolchain", "list",
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        let operation = try client.performAuthoring(method: .snapshotCreate, params: [
            "schemaVersion": 1, "path": measured.path,
            "includeExternal": false, "allowIncomplete": false,
            "expectedWorkspaceId": selected.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)
        ], operationId: operationId)
        let status = try client.workspaceOperationStatus(operationId: operationId)
        let listed = try client.workspaceOperationList()
        XCTAssertEqual(listed.scope, "process-local-workspace-copy")
        XCTAssertFalse(listed.complete)
        XCTAssertTrue(listed.operations.contains { $0.operationId == operationId })
        XCTAssertEqual(status.state, "applied")
        XCTAssertEqual(status.phase, "complete")
        XCTAssertEqual(status.destination, measured.path)
        XCTAssertEqual(status.copiedFiles, operation.snapshot?.fileCount)
        XCTAssertEqual(status.copiedBytes, operation.snapshot?.includedBytes)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["workspace", "operation-status", operationId,
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["operation", "list",
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["operation", "show", operationId,
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["workspace", "operation-cancel", operationId,
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        XCTAssertEqual(try client.workspaceOperationStatus(operationId: operationId).state, "applied")
        let diagnostic = root.appendingPathComponent("diagnostic.json")
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["diagnostics", "export",
            "--out", diagnostic.path, "--home", home.path,
            "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        let reportData = try Data(contentsOf: diagnostic)
        XCTAssertLessThanOrEqual(reportData.count, 16 * 1024)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
        XCTAssertEqual(report["schemaVersion"] as? Int, 1)
        XCTAssertEqual(report["identityProbe"] as? String, "not_performed")
        let rendered = String(decoding: reportData, as: UTF8.self)
        XCTAssertFalse(rendered.contains(home.path))
        XCTAssertFalse(rendered.contains(root.appendingPathComponent("visible").path))
        let requiredPin = String(repeating: "b", count: 64)
        try Data("""
        {"schemaVersion":1,"required":[{"catalogEntryId":"kit-1","kitVersion":"v1","platform":"darwin-arm64","inventoryHash":"\(requiredPin)"}]}
        """.utf8).write(to: root.appendingPathComponent(
            "visible/Workbench/Toolchains/requirements.json"), options: .atomic)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["toolchain", "install", "--required",
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 8)
        let project = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Unregister", kind: "web", trustedKitVersion: "builtin-web-1")
        let react = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "React", kind: "react", trustedKitVersion: "builtin-react-1")
        let requirementsPath = root.appendingPathComponent("visible/Workbench/Toolchains/requirements.json")
        let requirementsBefore = try Data(contentsOf: requirementsPath)
        let kitGeneration = try XCTUnwrap(workspace.current()?.catalog.generation)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["project", "upgrade-kit",
            react.project.projectId, "--source-version", react.sourceVersion,
            "--catalog-entry", "test-kit-2", "--kit-version", "2.0.0",
            "--inventory", String(repeating: "a", count: 64),
            "--generation", String(kitGeneration),
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 8)
        XCTAssertEqual(try Data(contentsOf: requirementsPath), requirementsBefore)
        XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: workspace)
            .get(react.project.projectId).sourceVersion, react.sourceVersion)
        let watchUntil = ProcessInfo.processInfo.systemUptime + 1.1
        try WorkbenchBuildWatchCLI.run(projectId: project.project.projectId,
            selected: client.workspaceStatus(), client: client,
            presentation: Presentation(json: true),
            cancelled: { ProcessInfo.processInfo.systemUptime >= watchUntil })
        XCTAssertNotNil(try client.performAuthoring(method: .buildHead, params: [
            "schemaVersion": 1, "projectId": project.project.projectId]).build)
        let relocated = root.appendingPathComponent("visible/Screens/relocated")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: project.path), to: relocated)
        let relocationGeneration = try XCTUnwrap(workspace.current()?.catalog.generation)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["project", "relocate",
            project.project.projectId, "--source-version", project.sourceVersion,
            "--to", "Screens/relocated", "--generation", String(relocationGeneration),
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
        XCTAssertEqual(try XCTUnwrap(workspace.current()).catalog.projects.first {
            $0.projectId == project.project.projectId
        }?.location.path, "Screens/relocated")
        let generation = try XCTUnwrap(workspace.current()?.catalog.generation)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["project", "unregister",
            project.project.projectId, "--generation", String(generation),
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
        XCTAssertFalse(try XCTUnwrap(workspace.current()).catalog.projects.contains {
            $0.projectId == project.project.projectId
        })

        _ = try workspace.create(at: root.appendingPathComponent("restored").path)
        for (name, mutation) in [
            ("extra", "extra"), ("changed", "changed"), ("marker", "marker")
        ] {
            let invalid = root.appendingPathComponent(name)
            try FileManager.default.copyItem(at: packageOutput, to: invalid)
            switch mutation {
            case "extra": try Data("unlisted".utf8).write(to: invalid.appendingPathComponent("files/extra.txt"))
            case "changed": try Data("changed".utf8).write(to: invalid.appendingPathComponent("files/index.html"))
            default:
                try Data("{}".utf8).write(to: invalid.appendingPathComponent("package-archive.json"))
            }
            XCTAssertEqual(WorkbenchCommand.run(arguments: ["screen", "import-package", invalid.path,
                "--home", home.path, "--runtime-directory", runtime.path, "--json"],
                environment: environment), 6)
        }
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["screen", "import-package", packageOutput.path,
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        let restored = try WorkbenchPortablePackages(workspace: workspace).exportVerified(
            dashboardId: manifest.dashboardId, revision: manifest.revision)
        XCTAssertEqual(restored.files["index.html"], html)
        XCTAssertEqual(restored.files["manifest.json"], runtimeManifest)
        XCTAssertTrue(try XCTUnwrap(workspace.current()).catalog.projects.isEmpty)

        let legacy = root.appendingPathComponent("legacy-package")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        try html.write(to: legacy.appendingPathComponent("index.html"))
        // The legacy flat format cannot place a runtime manifest.json beside its descriptor.
        let legacyManifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "legacy-package-screen", name: "Legacy", revision: "revision-1",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [.init(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        var sealedLegacy = legacyManifest
        sealedLegacy.digest = try DeploymentDigest.digest(for: sealedLegacy)
        try JSONEncoder().encode(sealedLegacy).write(to: legacy.appendingPathComponent("manifest.json"))
        _ = try workspace.create(at: root.appendingPathComponent("legacy-restored").path)
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["screen", "import", legacy.path,
            "--home", home.path, "--runtime-directory", runtime.path, "--json"],
            environment: environment), 0)
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: workspace).exportVerified(
            dashboardId: sealedLegacy.dashboardId, revision: sealedLegacy.revision).files["index.html"], html)
        let invalidMarkerOnLegacy = root.appendingPathComponent("legacy-with-invalid-marker")
        try FileManager.default.copyItem(at: legacy, to: invalidMarkerOnLegacy)
        try Data("{}".utf8).write(to: invalidMarkerOnLegacy.appendingPathComponent("package-archive.json"))
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["screen", "import-package",
            invalidMarkerOnLegacy.path, "--home", home.path,
            "--runtime-directory", runtime.path, "--json"], environment: environment), 6)
    }
}
