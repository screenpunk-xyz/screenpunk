import Foundation
#if os(macOS)
import CryptoKit
import Darwin
import ScreenpunkCore

public struct ControllerCloudWorkspace: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let membershipId: String
    public let role: String
}
public struct ControllerCloudProject: Codable, Sendable, Identifiable {
    public let id: String
    public let accountId: String
    public let name: String
    public let sourceKind: String
    public let kitVersion: String?
    public let headVersionId: String?
}
public struct ControllerCloudWorkbenchStatus: Codable, Sendable {
    public let accountId: String
    public let selectedWorkspaceId: String?
    public let workspaces: [ControllerCloudWorkspace]
    public let bindings: [ControllerCloudProjectBinding]
    public let screenSyncEnabled: Bool
    public let screenSyncMessage: String?
    public let screenSyncScreens: [String: ControllerCloudScreenSyncStatus]?
    public let automaticSyncState: String?
    public let automaticSyncErrors: [String: String]?
    private enum CodingKeys: String, CodingKey {
        case accountId, selectedWorkspaceId, workspaces, bindings, screenSyncEnabled, screenSyncMessage, screenSyncScreens, automaticSyncState, automaticSyncErrors
    }

}
extension ControllerCloudWorkbenchStatus {
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try value.decode(String.self, forKey: .accountId)
        selectedWorkspaceId = try value.decodeIfPresent(String.self, forKey: .selectedWorkspaceId)
        workspaces = try value.decode([ControllerCloudWorkspace].self, forKey: .workspaces)
        bindings = try value.decode([ControllerCloudProjectBinding].self, forKey: .bindings)
        screenSyncEnabled = try value.decodeIfPresent(Bool.self, forKey: .screenSyncEnabled) ?? false
        screenSyncMessage = try value.decodeIfPresent(String.self, forKey: .screenSyncMessage)
        screenSyncScreens = try value.decodeIfPresent([String: ControllerCloudScreenSyncStatus].self, forKey: .screenSyncScreens)
        automaticSyncState = try value.decodeIfPresent(String.self, forKey: .automaticSyncState)
        automaticSyncErrors = try value.decodeIfPresent([String: String].self, forKey: .automaticSyncErrors)
    }
}
public struct ControllerCloudInstallation: Codable, Sendable, Identifiable { public let id: String; public let installationId: String; public let name: String; public let locationId: String? }
public struct ControllerCloudPublication: Codable, Sendable, Identifiable { public let id: String; public let name: String; public let locationId: String? }
extension ControllerCloudProjectBinding {
    func requireAutomaticCreationScope(accountId: String, workspaceId: String?) throws {
        guard self.accountId == accountId, self.workspaceId == workspaceId else { throw ControllerCloudError.accountMismatch }
    }
}
struct ControllerCloudApprovedArchive: Decodable, Sendable {
    let operationId: String
    let installationId: String
    let packageId: String
    let archiveSha256: String
    let archiveBytes: Int
    let dataBase64: String

    func validatedBytes(operationId expectedOperation: String, installationId expectedInstallation: String,
                        packageId expectedPackage: String, sha256 expectedHash: String, byteCount expectedCount: Int) throws -> Data {
        guard operationId == expectedOperation, installationId == expectedInstallation,
              packageId == expectedPackage, archiveSha256 == expectedHash, archiveBytes == expectedCount,
              dataBase64.utf8.count <= 36 * 1024 * 1024,
              let bytes = Data(base64Encoded: dataBase64), bytes.count == expectedCount,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedHash else {
            throw ControllerCloudError.invalidResponse
        }
        return bytes
    }
}
private struct CloudPage<Item: Codable & Sendable>: Codable, Sendable {
    let items: [Item]
    let nextCursor: String?
}
private struct CloudSelection: Codable { var accountId: String; var workspaceId: String?; var localWorkspaceId: String? }
struct CloudNewProjectIntent: Codable { let accountId: String; let workspaceId: String; let localProjectId: String; let name: String; let kind: String; let idempotencyKey: String; var cloudProjectId: String?; var kitVersion: String? = nil; var requestedCloudProjectId: String? = nil }

public extension ControllerCloudConfiguration {
    /// Registration is supplied by the release deployment. No guessed public client IDs.
    static func deployment(clientID: String = "screenpunk-cli",
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           bundle: [String: Any] = Bundle.main.infoDictionary ?? [:],
                           session: URLSession = .shared, machineRoot: URL? = nil) async throws -> Self {
        let text = environment["SCREENPUNK_CLOUD_BASE_URL"] ?? bundle["ScreenpunkCloudAPIOrigin"] as? String
        guard let text, !text.contains("$("), let base = URL(string: text),
              base.scheme == "https", base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, ["", "/"].contains(base.path) else {
            throw ControllerCloudError.invalidConfiguration
        }
        // Explicit CLI development endpoint overrides; normal clients discover maintained issuer metadata.
        if let authorizationText = environment["SCREENPUNK_CLOUD_AUTHORIZATION_URL"],
           let tokenText = environment["SCREENPUNK_CLOUD_TOKEN_URL"],
           let revocationText = environment["SCREENPUNK_CLOUD_REVOCATION_URL"],
           let authorization = URL(string: authorizationText), let token = URL(string: tokenText), let revocation = URL(string: revocationText) {
            return try Self(baseURL: base, authorizationURL: authorization, tokenURL: token,
                clientID: environment["SCREENPUNK_CLOUD_CLIENT_ID"] ?? clientID,
                redirectURI: "http://127.0.0.1:43871/callback", revocationURL: revocation)
        }
        struct Metadata: Decodable { let issuer: URL; let authorization_endpoint: URL; let token_endpoint: URL; let revocation_endpoint: URL; let code_challenge_methods_supported: [String]; let token_endpoint_auth_methods_supported: [String] }
        let namespace = SHA256.hash(data: Data(base.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = machineRoot?.appendingPathComponent("cloud-controller/\(namespace)/authorization-server.json")
        let data: Data
        do {
            let (bytes, response) = try await session.data(from: base.appendingPathComponent(".well-known/oauth-authorization-server/issuer"))
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, bytes.count <= 128 * 1024 else { throw ControllerCloudError.invalidConfiguration }
            data = bytes
        } catch {
            guard let cache, let cached = try? Data(contentsOf: cache), cached.count <= 128 * 1024 else { throw error }
            data = cached
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard metadata.issuer == base.appendingPathComponent("issuer"),
              metadata.code_challenge_methods_supported.contains("S256"),
              metadata.token_endpoint_auth_methods_supported.contains("none"),
              [metadata.authorization_endpoint, metadata.token_endpoint, metadata.revocation_endpoint].allSatisfy({ $0.host == base.host && $0.port == base.port }) else { throw ControllerCloudError.invalidConfiguration }
        if let cache {
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: cache, options: .atomic)
        }
        return try Self(baseURL: base, authorizationURL: metadata.authorization_endpoint,
            tokenURL: metadata.token_endpoint, clientID: clientID,
            redirectURI: "http://127.0.0.1:43871/callback", revocationURL: metadata.revocation_endpoint)
    }
}

/// HTTP source adapter shared by Mac and CLI. Each upload replaces the exact reviewed head.
public struct ControllerCloudHTTPProjects: ControllerCloudProjectRemoteMetadata {
    public let session: ControllerCloudSession
    public init(session: ControllerCloudSession) { self.session = session }
    private func path(_ workspace: String, _ project: String) throws -> String {
        guard UUID(uuidString: workspace) != nil, UUID(uuidString: project) != nil else {
            throw ControllerCloudError.invalidSource
        }
        return "/controller/v1/workspaces/\(workspace)/projects/\(project)"
    }
    func head(workspaceId: String, projectId: String) async throws -> ControllerCloudRemoteHead {
        do {
            let project = try await session.request(try path(workspaceId, projectId), as: ControllerCloudProject.self)
            return .present(project.headVersionId ?? "")
        } catch ControllerCloudError.http(404) { return .deleted }
    }
    public func read(workspaceId: String, projectId: String) async throws -> ControllerCloudSourceSnapshot? {
        let prefix = try path(workspaceId, projectId)
        let project: ControllerCloudProject
        do { project = try await session.request(prefix, as: ControllerCloudProject.self) }
        catch ControllerCloudError.http(404) { return nil }
        guard let head = project.headVersionId else { return .init(revision: "", files: [:]) }
        guard UUID(uuidString: head) != nil else { throw ControllerCloudError.invalidResponse }
        struct File: Codable, Sendable { let path: String; let sha256: String; let size: Int; let mediaType: String }
        struct Manifest: Codable, Sendable { let files: [File]; let nextCursor: String? }
        struct Read: Codable, Sendable { let versionId: String; let path: String; let sha256: String; let size: Int; let encoding: String; let data: String }
        var files: [String: Data] = [:], cursor: String?, seen = Set<String>(), totalBytes = 0
        repeat {
            let suffix = cursor.map { "?cursor=" + $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! } ?? ""
            let manifest = try await session.request(prefix + "/versions/\(head)/manifest" + suffix, as: Manifest.self)
            for entry in manifest.files {
                guard entry.size >= 0, entry.size <= ControllerCloudSourceLimits.maximumFileBytes,
                      files.count < ControllerCloudSourceLimits.maximumFiles, files[entry.path] == nil else { throw ControllerCloudError.invalidSource }
                let body = try JSONSerialization.data(withJSONObject: ["versionId": head, "path": entry.path, "encoding": "base64"])
                let read = try await session.request(prefix + "/source/read", method: "POST", body: body, as: Read.self)
                guard read.versionId == head, read.path == entry.path, read.encoding == "base64",
                      let data = Data(base64Encoded: read.data), data.count == entry.size,
                      read.size == entry.size, read.sha256 == entry.sha256,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
                    throw ControllerCloudError.invalidResponse
                }
                totalBytes += data.count
                guard totalBytes <= ControllerCloudSourceLimits.maximumTotalBytes else { throw ControllerCloudError.invalidSource }
                files[entry.path] = data
            }
            cursor = manifest.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw ControllerCloudError.invalidResponse }
        } while cursor != nil
        let result = ControllerCloudSourceSnapshot(revision: head, files: files)
        try result.validate(); return result
    }
    public func write(workspaceId: String, projectId: String, baseRevision: String?,
                      files: [String: Data], idempotencyKey: String) async throws -> ControllerCloudSourceSnapshot {
        try ControllerCloudSourceSnapshot(revision: baseRevision ?? "", files: files).validate()
        struct Version: Decodable, Sendable { let id: String }
        let body = try JSONSerialization.data(withJSONObject: [
            "baseVersionId": baseRevision.map { $0 as Any } ?? NSNull(),
            "idempotencyKey": idempotencyKey,
            "files": files.keys.sorted().map { ["path": $0, "mediaType": "application/octet-stream", "encoding": "base64", "data": files[$0]!.base64EncodedString()] }
        ])
        guard ControllerCloudSourceLimits.allowsSyncBody(byteCount: body.count) else { throw ControllerCloudError.sourceLimitExceeded }
        do {
            let version = try await session.request(try path(workspaceId, projectId) + "/source/sync", method: "POST", body: body, as: Version.self)
            guard UUID(uuidString: version.id) != nil else { throw ControllerCloudError.invalidResponse }
            return .init(revision: version.id, files: files)
        } catch ControllerCloudError.http(409) { throw ControllerCloudError.conflict }
    }
}

