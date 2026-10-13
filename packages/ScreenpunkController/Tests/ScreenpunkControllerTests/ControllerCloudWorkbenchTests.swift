import XCTest
import Foundation
import ScreenpunkCore
import CryptoKit
@testable import ScreenpunkController
#if os(macOS)
private final class CloudWorkbenchHTTPStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private struct CloudWorkbenchTestTokens: ControllerCloudTokenStore {
    func load() -> ControllerCloudTokens? { .init(accessToken: "fixture-credential", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3600)) }
    func save(_ tokens: ControllerCloudTokens?) {}
}
private struct CloudCreationScheduleDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root }
}
final class ControllerCloudWorkbenchTests: XCTestCase {
    let workspace = "05f93b4e-7b95-40fa-bb3d-e1b2f59a6356"
    let project = "fb1890dd-093e-4c1a-9b25-e8376e1992c9"
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("ControllerHTTP/" + name + ".json"))
    }
    func session() throws -> ControllerCloudSession {
        let config = try ControllerCloudConfiguration(baseURL: URL(string:"https://cloud.test")!, authorizationURL:URL(string:"https://cloud.test/issuer/auth")!,tokenURL:URL(string:"https://cloud.test/issuer/token")!,clientID:"screenpunk-cli",redirectURI:"http://127.0.0.1:43871/callback")
        let url = URLSessionConfiguration.ephemeral; url.protocolClasses = [CloudWorkbenchHTTPStub.self]
        return ControllerCloudSession(configuration:config,tokenStore:CloudWorkbenchTestTokens(),session:URLSession(configuration:url))
    }
    override func tearDown() { CloudWorkbenchHTTPStub.handler = nil; super.tearDown() }

    func testBrokerOnlyCreationIsAutomaticallyLinkedAndUploadedOnceAcrossControllerHooks() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-cloud-create-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = root.appendingPathComponent("machine")
        let store = try WorkspaceStore(documents: CloudCreationScheduleDocuments(root: root), machineRootPath: machine.path)
        _ = try store.create(at: root.appendingPathComponent("workspace").path)
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"), deviceDirectoryURL: machine.appendingPathComponent("devices.json"), rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let server = WorkbenchBrokerServer(environment: environment, domain: WorkbenchBrokerDomain(controller: controller, workspace: store, mutationGate: {}))
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment); try client.connect(); defer { client.close() }
        let config = try ControllerCloudConfiguration(baseURL: URL(string: "https://cloud.test")!, authorizationURL: URL(string: "https://cloud.test/issuer/auth")!, tokenURL: URL(string: "https://cloud.test/issuer/token")!, clientID: "screenpunk-cli", redirectURI: "http://127.0.0.1:43871/callback")
        let cloud = try ControllerCloudWorkbench(configuration: config, client: client, machineRoot: machine, session: session())
        let remoteID = UUID().uuidString.lowercased(), versionID = UUID().uuidString.lowercased()
        var createCount = 0, uploadCount = 0, files: [String: Data] = [:]
        func body(_ request: URLRequest) throws -> [String: Any] {
            if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
            guard let stream = request.httpBodyStream else { return [:] }
            stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func response(_ object: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: object)) }
        func projectResponse() throws -> (Int, Data) { try response(["id": remoteID, "accountId": "account", "name": "MCP created", "sourceKind": "html", "kitVersion": "builtin-web-1", "headVersionId": files.isEmpty ? NSNull() : versionID as Any]) }
        func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        CloudWorkbenchHTTPStub.handler = { request in
            let path = request.url!.path
            if path == "/controller/v1/session" { return try response(["userId": "account", "clientId": "screenpunk-cli"]) }
            if path == "/controller/v1/workspaces" { return try response(["items": [["id": self.workspace, "name": "Workspace", "membershipId": "membership", "role": "owner"]], "nextCursor": NSNull()]) }
            if path.hasSuffix("/connections") { return try response(["id": try body(request)["controllerId"]!]) }
            if path.hasSuffix("/binding") { return try response(["id": UUID().uuidString.lowercased()]) }
            if path.hasSuffix("/projects") && request.httpMethod == "POST" {
                createCount += 1; let requestBody = try body(request)
                XCTAssertEqual(requestBody["kitVersion"] as? String, "builtin-web-1")
                return try projectResponse()
            }
            if path.hasSuffix("/projects/" + remoteID) { return try projectResponse() }
            if path.hasSuffix("/source/sync") {
                uploadCount += 1
                for file in try body(request)["files"] as! [[String: Any]] { files[file["path"] as! String] = Data(base64Encoded: file["data"] as! String)! }
                return try response(["id": versionID])
            }
            if path.hasSuffix("/manifest") { return try response(["files": files.keys.sorted().map { ["path": $0, "sha256": digest(files[$0]!), "size": files[$0]!.count, "mediaType": "application/octet-stream"] }, "nextCursor": NSNull()]) }
            if path.hasSuffix("/source/read") { let member = try body(request)["path"] as! String; let bytes = files[member]!; return try response(["versionId": versionID, "path": member, "sha256": digest(bytes), "size": bytes.count, "encoding": "base64", "data": bytes.base64EncodedString()]) }
            throw ControllerCloudError.invalidResponse
        }
        try await cloud.selectWorkspace(workspace)
        let selected = try client.workspaceStatus()
        // No UI/CLI post-hook: this is the official MCP broker authoring request.
        let created = try XCTUnwrap(client.performAuthoring(method: .projectCreate, params: ["schemaVersion": 1, "name": "MCP created", "kind": "web", "expectedWorkspaceId": selected.workspaceId!, "expectedSelectionGeneration": selected.selectionGeneration!]).project)
        try await cloud.automaticSync()
        let status = try await cloud.status()
        XCTAssertEqual(status.bindings.first?.localProjectId, created.project.projectId)
        XCTAssertEqual(status.bindings.first?.cloudProjectId, remoteID)
        XCTAssertEqual(status.bindings.first?.status, .synced)
        XCTAssertNotNil(files["web/index.html"])
        _ = try await cloud.linkCreatedProjectIfConnected(localProjectId: created.project.projectId, name: created.project.name, kind: "web")
        try await cloud.automaticSync()
        XCTAssertEqual(createCount, 1); XCTAssertEqual(uploadCount, 1)
    }
    func testActualCloudRouteResponsesDecodeAndReviewedInventoryRoundTrips() throws {
        struct Page<T:Decodable>: Decodable { let items:[T]; let nextCursor:String? }
        let decoder = JSONDecoder()
        let workspaces = try decoder.decode(Page<ControllerCloudWorkspace>.self, from:fixture("get-controller-v1-workspaces"))
        XCTAssertEqual(workspaces.items.first?.id, workspace)
        let projects = try decoder.decode(Page<ControllerCloudProject>.self, from:fixture("get-controller-v1-workspaces-id-projects"))
        XCTAssertEqual(projects.items.first?.headVersionId, nil)
        XCTAssertEqual(try decoder.decode(ControllerCloudProject.self,from:fixture("post-controller-v1-workspaces-id-projects")).sourceKind,"html")
        let devices = try decoder.decode(Page<ControllerCloudInstallation>.self, from:fixture("get-controller-v1-workspaces-id-installations"))
        XCTAssertEqual(devices.items.first?.locationId, nil)
        let publications = try decoder.decode(Page<ControllerCloudPublication>.self, from:fixture("get-controller-v1-workspaces-id-publications"))
        XCTAssertFalse(publications.items.isEmpty)
        let bytes = try fixture("post-controller-v1-workspaces-id-deployments-review")
        let review = try decoder.decode(ControllerCloudDeploymentReview.self, from:bytes); try review.validate()
        XCTAssertTrue(review.removeEntryIds.isEmpty)
        let before = try decoder.decode(ControllerCloudJSON.self, from:bytes)
        let after = try decoder.decode(ControllerCloudJSON.self, from:JSONEncoder().encode(review))
        XCTAssertEqual(before,after,"Apply must preserve the exact generation and resulting inventory reviewed by the server")
        for name in ["get-controller-v1-session","post-controller-v1-workspaces-id-deployments-apply","get-controller-v1-workspaces-id-installations-id-status","post-controller-v1-workspaces-id-projects-id-packages-import","post-controller-v1-workspaces-id-connections","post-controller-v1-workspaces-id-projects-id-binding","delete-binding"] {
            guard case .object = try decoder.decode(ControllerCloudJSON.self,from:fixture(name)) else { return XCTFail(name) }
        }
    }
    func testActualApprovedArchiveResponsePreservesReviewedIdentityAndRejectsTampering() throws {
        let response = try fixture("approved-archive")
        let operation = "a6465760-9c17-4255-991a-50d383b8f98a"
        let installation = "92bd8f13-f072-49d8-b83b-2414a27c6c27"
        let package = "472e786c-6af4-4ef6-af95-72a205690e5a"
        let hash = "2fda05e113e9bc1c1ab4b3e63014088b998ea7b6c25045a9336373d9b6156a67"
        func qualify(_ data: Data) throws -> Data {
            try JSONDecoder().decode(ControllerCloudApprovedArchive.self, from: data)
                .validatedBytes(operationId: operation, installationId: installation,
                    packageId: package, sha256: hash, byteCount: 701)
        }
        let bytes = try qualify(response)
        XCTAssertEqual(bytes.count, 701)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let changes: [(String, Any)] = [("operationId", UUID().uuidString.lowercased()),
            ("installationId", UUID().uuidString.lowercased()), ("packageId", UUID().uuidString.lowercased()),
            ("archiveSha256", String(repeating: "0", count: 64)), ("archiveBytes", 700), ("dataBase64", "invalid!")]
        for (key, value) in changes {
            var altered = original; altered[key] = value
            XCTAssertThrowsError(try qualify(JSONSerialization.data(withJSONObject: altered)), key)
        }
        var changed = bytes; changed[changed.startIndex] ^= 1
        var altered = original; altered["dataBase64"] = changed.base64EncodedString()
        XCTAssertThrowsError(try qualify(JSONSerialization.data(withJSONObject: altered)), "Same-size substituted bytes must fail SHA validation")
        altered = original; altered["dataBase64"] = bytes.dropLast().base64EncodedString()
        XCTAssertThrowsError(try qualify(JSONSerialization.data(withJSONObject: altered)), "Truncated archive must fail byte-count validation")
    }
    func testAutomaticNewProjectLinkNeverRetargetsExistingOrDeletedBinding() throws {
        let existing = ControllerCloudProjectBinding(accountId: "account", workspaceId: "workspace",
            localProjectId: "local", cloudProjectId: "cloud", status: .synced)
        XCTAssertNoThrow(try existing.requireAutomaticCreationScope(accountId: "account", workspaceId: "workspace"))
        XCTAssertThrowsError(try existing.requireAutomaticCreationScope(accountId: "other-account", workspaceId: "workspace"))
        XCTAssertThrowsError(try existing.requireAutomaticCreationScope(accountId: "account", workspaceId: "other-workspace"))
        XCTAssertThrowsError(try existing.requireAutomaticCreationScope(accountId: "account", workspaceId: nil))
        var deleted = existing; deleted.status = .deleted
        XCTAssertNoThrow(try deleted.requireAutomaticCreationScope(accountId: "account", workspaceId: "workspace"))
        XCTAssertEqual(deleted.cloudProjectId, existing.cloudProjectId)
        XCTAssertEqual(deleted.status, .deleted, "Creation hooks must preserve cloud deletion instead of recreating a project")
    }
    func testLiveEmptyProjectIsNotDeletedAndFirstUploadUsesNullCAS() async throws {
        let source = try fixture("get-controller-v1-workspaces-id-projects-id")
        CloudWorkbenchHTTPStub.handler = { request in XCTAssertEqual(request.url?.path,"/controller/v1/workspaces/\(self.workspace)/projects/\(self.project)"); return (200,source) }
        let remote = ControllerCloudHTTPProjects(session:try session())
        let empty = try await remote.read(workspaceId:workspace,projectId:project)
        XCTAssertEqual(empty?.revision,""); XCTAssertEqual(empty?.files,[:])
        let upload = try fixture("post-controller-v1-workspaces-id-projects-id-source-sync")
        CloudWorkbenchHTTPStub.handler = { request in
            XCTAssertEqual(request.httpMethod,"POST")
            let data = request.httpBody ?? request.httpBodyStream.map { stream in stream.open(); defer {stream.close()}; var bytes = [UInt8](repeating:0,count:8192); let count=stream.read(&bytes,maxLength:bytes.count); return Data(bytes.prefix(max(0,count))) } ?? Data()
            let body = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            XCTAssertTrue(body["baseVersionId"] is NSNull)
            XCTAssertEqual(body["idempotencyKey"] as? String,"reviewed-upload")
            return (200,upload)
        }
        let result = try await remote.write(workspaceId:workspace,projectId:project,baseRevision:nil,files:["index.html":Data("hello".utf8)],idempotencyKey:"reviewed-upload")
        XCTAssertEqual(result.revision,"55074fbf-5060-443c-a72f-6f5cc59eed1b")
        CloudWorkbenchHTTPStub.handler = {_ in (404,Data("{}".utf8))}
        let deleted = try await remote.read(workspaceId:workspace,projectId:project); XCTAssertNil(deleted)
    }
    func testMetadataDiscoveryAcceptsRegisteredClientAndRejectsOtherHost() async throws {
        let url = URLSessionConfiguration.ephemeral; url.protocolClasses = [CloudWorkbenchHTTPStub.self]
        let session = URLSession(configuration:url)
        func metadata(_ tokenHost:String) throws -> Data { try JSONSerialization.data(withJSONObject:["issuer":"https://cloud.test/issuer","authorization_endpoint":"https://cloud.test/issuer/auth","token_endpoint":"https://\(tokenHost)/issuer/token","revocation_endpoint":"https://cloud.test/issuer/revoke","code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none"]]) }
        CloudWorkbenchHTTPStub.handler = {request in XCTAssertEqual(request.url?.path,"/.well-known/oauth-authorization-server/issuer");return (200,try metadata("cloud.test"))}
        let config = try await ControllerCloudConfiguration.deployment(clientID:"screenpunk-mac",environment:[:],bundle:["ScreenpunkCloudAPIOrigin":"https://cloud.test"],session:session)
        XCTAssertEqual(config.clientID,"screenpunk-mac"); XCTAssertNotNil(config.revocationURL)
        CloudWorkbenchHTTPStub.handler = {_ in (200,try metadata("untrusted.test"))}
        do { _ = try await ControllerCloudConfiguration.deployment(environment:["SCREENPUNK_CLOUD_BASE_URL":"https://cloud.test"],session:session); XCTFail("Unexpected issuer host accepted") }
        catch { XCTAssertEqual(error as? ControllerCloudError,.invalidConfiguration) }
    }
    func testNativeZIPContainsVerifiedAssetsAndPersistedManifest() throws {
        let content = Data("hello".utf8)
        var manifest = DashboardManifest(schemaVersion:1,dashboardId:"11111111-1111-4111-8111-111111111111",name:"Météo 東京",revision:"22222222-2222-4222-8222-222222222222",entrypoint:"index.html",sdkVersion:"1",target:.init(profileId:"test",width:800,height:480,scale:1,orientation:"landscape"),connections:[],files:[.init(path:"index.html",bytes:content.count,sha256:DeploymentDigest.sha256Hex(content))])
        manifest.digest = try DeploymentDigest.digest(for:manifest)
        let archive = try ControllerCloudNativeArchive.encode(manifest:manifest,files:["index.html":content])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-cloud-zip-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false); defer {try? FileManager.default.removeItem(at:root)}
        let file = root.appendingPathComponent("package.zip"); try archive.write(to:file)
        let process = Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");process.arguments=["-p",file.path,"index.html"]
        let pipe=Pipe();process.standardOutput=pipe;try process.run();let bytes=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0);XCTAssertEqual(bytes,content)
        if let output=ProcessInfo.processInfo.environment["SCREENPUNK_TEST_NATIVE_ARCHIVE_OUT"] {try archive.write(to:URL(fileURLWithPath:output))}
        XCTAssertThrowsError(try ControllerCloudNativeArchive.encode(manifest:manifest,files:["index.html":Data("modified".utf8)]))
    }
}
#endif
