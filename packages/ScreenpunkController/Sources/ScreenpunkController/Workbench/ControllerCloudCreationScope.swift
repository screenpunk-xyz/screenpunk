import Foundation
#if os(macOS)
import Darwin

/// Broker-owned creation outbox. It arms only a new project transaction, before
/// its source/catalog commit; a recovered commit therefore retains its original
/// account/workspace even if the creating client disappears.
struct ControllerCloudCreationScope {
    private struct Connection: Codable, Equatable {
        let clientId: String
        let accountId: String
        let workspaceId: String
        let localWorkspaceId: String
    }
    private let root: URL
    private let connection: Connection

    static func publish(root: URL, clientId: String, accountId: String,
                        workspaceId: String?, localWorkspaceId: String?) throws {
        guard let workspaceId, let localWorkspaceId else {
            try disconnect(root: root, clientId: clientId); return
        }
        let connection = Connection(clientId: clientId, accountId: accountId,
            workspaceId: workspaceId, localWorkspaceId: localWorkspaceId)
        try durable(JSONEncoder().encode(connection), to: try contextFile(root: root, clientId: clientId))
    }
    static func disconnect(root: URL, clientId: String) throws {
        let file = try contextFile(root: root, clientId: clientId)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let current = try JSONDecoder().decode(Connection.self, from: Self.regularBytes(file))
        if current.clientId == clientId { try FileManager.default.removeItem(at: file); try syncDirectory(root) }
    }
    static func capture(workspace: WorkspaceStore) throws -> Self? {
        guard let selected = try workspace.current() else { return nil }
        let cloud = URL(fileURLWithPath: workspace.selection.machineRootPath).appendingPathComponent("cloud-controller")
        guard FileManager.default.fileExists(atPath: cloud.path) else { return nil }
        let roots = try FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)
        guard roots.count <= 64 else { throw WorkspaceError.limitExceeded }
        var found: Self?
        for root in roots {
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("creation-context-") && $0.pathExtension == "json" }
            guard files.count <= 8 else { throw WorkspaceError.limitExceeded }
            for file in files {
                let connection = try JSONDecoder().decode(Connection.self, from: Self.regularBytes(file))
                guard connection.localWorkspaceId == selected.descriptor.workspaceId else { continue }
                if let prior = found {
                    guard prior.root == root, prior.connection.accountId == connection.accountId,
                          prior.connection.workspaceId == connection.workspaceId else { throw WorkspaceError.conflict }
                } else { found = .init(root: root, connection: connection) }
            }
        }
        return found
    }
    func prepare(project: WorkspaceProject, descriptor: WorkspaceProjectDocument, localWorkspaceId: String) throws {
        guard connection.localWorkspaceId == localWorkspaceId else { throw WorkspaceError.conflict }
        try descriptor.validate(matching: project)
        let directory = root.appendingPathComponent("projects/\(localWorkspaceId)/new")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(project.projectId + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            let prior = try JSONDecoder().decode(CloudNewProjectIntent.self, from: Self.regularBytes(file))
            guard prior.accountId == connection.accountId, prior.workspaceId == connection.workspaceId,
                  prior.localProjectId == project.projectId else { throw WorkspaceError.conflict }
            return
        }
        let intent = CloudNewProjectIntent(accountId: connection.accountId,
            workspaceId: connection.workspaceId, localProjectId: project.projectId,
            name: descriptor.name, kind: descriptor.kind == "web" ? "html" : descriptor.kind,
            idempotencyKey: UUID().uuidString.lowercased(), cloudProjectId: nil, kitVersion: descriptor.kitVersion)
        try Self.durable(JSONEncoder().encode(intent), to: file)
    }
    private static func contextFile(root: URL, clientId: String) throws -> URL {
        guard !clientId.isEmpty, clientId.utf8.count <= 120, clientId.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw WorkspaceError.invalidSchema }
        return root.appendingPathComponent("creation-context-" + clientId + ".json")
    }
    private static func regularBytes(_ file: URL) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw WorkspaceError.unavailable }
        defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size <= 64 * 1024 else { throw WorkspaceError.invalidSchema }
        return try Data(contentsOf: URL(fileURLWithPath: "/dev/fd/\(fd)"))
    }
    private static func durable(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw WorkspaceError.unavailable }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw WorkspaceError.unavailable }
        defer { close(fd) }; guard fsync(fd) == 0 else { throw WorkspaceError.unavailable }
        try syncDirectory(file.deletingLastPathComponent())
    }
    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceError.unavailable }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw WorkspaceError.unavailable }
    }
}
#endif
