import Foundation
import CoreFoundation

#if os(macOS)
public struct WorkbenchScreenIconRequest: Sendable {
    public let expectedWorkspaceId: String
    public let expectedSelectionGeneration: Int
    public let expectedCatalogGeneration: Int
    public let dashboardId: String
    public let symbol: String

    public static func parse(_ fields: [String: Any]) throws -> Self {
        guard Set(fields.keys) == ["schemaVersion", "expectedWorkspaceId",
            "expectedSelectionGeneration", "expectedCatalogGeneration",
            "dashboardId", "symbol"],
            let version = integer(fields["schemaVersion"], minimum: 1), version == 1,
            let workspaceId = fields["expectedWorkspaceId"] as? String,
            WorkspaceValidation.id(workspaceId),
            let selection = integer(fields["expectedSelectionGeneration"], minimum: 1),
            let generation = integer(fields["expectedCatalogGeneration"], minimum: 0),
            let dashboardId = fields["dashboardId"] as? String,
            WorkspaceValidation.id(dashboardId),
            let symbol = fields["symbol"] as? String,
            WorkspaceSettings.validSymbol(symbol) else {
            throw WorkspaceError.invalidSchema
        }
        return .init(expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: selection,
            expectedCatalogGeneration: generation,
            dashboardId: dashboardId, symbol: symbol)
    }

    private static func integer(_ value: Any?, minimum: Int) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              number.intValue >= minimum else { return nil }
        return number.intValue
    }
}

public struct WorkbenchScreenIconResult: Codable, Sendable, Equatable {
    public let workspaceId: String
    public let selectionGeneration: Int
    public let catalogGeneration: Int
    public let dashboardId: String
    public let symbol: String
}

/// Presentation-only portable workspace metadata. No package asset, history
/// object, source association, device setting or machine authority is changed.
public final class WorkbenchScreenIconDomain {
    private let workspace: WorkspaceStore
    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func set(_ request: WorkbenchScreenIconRequest) throws -> WorkbenchScreenIconResult {
        guard let selected = try workspace.current(),
              selected.descriptor.workspaceId == request.expectedWorkspaceId,
              selected.selectionGeneration == request.expectedSelectionGeneration,
              selected.descriptor.generation == request.expectedCatalogGeneration else {
            throw WorkspaceError.conflict
        }
        if !selected.catalog.projects.contains(where: { $0.dashboardId == request.dashboardId }) {
            let packages = try WorkbenchPortablePackages(workspace: workspace).list()
            guard packages.contains(where: { $0.dashboardId == request.dashboardId }) else {
                throw WorkspaceError.invalidSchema
            }
        }
        let updated = try workspace.updateScreenIcon(dashboardId: request.dashboardId,
            symbol: request.symbol, expectedWorkspaceId: request.expectedWorkspaceId,
            expectedSelectionGeneration: request.expectedSelectionGeneration,
            expectedGeneration: request.expectedCatalogGeneration)
        guard updated.screenIcons[request.dashboardId] == request.symbol else {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "screenIcon",
                workspaceId: request.expectedWorkspaceId, projectId: nil)
        }
        return .init(workspaceId: request.expectedWorkspaceId,
            selectionGeneration: request.expectedSelectionGeneration,
            catalogGeneration: updated.generation, dashboardId: request.dashboardId,
            symbol: request.symbol)
    }
}
#endif
