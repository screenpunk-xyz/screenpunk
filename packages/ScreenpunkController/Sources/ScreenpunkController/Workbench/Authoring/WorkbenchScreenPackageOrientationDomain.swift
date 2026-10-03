import Foundation
import CoreFoundation
import ScreenpunkCore

#if os(macOS)
public struct WorkbenchScreenPackageOrientationRequest: Sendable {
    public let expectedWorkspaceId: String
    public let expectedSelectionGeneration: Int
    public let expectedCatalogGeneration: Int
    public let dashboardId: String
    public let expectedRevision: String
    public let expectedDigest: String
    public let support: ScreenOrientationSupport

    public static func parse(_ fields: [String: Any]) throws -> Self {
        guard Set(fields.keys) == ["schemaVersion", "expectedWorkspaceId",
            "expectedSelectionGeneration", "expectedCatalogGeneration", "dashboardId",
            "expectedRevision", "expectedDigest", "support"],
            let version = integer(fields["schemaVersion"], minimum: 1), version == 1,
            let workspaceId = fields["expectedWorkspaceId"] as? String,
            WorkspaceValidation.id(workspaceId),
            let selection = integer(fields["expectedSelectionGeneration"], minimum: 1),
            let generation = integer(fields["expectedCatalogGeneration"], minimum: 0),
            let dashboardId = fields["dashboardId"] as? String,
            WorkspaceValidation.id(dashboardId),
            let revision = fields["expectedRevision"] as? String,
            WorkspaceValidation.id(revision),
            let digest = fields["expectedDigest"] as? String,
            WorkspaceValidation.sha256(digest),
            let rawSupport = fields["support"] as? String,
            let support = ScreenOrientationSupport(rawValue: rawSupport) else {
            throw WorkspaceError.invalidSchema
        }
        return .init(expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: selection, expectedCatalogGeneration: generation,
            dashboardId: dashboardId, expectedRevision: revision,
            expectedDigest: digest, support: support)
    }

    private static func integer(_ value: Any?, minimum: Int) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              number.intValue >= minimum else { return nil }
        return number.intValue
    }
}

public struct WorkbenchScreenPackageOrientationResult: Codable, Sendable, Equatable {
    public let workspaceId: String
    public let selectionGeneration: Int
    public let catalogGeneration: Int
    public let dashboardId: String
    public let priorRevision: String
    public let revision: String
    public let digest: String
    public let support: ScreenOrientationSupport
}

/// Changes the portable supported-orientations asset in a new immutable
/// package revision. If the old target is disallowed, its dimensions are
/// normalized to the sole allowed direction. Device installation is separate.
public final class WorkbenchScreenPackageOrientationDomain {
    private let workspace: WorkspaceStore
    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func set(_ request: WorkbenchScreenPackageOrientationRequest) throws
        -> WorkbenchScreenPackageOrientationResult {
        guard let overview = try workspace.current(),
              overview.descriptor.workspaceId == request.expectedWorkspaceId,
              overview.selectionGeneration == request.expectedSelectionGeneration,
              overview.descriptor.generation == request.expectedCatalogGeneration else {
            throw WorkspaceError.conflict
        }
        let packages = WorkbenchPortablePackages(workspace: workspace)
        let prior = try packages.get(dashboardId: request.dashboardId,
            revision: request.expectedRevision)
        guard prior.manifest.digest == request.expectedDigest else { throw WorkspaceError.conflict }
        let currentSupport: ScreenOrientationSupport
        if let settings = prior.files[ScreenDesignSettings.path] {
            let object = try WorkspaceJSON.object(from: settings)
            guard Set(object.keys) == ["orientations"],
                  let raw = object["orientations"] as? String,
                  let parsed = ScreenOrientationSupport(rawValue: raw) else {
                throw WorkspaceError.invalidSchema
            }
            currentSupport = parsed
        } else { currentSupport = .both }
        if currentSupport == request.support {
            return .init(workspaceId: request.expectedWorkspaceId,
                selectionGeneration: request.expectedSelectionGeneration,
                catalogGeneration: overview.descriptor.generation,
                dashboardId: request.dashboardId, priorRevision: request.expectedRevision,
                revision: request.expectedRevision, digest: request.expectedDigest,
                support: request.support)
        }
        var files = prior.files
        let settings = try ScreenDesignSettings(orientations: request.support).data()
        files[ScreenDesignSettings.path] = settings
        var manifest = prior.manifest
        manifest.revision = UUID().uuidString.lowercased()
        if manifest.target.orientation != request.support.rawValue && request.support != .both {
            let width = manifest.target.width, height = manifest.target.height
            manifest.target.orientation = request.support.rawValue
            manifest.target.width = request.support == .landscape ? max(width, height) : min(width, height)
            manifest.target.height = request.support == .landscape ? min(width, height) : max(width, height)
        }
        manifest.files = files.map { path, bytes in
            ManifestFile(path: path, bytes: bytes.count,
                sha256: WorkbenchTransactionDigest.hex(bytes))
        }.sorted { $0.path < $1.path }
        manifest.digest = nil
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let published = try packages.importVerified(.init(manifest: manifest, files: files),
            expectedWorkspaceId: request.expectedWorkspaceId,
            expectedSelectionGeneration: request.expectedSelectionGeneration,
            expectedCatalogGeneration: request.expectedCatalogGeneration)
        guard published.manifest == manifest, published.files == files,
              let digest = published.manifest.digest else {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "screenOrientation",
                workspaceId: request.expectedWorkspaceId, projectId: nil)
        }
        return .init(workspaceId: request.expectedWorkspaceId,
            selectionGeneration: request.expectedSelectionGeneration,
            catalogGeneration: overview.descriptor.generation + 1,
            dashboardId: request.dashboardId, priorRevision: request.expectedRevision,
            revision: manifest.revision, digest: digest, support: request.support)
    }
}
#endif
