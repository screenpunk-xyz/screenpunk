import Foundation
#if os(macOS)

public struct WorkbenchWorkspaceConfigurationRead: Codable, Sendable, Equatable {
    public let path: String
    public let workspaceId: String
    public let generation: Int
    public let presentation: [String: String]
    public let profiles: [String: [String: String]]
    public let screenIcons: [String: String]

    init(_ overview: WorkspaceOverview) {
        path = overview.path + "/workspace.json"; workspaceId = overview.descriptor.workspaceId
        generation = overview.settings.generation
        presentation = overview.settings.presentation; profiles = overview.settings.profiles
        screenIcons = overview.settings.screenIcons
    }
    init(path: String, workspaceId: String, settings: WorkspaceSettings) {
        self.path = path + "/workspace.json"; self.workspaceId = workspaceId
        generation = settings.generation
        presentation = settings.presentation; profiles = settings.profiles
        screenIcons = settings.screenIcons
    }
}

/// Closed portable presentation settings. Machine-local endpoints, credentials,
/// install paths, workspace identity and layout cannot be represented here.
public final class WorkbenchWorkspaceConfiguration {
    private let workspace: WorkspaceStore
    private static let keys: Set<String> = ["theme", "view", "sort", "defaultCollection"]

    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func get() throws -> WorkbenchWorkspaceConfigurationRead {
        guard let current = try workspace.current() else { throw WorkspaceError.unavailable }
        return .init(current)
    }

    public func set(key: String, value: String,
                    expectedGeneration: Int) throws -> WorkbenchWorkspaceConfigurationRead {
        guard Self.keys.contains(key), WorkspaceValidation.text(value) else {
            throw WorkspaceError.invalidSchema
        }
        let current = try current(expectedGeneration)
        var presentation = current.settings.presentation
        presentation[key] = value
        if presentation == current.settings.presentation { return .init(current) }
        let updated = try workspace.updateSettings(presentation, profiles: current.settings.profiles,
            expectedGeneration: expectedGeneration)
        return .init(path: current.path, workspaceId: current.descriptor.workspaceId,
            settings: updated)
    }

    public func unset(key: String,
                      expectedGeneration: Int) throws -> WorkbenchWorkspaceConfigurationRead {
        guard Self.keys.contains(key) else { throw WorkspaceError.invalidSchema }
        let current = try current(expectedGeneration)
        var presentation = current.settings.presentation
        guard presentation.removeValue(forKey: key) != nil else { return .init(current) }
        let updated = try workspace.updateSettings(presentation, profiles: current.settings.profiles,
            expectedGeneration: expectedGeneration)
        return .init(path: current.path, workspaceId: current.descriptor.workspaceId,
            settings: updated)
    }

    private func current(_ expected: Int) throws -> WorkspaceOverview {
        guard expected >= 0, expected < WorkspaceValidation.maxUInt,
              let current = try workspace.current(),
              current.settings.generation == expected else { throw WorkspaceError.conflict }
        return current
    }
}
#endif
