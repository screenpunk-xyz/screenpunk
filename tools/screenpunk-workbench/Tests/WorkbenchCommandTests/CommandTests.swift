import XCTest
import Foundation
import Darwin
@testable import WorkbenchCommand
import ScreenpunkController
import ScreenpunkCore

private final class CLIExactDeviceState: @unchecked Sendable {
    let lock = NSLock()
    let pin = Array(repeating: UInt8(9), count: 32)
    let profile = DeviceProfile(deviceId: "cli-exact-device", name: "Fixture iPad")
    var screens: [LANScreenSetEntry] = []
    var selected: String?
    var sends = 0
}
private final class CLIExactLink: DeviceLink {
    let state: CLIExactDeviceState
    init(_ state: CLIExactDeviceState) { self.state = state }
    var devicePin: [UInt8]? { state.pin }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws {
        guard pinnedDevice == state.pin else { throw TransferFailure.validationFailed }
    }
    func hello() throws -> LANHello {
        LANHello(role: .device, deviceId: state.profile.deviceId,
            pinHex: PeerPin.hex(state.pin), name: state.profile.name,
            capabilities: ["screen-set-v1"], maxTransferBytes: 32 * 1024 * 1024,
            profile: state.profile)
    }
    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult { throw TransferFailure.notPaired }
    func confirmPairing(code: String) throws { throw TransferFailure.notPaired }
    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord { throw TransferFailure.validationFailed }
    func queryActive() throws -> String? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.screens.first(where: { $0.dashboardId == state.selected })?.revision
    }
    func queryActiveState() throws -> LANActiveQuery {
        state.lock.lock(); defer { state.lock.unlock() }
        let revision = state.screens.first(where: { $0.dashboardId == state.selected })?.revision
        return LANActiveQuery(revision: revision, screens: state.screens,
            selectedDashboardId: state.selected)
    }
    func deployScreenSet(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt {
        try body.validate()
        let screens = body.screens.map { LANScreenSetEntry(
            dashboardId: $0.deployment.revision.dashboardId,
            revision: $0.deployment.revision.revision, name: $0.name) }
        state.lock.lock(); defer { state.lock.unlock() }
        state.screens = screens; state.selected = body.selectedDashboardId; state.sends += 1
        return LANScreenSetReceipt(deploymentId: body.deploymentId,
            deviceId: body.deviceId, screens: screens,
            selectedDashboardId: body.selectedDashboardId)
    }
    func cancel() {}
}
private struct CLIExactLinkFactory: DeviceLinkFactory {
    let controllerIdentity: PairingIdentity
    let state: CLIExactDeviceState
    func makeLink() throws -> DeviceLink { CLIExactLink(state) }
}

final class CommandTests: XCTestCase {
    func testBuildWatchDebouncesLatestSourceAndAttemptsEachVersionOnce() throws {
        var watch = WorkbenchBuildWatchDebouncer()
        XCTAssertNil(watch.observe("source-a", at: 0))
        XCTAssertNil(watch.observe("source-b", at: 0.1))
        XCTAssertNil(watch.observe("source-b", at: 0.39))
        XCTAssertEqual(watch.observe("source-b", at: 0.4), "source-b")
        XCTAssertNil(watch.observe("source-b", at: 1))
        XCTAssertNil(watch.observe("source-c", at: 1.1))
        XCTAssertEqual(watch.observe("source-c", at: 1.41), "source-c")
        XCTAssertEqual(try WorkbenchBuildWatchCLI.projectId(["build", "--watch", "project-a"]),
            "project-a")
        XCTAssertEqual(try WorkbenchBuildWatchCLI.projectId(["build", "run", "project-a", "--watch"]),
            "project-a")
    }

    func testSubmittedPackageImportReplyLossAndLateSignalOutcomes() throws {
        let metadata = (workspace: "workspace-a", dashboard: "dashboard-a",
            revision: "revision-a", digest: String(repeating: "a", count: 64))
        for code: WorkbenchIPCErrorCode in [.disconnected, .timedOut, .unavailable] {
            XCTAssertThrowsError(try WorkbenchPackageImportCLI.classifySubmittedCommit(
                workspaceId: metadata.workspace, dashboardId: metadata.dashboard,
                revision: metadata.revision, digest: metadata.digest,
                send: { () -> Int in throw WorkbenchIPCError(code) })) { error in
                guard let failure = error as? CommandFailure else {
                    return XCTFail("Expected uncertain import classification")
                }
                XCTAssertEqual(failure.code, "outcome_unknown")
                XCTAssertEqual(failure.exitStatus, 7)
                XCTAssertEqual(failure.details["workspaceId"], metadata.workspace)
                XCTAssertEqual(failure.details["dashboardId"], metadata.dashboard)
                XCTAssertEqual(failure.details["revision"], metadata.revision)
                XCTAssertEqual(failure.details["digest"], metadata.digest)
            }
        }
        let receipt: Int = try WorkbenchPackageImportCLI.classifySubmittedCommit(
            workspaceId: metadata.workspace, dashboardId: metadata.dashboard,
            revision: metadata.revision, digest: metadata.digest, send: { 42 })
        XCTAssertEqual(receipt, 42)
        XCTAssertNil(WorkbenchCommand.postDispatchCancellationFailure(
            signalReceived: true, mutationApplied: true))
        XCTAssertEqual(WorkbenchCommand.postDispatchCancellationFailure(
            signalReceived: true, mutationApplied: false)?.code, "cancelled")
        let export = WorkbenchCommand.packageExportUncertainFailure(
            destination: "/private/tmp/exact-export")
        XCTAssertEqual(export.code, "outcome_unknown")
        XCTAssertEqual(export.details["destination"], "/private/tmp/exact-export")
        XCTAssertTrue(export.nextActions.joined().contains("Inspect the exact destination"))
        XCTAssertTrue(WorkbenchCommand.packageExportOutcomeUnknown(
            WorkbenchIPCError(.publicationOutcomeUnknown)))
        XCTAssertFalse(WorkbenchCommand.packageExportOutcomeUnknown(
            WorkbenchIPCError(.workspaceConflict)))
    }

