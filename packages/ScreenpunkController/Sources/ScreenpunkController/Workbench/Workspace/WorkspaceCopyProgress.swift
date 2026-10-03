import Foundation
#if os(macOS)

public struct WorkspaceCopyProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case copying, verifying, publishing, switching, complete
    }
    public let phase: Phase
    public let copiedFiles: Int
    public let totalFiles: Int
    public let copiedBytes: Int64
    public let totalBytes: Int64

    public init(phase: Phase, copiedFiles: Int, totalFiles: Int,
                copiedBytes: Int64, totalBytes: Int64) {
        self.phase = phase; self.copiedFiles = copiedFiles; self.totalFiles = totalFiles
        self.copiedBytes = copiedBytes; self.totalBytes = totalBytes
    }
}
#endif
