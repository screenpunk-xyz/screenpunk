import Foundation
#if os(macOS)
import Darwin

/// Candidate broker DTO for a bounded source editor read. No socket route exposes it yet.
public struct WorkbenchSourceTextRead: Codable, Sendable, Equatable {
    public let workspaceId: String
    public let selectionGeneration: Int
    public let projectId: String
    public let path: String
    public let sourceVersion: String
    public let text: String
}

struct WorkbenchSourceKitPin: Codable, Equatable {
    let schemaVersion: Int
    let catalogEntryId: String
    let kitVersion: String
    let platform: String
    let inventoryHash: String
    init(_ requirement: WorkspaceToolchainRequirements.Requirement) {
        schemaVersion = 1; catalogEntryId = requirement.catalogEntryId
        kitVersion = requirement.kitVersion; platform = requirement.platform
        inventoryHash = requirement.inventoryHash
    }
    var requirement: WorkspaceToolchainRequirements.Requirement {
        .init(catalogEntryId: catalogEntryId, kitVersion: kitVersion,
              platform: platform, inventoryHash: inventoryHash)
    }
}

/// Service-owned contained source authoring. Public methods are intended to be called
/// on the broker's serial domain queue; no API here opens an external project for writes.
public final class WorkbenchContainedAuthoring {
    private let workspace: WorkspaceStore
    var cloudCreationScope: ControllerCloudCreationScope?
    private let localReadTimeout: TimeInterval
    private let checkpoint: ((WorkbenchTransactionCheckpoint) throws -> Void)?
    public init(workspace: WorkspaceStore, localReadTimeout: TimeInterval = 15) {
        self.workspace = workspace; self.localReadTimeout = localReadTimeout; checkpoint = nil
    }
    init(workspace: WorkspaceStore, checkpoint: @escaping (WorkbenchTransactionCheckpoint) throws -> Void) {
        self.workspace = workspace; localReadTimeout = 15; self.checkpoint = checkpoint
    }

