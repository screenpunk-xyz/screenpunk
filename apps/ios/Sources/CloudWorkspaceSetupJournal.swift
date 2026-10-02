import Foundation
import ScreenpunkCore

/// Nonsecret durable operation identity. Names are preserved exactly across every retry.
struct CloudWorkspaceSetupJournalRecord: Codable, Equatable, Sendable {
    let userID: UUID
    let request: CloudNativeWorkspaceSetupRequest
    let receipt: CloudNativeWorkspaceSetupReceipt?
    init(userID: UUID, request: CloudNativeWorkspaceSetupRequest, receipt: CloudNativeWorkspaceSetupReceipt? = nil) throws {
        guard receipt == nil || receipt?.requestId == request.requestId else { throw CloudWorkspaceSetupJournalError.invalidRecord }
        self.userID = userID; self.request = request; self.receipt = receipt
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(userID: values.decode(UUID.self, forKey: .userID),
                      request: values.decode(CloudNativeWorkspaceSetupRequest.self, forKey: .request),
                      receipt: values.decodeIfPresent(CloudNativeWorkspaceSetupReceipt.self, forKey: .receipt))
    }
}
enum CloudWorkspaceSetupJournalError: Error { case invalidRecord }

@MainActor
protocol CloudWorkspaceSetupJournal {
    func load() throws -> CloudWorkspaceSetupJournalRecord?
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws
}

/// One unresolved operation cannot be overwritten, including after an account switch.
@MainActor
final class CloudWorkspaceSetupFileJournal: CloudWorkspaceSetupJournal {
    private let url: URL
    init(url: URL) { self.url = url }
    static func applicationJournal() -> CloudWorkspaceSetupFileJournal {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xyz.screenpunk.device", isDirectory: true)
        return .init(url: root.appendingPathComponent("native-workspace-setup.json"))
    }
    func load() throws -> CloudWorkspaceSetupJournalRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CloudWorkspaceSetupJournalRecord.self, from: Data(contentsOf: url))
    }
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }
}
