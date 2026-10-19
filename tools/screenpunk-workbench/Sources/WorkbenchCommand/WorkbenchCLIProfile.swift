import Foundation
import ScreenpunkController

/// Portable presentation only. Resolution never supplies a path, credential,
/// kit, device target, approval, or executable policy to a command.
struct WorkbenchCLIProfile {
    let name: String
    let workspaceId: String
    let configurationGeneration: Int
    let effectivePresentation: [String: String]

    static func resolve(_ name: String, selected: WorkbenchWorkspaceStatus,
                        client: WorkbenchBrokerClient) throws -> Self {
        guard selected.state == "selected", let workspaceId = selected.workspaceId,
              let generation = selected.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let result = try client.performAuthoring(method: .workspaceConfigGet, params: [
            "schemaVersion": 1, "expectedWorkspaceId": workspaceId,
            "expectedSelectionGeneration": generation])
        guard let configuration = result.configuration,
              configuration.workspaceId == workspaceId else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let overrides: [String: String]
        if name == "default" {
            overrides = [:]
        } else {
            guard let existing = configuration.profiles[name] else {
                throw CommandFailure("profile_not_found", "The selected workspace has no named profile \(name).", 6)
            }
            overrides = existing
        }
        return .init(name: name, workspaceId: workspaceId,
            configurationGeneration: configuration.generation,
            effectivePresentation: configuration.presentation.merging(overrides) { _, profile in profile })
    }
}
