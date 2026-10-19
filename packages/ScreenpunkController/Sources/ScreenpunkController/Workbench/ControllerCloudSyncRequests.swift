import Foundation
#if os(macOS)
import CryptoKit
import Darwin

public enum ControllerCloudScreenSyncTrigger: String, Codable, Sendable {
    case enabled, appOpened, screenSelected, localChanged, remoteInvalidation, reconnected
}
public struct ControllerCloudScreenSyncRequest: Codable, Sendable {
    public let requestId: String
    public let trigger: ControllerCloudScreenSyncTrigger
    public let accountId: String
    public let clientId: String
    public let workspaceId: String
    public let localWorkspaceId: String
    public let epoch: String
    public let dashboardIds: [String]
    public let requiresFullCheck: Bool
    public let notBefore: Date
}
/// One coalesced local event, not a remote polling schedule. Exact IDs/epoch prevent retargeting.
struct ControllerCloudSyncRequestStore {
    let root: URL
    var file: URL { root.appendingPathComponent("screen-sync-request.json") }
    static func originRoot(baseURL: URL, machineRoot: URL) throws -> URL {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, ["", "/"].contains(baseURL.path) else { throw ControllerCloudError.invalidConfiguration }
        let key = SHA256.hash(data: Data(baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return machineRoot.appendingPathComponent("cloud-controller/" + key)
    }
    func enabledScope() throws -> ControllerCloudSyncPolicy? {
        let file = root.appendingPathComponent("screen-sync-policy.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let policy = try JSONDecoder().decode(ControllerCloudSyncPolicy.self, from: Data(contentsOf: file))
        struct Selection: Decodable { let accountId: String; let workspaceId: String?; let localWorkspaceId: String? }
        guard policy.enabled, let workspace = policy.workspaceId, UUID(uuidString: workspace) != nil,
              let local = policy.localWorkspaceId, WorkspaceValidation.id(local),
              let bytes = try? Data(contentsOf: root.appendingPathComponent("selection.json")),
              let selected = try? JSONDecoder().decode(Selection.self, from: bytes), selected.accountId == policy.accountId,
              selected.workspaceId == workspace, selected.localWorkspaceId == local else { return nil }
        return policy
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let fd = open(root.appendingPathComponent("screen-sync-request.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ControllerCloudError.invalidConfiguration }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ControllerCloudError.conflict }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }
    /// Legacy explicit consent can retain its unique exact creation-context owner. Ambiguity
    /// never authorizes trying another credential/profile.
    func ownerClientId(_ policy: ControllerCloudSyncPolicy) throws -> String? {
        let allowed = Set(["screenpunk-cli", "screenpunk-mac"])
        if let owner = policy.clientId { return allowed.contains(owner) ? owner : nil }
        struct Connection: Decodable {
            let clientId: String; let accountId: String; let workspaceId: String; let localWorkspaceId: String
            let policyEpoch: String?; let screenSyncEnabled: Bool?
        }
        var owners = Set<String>()
        for client in allowed {
            guard let bytes = try? Data(contentsOf: root.appendingPathComponent("creation-context-" + client + ".json")), bytes.count <= 64 * 1024,
                  let value = try? JSONDecoder().decode(Connection.self, from: bytes), value.clientId == client,
                  value.accountId == policy.accountId, value.workspaceId == policy.workspaceId,
                  value.localWorkspaceId == policy.localWorkspaceId, value.policyEpoch == policy.epoch,
                  value.screenSyncEnabled == true else { continue }
            owners.insert(client)
        }
        return owners.count == 1 ? owners.first : nil
    }
    func enqueue(trigger: ControllerCloudScreenSyncTrigger, dashboardId: String?, authorizedBy: ControllerCloudScreenSyncRequest? = nil,
                 afterAdmission: (() throws -> Void)? = nil) throws {
        // This short lock covers capture/union/atomic-write only; it never spans IPC or awaits.
        try locked {
            guard let policy = try enabledScope(), let workspace = policy.workspaceId, let local = policy.localWorkspaceId,
                  let owner = try ownerClientId(policy) else { if authorizedBy != nil { throw CancellationError() }; return }
            if let expected = authorizedBy {
                guard policy.epoch == expected.epoch, policy.accountId == expected.accountId,
                      workspace == expected.workspaceId, local == expected.localWorkspaceId,
                      owner == expected.clientId else { throw CancellationError() }
            }
            // Internal deterministic interleaving seam; production always supplies nil.
            try afterAdmission?()
            if let dashboardId, !WorkspaceValidation.id(dashboardId) { throw ControllerCloudError.invalidSource }
            let previous = try pending()
            let matching = previous.flatMap { $0.epoch == policy.epoch && $0.accountId == policy.accountId &&
                $0.workspaceId == workspace && $0.localWorkspaceId == local && $0.clientId == owner ? $0 : nil }
            let ids = Set(matching?.dashboardIds ?? []).union(dashboardId.map { [$0] } ?? [])
            guard ids.count <= 256 else { throw ControllerCloudError.sourceLimitExceeded }
            // Never reconstruct from a later policy read: an obsolete captured epoch is safely ignored.
            let request = ControllerCloudScreenSyncRequest(requestId: UUID().uuidString.lowercased(), trigger: trigger,
                accountId: policy.accountId, clientId: owner, workspaceId: workspace, localWorkspaceId: local, epoch: policy.epoch,
                dashboardIds: ids.sorted(), requiresFullCheck: matching?.requiresFullCheck == true || trigger == .enabled || trigger == .appOpened || (trigger == .screenSelected && dashboardId == nil), notBefore: Date().addingTimeInterval(trigger == .localChanged ? 2 : 0))
            try ControllerCloudPersistence.write(JSONEncoder().encode(request), to: file)
        }
    }
    func pending() throws -> ControllerCloudScreenSyncRequest? {
        guard FileManager.default.fileExists(atPath: file.path), let policy = try enabledScope() else { return nil }
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 64 * 1024 else { throw ControllerCloudError.invalidSource }
        let value = try JSONDecoder().decode(ControllerCloudScreenSyncRequest.self, from: bytes)
        guard value.epoch == policy.epoch, value.accountId == policy.accountId, value.clientId == (try ownerClientId(policy)), value.workspaceId == policy.workspaceId,
              value.localWorkspaceId == policy.localWorkspaceId else { return nil }
        return value
    }
    func acknowledge(_ requestId: String) throws {
        try locked {
            guard let current = try pending(), current.requestId == requestId else { return }
            try FileManager.default.removeItem(at: file)
        }
    }
}
#endif
