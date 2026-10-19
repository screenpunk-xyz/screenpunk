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
        var remoteID = UUID().uuidString.lowercased()
        let versionID = UUID().uuidString.lowercased()
        var createCount = 0, uploadCount = 0, files: [String: Data] = [:]
        let otherWorkspace = UUID().uuidString.lowercased()
        var account = "account"
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
            if path.hasSuffix("/realtime/session") { return try Self.realtimeResponse(generation: "4451ae01-dc36-41e0-b58c-213264639c7d") }
            if path.hasSuffix("/changes") { return try response(["schemaVersion": 1, "items": [], "nextCursor": "1", "highWaterCursor": "1", "hasMore": false, "resetRequired": false]) }
            if path == "/controller/v1/session" { return try response(["userId": account, "clientId": "screenpunk-cli"]) }
            if path == "/controller/v1/workspaces" { return try response(["items": [self.workspace, otherWorkspace].map { ["id": $0, "name": "Workspace", "membershipId": "membership", "role": "owner"] }, "nextCursor": NSNull()]) }
            if path.hasSuffix("/connections") { return try response(["id": try body(request)["controllerId"]!]) }
            if path.hasSuffix("/binding") { return try response(["id": UUID().uuidString.lowercased()]) }
            if path.hasSuffix("/projects") && request.httpMethod == "POST" {
                createCount += 1; let requestBody = try body(request)
                remoteID = try XCTUnwrap(requestBody["projectId"] as? String)
                XCTAssertEqual(requestBody["kitVersion"] as? String, "builtin-web-1")
                return try projectResponse()
            }
            if path.hasSuffix("/projects") && request.httpMethod == "GET" {
                if path.contains(otherWorkspace) { return try response(["items": [], "nextCursor": NSNull()]) }
                let value = try JSONSerialization.jsonObject(with: projectResponse().1)
                return try response(["items": createCount == 0 ? [] : [value], "nextCursor": NSNull()])
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
        let before = try await cloud.status()
        XCTAssertFalse(before.screenSyncEnabled)
        try await cloud.automaticSync()
        XCTAssertEqual(createCount, 0)
        try await cloud.setScreenSyncEnabled(true)
        // No UI/CLI post-hook: this is the official MCP broker authoring request.
        let created = try XCTUnwrap(client.performAuthoring(method: .projectCreate, params: ["schemaVersion": 1, "name": "MCP created", "kind": "web", "expectedWorkspaceId": selected.workspaceId!, "expectedSelectionGeneration": selected.selectionGeneration!]).project)
        let queued = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: config.baseURL, machineRoot: machine))
        let completed = try await cloud.processScreenSyncRequest(queued)
        XCTAssertTrue(completed.admitted); XCTAssertTrue(completed.completed)
        let status = try await cloud.status()
        XCTAssertEqual(status.bindings.first?.localProjectId, created.project.projectId)
        XCTAssertEqual(status.bindings.first?.cloudProjectId, remoteID)
        XCTAssertEqual(status.bindings.first?.status, .synced)
        XCTAssertNotNil(files["web/index.html"])
        let progress = try await ControllerCloudWorkbench.localScreenSyncStatus(baseURL: config.baseURL, client: client, machineRoot: machine)
        XCTAssertEqual(progress.screenSyncScreens[created.project.dashboardId]?.state, "synced")
        XCTAssertNotNil(progress.screenSyncScreens[created.project.dashboardId]?.lastSuccessfulSyncAt)
        _ = try await cloud.linkCreatedProjectIfConnected(localProjectId: created.project.projectId, name: created.project.name, kind: "web")
        try await cloud.automaticSync()
        XCTAssertEqual(createCount, 1); XCTAssertEqual(uploadCount, 1)
        let sourceFile = URL(fileURLWithPath: selected.path!).appendingPathComponent(created.project.location.path!).appendingPathComponent("web/index.html")
        try Data("<!doctype html><html><body>Unsent local edit</body></html>".utf8).write(to: sourceFile)
        let editedProgress = try await ControllerCloudWorkbench.screenSyncProgress(baseURL: config.baseURL, client: client, machineRoot: machine)
        XCTAssertEqual(editedProgress[created.project.dashboardId]?.state, "pending")
        XCTAssertEqual(editedProgress[created.project.dashboardId]?.lastSuccessfulSyncAt, progress.screenSyncScreens[created.project.dashboardId]?.lastSuccessfulSyncAt)
        XCTAssertEqual(uploadCount, 1, "local-only progress must not upload the edit")
        // Recreate the facade with saved consent after an edit made while the service was absent.
        // The service's one startup appOpened event must include local work even with an empty feed.
        try ControllerCloudWorkbench.acknowledgeScreenSyncRequest(baseURL: config.baseURL, machineRoot: machine, requestId: queued.requestId)
        try cloud.requestScreenSync(.appOpened)
        let restarted = try ControllerCloudWorkbench(configuration: config, client: client, machineRoot: machine, session: session())
        let startup = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: config.baseURL, machineRoot: machine))
        XCTAssertTrue(startup.requiresFullCheck)
        let startupOutcome = try await restarted.processScreenSyncRequest(startup)
        XCTAssertTrue(startupOutcome.completed)
        XCTAssertEqual(uploadCount, 2); XCTAssertEqual(createCount, 1)
        XCTAssertEqual(files["web/index.html"], try Data(contentsOf: sourceFile))
        let restartProgress = try await restarted.screenSyncProgress()
        XCTAssertEqual(restartProgress[created.project.dashboardId]?.state, "synced")
        try await cloud.selectWorkspace(otherWorkspace)
        let switched = try await cloud.status()
        XCTAssertFalse(switched.screenSyncEnabled, "workspace selection is not transferred consent")
        try await cloud.setScreenSyncEnabled(true)
        try await cloud.automaticSync()
        XCTAssertEqual(createCount, 1, "an established Screen binding must not retarget across workspaces")
        account = "different-account"
        let otherAccount = try await cloud.status()
        XCTAssertFalse(otherAccount.screenSyncEnabled)
        try await cloud.automaticSync()
        XCTAssertEqual(createCount, 1); XCTAssertEqual(uploadCount, 2); XCTAssertEqual(try client.listProjects().first?.projectId, created.project.projectId)
        try await cloud.setScreenSyncEnabled(false)
    }
    private static func realtimeResponse(generation: String) throws -> (Int, Data) {
        let subscriber = "65f30700-1b9e-4d8f-a7f0-17d32169e087"
        return (200, try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "transport": "firebase-rtdb",
            "firebase": ["projectId": "controller-test", "databaseURL": "https://controller-test-default-rtdb.firebaseio.com", "apiKey": "synthetic", "appId": "synthetic", "messagingSenderId": "synthetic"],
            "customToken": "synthetic-controller-token", "firebaseUID": "spctl:\(subscriber):\(generation)",
            "subscriberId": subscriber, "generationId": generation, "wakePath": "v1/controllers/\(subscriber)/wake", "cursor": "9001",
            "authorityExpiresAtMs": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)]))
    }
    func testFirstEventEstablishesSubscriberBeforeFeedAndReusesGeneration() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let base = CloudWorkbenchHTTPStub.handler!, baseURL = URL(string: "https://cloud.test")!, machine = root.appendingPathComponent("machine")
        var registered = false, sessionCount = 0, feedCount = 0
        var registeredController: String?, sessionController: String?
        var generation = UUID().uuidString.lowercased()
        CloudWorkbenchHTTPStub.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/connections") {
                registeredController = try Self.requestObject(request)["controllerId"] as? String
                registered = true; return try base(request)
            }
            if path.hasSuffix("/realtime/session") {
                XCTAssertTrue(registered)
                sessionCount += 1
                if sessionCount > 1 { generation = UUID().uuidString.lowercased() }
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertTrue(try Self.requestObject(request).isEmpty)
                sessionController = path.split(separator: "/").dropLast(2).last.map(String.init)
                XCTAssertEqual(sessionController, registeredController)
                return try Self.realtimeResponse(generation: generation)
            }
            if path.hasSuffix("/changes") {
                feedCount += 1
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after" }?.value, feedCount == 1 ? "0" : "1", "session hint cursor must never be accepted as the feed checkpoint")
                // Actual backend requires the subscriber created only by the session POST.
                guard sessionCount > 0 else { return (403, Data("{\"code\":\"controller_realtime_unavailable\"}".utf8)) }
                XCTAssertEqual(path.split(separator: "/").dropLast().last.map(String.init), sessionController)
                return (200, Data("{\"schemaVersion\":1,\"items\":[],\"nextCursor\":\"1\",\"highWaterCursor\":\"1\",\"hasMore\":false,\"resetRequired\":false}".utf8))
            }
            if path.hasSuffix("/projects") { return (200, Data("{\"items\":[],\"nextCursor\":null}".utf8)) }
            return try base(request)
        }
        try await cloud.setScreenSyncEnabled(true)
        let first = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
        let outcome = try await cloud.processScreenSyncRequest(first)
        XCTAssertTrue(outcome.admitted); XCTAssertTrue(outcome.completed)
        XCTAssertEqual(sessionCount, 1); XCTAssertEqual(feedCount, 1)
        let prepared = try await cloud.prepareScreenSyncSession(first)
        let firstGeneration = prepared.generationId
        XCTAssertEqual(firstGeneration, generation)
        try ControllerCloudWorkbench.acknowledgeScreenSyncRequest(baseURL: baseURL, machineRoot: machine, requestId: first.requestId)
        try cloud.requestScreenSync(.reconnected)
        let next = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
        let caughtUp = try await cloud.processScreenSyncRequest(next)
        XCTAssertTrue(caughtUp.completed)
        XCTAssertEqual(sessionCount, 1, "ordinary catch-up must reuse the active generation")
        XCTAssertEqual(feedCount, 2)
        let reused = try await cloud.prepareScreenSyncSession(next)
        XCTAssertEqual(reused.generationId, firstGeneration)
        let renewal = try await cloud.prepareScreenSyncSession(next, renew: true)
        let renewed = try await cloud.processScreenSyncRequest(next)
        XCTAssertTrue(renewed.completed); XCTAssertEqual(sessionCount, 2); XCTAssertEqual(feedCount, 3)
        XCTAssertNotEqual(renewal.generationId, firstGeneration)
        XCTAssertEqual(renewal.generationId, generation)
        let namespace = SHA256.hash(data: Data(baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: machine.appendingPathComponent("cloud-controller/" + namespace + "/screen-sync-cursor-screenpunk-cli.json"))) as? [String: Any]
        XCTAssertEqual(checkpoint?["cursor"] as? String, "1")
    }
    func testDisableDuringRealtimeBootstrapCannotCacheOrUseOldConsent() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let base = CloudWorkbenchHTTPStub.handler!, baseURL = URL(string: "https://cloud.test")!, machine = root.appendingPathComponent("machine")
        let entered = expectation(description: "held subscriber bootstrap"), release = DispatchSemaphore(value: 0)
        var sessions = 0, feeds = 0
        CloudWorkbenchHTTPStub.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/realtime/session") {
                sessions += 1
                if sessions == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
                return try Self.realtimeResponse(generation: UUID().uuidString.lowercased())
            }
            if path.hasSuffix("/changes") {
                feeds += 1
                return (200, Data("{\"schemaVersion\":1,\"items\":[],\"nextCursor\":\"1\",\"highWaterCursor\":\"1\",\"hasMore\":false,\"resetRequired\":false}".utf8))
            }
            if path.hasSuffix("/projects") { return (200, Data("{\"items\":[],\"nextCursor\":null}".utf8)) }
            return try base(request)
        }
        try await cloud.setScreenSyncEnabled(true)
        let original = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
        let task = Task { try await cloud.processScreenSyncRequest(original) }
        await fulfillment(of: [entered], timeout: 2)
        try await ControllerCloudWorkbench.disableScreenSync(baseURL: baseURL, client: client, machineRoot: machine)
        release.signal()
        do { _ = try await task.value; XCTFail("revoked bootstrap accepted") } catch is CancellationError { }
        XCTAssertEqual(feeds, 0)
        XCTAssertNil(try ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
        try await cloud.setScreenSyncEnabled(true)
        let replacement = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
        XCTAssertNotEqual(original.epoch, replacement.epoch)
        let resumed = try await cloud.processScreenSyncRequest(replacement)
        XCTAssertTrue(resumed.completed); XCTAssertEqual(sessions, 2); XCTAssertEqual(feeds, 1)
    }
    func testEventFeedFailureKeepsCursorAndOfflineProgressRemainsReadableDuringTransfer() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        let baseURL = URL(string: "https://cloud.test")!, machine = root.appendingPathComponent("machine")
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let created = try XCTUnwrap(client.performAuthoring(method: .projectCreate, params: ["schemaVersion": 1, "name": "Quota test", "kind": "web"]).project)
        let base = CloudWorkbenchHTTPStub.handler!, entered = expectation(description: "held creation")
        let release = DispatchSemaphore(value: 0)
        var creates = 0, failFeed = true
        CloudWorkbenchHTTPStub.handler = { request in
            if request.url!.path.hasSuffix("/changes") {
                if failFeed { return (503, Data("{}".utf8)) }
                return (200, try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "items": [], "nextCursor": "9", "highWaterCursor": "9", "hasMore": false, "resetRequired": false]))
            }
            if request.url!.path.hasSuffix("/projects") && request.httpMethod == "GET" {
                return (200, Data("{\"items\":[],\"nextCursor\":null}".utf8))
            }
            if request.url!.path.hasSuffix("/projects") && request.httpMethod == "POST" {
                creates += 1; entered.fulfill(); _ = release.wait(timeout: .now() + 10)
                return (409, Data("{\"code\":\"resource_limit\",\"message\":\"untrusted private details\"}".utf8))
            }
            return try base(request)
        }
        try await cloud.setScreenSyncEnabled(true)
        let original = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
        do { _ = try await cloud.processScreenSyncRequest(original); XCTFail("503 must fail admission") } catch { }
        let namespace = SHA256.hash(data: Data(baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let cloudRoot = machine.appendingPathComponent("cloud-controller/" + namespace)
        let initial = try Data(contentsOf: cloudRoot.appendingPathComponent("automation-status.json"))
        XCTAssertTrue(String(decoding: initial, as: UTF8.self).contains("needs_attention"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudRoot.appendingPathComponent("screen-sync-cursor-screenpunk-cli.json").path))
        failFeed = false
        try cloud.requestScreenSync(.appOpened)
        let retry = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
        let transfer = Task { try await cloud.processScreenSyncRequest(retry) }
        await fulfillment(of: [entered], timeout: 5)
        let before = try Data(contentsOf: cloudRoot.appendingPathComponent("screen-sync-request.json"))
        let progress = try await ControllerCloudWorkbench.localScreenSyncStatus(baseURL: baseURL, client: client, machineRoot: machine)
        XCTAssertEqual(progress.screenSyncScreens[created.project.dashboardId]?.state, "syncing")
        XCTAssertEqual(try Data(contentsOf: cloudRoot.appendingPathComponent("screen-sync-request.json")), before, "pure read cannot mutate queued work")
        release.signal()
        let outcome = try await transfer.value
        XCTAssertTrue(outcome.admitted); XCTAssertFalse(outcome.completed)
        let failed = try await ControllerCloudWorkbench.screenSyncProgress(baseURL: baseURL, client: client, machineRoot: machine)
        XCTAssertEqual(failed[created.project.dashboardId]?.state, "error")
        XCTAssertEqual(failed[created.project.dashboardId]?.message, ControllerCloudSyncProgressStore.quotaMessage)
        XCTAssertNil(failed[created.project.dashboardId]?.lastSuccessfulSyncAt)
        XCTAssertEqual(creates, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudRoot.appendingPathComponent("screen-sync-cursor-screenpunk-cli.json").path))
        XCTAssertEqual(try ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine)?.requestId, retry.requestId)
        try await ControllerCloudWorkbench.disableScreenSync(baseURL: baseURL, client: client, machineRoot: machine)
        XCTAssertNil(try ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
    }
    func testSelectionAndLegacyCreationContextAreNotConsent() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let status = try await cloud.status()
        XCTAssertFalse(status.screenSyncEnabled); XCTAssertEqual(status.automaticSyncState, "off")
        let namespace = SHA256.hash(data: Data("https://cloud.test".utf8)).map { String(format: "%02x", $0) }.joined()
        let cloudRoot = root.appendingPathComponent("machine/cloud-controller/" + namespace)
        let selected = try client.workspaceStatus()
        // A previously retained account/workspace and old broker context are not an opt-in.
        let legacy: [String: Any] = ["clientId": "screenpunk-cli", "accountId": "account", "workspaceId": workspace, "localWorkspaceId": selected.workspaceId!]
        try JSONSerialization.data(withJSONObject: legacy).write(to: cloudRoot.appendingPathComponent("creation-context-screenpunk-cli.json"))
        let created = try XCTUnwrap(client.performAuthoring(method: .projectCreate, params: ["schemaVersion": 1, "name": "Local only", "kind": "web"]).project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudRoot.appendingPathComponent("projects/\(selected.workspaceId!)/new/\(created.project.projectId).json").path))
        var requests = 0
        CloudWorkbenchHTTPStub.handler = { _ in requests += 1; throw ControllerCloudError.invalidResponse }
        try await cloud.automaticSync()
        XCTAssertEqual(requests, 0)
        try await cloud.setScreenSyncEnabled(false)
    }

    func testCloudDiscoveryUsesNewIdentitiesAndRecoversAfterBindingFailureWithoutNameMatching() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let base = CloudWorkbenchHTTPStub.handler!
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
        let head = UUID().uuidString.lowercased()
        let descriptor: [String: Any] = ["schemaVersion": 1, "projectId": UUID().uuidString, "dashboardId": UUID().uuidString,
            "name": "Same name", "kind": "web", "kitVersion": "builtin-web-1", "entry": "web/index.html", "screenConfig": "screen.json"]
        var normalized = descriptor; normalized.removeValue(forKey: "projectId"); normalized.removeValue(forKey: "dashboardId")
        let files = ["screenpunk.project.json": try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]),
            "screen.json": Data("{}".utf8), "web/index.html": Data("<!doctype html><html><body>Cloud</body></html>".utf8)]
        var failedBinding = false, sourceReads = 0, creates = 0, deleted = Set<String>()
        var feedKind = "remove", feedCursor = "1"
        func object(_ id: String) -> [String: Any] { ["id": id, "accountId": "account", "name": "Same name", "sourceKind": "html", "kitVersion": "builtin-web-1", "headVersionId": head] }
        func response(_ value: Any, status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value)) }
        CloudWorkbenchHTTPStub.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/changes") { return try response(["schemaVersion": 1, "items": [["projectId": ids[0], "cursor": feedCursor, "kind": feedKind,
                "headVersionId": feedKind == "remove" ? NSNull() : head as Any, "packagesChanged": false]], "nextCursor": feedCursor, "highWaterCursor": feedCursor, "hasMore": false, "resetRequired": false]) }
            if path.hasSuffix("/projects") {
                if request.httpMethod == "POST" { creates += 1; throw ControllerCloudError.invalidResponse }
                return try response(["items": ids.filter { !deleted.contains($0) }.map(object), "nextCursor": NSNull()])
            }
            if let id = ids.first(where: { path.hasSuffix("/projects/" + $0) }) { return try response(object(id), status: deleted.contains(id) ? 404 : 200) }
            if path.hasSuffix("/binding") {
                if !failedBinding { failedBinding = true; return try response([:], status: 503) }
                return try response(["id": UUID().uuidString.lowercased()])
            }
            if path.hasSuffix("/manifest") {
                return try response(["files": files.keys.sorted().map { ["path": $0, "sha256": DeploymentDigest.sha256Hex(files[$0]!), "size": files[$0]!.count, "mediaType": "application/octet-stream"] }, "nextCursor": NSNull()])
            }
            if path.hasSuffix("/source/read") {
                sourceReads += 1
                let body = try Self.requestObject(request), member = body["path"] as! String, bytes = files[member]!
                return try response(["versionId": head, "path": member, "sha256": DeploymentDigest.sha256Hex(bytes), "size": bytes.count, "encoding": "base64", "data": bytes.base64EncodedString()])
            }
            return try base(request)
        }
        try await cloud.setScreenSyncEnabled(true)
        try await cloud.automaticSync()
        try await cloud.automaticSync()
        let imported = try client.listProjects()
        XCTAssertEqual(imported.count, 2); XCTAssertEqual(Set(imported.map(\.projectId)).count, 2)
        XCTAssertEqual(Set(imported.map(\.dashboardId)).count, 2)
        XCTAssertTrue(imported.allSatisfy { !ids.contains($0.projectId) && $0.name == "Same name" })
        let status = try await cloud.status()
        XCTAssertEqual(Set(status.bindings.map(\.cloudProjectId)), Set(ids))
        XCTAssertTrue(status.bindings.allSatisfy { $0.status == .synced }, "statuses: \(status.bindings.map { $0.status.rawValue })")
        let localProgress = try await ControllerCloudWorkbench.screenSyncProgress(baseURL: URL(string: "https://cloud.test")!, client: client, machineRoot: root.appendingPathComponent("machine"))
        XCTAssertTrue(imported.allSatisfy { localProgress[$0.dashboardId]?.state == "synced" && localProgress[$0.dashboardId]?.lastSuccessfulSyncAt != nil })
        let before = sourceReads
        try await cloud.automaticSync()
        XCTAssertEqual(sourceReads, before, "unchanged metadata must not download source again")
        XCTAssertEqual(creates, 0, "a Cloud restore must not arm upload-as-new")
        let baseURL = URL(string: "https://cloud.test")!, machine = root.appendingPathComponent("machine")
        if let old = try ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine) {
            try ControllerCloudWorkbench.acknowledgeScreenSyncRequest(baseURL: baseURL, machineRoot: machine, requestId: old.requestId)
        }
        try cloud.requestScreenSync(.remoteInvalidation)
        var event = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
        let removed = try await cloud.processScreenSyncRequest(event)
        XCTAssertTrue(removed.completed); XCTAssertEqual(sourceReads, before, "remove hints cannot perform ordinary source sync")
        var removedStatus = try await cloud.status()
        XCTAssertEqual(removedStatus.bindings.first { $0.cloudProjectId == ids[0] }?.status, .unavailable)
        XCTAssertEqual(try client.listProjects().map(\.projectId), imported.map(\.projectId))
        try ControllerCloudWorkbench.acknowledgeScreenSyncRequest(baseURL: baseURL, machineRoot: machine, requestId: event.requestId)
        feedKind = "upsert"; feedCursor = "2"
        try cloud.requestScreenSync(.remoteInvalidation)
        event = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: baseURL, machineRoot: machine))
        let restored = try await cloud.processScreenSyncRequest(event)
        XCTAssertTrue(restored.completed)
        removedStatus = try await cloud.status()
        XCTAssertEqual(removedStatus.bindings.first { $0.cloudProjectId == ids[0] }?.status, .synced)
        XCTAssertEqual(try client.listProjects().map(\.projectId), imported.map(\.projectId), "fresh readmission preserves the established local identity")
        XCTAssertEqual(sourceReads, before, "an unchanged re-admitted head needs no source download")

        let archived = imported[0], latest = try client.workspaceStatus()
        let inspected = try XCTUnwrap(client.performAuthoring(method: .projectInspect, params: ["schemaVersion": 1, "projectId": archived.projectId]).project)
        _ = try client.archiveScreen(params: ["schemaVersion": 1, "expectedWorkspaceId": latest.workspaceId!,
            "expectedSelectionGeneration": latest.selectionGeneration!, "expectedCatalogGeneration": latest.generation!,
            "dashboardId": archived.dashboardId, "projectId": archived.projectId, "expectedSourceVersion": inspected.sourceVersion])
        try await cloud.automaticSync()
        XCTAssertEqual(try client.listProjects().count, 1, "archived source must not reappear")
        let archivedStatus = try await cloud.status()
        let remaining = try XCTUnwrap(archivedStatus.bindings.first { $0.localProjectId != archived.projectId })
        deleted.insert(remaining.cloudProjectId)
        try await cloud.automaticSync()
        let afterDelete = try await cloud.status()
        XCTAssertEqual(afterDelete.bindings.first { $0.cloudProjectId == remaining.cloudProjectId }?.status, .deleted)
        XCTAssertEqual(try client.listProjects().count, 1, "Cloud deletion keeps the local copy")
        XCTAssertEqual(creates, 0)
        try await cloud.setScreenSyncEnabled(false)
    }

    func testPackageOnlyDiscoveryIsNewVisibleLocalScreenAndArchiveDoesNotResurrect() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let base = CloudWorkbenchHTTPStub.handler!
        let remote = UUID().uuidString.lowercased(), packageID = UUID().uuidString.lowercased()
        let content = Data("<!doctype html><html><body>Package</body></html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString.lowercased(), name: "Package only",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480, scale: 1, orientation: "landscape"), connections: [],
            files: [.init(path: "index.html", bytes: content.count, sha256: DeploymentDigest.sha256Hex(content))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let original = manifest
        let archive = try ControllerCloudNativeArchive.encode(manifest: original, files: ["index.html": content])
        var fileRequests = 0, writes = 0
        func response(_ value: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        let descriptor: [String: Any] = ["packageId": packageID, "projectId": remote, "sourceVersionId": NSNull(),
            "packageDigest": original.digest!, "manifestSha256": DeploymentDigest.sha256Hex(try JSONEncoder().encode(original)),
            "archiveSha256": DeploymentDigest.sha256Hex(archive), "archiveBytes": archive.count,
            "manifest": try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))]
        CloudWorkbenchHTTPStub.handler = { request in
            let path = request.url!.path
            if request.httpMethod != "GET" && !path.hasSuffix("/connections") { writes += 1; throw ControllerCloudError.invalidResponse }
            if path.hasSuffix("/projects") { return try response(["items": [["id": remote, "accountId": "account", "name": "Package only", "sourceKind": "imported", "headVersionId": NSNull()]], "nextCursor": NSNull()]) }
            if path.hasSuffix("/packages") { return try response(["items": [descriptor], "nextCursor": NSNull()]) }
            if path.hasSuffix("/file") {
                fileRequests += 1
                return try response(["projectId": remote, "packageId": packageID, "packageDigest": original.digest!,
                    "path": "index.html", "sha256": original.files[0].sha256, "size": content.count,
                    "offset": 0, "dataBase64": content.base64EncodedString(), "nextOffset": NSNull()])
            }
            return try base(request)
        }
        try await cloud.setScreenSyncEnabled(true)
        try await cloud.automaticSync()
        let selected = try client.workspaceStatus(), imported = try client.listWorkspacePackages(in: selected)
        XCTAssertEqual(imported.count, 1)
        let item = try XCTUnwrap(imported.first)
        XCTAssertNotEqual(item.dashboardId, original.dashboardId); XCTAssertNotEqual(item.revision, original.revision)
        XCTAssertEqual(item.name, original.name)
        XCTAssertTrue(try client.listProjects().isEmpty, "package restore must not fabricate source/builds")
        let localProgress = try await ControllerCloudWorkbench.screenSyncProgress(baseURL: URL(string: "https://cloud.test")!, client: client, machineRoot: root.appendingPathComponent("machine"))
        XCTAssertEqual(localProgress[item.dashboardId]?.state, "synced")
        XCTAssertNotNil(localProgress[item.dashboardId]?.lastSuccessfulSyncAt)
        let previous = fileRequests
        try await cloud.automaticSync()
        XCTAssertEqual(fileRequests, previous)
        let latest = try client.workspaceStatus()
        _ = try client.archiveScreen(params: ["schemaVersion": 1, "expectedWorkspaceId": latest.workspaceId!,
            "expectedSelectionGeneration": latest.selectionGeneration!, "expectedCatalogGeneration": latest.generation!,
            "dashboardId": item.dashboardId, "expectedRevision": item.revision, "expectedDigest": item.digest])
        try await cloud.automaticSync()
        XCTAssertTrue(try client.listWorkspacePackages(in: client.workspaceStatus()).isEmpty)
        XCTAssertEqual(fileRequests, previous); XCTAssertEqual(writes, 0, "no publish/build/delete or echo upload")
        try await cloud.setScreenSyncEnabled(false)
    }

    func testDisableDuringCreateStopsNextAutomaticRequestAndRetainsStableCreateIdentity() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        _ = try client.performAuthoring(method: .projectCreate, params: ["schemaVersion": 1, "name": "Local", "kind": "web"])
        let base = CloudWorkbenchHTTPStub.handler!, entered = expectation(description: "Cloud creation request")
        let release = DispatchSemaphore(value: 0)
        var requestsAfterCreate = 0, requestedID: String?
        CloudWorkbenchHTTPStub.handler = { request in
            if request.url!.path.hasSuffix("/projects") && request.httpMethod == "POST" {
                let body = try Self.requestObject(request); requestedID = body["projectId"] as? String
                entered.fulfill(); _ = release.wait(timeout: .now() + 10)
                return (200, try JSONSerialization.data(withJSONObject: ["id": requestedID!, "accountId": "account", "name": "Local", "sourceKind": "html", "headVersionId": NSNull()]))
            }
            if requestedID != nil { requestsAfterCreate += 1 }
            return try base(request)
        }
        try await cloud.setScreenSyncEnabled(true)
        let cycle = Task { try await cloud.automaticSync() }
        await fulfillment(of: [entered], timeout: 5)
        try await cloud.setScreenSyncEnabled(false)
        release.signal()
        _ = try? await cycle.value
        // Join the in-flight cycle via the same lock without scheduling more transfers.
        let status = try await cloud.status()
        XCTAssertFalse(status.screenSyncEnabled)
        XCTAssertNotNil(requestedID)
        // status itself uses identity/workspace metadata; no automatic binding/source request follows Off.
        XCTAssertEqual(requestsAfterCreate, 2)
        try await cloud.automaticSync()
        XCTAssertEqual(requestsAfterCreate, 2)
    }

    func testAmbiguousPackageCreateAndImportReconcileStableIdentityWithoutPublishing() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let selected = try client.workspaceStatus(), content = Data("<!doctype html><html><body>Local package</body></html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString.lowercased(), name: "Local package",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 800, height: 480, scale: 1, orientation: "landscape"), connections: [],
            files: [.init(path: "index.html", bytes: content.count, sha256: DeploymentDigest.sha256Hex(content))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let began = try client.beginPackageImport(manifest: manifest, expectedDigest: manifest.digest!, expectedWorkspaceId: selected.workspaceId!, expectedSelectionGeneration: selected.selectionGeneration!)
        _ = try client.sendPackageImportChunk(uploadId: began.uploadId!, fileIndex: 0, offset: 0, bytes: content, expectedWorkspaceId: selected.workspaceId!, expectedSelectionGeneration: selected.selectionGeneration!)
        _ = try client.commitPackageImport(uploadId: began.uploadId!, expectedDigest: manifest.digest!, expectedWorkspaceId: selected.workspaceId!, expectedSelectionGeneration: selected.selectionGeneration!)
        let base = CloudWorkbenchHTTPStub.handler!, original = manifest
        let archive = try ControllerCloudNativeArchive.encode(manifest: original, files: ["index.html": content])
        var createdID: String?, createRequests: [String] = [], importCount = 0, uploaded = false
        let packageID = UUID().uuidString.lowercased()
        func response(_ value: Any, status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value)) }
        CloudWorkbenchHTTPStub.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/projects") {
                if request.httpMethod == "POST" {
                    let body = try Self.requestObject(request), id = body["projectId"] as! String
                    createRequests.append(id); createdID = id
                    if createRequests.count == 1 { return try response([:], status: 503) }
                    return try response(["id": id])
                }
                return try response(["items": createdID.map { [["id": $0, "accountId": "account", "name": "Local package", "sourceKind": "imported", "headVersionId": NSNull()]] } ?? [], "nextCursor": NSNull()])
            }
            if path.hasSuffix("/packages/import") {
                importCount += 1; let body = try Self.requestObject(request)
                XCTAssertTrue(body["sourceVersionId"] is NSNull)
                XCTAssertEqual(Data(base64Encoded: body["data"] as! String), archive)
                uploaded = true
                return try response([:], status: 503) // server committed, response is ambiguous
            }
            if path.hasSuffix("/packages") {
                let item: [String: Any] = ["packageId": packageID, "projectId": createdID!, "sourceVersionId": NSNull(),
                    "packageDigest": original.digest!, "manifestSha256": DeploymentDigest.sha256Hex(try JSONEncoder().encode(original)),
                    "archiveSha256": DeploymentDigest.sha256Hex(archive), "archiveBytes": archive.count,
                    "manifest": try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))]
                return try response(["items": uploaded ? [item] : [], "nextCursor": NSNull()])
            }
            XCTAssertFalse(path.contains("/publications") || path.contains("/build"))
            return try base(request)
        }
        try await cloud.setScreenSyncEnabled(true)
        for _ in 0..<4 { try await cloud.automaticSync() }
        XCTAssertEqual(Set(createRequests).count, 1); XCTAssertEqual(createRequests.count, 2)
        XCTAssertEqual(importCount, 1, "catalog reconciliation must survive the import idempotency window")
        XCTAssertEqual(try client.listWorkspacePackages(in: client.workspaceStatus()).count, 1)
        let status = try await cloud.status()
        XCTAssertEqual(status.bindings.count, 1); XCTAssertEqual(status.bindings.first?.status, .synced)
        try await cloud.setScreenSyncEnabled(false)
    }

    func testOldStatusDecodesScreenSyncAsOff() throws {
        let bytes = Data(#"{"accountId":"account","workspaces":[],"bindings":[]}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ControllerCloudWorkbenchStatus.self, from: bytes).screenSyncEnabled)
    }

    func testBrokerCloudImportResumesBeforeBindingWithSameFreshIdentityAndPreservesLaterEdits() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let original = try XCTUnwrap(client.performAuthoring(method: .projectCreate, params: ["schemaVersion": 1, "name": "Duplicate name", "kind": "web"]).project)
        let source = try ControllerCloudBrokerSource(client: client, scratchRoot: root.appendingPathComponent("source-transfer"))
        let snapshot = try await source.read(projectId: original.project.projectId)
        let staged = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: staged.appendingPathComponent("snapshot.json"))
        let selected = try client.workspaceStatus(), intent = UUID().uuidString.lowercased(), dashboard = UUID().uuidString.lowercased()
        let fields: [String: Any] = ["schemaVersion": 1, "intentId": intent, "dashboardId": dashboard, "name": "Duplicate name", "path": staged.path,
            "expectedWorkspaceId": selected.workspaceId!, "expectedSelectionGeneration": selected.selectionGeneration!]
        let first = try XCTUnwrap(client.performAuthoring(method: .cloudProjectCreate, params: fields).project)
        XCTAssertEqual(first.project.projectId, intent); XCTAssertEqual(first.project.dashboardId, dashboard)
        XCTAssertNotEqual(intent, original.project.projectId); XCTAssertNotEqual(dashboard, original.project.dashboardId)
        // Simulate the client disappearing immediately after local commit, before any binding.
        client.close()
        let resumed = WorkbenchBrokerClient(environment: try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime")))
        try resumed.connect(); defer { resumed.close() }
        let second = try XCTUnwrap(resumed.performAuthoring(method: .cloudProjectCreate, params: fields).project)
        XCTAssertEqual(second.project, first.project); XCTAssertEqual(try resumed.listProjects().count, 2)
        var edited = snapshot.files; edited["web/index.html"] = Data("<!doctype html><html><body>Local edit after import</body></html>".utf8)
        try JSONEncoder().encode(ControllerCloudSourceSnapshot(revision: snapshot.revision, files: edited)).write(to: staged.appendingPathComponent("snapshot.json"))
        let changed = try XCTUnwrap(resumed.performAuthoring(method: .projectSyncSource, params: ["schemaVersion": 1,
            "projectId": intent, "expectedSourceVersion": second.sourceVersion, "path": staged.path]).project)
        try JSONEncoder().encode(snapshot).write(to: staged.appendingPathComponent("snapshot.json"))
        let replay = try XCTUnwrap(resumed.performAuthoring(method: .cloudProjectCreate, params: fields).project)
        XCTAssertEqual(replay.sourceVersion, changed.sourceVersion, "replay may not overwrite intervening local edits")
        XCTAssertEqual(try resumed.listProjects().count, 2)
    }

    func testNewCloudBindingDoesNotOverwriteConcurrentCloudSource() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let base = CloudWorkbenchHTTPStub.handler!, head = UUID().uuidString.lowercased()
        var id = "", uploads = 0
        let descriptor: [String: Any] = ["schemaVersion": 1, "name": "Concurrent Cloud edit", "kind": "web", "kitVersion": "builtin-web-1", "entry": "web/index.html", "screenConfig": "screen.json"]
        let remote = ["screenpunk.project.json": try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys]), "screen.json": Data("{}".utf8), "web/index.html": Data("<!doctype html><html><body>Concurrent Cloud edit</body></html>".utf8)]
        func response(_ value: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        func project() -> [String: Any] { ["id": id, "accountId": "account", "name": "Fresh", "sourceKind": "html", "headVersionId": head] }
        CloudWorkbenchHTTPStub.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/projects") && request.httpMethod == "POST" { id = try Self.requestObject(request)["projectId"] as! String; return try response(project()) }
            if !id.isEmpty && path.hasSuffix("/projects/" + id) { return try response(project()) }
            if path.hasSuffix("/binding") { return try response(["id": UUID().uuidString]) }
            if path.hasSuffix("/manifest") { return try response(["files": remote.keys.sorted().map { ["path": $0, "sha256": DeploymentDigest.sha256Hex(remote[$0]!), "size": remote[$0]!.count, "mediaType": "application/octet-stream"] }, "nextCursor": NSNull()]) }
            if path.hasSuffix("/source/read") {
                let member = try Self.requestObject(request)["path"] as! String, bytes = remote[member]!
                return try response(["versionId": head, "path": member, "sha256": DeploymentDigest.sha256Hex(bytes), "size": bytes.count, "encoding": "base64", "data": bytes.base64EncodedString()])
            }
            if path.hasSuffix("/source/sync") { uploads += 1; throw ControllerCloudError.invalidResponse }
            return try base(request)
        }
        let binding = try await cloud.createProject(name: "Fresh")
        XCTAssertEqual(binding.status, .conflict); XCTAssertEqual(uploads, 0)
        XCTAssertEqual(try client.listProjects().count, 1)
    }

    func testEmptySourceGainingSourceAndPackageKeepsOneLocalScreen() async throws {
        try await checkEmptySourceTransition(packageArrivesFirst: false)
    }
    func testPackageCopyGainingSourceKeepsItsEstablishedLocalScreen() async throws {
        try await checkEmptySourceTransition(packageArrivesFirst: true)
    }
    private func checkEmptySourceTransition(packageArrivesFirst: Bool) async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let base = CloudWorkbenchHTTPStub.handler!, id = UUID().uuidString.lowercased(), head = UUID().uuidString.lowercased()
        var hasSource = false, hasPackage = false, packageReads = 0
        let descriptor: [String: Any] = ["schemaVersion": 1, "name": "Growing Screen", "kind": "web", "kitVersion": "builtin-web-1", "entry": "web/index.html", "screenConfig": "screen.json"]
        let files = ["screenpunk.project.json": try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys]), "screen.json": Data("{}".utf8), "web/index.html": Data("<!doctype html><html><body>Source</body></html>".utf8)]
        let packageContent = Data("<!doctype html><html><body>Package</body></html>".utf8), packageID = UUID().uuidString.lowercased()
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString.lowercased(), name: "Growing Screen", revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "test", width: 800, height: 480, scale: 1, orientation: "landscape"), connections: [], files: [.init(path: "index.html", bytes: packageContent.count, sha256: DeploymentDigest.sha256Hex(packageContent))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let original = manifest, archive = try ControllerCloudNativeArchive.encode(manifest: manifest, files: ["index.html": packageContent])
        func response(_ value: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        func project() -> [String: Any] { ["id": id, "accountId": "account", "name": "Growing Screen", "sourceKind": "html", "headVersionId": hasSource ? head as Any : NSNull()] }
        CloudWorkbenchHTTPStub.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/projects") { return try response(["items": [project()], "nextCursor": NSNull()]) }
            if path.hasSuffix("/projects/" + id) { return try response(project()) }
            if path.hasSuffix("/binding") { return try response(["id": UUID().uuidString]) }
            if path.hasSuffix("/manifest") { return try response(["files": files.keys.sorted().map { ["path": $0, "sha256": DeploymentDigest.sha256Hex(files[$0]!), "size": files[$0]!.count, "mediaType": "application/octet-stream"] }, "nextCursor": NSNull()]) }
            if path.hasSuffix("/source/read") {
                let member = try Self.requestObject(request)["path"] as! String, bytes = files[member]!
                return try response(["versionId": head, "path": member, "sha256": DeploymentDigest.sha256Hex(bytes), "size": bytes.count, "encoding": "base64", "data": bytes.base64EncodedString()])
            }
            if path.hasSuffix("/packages") {
                let item: [String: Any] = ["packageId": packageID, "projectId": id, "sourceVersionId": hasSource ? head as Any : NSNull(), "packageDigest": original.digest!, "manifestSha256": DeploymentDigest.sha256Hex(try JSONEncoder().encode(original)), "archiveSha256": DeploymentDigest.sha256Hex(archive), "archiveBytes": archive.count, "manifest": try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))]
                return try response(["items": hasPackage ? [item] : [], "nextCursor": NSNull()])
            }
            if path.hasSuffix("/file") {
                packageReads += 1
                return try response(["projectId": id, "packageId": packageID, "packageDigest": original.digest!, "path": "index.html", "sha256": original.files[0].sha256, "size": packageContent.count, "offset": 0, "dataBase64": packageContent.base64EncodedString(), "nextOffset": NSNull()])
            }
            return try base(request)
        }
        try await cloud.setScreenSyncEnabled(true); try await cloud.automaticSync()
        let empty = try await cloud.status()
        XCTAssertTrue(empty.bindings.isEmpty, "no package identity may be claimed without an actual package")
        if packageArrivesFirst {
            hasPackage = true
            try await cloud.automaticSync()
            XCTAssertEqual(try client.listWorkspacePackages(in: client.workspaceStatus()).count, 1)
            XCTAssertTrue(try client.listProjects().isEmpty)
        }
        hasSource = true; hasPackage = true
        try await cloud.automaticSync(); try await cloud.automaticSync()
        let sources = try client.listProjects(), packages = try client.listWorkspacePackages(in: client.workspaceStatus())
        XCTAssertEqual(sources.count, packageArrivesFirst ? 0 : 1)
        XCTAssertEqual(packages.count, packageArrivesFirst ? 1 : 0)
        XCTAssertEqual(Set(sources.map(\.dashboardId) + packages.map(\.dashboardId)).count, 1)
        let status = try await cloud.status()
        XCTAssertEqual(status.bindings.count, 1); XCTAssertEqual(status.bindings.first?.cloudProjectId, id)
        XCTAssertEqual(packageReads, packageArrivesFirst ? 1 : 0)
        try await cloud.setScreenSyncEnabled(false)
    }

    func testCapturedCreationArchivedBeforeFirstCycleMakesNoCloudScreen() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let selected = try client.workspaceStatus(), namespace = SHA256.hash(data: Data("https://cloud.test".utf8)).map { String(format: "%02x", $0) }.joined()
        let cloudRoot = root.appendingPathComponent("machine/cloud-controller/" + namespace)
        // Restored consent while the service owner is stopped; actual broker create captures its intent.
        try ControllerCloudPersistence.write(JSONEncoder().encode(ControllerCloudSyncPolicy(accountId: "account", workspaceId: workspace, localWorkspaceId: selected.workspaceId, enabled: true, epoch: "restored")), to: cloudRoot.appendingPathComponent("screen-sync-policy.json"))
        try ControllerCloudCreationScope.publish(root: cloudRoot, clientId: "screenpunk-cli", accountId: "account", workspaceId: workspace, localWorkspaceId: selected.workspaceId)
        let created = try XCTUnwrap(client.performAuthoring(method: .projectCreate, params: ["schemaVersion": 1, "name": "Removed before sync", "kind": "web"]).project)
        let intent = cloudRoot.appendingPathComponent("projects/\(selected.workspaceId!)/new/\(created.project.projectId).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: intent.path))
        let current = try client.workspaceStatus()
        _ = try client.archiveScreen(params: ["schemaVersion": 1, "expectedWorkspaceId": current.workspaceId!, "expectedSelectionGeneration": current.selectionGeneration!, "expectedCatalogGeneration": current.generation!, "dashboardId": created.project.dashboardId, "projectId": created.project.projectId, "expectedSourceVersion": created.sourceVersion])
        let base = CloudWorkbenchHTTPStub.handler!
        var posts = 0
        CloudWorkbenchHTTPStub.handler = { request in
            if request.httpMethod == "POST" { posts += 1; return (503, Data("{}".utf8)) }
            if request.url!.path.hasSuffix("/projects") { return (200, Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
            return try base(request)
        }
        try await cloud.automaticSync()
        XCTAssertEqual(posts, 0); XCTAssertTrue(FileManager.default.fileExists(atPath: intent.path))
        let status = try await cloud.status()
        XCTAssertTrue(status.bindings.isEmpty)
        try await cloud.setScreenSyncEnabled(false)
    }

    private static func requestObject(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testCanonicalReactImportRoundTripsWithoutDescriptorEchoAcrossClients() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let base = CloudWorkbenchHTTPStub.handler!
        let remoteID = UUID().uuidString.lowercased()
        var head = UUID().uuidString.lowercased(), uploads = 0
        // Real canonical shape used by the maintained compiler, with no Mac descriptor.
        let original: [String: Data] = ["screen.json": Data(#"{"name":"Counter","connections":[]}"#.utf8),
            "src/main.tsx": Data("export default function App(){ return <button>0</button>; }".utf8),
            "src/screen.css": Data("button { color: blue; }".utf8)]
        var files = original
        func response(_ value: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        let handler: (URLRequest) throws -> (Int, Data) = { request in
            let path = request.url!.path
            if path.hasSuffix("/projects/" + remoteID) {
                return try response(["id": remoteID, "accountId": "account", "name": "Counter", "sourceKind": "react", "headVersionId": head])
            }
            if path.hasSuffix("/binding") { return try response(["id": remoteID]) }
            if path.hasSuffix("/manifest") {
                return try response(["files": files.keys.sorted().map { ["path": $0, "sha256": DeploymentDigest.sha256Hex(files[$0]!), "size": files[$0]!.count, "mediaType": "application/octet-stream"] }, "nextCursor": NSNull()])
            }
            if path.hasSuffix("/source/read") {
                let body = try Self.requestObject(request), member = try XCTUnwrap(body["path"] as? String), bytes = try XCTUnwrap(files[member])
                return try response(["versionId": head, "path": member, "sha256": DeploymentDigest.sha256Hex(bytes), "size": bytes.count, "encoding": "base64", "data": bytes.base64EncodedString()])
            }
            if path.hasSuffix("/source/sync") {
                let body = try Self.requestObject(request)
                XCTAssertEqual(body["baseVersionId"] as? String, head)
                let members = try XCTUnwrap(body["files"] as? [[String: Any]])
                var incoming: [String: Data] = [:]
                for member in members { incoming[try XCTUnwrap(member["path"] as? String)] = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(member["data"] as? String))) }
                XCTAssertNil(incoming["screenpunk.project.json"])
                XCTAssertEqual(Set(incoming.keys), Set(original.keys))
                files = incoming; uploads += 1; head = UUID().uuidString.lowercased()
                return try response(["id": head])
            }
            return try base(request)
        }
        CloudWorkbenchHTTPStub.handler = handler
        let first = try await cloud.restore(cloudProjectId: remoteID, name: "Counter")
        XCTAssertEqual(first.status, .synced); XCTAssertEqual(uploads, 0); XCTAssertEqual(files, original)
        let namespace = SHA256.hash(data: Data("https://cloud.test".utf8)).map { String(format: "%02x", $0) }.joined()
        let cloudRoot = root.appendingPathComponent("machine/cloud-controller/" + namespace)
        let local = try ControllerCloudBrokerSource(client: client, scratchRoot: cloudRoot.appendingPathComponent("source-transfer"), projectionRoot: cloudRoot.appendingPathComponent("projects"))
        let captured = try await local.read(projectId: first.localProjectId)
        XCTAssertEqual(captured.files, original)
        _ = try await cloud.sync(localProjectId: first.localProjectId)
        XCTAssertEqual(uploads, 0, "local metadata must never manufacture a Cloud revision")
        let (otherRoot, otherServer, otherClient, otherCloud) = try defaultWorkspaceFixture()
        defer { otherClient.close(); otherServer.stop(); try? FileManager.default.removeItem(at: otherRoot) }
        CloudWorkbenchHTTPStub.handler = handler
        try await otherCloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: otherRoot.appendingPathComponent("Screenpunk").path)
        let other = try await otherCloud.restore(cloudProjectId: remoteID, name: "Counter")
        XCTAssertNotEqual(first.localProjectId, other.localProjectId); XCTAssertEqual(uploads, 0)
        var edited = captured.files; edited["src/main.tsx"] = Data("export default function App(){ return <button>1</button>; }".utf8)
        try await local.replace(projectId: first.localProjectId, expectedRevision: captured.revision, snapshot: .init(revision: head, files: edited))
        _ = try await cloud.sync(localProjectId: first.localProjectId)
        XCTAssertEqual(uploads, 1); XCTAssertEqual(files, edited)
        _ = try await otherCloud.sync(localProjectId: other.localProjectId)
        XCTAssertEqual(uploads, 1, "another client's native IDs cannot echo back")
        files["src/screen.css"] = Data("button { color: red; }".utf8); head = UUID().uuidString.lowercased()
        _ = try await cloud.sync(localProjectId: first.localProjectId)
        let downloaded = try await local.read(projectId: first.localProjectId)
        XCTAssertEqual(downloaded.files, files); XCTAssertEqual(uploads, 1)
    }

    func testCanonicalRestoreReopensAfterProjectionAndAfterCreateBeforeBinding() async throws {
        var rejectCreation = false
        let (root, server, client, cloud) = try defaultWorkspaceFixture(mutationGate: {
            if rejectCreation { throw WorkbenchIPCError(.unavailable) }
        })
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("Screenpunk").path)
        let base = CloudWorkbenchHTTPStub.handler!, remoteID = UUID().uuidString.lowercased(), head = UUID().uuidString.lowercased()
        let files = ["screen.json": Data("{}".utf8), "src/main.tsx": Data("export default function App(){return <button>0</button>}".utf8), "src/screen.css": Data("button{color:blue}".utf8)]
        var rejectBinding = true, uploads = 0, bindingAttempts = 0
        func object() -> [String: Any] { ["id": remoteID, "accountId": "account", "name": "Counter", "sourceKind": "react", "headVersionId": head] }
        func response(_ value: Any, status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value)) }
        CloudWorkbenchHTTPStub.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/projects/" + remoteID) { return try response(object()) }
            if path.hasSuffix("/projects") && request.httpMethod == "GET" { return try response(["items": [object()], "nextCursor": NSNull()]) }
            if path.hasSuffix("/binding") {
                bindingAttempts += 1
                return try response(["id": remoteID], status: rejectBinding ? 503 : 200)
            }
            if path.hasSuffix("/manifest") { return try response(["files": files.keys.sorted().map { ["path": $0, "sha256": DeploymentDigest.sha256Hex(files[$0]!), "size": files[$0]!.count, "mediaType": "application/octet-stream"] }, "nextCursor": NSNull()]) }
            if path.hasSuffix("/source/read") {
                let body = try Self.requestObject(request), member = try XCTUnwrap(body["path"] as? String), bytes = try XCTUnwrap(files[member])
                return try response(["versionId": head, "path": member, "sha256": DeploymentDigest.sha256Hex(bytes), "size": bytes.count, "encoding": "base64", "data": bytes.base64EncodedString()])
            }
            if path.hasSuffix("/source/sync") { uploads += 1; return try response(["id": UUID().uuidString.lowercased()]) }
            return try base(request)
        }
        rejectCreation = true
        do { _ = try await cloud.restore(cloudProjectId: remoteID, name: "Counter"); XCTFail("injected pre-create interruption must fail") }
        catch { XCTAssertEqual(error as? WorkbenchIPCError, WorkbenchIPCError(.unavailable)) }
        // The production IPC client closes on failure; reconnect only the fixture inspector.
        try client.connect()
        XCTAssertTrue(try client.listProjects().isEmpty); XCTAssertEqual(bindingAttempts, 0)
        let machine = root.appendingPathComponent("machine"), selected = try client.workspaceStatus()
        let namespace = SHA256.hash(data: Data("https://cloud.test".utf8)).map { String(format: "%02x", $0) }.joined()
        let cloudRoot = machine.appendingPathComponent("cloud-controller/" + namespace)
        let imports = cloudRoot.appendingPathComponent("projects/\(selected.workspaceId!)/imports/\(workspace)")
        let intent = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: imports.appendingPathComponent(remoteID + ".json"))) as? [String: Any])
        let localID = try XCTUnwrap(intent["localProjectId"] as? String), dashboard = try XCTUnwrap(intent["dashboardId"] as? String)
        let projectionRoot = cloudRoot.appendingPathComponent("projects/\(selected.workspaceId!)/source-projections")
        XCTAssertEqual(try ControllerCloudCanonicalSourceStore(root: projectionRoot).read(localID)?.dashboardId, dashboard)
        let rawSnapshot = try JSONDecoder().decode(ControllerCloudSourceSnapshot.self, from: Data(contentsOf: imports.appendingPathComponent(remoteID + ".snapshot")))
        XCTAssertEqual(rawSnapshot.files, files); XCTAssertEqual(rawSnapshot.revision, head)
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        client.close(); rejectCreation = false
        let reopenedClient = WorkbenchBrokerClient(environment: environment); try reopenedClient.connect(); defer { reopenedClient.close() }
        let config = try ControllerCloudConfiguration(baseURL: URL(string: "https://cloud.test")!, authorizationURL: URL(string: "https://cloud.test/issuer/auth")!, tokenURL: URL(string: "https://cloud.test/issuer/token")!, clientID: "screenpunk-cli", redirectURI: "http://127.0.0.1:43871/callback")
        let reopened = try ControllerCloudWorkbench(configuration: config, client: reopenedClient, machineRoot: machine, session: session())
        do { _ = try await reopened.restore(cloudProjectId: remoteID, name: "Counter"); XCTFail("injected post-create binding failure must fail") }
        catch { XCTAssertEqual(error as? ControllerCloudError, .http(503)) }
        let created = try reopenedClient.listProjects()
        XCTAssertEqual(created.count, 1); XCTAssertEqual(created.first?.projectId, localID); XCTAssertEqual(created.first?.dashboardId, dashboard)
        reopenedClient.close(); rejectBinding = false
        let finalClient = WorkbenchBrokerClient(environment: environment); try finalClient.connect(); defer { finalClient.close() }
        let final = try ControllerCloudWorkbench(configuration: config, client: finalClient, machineRoot: machine, session: session())
        try await final.setScreenSyncEnabled(true)
        try await final.automaticSync()
        XCTAssertEqual(try finalClient.listProjects().map(\.projectId), [localID])
        let finalStatus = try await final.status()
        XCTAssertEqual(finalStatus.bindings.first { $0.cloudProjectId == remoteID }?.status, .synced)
        XCTAssertEqual(bindingAttempts, 2); XCTAssertEqual(uploads, 0)
        let persisted = try JSONDecoder().decode(ControllerCloudSourceSnapshot.self, from: Data(contentsOf: imports.appendingPathComponent(remoteID + ".snapshot")))
        XCTAssertEqual(persisted, rawSnapshot, "restart must not rewrite the canonical Cloud revision")
    }

    func testCanonicalProjectionPersistsIdentityBeforeCreateAndRejectsIncompatibleSource() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-canonical-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ControllerCloudCanonicalSourceStore.Record(schemaVersion: 1,
            localWorkspaceId: UUID().uuidString, cloudWorkspaceId: UUID().uuidString, cloudProjectId: UUID().uuidString,
            localProjectId: UUID().uuidString, dashboardId: UUID().uuidString, name: "Counter", sourceKind: "react")
        let store = ControllerCloudCanonicalSourceStore(root: root)
        let raw = ControllerCloudSourceSnapshot(revision: UUID().uuidString, files: ["screen.json": Data("{}".utf8), "src/main.tsx": Data("export {};".utf8)])
        let local = try store.prepare(record, snapshot: raw)
        XCTAssertEqual(try store.read(record.localProjectId), record, "crash before broker creation retains exact identity")
        XCTAssertEqual(try store.prepare(record, snapshot: raw), local)
        XCTAssertEqual(try record.canonicalView(local), raw)
        var wrong = local.files
        var descriptor = try XCTUnwrap(try JSONSerialization.jsonObject(with: wrong["screenpunk.project.json"]!) as? [String: Any])
        descriptor["entry"] = "src/other.tsx"; wrong["screenpunk.project.json"] = try JSONSerialization.data(withJSONObject: descriptor)
        XCTAssertThrowsError(try record.canonicalView(.init(revision: raw.revision, files: wrong)))
        for files in [["screen.json": Data("{}".utf8)], ["src/main.tsx": Data()], ["screen.json": Data("[]".utf8), "src/main.tsx": Data()], ["screen.json": Data("{}".utf8), "src/main.tsx": Data(), "../escape": Data()]] {
            XCTAssertThrowsError(try record.localView(.init(revision: raw.revision, files: files)))
        }
    }

    private func defaultWorkspaceFixture(existing: Bool = false, mutationGate: @escaping () throws -> Void = {}) throws -> (URL, WorkbenchBrokerServer, WorkbenchBrokerClient, ControllerCloudWorkbench) {
        let root = URL(fileURLWithPath: "/private/tmp/sp-cloud-default-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let documents = CloudCreationScheduleDocuments(root: root)
        if existing {
            let previous = try WorkspaceStore(documents: documents, machineRootPath: root.appendingPathComponent("previous-machine").path)
            _ = try previous.create(at: root.appendingPathComponent("Screenpunk").path)
        }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: documents, machineRootPath: machine.path)
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"), deviceDirectoryURL: machine.appendingPathComponent("devices.json"), rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let server = WorkbenchBrokerServer(environment: environment, domain: WorkbenchBrokerDomain(controller: controller, workspace: store, mutationGate: mutationGate))
        try server.start()
        let client = WorkbenchBrokerClient(environment: environment); try client.connect()
        let configuration = try ControllerCloudConfiguration(baseURL: URL(string: "https://cloud.test")!, authorizationURL: URL(string: "https://cloud.test/issuer/auth")!, tokenURL: URL(string: "https://cloud.test/issuer/token")!, clientID: "screenpunk-cli", redirectURI: "http://127.0.0.1:43871/callback")
        let cloud = try ControllerCloudWorkbench(configuration: configuration, client: client, machineRoot: machine, session: session())
        CloudWorkbenchHTTPStub.handler = { request in
            func response(_ body: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: body)) }
            if request.url!.path == "/controller/v1/session" { return try response(["userId": "account"]) }
            if request.url!.path == "/controller/v1/workspaces" { return try response(["items": [["id": self.workspace, "name": "Studio", "membershipId": "membership", "role": "owner"]], "nextCursor": NSNull()]) }
            if request.url!.path.hasSuffix("/realtime/session") { return try Self.realtimeResponse(generation: "4451ae01-dc36-41e0-b58c-213264639c7d") }
            if request.url!.path.hasSuffix("/connections") {
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
                }
                let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                return try response(["id": body["controllerId"]!])
            }
            throw ControllerCloudError.invalidResponse
        }
        return (root, server, client, cloud)
    }
    func testMacWorkspaceSetupCreatesOnceAndPreservesExistingLocalSelection() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Screenpunk").path
        XCTAssertNil(try client.workspaceStatus().workspaceId)
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: path)
        let first = try client.workspaceStatus()
        XCTAssertEqual(first.path, path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/workspace.json"))
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: path)
        XCTAssertEqual(try client.workspaceStatus().workspaceId, first.workspaceId)
        XCTAssertEqual(try client.workspaceStatus().selectionGeneration, first.selectionGeneration)
        let connected = try await cloud.status(); XCTAssertEqual(connected.selectedWorkspaceId, workspace)
        let other = try client.initializeWorkspace(path: root.appendingPathComponent("Other").path)
        let switched = try await cloud.status(); XCTAssertNil(switched.selectedWorkspaceId)
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: path)
        XCTAssertEqual(try client.workspaceStatus().workspaceId, other.workspaceId)
    }
    func testMacWorkspaceSetupOpensExistingDefaultWithoutReplacingContents() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture(existing: true)
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Screenpunk"), descriptor = folder.appendingPathComponent("workspace.json")
        let before = try Data(contentsOf: descriptor)
        try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: folder.path)
        XCTAssertEqual(try Data(contentsOf: descriptor), before)
        XCTAssertEqual(try client.workspaceStatus().path, folder.path)
    }
    func testMacWorkspaceSetupRejectsUnrelatedExistingDirectoryAndUnlistedCloudWorkspace() async throws {
        let (root, server, client, cloud) = try defaultWorkspaceFixture()
        defer { client.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Screenpunk")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let userFile = folder.appendingPathComponent("keep.txt"); try Data("user source".utf8).write(to: userFile)
        do { try await cloud.selectWorkspace(workspace, creatingLocalWorkspaceAt: folder.path); XCTFail("Unrelated folder adopted") } catch {}
        XCTAssertEqual(try Data(contentsOf: userFile), Data("user source".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("workspace.json").path))
        _ = try client.reconnectIfPeerClosed()
        XCTAssertNil(try client.workspaceStatus().workspaceId)
        let unused = root.appendingPathComponent("Unlisted").path
        do { try await cloud.selectWorkspace("unlisted", creatingLocalWorkspaceAt: unused); XCTFail("Unlisted Cloud workspace accepted") }
        catch { XCTAssertEqual(error as? ControllerCloudError, .accountMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused))
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
    func testDeploymentReviewRemovalIdsMatchCloudContract() throws {
        func entry(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
        func review(_ removals: [String]) -> ControllerCloudDeploymentReview {
            ControllerCloudDeploymentReview(schemaVersion: 1,
                publicationId: "05f76a3e-5a44-4cf0-8a5b-0d527f866591",
                installationId: "cdbdf510-4785-44f9-860c-9bf9be25a318",
                operationId: "ee643e93-5f50-4f44-9a84-1c430e57dfe0",
                removeEntryIds: removals,
                expectedGenerationId: "26acbf68-6685-4854-a1cf-43c3638d3767",
                resultingSet: .object([:]),
                resultingSetDigest: "9ba262c7a333ceeff9a94374571d110c11162929a5815a756589a6fd50391536")
        }
        func accept(_ removals: [String], _ label: String) {
            XCTAssertNoThrow(try review(removals).validate(), label)
        }
        func reject(_ removals: [String], _ label: String) {
            XCTAssertThrowsError(try review(removals).validate(), label) {
                XCTAssertEqual($0 as? ControllerCloudError, .invalidResponse, label)
            }
        }
        let lower = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let upper = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        XCTAssertEqual(ControllerCloudDeploymentReview.maximumRemoveEntryIds, 32)
        accept([], "zero removals")
        accept((0..<32).map(entry), "32 unique removal ids")
        accept([upper], "uppercase uuid")
        accept([upper, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"], "distinct mixed-case uuids")
        reject((0..<33).map(entry), "33 removal ids")
        reject(["not-a-uuid"], "invalid uuid")
        reject([entry(1), entry(1)], "duplicate uuid")
        reject([lower, upper], "case-variant duplicate uuid")
    }

    func testReviewDeploymentRejectsInvalidRemovalIdsBeforeRequest() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-cloud-review-removals-" + UUID().uuidString)
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
        func json(_ object: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: object)) }
        func requestObject(_ request: URLRequest) throws -> [String: Any] {
            if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
            guard let stream = request.httpBodyStream else { return [:] }
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func contextResponse(_ request: URLRequest) throws -> (Int, Data)? {
            let path = request.url?.path ?? ""
            if path == "/controller/v1/session" { return try json(["userId": "account", "clientId": "screenpunk-cli"]) }
            if path == "/controller/v1/workspaces" { return try json(["items": [["id": workspace, "name": "Workspace", "membershipId": "membership", "role": "owner"]], "nextCursor": NSNull()]) }
            if path.hasSuffix("/connections") { return try json(["id": try requestObject(request)["controllerId"]!]) }
            return nil
        }
        CloudWorkbenchHTTPStub.handler = { request in
            if let ready = try contextResponse(request) { return ready }
            throw ControllerCloudError.invalidResponse
        }
        try await cloud.selectWorkspace(workspace)

        let publication = "05f76a3e-5a44-4cf0-8a5b-0d527f866591"
        let installation = "cdbdf510-4785-44f9-860c-9bf9be25a318"
        let operation = "ee643e93-5f50-4f44-9a84-1c430e57dfe0"
        func entry(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012x", n) }
        let removalError = "Deployment review accepts at most 32 removal IDs. Each must be a UUID, and case variants count as the same ID."

        func reject(_ removals: [String], _ label: String) async {
            var paths: [String] = []
            CloudWorkbenchHTTPStub.handler = { request in
                paths.append(request.url?.path ?? request.url?.absoluteString ?? "")
                return (500, Data("{}".utf8))
            }
            do {
                _ = try await cloud.reviewDeployment(publicationId: publication, installationId: installation, operationId: operation, removeEntryIds: removals)
                XCTFail("accepted \(label)")
            } catch {
                XCTAssertEqual(error as? ControllerCloudError, .invalidRemoveEntryIds, label)
                XCTAssertEqual((error as? LocalizedError)?.errorDescription, removalError, label)
            }
            XCTAssertEqual(paths, [], "\(label) must not send a request")
        }
        await reject((0..<33).map(entry), "33 removal ids")
        await reject(["not-a-uuid"], "invalid uuid")
        let lower = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let upper = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        await reject([lower, upper], "case-variant duplicate uuid")

        func accept(_ removals: [String], _ label: String) async throws {
            var sent: [[String]] = []
            CloudWorkbenchHTTPStub.handler = { request in
                if let ready = try contextResponse(request) { return ready }
                XCTAssertEqual(request.httpMethod, "POST", label)
                XCTAssertEqual(request.url?.path, "/controller/v1/workspaces/\(self.workspace)/deployments/review", label)
                let body = try requestObject(request)
                let ids = try XCTUnwrap(body["removeEntryIds"] as? [String], label)
                sent.append(ids)
                XCTAssertEqual(body["publicationId"] as? String, publication, label)
                XCTAssertEqual(body["installationId"] as? String, installation, label)
                XCTAssertEqual(body["operationId"] as? String, operation, label)
                return try json([
                    "schemaVersion": 1,
                    "publicationId": publication,
                    "installationId": installation,
                    "operationId": operation,
                    "removeEntryIds": ids,
                    "expectedGenerationId": "26acbf68-6685-4854-a1cf-43c3638d3767",
                    "resultingSet": [:] as [String: Any],
                    "resultingSetDigest": "9ba262c7a333ceeff9a94374571d110c11162929a5815a756589a6fd50391536"
                ])
            }
            let review = try await cloud.reviewDeployment(publicationId: publication, installationId: installation, operationId: operation, removeEntryIds: removals)
            XCTAssertEqual(sent, [removals], label)
            XCTAssertEqual(review.removeEntryIds, removals, label)
        }
        try await accept([], "zero removals")
        var boundary = (0..<32).map(entry)
        boundary[10] = boundary[10].uppercased()
        XCTAssertNotEqual(boundary[10], entry(10), "boundary fixture must preserve an uppercase UUID")
        try await accept(boundary, "32 unique removal ids")
    }
}
#endif
