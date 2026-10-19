import Foundation
import ScreenpunkCore
#if os(macOS)

/// Measured in-memory package input from a bounded adapter. Archive parsing,
/// chunk staging and filename decoding must finish before this helper is called.
/// No source path, executable, credential or local authority is accepted here.
public struct WorkbenchBoundedPackageImportRequest: Sendable {
    public let expectedWorkspaceId: String
    public let expectedSelectionGeneration: Int
    public let expectedDigest: String
    public let package: WorkbenchPortablePackage

    public init(expectedWorkspaceId: String, expectedSelectionGeneration: Int,
                expectedDigest: String, package: WorkbenchPortablePackage) throws {
        guard WorkspaceValidation.id(expectedWorkspaceId),
              (1...WorkspaceValidation.maxUInt).contains(expectedSelectionGeneration),
              WorkspaceValidation.sha256(expectedDigest),
              package.manifest.digest == expectedDigest,
              package.files.count <= 2_000 else { throw WorkspaceError.invalidSchema }
        self.expectedWorkspaceId = expectedWorkspaceId
        self.expectedSelectionGeneration = expectedSelectionGeneration
        self.expectedDigest = expectedDigest
        self.package = package
    }
}

/// Historical bytes are retained, but imported content confers no editable
/// source, installed runtime, local binding, credential or deployment consent.
public struct WorkbenchBoundedPackageImportReceipt: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let workspaceId: String
    public let selectionGeneration: Int
    public let dashboardId: String
    public let revision: String
    public let digest: String
    public let fileCount: Int
    public let includedBytes: Int
    public let storage: String
    public let provenance: String
    public let editableSourceIncluded: Bool
    public let localBindingsImported: Bool
    public let deploymentAuthority: String

    init(request: WorkbenchBoundedPackageImportRequest,
         stored: WorkbenchPortablePackage) {
        schemaVersion = 1
        workspaceId = request.expectedWorkspaceId
        selectionGeneration = request.expectedSelectionGeneration
        dashboardId = stored.manifest.dashboardId
        revision = stored.manifest.revision
        digest = stored.manifest.digest ?? ""
        fileCount = stored.files.count
        includedBytes = stored.files.values.reduce(0) { $0 + $1.count }
        storage = stored.storage
        provenance = stored.provenance
        editableSourceIncluded = false
        localBindingsImported = false
        deploymentAuthority = "none"
    }
}

/// Calls the existing immutable, collision-checked history transaction.
/// The broker must invoke this on its serial owner queue after authenticating
/// and measuring any chunked transfer against the package's full inventory.
public final class WorkbenchBoundedPackageImport {
    private let workspace: WorkspaceStore
    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func perform(_ request: WorkbenchBoundedPackageImportRequest) throws
        -> WorkbenchBoundedPackageImportReceipt {
        let stored = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            request.package, expectedWorkspaceId: request.expectedWorkspaceId,
            expectedSelectionGeneration: request.expectedSelectionGeneration)
        guard stored.manifest.digest == request.expectedDigest,
              let selected = try workspace.current(),
              selected.descriptor.workspaceId == request.expectedWorkspaceId,
              selected.selectionGeneration == request.expectedSelectionGeneration else {
            throw WorkspaceError.conflict
        }
        return .init(request: request, stored: stored)
    }
}
#endif
