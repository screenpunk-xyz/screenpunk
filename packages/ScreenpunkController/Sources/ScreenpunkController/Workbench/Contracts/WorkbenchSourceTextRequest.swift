import Foundation
import CoreFoundation
#if os(macOS)
public struct WorkbenchSourceTextRequest: Sendable {
    public static let method = "project.sourceText"
    public let expectedWorkspaceId: String
    public let expectedSelectionGeneration: Int
    public let projectId: String
    public let path: String

    public init(expectedWorkspaceId: String, expectedSelectionGeneration: Int,
                projectId: String, path: String) throws {
        guard WorkspaceValidation.id(expectedWorkspaceId),
              (1...WorkspaceValidation.maxUInt).contains(expectedSelectionGeneration),
              WorkspaceValidation.id(projectId), WorkspaceValidation.member(path) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        self.expectedWorkspaceId = expectedWorkspaceId
        self.expectedSelectionGeneration = expectedSelectionGeneration
        self.projectId = projectId; self.path = path
    }

    static func parse(_ params: [String: Any]) throws -> Self {
        guard Set(params.keys) == ["schemaVersion", "expectedWorkspaceId",
                                   "expectedSelectionGeneration", "projectId", "path"],
              let schema = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let workspaceId = params["expectedWorkspaceId"] as? String,
              let generation = params["expectedSelectionGeneration"] as? NSNumber,
              CFGetTypeID(generation) != CFBooleanGetTypeID(),
              generation.doubleValue == Double(generation.intValue),
              let projectId = params["projectId"] as? String,
              let path = params["path"] as? String else { throw WorkbenchIPCError(.invalidRequest) }
        return try .init(expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: generation.intValue, projectId: projectId, path: path)
    }
}
#endif