/// One facade and persistence layout for both controller surfaces. The cross-process
/// lock protects rotating Keychain tokens and journals while broker RPC owns source writes.
public actor ControllerCloudWorkbench {
    public let session: ControllerCloudSession
    private let configuration: ControllerCloudConfiguration
    private let client: WorkbenchBrokerClient
    private let root: URL
    private var realtimeBootstrap: (request: ControllerCloudScreenSyncRequest, controllerId: String, session: ControllerCloudRealtimeSession)?
    public init(configuration: ControllerCloudConfiguration, client: WorkbenchBrokerClient,
                machineRoot: URL, session: ControllerCloudSession? = nil) throws {
        self.configuration = configuration; self.client = client
        self.session = session ?? ControllerCloudSession(configuration: configuration,
            tokenStore: ControllerCloudKeychain(server: configuration.baseURL, clientID: configuration.clientID))
        let namespace = SHA256.hash(data: Data(configuration.baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        root = machineRoot.appendingPathComponent("cloud-controller/" + namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest: [String: Any] = ["owner": "Screenpunk controller", "project": "Screenpunk", "purpose": "Cloud bindings and recoverable source synchronization", "createdAt": ISO8601DateFormatter().string(from: Date()), "lifecycle": "active", "resourcePaths": [root.path], "keep": ["selection.json", "screen-sync-policy.json", "projects", "pending-unlinks", "package-transfer/*-publication.json", "authorization-server.json", "automation-status.json"], "disposable": ["source-transfer", "archive-relay"], "credentials": "Keychain only"]
        let manifestURL = root.appendingPathComponent("ownership.json")
        if !FileManager.default.fileExists(atPath: manifestURL.path) { try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic) }
    }
    private func policy() throws -> ControllerCloudSyncPolicy? {
        let file = root.appendingPathComponent("screen-sync-policy.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(ControllerCloudSyncPolicy.self, from: Data(contentsOf: file))
    }
    private func syncEnabled(for selected: CloudSelection) throws -> Bool {
        guard let policy = try policy() else { return false }
        return policy.enabled && policy.accountId == selected.accountId && policy.workspaceId == selected.workspaceId &&
            policy.localWorkspaceId == selected.localWorkspaceId
    }
    /// Disabling is local and immediate, including while a transfer owns the cross-process lock.
    /// Every later automatic request/mutation rechecks this exact consent epoch.
    public func setScreenSyncEnabled(_ enabled: Bool, workspaceId: String? = nil,
                                      creatingLocalWorkspaceAt path: String? = nil) async throws {
        if enabled, let workspaceId,
           try selection()?.workspaceId != workspaceId || selection()?.localWorkspaceId != client.workspaceStatus().workspaceId {
            try await selectWorkspace(workspaceId, creatingLocalWorkspaceAt: path)
        }
        let selected: CloudSelection?
        if enabled { selected = try selection() } else { selected = try? selection() }
        if enabled {
            guard let selected, selected.workspaceId != nil,
                  try selected.localWorkspaceId == client.workspaceStatus().workspaceId else { throw ControllerCloudError.accountMismatch }
        }
        let value = ControllerCloudSyncPolicy(accountId: selected?.accountId ?? "", workspaceId: selected?.workspaceId,
            localWorkspaceId: selected?.localWorkspaceId, enabled: enabled, epoch: UUID().uuidString, clientId: configuration.clientID)
        let file = root.appendingPathComponent("screen-sync-policy.json")
        try ControllerCloudPersistence.write(JSONEncoder().encode(value), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if let selected { try save(selected) }
        else { try ControllerCloudCreationScope.disconnect(root: root, clientId: configuration.clientID) }
        if enabled { try requestScreenSync(.enabled) }
    }
    /// Event requests are durable; the service owns execution after this caller exits.
    public nonisolated func requestScreenSync(_ trigger: ControllerCloudScreenSyncTrigger, dashboardId: String? = nil) throws {
        try ControllerCloudSyncRequestStore(root: root).enqueue(trigger: trigger, dashboardId: dashboardId)
    }
    /// Callback admission and durable write are synchronous, so a stale listener cannot retarget consent.
    public nonisolated func requestScreenSync(_ trigger: ControllerCloudScreenSyncTrigger, authorizedBy request: ControllerCloudScreenSyncRequest) throws {
        try requireRequest(request)
        try ControllerCloudSyncRequestStore(root: root).enqueue(trigger: trigger, dashboardId: nil, authorizedBy: request)
    }
    public static func requestScreenSync(baseURL: URL, client: WorkbenchBrokerClient, machineRoot: URL,
                                          trigger: ControllerCloudScreenSyncTrigger, dashboardId: String? = nil) async throws {
        let root = try ControllerCloudSyncRequestStore.originRoot(baseURL: baseURL, machineRoot: machineRoot)
        let request = ControllerCloudSyncRequestStore(root: root)
        guard let scope = try request.enabledScope(), try client.workspaceStatus().workspaceId == scope.localWorkspaceId else { return }
        try request.enqueue(trigger: trigger, dashboardId: dashboardId)
    }
    public static func screenSyncOwner(baseURL: URL, machineRoot: URL) throws -> String? {
        let store = ControllerCloudSyncRequestStore(root: try ControllerCloudSyncRequestStore.originRoot(baseURL: baseURL, machineRoot: machineRoot))
        guard let policy = try store.enabledScope() else { return nil }
        return try store.ownerClientId(policy)
    }
    public static func pendingScreenSyncRequest(baseURL: URL, machineRoot: URL) throws -> ControllerCloudScreenSyncRequest? {
        try ControllerCloudSyncRequestStore(root: ControllerCloudSyncRequestStore.originRoot(baseURL: baseURL, machineRoot: machineRoot)).pending()
    }
    public static func acknowledgeScreenSyncRequest(baseURL: URL, machineRoot: URL, requestId: String) throws {
        try ControllerCloudSyncRequestStore(root: ControllerCloudSyncRequestStore.originRoot(baseURL: baseURL, machineRoot: machineRoot)).acknowledge(requestId)
    }
    private func selection() throws -> CloudSelection? {
        let file = root.appendingPathComponent("selection.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(CloudSelection.self, from: Data(contentsOf: file))
    }
    private func save(_ selection: CloudSelection) throws {
        let file = root.appendingPathComponent("selection.json")
        try ControllerCloudPersistence.write(JSONEncoder().encode(selection), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try ControllerCloudCreationScope.publish(root: root, clientId: configuration.clientID, accountId: selection.accountId, workspaceId: try syncEnabled(for: selection) ? selection.workspaceId : nil, localWorkspaceId: selection.localWorkspaceId)
    }
    private func identity() async throws -> String {
        struct Identity: Decodable, Sendable { let userId: String }
        let identity = try await session.request("/controller/v1/session", as: Identity.self)
        guard !identity.userId.isEmpty else { throw ControllerCloudError.invalidResponse }
        return identity.userId
    }
    private func controllerID(accountId: String) throws -> String {
        let accountKey = SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent("controller-" + configuration.clientID + "-" + accountKey + ".json")
        struct Record: Codable { let id: String }
        if FileManager.default.fileExists(atPath: file.path) {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard UUID(uuidString: record.id) != nil else { throw ControllerCloudError.invalidResponse }
            return record.id
        }
        let id = UUID().uuidString.lowercased()
        try JSONEncoder().encode(Record(id: id)).write(to: file, options: .atomic)
        return id
    }
    private func registerController(workspaceId: String) async throws -> String {
        struct Registration: Decodable, Sendable { let id: String }
        let id = try controllerID(accountId: await identity())
        let body = try JSONSerialization.data(withJSONObject: ["controllerId": id,
            "kind": configuration.clientID == "screenpunk-mac" ? "mac" : "cli",
            "name": configuration.clientID == "screenpunk-mac" ? "Screenpunk for Mac" : "Screenpunk CLI"])
        let registration = try await session.request("/controller/v1/workspaces/\(workspaceId)/connections", method: "POST", body: body, as: Registration.self)
        guard registration.id == id else { throw ControllerCloudError.invalidResponse }
        return id
    }
    private func recordBinding(_ binding: ControllerCloudProjectBinding, removing: Bool = false) async throws {
        struct Record: Decodable, Sendable { let id: String? }
        let controller = try await registerController(workspaceId: binding.workspaceId)
        let body = try JSONSerialization.data(withJSONObject: ["controllerId": controller, "localProjectId": binding.localProjectId])
        _ = try await session.request("/controller/v1/workspaces/\(binding.workspaceId)/projects/\(binding.cloudProjectId)/binding",
            method: removing ? "DELETE" : "POST", body: body, as: Record.self)
    }
    private func workspaceList() async throws -> [ControllerCloudWorkspace] {
        let page = try await session.request("/controller/v1/workspaces", as: CloudPage<ControllerCloudWorkspace>.self)
        guard page.nextCursor == nil else { throw ControllerCloudError.invalidResponse }
        return page.items
    }
    private func projectSync() throws -> ControllerCloudProjectSync {
        let workspace = try client.workspaceStatus()
        guard let id = workspace.workspaceId, workspace.state == "selected" else { throw ControllerCloudError.invalidSource }
        return try ControllerCloudProjectSync(root: root.appendingPathComponent("projects/" + id),
            remote: ControllerCloudHTTPProjects(session: session),
            local: ControllerCloudBrokerSource(client: client, scratchRoot: root.appendingPathComponent("source-transfer"),
                projectionRoot: root.appendingPathComponent("projects")))
    }
    public static func screenSyncProgress(baseURL: URL, client: WorkbenchBrokerClient, machineRoot: URL) async throws -> [String: ControllerCloudScreenSyncStatus] {
        try await localScreenSyncStatus(baseURL: baseURL, client: client, machineRoot: machineRoot).screenSyncScreens
    }
    public static func localScreenSyncStatus(baseURL: URL, client: WorkbenchBrokerClient, machineRoot: URL) async throws -> ControllerCloudScreenSyncLocalStatus {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, ["", "/"].contains(baseURL.path) else { throw ControllerCloudError.invalidConfiguration }
        let namespace = SHA256.hash(data: Data(baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = machineRoot.appendingPathComponent("cloud-controller/" + namespace)
        let local = try client.workspaceStatus()
        guard let localID = local.workspaceId, WorkspaceValidation.id(localID), let generation = local.selectionGeneration else { return .init(screenSyncEnabled: false, selectedWorkspaceId: nil, screenSyncScreens: [:]) }
        let selected = (try? Data(contentsOf: root.appendingPathComponent("selection.json"))).flatMap { try? JSONDecoder().decode(CloudSelection.self, from: $0) }
        let policy = (try? Data(contentsOf: root.appendingPathComponent("screen-sync-policy.json"))).flatMap { try? JSONDecoder().decode(ControllerCloudSyncPolicy.self, from: $0) }
        let matching = selected?.localWorkspaceId == localID && policy?.accountId == selected?.accountId &&
            policy?.workspaceId == selected?.workspaceId && policy?.localWorkspaceId == localID
        let enabled = matching && policy?.enabled == true
        var snapshot: ControllerCloudSyncProgressStore.Snapshot?
        if let selected, let workspace = selected.workspaceId, selected.localWorkspaceId == localID {
            snapshot = try? ControllerCloudSyncProgressStore(root: root, scope: .init(accountId: selected.accountId, workspaceId: workspace, localWorkspaceId: localID)).read()
        }
        let recent = snapshot?.cycleUpdatedAt.flatMap { ControllerCloudSyncProgressStore.date($0) }.map { Date().timeIntervalSince($0) < 120 } ?? false
        let active = enabled && snapshot?.cycleEpoch == policy?.epoch && snapshot?.cycleState == "syncing" && recent
        let projects = try client.listProjects()
        let packages = try client.listWorkspacePackages(in: local)
        var result: [String: ControllerCloudScreenSyncStatus] = [:]
        for project in projects {
            let inspected = try? client.performAuthoring(method: .projectInspect, params: ["schemaVersion": 1, "projectId": project.projectId,
                "expectedWorkspaceId": localID, "expectedSelectionGeneration": generation])
            result[project.dashboardId] = ControllerCloudSyncProgressStore.display(snapshot?.entries[project.dashboardId], signature: inspected?.project?.sourceVersion, enabled: enabled, active: active)
        }
        for dashboard in Set(packages.map(\.dashboardId)) where result[dashboard] == nil {
            let signature = ControllerCloudSyncProgressStore.signature(packages.filter { $0.dashboardId == dashboard }.map(\.digest))
            result[dashboard] = ControllerCloudSyncProgressStore.display(snapshot?.entries[dashboard], signature: signature, enabled: enabled, active: active)
        }
        return .init(screenSyncEnabled: enabled, selectedWorkspaceId: selected?.localWorkspaceId == localID ? selected?.workspaceId : nil, screenSyncScreens: result)
    }
    public static func disableScreenSync(baseURL: URL, client: WorkbenchBrokerClient, machineRoot: URL) async throws {
        let root = try ControllerCloudSyncRequestStore.originRoot(baseURL: baseURL, machineRoot: machineRoot)
        let prior = (try? Data(contentsOf: root.appendingPathComponent("screen-sync-policy.json"))).flatMap { try? JSONDecoder().decode(ControllerCloudSyncPolicy.self, from: $0) }
        let policy = ControllerCloudSyncPolicy(accountId: prior?.accountId ?? "", workspaceId: prior?.workspaceId,
            localWorkspaceId: prior?.localWorkspaceId, enabled: false, epoch: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ControllerCloudPersistence.write(JSONEncoder().encode(policy), to: root.appendingPathComponent("screen-sync-policy.json"))
    }
    public func screenSyncProgress() async throws -> [String: ControllerCloudScreenSyncStatus] {
        try await Self.screenSyncProgress(baseURL: configuration.baseURL, client: client, machineRoot: root.deletingLastPathComponent().deletingLastPathComponent())
    }
    public func status() async throws -> ControllerCloudWorkbenchStatus {
        let lock = try await acquireLock(); defer { lock.close() }
        let account = try await identity(), workspaces = try await workspaceList()
        let saved = try selection()
        let currentWorkspaceId = try client.workspaceStatus().workspaceId
        let selected = saved?.accountId == account && saved?.localWorkspaceId == currentWorkspaceId && workspaces.contains(where: { $0.id == saved?.workspaceId }) ? saved?.workspaceId : nil
        try ControllerCloudCreationScope.publish(root: root, clientId: configuration.clientID, accountId: account, workspaceId: try saved.map { try syncEnabled(for: $0) } == true ? selected : nil, localWorkspaceId: currentWorkspaceId)
        let sync = try? projectSync()
        var bindings = try await sync?.bindings(accountId: account) ?? []
        if let selected, let currentWorkspaceId {
            bindings += try ControllerCloudPackageSync(root: root, session: session, client: client, accountId: account,
                workspaceId: selected, localWorkspaceId: currentWorkspaceId).bindings()
        }
        let automation = (try? Data(contentsOf: root.appendingPathComponent("automation-status.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let enabled = try saved.map { try syncEnabled(for: $0) } == true && selected != nil
        return .init(accountId: account, selectedWorkspaceId: selected, workspaces: workspaces, bindings: bindings, screenSyncEnabled: enabled, screenSyncMessage: enabled ? (automation?["message"] as? String ?? "Waiting for the first Screen sync.") : "Screen sync is off.", screenSyncScreens: try await screenSyncProgress(), automaticSyncState: enabled ? (automation?["state"] as? String ?? "pending") : "off", automaticSyncErrors: automation?["errors"] as? [String: String])
    }
    public func selectWorkspace(_ id: String, creatingLocalWorkspaceAt path: String? = nil) async throws {
        let lock = try await acquireLock(); defer { lock.close() }
        let account = try await identity(), workspaces = try await workspaceList()
        guard workspaces.contains(where: { $0.id == id }) else { throw ControllerCloudError.accountMismatch }
        var localWorkspaceId = try client.workspaceStatus().workspaceId
        if localWorkspaceId == nil, let path {
            // The Mac explicitly opts into setup. Existing content is opened only through
            // broker validation; an unrelated directory is never overwritten or migrated.
            let local = try FileManager.default.fileExists(atPath: path)
                ? client.openWorkspace(path: path) : client.initializeWorkspace(path: path)
            localWorkspaceId = local.workspaceId
        }
        guard let localWorkspaceId else { throw ControllerCloudError.invalidSource }
        try save(.init(accountId: account, workspaceId: id, localWorkspaceId: localWorkspaceId))
        _ = try await registerController(workspaceId: id)
    }
    private func context() async throws -> CloudSelection {
        let account = try await identity()
        guard let selected = try selection(), selected.accountId == account,
              let workspace = selected.workspaceId, try selected.localWorkspaceId == client.workspaceStatus().workspaceId,
              try await workspaceList().contains(where: { $0.id == workspace }) else { throw ControllerCloudError.accountMismatch }
        return selected
    }
    public func projects() async throws -> [ControllerCloudProject] {
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context()
        var projects: [ControllerCloudProject] = [], cursor: String?, seen = Set<String>()
        repeat {
            let suffix = cursor.map { "?cursor=" + $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! } ?? ""
            let page = try await session.request("/controller/v1/workspaces/\(context.workspaceId!)/projects" + suffix, as: CloudPage<ControllerCloudProject>.self)
            projects += page.items; cursor = page.nextCursor
            guard projects.count <= 10_000 else { throw ControllerCloudError.invalidResponse }
            if let cursor, !seen.insert(cursor).inserted { throw ControllerCloudError.invalidResponse }
        } while cursor != nil
        return projects
    }
    public func link(localProjectId: String, cloudProjectId: String) async throws {
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context()
        _ = try client.getProject(localProjectId)
        guard try await ControllerCloudHTTPProjects(session: session).read(workspaceId: context.workspaceId!, projectId: cloudProjectId) != nil else { throw ControllerCloudError.deletedProject }
        try await projectSync().link(accountId: context.accountId, workspaceId: context.workspaceId!, localProjectId: localProjectId, cloudProjectId: cloudProjectId)
        try await recordBinding(projectSync().status(localProjectId: localProjectId))
    }
    public func sync(localProjectId: String, choice: ControllerCloudConflictChoice? = nil) async throws -> ControllerCloudProjectBinding {
        let lock = try await acquireLock(); defer { lock.close() }
        let account = try await identity(), sync = try projectSync()
        if let choice { return try await sync.resolve(accountId: account, localProjectId: localProjectId, choice: choice) }
        return try await sync.sync(accountId: account, localProjectId: localProjectId)
    }
    public func unlink(localProjectId: String) async throws {
        let lock = try await acquireLock(); defer { lock.close() }
        let sync = try projectSync()
        let binding = try await sync.status(localProjectId: localProjectId)
        // Local explicit detachment works while signed out/offline. Server cleanup is journaled.
        let pending = root.appendingPathComponent("pending-unlinks")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(binding).write(to: pending.appendingPathComponent(localProjectId + ".json"), options: .atomic)
        try await sync.unlink(localProjectId: localProjectId)
        let creation = try intentDirectory().appendingPathComponent(localProjectId + ".json")
        if FileManager.default.fileExists(atPath: creation.path) { try FileManager.default.removeItem(at: creation) }
    }
    public func signOut() async throws {
        try await setScreenSyncEnabled(false)
        let lock = try await acquireLock(); defer { lock.close() }
        try ControllerCloudCreationScope.disconnect(root: root, clientId: configuration.clientID)
        try await session.signOut()
    }
    public func signIn(openBrowser: @Sendable (URL) async throws -> Void) async throws {
        let lock = try await acquireLock(); defer { lock.close() }
        let callback = try ControllerCloudLoopback(); defer { callback.close() }
        guard callback.redirectURI == configuration.redirectURI else { throw ControllerCloudError.invalidConfiguration }
        do {
            let request = try await session.beginAuthorization()
            try await openBrowser(request.url)
            try await session.finishAuthorization(callback: callback.callback())
            let account = try await identity()
            // Account switching clears workspace selection without touching bindings or local source.
            if try selection()?.accountId != account { try save(.init(accountId: account, workspaceId: nil, localWorkspaceId: nil)) }
            else if let selected = try selection() { try save(selected) }
        } catch {
            await session.cancelAuthorization()
            throw error
        }
    }
    /// Explicitly creates and backs up a new source Screen. Automatic discovery requires opt-in.
    public func createProject(name: String, kind: String = "html") async throws -> ControllerCloudProjectBinding {
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context(), selected = try client.workspaceStatus()
        guard let workspaceId = selected.workspaceId, let generation = selected.selectionGeneration,
              ["html", "react"].contains(kind) else { throw ControllerCloudError.invalidSource }
        let local = try client.performAuthoring(method: .projectCreate, params: [
            "schemaVersion": 1, "name": name, "kind": kind == "html" ? "web" : "react",
            "expectedWorkspaceId": workspaceId, "expectedSelectionGeneration": generation])
        guard let localId = local.project?.project.projectId else { throw ControllerCloudError.invalidResponse }
        return try await linkCreated(localId: localId, name: name, kind: kind, context: context)
    }
    /// Optional post-create hook; automatic discovery uses the same durable intent and binding.
    public func linkCreatedProjectIfConnected(localProjectId: String, name: String, kind: String) async throws -> ControllerCloudProjectBinding? {
        let lock = try await acquireLock(); defer { lock.close() }
        guard let selected = try selection(), try syncEnabled(for: selected), try selected.localWorkspaceId == client.workspaceStatus().workspaceId else { return nil }
        if let existing = try await projectSync().statusIfPresent(localProjectId: localProjectId) {
            try existing.requireAutomaticCreationScope(accountId: selected.accountId, workspaceId: selected.workspaceId)
            return existing // Includes deleted projects: never recreate or retarget an existing binding.
        }
        // Only a broker-armed creation can enter automatic synchronization.
        let capturedFile = try intentDirectory().appendingPathComponent(localProjectId + ".json")
        guard FileManager.default.fileExists(atPath: capturedFile.path) else { return nil }
        let captured = try JSONDecoder().decode(CloudNewProjectIntent.self, from: Data(contentsOf: capturedFile))
        guard captured.accountId == selected.accountId, captured.workspaceId == selected.workspaceId else { throw ControllerCloudError.accountMismatch }
        let context = try await context()
        return try await linkCreated(localId: localProjectId, name: name, kind: kind == "web" ? "html" : kind, context: context)
    }
    private func intentDirectory() throws -> URL {
        guard let workspaceId = try client.workspaceStatus().workspaceId else { throw ControllerCloudError.invalidSource }
        let directory = root.appendingPathComponent("projects/\(workspaceId)/new")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func linkCreated(localId: String, name: String, kind: String, context: CloudSelection) async throws -> ControllerCloudProjectBinding {
        guard WorkspaceValidation.id(localId), ["html", "react"].contains(kind) else { throw ControllerCloudError.invalidSource }
        let sync = try projectSync()
        if let existing = try await sync.statusIfPresent(localProjectId: localId) {
            guard existing.accountId == context.accountId else { throw ControllerCloudError.accountMismatch }
            return existing
        }
        let file = try intentDirectory().appendingPathComponent(localId + ".json")
        var intent: CloudNewProjectIntent
        if FileManager.default.fileExists(atPath: file.path) {
            intent = try JSONDecoder().decode(CloudNewProjectIntent.self, from: Data(contentsOf: file))
            guard intent.accountId == context.accountId, intent.workspaceId == context.workspaceId else { throw ControllerCloudError.accountMismatch }
        } else {
            intent = .init(accountId: context.accountId, workspaceId: context.workspaceId!, localProjectId: localId, name: name, kind: kind, idempotencyKey: UUID().uuidString, cloudProjectId: nil, requestedCloudProjectId: UUID().uuidString.lowercased())
            try ControllerCloudPersistence.write(JSONEncoder().encode(intent), to: file)
        }
        if intent.cloudProjectId == nil {
            // A legacy unacknowledged create may already exist after an ambiguous response.
            // Never turn expiry of its old idempotency window into another Cloud Screen.
            guard let requestedCloudProjectId = intent.requestedCloudProjectId else { throw ControllerCloudError.conflict }
            if intent.kitVersion == nil {
                let local = try ControllerCloudBrokerSource(client: client, scratchRoot: root.appendingPathComponent("source-transfer"))
                let snapshot = try await local.read(projectId: localId)
                guard let descriptor = snapshot.files["screenpunk.project.json"],
                      let shape = try JSONSerialization.jsonObject(with: descriptor) as? [String: Any],
                      let kitVersion = shape["kitVersion"] as? String, WorkspaceValidation.id(kitVersion) else { throw ControllerCloudError.invalidSource }
                intent.kitVersion = kitVersion
                try ControllerCloudPersistence.write(JSONEncoder().encode(intent), to: file)
            }
            let body = try JSONSerialization.data(withJSONObject: ["name": intent.name, "sourceKind": intent.kind, "projectId": requestedCloudProjectId,
                "idempotencyKey": intent.idempotencyKey, "kitVersion": intent.kitVersion!])
            let cloud = try await session.request("/controller/v1/workspaces/\(intent.workspaceId)/projects", method: "POST", body: body, as: ControllerCloudProject.self)
            guard cloud.id == requestedCloudProjectId else { throw ControllerCloudError.invalidResponse }
            intent.cloudProjectId = cloud.id
            try ControllerCloudPersistence.write(JSONEncoder().encode(intent), to: file)
        }
        try await sync.link(accountId: context.accountId, workspaceId: intent.workspaceId, localProjectId: localId, cloudProjectId: intent.cloudProjectId!)
        try await recordBinding(sync.status(localProjectId: localId))
        try FileManager.default.removeItem(at: file)
        return try await sync.sync(accountId: context.accountId, localProjectId: localId)
    }
    private func persistCreatedIntent(localId: String, name: String, kind: String, context: CloudSelection) throws {
        guard WorkspaceValidation.id(localId), let cloudWorkspace = context.workspaceId,
              ["html", "react"].contains(kind) else { throw ControllerCloudError.invalidSource }
        let file = try intentDirectory().appendingPathComponent(localId + ".json")
        if !FileManager.default.fileExists(atPath: file.path) {
            let intent = CloudNewProjectIntent(accountId: context.accountId, workspaceId: cloudWorkspace, localProjectId: localId,
                name: name, kind: kind, idempotencyKey: UUID().uuidString, cloudProjectId: nil, requestedCloudProjectId: UUID().uuidString.lowercased())
            try ControllerCloudPersistence.write(JSONEncoder().encode(intent), to: file)
        }
    }
    public struct ScreenSyncRequestOutcome: Sendable {
        public let admitted: Bool
        public let completed: Bool
    }
    private struct SyncFeed: Decodable {
        struct Item: Decodable { let projectId: String; let cursor: String; let kind: String; let headVersionId: String?; let packagesChanged: Bool }
        let schemaVersion: Int; let items: [Item]; let nextCursor: String
        let highWaterCursor: String; let hasMore: Bool; let resetRequired: Bool
    }
    private struct SyncCheckpoint: Codable { let accountId: String; let workspaceId: String; let localWorkspaceId: String; let clientId: String; let cursor: String }
    public nonisolated func validateScreenSyncRequest(_ request: ControllerCloudScreenSyncRequest) throws { try requireRequest(request) }
    private nonisolated func requireRequest(_ request: ControllerCloudScreenSyncRequest) throws {
        guard let policy = try ControllerCloudSyncRequestStore(root: root).enabledScope(), policy.epoch == request.epoch,
              policy.accountId == request.accountId, policy.workspaceId == request.workspaceId,
              policy.localWorkspaceId == request.localWorkspaceId,
              try ControllerCloudSyncRequestStore(root: root).ownerClientId(policy) == configuration.clientID,
              request.clientId == configuration.clientID,
              try client.workspaceStatus().workspaceId == request.localWorkspaceId else { throw CancellationError() }
    }
    /// A durable local event admits one bounded catch-up. Hints never become accepted cursors.
    public func processScreenSyncRequest(_ request: ControllerCloudScreenSyncRequest) async throws -> ScreenSyncRequestOutcome {
        do { return try await processAdmittedScreenSyncRequest(request) }
        catch {
            // Initial admission/feed failures are visible before any transfer loop can publish its tail.
            let progress = ControllerCloudSyncProgressStore(root: root, scope: .init(accountId: request.accountId,
                workspaceId: request.workspaceId, localWorkspaceId: request.localWorkspaceId))
            if (try? requireRequest(request)) != nil {
                try publishCycle(progress: progress, epoch: request.epoch, state: "needs_attention",
                    message: "Screen sync could not finish. Your copies are preserved.")
            }
            throw error
        }
    }
    private func processAdmittedScreenSyncRequest(_ request: ControllerCloudScreenSyncRequest) async throws -> ScreenSyncRequestOutcome {
        try requireRequest(request)
        return try await ControllerCloudAutomaticSyncAuthorization.$check.withValue({ try self.requireRequest(request) }) {
            let checkpointURL = root.appendingPathComponent("screen-sync-cursor-" + configuration.clientID + ".json")
            var cursor = "0", targets = Set<String>(), removed = Set<String>()
            var full = request.requiresFullCheck
            let lock = try await acquireLock()
            let account: String
            do {
                account = try await identity()
                guard account == request.accountId else { throw ControllerCloudError.accountMismatch }
                let controller = try await registerController(workspaceId: request.workspaceId)
                try requireRequest(request)
                // The session creates the subscriber required by the first authenticated feed read.
                _ = try await admittedRealtimeSession(request, controllerId: controller, renew: false)
                if let bytes = try? Data(contentsOf: checkpointURL), bytes.count <= 4096,
                   let saved = try? JSONDecoder().decode(SyncCheckpoint.self, from: bytes), saved.accountId == account,
                   saved.workspaceId == request.workspaceId, saved.localWorkspaceId == request.localWorkspaceId,
                   saved.clientId == request.clientId, Int64(saved.cursor) != nil { cursor = saved.cursor }
                var complete = false
                for _ in 0..<100 {
                    let feed = try await session.request("/controller/v1/workspaces/\(request.workspaceId)/connections/\(controller)/changes?after=\(cursor)&limit=100", as: SyncFeed.self)
                    guard feed.schemaVersion == 1, feed.items.count <= 100,
                          let next = Int64(feed.nextCursor), let old = Int64(cursor), next >= old,
                          let high = Int64(feed.highWaterCursor), high >= next else { throw ControllerCloudError.invalidResponse }
                    if feed.resetRequired { guard feed.items.isEmpty, !feed.hasMore else { throw ControllerCloudError.invalidResponse }; full = true }
                    for item in feed.items {
                        guard UUID(uuidString: item.projectId) != nil, let position = Int64(item.cursor), position > old, position <= next,
                              ["upsert", "remove"].contains(item.kind), item.headVersionId == nil || UUID(uuidString: item.headVersionId!) != nil else { throw ControllerCloudError.invalidResponse }
                        if item.kind == "remove" { removed.insert(item.projectId); targets.remove(item.projectId) }
                        else { targets.insert(item.projectId); removed.remove(item.projectId) }
                    }
                    cursor = feed.nextCursor
                    if !feed.hasMore { complete = true; break }
                    guard next > old else { throw ControllerCloudError.invalidResponse }
                }
                guard complete else { throw ControllerCloudError.sourceLimitExceeded }
                let sync = try projectSync()
                try await sync.remoteEligibility(accountId: account, workspaceId: request.workspaceId, cloudProjectIds: removed, admitted: false)
                let progress = ControllerCloudSyncProgressStore(root: root, scope: .init(accountId: account, workspaceId: request.workspaceId, localWorkspaceId: request.localWorkspaceId))
                let visible = try client.listProjects()
                for binding in try await sync.bindings(accountId: account) where removed.contains(binding.cloudProjectId) {
                    if let local = visible.first(where: { $0.projectId == binding.localProjectId }) {
                        let current = try? client.performAuthoring(method: .projectInspect, params: ["schemaVersion": 1, "projectId": local.projectId]).project?.sourceVersion
                        try progress.screen(local.dashboardId, state: "error", signature: current ?? nil)
                    }
                }
                try ControllerCloudPackageSync(root: root, session: session, client: client, accountId: account,
                    workspaceId: request.workspaceId, localWorkspaceId: request.localWorkspaceId).markUnavailable(cloudProjectIds: removed)
                // Only a fresh admitted nonempty source head can re-enable an unavailable source binding.
                for project in try await discoverCloudProjects(workspaceId: request.workspaceId, projectIds: targets) where project.headVersionId != nil {
                    try await sync.remoteEligibility(accountId: account, workspaceId: request.workspaceId, cloudProjectIds: [project.id], admitted: true)
                }
                try requireRequest(request)
                lock.close()
            } catch { lock.close(); throw error }
            let success = try await runAutomaticSync(cloudProjectIds: full ? nil : targets,
                localDashboardIds: full ? nil : Set(request.dashboardIds), admittedAccount: account)
            guard success else { return ScreenSyncRequestOutcome(admitted: true, completed: false) }
            try requireRequest(request)
            let commitLock = try await acquireLock(); defer { commitLock.close() }
            try requireRequest(request)
            try ControllerCloudPersistence.write(JSONEncoder().encode(SyncCheckpoint(accountId: account, workspaceId: request.workspaceId,
                localWorkspaceId: request.localWorkspaceId, clientId: request.clientId, cursor: cursor)), to: checkpointURL)
            return ScreenSyncRequestOutcome(admitted: true, completed: true)
        }
    }
    /// The service prepares and starts its listener before potentially long catch-up work.
    /// Admission is tied to this request's exact scope, never a later queued request.
    public func prepareScreenSyncSession(_ request: ControllerCloudScreenSyncRequest, renew: Bool = false) async throws -> ControllerCloudRealtimeSession {
        try requireRequest(request)
        return try await ControllerCloudAutomaticSyncAuthorization.$check.withValue({ try self.requireRequest(request) }) {
            let lock = try await acquireLock(); defer { lock.close() }
            guard try await identity() == request.accountId else { throw ControllerCloudError.accountMismatch }
            let controller = try await registerController(workspaceId: request.workspaceId)
            try requireRequest(request)
            return try await admittedRealtimeSession(request, controllerId: controller, renew: renew)
        }
    }
    /// Caller holds the admitted session lock. Bootstrap credentials stay in memory and are
    /// handed unchanged to the single listener; wake/session cursors never become checkpoints.
    private func admittedRealtimeSession(_ request: ControllerCloudScreenSyncRequest, controllerId: String,
                                          renew: Bool) async throws -> ControllerCloudRealtimeSession {
        try requireRequest(request)
        if !renew, let cached = realtimeBootstrap,
           cached.controllerId == controllerId, cached.request.epoch == request.epoch,
           cached.request.accountId == request.accountId, cached.request.workspaceId == request.workspaceId,
           cached.request.clientId == request.clientId, cached.request.localWorkspaceId == request.localWorkspaceId,
           (try? cached.session.validate(now: Date())) != nil {
            try requireRequest(request)
            return cached.session
        }
        let fresh = try await session.request("/controller/v1/workspaces/\(request.workspaceId)/connections/\(controllerId)/realtime/session",
            method: "POST", body: Data("{}".utf8), as: ControllerCloudRealtimeSession.self)
        try requireRequest(request)
        try fresh.validate(now: Date())
        realtimeBootstrap = (request: request, controllerId: controllerId, session: fresh)
        return fresh
    }
    /// Bounded background cycle. It uploads/downloads source only and never builds or deploys.
    public func automaticSync() async throws { _ = try await runAutomaticSync() }
    private func runAutomaticSync(cloudProjectIds: Set<String>? = nil, localDashboardIds: Set<String>? = nil, admittedAccount: String? = nil) async throws -> Bool {
        guard let selected = try selection(), try syncEnabled(for: selected), let approved = try policy(),
              try ControllerCloudSyncRequestStore(root: root).ownerClientId(approved) == configuration.clientID else { return false }
        let policyURL = root.appendingPathComponent("screen-sync-policy.json"), client = self.client
        guard let workspace = selected.workspaceId, let localID = selected.localWorkspaceId else { return false }
        let progress = ControllerCloudSyncProgressStore(root: root, scope: .init(accountId: selected.accountId, workspaceId: workspace, localWorkspaceId: localID))
        do { return try await ControllerCloudAutomaticSyncAuthorization.$check.withValue({
            let current = try JSONDecoder().decode(ControllerCloudSyncPolicy.self, from: Data(contentsOf: policyURL))
            let selected = try JSONDecoder().decode(CloudSelection.self, from: Data(contentsOf: policyURL.deletingLastPathComponent().appendingPathComponent("selection.json")))
            guard current.enabled, current.epoch == approved.epoch,
                  selected.accountId == approved.accountId, selected.workspaceId == approved.workspaceId,
                  selected.localWorkspaceId == approved.localWorkspaceId,
                  try client.workspaceStatus().workspaceId == approved.localWorkspaceId else { throw CancellationError() }
        }) { try await automaticSyncEnabled(progress: progress, epoch: approved.epoch, cloudProjectIds: cloudProjectIds,
            localDashboardIds: localDashboardIds, admittedAccount: admittedAccount) } }
        catch is CancellationError {
            try publishCycle(progress: progress, epoch: approved.epoch, state: "pending", message: "Screen sync stopped. Your copies are preserved.")
            throw CancellationError()
        } catch {
            try publishCycle(progress: progress, epoch: approved.epoch, state: "needs_attention", message: "Screen sync could not finish. Your copies are preserved.")
            throw error
        }
    }
    private func publishCycle(progress: ControllerCloudSyncProgressStore, epoch: String, state: String, message: String, errors: [String: String] = [:]) throws {
        try progress.cycle(state == "running" ? "syncing" : state == "needs_attention" ? "error" : state, message: message, epoch: epoch)
        let value: [String: Any] = ["schemaVersion": 1, "state": state, "message": message,
            "checkedAt": ControllerCloudSyncProgressStore.now, "errors": errors]
        try ControllerCloudPersistence.write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: root.appendingPathComponent("automation-status.json"))
    }
    private func automaticSyncEnabled(progress: ControllerCloudSyncProgressStore, epoch: String, cloudProjectIds: Set<String>?, localDashboardIds: Set<String>?, admittedAccount: String?) async throws -> Bool {
        try ControllerCloudAutomaticSyncAuthorization.requireConsent()
        let lock = try await acquireLock(); defer { lock.close() }
        try publishCycle(progress: progress, epoch: epoch, state: "running", message: "Checking Screens for changes…")
        let account: String
        if let admittedAccount { account = admittedAccount } else { account = try await identity() }
        let sync = try projectSync()
        guard let scope = try selection(), scope.accountId == account, try syncEnabled(for: scope),
              try scope.localWorkspaceId == client.workspaceStatus().workspaceId else {
            try publishCycle(progress: progress, epoch: epoch, state: "pending", message: "Screen sync is waiting for its connected workspace.")
            return false
        }
        var errors: [String: String] = [:]
        let unlinks = root.appendingPathComponent("pending-unlinks")
        if FileManager.default.fileExists(atPath: unlinks.path) {
            for file in try FileManager.default.contentsOfDirectory(at: unlinks, includingPropertiesForKeys: nil).prefix(250) {
                let binding = try JSONDecoder().decode(ControllerCloudProjectBinding.self, from: Data(contentsOf: file))
                if binding.accountId == account { try await recordBinding(binding, removing: true); try FileManager.default.removeItem(at: file) }
            }
        }
        let importsRoot = root.appendingPathComponent("projects/\(scope.localWorkspaceId!)/imports")
        var importedLocalIDs = Set<String>()
        if let files = FileManager.default.enumerator(at: importsRoot, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension == "json" {
                importedLocalIDs.insert(try JSONDecoder().decode(LocalImportIntent.self, from: Data(contentsOf: file)).localProjectId)
            }
        }
        let visibleProjects = try client.listProjects()
        let visibleIDs = Set(visibleProjects.map(\.projectId))
        for project in visibleProjects where localDashboardIds == nil || localDashboardIds!.contains(project.dashboardId) {
            try ControllerCloudAutomaticSyncAuthorization.requireConsent()
            let existing = try await sync.statusIfPresent(localProjectId: project.projectId)
            let suppressed = try await sync.isSuppressed(localProjectId: project.projectId)
            if importedLocalIDs.contains(project.projectId) || existing != nil || suppressed { continue }
            do {
                try progress.screen(project.dashboardId, state: "syncing")
                let local = try ControllerCloudBrokerSource(client: client, scratchRoot: root.appendingPathComponent("source-transfer"))
                let snapshot = try await local.read(projectId: project.projectId)
                guard let descriptor = snapshot.files["screenpunk.project.json"],
                      let shape = try JSONSerialization.jsonObject(with: descriptor) as? [String: Any],
                      let kind = shape["kind"] as? String else { throw ControllerCloudError.invalidSource }
                try progress.screen(project.dashboardId, state: "syncing", signature: snapshot.revision)
                try persistCreatedIntent(localId: project.projectId, name: project.name, kind: kind == "web" ? "html" : kind, context: scope)
            } catch {
                try progress.screen(project.dashboardId, state: "error", resourceLimited: error as? ControllerCloudError == .resourceLimit)
                errors[project.projectId] = "Screen sync paused. Your copies are preserved."
            }
        }
        if let selected = try selection(), selected.accountId == account,
           try selected.localWorkspaceId == client.workspaceStatus().workspaceId {
            let directory = try intentDirectory()
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }).prefix(250) {
                let intent = try JSONDecoder().decode(CloudNewProjectIntent.self, from: Data(contentsOf: file))
                if intent.accountId == account && intent.workspaceId == selected.workspaceId && visibleIDs.contains(intent.localProjectId) &&
                   (localDashboardIds == nil || visibleProjects.contains(where: { $0.projectId == intent.localProjectId && localDashboardIds!.contains($0.dashboardId) })) {
                    do {
                        if let project = visibleProjects.first(where: { $0.projectId == intent.localProjectId }) { try progress.screen(project.dashboardId, state: "syncing") }
                        let result = try await linkCreated(localId: intent.localProjectId, name: intent.name, kind: intent.kind, context: selected)
                        try recordProgress(result, projects: visibleProjects, progress: progress)
                    }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        if let project = visibleProjects.first(where: { $0.projectId == intent.localProjectId }) { try progress.screen(project.dashboardId, state: "error", resourceLimited: error as? ControllerCloudError == .resourceLimit) }
                        errors[intent.localProjectId] = "Screen sync paused. Your copies are preserved."
                    }
                }
            }
        }
        let bindings = try await sync.bindings(accountId: account)
        for binding in bindings.prefix(250) where binding.workspaceId == scope.workspaceId && binding.status != .conflict && binding.status != .deleted && binding.status != .unavailable {
            if cloudProjectIds != nil && !cloudProjectIds!.contains(binding.cloudProjectId) &&
               !visibleProjects.contains(where: { $0.projectId == binding.localProjectId && localDashboardIds?.contains($0.dashboardId) == true }) { continue }
            try ControllerCloudAutomaticSyncAuthorization.requireConsent()
            guard visibleIDs.contains(binding.localProjectId) else { continue }
            do {
                if let project = visibleProjects.first(where: { $0.projectId == binding.localProjectId }) {
                    let inspected = try client.performAuthoring(method: .projectInspect, params: ["schemaVersion": 1, "projectId": project.projectId])
                    try progress.screen(project.dashboardId, state: "syncing", signature: inspected.project?.sourceVersion)
                }
                try await recordBinding(binding)
                let result = try await sync.sync(accountId: account, localProjectId: binding.localProjectId)
                try recordProgress(result, projects: visibleProjects, progress: progress)
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                if let project = visibleProjects.first(where: { $0.projectId == binding.localProjectId }) { try progress.screen(project.dashboardId, state: "error", resourceLimited: error as? ControllerCloudError == .resourceLimit) }
                errors[binding.localProjectId] = "Screen sync paused. Your copies are preserved."
            }
        }
        let sourceKnown = try await sync.allBindings() + (try await sync.suppressedBindings())
        let packageSync = ControllerCloudPackageSync(root: root, session: session, client: client, accountId: account,
            workspaceId: scope.workspaceId!, localWorkspaceId: scope.localWorkspaceId!)
        let known = sourceKnown + (try packageSync.discoveryBindings())
        let cloudProjects = try await discoverCloudProjects(workspaceId: scope.workspaceId!, projectIds: cloudProjectIds)
        for cloud in cloudProjects where ["html", "react"].contains(cloud.sourceKind) && cloud.headVersionId != nil && !known.contains(where: { $0.workspaceId == scope.workspaceId && $0.cloudProjectId == cloud.id }) {
            try ControllerCloudAutomaticSyncAuthorization.requireConsent()
            do {
                let result = try await restoreDiscovered(cloud: cloud, context: scope, progress: progress)
                try recordProgress(result, projects: client.listProjects(), progress: progress)
            }
            catch is CancellationError { throw CancellationError() }
            catch { errors[cloud.id] = "Screen sync paused. Your copies are preserved." }
        }
        try updatePackageProgress(progress: progress, phase: "syncing")
        var packageResourceLimited = false
        do {
            let currentSourceBindings = try await sync.allBindings() + (try await sync.suppressedBindings())
            try await packageSync.synchronize(cloud: cloudProjects, sourceBindings: currentSourceBindings,
                sourceDashboardIds: Set(try client.listProjects().map(\.dashboardId)), cloudProjectIds: cloudProjectIds, localDashboardIds: localDashboardIds)
        } catch is CancellationError { throw CancellationError() }
        catch {
            packageResourceLimited = error as? ControllerCloudError == .resourceLimit
            errors["packages"] = packageResourceLimited ? ControllerCloudSyncProgressStore.quotaMessage : "Some package Screens could not sync. Your copies are preserved."
        }
        try updatePackageProgress(progress: progress, phase: errors["packages"] == nil ? "synced" : "error", resourceLimited: packageResourceLimited)
        for binding in bindings where binding.status == .conflict {
            if cloudProjectIds == nil || cloudProjectIds!.contains(binding.cloudProjectId) ||
               visibleProjects.contains(where: { $0.projectId == binding.localProjectId && localDashboardIds?.contains($0.dashboardId) == true }) {
                errors[binding.localProjectId] = "Both Screen versions are preserved because they changed independently."
            }
        }
        try ControllerCloudAutomaticSyncAuthorization.requireConsent()
        try publishCycle(progress: progress, epoch: epoch, state: errors.isEmpty ? "idle" : "needs_attention",
            message: errors.isEmpty ? "Screen sync check completed." : "Some Screens could not sync. Your copies are preserved.", errors: errors)
        return errors.isEmpty
    }
    private func recordProgress(_ binding: ControllerCloudProjectBinding, projects: [WorkspaceProject], progress: ControllerCloudSyncProgressStore) throws {
        try ControllerCloudAutomaticSyncAuthorization.requireConsent()
        guard let project = projects.first(where: { $0.projectId == binding.localProjectId }) else { return }
        try progress.screen(project.dashboardId, state: binding.status == .synced ? "synced" : binding.status == .conflict || binding.status == .deleted ? "error" : "pending",
            signature: binding.localRevision, acknowledge: binding.status == .synced)
    }
    private struct PackageProgressEvidence: Decodable {
        let binding: ControllerCloudProjectBinding
        let dashboardId: String
        let uploadedDigests: Set<String>
        let retiredForSource: Bool?
    }
    private func updatePackageProgress(progress: ControllerCloudSyncProgressStore, phase: String, resourceLimited: Bool = false) throws {
        try ControllerCloudAutomaticSyncAuthorization.requireConsent()
        let selected = try client.workspaceStatus()
        let packages = try client.listWorkspacePackages(in: selected)
        let sources = Set(try client.listProjects().map(\.dashboardId))
        let directory = root.appendingPathComponent("projects/\(progress.scope.localWorkspaceId)/packages")
        var evidence: [String: PackageProgressEvidence] = [:]
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension == "json" {
                let row = try JSONDecoder().decode(PackageProgressEvidence.self, from: Data(contentsOf: file))
                if row.binding.accountId == progress.scope.accountId && row.binding.workspaceId == progress.scope.workspaceId && row.retiredForSource != true { evidence[row.dashboardId] = row }
            }
        }
        for dashboard in Set(packages.map(\.dashboardId)).subtracting(sources) {
            let digests = packages.filter { $0.dashboardId == dashboard }.map(\.digest)
            let signature = ControllerCloudSyncProgressStore.signature(digests)
            let acknowledged = evidence[dashboard].map { $0.binding.status == .synced && Set(digests).isSubset(of: $0.uploadedDigests) } ?? false
            if let row = evidence[dashboard], [.unavailable, .deleted, .conflict].contains(row.binding.status) {
                try progress.screen(dashboard, state: "error", signature: signature)
                continue
            }
            let existing = try progress.read().entries[dashboard]
            let newlyAcknowledged = acknowledged && existing?.acknowledgedSignature != signature
            try ControllerCloudAutomaticSyncAuthorization.requireConsent()
            try progress.screen(dashboard, state: phase == "syncing" ? "syncing" : acknowledged && (phase != "error" || newlyAcknowledged) ? "synced" : phase == "error" ? "error" : "pending",
                signature: signature, acknowledge: phase != "syncing" && acknowledged && (phase != "error" || newlyAcknowledged), resourceLimited: resourceLimited && !acknowledged)
        }
    }
    public func reviewDeployment(publicationId: String, installationId: String, operationId: String = UUID().uuidString.lowercased(), removeEntryIds: [String] = []) async throws -> ControllerCloudDeploymentReview {
        guard ControllerCloudDeploymentReview.removeEntryIdsMatchCloudContract(removeEntryIds) else { throw ControllerCloudError.invalidRemoveEntryIds }
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context()
        guard [publicationId, installationId, operationId].allSatisfy({ UUID(uuidString: $0) != nil }) else { throw ControllerCloudError.invalidSource }
        let body = try JSONSerialization.data(withJSONObject: ["publicationId": publicationId, "installationId": installationId, "operationId": operationId, "removeEntryIds": removeEntryIds])
        let review = try await session.request("/controller/v1/workspaces/\(context.workspaceId!)/deployments/review", method: "POST", body: body, as: ControllerCloudDeploymentReview.self)
        try review.validate()
        guard review.publicationId == publicationId, review.installationId == installationId,
              review.operationId == operationId, review.removeEntryIds == removeEntryIds else { throw ControllerCloudError.invalidResponse }
        return review
    }
    public func installations() async throws -> [ControllerCloudInstallation] {
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context()
        let page = try await session.request("/controller/v1/workspaces/\(context.workspaceId!)/installations", as: CloudPage<ControllerCloudInstallation>.self)
        guard page.nextCursor == nil else { throw ControllerCloudError.invalidResponse }; return page.items
    }
    public func publications() async throws -> [ControllerCloudPublication] {
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context()
        let page = try await session.request("/controller/v1/workspaces/\(context.workspaceId!)/publications", as: CloudPage<ControllerCloudPublication>.self)
        guard page.nextCursor == nil else { throw ControllerCloudError.invalidResponse }; return page.items
    }
    public func publishLocalBuild(localProjectId: String) async throws -> ControllerCloudPublication {
        let lock = try await acquireLock(); defer { lock.close() }
        let account = try await identity(), sync = try projectSync(), selected = try client.workspaceStatus()
        guard let workspaceId = selected.workspaceId, let generation = selected.selectionGeneration else { throw ControllerCloudError.invalidSource }
        let binding = try await sync.status(localProjectId: localProjectId)
        guard binding.accountId == account else { throw ControllerCloudError.accountMismatch }
        let params: [String: Any] = ["schemaVersion": 1, "projectId": localProjectId, "expectedWorkspaceId": workspaceId, "expectedSelectionGeneration": generation]
        let head = try client.performAuthoring(method: .buildHead, params: params)
        guard let build = head.build else { throw ControllerCloudError.invalidSource }
        // Associate source only when the synced snapshot is the build's exact source revision.
        let sourceVersion: Any = binding.localRevision == build.sourceVersion ? (binding.cloudRevision.map { $0 as Any } ?? NSNull()) : NSNull()
        let scratch = root.appendingPathComponent("package-transfer")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = scratch.appendingPathComponent("export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let export = try client.performAuthoring(method: .packageExport, params: [
            "schemaVersion": 1, "dashboardId": build.dashboardId, "revision": build.revision, "path": output.path,
            "expectedWorkspaceId": workspaceId, "expectedSelectionGeneration": generation])
        guard export.packageExport?.path == output.path, export.packageExport?.digest == build.digest else { throw ControllerCloudError.invalidResponse }
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(contentsOf: output.appendingPathComponent("manifest.json")))
        var files: [String: Data] = [:]
        for file in manifest.files {
            guard WorkspaceValidation.member(file.path) else { throw ControllerCloudError.invalidSource }
            files[file.path] = try Data(contentsOf: output.appendingPathComponent("files/" + file.path))
        }
        let archive = try ControllerCloudNativeArchive.encode(manifest: manifest, files: files)
        struct Package: Decodable, Sendable { let id: String }
        let key = "local-build-" + localProjectId + "-" + build.digest
        let toolchain = build.selectedToolchain.map { ["name": $0.catalogEntryId, "version": $0.kitVersion] }
            ?? ["name": "Screenpunk built-in HTML packager", "version": "1"]
        let body = try JSONSerialization.data(withJSONObject: ["sourceVersionId": sourceVersion, "idempotencyKey": key,
            "data": archive.base64EncodedString(), "toolchain": toolchain])
        let package = try await session.request("/controller/v1/workspaces/\(binding.workspaceId)/projects/\(binding.cloudProjectId)/packages/import", method: "POST", body: body, as: Package.self)
        guard UUID(uuidString: package.id) != nil else { throw ControllerCloudError.invalidResponse }
        // Stable explicit publication identity permits safely retrying a lost publication response.
        let publicationFile = scratch.appendingPathComponent(build.digest + "-publication.json")
        struct PublicationIdentity: Codable { let id: String }
        let publicationId: String
        if FileManager.default.fileExists(atPath: publicationFile.path) { publicationId = try JSONDecoder().decode(PublicationIdentity.self, from: Data(contentsOf: publicationFile)).id }
        else { publicationId = UUID().uuidString.lowercased(); try JSONEncoder().encode(PublicationIdentity(id: publicationId)).write(to: publicationFile, options: .atomic) }
        let publicationBody = try JSONSerialization.data(withJSONObject: ["publicationId": publicationId, "projectId": binding.cloudProjectId, "packageId": package.id, "locationId": NSNull()])
        _ = try await session.request("/controller/v1/workspaces/\(binding.workspaceId)/publications", method: "POST", body: publicationBody, as: ControllerCloudJSON.self)
        return .init(id: publicationId, name: manifest.name, locationId: nil)
    }
    public func applyDeployment(_ review: ControllerCloudDeploymentReview) async throws -> ControllerCloudJSON {
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context(); try review.validate()
        // Submit the frozen reviewed generation. Server CAS rejects changes; never refresh/rebase here.
        do {
            let result = try await session.request("/controller/v1/workspaces/\(context.workspaceId!)/deployments/apply", method: "POST", body: JSONEncoder().encode(review), as: ControllerCloudJSON.self)
            try? await relayApprovedArchives(review, workspaceId: context.workspaceId!)
            return result
        } catch {
            // A lost response can follow approval. The export endpoint and device
            // independently verify this exact operation before any archive is accepted.
            try? await relayApprovedArchives(review, workspaceId: context.workspaceId!)
            throw error
        }
    }
    private func relayApprovedArchives(_ review: ControllerCloudDeploymentReview, workspaceId: String) async throws {
        let devices = try client.listDevices(timeout: 0.5)
        var matched = devices.first(where: { ControllerCloudDeviceIdentity.matches(local: $0, installationId: review.installationId) })
        if matched == nil {
            // New pairings have no installation proof in unauthenticated hello.
            // Probe a bounded set of recently used approved peers; never match names.
            for candidate in devices.filter({ $0.ownerMatchesCurrent }).sorted(by: { ($0.lastSeenAt ?? "") > ($1.lastSeenAt ?? "") }).prefix(12) {
                guard let fresh = try? client.deviceStatus(candidate.deviceId, refresh: true) else { continue }
                if ControllerCloudDeviceIdentity.matches(local: fresh, installationId: review.installationId) { matched = fresh; break }
            }
        }
        guard let device = matched else { return }
        guard case .object(let set) = review.resultingSet, case .array(let entries)? = set["entries"] else { throw ControllerCloudError.invalidResponse }
        var packages = Set<String>()
        for entry in entries {
            guard case .object(let entry) = entry, case .object(let provenance)? = entry["provenance"],
                  provenance["kind"] == .string("cloud"), case .object(let package)? = provenance["package"],
                  package["publicationId"] == .string(review.publicationId) else { continue }
            guard case .string(let projectId)? = package["projectId"], case .string(let packageId)? = package["packageId"],
                  case .string(let hash)? = package["archiveSha256"], case .integer(let count)? = package["compressedBytes"],
                  UUID(uuidString: projectId) != nil, UUID(uuidString: packageId) != nil,
                  WorkspaceValidation.sha256(hash), count > 0, count <= 25 * 1024 * 1024 else { throw ControllerCloudError.invalidResponse }
            guard packages.insert(packageId).inserted else { continue }
            let path = "/controller/v1/workspaces/\(workspaceId)/projects/\(projectId)/deployments/\(review.operationId)/packages/\(packageId)/archive"
            let archive = try await session.request(path, as: ControllerCloudApprovedArchive.self)
            let bytes = try archive.validatedBytes(operationId: review.operationId, installationId: review.installationId,
                packageId: packageId, sha256: hash, byteCount: Int(count))
            let stage = root.appendingPathComponent("archive-relay/" + UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: stage) }
            try bytes.write(to: stage.appendingPathComponent("archive.zip"), options: .atomic)
            // Only exact approved bytes cross LAN. The device requalifies them
            // against its fixed Cloud plan; this receipt does not establish activation.
            try client.relayCloudArchive(deviceId: device.deviceId, installationId: review.installationId,
                operationId: review.operationId, packageId: packageId, archiveSha256: hash, stagedPath: stage.path)
        }
        try? client.relayCloudCommand(deviceId: device.deviceId, installationId: review.installationId, operationId: review.operationId)
    }
    public func deviceStatus(installationId: String) async throws -> ControllerCloudJSON {
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context()
        guard UUID(uuidString: installationId) != nil else { throw ControllerCloudError.invalidSource }
        return try await session.request("/controller/v1/workspaces/\(context.workspaceId!)/installations/\(installationId)/status", as: ControllerCloudJSON.self)
    }
    public func invokeService(localProjectId: String, invocationId: UUID, bindingId: UUID,
                              operation: String, input: String) async throws -> Data {
        do {
        let lock = try await acquireLock(); defer { lock.close() }
        let account = try await identity(), sync = try projectSync()
        let binding = try await sync.status(localProjectId: localProjectId)
        guard binding.accountId == account, binding.status != .deleted,
              !operation.isEmpty, operation.utf8.count <= 128, input.utf8.count <= 32_768 else { throw ControllerCloudError.accountMismatch }
        let body = try JSONSerialization.data(withJSONObject: ["invocationId": invocationId.uuidString.lowercased(),
            "bindingId": bindingId.uuidString.lowercased(), "projectId": binding.cloudProjectId,
            "operation": operation, "input": operation == "weather.read" ? ["location": input] : ["prompt": input]])
        let response = try await session.request("/v1/accounts/\(binding.workspaceId)/services/invocations", method: "POST", body: body, as: ControllerCloudJSON.self)
        return try JSONEncoder().encode(response)
        } catch {
            let state: String
            switch error {
            case is CancellationError: state = "service_disconnected"
            case let error as URLError where error.code == .cancelled: state = "service_disconnected"
            case is URLError: state = "service_offline"
            case ControllerCloudError.http(429): state = "service_quota_exhausted"
            case ControllerCloudError.http(401), ControllerCloudError.http(403),
                 ControllerCloudError.signedOut, ControllerCloudError.accountMismatch: state = "service_disconnected"
            default: state = "service_unavailable"
            }
            throw ControllerCloudServiceState(state: state)
        }
    }

    private func discoverCloudProjects(workspaceId: String, projectIds: Set<String>? = nil) async throws -> [ControllerCloudProject] {
        if let projectIds {
            var result: [ControllerCloudProject] = []
            for id in projectIds.sorted() {
                guard UUID(uuidString: id) != nil else { throw ControllerCloudError.invalidResponse }
                do { result.append(try await session.request("/controller/v1/workspaces/\(workspaceId)/projects/\(id)", as: ControllerCloudProject.self)) }
                catch ControllerCloudError.http(404) { continue }
            }
            return result
        }
        var result: [ControllerCloudProject] = [], cursor: String?, seen = Set<String>()
        repeat {
            let suffix = cursor.map { "?cursor=" + $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! } ?? ""
            let page = try await session.request("/controller/v1/workspaces/\(workspaceId)/projects" + suffix, as: CloudPage<ControllerCloudProject>.self)
            result += page.items; cursor = page.nextCursor
            guard result.count <= 10_000 else { throw ControllerCloudError.invalidResponse }
            if let cursor, !seen.insert(cursor).inserted { throw ControllerCloudError.invalidResponse }
        } while cursor != nil
        return result
    }
    public func restore(cloudProjectId: String, name: String) async throws -> ControllerCloudProjectBinding {
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context()
        guard UUID(uuidString: cloudProjectId) != nil else { throw ControllerCloudError.invalidSource }
        let cloud = try await session.request("/controller/v1/workspaces/\(context.workspaceId!)/projects/\(cloudProjectId)", as: ControllerCloudProject.self)
        return try await restoreDiscovered(cloud: cloud, context: context, name: name)
    }
    private struct LocalImportIntent: Codable {
        let cloudProjectId: String
        let localProjectId: String
        let dashboardId: String
        let name: String
    }
    private func restoreDiscovered(cloud: ControllerCloudProject, context: CloudSelection, name: String? = nil, progress: ControllerCloudSyncProgressStore? = nil) async throws -> ControllerCloudProjectBinding {
        guard UUID(uuidString: cloud.id) != nil, ["html", "react"].contains(cloud.sourceKind), cloud.headVersionId != nil else { throw ControllerCloudError.invalidSource }
        let selected = try client.workspaceStatus()
        guard let workspaceId = selected.workspaceId, workspaceId == context.localWorkspaceId,
              let generation = selected.selectionGeneration else { throw ControllerCloudError.accountMismatch }
        let directory = root.appendingPathComponent("projects/\(workspaceId)/imports/\(context.workspaceId!)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(cloud.id + ".json")
        let intent: LocalImportIntent
        if FileManager.default.fileExists(atPath: file.path) { intent = try JSONDecoder().decode(LocalImportIntent.self, from: Data(contentsOf: file)) }
        else {
            intent = .init(cloudProjectId: cloud.id, localProjectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(), name: name ?? cloud.name)
            try ControllerCloudPersistence.write(JSONEncoder().encode(intent), to: file)
        }
        guard intent.cloudProjectId == cloud.id else { throw ControllerCloudError.conflict }
        let sync = try projectSync()
        if let bound = try await sync.statusIfPresent(localProjectId: intent.localProjectId) { return bound }
        let snapshotFile = directory.appendingPathComponent(cloud.id + ".snapshot")
        let snapshot: ControllerCloudSourceSnapshot
        if FileManager.default.fileExists(atPath: snapshotFile.path) { snapshot = try JSONDecoder().decode(ControllerCloudSourceSnapshot.self, from: Data(contentsOf: snapshotFile)) }
        else {
            guard let remote = try await ControllerCloudHTTPProjects(session: session).read(workspaceId: context.workspaceId!, projectId: cloud.id) else { throw ControllerCloudError.deletedProject }
            snapshot = remote
            try ControllerCloudPersistence.write(JSONEncoder().encode(snapshot), to: snapshotFile)
        }
        let projectionStore = ControllerCloudCanonicalSourceStore(root: root.appendingPathComponent("projects/\(workspaceId)/source-projections"))
        let localSnapshot: ControllerCloudSourceSnapshot
        if snapshot.files["screenpunk.project.json"] == nil {
            let record = ControllerCloudCanonicalSourceStore.Record(schemaVersion: 1,
                localWorkspaceId: workspaceId, cloudWorkspaceId: context.workspaceId!, cloudProjectId: cloud.id,
                localProjectId: intent.localProjectId, dashboardId: intent.dashboardId, name: intent.name,
                sourceKind: cloud.sourceKind)
            localSnapshot = try projectionStore.prepare(record, snapshot: snapshot)
        } else {
            // A format change cannot silently retarget an existing canonical projection.
            guard try projectionStore.read(intent.localProjectId) == nil else { throw ControllerCloudError.conflict }
            localSnapshot = snapshot
        }
        let staging = directory.appendingPathComponent(intent.localProjectId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(localSnapshot).write(to: staging.appendingPathComponent("snapshot.json"), options: .atomic)
        defer { try? FileManager.default.removeItem(at: staging) }
        try ControllerCloudAutomaticSyncAuthorization.requireConsent()
        let created = try client.performAuthoring(method: .cloudProjectCreate, params: [
            "schemaVersion": 1, "intentId": intent.localProjectId, "dashboardId": intent.dashboardId,
            "name": intent.name, "path": staging.path,
            "expectedWorkspaceId": workspaceId, "expectedSelectionGeneration": generation])
        guard let local = created.project?.project, local.projectId == intent.localProjectId,
              local.dashboardId == intent.dashboardId else { throw ControllerCloudError.invalidResponse }
        try progress?.screen(local.dashboardId, state: "syncing", signature: created.project?.sourceVersion)
        try await sync.link(accountId: context.accountId, workspaceId: context.workspaceId!, localProjectId: intent.localProjectId, cloudProjectId: cloud.id)
        try await recordBinding(sync.status(localProjectId: intent.localProjectId))
        return try await sync.sync(accountId: context.accountId, localProjectId: intent.localProjectId)
    }
    private func acquireLock() async throws -> ControllerCloudProcessLock {
        let lock = try ControllerCloudProcessLock(path: root.appendingPathComponent("session.lock").path)
        let deadline = Date().addingTimeInterval(300)
        while !lock.tryAcquire() {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ControllerCloudError.conflict }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return lock
    }
}
private final class ControllerCloudProcessLock: @unchecked Sendable {
    private var descriptor: Int32
    init(path: String) throws {
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ControllerCloudError.invalidConfiguration }
    }
    func tryAcquire() -> Bool { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }
    func close() { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}
#endif

private struct ControllerCloudServiceState: LocalizedError {
    let state: String
    var errorDescription: String? { state }
}
