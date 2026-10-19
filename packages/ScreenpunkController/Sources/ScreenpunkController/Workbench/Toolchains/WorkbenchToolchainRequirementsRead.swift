import Foundation
#if os(macOS)
import Darwin

/// Portable pins are useful recovery information, but never installation or
/// execution authority until the independent release catalog authenticates.
public struct WorkbenchToolchainRequirementsRead: Codable, Sendable, Equatable {
    public static let method = "toolchain.requirements"
    public let schemaVersion: Int
    public let kind: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let required: [WorkspaceToolchainRequirements.Requirement]
    public let trust: String
    public let installation: String
    public let installed: [WorkspaceToolchainRequirements.Requirement]?

    init(workspaceId: String, selectionGeneration: Int,
         required: [WorkspaceToolchainRequirements.Requirement],
         installed: [WorkspaceToolchainRequirements.Requirement]? = nil) {
        schemaVersion = 1; kind = "toolchainRequirements"
        self.workspaceId = workspaceId; self.selectionGeneration = selectionGeneration
        self.required = required; self.installed = installed
        trust = installed == nil ? "not_registered" : "authenticated"
        installation = installed.map { $0.count == required.count ? "complete" : "incomplete" } ?? "not_assessed"
    }

    public func validate() throws {
        guard schemaVersion == 1, kind == "toolchainRequirements",
              WorkspaceValidation.id(workspaceId), selectionGeneration > 0,
              ((trust == "not_registered" && installation == "not_assessed" && installed == nil) ||
               (trust == "authenticated" && installed != nil &&
                installation == (installed!.count == required.count ? "complete" : "incomplete"))),
              required.count <= 128,
              required.allSatisfy({ WorkspaceValidation.id($0.catalogEntryId) &&
                  WorkspaceValidation.id($0.kitVersion) && $0.platform == "darwin-arm64" &&
                  WorkspaceValidation.sha256($0.inventoryHash) }),
              Set(required.map(\.catalogEntryId)).count == required.count,
              (installed ?? []).allSatisfy({ required.contains($0) }),
              Set((installed ?? []).map(\.catalogEntryId)).count == (installed ?? []).count else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}

public struct WorkbenchToolchainInstallResult: Codable, Sendable, Equatable {
    public static let method = "toolchain.installRequired"
    public let schemaVersion: Int
    public let kind: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let requiredCount: Int
    public let installed: [WorkspaceToolchainRequirements.Requirement]
    public let complete: Bool

    init(requirements: WorkbenchToolchainRequirementsRead,
         installed: [WorkspaceToolchainRequirements.Requirement]) {
        schemaVersion = 1; kind = "toolchainInstall"
        workspaceId = requirements.workspaceId
        selectionGeneration = requirements.selectionGeneration
        requiredCount = requirements.required.count
        self.installed = installed; complete = installed.count == requiredCount
    }
    public func validate() throws {
        guard schemaVersion == 1, kind == "toolchainInstall",
              WorkspaceValidation.id(workspaceId), selectionGeneration > 0,
              (0...128).contains(requiredCount), complete,
              installed.count == requiredCount,
              Set(installed.map(\.catalogEntryId)).count == installed.count,
              installed.allSatisfy({ WorkspaceValidation.id($0.catalogEntryId) &&
                  WorkspaceValidation.id($0.kitVersion) && $0.platform == "darwin-arm64" &&
                  WorkspaceValidation.sha256($0.inventoryHash) }) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}

enum WorkbenchToolchainRequirementsReader {
    static func read(workspace: WorkspaceStore) throws -> WorkbenchToolchainRequirementsRead {
        guard let selected = try workspace.current(),
              let generation = selected.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let root = try WorkspaceFiles(path: selected.path)
        let directory = try root.directory(["Workbench", "Toolchains"])
        defer { close(directory) }
        let data = try root.read(directory, "requirements.json", maxBytes: 64 * 1024)
        let requirements = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
            from: data, shape: .requirements)
        try requirements.validate()
        guard let current = try workspace.current(),
              current.descriptor.workspaceId == selected.descriptor.workspaceId,
              current.selectionGeneration == generation else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let result = WorkbenchToolchainRequirementsRead(
            workspaceId: selected.descriptor.workspaceId,
            selectionGeneration: generation, required: requirements.required)
        try result.validate()
        return result
    }
}
#endif
