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
    public let automaticSyncState: String?
    public let automaticSyncErrors: [String: String]?
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
struct CloudNewProjectIntent: Codable { let accountId: String; let workspaceId: String; let localProjectId: String; let name: String; let kind: String; let idempotencyKey: String; var cloudProjectId: String?; var kitVersion: String? = nil }

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
public struct ControllerCloudHTTPProjects: ControllerCloudProjectRemote {
    public let session: ControllerCloudSession
    public init(session: ControllerCloudSession) { self.session = session }
    private func path(_ workspace: String, _ project: String) throws -> String {
        guard UUID(uuidString: workspace) != nil, UUID(uuidString: project) != nil else {
            throw ControllerCloudError.invalidSource
        }
        return "/controller/v1/workspaces/\(workspace)/projects/\(project)"
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
                guard entry.size >= 0, entry.size <= 5 * 1024 * 1024,
                      files.count < 2_000, files[entry.path] == nil else { throw ControllerCloudError.invalidSource }
                let body = try JSONSerialization.data(withJSONObject: ["versionId": head, "path": entry.path, "encoding": "base64"])
                let read = try await session.request(prefix + "/source/read", method: "POST", body: body, as: Read.self)
                guard read.versionId == head, read.path == entry.path, read.encoding == "base64",
                      let data = Data(base64Encoded: read.data), data.count == entry.size,
                      read.size == entry.size, read.sha256 == entry.sha256,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
                    throw ControllerCloudError.invalidResponse
                }
                totalBytes += data.count
                guard totalBytes <= 25 * 1024 * 1024 else { throw ControllerCloudError.invalidSource }
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
    public init(configuration: ControllerCloudConfiguration, client: WorkbenchBrokerClient,
                machineRoot: URL, session: ControllerCloudSession? = nil) throws {
        self.configuration = configuration; self.client = client
        self.session = session ?? ControllerCloudSession(configuration: configuration,
            tokenStore: ControllerCloudKeychain(server: configuration.baseURL, clientID: configuration.clientID))
        let namespace = SHA256.hash(data: Data(configuration.baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        root = machineRoot.appendingPathComponent("cloud-controller/" + namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest: [String: Any] = ["owner": "Screenpunk controller", "project": "Screenpunk", "purpose": "Cloud bindings and recoverable source synchronization", "createdAt": ISO8601DateFormatter().string(from: Date()), "lifecycle": "active", "resourcePaths": [root.path], "keep": ["selection.json", "projects", "pending-unlinks", "package-transfer/*-publication.json", "authorization-server.json", "automation-status.json"], "disposable": ["source-transfer", "archive-relay"], "credentials": "Keychain only"]
        let manifestURL = root.appendingPathComponent("ownership.json")
        if !FileManager.default.fileExists(atPath: manifestURL.path) { try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic) }
    }
    private func selection() throws -> CloudSelection? {
        let file = root.appendingPathComponent("selection.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(CloudSelection.self, from: Data(contentsOf: file))
    }
    private func save(_ selection: CloudSelection) throws {
        let file = root.appendingPathComponent("selection.json")
        try JSONEncoder().encode(selection).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try ControllerCloudCreationScope.publish(root: root, clientId: configuration.clientID, accountId: selection.accountId, workspaceId: selection.workspaceId, localWorkspaceId: selection.localWorkspaceId)
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
            local: ControllerCloudBrokerSource(client: client, scratchRoot: root.appendingPathComponent("source-transfer")))
    }
    public func status() async throws -> ControllerCloudWorkbenchStatus {
        let lock = try await acquireLock(); defer { lock.close() }
        let account = try await identity(), workspaces = try await workspaceList()
        let saved = try selection()
        let currentWorkspaceId = try client.workspaceStatus().workspaceId
        let selected = saved?.accountId == account && saved?.localWorkspaceId == currentWorkspaceId && workspaces.contains(where: { $0.id == saved?.workspaceId }) ? saved?.workspaceId : nil
        try ControllerCloudCreationScope.publish(root: root, clientId: configuration.clientID, accountId: account, workspaceId: selected, localWorkspaceId: currentWorkspaceId)
        let sync = try? projectSync()
        let bindings = try await sync?.bindings(accountId: account) ?? []
        let automation = (try? Data(contentsOf: root.appendingPathComponent("automation-status.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return .init(accountId: account, selectedWorkspaceId: selected, workspaces: workspaces, bindings: bindings, automaticSyncState: automation?["state"] as? String, automaticSyncErrors: automation?["errors"] as? [String: String])
    }
    public func selectWorkspace(_ id: String) async throws {
        let lock = try await acquireLock(); defer { lock.close() }
        let account = try await identity(), workspaces = try await workspaceList()
        guard workspaces.contains(where: { $0.id == id }) else { throw ControllerCloudError.accountMismatch }
        guard let localWorkspaceId = try client.workspaceStatus().workspaceId else { throw ControllerCloudError.invalidSource }
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
    /// New projects created through this connected workspace are immediately linked and backed up.
    /// Existing projects require the explicit link action instead.
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
    /// Called only after an explicit source-project create in the selected connected workspace.
    /// Existing projects are never discovered and linked by the background synchronizer.
    public func linkCreatedProjectIfConnected(localProjectId: String, name: String, kind: String) async throws -> ControllerCloudProjectBinding? {
        let lock = try await acquireLock(); defer { lock.close() }
        guard let selected = try selection(), try selected.localWorkspaceId == client.workspaceStatus().workspaceId else { return nil }
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
            intent = .init(accountId: context.accountId, workspaceId: context.workspaceId!, localProjectId: localId, name: name, kind: kind, idempotencyKey: UUID().uuidString, cloudProjectId: nil)
            try JSONEncoder().encode(intent).write(to: file, options: .atomic)
        }
        if intent.cloudProjectId == nil {
            if intent.kitVersion == nil {
                let local = try ControllerCloudBrokerSource(client: client, scratchRoot: root.appendingPathComponent("source-transfer"))
                let snapshot = try await local.read(projectId: localId)
                guard let descriptor = snapshot.files["screenpunk.project.json"],
                      let shape = try JSONSerialization.jsonObject(with: descriptor) as? [String: Any],
                      let kitVersion = shape["kitVersion"] as? String, WorkspaceValidation.id(kitVersion) else { throw ControllerCloudError.invalidSource }
                intent.kitVersion = kitVersion
                try JSONEncoder().encode(intent).write(to: file, options: .atomic)
            }
            let body = try JSONSerialization.data(withJSONObject: ["name": intent.name, "sourceKind": intent.kind,
                "idempotencyKey": intent.idempotencyKey, "kitVersion": intent.kitVersion!])
            let cloud = try await session.request("/controller/v1/workspaces/\(intent.workspaceId)/projects", method: "POST", body: body, as: ControllerCloudProject.self)
            intent.cloudProjectId = cloud.id
            try JSONEncoder().encode(intent).write(to: file, options: .atomic)
        }
        try await sync.link(accountId: context.accountId, workspaceId: intent.workspaceId, localProjectId: localId, cloudProjectId: intent.cloudProjectId!)
        try await recordBinding(sync.status(localProjectId: localId))
        try FileManager.default.removeItem(at: file)
        let first = try await sync.sync(accountId: context.accountId, localProjectId: localId)
        return first.status == .conflict ? try await sync.resolve(accountId: context.accountId, localProjectId: localId, choice: .local) : first
    }
    private func persistCreatedIntent(localId: String, name: String, kind: String, context: CloudSelection) throws {
        guard WorkspaceValidation.id(localId), let cloudWorkspace = context.workspaceId,
              ["html", "react"].contains(kind) else { throw ControllerCloudError.invalidSource }
        let file = try intentDirectory().appendingPathComponent(localId + ".json")
        if !FileManager.default.fileExists(atPath: file.path) {
            let intent = CloudNewProjectIntent(accountId: context.accountId, workspaceId: cloudWorkspace, localProjectId: localId,
                name: name, kind: kind, idempotencyKey: UUID().uuidString, cloudProjectId: nil)
            try JSONEncoder().encode(intent).write(to: file, options: .atomic)
        }
    }
    /// Bounded background cycle. It uploads/downloads source only and never builds or deploys.
    public func automaticSync() async throws {
        let lock = try await acquireLock(); defer { lock.close() }
        let account = try await identity(), sync = try projectSync()
        var errors: [String: String] = [:]
        let unlinks = root.appendingPathComponent("pending-unlinks")
        if FileManager.default.fileExists(atPath: unlinks.path) {
            for file in try FileManager.default.contentsOfDirectory(at: unlinks, includingPropertiesForKeys: nil).prefix(250) {
                let binding = try JSONDecoder().decode(ControllerCloudProjectBinding.self, from: Data(contentsOf: file))
                if binding.accountId == account { try await recordBinding(binding, removing: true); try FileManager.default.removeItem(at: file) }
            }
        }
        if let selected = try selection(), selected.accountId == account,
           try selected.localWorkspaceId == client.workspaceStatus().workspaceId {
            let directory = try intentDirectory()
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }).prefix(250) {
                let intent = try JSONDecoder().decode(CloudNewProjectIntent.self, from: Data(contentsOf: file))
                if intent.accountId == account && intent.workspaceId == selected.workspaceId {
                    do { _ = try await linkCreated(localId: intent.localProjectId, name: intent.name, kind: intent.kind, context: selected) }
                    catch { errors[intent.localProjectId] = String(describing: error) }
                }
            }
        }
        let bindings = try await sync.bindings(accountId: account)
        for binding in bindings.prefix(250) where binding.status != .conflict && binding.status != .deleted {
            try Task.checkCancellation()
            do { try await recordBinding(binding); _ = try await sync.sync(accountId: account, localProjectId: binding.localProjectId) }
            catch { errors[binding.localProjectId] = String(describing: error) }
        }
        let value: [String: Any] = ["schemaVersion": 1, "state": errors.isEmpty ? "running" : "needs_attention", "checkedAt": ISO8601DateFormatter().string(from: Date()), "errors": errors]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: root.appendingPathComponent("automation-status.json"), options: .atomic)
    }
    public func reviewDeployment(publicationId: String, installationId: String, operationId: String = UUID().uuidString.lowercased(), removeEntryIds: [String] = []) async throws -> ControllerCloudDeploymentReview {
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

    public func restore(cloudProjectId: String, name: String) async throws -> ControllerCloudProjectBinding {
        let lock = try await acquireLock(); defer { lock.close() }
        let context = try await context(), selected = try client.workspaceStatus()
        guard UUID(uuidString: cloudProjectId) != nil,
              let workspaceId = selected.workspaceId, let generation = selected.selectionGeneration else { throw ControllerCloudError.invalidSource }
        let cloud = try await session.request("/controller/v1/workspaces/\(context.workspaceId!)/projects/\(cloudProjectId)", as: ControllerCloudProject.self)
        guard ["html", "react"].contains(cloud.sourceKind), cloud.headVersionId != nil else { throw ControllerCloudError.invalidSource }
        let created = try client.performAuthoring(method: .projectCreate, params: [
            "schemaVersion": 1, "name": name, "kind": cloud.sourceKind == "html" ? "web" : "react",
            "expectedWorkspaceId": workspaceId, "expectedSelectionGeneration": generation])
        guard let localId = created.project?.project.projectId else { throw ControllerCloudError.invalidResponse }
        let sync = try projectSync()
        try await sync.link(accountId: context.accountId, workspaceId: context.workspaceId!, localProjectId: localId, cloudProjectId: cloudProjectId)
        try await recordBinding(sync.status(localProjectId: localId))
        let first = try await sync.sync(accountId: context.accountId, localProjectId: localId)
        return first.status == .conflict ? try await sync.resolve(accountId: context.accountId, localProjectId: localId, choice: .remote) : first
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
