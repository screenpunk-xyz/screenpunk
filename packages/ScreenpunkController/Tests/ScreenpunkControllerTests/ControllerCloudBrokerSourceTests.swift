#if os(macOS)
import XCTest
@testable import ScreenpunkController
private struct CloudBrokerDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}
final class ControllerCloudBrokerSourceTests: XCTestCase {
    func testFullSnapshotRestoreUsesBrokerCASAndKeepsIdentityAndToolchain() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/sp-cloud-broker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at:machine,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let workspace = try WorkspaceStore(documents:CloudBrokerDocuments(root:root),machineRootPath:machine.path)
        _ = try workspace.create(at:root.appendingPathComponent("visible").path)
        let authoring = WorkbenchContainedAuthoring(workspace:workspace)
        let original = try authoring.create(name:"Cloud",kind:"web",trustedKitVersion:"kit-1")
        let privateBytes = Data("test-only-local-credential".utf8)
        _ = try authoring.patch(original.project.projectId,expectedSourceVersion:original.sourceVersion,changes:[
            .init(path:"credentials.json",bytes:privateBytes),.init(path:"build/temporary.js",bytes:Data("local build".utf8)),
            .init(path:"cache/entry.txt",bytes:Data("local cache".utf8))])
        let controller = try ControllerService.bootstrap(root:root.appendingPathComponent("legacy"),deviceDirectoryURL:machine.appendingPathComponent("devices.json"),rendererFactory:{nil})
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory:root.appendingPathComponent("runtime"))
        let domain = WorkbenchBrokerDomain(controller:controller,workspace:workspace,mutationGate:{})
        let server = WorkbenchBrokerServer(environment:environment,domain:domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment:environment)
        try client.connect(); defer { client.close() }
        let capabilities = try client.capabilities()
        XCTAssertFalse(capabilities.supportedMethods.contains("project.syncSource"), "Preserve the pinned legacy public API catalogue")
        XCTAssertEqual(WorkbenchAuthoringRecoveryMethod.advertisedCases.map(\.rawValue),WorkbenchAuthoringRecoveryMethod.allCases.filter {$0 != .projectSyncSource}.map(\.rawValue))
        let adapter = try ControllerCloudBrokerSource(client:client,scratchRoot:root.appendingPathComponent("cloud-scratch"))
        let before = try await adapter.read(projectId:original.project.projectId)
        XCTAssertNil(before.files["credentials.json"]); XCTAssertNil(before.files["build/temporary.js"]); XCTAssertNil(before.files["cache/entry.txt"])
        let descriptor = try XCTUnwrap(before.files["screenpunk.project.json"])
        let shape = try XCTUnwrap(JSONSerialization.jsonObject(with:descriptor) as? [String:Any])
        XCTAssertNil(shape["projectId"]); XCTAssertNotNil(shape["kitVersion"])
        var changed = before.files
        for index in 0..<100 { changed["assets/file-\(index).txt"] = Data("asset \(index)".utf8) }
        changed["web/index.html"] = Data("<html>cloud restore</html>".utf8)
        let incoming = ControllerCloudSourceSnapshot(revision:"remote",files:changed)
        try await adapter.replace(projectId:original.project.projectId,expectedRevision:before.revision,snapshot:incoming)
        let after = try await adapter.read(projectId:original.project.projectId)
        XCTAssertEqual(after.files,incoming.files)
        let current = try authoring.get(original.project.projectId)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:current.path).appendingPathComponent("credentials.json")),privateBytes)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:current.path).appendingPathComponent("build/temporary.js")),Data("local build".utf8))
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:current.path).appendingPathComponent("cache/entry.txt")),Data("local cache".utf8))
        XCTAssertEqual(current.project.projectId,original.project.projectId)
        XCTAssertEqual(current.project.dashboardId,original.project.dashboardId)
        do { try await adapter.replace(projectId:original.project.projectId,expectedRevision:before.revision,snapshot:before); XCTFail("stale CAS accepted") } catch { XCTAssertEqual(error as? ControllerCloudError,.conflict) }
        let staged = root.appendingPathComponent("staged-malicious")
        try FileManager.default.createDirectory(at:staged,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let target = root.appendingPathComponent("outside-snapshot.json")
        try JSONEncoder().encode(incoming).write(to:target)
        try FileManager.default.createSymbolicLink(at:staged.appendingPathComponent("snapshot.json"),withDestinationURL:target)
        let selected = try client.workspaceStatus()
        XCTAssertThrowsError(try client.performAuthoring(method:.projectSyncSource,params:["schemaVersion":1,"projectId":original.project.projectId,"expectedSourceVersion":after.revision,"path":staged.path,"expectedWorkspaceId":try XCTUnwrap(selected.workspaceId),"expectedSelectionGeneration":try XCTUnwrap(selected.selectionGeneration)]))
        try client.connect()
        let safe = try await adapter.read(projectId:original.project.projectId); XCTAssertEqual(safe.files,incoming.files)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("cloud-scratch").path),[])
    }
}
#endif
