import Foundation
#if os(macOS)
import Darwin
/// Request-boundary consent is inherited only by automatic work, never by explicit Cloud actions.
enum ControllerCloudAutomaticSyncAuthorization {
    @TaskLocal static var check: (@Sendable () throws -> Void)?
    static func requireConsent() throws { try Task.checkCancellation(); try check?() }
}
struct ControllerCloudSyncPolicy: Codable, Sendable {
    let accountId: String
    let workspaceId: String?
    let localWorkspaceId: String?
    let enabled: Bool
    let epoch: String
    var clientId: String? = nil
}
/// Persist identity and consent before any asynchronous operation can commit remotely.
enum ControllerCloudPersistence {
    static func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw WorkspaceError.unavailable }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceError.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw WorkspaceError.unavailable }
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw WorkspaceError.unavailable }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw WorkspaceError.unavailable }
    }
}
#endif
