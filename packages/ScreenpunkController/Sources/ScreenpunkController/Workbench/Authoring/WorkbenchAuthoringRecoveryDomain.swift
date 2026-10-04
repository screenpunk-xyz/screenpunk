import Foundation
import ScreenpunkCore
#if os(macOS)

/// Intended to run on the broker's existing serial owner queue after socket
/// authentication. The caller supplies the same old-writer exclusion check
/// used for other workspace mutations; no client can set or bypass it.
public final class WorkbenchAuthoringRecoveryDomain {
    private let workspace: WorkspaceStore
    private let mutationGate: () throws -> Void
    private let timeout: TimeInterval
    private let migrationGate: (any WorkspaceOldWriterExclusionGate)?
    private let trustedCatalog: DurableToolchainCatalogStore?
    private var plannedMigration: (plan: WorkspaceLegacyMigrationPlan, destination: String,
                                   expiresAt: TimeInterval)?

    public convenience init(workspace: WorkspaceStore, timeout: TimeInterval = 15,
                            mutationGate: @escaping () throws -> Void) {
        self.init(workspace: workspace, timeout: timeout, mutationGate: mutationGate,
            trustedCatalog: nil)
    }

    init(workspace: WorkspaceStore, timeout: TimeInterval,
         mutationGate: @escaping () throws -> Void,
         trustedCatalog: DurableToolchainCatalogStore?) {
        self.workspace = workspace; self.timeout = timeout; self.mutationGate = mutationGate
        self.migrationGate = WorkbenchMigrationWriterGate(checkOwner: mutationGate)
        self.trustedCatalog = trustedCatalog
    }