    public func list(deadline: TimeInterval? = nil, cancelled: @escaping () -> Bool = { false }) throws -> [WorkspaceProject] {
        try current(budget: readBudget(deadline: deadline, cancelled: cancelled)).catalog.projects
    }
    public func coverage(deadline: TimeInterval? = nil, cancelled: @escaping () -> Bool = { false }) throws -> WorkspaceCoverage {
        try current(budget: readBudget(deadline: deadline, cancelled: cancelled)).coverage
    }
    public func get(_ projectId: String, deadline: TimeInterval? = nil,
                    cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchSourceProject {
        let budget = readBudget(deadline: deadline, cancelled: cancelled)
        let (overview, project, files) = try capture(projectId, budget: budget)
        guard let relative = project.location.path else { throw WorkspaceError.unavailable }
        let sourceVersion = try WorkbenchSourceHasher.hash(files)
        try budget.check()
        return .init(project: project, path: overview.path + "/" + relative,
                         sourceVersion: sourceVersion, sourceHashVersion: 1,
                         fileCount: files.count, includedBytes: files.values.reduce(0) { $0 + $1.count })
    }
    public func readText(_ projectId: String, path: String, expectedWorkspaceId: String,
                         expectedSelectionGeneration: Int, deadline: TimeInterval? = nil,
                         cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchSourceTextRead {
        guard WorkspaceValidation.id(projectId), WorkspaceValidation.id(expectedWorkspaceId),
              expectedSelectionGeneration >= 0, WorkspaceValidation.member(path),
              path != "screenpunk.project.json", path != "screenpunk.lock.json",
              !WorkspaceFiles.fixedSourceExcludes(path),
              ["html", "htm", "css", "js", "json", "svg", "txt", "ts", "tsx", "jsx", "md"]
                .contains(path.split(separator: ".").last.map(String.init)?.lowercased() ?? "") else {
            throw WorkspaceError.invalidSchema
        }
        let budget = readBudget(deadline: deadline, cancelled: cancelled)
        let selected = try current(budget: budget)
        guard selected.descriptor.workspaceId == expectedWorkspaceId,
              selected.selectionGeneration == expectedSelectionGeneration else {
            throw WorkspaceError.conflict
        }
        let (overview, project, files) = try capture(projectId, budget: budget)
        guard overview.descriptor.workspaceId == expectedWorkspaceId,
              overview.selectionGeneration == expectedSelectionGeneration,
              project.projectId == projectId else { throw WorkspaceError.conflict }
        guard let bytes = files[path], bytes.count <= 2_048,
              !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
            throw WorkspaceError.limitExceeded
        }
        let version = try WorkbenchSourceHasher.hash(files)
        try budget.check()
        return WorkbenchSourceTextRead(workspaceId: expectedWorkspaceId,
            selectionGeneration: expectedSelectionGeneration, projectId: projectId,
            path: path, sourceVersion: version, text: text)
    }

    /// Reads a bounded binary chunk from the current included-source snapshot.
    /// Every page recomputes the full source hash and rejects a changed project,
    /// so separate pages cannot silently combine different source versions.
    public func readChunk(_ request: WorkbenchSourceChunkRequest,
                          deadline: TimeInterval? = nil,
                          cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchSourceChunkRead {
        let budget = readBudget(deadline: deadline, cancelled: cancelled)
        let selected = try current(budget: budget)
        guard selected.descriptor.workspaceId == request.expectedWorkspaceId,
              selected.selectionGeneration == request.expectedSelectionGeneration else {
            throw WorkspaceError.conflict
        }
        let (overview, project, files) = try capture(request.projectId, budget: budget)
        guard overview.descriptor.workspaceId == request.expectedWorkspaceId,
              overview.selectionGeneration == request.expectedSelectionGeneration,
              project.projectId == request.projectId,
              let bytes = files[request.path],
              bytes.count <= WorkbenchSourceChunkRequest.maximumFileBytes,
              request.offset <= bytes.count else { throw WorkspaceError.conflict }
        guard try WorkbenchSourceHasher.hash(files) == request.expectedSourceVersion else {
            throw WorkspaceError.conflict
        }
        let result = WorkbenchSourceChunkRead(request: request, file: bytes)
        try result.validate(for: request)
        try budget.check()
        let after = try current(budget: budget)
        guard after.descriptor.workspaceId == request.expectedWorkspaceId,
              after.selectionGeneration == request.expectedSelectionGeneration else {
            throw WorkspaceError.conflict
        }
        return result
    }
    public func path(_ projectId: String, deadline: TimeInterval? = nil,
                     cancelled: @escaping () -> Bool = { false }) throws -> String {
        try get(projectId, deadline: deadline, cancelled: cancelled).path
    }

    /// Blank templates are trusted built-in source only. Other template names require
    /// a verified installed kit and are unavailable through this API.
    @discardableResult public func create(name: String, kind: String, trustedKitVersion: String,
                                          template: String = "blank") throws -> WorkbenchSourceProject {
        guard WorkspaceValidation.text(name), !name.isEmpty, ["react", "web"].contains(kind),
              template == "blank", WorkspaceValidation.id(trustedKitVersion) else { throw WorkspaceError.invalidSchema }
        let overview = try requireCurrent()
        let relative = try workspace.nextContainedDestination(named: name)
        let parts = relative.split(separator: "/").map(String.init)
        let root = try WorkspaceFiles(path: overview.path)
        let screens = try root.directory(["Screens"]); defer { close(screens) }
        guard mkdirat(screens, parts[1], 0o700) == 0 else {
            throw errno == EEXIST ? WorkspaceError.conflict : WorkspaceError.unavailable
        }
        guard fsync(screens) == 0 else { throw WorkspaceError.unavailable }
        let project = WorkspaceProject(projectId: UUID().uuidString.lowercased(),
            dashboardId: UUID().uuidString.lowercased(), name: name, location: .contained(relative))
        let entry = kind == "react" ? "src/main.tsx" : "web/index.html"
        let descriptor = WorkspaceProjectDocument(schemaVersion: 1, projectId: project.projectId,
            dashboardId: project.dashboardId, name: name, kind: kind,
            kitVersion: trustedKitVersion, entry: entry, screenConfig: "screen.json")
        let screenConfig = try JSONSerialization.data(withJSONObject: ["name": name, "connections": []], options: [.sortedKeys])
        let source = kind == "react"
            ? Data("import { createRoot } from 'react-dom/client';\nimport { ScreenpunkProvider, useScreenReady } from '@screenpunk/react';\n// Persist user inputs with screenpunk.state.get/set/remove; keep dashboardId/key stable. Restore before defaults, save edits, check runtime persistentState/persistentStateWritable and report failures.\nfunction App(){ useScreenReady(); return <main><h1>New screen</h1></main>; }\ncreateRoot(document.getElementById('root')!).render(<ScreenpunkProvider><App/></ScreenpunkProvider>);\n".utf8)
            : Data("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"stylesheet\" href=\"styles.css\"><title>New screen</title></head><body><main><h1>New screen</h1></main><script src=\"app.js\"></script></body></html>\n".utf8)
        let descriptorBytes = try WorkspaceJSON.encode(descriptor)
        var sourceFiles = ["screenpunk.project.json": descriptorBytes, "screen.json": screenConfig, entry: source]
        if kind == "web" {
            // Package CSP requires bundled assets; teach the supported shape in the blank template.
            sourceFiles["web/styles.css"] = Data("body { margin: 0; font-family: -apple-system, sans-serif; } main { padding: 24px; }\n".utf8)
            sourceFiles["web/app.js"] = Data("// Add behavior here using addEventListener; inline script/event handlers are blocked.\n// Persist every user input using native screenpunk.state.get/set/remove; retain dashboardId and stable versioned keys.\n// Wait for active persistentState/persistentStateWritable, restore before defaults and save only explicit edits.\n// Report unsupported/read-only hosts and read/save errors; never overwrite defaults on load or failed reads.\n// Reset only on explicit user action; test an approved screen update and app relaunch.\n".utf8)
        }
        try commitSource(project: project, before: [:], after: sourceFiles,
                         expected: overview, register: true, root: root)
        return try readAfterSourceCommit(project.projectId,
            workspaceId: overview.descriptor.workspaceId)
    }

    /// Register an already complete contained folder, including one left by an
    /// interrupted create before catalog publication. It never copies or moves it.
    @discardableResult public func openContained(at path: String) throws -> WorkbenchSourceProject {
        let overview = try requireCurrent()
        guard path.hasPrefix(overview.path + "/Screens/") else { throw WorkspaceError.invalidPath }
        let relative = String(path.dropFirst((overview.path + "/").count))
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "Screens", WorkspaceValidation.member(relative) else {
            throw WorkspaceError.invalidPath
        }
        let root = try WorkspaceFiles(path: overview.path)
        let folder = try root.directory(parts); defer { close(folder) }
        let document = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
            from: root.read(folder, "screenpunk.project.json"), shape: .project)
        let project = WorkspaceProject(projectId: document.projectId, dashboardId: document.dashboardId,
            name: document.name, location: .contained(relative))
        try document.validate(matching: project)
        let inventory = try root.inventory(parts, required: ["screenpunk.project.json", document.screenConfig, document.entry])
        guard inventory.files <= 2_000, inventory.bytes <= 25 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
        guard !overview.catalog.projects.contains(where: { $0.projectId == project.projectId ||
            $0.dashboardId == project.dashboardId || $0.location.path == relative }) else { throw WorkspaceError.conflict }
        var files: [String: Data] = [:]
        for member in inventory.includedFiles {
            let components = member.split(separator: "/").map(String.init)
            let parent = try root.directory(parts + Array(components.dropLast())); defer { close(parent) }
            files[member] = try root.read(parent, components.last!, maxBytes: 5 * 1024 * 1024)
        }
        try commitSource(project: project, before: files, after: files,
                         expected: overview, register: true, root: root)
        return try readAfterSourceCommit(project.projectId,
            workspaceId: overview.descriptor.workspaceId)
    }

    /// Import only prevalidated included source bytes as a new contained
    /// project. Source/dashboard IDs are regenerated; the ordinary source
    /// transaction publishes the new descriptor and immutable history.
    @discardableResult public func importVerifiedSource(
        descriptor original: WorkspaceProjectDocument, files imported: [String: Data],
        name overrideName: String? = nil,
        relativeDestination: String? = nil) throws -> WorkbenchSourceProject {
        let name = overrideName ?? original.name
        guard WorkspaceValidation.text(name), !name.isEmpty,
              imported["screenpunk.project.json"] != nil,
              imported[original.screenConfig] != nil,
              imported[original.entry] != nil,
              imported.count <= 2_000,
              imported.keys.allSatisfy({ WorkspaceValidation.member($0) &&
                  !WorkspaceFiles.fixedSourceExcludes($0) }) else { throw WorkspaceError.invalidSchema }
        let overview = try requireCurrent()
        let relative = try relativeDestination ?? workspace.nextContainedDestination(named: name)
        try WorkspaceProjectLocation.contained(relative).validate()
        let project = WorkspaceProject(projectId: UUID().uuidString.lowercased(),
            dashboardId: UUID().uuidString.lowercased(), name: name,
            location: .contained(relative))
        let descriptor = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: project.projectId, dashboardId: project.dashboardId,
            name: name, kind: original.kind, kitVersion: original.kitVersion,
            entry: original.entry, screenConfig: original.screenConfig)
        try descriptor.validate(matching: project)
        var files = imported
        files["screenpunk.project.json"] = try WorkspaceJSON.encode(descriptor)
        _ = try WorkbenchSourceHasher.hash(files)
        // A new source commit publishes each member once in immutable history
        // and once in the project, plus its history inventory and three metadata
        // members. Reject an oversized journal before reserving Screens/NAME.
        guard 2 * files.count + 4 <= WorkbenchTransactionAccounting.maximumOperations(for: .sourceCommit)
        else { throw WorkspaceError.limitExceeded }
        let root = try WorkspaceFiles(path: overview.path)
        let screens = try root.directory(["Screens"]); defer { close(screens) }
        let folder = String(relative.split(separator: "/").last!)
        let parts = ["Screens", folder]
        guard mkdirat(screens, folder, 0o700) == 0 else {
            throw errno == EEXIST ? WorkspaceError.conflict : WorkspaceError.unavailable
        }
        let created = try root.directory(parts); defer { close(created) }
        var createdInfo = stat()
        guard fstat(created, &createdInfo) == 0 else { throw WorkspaceError.unavailable }
        do {
            guard fsync(screens) == 0 else { throw WorkspaceError.unavailable }
            try commitSource(project: project, before: [:], after: files,
                expected: overview, register: true, root: root)
        } catch {
            // A prepared journal owns its recovery destination. Only reclaim
            // the exact empty directory when no durable transaction exists.
            if (try? root.emptyDirectory(["Workbench", "Transactions"])) == true,
               (try? root.emptyDirectory(parts)) == true {
                var now = stat()
                if fstatat(screens, folder, &now, AT_SYMLINK_NOFOLLOW) == 0,
                   WorkspaceNodeID(now) == WorkspaceNodeID(createdInfo),
                   unlinkat(screens, folder, AT_REMOVEDIR) == 0 {
                    _ = fsync(screens)
                }
            }
            throw error
        }
        return try readAfterSourceCommit(project.projectId,
            workspaceId: overview.descriptor.workspaceId)
    }


