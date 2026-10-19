import XCTest
import Foundation
import CryptoKit
import ScreenpunkController
@testable import WorkbenchCommand

final class LocalOnlyStartupTests: XCTestCase {
    private func fixture() throws -> URL {
        let parent = URL(fileURLWithPath: "/private/tmp/sp-lo-01a14a82")
        let root = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }

    func testFlagIsForegroundOnlyAndRejectedBeforeBootstrap() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let options = try Options.parse(["--local-only"], environment: [:])
        XCTAssertEqual(try options.cloudSyncStartup(for: ["service", "run", "--foreground"]), .localOnly)
        XCTAssertEqual(try Options.parse([], environment: [:]).cloudSyncStartup(for: ["service", "start"]), .automatic)
        for words in [["service", "start"], ["service", "restart"], ["service", "stop"],
                      ["cloud", "status"], ["workspace", "init", root.appendingPathComponent("workspace").path],
                      ["mcp", "serve"], ["status"]] {
            XCTAssertThrowsError(try options.cloudSyncStartup(for: words))
            XCTAssertNotEqual(WorkbenchCommand.run(arguments: words + ["--local-only", "--json",
                "--home", root.appendingPathComponent("home").path,
                "--runtime-directory", root.appendingPathComponent("runtime").path],
                environment: ["SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path]), 0)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertTrue(WorkbenchCloudSyncStartup.localOnly.readinessDiagnostic.contains("pending work are unchanged"))
        XCTAssertTrue(WorkbenchCloudSyncStartup.localOnly.readinessDiagnostic.contains("local-only"))
    }

    func testLocalOnlyRetainsEnabledFifteenScreenQueueThroughPatchBuildExportAndStop() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime"), home = root.appendingPathComponent("home")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let machine = runtime.appendingPathComponent("machine")
        let documents = CLIWorkspaceDocuments(environment: ["SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path])
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: documents, machineRootPath: machine.path)
        _ = try workspace.create(at: root.appendingPathComponent("workspace").path)
        let localID = try XCTUnwrap(workspace.current()?.descriptor.workspaceId)
        // Prepare the existing project before Cloud consent/pending work exists.
        // New-project creation has its own local Cloud handoff and is deliberately
        // outside the recovery window being tested.
        func prepareExistingProject() throws -> WorkbenchAuthoringRecoveryResult {
            let preparation = try WorkbenchServiceHost(broker: broker, home: home, documents: documents,
                ownerCheck: {}, nativeFactory: { _ in nil }, cloudSyncStartup: .localOnly)
            defer { preparation.stop() }
            let client = WorkbenchBrokerClient(environment: broker)
            try client.connect(); defer { client.close() }
            return try client.performAuthoring(method: .projectCreate,
                params: ["schemaVersion": 1, "name": "Existing Screen", "kind": "web"])
        }
        let created = try prepareExistingProject()
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(created)) as? [String: Any])
        let sourceProject = try XCTUnwrap(encoded["project"] as? [String: Any])
        let project = try XCTUnwrap(sourceProject["project"] as? [String: Any])
        let id = try XCTUnwrap(project["projectId"] as? String)
        let dashboard = try XCTUnwrap(project["dashboardId"] as? String)
        let source = try XCTUnwrap(sourceProject["sourceVersion"] as? String)
        let base = URL(string: "https://local-only-fixture.invalid")!
        let namespace = SHA256.hash(data: Data(base.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let cloudRoot = machine.appendingPathComponent("cloud-controller/" + namespace)
        try FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
        let account = UUID().uuidString, remote = UUID().uuidString, epoch = UUID().uuidString
        let selection: [String: Any] = ["accountId": account, "workspaceId": remote, "localWorkspaceId": localID]
        let policy = selection.merging(["enabled": true, "epoch": epoch, "clientId": "screenpunk-mac"] as [String: Any]) { _, new in new }
        let context = policy.merging(["policyEpoch": epoch, "screenSyncEnabled": true]) { _, new in new }
        let ids = (0..<15).map { _ in UUID().uuidString.lowercased() }
        let request = selection.merging(["requestId": UUID().uuidString.lowercased(), "trigger": "localChanged",
            "clientId": "screenpunk-mac", "epoch": epoch, "dashboardIds": ids,
            "requiresFullCheck": true, "notBefore": Date().addingTimeInterval(-10).timeIntervalSinceReferenceDate] as [String: Any]) { _, new in new }
        for (name, object) in [("selection.json", selection), ("screen-sync-policy.json", policy),
                               ("creation-context-screenpunk-mac.json", context), ("screen-sync-request.json", request)] {
            let file = cloudRoot.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func snapshot() throws -> [String: String] {
            var result: [String: String] = [:]
            for file in try FileManager.default.contentsOfDirectory(at: cloudRoot, includingPropertiesForKeys: nil) {
                let data = try Data(contentsOf: file)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                result[file.lastPathComponent] = data.base64EncodedString() + "|" + String(describing: attributes[.systemFileNumber]!) + "|" + String(describing: attributes[.modificationDate]!) + "|" + String(describing: attributes[.posixPermissions]!)
            }
            return result
        }
        XCTAssertEqual(try ControllerCloudWorkbench.screenSyncOwner(baseURL: base, machineRoot: machine), "screenpunk-mac")
        let pending = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine))
        XCTAssertEqual(pending.dashboardIds.count, 15)
        XCTAssertTrue(pending.requiresFullCheck)
        let before = try snapshot()
        var cloudConstructions = 0, nativeActivations = 0
        let host = try WorkbenchServiceHost(broker: broker, home: home, documents: documents,
            ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in nativeActivations += 1 }, deactivate: {})
            }, cloudSyncStartup: .localOnly, cloudTaskFactory: {
                cloudConstructions += 1
                return Task {}
            })
        defer { host.stop() }
        let client = WorkbenchBrokerClient(environment: broker)
        try client.connect()
        defer { client.close() }
        XCTAssertEqual(try snapshot(), before)
        var candidate = Bundle(for: Self.self).bundleURL
        var binary = ProcessInfo.processInfo.environment["SP_CLI_TEST_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
        for _ in 0..<7 where binary == nil {
            let file = candidate.appendingPathComponent("screenpunk")
            if FileManager.default.isExecutableFile(atPath: file.path) { binary = file }
            candidate.deleteLastPathComponent()
        }
        let executable = try XCTUnwrap(binary)
        func run(_ words: [String], status: Int32 = 0) throws -> [String: Any] {
            let output = root.appendingPathComponent(UUID().uuidString + ".json")
            XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process(); process.executableURL = executable
            // An invalid supplied origin deliberately makes accidental Cloud facade
            // construction fail. Ordinary existing-project routes must ignore it.
            process.environment = ["PATH": "/usr/bin:/bin", "SCREENPUNK_CLOUD_BASE_URL": "invalid-origin",
                "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path]
            process.arguments = words + ["--json", "--no-input", "--home", home.path, "--runtime-directory", runtime.path]
            process.standardOutput = handle; process.standardError = handle
            try process.run(); process.waitUntilExit()
            let bytes = try Data(contentsOf: output)
            XCTAssertEqual(process.terminationStatus, status, String(decoding: bytes, as: UTF8.self))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        }
        func result(_ words: [String]) throws -> [String: Any] { try XCTUnwrap(run(words)["result"] as? [String: Any]) }
        _ = try result(["workspace", "show"])
        _ = try result(["device", "list"])
        let input = root.appendingPathComponent("edited.html")
        try Data("<html><body>Local-only existing Screen</body></html>".utf8).write(to: input)
        let edited = try XCTUnwrap(result(["project", "edit", id, source, "web/index.html", input.path])["project"] as? [String: Any])
        let updatedSource = try XCTUnwrap(edited["sourceVersion"] as? String)
        XCTAssertNotEqual(updatedSource, source)
        let stale = try XCTUnwrap(run(["build", "run", id, source], status: 6)["error"] as? [String: Any])
        XCTAssertEqual(stale["code"] as? String, "build_source_conflict")
        let built = try XCTUnwrap(result(["build", "run", id, updatedSource])["build"] as? [String: Any])
        let revision = try XCTUnwrap(built["revision"] as? String)
        let exported = try result(["screen", "export-package", dashboard, "--revision", revision,
            "--out", root.appendingPathComponent("export").path])
        XCTAssertNotNil(exported["packageExport"])
        XCTAssertThrowsError(try WorkbenchServiceHost(broker: broker, home: home, documents: documents,
            ownerCheck: {}, nativeFactory: { _ in nil }, cloudTaskFactory: { cloudConstructions += 1; return Task {} }))
        // Allow an incorrectly started async worker enough time to expose itself.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(cloudConstructions, 0)
        XCTAssertEqual(nativeActivations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: machine.appendingPathComponent("cloud-sync-status.json").path))
        XCTAssertEqual(try snapshot(), before)
        client.close(); host.stop()
        XCTAssertEqual(try snapshot(), before)
        XCTAssertEqual(try ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine)?.requestId, pending.requestId)
        for method: WorkbenchAuthoringRecoveryMethod in [.projectPatch, .buildRun, .packageExport] {
            XCTAssertFalse(WorkbenchCloudCLI.automaticallyLinksNewProject(method))
        }
    }

    func testProductionLocalOnlyBranchCreatesNoCloudStatusOrNamespace() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let host = try WorkbenchServiceHost(broker: broker, home: root.appendingPathComponent("home"),
            documents: CLIWorkspaceDocuments(environment: ["SCREENPUNK_CLOUD_BASE_URL": "invalid-origin",
                "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path]),
            ownerCheck: {}, nativeFactory: { _ in nil }, cloudSyncStartup: .localOnly)
        defer { host.stop() }
        let client = WorkbenchBrokerClient(environment: broker)
        try client.connect(); defer { client.close() }
        XCTAssertNoThrow(try client.workspaceStatus())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("machine/cloud-sync-status.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("machine/cloud-controller").path))
    }

    func testAutomaticDefaultStillConstructsWorkerAndSecondHostCannotReuseIt() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let home = root.appendingPathComponent("home")
        let documents = CLIWorkspaceDocuments(environment: ["SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path])
        var constructions = 0
        let host = try WorkbenchServiceHost(broker: broker, home: home, documents: documents,
            ownerCheck: {}, nativeFactory: { _ in nil }, cloudTaskFactory: { constructions += 1; return Task {} })
        defer { host.stop() }
        XCTAssertEqual(constructions, 1)
        XCTAssertThrowsError(try WorkbenchServiceHost(broker: broker, home: home, documents: documents,
            ownerCheck: {}, nativeFactory: { _ in nil }, cloudSyncStartup: .localOnly,
            cloudTaskFactory: { constructions += 1; return Task {} }))
        XCTAssertEqual(constructions, 1)
        let client = WorkbenchBrokerClient(environment: broker)
        try client.connect(); defer { client.close() }
        XCTAssertNoThrow(try client.workspaceStatus())
    }
}
