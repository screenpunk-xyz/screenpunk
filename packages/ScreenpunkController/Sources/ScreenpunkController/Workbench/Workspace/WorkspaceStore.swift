import Foundation
#if os(macOS)
import Darwin

public struct WorkspaceOverview: Sendable {
    public let path: String
    public let descriptor: WorkspaceDescriptor
    public let catalog: WorkspaceCatalog
    public let settings: WorkspaceSettings
    public let coverage: WorkspaceCoverage
    public let selectionGeneration: Int?
    public let historyAuthority = "historical-only"
    public let localConnections = "unconfigured"
    public let authenticatedDeviceCount = 0
}

/// Service-owned visible workspace core. Construction and proposal are inert; create/open
/// require explicit calls and never bootstrap a controller, installed kit or device identity.
public final class WorkspaceStore {
    private let documents: any WorkspaceDocumentsResolver
    private let postCommitReadGate: () throws -> Void
    public let selection: WorkspaceSelectionStore
    public init(documents: any WorkspaceDocumentsResolver, machineRootPath: String) throws {
        self.documents = documents; postCommitReadGate = {}
        selection = try WorkspaceSelectionStore(machineRootPath: machineRootPath)
    }
    init(documents: any WorkspaceDocumentsResolver, machineRootPath: String,
         postCommitReadGate: @escaping () throws -> Void) throws {
        self.documents = documents; self.postCommitReadGate = postCommitReadGate
        selection = try WorkspaceSelectionStore(machineRootPath: machineRootPath)
    }
    public func proposedPath() throws -> String {
        let path = try documents.documentsDirectory().path
        guard WorkspaceValidation.absolute(path) else { throw WorkspaceError.invalidPath }
        return path + "/Screenpunk"
    }
    @discardableResult public func create(at explicitPath: String? = nil, name: String = "Screenpunk") throws -> WorkspaceOverview {
        try create(at: explicitPath, name: name, readBudget: nil)
    }
    @discardableResult func create(at explicitPath: String?, name: String = "Screenpunk",
                                   readBudget: WorkspaceReadBudget?, beforeSelection: () throws -> Void = {}) throws -> WorkspaceOverview {
        try readBudget?.check()
        guard WorkspaceValidation.text(name) else { throw WorkspaceError.invalidSchema }
        let path = try (explicitPath ?? proposedPath())
        let root = try WorkspaceFiles(path: path, create: true) // Any existing destination fails; no clobber.
        for parts in [
            ["Screens"], ["Workbench"], ["Workbench", "Library"], ["Workbench", "Settings"],
            ["Workbench", "History"], ["Workbench", "History", "Builds"],
            ["Workbench", "History", "Packages"], ["Workbench", "History", "Prepared"],
            ["Workbench", "History", "Deployments"], ["Workbench", "Attachments"],
            ["Workbench", "Toolchains"], ["Workbench", "Transactions"], ["Workbench", "Migrations"]
        ] { let fd = try root.directory(parts, create: true); close(fd) }
        let descriptor = WorkspaceDescriptor(name: name)
        try root.write(root.fd, "workspace.json", data: WorkspaceJSON.encode(descriptor), expected: nil)
        try writeNew(WorkspaceCatalog(), root: root, parent: ["Workbench", "Library"], name: "catalog.json")
        try writeNew(WorkspaceSettings(), root: root, parent: ["Workbench", "Settings"], name: "workbench.json")
        try writeNew(WorkspaceConnections(), root: root, parent: ["Workbench", "Settings"], name: "connections.json")
        try writeNew(WorkspaceToolchainRequirements(), root: root, parent: ["Workbench", "Toolchains"], name: "requirements.json")
        let selected = try selection.select(path: path, descriptor: descriptor, identity: root.identity,
                                            readBudget: readBudget, beforeCommit: beforeSelection)
        return try inspect(root: root, selected: selected, readBudget: readBudget)
    }
    @discardableResult public func open(at path: String) throws -> WorkspaceOverview {
        try open(at: path, readBudget: nil)
    }
    @discardableResult func open(at path: String, readBudget: WorkspaceReadBudget?,
                                 beforeSelection: () throws -> Void = {}) throws -> WorkspaceOverview {
        try readBudget?.check()
        let root = try WorkspaceFiles(path: path)
        let preview = try inspect(root: root, selected: nil, readBudget: readBudget)
        guard preview.coverage.missingPaths.isEmpty else { throw WorkspaceError.incomplete }
        let selected = try selection.select(path: path, descriptor: preview.descriptor, identity: root.identity,
                                            readBudget: readBudget, beforeCommit: beforeSelection)
        return try inspect(root: root, selected: selected, readBudget: readBudget)
    }
    public func inspect(at path: String) throws -> WorkspaceOverview { try inspect(root: WorkspaceFiles(path: path), selected: nil) }
    func inspect(at path: String, readBudget: WorkspaceReadBudget) throws -> WorkspaceOverview {
        try inspect(root: WorkspaceFiles(path: path), selected: nil, readBudget: readBudget)
    }
    public func current() throws -> WorkspaceOverview? { try current(readBudget: nil) }
    func current(readBudget: WorkspaceReadBudget?) throws -> WorkspaceOverview? {
        try readBudget?.check()
        guard let active = try selection.current(readBudget: readBudget) else { return nil }
        let root = try WorkspaceFiles(path: active.activePath)
        try readBudget?.requireLocal(root.fd)
        guard root.identity.device == active.rootDevice, root.identity.inode == active.rootInode else { throw WorkspaceError.conflict }
        let result = try inspect(root: root, selected: active, readBudget: readBudget)
        guard result.descriptor.workspaceId == active.workspaceId else { throw WorkspaceError.conflict }
        try readBudget?.check()
        return result
    }
    public func nextContainedDestination(named name: String) throws -> String {
        guard WorkspaceValidation.text(name), !name.isEmpty else { throw WorkspaceError.invalidPath }
        let overview = try requireCurrent()
        let root = try WorkspaceFiles(path: overview.path)
        let screens = try root.directory(["Screens"]); defer { close(screens) }
        let base = String(name.precomposedStringWithCanonicalMapping.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        guard !base.isEmpty else { throw WorkspaceError.invalidPath }
        for suffix in 1...10_000 {
            let candidate = suffix == 1 ? base : base + "-\(suffix)"
            guard candidate.utf8.count <= 200 else { throw WorkspaceError.limitExceeded }
            let relative = "Screens/" + candidate
            let collision = overview.catalog.projects.contains { $0.location.path?.precomposedStringWithCanonicalMapping.lowercased() == relative.precomposedStringWithCanonicalMapping.lowercased() }
            let filePresent = try root.exists(screens, candidate)
            if !collision && !filePresent { return relative }
        }
        throw WorkspaceError.limitExceeded
    }
    @discardableResult public func registerContained(_ project: WorkspaceProject, expectedCatalogGeneration: Int) throws -> WorkspaceOverview {
        guard project.location.kind == "workspace", let relative = project.location.path else { throw WorkspaceError.invalidPath }
        try project.validate()
        let active = try requireSelected()
        let root = try WorkspaceFiles(path: active.activePath)
        try verifySelected(root, active)
        let parts = relative.split(separator: "/").map(String.init)
        _ = try validateProject(project, root: root, relative: parts)
        return try mutateCatalog(root: root, active: active, expectedGeneration: expectedCatalogGeneration, project: project)
    }
    @discardableResult public func registerExternal(_ project: WorkspaceProject, sourcePath: String,
                                                     explicitExternal: Bool, expectedCatalogGeneration: Int) throws -> WorkspaceOverview {
        guard explicitExternal, project.location.kind == "external", let reference = project.location.referenceId,
              WorkspaceValidation.absolute(sourcePath) else { throw WorkspaceError.invalidPath }
        try project.validate()
        let active = try requireSelected()
        let root = try WorkspaceFiles(path: active.activePath)
        try verifySelected(root, active)
        guard externalPathAllowed(sourcePath, workspace: active.activePath) else { throw WorkspaceError.invalidPath }
        let external = try WorkspaceFiles(path: sourcePath, requiredPrivateRoot: false)
        _ = try validateProject(project, root: external, relative: [])
        try external.verifyRoot()
        return try mutateCatalog(root: root, active: active, expectedGeneration: expectedCatalogGeneration,
                                 project: project, external: (reference, sourcePath, external.identity))
    }
    /// Rebind an existing external catalog entry to an explicitly selected,
    /// verified folder. This changes only machine-local selection state; it
    /// neither copies source nor adds authority to portable metadata.
    @discardableResult public func rebindExternal(_ projectId: String, to path: String,
        expectedSourceVersion: String, expectedSelectionGeneration: Int) throws -> WorkspaceOverview {
        guard WorkspaceValidation.id(projectId), WorkspaceValidation.absolute(path),
              WorkspaceValidation.sha256(expectedSourceVersion) else {
            throw WorkspaceError.invalidPath
        }
        let active = try requireSelected()
        guard active.selectionGeneration == expectedSelectionGeneration,
              let overview = try current(),
              overview.selectionGeneration == expectedSelectionGeneration,
              let project = overview.catalog.projects.first(where: { $0.projectId == projectId }),
              let reference = project.location.referenceId,
              externalPathAllowed(path, workspace: overview.path),
              externalPathAllowed(path, workspace: selection.machineRootPath) else {
            throw WorkspaceError.conflict
        }
        let proposedKey = WorkspaceValidation.portableKey(path)
        guard !active.externalBindings.contains(where: { key, value in
            key != reference && WorkspaceValidation.portableKey(value.path) == proposedKey
        }) else { throw WorkspaceError.conflict }
        let source = try WorkspaceFiles(path: path, requiredPrivateRoot: false)
        let archive = WorkbenchPortableSourceArchive(workspace: self)
        guard try archive.capture(path: path, project: project).2 == expectedSourceVersion,
              try archive.capture(path: path, project: project).2 == expectedSourceVersion else {
            throw WorkspaceError.conflict
        }
        try source.verifyRoot()
        _ = try selection.bind(reference: reference, path: path, identity: source.identity,
            expectedSelection: expectedSelectionGeneration,
            workspaceId: overview.descriptor.workspaceId)
        return try readAfterCommittedMutation(operation: "externalRebind",
            workspaceId: overview.descriptor.workspaceId, projectId: projectId) { rebound in
            guard rebound.selectionGeneration == expectedSelectionGeneration + 1 else { return false }
            return try self.resolveProject(projectId) == path
        }
    }
    /// The copied contained tree is complete before the catalog switches from its
    /// machine-local external reference. A failed switch leaves an inert copy;
    /// a failed binding cleanup leaves only an inert local binding.
    func adoptExternal(_ projectId: String, to relative: String,
                       expectedCatalogGeneration: Int,
                       verifySource: () throws -> Void) throws {
        guard WorkspaceValidation.id(projectId), WorkspaceValidation.member(relative),
              relative.split(separator: "/").count == 2,
              relative.hasPrefix("Screens/") else { throw WorkspaceError.invalidPath }
        let active = try requireSelected()
        let root = try WorkspaceFiles(path: active.activePath)
        try verifySelected(root, active)
        guard let overview = try current(), overview.catalog.generation == expectedCatalogGeneration,
              let index = overview.catalog.projects.firstIndex(where: { $0.projectId == projectId }),
              let reference = overview.catalog.projects[index].location.referenceId,
              active.externalBindings[reference] != nil else { throw WorkspaceError.conflict }
        let old = overview.catalog.projects[index]
        let replacement = WorkspaceProject(projectId: old.projectId,
            dashboardId: old.dashboardId, name: old.name,
            location: .contained(relative), collectionIds: old.collectionIds,
            sortOrder: old.sortOrder)
        _ = try validateProject(replacement, root: root,
            relative: relative.split(separator: "/").map(String.init))
        try verifySource()
        var projects = overview.catalog.projects
        projects[index] = replacement
        try commitMetadata(overview: overview, projects: projects,
            presentation: overview.settings.presentation, profiles: overview.settings.profiles)
        // The catalog is already authoritative; cleanup can safely be retried.
        _ = try? selection.unbind(reference: reference, expectedSelection: active.selectionGeneration,
                                 expectedWorkspaceId: active.workspaceId)
    }
    public func resolveProject(_ projectId: String) throws -> String? {
        try resolveProject(projectId, readBudget: nil)
    }
    func resolveProject(_ projectId: String, readBudget: WorkspaceReadBudget?) throws -> String? {
        guard let overview = try current(readBudget: readBudget) else { throw WorkspaceError.unavailable }
        guard let project = overview.catalog.projects.first(where: { $0.projectId == projectId }) else { return nil }
        if let relative = project.location.path {
            try readBudget?.check()
            let root = try WorkspaceFiles(path: overview.path)
            _ = try validateProject(project, root: root, relative: relative.split(separator: "/").map(String.init),
                                    readBudget: readBudget)
            try root.verifyRoot()
            try readBudget?.check()
            return overview.path + "/" + relative
        }
        guard let reference = project.location.referenceId, let active = try selection.current(readBudget: readBudget),
              active.activePath == overview.path, let binding = active.externalBindings[reference] else { return nil }
        do {
            guard externalPathAllowed(binding.path, workspace: overview.path) else { return nil }
            let source = try WorkspaceFiles(path: binding.path, requiredPrivateRoot: false)
            try readBudget?.requireLocal(source.fd)
            guard source.identity.device == binding.device && source.identity.inode == binding.inode else { return nil }
            _ = try validateProject(project, root: source, relative: [], readBudget: readBudget)
            try source.verifyRoot()
            try readBudget?.check()
            return binding.path
        } catch WorkspaceError.unavailable { throw WorkspaceError.unavailable }
        catch { return nil }
    }
    @discardableResult public func updateSettings(_ presentation: [String: String],
                                                   profiles: [String: [String: String]], expectedGeneration: Int) throws -> WorkspaceSettings {
        guard let overview = try current(), overview.settings.generation == expectedGeneration else {
            throw WorkspaceError.conflict
        }
        return try commitMetadata(overview: overview, projects: overview.catalog.projects,
            presentation: presentation, profiles: profiles)
    }

    /// One portable library-presentation edit. The broker supplies the exact
    /// selected workspace and generation; no machine identity or package bytes
    /// are stored in this map.
    @discardableResult public func updateScreenIcon(dashboardId: String, symbol: String,
        expectedWorkspaceId: String, expectedSelectionGeneration: Int,
        expectedGeneration: Int) throws -> WorkspaceSettings {
        guard WorkspaceValidation.id(dashboardId), WorkspaceValidation.id(expectedWorkspaceId),
              WorkspaceSettings.validSymbol(symbol),
              let overview = try current(),
              overview.descriptor.workspaceId == expectedWorkspaceId,
              overview.selectionGeneration == expectedSelectionGeneration,
              overview.descriptor.generation == expectedGeneration else {
            throw WorkspaceError.conflict
        }
        var icons = overview.settings.screenIcons
        icons[dashboardId] = symbol
        if icons == overview.settings.screenIcons { return overview.settings }
        return try commitMetadata(overview: overview, projects: overview.catalog.projects,
            presentation: overview.settings.presentation, profiles: overview.settings.profiles,
            screenIcons: icons)
    }

    /// Removes only the portable catalog reference. Source folders and all
    /// retained history stay in place for explicit later recovery or reopening.
    /// An external binding is revoked first; if the portable commit then fails,
    /// the still-registered external project is safely unresolved on this Mac.
    @discardableResult public func unregisterProject(_ projectId: String,
                                                     expectedCatalogGeneration: Int) throws
        -> WorkspaceOverview {
        guard WorkspaceValidation.id(projectId),
              let initial = try current(),
              let initialSelectionGeneration = initial.selectionGeneration,
              initial.catalog.generation == expectedCatalogGeneration,
              let project = initial.catalog.projects.first(where: { $0.projectId == projectId })
        else { throw WorkspaceError.conflict }
        var expectedSelectionGeneration = initialSelectionGeneration
        var unboundExternalReference = false
        if let reference = project.location.referenceId,
           let active = try selection.current(),
           active.externalBindings[reference] != nil {
            _ = try selection.unbind(reference: reference,
                expectedSelection: initialSelectionGeneration,
                expectedWorkspaceId: initial.descriptor.workspaceId)
            expectedSelectionGeneration += 1
            unboundExternalReference = true
        }
        let selected: WorkspaceOverview?
        do { selected = try current() }
        catch {
            if unboundExternalReference {
                throw WorkspaceAppliedMutationReadUnavailable(operation: "externalUnbind",
                    workspaceId: initial.descriptor.workspaceId, projectId: projectId)
            }
            throw error
        }
        guard let selected,
              selected.path == initial.path,
              selected.selectionGeneration == expectedSelectionGeneration,
              selected.descriptor.workspaceId == initial.descriptor.workspaceId,
              selected.catalog == initial.catalog else { throw WorkspaceError.conflict }
        let projects = selected.catalog.projects.filter { $0.projectId != projectId }
        _ = try commitMetadata(overview: selected, projects: projects,
            presentation: selected.settings.presentation, profiles: selected.settings.profiles)
        return try readAfterCommittedMutation(operation: "projectUnregister",
            workspaceId: selected.descriptor.workspaceId, projectId: projectId) { result in
            !result.catalog.projects.contains(where: { $0.projectId == projectId })
        }
    }

    /// Switches a contained project's catalog location to an independently
    /// prepared Screens folder with the same identity and exact source hash.
    /// The filesystem copy/move is a separate explicit user operation.
    @discardableResult public func relocateContainedProject(_ projectId: String,
        expectedSourceVersion: String, to relative: String,
        expectedCatalogGeneration: Int) throws -> WorkspaceOverview {
        guard WorkspaceValidation.id(projectId), WorkspaceValidation.sha256(expectedSourceVersion),
              let initial = try current(),
              let selectionGeneration = initial.selectionGeneration,
              initial.catalog.generation == expectedCatalogGeneration,
              let project = initial.catalog.projects.first(where: { $0.projectId == projectId }),
              let oldRelative = project.location.path,
              oldRelative != relative else { throw WorkspaceError.conflict }
        try WorkspaceProjectLocation.contained(relative).validate()
        guard !initial.catalog.projects.contains(where: { $0.location.path == relative }) else {
            throw WorkspaceError.conflict
        }
        let destination = WorkspaceProject(projectId: project.projectId,
            dashboardId: project.dashboardId, name: project.name,
            location: .contained(relative), collectionIds: project.collectionIds,
            sortOrder: project.sortOrder)
        let archive = WorkbenchPortableSourceArchive(workspace: self)
        let targetPath = initial.path + "/" + relative
        let targetRoot = try WorkspaceFiles(path: targetPath)
        let targetIdentity = targetRoot.identity
        let target = try archive.capture(path: targetPath, project: destination)
        guard target.0.name == project.name,
              target.2 == expectedSourceVersion else { throw WorkspaceError.conflict }
        let originalPath = initial.path + "/" + oldRelative
        let originalRoot: WorkspaceFiles?
        do { originalRoot = try WorkspaceFiles(path: originalPath) }
        catch WorkspaceError.unavailable { originalRoot = nil }
        let originalIdentity = originalRoot?.identity
        if originalRoot != nil {
            let source = try archive.capture(path: originalPath, project: project)
            guard source.0 == target.0, source.1 == target.1,
                  source.2 == expectedSourceVersion else { throw WorkspaceError.conflict }
        }
        let recheck: () throws -> Void = {
            guard let active = try self.selection.current(),
                  active.activePath == initial.path,
                  active.selectionGeneration == selectionGeneration,
                  active.workspaceId == initial.descriptor.workspaceId,
                  try WorkspaceFiles(path: targetPath).identity == targetIdentity else {
                throw WorkspaceError.conflict
            }
            let updated = try archive.capture(path: targetPath, project: destination)
            guard updated.0 == target.0, updated.1 == target.1,
                  updated.2 == expectedSourceVersion else { throw WorkspaceError.conflict }
            if let originalIdentity {
                guard try WorkspaceFiles(path: originalPath).identity == originalIdentity else {
                    throw WorkspaceError.conflict
                }
                let source = try archive.capture(path: originalPath, project: project)
                guard source.0 == target.0, source.1 == target.1,
                      source.2 == expectedSourceVersion else { throw WorkspaceError.conflict }
            }
        }
        try recheck()
        let projects = initial.catalog.projects.map { $0.projectId == projectId ? destination : $0 }
        _ = try commitMetadata(overview: initial, projects: projects,
            presentation: initial.settings.presentation, profiles: initial.settings.profiles,
            referenceValidationHook: recheck)
        return try readAfterCommittedMutation(operation: "projectRelocate",
            workspaceId: initial.descriptor.workspaceId, projectId: projectId) { result in
            result.catalog.projects.first(where: { $0.projectId == projectId }) == destination
        }
    }
    private func mutateCatalog(root: WorkspaceFiles, active: WorkspaceSelection, expectedGeneration: Int,
                               project: WorkspaceProject, external: (String, String, WorkspaceNodeID)? = nil) throws -> WorkspaceOverview {
        try verifySelected(root, active)
        guard let initial = try current(), initial.catalog.generation == expectedGeneration else {
            throw WorkspaceError.conflict
        }
        let nextProjects = initial.catalog.projects + [project]
        try WorkspaceCatalog(generation: initial.descriptor.generation + 1,
            projects: nextProjects,
            archivedDashboardIds: initial.catalog.archivedDashboardIds).validate()
        if let relative = project.location.path {
            _ = try validateProject(project, root: root,
                relative: relative.split(separator: "/").map(String.init))
            try root.verifyRoot()
        }
        if let external {
            guard externalPathAllowed(external.1, workspace: active.activePath) else {
                throw WorkspaceError.invalidPath
            }
            let source = try WorkspaceFiles(path: external.1, requiredPrivateRoot: false)
            guard source.identity == external.2 else { throw WorkspaceError.conflict }
            _ = try validateProject(project, root: source, relative: [])
            try source.verifyRoot()
            // If publication fails this is only an inert local binding. It is
            // never sufficient to establish a portable catalog entry.
            _ = try selection.bind(reference: external.0, path: external.1,
                identity: external.2, expectedSelection: active.selectionGeneration,
                workspaceId: active.workspaceId)
        }
        let selected: WorkspaceOverview?
        do { selected = try current() }
        catch {
            if external != nil {
                throw WorkspaceAppliedMutationReadUnavailable(operation: "externalBind",
                    workspaceId: initial.descriptor.workspaceId, projectId: project.projectId)
            }
            throw error
        }
        guard let selected, selected.descriptor.workspaceId == initial.descriptor.workspaceId,
              selected.catalog == initial.catalog else { throw WorkspaceError.conflict }
        try commitMetadata(overview: selected, projects: nextProjects,
            presentation: selected.settings.presentation, profiles: selected.settings.profiles)
        return try readAfterCommittedMutation(operation: "projectRegister",
            workspaceId: selected.descriptor.workspaceId, projectId: project.projectId) { result in
            result.catalog.projects.contains(project)
        }
    }

    private func readAfterCommittedMutation(operation: String, workspaceId: String,
        projectId: String?, validate: (WorkspaceOverview) throws -> Bool) throws -> WorkspaceOverview {
        do {
            try postCommitReadGate()
            guard let result = try current(), result.descriptor.workspaceId == workspaceId,
                  try validate(result) else { throw WorkspaceError.conflict }
            return result
        } catch {
            throw WorkspaceAppliedMutationReadUnavailable(operation: operation,
                workspaceId: workspaceId, projectId: projectId)
        }
    }

    /// Hide one screen in the portable library. All source and package history
    /// remains registered and recoverable; device state is never touched.
    @discardableResult public func archiveScreen(dashboardId: String,
        expectedWorkspaceId: String, expectedSelectionGeneration: Int,
        expectedGeneration: Int) throws -> WorkspaceCatalog {
        guard WorkspaceValidation.id(dashboardId),
              let overview = try current(),
              overview.descriptor.workspaceId == expectedWorkspaceId,
              overview.selectionGeneration == expectedSelectionGeneration,
              overview.descriptor.generation == expectedGeneration,
              !overview.catalog.archivedDashboardIds.contains(dashboardId) else {
            throw WorkspaceError.conflict
        }
        let archived = (overview.catalog.archivedDashboardIds + [dashboardId]).sorted()
        _ = try commitMetadata(overview: overview,
            projects: overview.catalog.projects,
            presentation: overview.settings.presentation,
            profiles: overview.settings.profiles,
            archivedDashboardIds: archived)
        return try readAfterCommittedMutation(operation: "screenArchive",
            workspaceId: expectedWorkspaceId, projectId: nil) { result in
            result.catalog.generation == expectedGeneration + 1 &&
                result.catalog.archivedDashboardIds == archived
        }.catalog
    }

    /// Descriptor, catalog and portable settings advance as one recoverable
    /// metadata generation. The transaction engine checks all before-images under
    /// the selected root lock and publishes the descriptor last.
    @discardableResult private func commitMetadata(overview: WorkspaceOverview,
                                                   projects: [WorkspaceProject],
                                                   presentation: [String: String],
                                                   profiles: [String: [String: String]],
                                                   screenIcons: [String: String]? = nil,
                                                   archivedDashboardIds: [String]? = nil,
                                                   referenceValidationHook: (() throws -> Void)? = nil) throws -> WorkspaceSettings {
        let generation = overview.descriptor.generation
        // V1 history journals advanced only workspace.json. Exact before-image
        // CAS below permits a metadata mutation to reconcile those older roots.
        guard generation < WorkspaceValidation.maxUInt,
              overview.catalog.generation <= generation,
              overview.settings.generation <= generation else { throw WorkspaceError.conflict }
        let root = try WorkspaceFiles(path: overview.path)
        let active = try requireSelected()
        try verifySelected(root, active)
        guard overview.selectionGeneration == active.selectionGeneration else {
            throw WorkspaceError.conflict
        }
        let library = try root.directory(["Workbench", "Library"]); defer { close(library) }
        let settingsFolder = try root.directory(["Workbench", "Settings"]); defer { close(settingsFolder) }
        let nextDescriptor = WorkspaceDescriptor(copy: overview.descriptor, generation: generation + 1)
        let nextCatalog = WorkspaceCatalog(generation: generation + 1, projects: projects,
            archivedDashboardIds: archivedDashboardIds ?? overview.catalog.archivedDashboardIds)
        let nextSettings = WorkspaceSettings(generation: generation + 1,
            presentation: presentation, profiles: profiles,
            screenIcons: screenIcons ?? overview.settings.screenIcons)
        try nextDescriptor.validate(); try nextCatalog.validate(); try nextSettings.validate()
        let bytes: [(String, Data, Data)] = [
            ("workspaceDescriptor", try root.read(root.fd, "workspace.json"),
             try WorkspaceJSON.encode(nextDescriptor)),
            ("libraryCatalog", try root.read(library, "catalog.json"),
             try WorkspaceJSON.encode(nextCatalog)),
            ("workbenchSettings", try root.read(settingsFolder, "workbench.json"),
             try WorkspaceJSON.encode(nextSettings))]
        guard try WorkspaceJSON.decode(WorkspaceDescriptor.self,
                  from: bytes[0].1, shape: .descriptor) == overview.descriptor,
              try WorkspaceJSON.decode(WorkspaceCatalog.self,
                  from: bytes[1].1, shape: .catalog) == overview.catalog,
              try WorkspaceJSON.decode(WorkspaceSettings.self,
                  from: bytes[2].1, shape: .settings) == overview.settings else {
            throw WorkspaceError.conflict
        }
        let operations = bytes.map { name, old, next in
            WorkbenchTransactionOperation(target: .metadata(name),
                before: .present(old), after: .present(next),
                recoveryBlobHash: WorkbenchTransactionDigest.hex(next))
        }
        let journal = WorkbenchTransactionJournal(schemaVersion: 1,
            transactionId: UUID().uuidString.lowercased(),
            workspaceId: overview.descriptor.workspaceId,
            kind: .catalogSettingsCommit, expectedGeneration: generation,
            operations: operations)
        var blobs: [String: Data] = [:]
        for (_, _, next) in bytes { blobs[WorkbenchTransactionDigest.hex(next)] = next }
        let engine = WorkbenchTransactionEngine(selection: selection,
            referenceValidationHook: referenceValidationHook)
        try engine.prepare(journal, blobs: blobs)
        try engine.commit(journal.transactionId)
        return nextSettings
    }
    private func requireSelected() throws -> WorkspaceSelection {
        guard let current = try selection.current() else { throw WorkspaceError.unavailable }; return current
    }
    private func requireCurrent() throws -> WorkspaceOverview {
        guard let current = try current() else { throw WorkspaceError.unavailable }; return current
    }
    private func verifySelected(_ root: WorkspaceFiles, _ selected: WorkspaceSelection) throws {
        guard selected.activePath == root.path, selected.rootDevice == root.identity.device, selected.rootInode == root.identity.inode,
              try selection.current()?.selectionGeneration == selected.selectionGeneration else { throw WorkspaceError.conflict }
        let parent = root.fd
        let descriptor = try load(WorkspaceDescriptor.self, root: root, parent: parent, name: "workspace.json", shape: .descriptor)
        try descriptor.validate()
        guard descriptor.workspaceId == selected.workspaceId else { throw WorkspaceError.conflict }
    }
    private func inspect(root: WorkspaceFiles, selected: WorkspaceSelection?,
                         readBudget: WorkspaceReadBudget? = nil) throws -> WorkspaceOverview {
        try readBudget?.requireLocal(root.fd)
        let descriptor = try load(WorkspaceDescriptor.self, root: root, parent: root.fd, name: "workspace.json", shape: .descriptor,
                                  readBudget: readBudget)
        try descriptor.validate()
        let library = try root.directory(["Screens"]); close(library)
        let catalogDirectory = try root.directory(["Workbench", "Library"]); defer { close(catalogDirectory) }
        let settingsDirectory = try root.directory(["Workbench", "Settings"]); defer { close(settingsDirectory) }
        let toolchains = try root.directory(["Workbench", "Toolchains"]); defer { close(toolchains) }
        for parts in [["Workbench", "History", "Builds"], ["Workbench", "History", "Packages"],
                      ["Workbench", "History", "Prepared"], ["Workbench", "History", "Deployments"],
                      ["Workbench", "Attachments"], ["Workbench", "Transactions"], ["Workbench", "Migrations"]] {
            let fd = try root.directory(parts); close(fd)
        }
        guard try root.emptyDirectory(["Workbench", "Transactions"]) else {
            // No F3 recovery executor in this slice; never ignore an untrusted pending journal.
            throw WorkspaceError.incomplete
        }
        let catalog = try load(WorkspaceCatalog.self, root: root, parent: catalogDirectory, name: "catalog.json", shape: .catalog,
                               readBudget: readBudget)
        try catalog.validate()
        let settings = try load(WorkspaceSettings.self, root: root, parent: settingsDirectory, name: "workbench.json", shape: .settings,
                                readBudget: readBudget)
        try settings.validate()
        let connections = try load(WorkspaceConnections.self, root: root, parent: settingsDirectory, name: "connections.json", shape: .connections,
                                   readBudget: readBudget)
        try connections.validate()
        let requirements = try load(WorkspaceToolchainRequirements.self, root: root, parent: toolchains, name: "requirements.json", shape: .requirements,
                                    readBudget: readBudget)
        try requirements.validate()
        let active = selected?.workspaceId == descriptor.workspaceId && selected?.activePath == root.path ? selected : nil
        var contained: [String] = [], external: [String] = [], unresolved: [String] = [], missing: [String] = []
        var includedBytes: Int64 = 0, includedFiles = 0, visitedMembers = 2, omitted: [String] = []
        for project in catalog.projects {
            try readBudget?.check()
            guard visitedMembers < 1_000_000 else { throw WorkspaceError.limitExceeded }
            visitedMembers += 1 // The contained or external project root itself.
            if let relative = project.location.path {
                contained.append(project.projectId)
                do {
                    let parts = relative.split(separator: "/").map(String.init)
                    let inventory = try validateProject(project, root: root, relative: parts,
                                                        memberLimit: 1_000_000 - visitedMembers, readBudget: readBudget)
                    guard inventory.bytes <= 64 * 1024 * 1024 * 1024 - includedBytes,
                          inventory.files <= 1_000_000 - includedFiles,
                          inventory.members <= 1_000_000 - visitedMembers else { throw WorkspaceError.limitExceeded }
                    includedBytes += inventory.bytes; includedFiles += inventory.files
                    visitedMembers += inventory.members; omitted += inventory.omitted
                }
                catch WorkspaceError.unavailable { missing.append(relative) }
                catch WorkspaceError.unsafeFile { missing.append(relative) }
            } else if let reference = project.location.referenceId {
                external.append(project.projectId)
                guard let binding = active?.externalBindings[reference] else { unresolved.append(project.projectId); continue }
                do {
                    guard externalPathAllowed(binding.path, workspace: root.path) else { unresolved.append(project.projectId); continue }
                    let location = try WorkspaceFiles(path: binding.path, requiredPrivateRoot: false)
                    try readBudget?.requireLocal(location.fd)
                    guard location.identity.device == binding.device, location.identity.inode == binding.inode else {
                        unresolved.append(project.projectId); continue
                    }
                    let inventory = try validateProject(project, root: location, relative: [],
                                                        memberLimit: 1_000_000 - visitedMembers, readBudget: readBudget)
                    visitedMembers += inventory.members
                    try location.verifyRoot()
                } catch WorkspaceError.limitExceeded { throw WorkspaceError.limitExceeded }
                  catch { unresolved.append(project.projectId) }
            }
        }
        do {
            guard visitedMembers < 1_000_000 else { throw WorkspaceError.limitExceeded }
            visitedMembers += 1 // Workbench root.
            let retained = try root.inventory(["Workbench"], retained: true, memberLimit: 1_000_000 - visitedMembers,
                                              readBudget: readBudget)
            guard retained.bytes <= 64 * 1024 * 1024 * 1024 - includedBytes,
                  retained.files <= 1_000_000 - includedFiles,
                  retained.members <= 1_000_000 - visitedMembers else { throw WorkspaceError.limitExceeded }
            includedBytes += retained.bytes; includedFiles += retained.files; visitedMembers += retained.members
        } catch WorkspaceError.unsafeFile { missing.append("Workbench") }
        let workspaceMetadata = try root.metadata(root.fd, "workspace.json")
        guard workspaceMetadata.st_size <= 64 * 1024 * 1024 * 1024 - includedBytes else { throw WorkspaceError.limitExceeded }
        includedBytes += workspaceMetadata.st_size
        let coverage = WorkspaceCoverage(contained: contained, external: external, unresolved: unresolved,
                                         missing: missing, omitted: omitted, includedBytes: includedBytes)
        try readBudget?.check()
        return WorkspaceOverview(path: root.path, descriptor: descriptor, catalog: catalog, settings: settings,
                                 coverage: coverage, selectionGeneration: active?.selectionGeneration)
    }
    private func externalPathAllowed(_ path: String, workspace: String) -> Bool {
        let candidate = WorkspaceValidation.portableKey(path)
        return [workspace, selection.machineRootPath].allSatisfy { reserved in
            let base = WorkspaceValidation.portableKey(reserved)
            return candidate != base && !candidate.hasPrefix(base + "/") && !base.hasPrefix(candidate + "/")
        }
    }
    private func validateProject(_ project: WorkspaceProject, root: WorkspaceFiles, relative: [String],
                                 memberLimit: Int? = nil, readBudget: WorkspaceReadBudget? = nil) throws -> WorkspaceProjectInventory {
        try readBudget?.check()
        let directory = try root.directory(relative); defer { close(directory) }
        let descriptor: WorkspaceProjectDocument
        do { descriptor = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
            from: root.read(directory, "screenpunk.project.json", readBudget: readBudget), shape: .project) }
        catch WorkspaceError.unsafeFile { throw WorkspaceError.unavailable }
        try descriptor.validate(matching: project)
        for member in [descriptor.entry, descriptor.screenConfig] {
            let components = member.split(separator: "/").map(String.init)
            let parent = try root.directory(relative + Array(components.dropLast())); defer { close(parent) }
            let metadata = try root.metadata(parent, components.last!)
            guard metadata.st_size >= 0, metadata.st_size <= 5 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
        }
        let config = try root.read(directory, descriptor.screenConfig, maxBytes: 5 * 1024 * 1024,
                                   readBudget: readBudget)
        guard (try? JSONSerialization.jsonObject(with: config)) is [String: Any] else { throw WorkspaceError.invalidSchema }
        let hasLockfile = try root.exists(directory, "screenpunk.lock.json")
        if hasLockfile {
            let metadata = try root.metadata(directory, "screenpunk.lock.json")
            guard metadata.st_size >= 0, metadata.st_size <= 5 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
            let lockfile = try root.read(directory, "screenpunk.lock.json", maxBytes: 5 * 1024 * 1024,
                                         readBudget: readBudget)
            guard (try? JSONSerialization.jsonObject(with: lockfile)) is [String: Any] else { throw WorkspaceError.invalidSchema }
        }
        return try root.inventory(relative, memberLimit: memberLimit,
                                  readBudget: readBudget,
                                  required: ["screenpunk.project.json", descriptor.entry, descriptor.screenConfig] +
                                            (hasLockfile ? ["screenpunk.lock.json"] : []))
    }
    private func load<T: Decodable>(_ type: T.Type, root: WorkspaceFiles, parent: Int32, name: String, shape: WorkspaceJSON.Shape,
                                    readBudget: WorkspaceReadBudget? = nil) throws -> T {
        try WorkspaceJSON.decode(type, from: root.read(parent, name, readBudget: readBudget), shape: shape)
    }
    private func writeNew<T: Encodable>(_ value: T, root: WorkspaceFiles, parent: [String], name: String) throws {
        let directory = try root.directory(parent); defer { close(directory) }
        try root.write(directory, name, data: WorkspaceJSON.encode(value), expected: nil)
    }
}
#endif
