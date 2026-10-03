import Foundation
#if os(macOS)

public struct WorkbenchSourceProject: Codable, Sendable, Equatable {
    public let project: WorkspaceProject
    public let path: String
    public let sourceVersion: String
    public let sourceHashVersion: Int
    public let fileCount: Int
    public let includedBytes: Int
}

public struct WorkbenchSourceChange: Sendable {
    public let path: String
    public let bytes: Data?
    public init(path: String, bytes: Data?) { self.path = path; self.bytes = bytes }
}

public struct WorkbenchSourceHistoryEntry: Codable, Sendable, Equatable {
    public let sourceVersion: String
    public let sourceHashVersion: Int
    public let projectId: String
    public let dashboardId: String
    public let files: [WorkbenchSourceFile]
}
public struct WorkbenchSourceFile: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let bytes: Int
}

/// Source versions are content identities. They never authorize a kit, build or device action.
enum WorkbenchSourceHasher {
    static let version = 1
    static func hash(_ files: [String: Data]) throws -> String {
        guard files.count <= 2_000,
              files.values.reduce(0, { $0 + $1.count }) <= 25 * 1024 * 1024 else {
            throw WorkspaceError.limitExceeded
        }
        // M0 canonical V1: H("source", sorted [{path, sha256}]).
        var material = Data("screenpunk/source/v1\0".utf8)
        material.append(UInt8(ascii: "a")); appendLength(files.count, to: &material)
        var collisions = WorkspacePathCollisionDetector()
        for (path, bytes) in files.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
            guard WorkspaceValidation.member(path), !WorkspaceFiles.fixedSourceExcludes(path),
                  bytes.count <= 5 * 1024 * 1024 else { throw WorkspaceError.invalidSchema }
            try collisions.insert(path)
            material.append(UInt8(ascii: "o")); appendLength(2, to: &material)
            appendString("path", to: &material)
            appendString(path, to: &material)
            appendString("sha256", to: &material)
            let digest = WorkbenchTransactionDigest.hex(bytes)
            appendString(digest, to: &material)
        }
        return WorkbenchTransactionDigest.hex(material)
    }
    private static func appendLength(_ count: Int, to data: inout Data) {
        var number = UInt64(count).bigEndian
        withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
    }
    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        data.append(UInt8(ascii: "s")); appendLength(bytes.count, to: &data); data.append(bytes)
    }
}

extension WorkspaceDescriptor {
    init(copy source: WorkspaceDescriptor, generation: Int) {
        schemaVersion = source.schemaVersion; workspaceId = source.workspaceId; name = source.name
        self.generation = generation; paths = source.paths; defaults = source.defaults; recovery = source.recovery
    }
}
#endif
