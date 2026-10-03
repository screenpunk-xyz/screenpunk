import Foundation
import CoreFoundation
import ScreenpunkCore

#if os(macOS)
/// Selected-workspace history is separate from legacy-controller `package.*`.
public enum WorkbenchWorkspacePackageMethod: String, CaseIterable, Sendable {
    case list = "workspace.package.list"
    case get = "workspace.package.get"
    case file = "workspace.package.file"
}

public enum WorkbenchWorkspacePackageRequest: Sendable {
    case list(String, Int, String?)
    case get(String, Int, String, String)
    case file(String, Int, String, String, String, Int)

    public var method: WorkbenchWorkspacePackageMethod {
        switch self {
        case .list: return .list
        case .get: return .get
        case .file: return .file
        }
    }
    public var selection: (workspaceId: String, generation: Int) {
        switch self {
        case .list(let id, let generation, _), .get(let id, let generation, _, _),
             .file(let id, let generation, _, _, _, _): return (id, generation)
        }
    }

    public static func parse(_ method: WorkbenchWorkspacePackageMethod,
                             _ params: [String: Any]) throws -> Self {
        guard let version = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let workspaceId = params["expectedWorkspaceId"] as? String,
              WorkspaceValidation.id(workspaceId),
              let generation = params["expectedSelectionGeneration"] as? NSNumber,
              CFGetTypeID(generation) != CFBooleanGetTypeID(),
              generation.doubleValue == Double(generation.intValue), generation.intValue >= 0 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if method == .list {
            let required: Set<String> = ["schemaVersion", "expectedWorkspaceId",
                                         "expectedSelectionGeneration"]
            guard Set(params.keys) == required || Set(params.keys) == required.union(["cursor"]) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let cursor = params["cursor"] as? String
            guard params["cursor"] == nil || (cursor != nil && (1...300).contains(cursor!.utf8.count)) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .list(workspaceId, generation.intValue, cursor)
        }
        guard let dashboardId = params["dashboardId"] as? String,
              let revision = params["revision"] as? String,
              WorkspaceValidation.id(dashboardId), WorkspaceValidation.id(revision) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if method == .get {
            guard Set(params.keys) == ["schemaVersion", "expectedWorkspaceId",
                                       "expectedSelectionGeneration", "dashboardId", "revision"] else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .get(workspaceId, generation.intValue, dashboardId, revision)
        }
        guard Set(params.keys) == ["schemaVersion", "expectedWorkspaceId",
                                   "expectedSelectionGeneration", "dashboardId", "revision",
                                   "path", "offset"],
              let path = params["path"] as? String,
              path.isEmpty || WorkspaceValidation.member(path),
              let offset = params["offset"] as? NSNumber,
              CFGetTypeID(offset) != CFBooleanGetTypeID(),
              offset.doubleValue == Double(offset.intValue), offset.intValue >= 0 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return .file(workspaceId, generation.intValue, dashboardId, revision, path, offset.intValue)
    }
}

struct WorkbenchWorkspacePackageCursor {
    let workspaceId: String
    let selectionGeneration: Int
    let historyGeneration: Int
    let inventoryHash: String
    let lastObjectId: String

    var value: String {
        "v1:\(workspaceId):\(selectionGeneration):\(historyGeneration):\(inventoryHash):\(lastObjectId)"
    }
    static func parse(_ value: String) throws -> Self {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "v1", WorkspaceValidation.id(parts[1]),
              let selection = Int(parts[2]), (1...WorkspaceValidation.maxUInt).contains(selection),
              let history = Int(parts[3]), (1...WorkspaceValidation.maxUInt).contains(history),
              WorkspaceValidation.sha256(parts[4]), WorkspaceValidation.sha256(parts[5]) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return .init(workspaceId: parts[1], selectionGeneration: selection,
            historyGeneration: history, inventoryHash: parts[4], lastObjectId: parts[5])
    }
}