    /// Explicit open recovery is limited to contained, non-destructive journals.
    /// The later broker integration must call this before WorkspaceStore.open.
    public func recoverContainedBeforeOpen(at path: String) throws -> [String] {
        let engine = try WorkbenchTransactionEngine(forExplicitOpenAt: path, selection: workspace.selection)
        return try engine.recoverAll()
    }

    /// `expectedSourceVersion` is a full included-source hash. Every current included
    /// file participates in the journal, so unchanged bytes are checked as CAS inputs.
    @discardableResult public func patch(_ projectId: String, expectedSourceVersion: String,
                                         changes: [WorkbenchSourceChange]) throws -> WorkbenchSourceProject {
        guard WorkspaceValidation.sha256(expectedSourceVersion), (1...64).contains(changes.count) else {
            throw WorkspaceError.invalidSchema
        }
        let (overview, project, currentFiles) = try capture(projectId)
        guard project.location.path != nil else { throw WorkspaceError.unavailable }
        guard try WorkbenchSourceHasher.hash(currentFiles) == expectedSourceVersion else { throw WorkspaceError.conflict }
        var projected = currentFiles
        var seen = WorkspacePathCollisionDetector()
        for change in changes {
            guard WorkspaceValidation.member(change.path), !WorkspaceFiles.fixedSourceExcludes(change.path),
                  change.path != "screenpunk.project.json", change.path != "screenpunk.lock.json" else {
                throw WorkspaceError.invalidPath
            }
            try seen.insert(change.path)
            if let bytes = change.bytes {
                guard bytes.count <= 5 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
                projected[change.path] = bytes
            } else { projected.removeValue(forKey: change.path) }
        }
        guard projected.values.reduce(0, { $0 + $1.count }) <= 25 * 1024 * 1024 else {
            throw WorkspaceError.limitExceeded
        }
        let descriptor = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: projected["screenpunk.project.json"] ?? Data())
        try descriptor.validate(matching: project)
        guard projected[descriptor.entry] != nil, let config = projected["screen.json"],
              (try? JSONSerialization.jsonObject(with: config)) is [String: Any] else { throw WorkspaceError.invalidSchema }
        let nextVersion = try WorkbenchSourceHasher.hash(projected)
        guard nextVersion != expectedSourceVersion else { return try get(projectId) }
        try commitSource(project: project, before: currentFiles, after: projected,
                         expected: overview, register: false, root: WorkspaceFiles(path: overview.path))
        let result = try readAfterSourceCommit(projectId,
            workspaceId: overview.descriptor.workspaceId)
        guard result.sourceVersion == nextVersion else {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "sourceCommit",
                workspaceId: overview.descriptor.workspaceId, projectId: projectId)
        }
        return result
    }

    /// The broker supplies a kit already verified by the trusted toolchain resolver.
    /// This publishes only portable requirements and source identity; execution still
    /// requires the build path to resolve and verify the kit again at use time.
    @discardableResult func upgradeKit(_ projectId: String, expectedSourceVersion: String,
                                       expectedCatalogGeneration: Int,
                                       verifiedKit: VerifiedToolchainKit) throws -> WorkbenchSourceProject {
        let entry = verifiedKit.approved.entry
        guard entry.kind == "authoringKit" else { throw WorkspaceError.invalidSchema }
        return try upgradeKitPreverified(projectId, expectedSourceVersion: expectedSourceVersion,
            expectedCatalogGeneration: expectedCatalogGeneration,
            requirement: .init(catalogEntryId: entry.catalogEntryId,
                kitVersion: entry.version, platform: entry.platform,
                inventoryHash: entry.inventoryHash))
    }

    /// Transaction mechanics for a preverified requirement. Only the trusted
    /// broker adapter may supply this; this helper does not authenticate kits.
    @discardableResult func upgradeKitPreverified(_ projectId: String,
        expectedSourceVersion: String, expectedCatalogGeneration: Int,
        requirement: WorkspaceToolchainRequirements.Requirement) throws -> WorkbenchSourceProject {
        guard WorkspaceValidation.sha256(expectedSourceVersion), expectedCatalogGeneration >= 0 else {
            throw WorkspaceError.invalidSchema
        }
        let (overview, project, before) = try capture(projectId)
        guard project.location.path != nil, overview.catalog.generation == expectedCatalogGeneration,
              try WorkbenchSourceHasher.hash(before) == expectedSourceVersion else {
            throw WorkspaceError.conflict
        }
        guard requirement.platform == "darwin-arm64",
              WorkspaceValidation.id(requirement.catalogEntryId),
              WorkspaceValidation.id(requirement.kitVersion),
              WorkspaceValidation.sha256(requirement.inventoryHash) else { throw WorkspaceError.invalidSchema }
        let root = try WorkspaceFiles(path: overview.path)
        let toolchains = try root.directory(["Workbench", "Toolchains"]); defer { close(toolchains) }
        let oldRequirements = try root.read(toolchains, "requirements.json")
        let currentRequirements = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
            from: oldRequirements, shape: .requirements)
        try currentRequirements.validate()
        var selected = currentRequirements.required
        if let existing = selected.first(where: { $0.catalogEntryId == requirement.catalogEntryId }) {
            guard existing == requirement else { throw WorkspaceError.conflict }
        } else { selected.append(requirement) }
        let nextRequirements = WorkspaceToolchainRequirements(required: selected)
        try nextRequirements.validate()
        let currentDocument = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
            from: before["screenpunk.project.json"] ?? Data(), shape: .project)
        try currentDocument.validate(matching: project)
        guard currentDocument.kind == "react" else { throw WorkspaceError.invalidSchema }
        let nextDocument = WorkspaceProjectDocument(schemaVersion: currentDocument.schemaVersion,
            projectId: currentDocument.projectId, dashboardId: currentDocument.dashboardId,
            name: currentDocument.name, kind: currentDocument.kind, kitVersion: requirement.kitVersion,
            entry: currentDocument.entry, screenConfig: currentDocument.screenConfig)
        var after = before
        after["screenpunk.project.json"] = try WorkspaceJSON.encode(nextDocument)
        after["screenpunk.lock.json"] = try WorkspaceJSON.encode(WorkbenchSourceKitPin(requirement))
        let nextVersion = try WorkbenchSourceHasher.hash(after)
        guard nextVersion != expectedSourceVersion || nextRequirements != currentRequirements else {
            return try get(projectId)
        }
        try commitSource(project: project, before: before, after: after,
            expected: overview, register: false, root: root,
            requirements: (oldRequirements, try WorkspaceJSON.encode(nextRequirements)))
        let result = try readAfterSourceCommit(projectId,
            workspaceId: overview.descriptor.workspaceId)
        guard result.sourceVersion == nextVersion else {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "kitUpgrade",
                workspaceId: overview.descriptor.workspaceId, projectId: projectId)
        }
        return result
    }

    public func versions(_ projectId: String, deadline: TimeInterval? = nil,
                         cancelled: @escaping () -> Bool = { false }) throws -> [WorkbenchSourceHistoryEntry] {
        let budget = readBudget(deadline: deadline, cancelled: cancelled)
        let overview = try current(budget: budget)
        guard overview.catalog.projects.contains(where: { $0.projectId == projectId }) else { throw WorkspaceError.unavailable }
        let root = try WorkspaceFiles(path: overview.path)
        let directory = try root.directory(["Workbench", "History", "Builds"])
        defer { close(directory) }
        var result: [WorkbenchSourceHistoryEntry] = []
        for id in try directoryEntries(directory, limit: 100_000, budget: budget).sorted() where WorkspaceValidation.sha256(id) {
            try budget.check()
            let source: Int32
            do { source = try root.directory(["Workbench", "History", "Builds", id, "source"]) }
            catch { continue }
            defer { close(source) }
            guard try root.exists(source, ".screenpunk-snapshot.json") else { continue }
            let value = try JSONDecoder().decode(WorkbenchSourceHistoryEntry.self,
                from: root.read(source, ".screenpunk-snapshot.json", maxBytes: 8 * 1024 * 1024, readBudget: budget))
            guard value.sourceVersion == id, value.sourceHashVersion == 1 else { throw WorkspaceError.invalidSchema }
            guard value.files.count <= 2_000 else { throw WorkspaceError.limitExceeded }
            var files: [String: Data] = [:]
            var collisions = WorkspacePathCollisionDetector()
            for file in value.files {
                try budget.check()
                guard WorkspaceValidation.member(file.path), !WorkspaceFiles.fixedSourceExcludes(file.path),
                      file.bytes >= 0, file.bytes <= 5 * 1024 * 1024 else { throw WorkspaceError.invalidSchema }
                try collisions.insert(file.path)
                let components = file.path.split(separator: "/").map(String.init)
                let parent = try root.directory(["Workbench", "History", "Builds", id, "source"] + Array(components.dropLast()))
                defer { close(parent) }
                let bytes = try root.read(parent, components.last!, maxBytes: 5 * 1024 * 1024, readBudget: budget)
                guard bytes.count == file.bytes, WorkbenchTransactionDigest.hex(bytes) == file.sha256 else {
                    throw WorkspaceError.conflict
                }
                files[file.path] = bytes
            }
            guard try WorkbenchSourceHasher.hash(files) == id else { throw WorkspaceError.conflict }
            try budget.check()
            guard let descriptorBytes = files["screenpunk.project.json"] else { throw WorkspaceError.invalidSchema }
            let descriptor = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
                from: descriptorBytes, shape: .project)
            guard value.projectId == descriptor.projectId,
                  value.dashboardId == descriptor.dashboardId else { throw WorkspaceError.conflict }
            // An interrupted create can leave an inert history object before
            // the catalog publication that makes its project visible.
            guard let registered = overview.catalog.projects.first(where: { $0.projectId == descriptor.projectId }) else { continue }
            guard registered.location.path != nil else { throw WorkspaceError.conflict }
            try descriptor.validate(matching: registered)
            if descriptor.projectId == projectId { result.append(value) }
        }
        return result
    }

    func commitSource(project: WorkspaceProject, before: [String: Data],
                              after: [String: Data], expected: WorkspaceOverview,
                              register: Bool, root: WorkspaceFiles,
                              requirements: (Data, Data)? = nil) throws {
        if register, let scope = cloudCreationScope {
            guard let bytes = after["screenpunk.project.json"] else { throw WorkspaceError.invalidSchema }
            let descriptor = try WorkspaceJSON.decode(WorkspaceProjectDocument.self, from: bytes, shape: .project)
            try scope.prepare(project: project, descriptor: descriptor, localWorkspaceId: expected.descriptor.workspaceId)
        }
        let version = try WorkbenchSourceHasher.hash(after)
        let metadata = WorkbenchSourceHistoryEntry(sourceVersion: version, sourceHashVersion: 1,
            projectId: project.projectId, dashboardId: project.dashboardId,
            files: after.keys.sorted().map { path in WorkbenchSourceFile(path: path,
                sha256: WorkbenchTransactionDigest.hex(after[path]!), bytes: after[path]!.count) })
        var history = after
        history[".screenpunk-snapshot.json"] = try JSONEncoder().encode(metadata)
        guard history.count <= 2_001 else { throw WorkspaceError.limitExceeded }
        guard history.count + Set(before.keys).union(after.keys).count + 3 +
                (requirements == nil ? 0 : 1) <= WorkbenchTransactionAccounting.maximumOperations(for: .sourceCommit)
        else { throw WorkspaceError.limitExceeded }
        let existingSnapshot = try existingSnapshotBytes(project: project, version: version,
            files: after, root: root)
        if let existingSnapshot { history[".screenpunk-snapshot.json"] = existingSnapshot }
        let alreadyPublished = existingSnapshot != nil
        var operations: [WorkbenchTransactionOperation] = history.keys.sorted().map { member in
            let bytes = history[member]!
            let image = WorkbenchTransactionImage.present(bytes)
            return .init(target: .history("buildSource", version, member),
                         before: alreadyPublished ? image : .absent,
                         after: image, recoveryBlobHash: image.sha256)
        }
        operations += Set(before.keys).union(after.keys).sorted().map { member in
            let prior = before[member].map(WorkbenchTransactionImage.present) ?? .absent
            let next = after[member].map(WorkbenchTransactionImage.present) ?? .absent
            return .init(target: .project(project.projectId, member), before: prior,
                         after: next, recoveryBlobHash: next.sha256)
        }
        var payloads = Array(history.values) + Array(after.values)
        let oldDescriptor = try root.read(root.fd, "workspace.json")
        let library = try root.directory(["Workbench", "Library"]); defer { close(library) }
        let settingsFolder = try root.directory(["Workbench", "Settings"]); defer { close(settingsFolder) }
        let oldCatalog = try root.read(library, "catalog.json")
        let oldSettings = try root.read(settingsFolder, "workbench.json")
        let generation = expected.descriptor.generation + 1
        let nextDescriptor = WorkspaceDescriptor(copy: expected.descriptor, generation: generation)
        let nextProjects = register ? expected.catalog.projects + [project] :
            expected.catalog.projects.map { $0.projectId == project.projectId ? project : $0 }
        let nextCatalog = WorkspaceCatalog(generation: generation, projects: nextProjects,
            archivedDashboardIds: expected.catalog.archivedDashboardIds)
        let nextSettings = WorkspaceSettings(generation: generation,
            presentation: expected.settings.presentation, profiles: expected.settings.profiles,
            screenIcons: expected.settings.screenIcons)
        var metadataPayloads: [(String, Data, Data)] = [
            ("workspaceDescriptor", oldDescriptor, try WorkspaceJSON.encode(nextDescriptor)),
            ("libraryCatalog", oldCatalog, try WorkspaceJSON.encode(nextCatalog)),
            ("workbenchSettings", oldSettings, try WorkspaceJSON.encode(nextSettings))]
        if let requirements {
            metadataPayloads.append(("toolchainRequirements", requirements.0, requirements.1))
        }
        for (name, prior, next) in metadataPayloads {
            operations.append(.init(target: .metadata(name), before: .present(prior),
                                    after: .present(next), recoveryBlobHash: WorkbenchTransactionDigest.hex(next)))
            payloads.append(next)
        }
        let journal = WorkbenchTransactionJournal(schemaVersion: 2,
            transactionId: UUID().uuidString.lowercased(), workspaceId: expected.descriptor.workspaceId,
            kind: .sourceCommit, expectedGeneration: expected.descriptor.generation,
            operations: operations)
        let engine = WorkbenchTransactionEngine(selection: workspace.selection, checkpoint: checkpoint)
        try engine.prepare(journal, blobs: blobMap(payloads))
        try engine.commit(journal.transactionId)
    }

    private func readAfterSourceCommit(_ projectId: String, workspaceId: String)
        throws -> WorkbenchSourceProject {
        do { return try get(projectId) }
        catch {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "sourceCommit",
                workspaceId: workspaceId, projectId: projectId)
        }
    }

    private func existingSnapshotBytes(project: WorkspaceProject, version: String,
                                       files: [String: Data], root: WorkspaceFiles) throws -> Data? {
        let builds = try root.directory(["Workbench", "History", "Builds"]); defer { close(builds) }
        guard try root.exists(builds, version) else { return nil }
        let source = try root.directory(["Workbench", "History", "Builds", version, "source"])
        defer { close(source) }
        let metadataBytes = try root.read(source, ".screenpunk-snapshot.json", maxBytes: 8 * 1024 * 1024)
        let metadata = try JSONDecoder().decode(WorkbenchSourceHistoryEntry.self, from: metadataBytes)
        guard metadata.sourceVersion == version, metadata.sourceHashVersion == 1,
              metadata.projectId == project.projectId, metadata.dashboardId == project.dashboardId,
              metadata.files.count == files.count else { throw WorkspaceError.conflict }
        for file in metadata.files {
            guard let expected = files[file.path], expected.count == file.bytes,
                  WorkbenchTransactionDigest.hex(expected) == file.sha256 else { throw WorkspaceError.conflict }
            let components = file.path.split(separator: "/").map(String.init)
            let parent = try root.directory(["Workbench", "History", "Builds", version, "source"] + Array(components.dropLast()))
            defer { close(parent) }
            guard try root.read(parent, components.last!, maxBytes: 5 * 1024 * 1024) == expected else {
                throw WorkspaceError.conflict
            }
        }
        return metadataBytes
    }

    private func blobMap(_ values: [Data]) -> [String: Data] {
        var result: [String: Data] = [:]
        for value in values { result[WorkbenchTransactionDigest.hex(value)] = value }
        return result
    }
    func capture(_ projectId: String) throws -> (WorkspaceOverview, WorkspaceProject, [String: Data]) {
        try capture(projectId, budget: readBudget(deadline: nil, cancelled: { false }))
    }
    private func capture(_ projectId: String, budget: WorkspaceReadBudget) throws -> (WorkspaceOverview, WorkspaceProject, [String: Data]) {
        guard let overview = try workspace.current(readBudget: budget),
              let project = overview.catalog.projects.first(where: { $0.projectId == projectId }),
              let relative = project.location.path else { throw WorkspaceError.unavailable }
        let root = try WorkspaceFiles(path: overview.path)
        let parts = relative.split(separator: "/").map(String.init)
        let folder = try root.directory(parts); defer { close(folder) }
        let descriptor = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
            from: root.read(folder, "screenpunk.project.json", readBudget: budget), shape: .project)
        try descriptor.validate(matching: project)
        let hasLock = try root.exists(folder, "screenpunk.lock.json")
        let required = ["screenpunk.project.json", descriptor.screenConfig, descriptor.entry]
            + (hasLock ? ["screenpunk.lock.json"] : [])
        let inventory = try root.inventory(parts, readBudget: budget, required: required)
        var files: [String: Data] = [:]
        for path in inventory.includedFiles.sorted() {
            try budget.check()
            let components = path.split(separator: "/").map(String.init)
            let parent = try root.directory(parts + Array(components.dropLast())); defer { close(parent) }
            files[path] = try root.read(parent, components.last!, maxBytes: 5 * 1024 * 1024, readBudget: budget)
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= 25 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
        try budget.check()
        return (overview, project, files)
    }
    private func current(budget: WorkspaceReadBudget) throws -> WorkspaceOverview {
        guard let value = try workspace.current(readBudget: budget) else { throw WorkspaceError.unavailable }
        return value
    }
    private func readBudget(deadline: TimeInterval?, cancelled: @escaping () -> Bool) -> WorkspaceReadBudget {
        WorkspaceReadBudget(deadline: min(deadline ?? .infinity, ProcessInfo.processInfo.systemUptime + localReadTimeout),
                            cancelled: cancelled)
    }
    private func requireCurrent() throws -> WorkspaceOverview {
        guard let value = try workspace.current() else { throw WorkspaceError.unavailable }
        return value
    }
    private func directoryEntries(_ fd: Int32, limit: Int, budget: WorkspaceReadBudget) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            try budget.check()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name == "." || name == ".." { continue }
            guard result.count < limit, WorkspaceValidation.member(name), !name.contains("/") else { throw WorkspaceError.limitExceeded }
            result.append(name)
        }
        return result
    }
}
#endif