    public func perform(_ request: WorkbenchAuthoringRecoveryRequest,
                        cancelled: @escaping () -> Bool = { false },
                        progress: @escaping (WorkspaceCopyProgress) -> Void = { _ in })
        throws -> WorkbenchAuthoringRecoveryResult {
        guard timeout > 0, timeout <= 300 else { throw WorkbenchIPCError(.invalidConfiguration) }
        let extended = request.method == .migrationPlan || request.method == .migrationApply ||
            request.method == .projectClone || request.method == .packageExport ||
            request.method == .projectSourceExport || request.method == .projectSourceImport ||
            request.method == .projectOpenExternal || request.method == .projectAdoptExternal ||
            request.method == .projectRelocateExternal || request.method == .projectUpgradeKit
        let duration = request.method == .snapshotCreate || request.method == .workspaceRelocate ? timeout :
            (extended ? min(timeout, 120) : min(timeout, 15))
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        func check() throws {
            if cancelled() { throw WorkbenchIPCError(.disconnected) }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw WorkbenchIPCError(.timedOut) }
        }
        let authoring = WorkbenchContainedAuthoring(workspace: workspace,
            localReadTimeout: min(timeout, 120))
        do {
            try check()
            let result: WorkbenchAuthoringRecoveryResult
            switch request {
            case .selectionBound(let inner, let expectedId, let expectedGeneration):
                guard let current = try workspace.current(),
                      current.descriptor.workspaceId == expectedId,
                      current.selectionGeneration == expectedGeneration else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                try check()
                result = try perform(inner, cancelled: cancelled, progress: progress)
            case .projectCreate(let name, let kind):
                try mutationGate(); try check()
                let project = try authoring.create(name: name, kind: kind,
                    trustedKitVersion: kind == "react" ? "builtin-react-1" : "builtin-web-1")
                result = .init(kind: .authoringProject, project: project)
            case .projectClone(let id, let version, let name):
                try mutationGate(); try check()
                let project = try WorkbenchPortableSourceArchive(workspace: workspace)
                    .cloneCurrent(projectId: id, expectedSourceVersion: version,
                        destinationName: name)
                result = .init(kind: .authoringProject, project: project)
            case .projectUnregister(let id, let expectedGeneration):
                try mutationGate(); try check()
                let overview = try workspace.unregisterProject(id,
                    expectedCatalogGeneration: expectedGeneration)
                do {
                    result = .init(kind: .projectUnregistered,
                        projectUnregistered: try .init(projectId: id, overview: overview))
                } catch { throw WorkbenchIPCError(.publicationOutcomeUnknown) }
            case .projectRelocateContained(let id, let sourceVersion, let destination,
                                           let expectedGeneration):
                try mutationGate(); try check()
                let before = try authoring.get(id, deadline: deadline, cancelled: cancelled)
                guard before.sourceVersion == sourceVersion else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                let overview = try workspace.relocateContainedProject(id,
                    expectedSourceVersion: sourceVersion, to: destination,
                    expectedCatalogGeneration: expectedGeneration)
                guard let project = overview.catalog.projects.first(where: { $0.projectId == id }) else {
                    throw WorkbenchIPCError(.publicationOutcomeUnknown)
                }
                result = .init(kind: .authoringProject,
                    project: WorkbenchSourceProject(project: project,
                        path: overview.path + "/" + destination,
                        sourceVersion: sourceVersion, sourceHashVersion: before.sourceHashVersion,
                        fileCount: before.fileCount, includedBytes: before.includedBytes))
            case .projectUpgradeKit(let id, let sourceVersion, let expectedGeneration,
                                    let requirement):
                try mutationGate(); try check()
                guard let trustedCatalog else {
                    throw WorkbenchIPCError(.toolchainTrustUnavailable)
                }
                let upgraded = try trustedCatalog.withResolved(requirement) { resolver, approved in
                    let verified = try resolver.verifyInstalled(approved)
                    try check()
                    return try authoring.upgradeKit(id, expectedSourceVersion: sourceVersion,
                        expectedCatalogGeneration: expectedGeneration, verifiedKit: verified)
                }
                result = .init(kind: .authoringProject, project: upgraded)
            case .projectInspect(let id):
                let project = try authoring.get(id, deadline: deadline, cancelled: cancelled)
                try check()
                result = .init(kind: .authoringProject, project: project)
            case .projectPatch(let id, let expectedSourceVersion, let changes):
                try mutationGate(); try check()
                let project = try authoring.patch(id, expectedSourceVersion: expectedSourceVersion,
                                                  changes: changes)
                result = .init(kind: .authoringProject, project: project)
            case .projectOpenContained(let path):
                try mutationGate(); try check()
                let project = try authoring.openContained(at: path)
                result = .init(kind: .authoringProject, project: project)
            case .projectSourceExport(let id, let version, let path):
                try mutationGate(); try check()
                let archive = WorkbenchPortableSourceArchive(workspace: workspace)
                let receipt: WorkbenchPortableSourceArchiveReceipt
                do { receipt = try archive.export(projectId: id,
                    expectedSourceVersion: version, to: path) }
                catch WorkspaceError.conflict {
                    receipt = try archive.exportRetained(projectId: id,
                        sourceVersion: version, to: path)
                }
                result = .init(kind: .sourceArchive, sourceArchive: receipt)
            case .projectSourceImport(let path, let name):
                try mutationGate(); try check()
                let imported = try WorkbenchPortableSourceArchive(workspace: workspace)
                    .importSource(from: path, destinationName: name)
                result = .init(kind: .authoringProject, project: imported)
            case .projectOpenExternal(let path):
                try mutationGate(); try check()
                let archive = WorkbenchPortableSourceArchive(workspace: workspace)
                let (project, version) = try archive.openExternalVersioned(at: path,
                    explicitExternal: true)
                result = .init(kind: .sourceLocation, sourceLocation: .init(
                    project: project, path: path, sourceVersion: version,
                    backupCoverage: "outside-workspace-backup-coverage"))
            case .projectAdoptExternal(let id, let version, let name):
                try mutationGate(); try check()
                let archive = WorkbenchPortableSourceArchive(workspace: workspace)
                guard let workspacePath = try workspace.current()?.path else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                let project = try archive.adoptExternal(projectId: id,
                    expectedSourceVersion: version, name: name)
                guard let relative = project.location.path else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                result = .init(kind: .sourceLocation, sourceLocation: .init(
                    project: project, path: workspacePath + "/" + relative, sourceVersion: version,
                    backupCoverage: "included-in-workspace-backup"))
            case .projectRelocateExternal(let id, let version, let path):
                try mutationGate(); try check()
                guard let generation = try workspace.current()?.selectionGeneration else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                let updated = try workspace.rebindExternal(id, to: path,
                    expectedSourceVersion: version,
                    expectedSelectionGeneration: generation)
                guard let project = updated.catalog.projects.first(where: { $0.projectId == id }) else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                result = .init(kind: .sourceLocation, sourceLocation: .init(
                    project: project, path: path, sourceVersion: version,
                    backupCoverage: "outside-workspace-backup-coverage"))
            case .buildRun(let id, let expectedSourceVersion, let baseRevision):
                try mutationGate(); try check()
                try requirePlainWeb(projectId: id)
                let coordinator = plainWebCoordinator()
                let built = try coordinator.build(projectID: id,
                    expectedSourceVersion: expectedSourceVersion, baseRevision: baseRevision,
                    cancelled: { cancelled() || ProcessInfo.processInfo.systemUptime >= deadline })
                result = .init(kind: .buildHead, build: buildRead(built.head, diagnostics: built.diagnostics))
            case .buildHead(let id):
                guard let head = try plainWebCoordinator().readHead(projectID: id)?.0 else {
                    throw WorkbenchIPCError(.unavailable)
                }
                try check()
                result = .init(kind: .buildHead, build: buildRead(head, diagnostics: ""))
            case .packageHistory(let cursorValue):
                guard let selected = try workspace.current(),
                      let selectionGeneration = selected.selectionGeneration else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                let cursor = try cursorValue.map(WorkbenchWorkspacePackageCursor.parse)
                if let cursor {
                    guard cursor.workspaceId == selected.descriptor.workspaceId,
                          cursor.selectionGeneration == selectionGeneration,
                          cursor.historyGeneration == selected.descriptor.generation else {
                        throw WorkbenchIPCError(.workspaceConflict)
                    }
                }
                let page = try WorkbenchPortablePackages(workspace: workspace,
                    localReadTimeout: timeout).listPage(afterObjectId: cursor?.lastObjectId,
                        expectedInventoryHash: cursor?.inventoryHash,
                        deadline: deadline, cancelled: cancelled)
                let nextCursor = page.hasMore ? WorkbenchWorkspacePackageCursor(
                    workspaceId: selected.descriptor.workspaceId,
                    selectionGeneration: selectionGeneration,
                    historyGeneration: selected.descriptor.generation,
                    inventoryHash: page.inventoryHash,
                    lastObjectId: page.lastObjectId!).value : nil
                try check()
                result = .init(kind: .packageHistory, packages: page.manifests.map {
                    WorkbenchPackageHistoryRead(dashboardId: $0.dashboardId,
                        revision: $0.revision, digest: $0.digest ?? "", name: $0.name,
                        fileCount: $0.files.count, provenance: "workspace-history-untrusted")
                }, hasMore: page.hasMore, nextCursor: nextCursor)
            case .packageExport(let dashboardId, let revision, let path):
                try mutationGate(); try check()
                let exported = try WorkbenchPortablePackageArchive(workspace: workspace).export(
                    dashboardId: dashboardId, revision: revision, to: path,
                    deadline: deadline, cancelled: cancelled)
                result = .init(kind: .packageExport, packageExport: exported)
            case .snapshotCreate(let path, let includeExternal, let allowIncomplete):
                try mutationGate(); try check()
                let value = try WorkspaceSnapshot(workspace: workspace).create(at: path,
                    includeExternal: includeExternal, allowIncomplete: allowIncomplete,
                    timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime),
                    cancelled: cancelled, progress: progress)
                result = .init(kind: .workspaceSnapshot, snapshot: .init(path: value.path,
                    workspaceId: value.workspaceId, generation: value.generation,
                    fileCount: value.fileCount, includedBytes: value.includedBytes,
                    complete: value.complete, scope: "authoring",
                    excludedExternalProjectIds: value.excludedExternalProjectIds,
                    unregisteredScreenPaths: value.unregisteredScreenPaths,
                    omittedAuxiliaryPaths: value.omittedAuxiliaryPaths))
            case .workspaceRelocate(let path):
                try mutationGate(); try check()
                let value = try WorkspaceRelocation(workspace: workspace).relocate(to: path,
                    timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime),
                    cancelled: cancelled, progress: progress)
                result = .init(kind: .workspaceRelocation, relocation: value)
            case .workspaceConfigGet, .workspaceConfigPath:
                let value = try WorkbenchWorkspaceConfiguration(workspace: workspace).get()
                try check()
                result = .init(kind: .workspaceConfiguration, configuration: value)
            case .workspaceConfigSet(let key, let value, let expectedGeneration):
                try mutationGate(); try check()
                let updated = try WorkbenchWorkspaceConfiguration(workspace: workspace)
                    .set(key: key, value: value, expectedGeneration: expectedGeneration)
                result = .init(kind: .workspaceConfiguration, configuration: updated)
            case .workspaceConfigUnset(let key, let expectedGeneration):
                try mutationGate(); try check()
                let updated = try WorkbenchWorkspaceConfiguration(workspace: workspace)
                    .unset(key: key, expectedGeneration: expectedGeneration)
                result = .init(kind: .workspaceConfiguration, configuration: updated)
            case .migrationPlan(let path, let destination):
                plannedMigration = nil
                let plan = try WorkspaceLegacyMigration(workspace: workspace).inspectLegacy(at: path,
                    timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime),
                    cancelled: cancelled)
                try check()
                let summary = plan.summary
                if let destination {
                    guard WorkspaceValidation.absolute(destination),
                          destination != path, !destination.hasPrefix(path + "/"),
                          !path.hasPrefix(destination + "/") else {
                        throw WorkbenchIPCError(.invalidWorkspacePath)
                    }
                    if summary.unsupportedPortablePaths.isEmpty {
                        plannedMigration = (plan, destination,
                            ProcessInfo.processInfo.systemUptime + 600)
                    }
                }
                result = .init(kind: .migrationPlan, migrationPlan: migrationRead(summary,
                    destination: destination))
            case .migrationReview(let id):
                guard let pending = plannedMigration,
                      pending.plan.summary.migrationId == id,
                      ProcessInfo.processInfo.systemUptime < pending.expiresAt else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                result = .init(kind: .migrationPlan, migrationPlan: migrationRead(
                    pending.plan.summary, destination: pending.destination))
            case .migrationApply(let id):
                guard let pending = plannedMigration,
                      pending.plan.summary.migrationId == id,
                      ProcessInfo.processInfo.systemUptime < pending.expiresAt,
                      let migrationGate,
                      try workspace.current() == nil else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                plannedMigration = nil // one attempt; a failed/uncertain copy needs a new review
                try mutationGate(); try check()
                let overview = try WorkspaceLegacyMigration(workspace: workspace).apply(
                    pending.plan, to: pending.destination, gate: migrationGate,
                    timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime),
                    cancelled: cancelled)
                result = .init(kind: .migrationApplied,
                    migrationApplied: WorkbenchWorkspaceStatus(overview: overview))
            }
            do { try result.validate(for: request.method) }
            catch {
                let readMethods: Set<WorkbenchAuthoringRecoveryMethod> = [
                    .projectInspect, .buildHead, .packageHistory,
                    .workspaceConfigGet, .workspaceConfigPath, .migrationPlan]
                if readMethods.contains(request.method) { throw error }
                throw WorkbenchIPCError(.publicationOutcomeUnknown)
            }
            return result
        } catch let error as WorkbenchIPCError { throw error }
        catch let error as WorkbenchBuildConflict {
            switch error {
            case .sourceVersion: throw WorkbenchIPCError(.buildSourceConflict)
            case .baseRevision: throw WorkbenchIPCError(.buildHeadConflict)
            }
        }
        catch is ToolchainTrustError { throw WorkbenchIPCError(.toolchainTrustUnavailable) }
        catch is WorkspaceAppliedMutationReadUnavailable {
            throw WorkbenchIPCError(.publicationOutcomeUnknown)
        }
        catch is WorkbenchPortablePackageExportPublicationUncertain {
            throw WorkbenchIPCError(.publicationOutcomeUnknown)
        }
        catch let error as WorkspaceError {
            switch error {
            case .invalidPath, .unsafeFile: throw WorkbenchIPCError(.invalidWorkspacePath)
            case .invalidSchema: throw WorkbenchIPCError(.invalidRequest)
            case .newerSchema: throw WorkbenchIPCError(.unsupportedVersion)
            case .conflict: throw WorkbenchIPCError(.workspaceConflict)
            case .alreadyExists: throw WorkbenchIPCError(.workspaceExists)
            case .incomplete: throw WorkbenchIPCError(.workspaceIncomplete)
            case .limitExceeded: throw WorkbenchIPCError(.resourceLimit)
            case .unavailable: throw WorkbenchIPCError(cancelled() ? .disconnected :
                ProcessInfo.processInfo.systemUptime >= deadline ? .timedOut : .unavailable)
            }
        }
    }

    private func migrationRead(_ summary: WorkspaceLegacyMigrationSummary,
                               destination: String?) -> WorkbenchMigrationPlanRead {
        .init(migrationId: summary.migrationId, sourcePath: summary.sourcePath,
              destinationPath: destination, projectIds: summary.projectIds,
              packageRevisions: summary.packageRevisions,
              portableBytes: summary.portableBytes, expandedBytes: summary.expandedBytes,
              plannedMembers: summary.plannedMembers,
              unsupportedPortablePaths: summary.unsupportedPortablePaths,
              excludedClasses: summary.excludedClasses,
              applyAvailable: destination != nil && summary.unsupportedPortablePaths.isEmpty)
    }

    private func plainWebCoordinator() -> WorkbenchBuildCoordinator {
        WorkbenchBuildCoordinator(workspace: workspace) { _, _, _, _, _, _ in
            throw WorkbenchIPCError(.methodNotFound)
        }
    }
    private func requirePlainWeb(projectId: String) throws {
        guard let overview = try workspace.current(),
              let project = overview.catalog.projects.first(where: { $0.projectId == projectId }),
              let relative = project.location.path else { throw WorkbenchIPCError(.unavailable) }
        let root = try WorkspaceFiles(path: overview.path)
        let folder = try root.directory(relative.split(separator: "/").map(String.init))
        defer { close(folder) }
        let document = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
            from: root.read(folder, "screenpunk.project.json"), shape: .project)
        try document.validate(matching: project)
        guard document.kind == "web" else { throw WorkbenchIPCError(.methodNotFound) }
    }
    private func buildRead(_ head: WorkbenchBuildHead, diagnostics: String) -> WorkbenchBuildRead {
        WorkbenchBuildRead(projectId: head.projectID, dashboardId: head.dashboardID,
            sourceVersion: head.sourceVersion, revision: head.revision,
            digest: head.digest, diagnostics: String(diagnostics.prefix(2_000)))
    }
}
#endif