public struct WorkbenchWorkspacePackageSummary: Codable, Sendable, Equatable {
    public let dashboardId: String
    public let revision: String
    public let name: String
    public let digest: String
    public let fileCount: Int
    public let storage: String
    public let provenance: String
    public let visibleInLibrary: Bool
    init(_ manifest: DashboardManifest, visibleInLibrary: Bool = true) throws {
        guard let digest = manifest.digest else { throw WorkbenchIPCError(.unavailable) }
        dashboardId = manifest.dashboardId; revision = manifest.revision
        name = manifest.name; self.digest = digest; fileCount = manifest.files.count
        storage = "selected-workspace-history"
        provenance = "workspace-history-untrusted"
        self.visibleInLibrary = visibleInLibrary
    }
}

public struct WorkbenchWorkspacePackageChunk: Codable, Sendable, Equatable {
    public let path: String
    public let offset: Int
    public let totalBytes: Int
    public let sha256: String
    public let bytes: Data
}

public struct WorkbenchWorkspacePackageResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let packages: [WorkbenchWorkspacePackageSummary]?
    public let hasMore: Bool?
    public let nextCursor: String?
    public let ordering: String?
    public let package: WorkbenchWorkspacePackageSummary?
    public let chunk: WorkbenchWorkspacePackageChunk?
    init(_ method: WorkbenchWorkspacePackageMethod, _ workspaceId: String, _ selectionGeneration: Int,
         packages: [WorkbenchWorkspacePackageSummary]? = nil,
         hasMore: Bool? = nil, nextCursor: String? = nil,
         package: WorkbenchWorkspacePackageSummary? = nil,
         chunk: WorkbenchWorkspacePackageChunk? = nil) {
        schemaVersion = 1; kind = method.rawValue; self.workspaceId = workspaceId
        self.selectionGeneration = selectionGeneration
        self.packages = packages; self.package = package; self.chunk = chunk
        self.hasMore = hasMore; self.nextCursor = nextCursor
        ordering = packages == nil ? nil : "history-object-id-ascending"
    }
    public func validate(for request: WorkbenchWorkspacePackageRequest) throws {
        guard schemaVersion == 1, kind == request.method.rawValue,
              workspaceId == request.selection.workspaceId,
              selectionGeneration == request.selection.generation,
              [packages != nil, package != nil, chunk != nil].filter({ $0 }).count == 1 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        switch request {
        case .list:
            guard let packages, packages.count <= 128,
                  let hasMore, !hasMore || (!packages.isEmpty && nextCursor != nil),
                  hasMore || nextCursor == nil,
                  ordering == "history-object-id-ascending",
                  packages.allSatisfy({ $0.storage == "selected-workspace-history" &&
                      WorkspaceValidation.sha256($0.digest) }),
                  (nextCursor == nil || (try? WorkbenchWorkspacePackageCursor.parse(nextCursor!)) != nil) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let objectIDs = packages.map {
                WorkbenchTransactionDigest.hex(Data(($0.dashboardId + "\0" + $0.revision).utf8))
            }
            guard objectIDs == objectIDs.sorted(), Set(objectIDs).count == objectIDs.count else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            if let nextCursor {
                let parsed = try WorkbenchWorkspacePackageCursor.parse(nextCursor)
                guard parsed.workspaceId == workspaceId,
                      parsed.selectionGeneration == selectionGeneration,
                      parsed.lastObjectId == objectIDs.last else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
            }
        case .get(_, _, let id, let revision):
            guard let package, package.dashboardId == id, package.revision == revision,
                  package.storage == "selected-workspace-history",
                  hasMore == nil, nextCursor == nil, ordering == nil else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        case .file(_, _, _, _, let path, let offset):
            guard let chunk, chunk.path == path, chunk.offset == offset,
                  offset <= chunk.totalBytes, chunk.bytes.count <= 64 * 1024,
                  chunk.bytes.count <= chunk.totalBytes - offset,
                  WorkspaceValidation.sha256(chunk.sha256),
                  hasMore == nil, nextCursor == nil, ordering == nil else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
    }
}
#endif
