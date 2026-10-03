import Foundation
import CoreFoundation
#if os(macOS)

/// One included member of one selected, version-checked contained project.
/// The broker supplies fixed-size chunks; callers cannot name an absolute path.
public struct WorkbenchSourceChunkRequest: Sendable {
    public static let method = "project.sourceChunk"
    public static let maximumFileBytes = 5 * 1024 * 1024
    public static let chunkBytes = 64 * 1024
    public let expectedWorkspaceId: String
    public let expectedSelectionGeneration: Int
    public let projectId: String
    public let path: String
    public let expectedSourceVersion: String
    public let offset: Int

    public init(expectedWorkspaceId: String, expectedSelectionGeneration: Int,
                projectId: String, path: String, expectedSourceVersion: String,
                offset: Int) throws {
        guard WorkspaceValidation.id(expectedWorkspaceId),
              (1...WorkspaceValidation.maxUInt).contains(expectedSelectionGeneration),
              WorkspaceValidation.id(projectId), WorkspaceValidation.member(path),
              !WorkspaceFiles.fixedSourceExcludes(path),
              WorkspaceValidation.sha256(expectedSourceVersion),
              (0...Self.maximumFileBytes).contains(offset) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        self.expectedWorkspaceId = expectedWorkspaceId
        self.expectedSelectionGeneration = expectedSelectionGeneration
        self.projectId = projectId; self.path = path
        self.expectedSourceVersion = expectedSourceVersion; self.offset = offset
    }

    static func parse(_ params: [String: Any]) throws -> Self {
        guard Set(params.keys) == ["schemaVersion", "expectedWorkspaceId",
                                   "expectedSelectionGeneration", "projectId", "path",
                                   "expectedSourceVersion", "offset"],
              let schema = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let workspaceId = params["expectedWorkspaceId"] as? String,
              let generation = params["expectedSelectionGeneration"] as? NSNumber,
              CFGetTypeID(generation) != CFBooleanGetTypeID(),
              generation.doubleValue == Double(generation.intValue),
              let projectId = params["projectId"] as? String,
              let path = params["path"] as? String,
              let version = params["expectedSourceVersion"] as? String,
              let offset = params["offset"] as? NSNumber,
              CFGetTypeID(offset) != CFBooleanGetTypeID(),
              offset.doubleValue == Double(offset.intValue) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return try .init(expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: generation.intValue,
            projectId: projectId, path: path, expectedSourceVersion: version,
            offset: offset.intValue)
    }
}

public struct WorkbenchSourceChunkRead: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let workspaceId: String
    public let selectionGeneration: Int
    public let projectId: String
    public let path: String
    public let sourceVersion: String
    public let fileSHA256: String
    public let fileBytes: Int
    public let offset: Int
    public let bytesBase64: String
    public let nextOffset: Int
    public let complete: Bool

    init(request: WorkbenchSourceChunkRequest, file: Data) {
        schemaVersion = 1
        workspaceId = request.expectedWorkspaceId
        selectionGeneration = request.expectedSelectionGeneration
        projectId = request.projectId; path = request.path
        sourceVersion = request.expectedSourceVersion
        fileSHA256 = WorkbenchTransactionDigest.hex(file)
        fileBytes = file.count; offset = request.offset
        nextOffset = min(file.count, request.offset + WorkbenchSourceChunkRequest.chunkBytes)
        bytesBase64 = file[request.offset..<nextOffset].base64EncodedString()
        complete = nextOffset == file.count
    }

    func validate(for request: WorkbenchSourceChunkRequest) throws {
        guard schemaVersion == 1, workspaceId == request.expectedWorkspaceId,
              selectionGeneration == request.expectedSelectionGeneration,
              projectId == request.projectId, path == request.path,
              sourceVersion == request.expectedSourceVersion,
              WorkspaceValidation.sha256(fileSHA256),
              (0...WorkbenchSourceChunkRequest.maximumFileBytes).contains(fileBytes),
              offset == request.offset, offset <= fileBytes,
              nextOffset >= offset, nextOffset <= fileBytes,
              nextOffset - offset <= WorkbenchSourceChunkRequest.chunkBytes,
              complete == (nextOffset == fileBytes),
              let bytes = Data(base64Encoded: bytesBase64),
              bytes.count == nextOffset - offset,
              bytes.base64EncodedString() == bytesBase64 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}
#endif