    func testConfiguredMCPStreamsOpenPipeAndRefreshesIdleBrokerSession() throws {
        let runtime = root.appendingPathComponent("mcp-stream-runtime")
        let home = root.appendingPathComponent("mcp-stream-home")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path])
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in nil })
        defer { host.stop() }
        let input = Pipe(), output = Pipe()
        let child = Process()
        child.executableURL = binaries.appendingPathComponent("screenpunk")
        child.arguments = ["mcp", "serve", "--home", home.path,
                           "--runtime-directory", runtime.path]
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path,
            "TMPDIR": root.path,
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        func exchange(_ id: Int, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": id,
                "method": method, "params": params]
            let bytes = try JSONSerialization.data(withJSONObject: request,
                options: [.sortedKeys]) + Data([10])
            try input.fileHandleForWriting.write(contentsOf: bytes)
            var response = Data()
            let fd = output.fileHandleForReading.fileDescriptor
            while response.count < 1024 * 1024 {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 3_000) > 0 else {
                    XCTFail("MCP response did not arrive while stdin remained open")
                    throw WorkbenchIPCError(.timedOut)
                }
                var byte: UInt8 = 0
                guard Darwin.read(fd, &byte, 1) == 1 else { throw WorkbenchIPCError(.disconnected) }
                if byte == 10 {
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
                    XCTAssertEqual((object["id"] as? NSNumber)?.intValue, id)
                    return object
                }
                response.append(byte)
            }
            throw WorkbenchIPCError(.frameTooLarge)
        }
        XCTAssertNotNil(try exchange(1, "initialize")["result"])
        XCTAssertNotNil((try exchange(2, "tools/list")["result"] as? [String: Any])?["tools"])
        let workspace = root.appendingPathComponent("mcp-stream-workspace")
        let created = try exchange(3, "tools/call", ["name": "initialize_workspace",
            "arguments": ["path": workspace.path]])
        XCTAssertEqual((created["result"] as? [String: Any])?["isError"] as? Bool, false)
        Thread.sleep(forTimeInterval: 11)
        let observer = WorkbenchBrokerClient(environment: broker)
        try observer.connect(); defer { observer.close() }
        XCTAssertEqual(try observer.serviceLifecycle().authenticatedConnections, 1,
            "The original MCP socket must have closed before the next call")
        let read = try exchange(4, "tools/call", ["name": "get_workspace", "arguments": [:]])
        XCTAssertEqual((read["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(try observer.serviceLifecycle().authenticatedConnections, 2)
        XCTAssertTrue(child.isRunning)
        observer.close()
        host.stop()
        let otherHome = root.appendingPathComponent("mcp-stream-foreign-home")
        let foreign = try WorkbenchServiceHost(broker: broker, home: otherHome,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in nil })
        defer { foreign.stop() }
        let mismatch = try exchange(5, "tools/call", ["name": "get_workspace", "arguments": [:]])
        XCTAssertEqual((mismatch["result"] as? [String: Any])?["isError"] as? Bool, true)
        let stillRejected = try exchange(6, "tools/call", ["name": "get_workspace", "arguments": [:]])
        XCTAssertEqual((stillRejected["result"] as? [String: Any])?["isError"] as? Bool, true,
            "A wrong-home refreshed socket must not be reused for a later request")
    }

    func testPortableSourceExportImportThroughInstalledCLIRoute() throws {
        let runtime = root.appendingPathComponent("portable-cli-runtime")
        let home = root.appendingPathComponent("portable-cli-home")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path])
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in nil })
        defer { host.stop() }
        func command(_ words: [String]) throws -> [String: Any] {
            let response = try run(words + ["--home", home.path, "--json"], runtime: runtime)
            XCTAssertEqual(response.status, 0, response.stdout)
            return try XCTUnwrap(response.json()["result"] as? [String: Any])
        }
        _ = try command(["workspace", "init", root.appendingPathComponent("portable-workspace").path])
        let created = try command(["project", "create", "Portable"])
        let source = try XCTUnwrap(created["project"] as? [String: Any])
        let project = try XCTUnwrap(source["project"] as? [String: Any])
        let id = try XCTUnwrap(project["projectId"] as? String)
        let version = try XCTUnwrap(source["sourceVersion"] as? String)
        let archive = root.appendingPathComponent("portable-export")
        let exported = try command(["project", "export-source", id,
            "--source-version", version, "--out", archive.path])
        XCTAssertEqual((exported["sourceArchive"] as? [String: Any])?["sourceVersion"] as? String,
            version)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            archive.appendingPathComponent("source-archive.json").path))
        let imported = try command(["project", "import-source", archive.path,
            "--to", "Screens/recovered"])
        let importedSource = try XCTUnwrap(imported["project"] as? [String: Any])
        let importedProject = try XCTUnwrap(importedSource["project"] as? [String: Any])
        XCTAssertNotEqual(importedProject["projectId"] as? String, id)
        XCTAssertEqual((importedSource["sourceVersion"] as? String)?.count, 64)
        XCTAssertNotEqual(importedSource["sourceVersion"] as? String, version,
            "Fresh project and dashboard IDs change the editable-source hash")
    }

    func testAgentListUsesTheConfiguredMCPToolSetWithoutStartingService() throws {
        let result = try run(["agent", "list", "--json"],
            runtime: root.appendingPathComponent("agent-list"))
        XCTAssertEqual(result.status, 0, result.stdout)
        let listed = (try result.json()["result"] as? [String: Any])?["tools"] as? [String]
        XCTAssertEqual(listed, WorkbenchMCPBridge.names)
        XCTAssertTrue(listed?.contains("request_connection_intent") == true)
    }

    func testCopiedCLISymlinkLoadsOnlyPackagedResourcesForAgentAndMCP() throws {
        let originalBinaries = binaries!
        let release = root.appendingPathComponent("Caskroom/screenpunk-cli/1.0.3/Screenpunk CLI 1.0.3")
        let packagedBin = release.appendingPathComponent("bin")
        let links = root.appendingPathComponent("bin")
        let resources = release.appendingPathComponent("Resources/help")
        for directory in [packagedBin, links, resources] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for name in ["screenpunk", "screenpunk-mcp"] {
            let copied = packagedBin.appendingPathComponent(name)
            try FileManager.default.copyItem(at: originalBinaries.appendingPathComponent(name), to: copied)
            try FileManager.default.createSymbolicLink(at: links.appendingPathComponent(name), withDestinationURL: copied)
        }
        // Unique packaged content proves the child did not use the build tree's
        // generated Bundle.module location or silently substitute fallback text.
        let marker = "packaged-catalog-\(UUID().uuidString)"
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packages/ScreenpunkController/Sources/ScreenpunkController/Resources")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: source.appendingPathComponent("mcp-catalog.json"))) as? [String: Any])
        var tools = try XCTUnwrap(catalog["tools"] as? [[String: Any]])
        let helpIndex = try XCTUnwrap(tools.firstIndex(where: { $0["name"] as? String == "get_help" }))
        tools[helpIndex]["description"] = marker
        catalog["tools"] = tools
        try JSONSerialization.data(withJSONObject: catalog).write(to: resources.appendingPathComponent("mcp-catalog.json"))
        let helpMarker = "packaged-help-\(UUID().uuidString)"
        var help = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: source.appendingPathComponent("help.json"))) as? [String: [String: String]])
        help["onboarding"]?["body"] = helpMarker
        try JSONSerialization.data(withJSONObject: help).write(to: resources.appendingPathComponent("help.json"))
        binaries = links
        defer { binaries = originalBinaries }
        let runtime = root.appendingPathComponent("packaged-agent-runtime")
        let home = root.appendingPathComponent("packaged-agent-home")
        let listed = try run(["agent", "list", "--json"], runtime: runtime)
        XCTAssertEqual(listed.status, 0, listed.stderr)
        XCTAssertEqual((try listed.json()["result"] as? [String: Any])?["count"] as? Int,
            WorkbenchMCPBridge.names.count)
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path])
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in nil })
        defer { host.stop() }
        let tested = try run(["agent", "test", "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(tested.status, 0, tested.stderr)
        XCTAssertEqual((try tested.json()["result"] as? [String: Any])?["status"] as? String, "ready")
        let mcp = try collect(spawn(["--home", home.path],
            executable: "screenpunk-mcp", runtime: runtime, input: """
            {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
            {"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"screenpunk://help/onboarding"}}

            """))
        XCTAssertEqual(mcp.status, 0, mcp.stderr)
        let responses = try mcp.stdout.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(responses.count, 2)
        let response = try XCTUnwrap(responses.first)
        let advertised = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(advertised.first(where: { $0["name"] as? String == "get_help" })?["description"] as? String, marker)
        let contents = try XCTUnwrap((responses.last?["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["text"] as? String, helpMarker)
    }

    func testNamedPortableProfileResolutionIsSelectedWorkspaceOnly() throws {
        let runtime = root.appendingPathComponent("profile-runtime")
        let home = root.appendingPathComponent("profile-home")
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path])
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("profile resolution must not activate native LAN") },
                    deactivate: {})
            })
        defer { host.stop() }
        let visible = root.appendingPathComponent("profile-visible")
        let created = try run(["workspace", "init", visible.path, "--home", home.path,
            "--json"], runtime: runtime)
        XCTAssertEqual(created.status, 0, created.stdout)
        let workspace = try WorkspaceStore(documents: documents,
            machineRootPath: runtime.appendingPathComponent("machine").path)
        let initial = try XCTUnwrap(workspace.current())
        _ = try workspace.updateSettings(["theme": "light", "view": "grid"],
            profiles: ["desk": ["theme": "dark", "sort": "name"]],
            expectedGeneration: initial.settings.generation)
        func config(_ name: String) throws -> [String: Any] {
            let value = try run(["config", "get", "--scope", "workspace", "--profile", name,
                "--home", home.path, "--json"], runtime: runtime)
            XCTAssertEqual(value.status, 0, value.stdout)
            return try XCTUnwrap(value.json()["result"] as? [String: Any])
        }
        let named = try config("desk")
        XCTAssertEqual(named["selectedProfile"] as? String, "desk")
        let effective = try XCTUnwrap(named["effectivePresentation"] as? [String: String])
        XCTAssertEqual(effective, ["theme": "dark", "view": "grid", "sort": "name"])
        XCTAssertEqual(try config("default")["effectivePresentation"] as? [String: String],
            ["theme": "light", "view": "grid"])
        let unknown = try run(["config", "get", "--scope", "workspace", "--profile", "missing",
            "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(unknown.status, 6)
        XCTAssertEqual((try unknown.json()["error"] as? [String: Any])?["code"] as? String,
            "profile_not_found")
        let unsafe = try run(["config", "get", "--scope", "workspace", "--profile", "../desk",
            "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(unsafe.status, 2)
        let beforeWrites = try XCTUnwrap(workspace.current()).settings
        for words in [["set", "theme", "system", String(beforeWrites.generation)],
                      ["unset", "view", String(beforeWrites.generation)]] {
            let refused = try run(["config"] + words + ["--scope", "workspace",
                "--profile", "desk", "--home", home.path, "--json"], runtime: runtime)
            XCTAssertEqual(refused.status, 2, refused.stdout)
            XCTAssertEqual((try refused.json()["error"] as? [String: Any])?["code"] as? String,
                "usage")
            XCTAssertEqual(try workspace.current()?.settings, beforeWrites,
                "Named-profile write refusal must not mutate defaults or the profile map")
        }
        let defaultSet = try run(["config", "set", "theme", "system",
            String(beforeWrites.generation), "--scope", "workspace", "--profile", "default",
            "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(defaultSet.status, 0, defaultSet.stdout)
        let afterSet = try XCTUnwrap(workspace.current()).settings
        XCTAssertEqual(afterSet.presentation["theme"], "system")
        XCTAssertEqual(afterSet.profiles, beforeWrites.profiles)
        let defaultUnset = try run(["config", "unset", "view", String(afterSet.generation),
            "--scope", "workspace", "--profile", "default", "--home", home.path,
            "--json"], runtime: runtime)
        XCTAssertEqual(defaultUnset.status, 0, defaultUnset.stdout)
        let afterUnset = try XCTUnwrap(workspace.current()).settings
        XCTAssertNil(afterUnset.presentation["view"])
        XCTAssertEqual(afterUnset.profiles, beforeWrites.profiles)
        for verb in ["icon-set", "archive"] {
            let refused = try run(["screen", verb, "--profile", "desk", "--home", home.path,
                "--json"], runtime: runtime)
            XCTAssertEqual(refused.status, 2, refused.stdout)
            XCTAssertEqual(try workspace.current()?.settings, afterUnset)
        }
        let client = WorkbenchBrokerClient(environment: broker)
        try client.connect(); defer { client.close() }
        let selected = try client.workspaceStatus()
        _ = try client.initializeWorkspace(path: root.appendingPathComponent("profile-other").path)
        XCTAssertThrowsError(try WorkbenchCLIProfile.resolve("desk", selected: selected,
            client: client)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
    }

    func testAgentTestUsesOrdinaryCredentialAndBindsControllerHome() throws {
        let runtime = root.appendingPathComponent("agent-test-runtime")
        let home = root.appendingPathComponent("agent-test-home")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path])
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("agent test must not activate native LAN") }, deactivate: {})
            })
        defer { host.stop() }
        let ready = try run(["agent", "test", "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(ready.status, 0, ready.stdout)
        XCTAssertEqual((try ready.json()["result"] as? [String: Any])?["status"] as? String, "ready")
        let doctor = try run(["doctor", "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(doctor.status, 0, doctor.stdout)
        let diagnostics = try XCTUnwrap(doctor.json()["result"] as? [String: Any])
        XCTAssertEqual(diagnostics["build"] as? String, "route_available_kit_unverified")
        XCTAssertEqual(diagnostics["identity"] as? String, "not_loaded")
        XCTAssertEqual(diagnostics["identityPersistence"] as? String, "not_assessed")
        XCTAssertEqual(diagnostics["networkTransport"] as? String, "not_attached")
        XCTAssertEqual(diagnostics["networkAuthorization"] as? String, "not_assessed")
        XCTAssertEqual((diagnostics["dependencies"] as? [String: String])?["trustedReleaseCatalog"],
            "not_assessed", "No workspace is selected, so doctor cannot read its kit requirements.")
        XCTAssertEqual((diagnostics["serviceEvidence"] as? [String: Any])?["controllerHomePath"] as? String,
            home.resolvingSymlinksInPath().path)
        let listed = try run(["agent", "list", "--json"], runtime: runtime)
        let expected = Set(((try listed.json()["result"] as? [String: Any])?["tools"] as? [String]) ?? [])
        let mcp = try collect(spawn(["mcp", "serve", "--home", home.path],
            runtime: runtime, input: """
            {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}

            """))
        XCTAssertEqual(mcp.status, 0, mcp.stderr)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mcp.stdout.utf8)) as? [String: Any])
        let actual = Set((((response["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String })
        XCTAssertEqual(actual, expected)
        let wrong = try run(["agent", "test", "--home",
            root.appendingPathComponent("other-home").path, "--json"], runtime: runtime)
        XCTAssertEqual(wrong.status, 5, wrong.stdout)
        XCTAssertEqual((try wrong.json()["error"] as? [String: Any])?["code"] as? String,
            "controller_home_mismatch")
    }

    func testSharedOwnerLockRejectsBrokerBeforeControllerBootstrap() throws {
        let home = root.appendingPathComponent("contended-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let file = home.appendingPathComponent("workbench-owner.lock")
        let fd = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("contended-runtime"))
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path
        ])
        XCTAssertThrowsError(try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in
                XCTFail("controller bootstrap must not reach native composition")
                return nil
            })) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .alreadyRunning)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path),
            ["workbench-owner.lock"])
    }
    func testWriterAppearingDuringLockAcquisitionStillBlocksBootstrap() throws {
        let home = root.appendingPathComponent("late-writer-home")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("late-writer-runtime"))
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path
        ])
        var checks = 0
        XCTAssertThrowsError(try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {
                checks += 1
                if checks == 2 { throw WorkbenchIPCError(.incompatibleOwner) }
            }, nativeFactory: { _ in
                XCTFail("late old writer must block native composition")
                return nil
            })) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .incompatibleOwner)
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path),
            ["workbench-owner.lock"])
    }

    func testKnownLegacyWritersAreDistinguishedFromWorkbenchAdapter() {
        XCTAssertTrue(WorkbenchLegacyOwnerGate.isKnownLegacyWriter(path: "/Applications/Screenpunk.app/Contents/MacOS/Screenpunk"))
        XCTAssertTrue(WorkbenchLegacyOwnerGate.isKnownLegacyWriter(path: "/repo/tools/screenpunk-mcp/.build/screenpunk-mcp"))
        XCTAssertFalse(WorkbenchLegacyOwnerGate.isKnownLegacyWriter(path: "/repo/tools/screenpunk-workbench/.build/screenpunk-mcp"))
    }
    func testServiceHostUsesOwnedProcessInventoryForStartupAndMutation() throws {
        let runtime = root.appendingPathComponent("injected-owner-runtime")
        let home = root.appendingPathComponent("injected-owner-home")
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path
        ])
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        var snapshot = WorkbenchLegacyOwnerGate.Snapshot(guiRunning: false,
            executablePaths: ["/Applications/Screenpunk.app/Contents/MacOS/Screenpunk"])
        let check: () throws -> Void = { try WorkbenchLegacyOwnerGate.assertNoKnownWriter(snapshot: { snapshot }) }
        let inertNative: (ControllerService) -> WorkbenchNativeComposition? = { _ in
            WorkbenchNativeComposition(activateOnStart: false,
                activate: { _ in XCTFail("native LAN must remain inactive") }, deactivate: {})
        }
        XCTAssertThrowsError(try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: check, nativeFactory: inertNative)) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code, .incompatibleOwner)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path),
            "rejected ownership must precede controller bootstrap")
        snapshot = .init(guiRunning: false,
            executablePaths: ["/repo/tools/screenpunk-mcp/.build/screenpunk-mcp"])
        XCTAssertThrowsError(try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: check, nativeFactory: inertNative)) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code, .incompatibleOwner)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))

        snapshot = .init(guiRunning: false, executablePaths: ["/usr/bin/xctest"])
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: check, nativeFactory: inertNative)
        defer { host.stop() }
        let client = WorkbenchBrokerClient(environment: broker)
        try client.connect()
        defer { client.close() }
        XCTAssertEqual(try client.health().status, "ready")
        let rejectedApproval = try run(["approval", "approve", "untrusted-intent", "--home", home.path,
                                        "--json"], runtime: runtime)
        XCTAssertEqual(rejectedApproval.status, 7)
        XCTAssertEqual((try rejectedApproval.json()["error"] as? [String: Any])?["code"] as? String,
            "confirmation_required")
        snapshot = .init(guiRunning: true, executablePaths: [])
        XCTAssertThrowsError(try client.initializeWorkspace(path: root.appendingPathComponent("Documents/Denied").path)) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code, .incompatibleOwner)
        }
        let secondClient = WorkbenchBrokerClient(environment: broker)
        try secondClient.connect()
        defer { secondClient.close() }
        XCTAssertEqual(try secondClient.health().status, "ready")
    }
    func testAuthenticatedCLIPlainWebSnapshotAndFreshMachineOpen() throws {
        let runtime = root.appendingPathComponent("authoring-runtime")
        let home = root.appendingPathComponent("authoring-home")
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path
        ])
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let inertNative: (ControllerService) -> WorkbenchNativeComposition? = { _ in
            WorkbenchNativeComposition(activateOnStart: false,
                activate: { _ in XCTFail("authoring must not activate native LAN") }, deactivate: {})
        }
        var host: WorkbenchServiceHost? = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: inertNative)
        defer { host?.stop() }
        func command(_ words: [String], using activeHome: URL = home, runtime activeRuntime: URL = runtime) throws -> [String: Any] {
            let response = try run(words + ["--home", activeHome.path, "--json"], runtime: activeRuntime)
            XCTAssertEqual(response.status, 0, response.stdout)
            let envelope = try response.json()
            XCTAssertEqual(envelope["ok"] as? Bool, true)
            return try XCTUnwrap(envelope["result"] as? [String: Any])
        }
        let visible = root.appendingPathComponent("visible")
        _ = try command(["workspace", "init", visible.path])
        let created = try command(["project", "create", "Web"])
        let createdProject = try XCTUnwrap(created["project"] as? [String: Any])
        let project = try XCTUnwrap(createdProject["project"] as? [String: Any])
        let id = try XCTUnwrap(project["projectId"] as? String)
        let firstHash = try XCTUnwrap(createdProject["sourceVersion"] as? String)
        let input = root.appendingPathComponent("replacement.html")
        let newHTML = Data("<html><main>CLI</main></html>".utf8)
        try newHTML.write(to: input)
        let edited = try command(["project", "edit", id, firstHash, "web/index.html", input.path])
        let editedProject = try XCTUnwrap(edited["project"] as? [String: Any])
        let secondHash = try XCTUnwrap(editedProject["sourceVersion"] as? String)
        XCTAssertNotEqual(firstHash, secondHash)
        let sourceRead = try command(["project", "source", id, "web/index.html"])
        XCTAssertEqual(sourceRead["text"] as? String, String(decoding: newHTML, as: UTF8.self))
        XCTAssertEqual(sourceRead["sourceVersion"] as? String, secondHash)
        XCTAssertEqual(try XCTUnwrap(command(["project", "versions", id])["count"] as? Int), 2)
        let build = try command(["build", "run", id, secondHash])
        let buildHead = try XCTUnwrap(build["build"] as? [String: Any])
        let revision = try XCTUnwrap(buildHead["revision"] as? String)
        XCTAssertEqual(try XCTUnwrap(command(["screen", "history"])["packages"] as? [[String: Any]]).count, 1)
        let packageConsumer = WorkbenchBrokerClient(environment: broker)
        try packageConsumer.connect()
        let selected = try packageConsumer.workspaceStatus()
        let workspacePackages = try packageConsumer.listWorkspacePackages(in: selected)
        XCTAssertEqual(workspacePackages.count, 1)
        let built = try XCTUnwrap(workspacePackages.first)
        XCTAssertEqual(built.revision, revision)
        XCTAssertEqual(built.storage, "selected-workspace-history")
        XCTAssertTrue(try packageConsumer.listPackages().isEmpty,
            "legacy-controller enumeration must remain separately labeled")
        XCTAssertEqual(try packageConsumer.workspacePackage(dashboardId: built.dashboardId,
            revision: revision, in: selected), built)
        let file = try packageConsumer.workspacePackageFile(dashboardId: built.dashboardId,
            revision: revision, path: "index.html", offset: 0, in: selected)
        XCTAssertEqual(file.bytes, newHTML)
        XCTAssertEqual(file.totalBytes, newHTML.count)
        let manifestChunk = try packageConsumer.workspacePackageFile(dashboardId: built.dashboardId,
            revision: revision, path: "", offset: 0, in: selected)
        XCTAssertEqual(manifestChunk.offset, 0)
        XCTAssertEqual(manifestChunk.totalBytes, manifestChunk.bytes.count)
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestChunk.bytes)
        XCTAssertEqual(manifest.digest, built.digest)
        let largerInput = root.appendingPathComponent("larger.html")
        let largerHTML = Data(("<html><main>" + String(repeating: "L", count: 8_192) +
            "</main></html>").utf8)
        try largerHTML.write(to: largerInput)
        let largerEdit = try command(["project", "edit", id, secondHash,
            "web/index.html", largerInput.path])
        let largerHash = try XCTUnwrap((largerEdit["project"] as? [String: Any])?["sourceVersion"] as? String)
        XCTAssertNotEqual(largerHash, secondHash)
        XCTAssertEqual(try Data(contentsOf: visible.appendingPathComponent("Screens/web/web/index.html")), largerHTML)
        let staleEdit = try run(["project", "edit", id, secondHash, "web/index.html",
            largerInput.path, "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual((try staleEdit.json()["error"] as? [String: Any])?["code"] as? String,
            "workspace_conflict")
        let editorClient = WorkbenchBrokerClient(environment: broker)
        try editorClient.connect()
        let editorBytes = Data("<html><main>Private editor</main></html>".utf8)
        try WorkbenchLocalEditorCLI.run(projectId: id, path: "web/index.html",
            selected: try editorClient.workspaceStatus(), client: editorClient,
            presentation: Presentation(json: false), environment: [:],
            edit: { try editorBytes.write(to: $0, options: .atomic) }, temporaryRoot: root)
        let editorResult = try editorClient.performAuthoring(method: .projectInspect, params: [
            "schemaVersion": 1, "projectId": id])
        XCTAssertNotEqual(editorResult.project?.sourceVersion, largerHash)
        XCTAssertEqual(try Data(contentsOf: visible.appendingPathComponent("Screens/web/web/index.html")),
            editorBytes)
        let priorEditorVersion = try XCTUnwrap(editorResult.project?.sourceVersion)
        let competingBytes = Data("<html>Competing change</html>".utf8)
        let competingInput = root.appendingPathComponent("competing.html")
        try competingBytes.write(to: competingInput)
        var preservedDraft: String?
        XCTAssertThrowsError(try WorkbenchLocalEditorCLI.run(projectId: id,
            path: "web/index.html", selected: try editorClient.workspaceStatus(),
            client: editorClient, presentation: Presentation(json: false),
            environment: [:], edit: { draft in
                preservedDraft = draft.path
                try Data("<html>Unsaved editor choice</html>".utf8).write(to: draft, options: .atomic)
                _ = try command(["project", "edit", id, priorEditorVersion,
                    "web/index.html", competingInput.path])
            }, temporaryRoot: root)) { error in
            XCTAssertEqual((error as? CommandFailure)?.code, "edit_outcome_unknown")
            XCTAssertEqual((error as? CommandFailure)?.details["draftPath"], preservedDraft)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(preservedDraft))),
            Data("<html>Unsaved editor choice</html>".utf8))
        XCTAssertEqual(try Data(contentsOf: visible.appendingPathComponent("Screens/web/web/index.html")),
            competingBytes)
        editorClient.close()
        let react = try command(["project", "create", "React", "react"])
        let reactProject = try XCTUnwrap((react["project"] as? [String: Any])?["project"] as? [String: Any])
        let reactID = try XCTUnwrap(reactProject["projectId"] as? String)
        let reactSource = try command(["project", "source", reactID, "src/main.tsx"])
        XCTAssertTrue((reactSource["text"] as? String)?.contains("@screenpunk/react") == true)
        let backup = root.appendingPathComponent("backup")
        let snapshot = try command(["workspace", "snapshot", backup.path])
        XCTAssertEqual((snapshot["snapshot"] as? [String: Any])?["complete"] as? Bool, true)
        _ = try command(["workspace", "init", root.appendingPathComponent("replacement-workspace").path])
        XCTAssertThrowsError(try packageConsumer.listWorkspacePackages(in: selected)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        packageConsumer.close()
        host?.stop(); host = nil
        let restoredHome = root.appendingPathComponent("restored-home")
        let restoredRuntime = root.appendingPathComponent("restored-runtime")
        let restoredBroker = try WorkbenchBrokerEnvironment(runtimeDirectory: restoredRuntime)
        host = try WorkbenchServiceHost(broker: restoredBroker, home: restoredHome,
            documents: documents, ownerCheck: {}, nativeFactory: inertNative)
        _ = try command(["workspace", "open", backup.path], using: restoredHome, runtime: restoredRuntime)
        let restoredHead = try command(["build", "head", id], using: restoredHome, runtime: restoredRuntime)
        XCTAssertEqual((restoredHead["build"] as? [String: Any])?["revision"] as? String, revision)
        XCTAssertEqual(try command(["service", "lifecycle"], using: restoredHome,
                                   runtime: restoredRuntime)["state"] as? String, "healthy")
        XCTAssertEqual(try command(["service", "drain"], using: restoredHome,
                                   runtime: restoredRuntime)["state"] as? String, "drained")
    }

    func testEditorConfirmedPatchWithClosedStdoutReportsAppliedDisplayFailure() throws {
        let runtime = root.appendingPathComponent("closed-output-runtime")
        let home = root.appendingPathComponent("closed-output-home")
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path
        ])
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("editor must not activate native LAN") }, deactivate: {})
            })
        defer { host.stop() }
        let visible = root.appendingPathComponent("closed-output-workspace")
        let initialized = try run(["workspace", "init", visible.path,
            "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(initialized.status, 0, initialized.stderr)
        let created = try run(["project", "create", "Web", "--home", home.path,
            "--json"], runtime: runtime)
        XCTAssertEqual(created.status, 0, created.stderr)
        let result = try XCTUnwrap(created.json()["result"] as? [String: Any])
        let project = try XCTUnwrap((result["project"] as? [String: Any])?["project"] as? [String: Any])
        let projectId = try XCTUnwrap(project["projectId"] as? String)
        let editor = root.appendingPathComponent("private-editor.sh")
        try Data("#!/bin/sh\nprintf '%s' \"$SCREENPUNK_TEST_CONTENT\" > \"$1\"\n".utf8)
            .write(to: editor)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        for jsonOutput in [false, true] {
            let content = "<html><main>closed stdout \(jsonOutput)</main></html>"
            let errors = root.appendingPathComponent("closed-output-\(jsonOutput).err")
            _ = FileManager.default.createFile(atPath: errors.path, contents: nil)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "exec 1>&-; exec \"$@\"", "sh",
                binaries.appendingPathComponent("screenpunk").path,
                "project", "edit-local", projectId, "web/index.html",
                "--home", home.path, "--runtime-directory", runtime.path]
                + (jsonOutput ? ["--json"] : [])
            child.environment = ["HOME": root.path, "TMPDIR": root.path,
                "PATH": "/usr/bin:/bin", "SCREENPUNK_EDITOR": editor.path,
                "SCREENPUNK_TEST_CONTENT": content,
                "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path]
            child.standardInput = FileHandle.nullDevice
            child.standardError = try FileHandle(forWritingTo: errors)
            try child.run()
            let deadline = Date().addingTimeInterval(5)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL); XCTFail("Editor child exceeded deadline") }
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .exit)
            XCTAssertEqual(child.terminationStatus, 6)
            let diagnostic = try String(contentsOf: errors, encoding: .utf8)
            XCTAssertTrue(diagnostic.contains("edit_applied_display_failed"), diagnostic)
            let saved = visible.appendingPathComponent("Screens/web/web/index.html")
            XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), content)
            let pattern = try NSRegularExpression(pattern: "at (/[^\\n]+/screenpunk-edit-[^ /]+/index\\.html)\\.")
            let range = NSRange(diagnostic.startIndex..<diagnostic.endIndex, in: diagnostic)
            let match = try XCTUnwrap(pattern.firstMatch(in: diagnostic, range: range))
            let draftRange = try XCTUnwrap(Range(match.range(at: 1), in: diagnostic))
            XCTAssertTrue(FileManager.default.fileExists(atPath: String(diagnostic[draftRange])))
        }
    }
    func testDeployCLIPrivateFakeDevicePrepareReviewApplyAndNoResend() throws {
        let runtime = root.appendingPathComponent("exact-runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let home = root.appendingPathComponent("legacy")
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path
        ])
        let workspace = try WorkspaceStore(documents: documents,
            machineRootPath: runtime.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html><main>Exact</main></html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "cli-dashboard", name: "Exact", revision: "cli-source-1",
            entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "source", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let controller = try ControllerService.bootstrap(root: home,
            deviceDirectoryURL: runtime.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        let device = CLIExactDeviceState()
        let owner = PairingIdentityFactory.make(role: .controller)
        let paired = PairedDevice(profile: device.profile, owner: owner, reachable: false)
        try controller.devices.directory.upsert(PairedDeviceRecord(device: paired,
            host: "192.0.2.50", port: 7843, devicePinHex: PeerPin.hex(device.pin),
            pairedAt: Date()))
        let factory = CLIExactLinkFactory(controllerIdentity: owner, state: device)
        let native = WorkbenchNativeComposition(activateOnStart: false,
            activate: { $0.devices.attach(factory) },
            deactivate: { controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: native, machineAuthorityPath: runtime.appendingPathComponent("machine/authority.json").path,
            mutationGate: {})
        let server = WorkbenchBrokerServer(environment: broker, domain: domain)
        try server.start(); defer { server.stop() }
        let proposal = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "weather",
            origin: "https://example.local", transport: .http, authRef: "", lan: true,
            allowInsecureHTTP: false, operations: [.init(name: "read", kind: .http,
                method: .GET, path: "/api/weather", idempotent: true, write: false)])
        let proposedAuth = ConnectionAuthBinding(authRef: "", placement: .none)
        let proposalGrantJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(proposal)) as? [String: Any])
        let proposalAuthJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(proposedAuth)) as? [String: Any])
        var proposalArguments: [String: Any] = ["deviceId": device.profile.deviceId,
            "dashboardId": "cli-dashboard", "revision": "cli-source-1",
            "grant": proposalGrantJSON, "auth": proposalAuthJSON]
        func mcpLine(id: Int, arguments: [String: Any]) throws -> String {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": id,
                "method": "tools/call", "params": ["name": "request_connection_intent",
                                             "arguments": arguments]]
            return String(decoding: try JSONSerialization.data(withJSONObject: request,
                options: [.sortedKeys]), as: UTF8.self)
        }
        let firstMCP = try mcpLine(id: 1, arguments: proposalArguments)
        proposalArguments["role"] = "localReview"
        let rejectedMCP = try mcpLine(id: 2, arguments: proposalArguments)
        let mcpResult = try collect(spawn(["mcp", "serve", "--home", home.path],
            runtime: runtime, input: firstMCP + "\n" + rejectedMCP + "\n"))
        XCTAssertEqual(mcpResult.status, 0, mcpResult.stderr)
        let mcpLines = mcpResult.stdout.split(separator: "\n")
        XCTAssertEqual(mcpLines.count, 2)
        let firstReply = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(mcpLines[0].utf8)) as? [String: Any])
        let firstContent = try XCTUnwrap((firstReply["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let intentBytes = Data(try XCTUnwrap(firstContent.first?["text"] as? String).utf8)
        let proposed = try JSONDecoder().decode(WorkbenchConnectionIntentView.self, from: intentBytes)
        XCTAssertTrue(WorkbenchConnectionIntentAttestation.matchesRequest(proposed,
            deviceId: device.profile.deviceId, dashboardId: "cli-dashboard", revision: "cli-source-1",
            grant: proposal, auth: proposedAuth))
        var changedProposal = proposal
        changedProposal.operations[0].idempotent = false
        XCTAssertFalse(WorkbenchConnectionIntentAttestation.matchesRequest(proposed,
            deviceId: device.profile.deviceId, dashboardId: "cli-dashboard", revision: "cli-source-1",
            grant: changedProposal, auth: proposedAuth))
        let secondReply = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(mcpLines[1].utf8)) as? [String: Any])
        XCTAssertEqual((secondReply["result"] as? [String: Any])?["isError"] as? Bool, true)
        let inventory = WorkbenchBrokerClient(environment: broker)
        try inventory.connect(); defer { inventory.close() }
        let emptySet = try inventory.freshDeviceScreenSet(deviceId: device.profile.deviceId)
        XCTAssertEqual(emptySet.profile.deviceId, device.profile.deviceId)
        XCTAssertEqual(emptySet.authority, "fresh-pinned-owned-screen-set-v1")
        XCTAssertTrue(emptySet.screens.isEmpty)
        func command(_ words: [String]) throws -> [String: Any] {
            let response = try run(words + ["--home", home.path, "--json"], runtime: runtime)
            XCTAssertEqual(response.status, 0, response.stdout)
            let envelope = try response.json()
            XCTAssertEqual(envelope["ok"] as? Bool, true)
            return try XCTUnwrap(envelope["result"] as? [String: Any])
        }
        let initiallyInstalled = try command(["device", "screens", device.profile.deviceId])
        XCTAssertEqual(initiallyInstalled["authority"] as? String, "fresh-pinned-owned-screen-set-v1")
        XCTAssertEqual((initiallyInstalled["screens"] as? [[String: Any]])?.count, 0)
        let preparedResult = try command(["deploy", "prepare", "cli-exact-device",
            "cli-dashboard", "cli-source-1", "portrait"])
        let prepared = try XCTUnwrap(preparedResult["prepared"] as? [String: Any])
        let preparedRevision = try XCTUnwrap(prepared["revision"] as? String)
        XCTAssertNotEqual(preparedRevision, "cli-source-1")
        let planResult = try command(["deploy", "plan", "cli-exact-device",
            "cli-dashboard", "cli-source-1", preparedRevision])
        let review = try XCTUnwrap(planResult["review"] as? [String: Any])
        let plan = try XCTUnwrap(review["plan"] as? [String: Any])
        XCTAssertEqual(plan["deviceProfileHash"] as? String, emptySet.deviceProfileHash)
        XCTAssertEqual(plan["expectedInstalledSetHash"] as? String, emptySet.installedSetHash)
        XCTAssertNil(review["previouslySelectedDashboardId"] as? String)
        let planID = try XCTUnwrap(plan["planId"] as? String)
        XCTAssertEqual((try command(["deploy", "review", planID])["review"] as? [String: Any])?["planHash"] as? String,
            review["planHash"] as? String)
        let denied = try run(["deploy", "apply", planID, "--no-input", "--home", home.path, "--json"],
            runtime: runtime)
        XCTAssertEqual((try denied.json()["error"] as? [String: Any])?["code"] as? String,
            "confirmation_required")
        device.lock.lock(); let sendsBefore = device.sends; device.lock.unlock()
        XCTAssertEqual(sendsBefore, 0)
        let applied = try command(["deploy", "apply", planID, "--approved"])
        let operation = try XCTUnwrap(applied["operation"] as? [String: Any])
        let operationID = try XCTUnwrap(operation["operationId"] as? String)
        XCTAssertEqual(operation["state"] as? String, "active")
        XCTAssertEqual((try command(["deploy", "lookup", planID])["operation"] as? [String: Any])?["operationId"] as? String,
            operationID)
        XCTAssertEqual((try command(["deploy", "status", operationID])["operation"] as? [String: Any])?["state"] as? String,
            "active")
        XCTAssertEqual((try command(["deploy", "apply", planID, "--approved"])["operation"] as? [String: Any])?["operationId"] as? String,
            operationID)
        device.lock.lock(); let sendsAfter = device.sends; device.lock.unlock()
        XCTAssertEqual(sendsAfter, 1)
        XCTAssertEqual(try inventory.freshDeviceScreenSet(deviceId: device.profile.deviceId).screens.count, 1)
        let installed = try command(["device", "screens", device.profile.deviceId])
        XCTAssertEqual((installed["screens"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(installed["selectedDashboardId"] as? String, "cli-dashboard")

        // A person may spend longer than the broker's socket idle timeout
        // reading the review. The CLI reconnects and rechecks the frozen plan
        // before its local-review assertion is admitted.
        let nextPlan = try command(["deploy", "plan", "cli-exact-device",
            "cli-dashboard", "cli-source-1", preparedRevision])
        let nextID = try XCTUnwrap(((nextPlan["review"] as? [String: Any])?["plan"] as? [String: Any])?["planId"] as? String)
        let reviewClient = WorkbenchBrokerClient(environment: broker, credentialScope: .localReview)
        try reviewClient.connect(); defer { reviewClient.close() }
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        let finished = DispatchSemaphore(value: 0)
        var interactive: Swift.Result<Void, Error>?
        let currentSelection = try inventory.workspaceStatus()
        DispatchQueue.global().async {
            interactive = Swift.Result {
                try WorkbenchDeploymentCLI.run(words: ["deploy", "apply", nextID],
                    options: Options(), client: reviewClient, selected: currentSelection,
                    presentation: Presentation(json: true), openTTY: { Darwin.dup(slave) })
            }
            finished.signal()
        }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var rendered = ""
        var pageResponses = 0
        var sawApprovalPrompt = false
        let promptDeadline = Date().addingTimeInterval(10)
        while Date() < promptDeadline, !sawApprovalPrompt {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(master, &chunk, chunk.count)
            if count > 0 { rendered += String(decoding: chunk.prefix(count), as: UTF8.self) }
            let pagePrompts = rendered.components(separatedBy: "Press Enter to view the remaining exact deployment scope").count - 1
            while pageResponses < pagePrompts {
                let enter = Data("\n".utf8)
                _ = enter.withUnsafeBytes { Darwin.write(master, $0.baseAddress, enter.count) }
                pageResponses += 1
            }
            sawApprovalPrompt = rendered.contains("Type APPROVE to install this exact screen set")
            if !sawApprovalPrompt { usleep(10_000) }
        }
        XCTAssertTrue(sawApprovalPrompt, rendered)
        Thread.sleep(forTimeInterval: 11)
        let approval = Data("APPROVE\n".utf8)
        XCTAssertEqual(approval.withUnsafeBytes { Darwin.write(master, $0.baseAddress, approval.count) }, approval.count)
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        XCTAssertNoThrow(try interactive?.get())
        device.lock.lock(); let sendsAfterReview = device.sends; device.lock.unlock()
        XCTAssertEqual(sendsAfterReview, 2)
    }
    func testScreenHistoryCLICompletelyAggregates129VerifiedRevisions() throws {
        let runtime = root.appendingPathComponent("history-runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let home = root.appendingPathComponent("history-legacy")
        let workspace = try WorkspaceStore(documents: CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path
        ]), machineRootPath: runtime.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("history-visible").path)
        let bytes = Data("<html>History</html>".utf8)
        let digest = DeploymentDigest.sha256Hex(bytes)
        let packages = WorkbenchPortablePackages(workspace: workspace)
        for index in 0..<129 {
            var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
                dashboardId: "cli-history", name: "History \(index)", revision: "revision-\(index)",
                entrypoint: "index.html", sdkVersion: "1",
                target: ManifestTarget(profileId: "test", width: 800, height: 480,
                    scale: 1, orientation: "landscape"), connections: [],
                files: [ManifestFile(path: "index.html", bytes: bytes.count, sha256: digest)])
            manifest.digest = try DeploymentDigest.digest(for: manifest)
            _ = try packages.importVerified(.init(manifest: manifest, files: ["index.html": bytes]))
        }
        let controller = try ControllerService.bootstrap(root: home,
            deviceDirectoryURL: runtime.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            native: nil, mutationGate: {})
        let server = WorkbenchBrokerServer(environment: broker, domain: domain)
        try server.start(); defer { server.stop() }
        let response = try run(["screen", "history", "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(response.status, 0, response.stdout)
        let result = try XCTUnwrap(response.json()["result"] as? [String: Any])
        XCTAssertEqual(result["count"] as? Int, 129)
        XCTAssertEqual(result["complete"] as? Bool, true)
        XCTAssertEqual(Set((result["packages"] as? [[String: Any]] ?? []).compactMap {
            $0["revision"] as? String
        }).count, 129)
    }
    func testScreenIconCLIUsesSelectedExactGenerationAndClosedInput() throws {
        let runtime = root.appendingPathComponent("screen-runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path
        ]), machineRootPath: runtime.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("screen-visible").path)
        let source = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Screen", kind: "react", trustedKitVersion: "kit-1")
        let packageBytes = Data("<html>associated</html>".utf8)
        var package = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Associated",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1,
                orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: packageBytes.count,
                sha256: DeploymentDigest.sha256Hex(packageBytes))])
        package.digest = try DeploymentDigest.digest(for: package)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: package, files: ["index.html": packageBytes]))
        let before = try XCTUnwrap(workspace.current())
        let input = root.appendingPathComponent("screen-input.json")
        let fields: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": source.project.dashboardId, "symbol": "star.fill"]
        try JSONSerialization.data(withJSONObject: fields).write(to: input)
        let home = root.appendingPathComponent("screen-legacy")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let controller = try ControllerService.bootstrap(root: home,
            deviceDirectoryURL: runtime.appendingPathComponent("machine/devices.json"),
            rendererFactory: { nil })
        let server = WorkbenchBrokerServer(environment: broker,
            domain: WorkbenchBrokerDomain(controller: controller, workspace: workspace,
                native: nil, mutationGate: {}))
        try server.start(); defer { server.stop() }
        let selectedDoctor = try run(["doctor", "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(selectedDoctor.status, 0, selectedDoctor.stdout)
        let selectedDiagnostics = try XCTUnwrap(selectedDoctor.json()["result"] as? [String: Any])
        XCTAssertEqual((selectedDiagnostics["dependencies"] as? [String: Any])?["trustedReleaseCatalog"]
            as? String, "not_registered")
        XCTAssertEqual(selectedDiagnostics["identity"] as? String, "not_loaded")
        XCTAssertEqual(selectedDiagnostics["networkAuthorization"] as? String, "not_assessed")
        for invalidBytes in [Data(repeating: 65, count: 4_097), Data("{malformed".utf8)] {
            try invalidBytes.write(to: input)
            for verb in WorkbenchScreenMutationCLI.verbs.sorted() {
                let rejected = try run(["screen", verb, "--file", input.path,
                    "--home", home.path, "--json"], runtime: runtime)
                XCTAssertEqual(rejected.status, 2, rejected.stdout)
                XCTAssertEqual(try (rejected.json()["error"] as? [String: Any])?["code"] as? String,
                    "usage")
            }
            XCTAssertEqual(try workspace.current()?.descriptor.generation, before.descriptor.generation)
        }
        try JSONSerialization.data(withJSONObject: fields).write(to: input)
        let command = ["screen", "icon-set", "--file", input.path, "--home", home.path, "--json"]
        let applied = try run(command, runtime: runtime)
        XCTAssertEqual(applied.status, 0, applied.stdout)
        XCTAssertEqual(try (applied.json()["result"] as? [String: Any])?["symbol"] as? String,
            "star.fill")
        XCTAssertEqual(try workspace.current()?.settings.screenIcons[source.project.dashboardId],
            "star.fill")
        let logs = try run(["device", "logs", "device-a", "--home", home.path, "--json"],
            runtime: runtime)
        XCTAssertEqual(logs.status, 0, logs.stdout)
        XCTAssertEqual(try (logs.json()["result"] as? [String: Any])?["scope"] as? String,
            "broker-observed-device-events")
        XCTAssertEqual(try (logs.json()["result"] as? [String: Any])?["complete"] as? Bool,
            false)
        let stale = try run(command, runtime: runtime)
        XCTAssertNotEqual(stale.status, 0)
        XCTAssertEqual(try (stale.json()["error"] as? [String: Any])?["code"] as? String,
            "workspace_conflict")
        var injected = fields; injected["role"] = "owner"
        try JSONSerialization.data(withJSONObject: injected).write(to: input)
        let invalid = try run(command, runtime: runtime)
        XCTAssertEqual(try (invalid.json()["error"] as? [String: Any])?["code"] as? String,
            WorkbenchIPCErrorCode.invalidRequest.rawValue)
        let attachSelection = try XCTUnwrap(workspace.current())
        let attachFields: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": attachSelection.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(attachSelection.selectionGeneration),
            "expectedCatalogGeneration": attachSelection.descriptor.generation,
            "projectId": source.project.projectId,
            "expectedSourceVersion": source.sourceVersion,
            "dashboardId": package.dashboardId,
            "expectedRevision": package.revision,
            "expectedDigest": try XCTUnwrap(package.digest)]
        try JSONSerialization.data(withJSONObject: attachFields).write(to: input)
        let associated = try run(["screen", "react-source-associate", "--file", input.path,
            "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(associated.status, 0, associated.stdout)
        XCTAssertEqual(try workspace.current()?.catalog.projects.first?.dashboardId,
            package.dashboardId)
        let archiveSelection = try XCTUnwrap(workspace.current())
        let archiveFields: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": archiveSelection.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(archiveSelection.selectionGeneration),
            "expectedCatalogGeneration": archiveSelection.descriptor.generation,
            "dashboardId": package.dashboardId,
            "expectedRevision": package.revision,
            "expectedDigest": try XCTUnwrap(package.digest)]
        try JSONSerialization.data(withJSONObject: archiveFields).write(to: input)
        let archived = try run(["screen", "archive", "--file", input.path,
            "--home", home.path, "--json"], runtime: runtime)
        XCTAssertEqual(archived.status, 0, archived.stdout)
        XCTAssertEqual(try workspace.current()?.catalog.archivedDashboardIds, [package.dashboardId])
        let history = try run(["screen", "history", "--home", home.path, "--json"],
            runtime: runtime)
        XCTAssertEqual(history.status, 0, history.stdout)
        XCTAssertEqual(try (history.json()["result"] as? [String: Any])?["count"] as? Int, 1)
    }
    func testPrivateTerminalCredentialInputDisablesEcho() throws {
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        let completed = DispatchSemaphore(value: 0)
        var outcome: Swift.Result<Data, Error>?
        DispatchQueue.global().async(execute: {
            outcome = Swift.Result { try WorkbenchCommand.readSecret(fd: slave, prompt: false) }
            completed.signal()
        })
        var hidden = false
        for _ in 0..<200 {
            var state = termios()
            if tcgetattr(slave, &state) == 0, state.c_lflag & tcflag_t(ECHO) == 0 { hidden = true; break }
            usleep(1000)
        }
        XCTAssertTrue(hidden)
        let canary = Data("credential-canary\n".utf8)
        XCTAssertEqual(canary.withUnsafeBytes { Darwin.write(master, $0.baseAddress, canary.count) }, canary.count)
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try outcome?.get(), Data("credential-canary".utf8))
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var echoed = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(master, &echoed, echoed.count)
        if count > 0 { XCTAssertFalse(String(decoding: echoed.prefix(count), as: UTF8.self).contains("credential-canary")) }
    }
    func testLocalReviewTTYRequiresExactAffirmativeInputAndRendersRedactedScope() throws {
        let review = try localReviewFixture()
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        let completed = DispatchSemaphore(value: 0)
        var result: Swift.Result<Bool, Error>?
        DispatchQueue.global().async {
            result = Swift.Result {
                try WorkbenchLocalApprovalTerminal.confirm(review, noInput: false,
                    openTTY: { Darwin.dup(slave) })
            }
            completed.signal()
        }
        // The scope spans two pages. Enter only advances the review; exact
        // APPROVE after the final page authorizes it.
        for input in ["\n", "APPROVE\n"] {
            let bytes = Array(input.utf8)
            XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, bytes.count) }, bytes.count)
            usleep(20_000)
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try result?.get(), true)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var output = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(master, &output, output.count)
        let rendered = count > 0 ? String(decoding: output.prefix(count), as: UTF8.self) : ""
        XCTAssertTrue(rendered.contains("Controller owner pin"))
        XCTAssertTrue(rendered.contains("Network permission: https://example.local"))
        XCTAssertTrue(rendered.contains("lights"))
        XCTAssertTrue(rendered.contains("view=kitchen"))
        XCTAssertFalse(rendered.contains("secret-query-value"))
        XCTAssertFalse(rendered.contains("\u{001b}"))
        XCTAssertThrowsError(try WorkbenchLocalApprovalTerminal.confirm(review, noInput: true,
            openTTY: { XCTFail("no-input must not open TTY"); return -1 }))
        XCTAssertThrowsError(try WorkbenchLocalApprovalTerminal.confirm(review, noInput: false,
            openTTY: { -1 }))

        var declinedMaster: Int32 = -1, declinedSlave: Int32 = -1
        XCTAssertEqual(openpty(&declinedMaster, &declinedSlave, nil, nil, nil), 0)
        defer { Darwin.close(declinedMaster); Darwin.close(declinedSlave) }
        let declined = DispatchSemaphore(value: 0)
        var declinedResult: Swift.Result<Bool, Error>?
        DispatchQueue.global().async {
            declinedResult = Swift.Result {
                try WorkbenchLocalApprovalTerminal.confirm(review, noInput: false,
                    openTTY: { Darwin.dup(declinedSlave) })
            }
            declined.signal()
        }
        for input in ["\n", "approve\n"] {
            let bytes = Array(input.utf8)
            XCTAssertEqual(bytes.withUnsafeBytes {
                Darwin.write(declinedMaster, $0.baseAddress, bytes.count)
            }, bytes.count)
            usleep(20_000)
        }
        XCTAssertEqual(declined.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try declinedResult?.get(), false)
    }

    func testLocalReviewTTYPaginatesCompleteLongAuthorityAndLANPermission() throws {
        let tail = "AUTHORITATIVE-PATH-TAIL"
        let address = "https://example.local/" + String(repeating: "x", count: 4600) + tail
        let review = try localReviewFixture(address: address, origin: "lan:example.local")
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let completed = DispatchSemaphore(value: 0)
        var result: Swift.Result<Bool, Error>?
        DispatchQueue.global().async {
            result = Swift.Result {
                try WorkbenchLocalApprovalTerminal.confirm(review, noInput: false,
                    openTTY: { Darwin.dup(slave) })
            }
            completed.signal()
        }
        var rendered = ""
        var advanced = 0
        var approved = false
        var finished = false
        let until = Date().addingTimeInterval(5)
        while Date() < until && !finished {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(master, &bytes, bytes.count)
            if count > 0 { rendered += String(decoding: bytes.prefix(count), as: UTF8.self) }
            let prompts = rendered.components(separatedBy: "Press Enter to view the remaining scope").count - 1
            if prompts > advanced {
                let newline = Array("\n".utf8)
                _ = newline.withUnsafeBytes { Darwin.write(master, $0.baseAddress, newline.count) }
                advanced += 1
            } else if rendered.contains("Type APPROVE to authorize") && !approved {
                let yes = Array("APPROVE\n".utf8)
                _ = yes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, yes.count) }
                approved = true
            }
            finished = completed.wait(timeout: .now()) == .success
            usleep(1_000)
        }
        XCTAssertTrue(approved)
        if !finished { finished = completed.wait(timeout: .now() + 1) == .success }
        XCTAssertTrue(finished)
        XCTAssertEqual(try result?.get(), true)
        XCTAssertTrue(rendered.contains("Network permission: lan:example.local"))
        XCTAssertTrue(rendered.contains(tail))
        XCTAssertFalse(rendered.contains("[truncated]"))
        let tailRange = try XCTUnwrap(rendered.range(of: tail))
        let approvalRange = try XCTUnwrap(rendered.range(of: "Type APPROVE to authorize"))
        XCTAssertLessThan(tailRange.lowerBound, approvalRange.lowerBound)
    }

    private func localReviewFixture(address: String = "https://example.local/api/lights?view=kitchen&token=REDACTED",
                                    origin: String = "https://example.local") throws -> WorkbenchConnectionReview {
        let expires = Date().addingTimeInterval(120).timeIntervalSinceReferenceDate
        let json: [String: Any] = [
            "schemaVersion": 1, "reviewHandle": Data(repeating: 7, count: 32).base64EncodedString(),
            "intentId": UUID().uuidString, "declarationHash": String(repeating: "a", count: 64),
            "authorizationContextHash": String(repeating: "b", count: 64),
            "ownerPin": "owner-pin", "ownerEpoch": "owner-epoch", "devicePin": "device-pin",
            "pairingEpoch": "pairing-epoch", "endpoint": "https://example.local:443",
            "credentialGeneration": 1, "grantGeneration": 0,
            "intentExpiresAt": expires, "reviewExpiresAt": expires,
            "summary": [
                "bindingId": UUID().uuidString, "deviceId": "fixture-device", "dashboardId": "dashboard",
                "revision": "rev", "alias": "Kitchen", "origin": origin,
                "transport": "http", "operations": [["name": "lights", "method": "GET",
                    "address": address, "writes": false]],
                "authenticationPlacement": "none", "redirectPolicy": "deny_cross_origin_and_downgrade",
                "maximumResponseBytes": 1024, "timeoutSeconds": 5, "localStatus": "pending",
                "remoteRevocation": "not_requested"
            ]
        ]
        return try JSONDecoder().decode(WorkbenchConnectionReview.self,
            from: JSONSerialization.data(withJSONObject: json))
    }
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        func json() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        }
    }
    private var root: URL!
    private var binaries: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/spb-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: false)
        if let path = ProcessInfo.processInfo.environment["SCREENPUNK_TEST_BIN_DIR"] {
            binaries = URL(fileURLWithPath: path)
        } else {
            var candidate = Bundle(for: Self.self).bundleURL
            for _ in 0..<7 {
                if FileManager.default.isExecutableFile(atPath: candidate.appendingPathComponent("screenpunk").path) {
                    binaries = candidate; break
                }
                candidate.deleteLastPathComponent()
            }
        }
        XCTAssertNotNil(binaries, "swift test must build screenpunk and screenpunk-service alongside tests")
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    private func spawn(_ arguments: [String], executable: String = "screenpunk", runtime: URL? = nil,
                       input: String? = nil) throws -> (Process, URL, URL) {
        let process = Process()
        process.executableURL = binaries.appendingPathComponent(executable)
        process.arguments = arguments
        // Deliberately no inherited GUI/helper/controller/runtime configuration or credentials.
        var env = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
                   "SCREENPUNK_CONTROLLER_HOME": root.appendingPathComponent("legacy").path,
                   "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path,
                   "SCREENPUNK_PREVIEW_HELPER": root.appendingPathComponent("missing-helper").path]
        if let runtime { env["SCREENPUNK_RUNTIME_DIRECTORY"] = runtime.path }
        process.environment = env
        let output = root.appendingPathComponent(UUID().uuidString + ".out")
        let errors = root.appendingPathComponent(UUID().uuidString + ".err")
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errors.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: errors)
        if let input {
            let path = root.appendingPathComponent(UUID().uuidString + ".in")
            try Data(input.utf8).write(to: path)
            process.standardInput = try FileHandle(forReadingFrom: path)
        } else { process.standardInput = FileHandle.nullDevice }
        try process.run()
        return (process, output, errors)
    }
    private func collect(_ running: (Process, URL, URL), timeout: Double = 5) throws -> Result {
        let deadline = Date().addingTimeInterval(timeout)
        while running.0.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if running.0.isRunning { kill(running.0.processIdentifier, SIGKILL); XCTFail("Subprocess exceeded test deadline") }
        running.0.waitUntilExit()
        return try Result(status: running.0.terminationStatus,
                          stdout: String(contentsOf: running.1, encoding: .utf8),
                          stderr: String(contentsOf: running.2, encoding: .utf8))
    }
    private func run(_ arguments: [String], runtime: URL? = nil) throws -> Result { try collect(spawn(arguments, runtime: runtime)) }
    private func skipForObservedOwnerConflict(_ result: Result) throws {
        if result.status == 5,
           (try? result.json()["error"] as? [String: Any])?["code"] as? String == "incompatibleOwner" {
            throw XCTSkip("A live legacy writer holds the production owner boundary; private injected-owner fixtures cover this route.")
        }
    }
    private func waitReady(_ running: (Process, URL, URL)) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && running.0.isRunning {
            if (try String(contentsOf: running.2, encoding: .utf8)).contains("workbench broker ready") { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !running.0.isRunning {
            running.0.waitUntilExit()
            try skipForObservedOwnerConflict(Result(status: running.0.terminationStatus,
                stdout: (try? String(contentsOf: running.1)) ?? "",
                stderr: (try? String(contentsOf: running.2)) ?? ""))
        }
        XCTFail("Service did not become ready: \((try? String(contentsOf: running.2)) ?? "")")
        throw WorkbenchIPCError(.unavailable)
    }

    func testOfflineVersionHelpAndUnavailableCommands() throws {
        for args in [["version", "--json"], ["--version", "--json"], ["help", "--json"],
                     ["service", "run", "--help", "--json"], ["operation", "--help", "--json"],
                     ["install", "--help", "--json"], ["update", "--help", "--json"],
                     ["uninstall", "--help", "--json"], ["mcp", "--help", "--json"]] {
            let result = try run(args)
            XCTAssertEqual(result.status, 0); XCTAssertEqual(result.stderr, "")
            XCTAssertEqual(try result.json()["ok"] as? Bool, true)
        }
        let future = try run(["toolchain", "list", "--json"])
        XCTAssertEqual(future.status, 9)
        XCTAssertEqual(try (future.json()["error"] as? [String: Any])?["code"] as? String, "unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy").path))
    }
    func testConnectionUpdateStagesWithOrdinaryBrokerCredential() {
        XCTAssertEqual(WorkbenchCommand.brokerCredentialScope(for: [
            "connection", "update", "binding-1", "1"]), .ordinary)
        XCTAssertEqual(WorkbenchCommand.brokerCredentialScope(for: [
            "connection", "request", "device-1"]), .ordinary)
        XCTAssertEqual(WorkbenchCommand.brokerCredentialScope(for: [
            "connection", "review", "intent-1"]), .localReview)
        XCTAssertEqual(WorkbenchCommand.brokerCredentialScope(for: [
            "connection", "configure", "device-1"]), .localReview)
    }
    func testExplicitRuntimeAndOptionErrors() throws {
        for args in [["service", "status", "--runtime-directory", "relative", "--json"],
                     ["doctor", "--timeout", "nan", "--json"], ["doctor", "--timeout", "11", "--json"],
                     ["doctor", "--timeout", "--json"], ["doctor", "--runtime-directory", "/private/tmp/../tmp/runtime", "--json"]] {
            let result = try run(args)
            XCTAssertEqual(result.status, 2); XCTAssertEqual(result.stderr, "")
            XCTAssertEqual(try result.json()["ok"] as? Bool, false)
        }
        let unknown = try run(["bogus", "--json"])
        XCTAssertEqual(unknown.status, 2)
    }
    func testUnavailableAndStaleRuntime() throws {
        let runtime = root.appendingPathComponent("runtime")
        let absent = try run(["service", "status", "--json"], runtime: runtime)
        XCTAssertEqual(absent.status, 9); XCTAssertEqual(try absent.json()["ok"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        let doctor = try run(["doctor", "--json"], runtime: runtime)
        XCTAssertEqual(doctor.status, 9)
        let error = try XCTUnwrap(doctor.json()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unavailable")
        let running = try spawn(["service", "run", "--foreground", "--json"], runtime: runtime)
        defer { if running.0.isRunning { kill(running.0.processIdentifier, SIGKILL); running.0.waitUntilExit() } }
        try waitReady(running)
        kill(running.0.processIdentifier, SIGKILL)
        _ = try collect(running)
        let stale = try run(["service", "status", "--json"], runtime: runtime)
        XCTAssertEqual(stale.status, 9); XCTAssertEqual(try stale.json()["ok"] as? Bool, false)
    }
    func testForegroundDoctorSingletonAndCtrlC() throws {
        let runtime = root.appendingPathComponent("space café")
        let running = try spawn(["service", "run", "--foreground", "--json"], runtime: runtime)
        defer { if running.0.isRunning { kill(running.0.processIdentifier, SIGKILL); running.0.waitUntilExit() } }
        try waitReady(running)
        XCTAssertEqual(try String(contentsOf: running.1), "", "Readiness must not contaminate stdout")
        let doctor = try run(["doctor", "--json"], runtime: runtime)
        XCTAssertEqual(doctor.status, 0); XCTAssertEqual(doctor.stderr, "")
        let result = try XCTUnwrap(doctor.json()["result"] as? [String: Any])
        XCTAssertEqual(result["workspaceState"] as? String, "unconfigured")
        XCTAssertEqual(result["build"] as? String, "route_available_kit_unverified")
        XCTAssertEqual(result["screenshots"] as? String, "unavailable")
        XCTAssertEqual(result["devices"] as? String, "read-only")
        XCTAssertEqual(result["identity"] as? String, "not_loaded")
        XCTAssertEqual(result["networkAuthorization"] as? String, "not_assessed")
        XCTAssertEqual((result["dependencies"] as? [String: String])?["trustedReleaseCatalog"], "not_registered")
        XCTAssertEqual((result["serviceEvidence"] as? [String: Any])?["state"] as? String, "healthy")
        let busy = try run(["service", "run", "--foreground", "--json"], runtime: runtime)
        XCTAssertEqual(busy.status, 5)
        let alternate = try run(["service", "run", "--foreground", "--json"], runtime: root.appendingPathComponent("other-runtime"))
        XCTAssertEqual(alternate.status, 5, alternate.stdout)
        let flagOverride = try run(["service", "status", "--runtime-directory", runtime.path, "--json"],
                                   runtime: root.appendingPathComponent("must-not-use-env"))
        XCTAssertEqual(flagOverride.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-use-env").path))
        let status = try run(["service", "status"], runtime: runtime)
        XCTAssertEqual(status.status, 0); XCTAssertTrue(status.stdout.contains("Service: ready"))
        kill(running.0.processIdentifier, SIGINT)
        let stopped = try collect(running)
        XCTAssertEqual(stopped.status, 130); XCTAssertEqual(try stopped.json()["ok"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("broker.sock").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy").path))
    }
    func testForegroundCtrlCCleansOwnedRuntimeWithoutClient() throws {
        let runtime = root.appendingPathComponent("ctrlc")
        let running = try spawn(["service", "run", "--foreground", "--json"], runtime: runtime)
        defer { if running.0.isRunning { kill(running.0.processIdentifier, SIGKILL); running.0.waitUntilExit() } }
        try waitReady(running)
        XCTAssertEqual(try String(contentsOf: running.1), "")
        kill(running.0.processIdentifier, SIGINT)
        let stopped = try collect(running)
        XCTAssertEqual(stopped.status, 130)
        XCTAssertEqual(try (stopped.json()["error"] as? [String: Any])?["code"] as? String, "cancelled")
        for name in ["broker.sock", "broker.token", "broker.locator.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent(name).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("broker.lock").path))
    }
    func testServiceExecutableUsesSameBrokerAndSIGTERM() throws {
        let runtime = root.appendingPathComponent("runtime")
        let running = try spawn(["--foreground", "--json"], executable: "screenpunk-service", runtime: runtime)
        defer { if running.0.isRunning { kill(running.0.processIdentifier, SIGKILL); running.0.waitUntilExit() } }
        try waitReady(running)
        XCTAssertEqual(try run(["service", "status", "--json"], runtime: runtime).status, 0)
        kill(running.0.processIdentifier, SIGTERM)
        let stopped = try collect(running)
        XCTAssertEqual(stopped.status, 0)
        XCTAssertEqual(try (stopped.json()["result"] as? [String: Any])?["status"] as? String, "stopped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("broker.sock").path))
    }
    func testMalformedAndVersionMismatchedResponses() throws {
        for (name, bytes) in [("malformed", Data("{broken".utf8)),
                              ("version", Data(#"{"apiVersion":"2.0","requestId":"authentication","ok":false,"error":{"code":"unsupportedVersion","message":"\u001b[31mPEER_TEXT"}}"#.utf8))] {
            let runtime = root.appendingPathComponent(name)
            let peer = try AdversarialPeer(runtime: runtime, response: bytes)
            defer { withExtendedLifetime(peer) {} }
            let result = try run(["service", "status", "--json"], runtime: runtime)
            XCTAssertEqual(result.status, 8)
            XCTAssertEqual(try result.json()["ok"] as? Bool, false)
            XCTAssertEqual(result.stderr, "")
            XCTAssertFalse(result.stdout.contains("PEER_TEXT"))
        }
    }
    func testShortDeadlineAndClientCtrlCLeavePeerAlive() throws {
        let runtime = root.appendingPathComponent("silent")
        let peer = try AdversarialPeer(runtime: runtime, response: nil, pause: 1)
        defer { withExtendedLifetime(peer) {} }
        let result = try run(["service", "status", "--timeout", "0.1", "--json"], runtime: runtime)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(try result.json()["ok"] as? Bool, false)
        let secondRuntime = root.appendingPathComponent("cancel")
        let secondPeer = try AdversarialPeer(runtime: secondRuntime, response: nil, pause: 1)
        defer { withExtendedLifetime(secondPeer) {} }
        let running = try spawn(["service", "status", "--timeout", "0.5", "--json"], runtime: secondRuntime)
        Thread.sleep(forTimeInterval: 0.1)
        kill(running.0.processIdentifier, SIGINT)
        let cancelled = try collect(running)
        XCTAssertEqual(cancelled.status, 130)
        XCTAssertEqual(try cancelled.json()["ok"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondRuntime.appendingPathComponent("broker.sock").path))
    }
    func testPresentationEscapesControlsAndBidiAndBoundsLabels() {
        XCTAssertEqual(TerminalPresentation.safe("café\n\u{1b}[31m\u{202e}evil"), "café\\u{000A}\\u{001B}[31m\\u{202E}evil")
        XCTAssertTrue(TerminalPresentation.safe(String(repeating: "é", count: 3000)).hasSuffix(" [truncated]"))
    }

    func testStandaloneWorkspaceLifecycleAndReadCommands() throws {
        let runtime = root.appendingPathComponent("runtime")
        let running = try spawn(["service", "run", "--foreground", "--json"], runtime: runtime)
        defer { if running.0.isRunning { kill(running.0.processIdentifier, SIGKILL); running.0.waitUntilExit() } }
        try waitReady(running)
        let setup = try run(["setup", "--no-input", "--json"], runtime: runtime)
        XCTAssertEqual(setup.status, 0, setup.stdout)
        let selected = try XCTUnwrap(setup.json()["result"] as? [String: Any])
        let path = try XCTUnwrap(selected["path"] as? String)
        XCTAssertEqual(path, root.appendingPathComponent("Documents/Screenpunk").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Documents/Screenpunk/workspace.json").path))
        let secondClient = try run(["workspace", "path", "--json"], runtime: runtime)
        XCTAssertEqual(secondClient.status, 0, secondClient.stdout)
        XCTAssertEqual((try secondClient.json()["result"] as? [String: Any])?["path"] as? String, path)
        let projects = try run(["project", "list", "--json"], runtime: runtime)
        XCTAssertEqual(projects.status, 0)
        XCTAssertEqual((try projects.json()["result"] as? [String: Any])?["count"] as? Int, 0)
        let screens = try run(["screen", "list", "--json"], runtime: runtime)
        XCTAssertEqual(screens.status, 0)
        let devices = try run(["device", "list", "--json"], runtime: runtime)
        XCTAssertEqual(devices.status, 0)
        let mismatch = try run(["workspace", "show", "--workspace", root.appendingPathComponent("elsewhere").path, "--json"], runtime: runtime)
        XCTAssertEqual(mismatch.status, 6)
        XCTAssertEqual((try mismatch.json()["error"] as? [String: Any])?["code"] as? String, "workspace_not_selected")
        let refresh = try run(["device", "list", "--refresh", "--json"], runtime: runtime)
        XCTAssertEqual(refresh.status, 8)
        XCTAssertEqual((try refresh.json()["error"] as? [String: Any])?["code"] as? String, "capability_unavailable")
        let unsupported = try run(["build", "missing", "--json"], runtime: runtime)
        XCTAssertEqual(unsupported.status, 8)
        let alternatePath = root.appendingPathComponent("Documents/Second").path
        let initialized = try run(["workspace", "init", alternatePath, "--json"], runtime: runtime)
        XCTAssertEqual(initialized.status, 0, initialized.stdout)
        XCTAssertEqual((try initialized.json()["result"] as? [String: Any])?["path"] as? String, alternatePath)
        let oldAssertion = try run(["project", "list", "--workspace", path, "--json"], runtime: runtime)
        XCTAssertEqual(oldAssertion.status, 6)
        XCTAssertEqual((try oldAssertion.json()["error"] as? [String: Any])?["code"] as? String, "workspace_not_selected")
        let restored = try run(["workspace", "open", path, "--json"], runtime: runtime)
        XCTAssertEqual(restored.status, 0, restored.stdout)
        try FileManager.default.removeItem(at: runtime.appendingPathComponent("machine"))
        let reopened = try run(["workspace", "open", path, "--json"], runtime: runtime)
        XCTAssertEqual(reopened.status, 0, reopened.stdout)
        XCTAssertEqual((try reopened.json()["result"] as? [String: Any])?["path"] as? String, path)
        let stopped = try run(["service", "stop", "--json"], runtime: runtime)
        XCTAssertEqual(stopped.status, 0, stopped.stdout)
        XCTAssertEqual(try collect(running).status, 0)
    }

    func testBackgroundStartRestartStopAndAgentReadBridge() throws {
        let runtime = root.appendingPathComponent("background")
        let started = try run(["service", "start", "--json"], runtime: runtime)
        try skipForObservedOwnerConflict(started)
        XCTAssertEqual(started.status, 0, started.stdout)
        guard started.status == 0 else { return }
        defer { _ = try? run(["service", "stop", "--json"], runtime: runtime) }
        XCTAssertEqual(try run(["service", "status", "--json"], runtime: runtime).status, 0)
        let restarted = try run(["service", "restart", "--json"], runtime: runtime)
        XCTAssertEqual(restarted.status, 0, restarted.stdout)
        guard restarted.status == 0 else { return }
        for client in ["codex", "cursor", "claude", "generic"] {
            let config = try run(["agent", "config", "--client", client, "--json"], runtime: runtime)
            XCTAssertEqual(config.status, 0, config.stdout)
            let result = try XCTUnwrap(config.json()["result"] as? [String: Any])
            XCTAssertEqual(result["client"] as? String, client)
            XCTAssertTrue((result["configuration"] as? String)?.contains("mcp") == true)
        }
        let listed = try run(["agent", "list", "--json"], runtime: runtime)
        XCTAssertEqual(listed.status, 0, listed.stdout)
        let tools = (try listed.json()["result"] as? [String: Any])?["tools"] as? [String]
        XCTAssertEqual(tools, WorkbenchMCPBridge.names)
        let tested = try run(["agent", "test", "--json"], runtime: runtime)
        XCTAssertEqual(tested.status, 0, tested.stdout)
        XCTAssertEqual((try tested.json()["result"] as? [String: Any])?["status"] as? String, "ready")
        let calls = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_workspace","arguments":{}}}
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"workspace.open","arguments":{"path":"/tmp/forbidden"}}}

        """
        let mcp = try collect(spawn(["mcp", "serve"], runtime: runtime, input: calls))
        XCTAssertEqual(mcp.status, 0, mcp.stderr)
        let lines = mcp.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        guard lines.count == 4 else { return }
        let parsed = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertNotNil((parsed[0]["result"] as? [String: Any])?["capabilities"])
        XCTAssertEqual(((parsed[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count,
            WorkbenchMCPBridge.names.count)
        XCTAssertEqual((parsed[2]["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual((parsed[3]["result"] as? [String: Any])?["isError"] as? Bool, true)
        let alias = try collect(spawn([], executable: "screenpunk-mcp", runtime: runtime, input: calls))
        XCTAssertEqual(alias.status, 0, alias.stderr)
        XCTAssertEqual(alias.stdout.split(separator: "\n").count, 4)
        let stopped = try run(["service", "stop", "--json"], runtime: runtime)
        XCTAssertEqual(stopped.status, 0, stopped.stdout)
        let unavailableMCP = try run(["mcp", "serve", "--json"], runtime: runtime)
        XCTAssertNotEqual(unavailableMCP.status, 0)
        XCTAssertEqual(unavailableMCP.stdout, "", "MCP errors must not leak CLI JSON onto protocol stdout")
    }

    func testBrokerHomeBindingPreservesOtherHome() throws {
        let runtime = root.appendingPathComponent("home-binding")
        let first = root.appendingPathComponent("first-home")
        let second = root.appendingPathComponent("second-home")
        let legacy = second.appendingPathComponent("dashboards")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let marker = legacy.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to: marker)
        let started = try run(["service", "start", "--home", first.path, "--json"], runtime: runtime)
        try skipForObservedOwnerConflict(started)
        XCTAssertEqual(started.status, 0, started.stdout)
        guard started.status == 0 else { return }
        defer { _ = try? run(["service", "stop", "--home", first.path, "--json"], runtime: runtime) }
        for command in [["service", "start"], ["service", "status"], ["service", "restart"],
                        ["service", "stop"], ["setup", "--workspace", root.appendingPathComponent("new-workspace").path]] {
            let result = try run(command + ["--home", second.path, "--json"], runtime: runtime)
            XCTAssertEqual(result.status, 5, result.stdout)
            XCTAssertEqual((try result.json()["error"] as? [String: Any])?["code"] as? String, "controller_home_mismatch")
        }
        XCTAssertEqual(try run(["mcp", "serve", "--home", second.path], runtime: runtime).status, 5)
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
        XCTAssertEqual(try run(["service", "status", "--home", first.path, "--json"], runtime: runtime).status, 0)
    }

    func testHealthAndDoctorStayAvailableWhileWorkspaceLockIsHeld() throws {
        let runtime = root.appendingPathComponent("health-lock")
        let path = root.appendingPathComponent("locked-workspace").path
        let initialized = try run(["workspace", "init", path, "--json"], runtime: runtime)
        try skipForObservedOwnerConflict(initialized)
        XCTAssertEqual(initialized.status, 0, initialized.stdout)
        guard initialized.status == 0 else { return }
        defer { _ = try? run(["service", "stop", "--json"], runtime: runtime) }
        let lock = open(runtime.appendingPathComponent("machine/.screenpunk.lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lock, 0)
        guard lock >= 0 else { return }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let status = try run(["service", "status", "--timeout", "0.5", "--json"], runtime: runtime)
        XCTAssertEqual(status.status, 0, status.stdout)
        let doctor = try run(["doctor", "--timeout", "0.5", "--json"], runtime: runtime)
        XCTAssertEqual(doctor.status, 0, doctor.stdout)
        XCTAssertEqual((try doctor.json()["result"] as? [String: Any])?["workspaceCoverage"] as? String, "unavailable")
    }

    func testMCPInvalidRequestWithIdGetsError() throws {
        let runtime = root.appendingPathComponent("mcp-invalid")
        let started = try run(["service", "start", "--json"], runtime: runtime)
        try skipForObservedOwnerConflict(started)
        XCTAssertEqual(started.status, 0, started.stdout)
        guard started.status == 0 else { return }
        defer { _ = try? run(["service", "stop", "--json"], runtime: runtime) }
        let input = """
        {"jsonrpc":"2.0","id":4,"method":123,"params":{}}
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}

        """
        let result = try collect(spawn(["mcp", "serve"], runtime: runtime, input: input))
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        guard lines.count == 1 else { return }
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual(response["id"] as? Int, 4)
    }

    func testTimedOutSelectionCannotCommitAfterServiceStops() throws {
        let runtime = root.appendingPathComponent("selection-drain")
        let first = root.appendingPathComponent("first-workspace").path
        let second = root.appendingPathComponent("second-workspace").path
        let initialized = try run(["workspace", "init", first, "--json"], runtime: runtime)
        try skipForObservedOwnerConflict(initialized)
        XCTAssertEqual(initialized.status, 0, initialized.stdout)
        guard initialized.status == 0 else { return }
        XCTAssertEqual(try run(["workspace", "init", second, "--json"], runtime: runtime).status, 0)
        XCTAssertEqual(try run(["workspace", "open", first, "--json"], runtime: runtime).status, 0)
        let bootstrap = runtime.appendingPathComponent("machine/bootstrap.json")
        let before = try Data(contentsOf: bootstrap)
        let lock = open(runtime.appendingPathComponent("machine/.screenpunk.lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lock, 0)
        guard lock >= 0 else { return }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let pending = try run(["workspace", "open", second, "--timeout", "0.5", "--json"], runtime: runtime)
        XCTAssertNotEqual(pending.status, 0, pending.stdout)
        let stopped = try run(["service", "stop", "--json"], runtime: runtime)
        XCTAssertEqual(stopped.status, 0, stopped.stdout)
        XCTAssertEqual(try Data(contentsOf: bootstrap), before)
        _ = flock(lock, LOCK_UN)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(try Data(contentsOf: bootstrap), before)
    }

    func testSetupBlocksLegacyAuthoritativeDataWithoutMovingIt() throws {
        let projects = root.appendingPathComponent("legacy/authoring/projects/older")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let marker = projects.appendingPathComponent("source.ts")
        try Data("retained".utf8).write(to: marker)
        let runtime = root.appendingPathComponent("runtime")
        let running = try spawn(["service", "run", "--foreground", "--json"], runtime: runtime)
        defer { if running.0.isRunning { kill(running.0.processIdentifier, SIGKILL); running.0.waitUntilExit() } }
        try waitReady(running)
        let setup = try run(["setup", "--no-input", "--json"], runtime: runtime)
        XCTAssertEqual(setup.status, 6)
        XCTAssertEqual((try setup.json()["error"] as? [String: Any])?["code"] as? String, "migration_required")
        XCTAssertEqual(try String(contentsOf: marker), "retained")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Documents/Screenpunk").path))
        XCTAssertEqual(try run(["service", "stop", "--json"], runtime: runtime).status, 0)
        _ = try collect(running)
    }

    func testReviewedMigrationCLIUsesOnePlanAndPreservesLegacySource() throws {
        let runtime = root.appendingPathComponent("migration-runtime")
        let home = root.appendingPathComponent("migration-home")
        let legacy = root.appendingPathComponent("synthetic-legacy")
        let projectId = UUID().uuidString.lowercased()
        let dashboardId = UUID().uuidString.lowercased()
        let project = legacy.appendingPathComponent("authoring/projects/\(projectId)")
        let source = project.appendingPathComponent("source/web")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{\"dashboardId\":\"\(dashboardId)\",\"kitVersion\":\"1.0.0\"}".utf8)
            .write(to: project.appendingPathComponent("project.json"))
        try Data("{\"name\":\"Legacy\"}".utf8)
            .write(to: project.appendingPathComponent("source/screen.json"))
        let original = Data("<html>legacy fixture</html>".utf8)
        try original.write(to: source.appendingPathComponent("index.html"))
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let documents = CLIWorkspaceDocuments(environment: [
            "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path])
        let host = try WorkbenchServiceHost(broker: broker, home: home, documents: documents,
            ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("migration must not activate native LAN") }, deactivate: {})
            })
        defer { host.stop() }
        func command(_ words: [String]) throws -> [String: Any] {
            let response = try run(words + ["--home", home.path, "--json"], runtime: runtime)
            XCTAssertEqual(response.status, 0, response.stdout)
            return try XCTUnwrap(response.json()["result"] as? [String: Any])
        }
        let destination = root.appendingPathComponent("migrated")
        let plan = try XCTUnwrap(command(["migration", "plan", legacy.path,
            destination.path])["migrationPlan"] as? [String: Any])
        let planID = try XCTUnwrap(plan["migrationId"] as? String)
        XCTAssertEqual(plan["applyAvailable"] as? Bool, true)
        let ordinary = WorkbenchBrokerClient(environment: broker)
        try ordinary.connect(); defer { ordinary.close() }
        XCTAssertThrowsError(try ordinary.performAuthoring(method: .migrationApply,
            params: ["schemaVersion": 1, "migrationId": planID])) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code, .methodNotFound)
        }
        XCTAssertEqual(((try command(["migration", "review", planID]))["migrationPlan"] as? [String: Any])?["destinationPath"] as? String,
                       destination.path)
        let denied = try run(["migration", "apply", planID, "--no-input", "--home", home.path, "--json"],
                             runtime: runtime)
        XCTAssertEqual((try denied.json()["error"] as? [String: Any])?["code"] as? String,
                       "confirmation_required")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let applied = try XCTUnwrap(command(["migration", "apply", planID,
            "--approved"])["migrationApplied"] as? [String: Any])
        XCTAssertEqual(applied["path"] as? String, destination.path)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("source/web/index.html")),
                       original)
        let screenFiles = try XCTUnwrap(FileManager.default.enumerator(
            at: destination.appendingPathComponent("Screens"),
            includingPropertiesForKeys: [.isRegularFileKey]))
        var copiedSource = false
        for case let file as URL in screenFiles where file.lastPathComponent == "index.html" {
            copiedSource = try Data(contentsOf: file) == original
        }
        XCTAssertTrue(copiedSource)
        let repeated = try run(["migration", "apply", planID, "--approved", "--home", home.path, "--json"],
                               runtime: runtime)
        XCTAssertNotEqual(repeated.status, 0)
    }

    func testNoninteractiveSetupStartsStandaloneServiceOnDemand() throws {
        let runtime = root.appendingPathComponent("on-demand")
        let setup = try run(["setup", "--no-input", "--json"], runtime: runtime)
        try skipForObservedOwnerConflict(setup)
        XCTAssertEqual(setup.status, 0, setup.stdout)
        guard setup.status == 0 else { return }
        defer { _ = try? run(["service", "stop", "--json"], runtime: runtime) }
        XCTAssertEqual(try run(["workspace", "show", "--json"], runtime: runtime).status, 0)
        XCTAssertEqual(try run(["service", "stop", "--json"], runtime: runtime).status, 0)
    }
}
