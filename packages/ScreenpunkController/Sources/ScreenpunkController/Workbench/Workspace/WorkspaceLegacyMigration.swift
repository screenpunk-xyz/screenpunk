import Foundation
import ScreenpunkCore
#if os(macOS)
import Darwin

struct WorkspaceLegacyMigrationSummary: Equatable {
    let migrationId: String
    let projectIds: [String]
    let packageRevisions: [String]
    let portableBytes: Int
    let expandedBytes: Int
    let plannedMembers: Int
    let unsupportedPortablePaths: [String]
    let excludedClasses: [String]
    let sourcePath: String
}

/// This capability is intentionally internal until the runtime supplies an
/// independently verified old-writer exclusion gate and a user-reviewed plan.
protocol WorkspaceOldWriterExclusionGate {
    func withExclusion<T>(legacyPath: String, device: UInt64, inode: UInt64,
                          perform: () throws -> T) throws -> T
}

/// The broker already holds its controller-home owner lock. During migration,
/// also hold the two file locks used by legacy package and authoring writers.
/// The process inventory check rejects legacy binaries that do not cooperate
/// with those locks before any source is copied.
struct WorkbenchMigrationWriterGate: WorkspaceOldWriterExclusionGate {
    let checkOwner: () throws -> Void

    func withExclusion<T>(legacyPath: String, device: UInt64, inode: UInt64,
                          perform: () throws -> T) throws -> T {
        try checkOwner()
        let source = try WorkspaceFiles(path: legacyPath, requiredPrivateRoot: false)
        guard source.identity.device == device, source.identity.inode == inode else {
            throw WorkspaceError.conflict
        }
        var locks: [Int32] = []
        defer { for fd in locks.reversed() { _ = flock(fd, LOCK_UN); close(fd) } }
        for name in ["authoring.lock", "lock"] {
            let fd = openat(source.fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw WorkspaceError.unavailable }
            locks.append(fd)
            var metadata = stat()
            guard fstat(fd, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WorkspaceError.unavailable }
        }
        try checkOwner()
        return try perform()
    }
}

final class WorkspaceLegacyMigrationPlan {
    fileprivate let source: WorkspaceFiles
    fileprivate let sourceImages: [String: Data]
    fileprivate let projectRecords: [ProjectRecord]
    fileprivate let packageRecords: [PackageRecord]
    fileprivate let headRecords: [LegacyHeadRecord]
    fileprivate let cacheOnlyRevisions: [String]
    fileprivate let optionalImages: [String: Data]
    let summary: WorkspaceLegacyMigrationSummary
    fileprivate init(source: WorkspaceFiles, sourceImages: [String: Data],
                     projectRecords: [ProjectRecord], packageRecords: [PackageRecord],
                     headRecords: [LegacyHeadRecord], cacheOnlyRevisions: [String],
                     optionalImages: [String: Data], summary: WorkspaceLegacyMigrationSummary) {
        self.source = source; self.sourceImages = sourceImages
        self.projectRecords = projectRecords; self.packageRecords = packageRecords
        self.headRecords = headRecords; self.cacheOnlyRevisions = cacheOnlyRevisions
        self.optionalImages = optionalImages; self.summary = summary
    }
}

private struct ProjectRecord {
    let project: WorkspaceProject
    let document: WorkspaceProjectDocument
    let files: [String: Data]
    let includedFiles: [String: Data]
    let legacyVersion: String
    let newVersion: String
}
private struct PackageRecord {
    let dashboardId: String
    let revision: String
    let manifestBytes: Data
    let files: [String: Data]
}
private struct LegacyHeadRecord {
    let dashboardId: String
    let bytes: Data
    let draftRevision: String
}
private struct MigrationPortableRecord: Codable {
    let schemaVersion: Int
    let migrationId: String
    let projectIds: [String]
    let packageRevisions: [String]
    let cacheOnlyRevisions: [String]
    let legacyDraftHeads: [String: String]
    let sourceVersionMap: [String: String]
    let unknownKitProvenance: [String]
    let excludedClasses: [String]
    let unsupportedPortablePaths: [String]
    let originalsPreserved: Bool
}

/// Copies approved legacy portable classes into a new visible workspace on
/// the destination volume, verifies every source preimage, then selects it.
/// Failure before selection retains the original source and local pointer.
final class WorkspaceLegacyMigration {
    private let workspace: WorkspaceStore
    init(workspace: WorkspaceStore) { self.workspace = workspace }

    private func historyMetadata(_ item: ProjectRecord) -> WorkbenchSourceHistoryEntry {
        WorkbenchSourceHistoryEntry(sourceVersion: item.newVersion, sourceHashVersion: 1,
            projectId: item.project.projectId, dashboardId: item.project.dashboardId,
            files: item.includedFiles.keys.sorted().map { member in
                WorkbenchSourceFile(path: member, sha256: WorkbenchTransactionDigest.hex(item.includedFiles[member]!),
                                    bytes: item.includedFiles[member]!.count)
            })
    }
    private func portableRecord(migrationId: String, projectIds: [String], packageRevisions: [String],
                                projects: [ProjectRecord], heads: [LegacyHeadRecord],
                                cacheOnlyRevisions: [String], excluded: [String],
                                unsupported: [String]) -> MigrationPortableRecord {
        MigrationPortableRecord(schemaVersion: 1, migrationId: migrationId,
            projectIds: projectIds, packageRevisions: packageRevisions,
            cacheOnlyRevisions: cacheOnlyRevisions,
            legacyDraftHeads: Dictionary(uniqueKeysWithValues: heads.map { ($0.dashboardId, $0.draftRevision) }),
            sourceVersionMap: Dictionary(uniqueKeysWithValues: projects.map {
                ($0.project.projectId, $0.legacyVersion + " -> " + $0.newVersion)
            }), unknownKitProvenance: projectIds, excludedClasses: excluded,
            unsupportedPortablePaths: unsupported, originalsPreserved: true)
    }

    func inspectLegacy(at path: String, timeout: TimeInterval = 120,
                       cancelled: @escaping () -> Bool = { false }) throws -> WorkspaceLegacyMigrationPlan {
        guard timeout > 0, timeout <= 3_600 else { throw WorkspaceError.limitExceeded }
        return try inspectLegacy(at: path, budget: WorkspaceReadBudget(
            deadline: ProcessInfo.processInfo.systemUptime + timeout, cancelled: cancelled))
    }
    private func inspectLegacy(at path: String, budget: WorkspaceReadBudget) throws -> WorkspaceLegacyMigrationPlan {
        let source = try WorkspaceFiles(path: path, requiredPrivateRoot: false)
        try budget.requireLocal(source.fd)
        var images: [String: Data] = [:]
        var projects: [ProjectRecord] = [], packages: [PackageRecord] = []
        var heads: [LegacyHeadRecord] = []
        var cacheOnlyRevisions: [String] = []
        var total = 0, members = 0
        var unsupported: [String] = []
        func remember(_ relative: String, _ bytes: Data) throws {
            guard bytes.count <= 150 * 1024 * 1024 - total else { throw WorkspaceError.limitExceeded }
            total += bytes.count; images[relative] = bytes
        }
        let projectBase = ["authoring", "projects"]
        if try directoryExists(source, projectBase) {
            for id in try entries(source, projectBase, budget: budget, members: &members) {
                guard WorkspaceValidation.id(id) else { throw WorkspaceError.invalidSchema }
                let base = projectBase + [id]
                let metadata = try read(source, base + ["project.json"], budget: budget)
                try remember((base + ["project.json"]).joined(separator: "/"), metadata)
                guard let raw = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
                      let dashboardId = raw["dashboardId"] as? String, WorkspaceValidation.id(dashboardId),
                      let kitVersion = raw["kitVersion"] as? String, WorkspaceValidation.id(kitVersion)
                else { throw WorkspaceError.invalidSchema }
                var files: [String: Data] = [:]
                try scan(source, base + ["source"], relative: [], budget: budget, members: &members) { parts, bytes in
                    let member = parts.joined(separator: "/")
                    guard !WorkspaceFiles.fixedSourceExcludes(member), bytes.count <= 5 * 1024 * 1024,
                          files.count < 2_000 else { throw WorkspaceError.limitExceeded }
                    files[member] = bytes
                    try remember((base + ["source"] + parts).joined(separator: "/"), bytes)
                }
                guard files["screenpunk.project.json"] == nil else { throw WorkspaceError.conflict }
                let kind: String, entry: String
                if files["src/main.tsx"] != nil { kind = "react"; entry = "src/main.tsx" }
                else if files["web/index.html"] != nil { kind = "web"; entry = "web/index.html" }
                else { throw WorkspaceError.invalidSchema }
                guard let screen = files["screen.json"],
                      let config = try JSONSerialization.jsonObject(with: screen) as? [String: Any] else {
                    throw WorkspaceError.invalidSchema
                }
                let name = (config["name"] as? String).flatMap { WorkspaceValidation.text($0) ? $0 : nil } ?? id
                let project = WorkspaceProject(projectId: id, dashboardId: dashboardId, name: name,
                    location: .contained("Screens/legacy-" + id))
                let document = WorkspaceProjectDocument(schemaVersion: 1, projectId: id,
                    dashboardId: dashboardId, name: name, kind: kind, kitVersion: kitVersion,
                    entry: entry, screenConfig: "screen.json")
                try document.validate(matching: project)
                // The old ScreenAuthoring reader skips hidden entries before
                // computing its source version. The new reader includes the
                // ignore file itself but excludes paths matched by its rules.
                let legacyFiles = files.filter { path, _ in
                    !path.split(separator: "/").contains(where: { $0.hasPrefix(".") })
                }
                let legacyMaterial = legacyFiles.keys.sorted().map {
                    "\($0):\(WorkbenchTransactionDigest.hex(legacyFiles[$0]!))"
                }.joined(separator: "\n")
                let legacyVersion = WorkbenchTransactionDigest.hex(Data(legacyMaterial.utf8))
                files["screenpunk.project.json"] = try WorkspaceJSON.encode(document)
                let rules = try WorkspaceIgnoreRules(data: files[".screenpunkignore"], readBudget: budget)
                try WorkspaceProjectedSourcePolicy.validate(current: rules, projected: rules,
                    targets: [], required: ["screenpunk.project.json", document.screenConfig, document.entry])
                let included = files.filter { !rules.excludes($0.key) }
                let newVersion = try WorkbenchSourceHasher.hash(included)
                projects.append(.init(project: project, document: document, files: files,
                                      includedFiles: included,
                                      legacyVersion: legacyVersion, newVersion: newVersion))
                unsupported += try unlisted(source, base, allowed: ["project.json", "source"],
                                             budget: budget, members: &members)
            }
        }
        if try directoryExists(source, ["authoring"]) {
            unsupported += try unlisted(source, ["authoring"], allowed: ["projects", "authoring.lock"],
                                         budget: budget, members: &members)
        }
        if try directoryExists(source, ["dashboards"]) {
            for dashboardId in try entries(source, ["dashboards"], budget: budget, members: &members) {
                guard WorkspaceValidation.id(dashboardId) else { throw WorkspaceError.invalidSchema }
                let dashboardBase = ["dashboards", dashboardId]
                let hasHead = try { () throws -> Bool in
                    let dashboardFD = try source.directory(dashboardBase)
                    defer { close(dashboardFD) }
                    return try source.exists(dashboardFD, "head.json")
                }()
                if hasHead {
                    let headPath = (dashboardBase + ["head.json"]).joined(separator: "/")
                    let headBytes = try read(source, dashboardBase + ["head.json"], budget: budget)
                    try remember(headPath, headBytes)
                    guard headBytes.count <= 1_048_576,
                          let raw = try JSONSerialization.jsonObject(with: headBytes) as? [String: Any],
                          let name = raw["name"] as? String, WorkspaceValidation.text(name),
                          let draft = raw["draftRevision"] as? String, WorkspaceValidation.id(draft),
                          raw["updatedAt"] as? String != nil else { throw WorkspaceError.invalidSchema }
                    heads.append(.init(dashboardId: dashboardId, bytes: headBytes, draftRevision: draft))
                }
                unsupported += try unlisted(source, dashboardBase, allowed: ["head.json", "revisions"],
                                             budget: budget, members: &members)
                let revisions = ["dashboards", dashboardId, "revisions"]
                guard try directoryExists(source, revisions) else { continue }
                for revision in try entries(source, revisions, budget: budget, members: &members) {
                    guard WorkspaceValidation.id(revision), !revision.hasSuffix(".staging") else {
                        throw WorkspaceError.invalidSchema
                    }
                    let base = revisions + [revision]
                    let manifestBytes = try read(source, base + ["manifest.json"], budget: budget)
                    guard manifestBytes.count <= 8 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
                    try remember((base + ["manifest.json"]).joined(separator: "/"), manifestBytes)
                    let manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestBytes)
                    try PackageValidator.validate(manifest)
                    try PackageValidator.validateInventoryBounds(manifest.files)
                    guard manifest.dashboardId == dashboardId, manifest.revision == revision,
                          manifest.digest == (try DeploymentDigest.digest(for: manifest)) else {
                        throw WorkspaceError.conflict
                    }
                    var files: [String: Data] = [:]
                    for item in manifest.files {
                        try budget.check()
                        guard WorkspaceValidation.member(item.path) else { throw WorkspaceError.invalidPath }
                        let parts = item.path.split(separator: "/").map(String.init)
                        let bytes = try read(source, base + parts, maxBytes: item.bytes, budget: budget)
                        guard bytes.count == item.bytes,
                              WorkbenchTransactionDigest.hex(bytes) == item.sha256 else {
                            throw WorkspaceError.conflict
                        }
                        files[item.path] = bytes
                        try remember((base + parts).joined(separator: "/"), bytes)
                    }
                    packages.append(.init(dashboardId: dashboardId, revision: revision,
                                          manifestBytes: manifestBytes, files: files))
                    unsupported += try unlistedDeclaredTree(source, base,
                        declaredFiles: Set(["manifest.json"] + manifest.files.map(\.path)),
                        budget: budget, members: &members)
                }
            }
        }
        let libraryRevisions = Set(packages.map { $0.dashboardId + "/" + $0.revision })
        for head in heads where !libraryRevisions.contains(head.dashboardId + "/" + head.draftRevision) {
            throw WorkspaceError.incomplete
        }
        if try directoryExists(source, ["device-packages"]) {
            var known = Dictionary(uniqueKeysWithValues: packages.map {
                ($0.dashboardId + "/" + $0.revision, $0)
            })
            for deviceId in try entries(source, ["device-packages"], budget: budget, members: &members) {
                guard WorkspaceValidation.id(deviceId) else { throw WorkspaceError.invalidSchema }
                let device = ["device-packages", deviceId]
                unsupported += try unlisted(source, device, allowed: ["dashboards", "lock"],
                                             budget: budget, members: &members)
                guard try directoryExists(source, device + ["dashboards"]) else { continue }
                for dashboardId in try entries(source, device + ["dashboards"],
                                               budget: budget, members: &members) {
                    guard WorkspaceValidation.id(dashboardId) else { throw WorkspaceError.invalidSchema }
                    let dashboard = device + ["dashboards", dashboardId]
                    unsupported += try unlisted(source, dashboard, allowed: ["head.json", "revisions"],
                                                 budget: budget, members: &members)
                    let revisions = dashboard + ["revisions"]
                    guard try directoryExists(source, revisions) else { continue }
                    for revision in try entries(source, revisions, budget: budget, members: &members) {
                        guard WorkspaceValidation.id(revision), !revision.hasSuffix(".staging") else {
                            throw WorkspaceError.invalidSchema
                        }
                        let base = revisions + [revision]
                        let manifestBytes = try read(source, base + ["manifest.json"], budget: budget)
                        guard manifestBytes.count <= 8 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
                        try remember((base + ["manifest.json"]).joined(separator: "/"), manifestBytes)
                        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestBytes)
                        try PackageValidator.validate(manifest)
                        try PackageValidator.validateInventoryBounds(manifest.files)
                        guard manifest.dashboardId == dashboardId, manifest.revision == revision,
                              manifest.digest == (try DeploymentDigest.digest(for: manifest)) else {
                            throw WorkspaceError.conflict
                        }
                        var files: [String: Data] = [:]
                        for item in manifest.files {
                            try budget.check()
                            guard WorkspaceValidation.member(item.path) else { throw WorkspaceError.invalidPath }
                            let parts = item.path.split(separator: "/").map(String.init)
                            let bytes = try read(source, base + parts, maxBytes: item.bytes, budget: budget)
                            guard bytes.count == item.bytes,
                                  WorkbenchTransactionDigest.hex(bytes) == item.sha256 else {
                                throw WorkspaceError.conflict
                            }
                            files[item.path] = bytes
                            try remember((base + parts).joined(separator: "/"), bytes)
                        }
                        let key = dashboardId + "/" + revision
                        if let previous = known[key] {
                            guard previous.manifestBytes == manifestBytes, previous.files == files else {
                                throw WorkspaceError.conflict
                            }
                        } else {
                            let record = PackageRecord(dashboardId: dashboardId, revision: revision,
                                                       manifestBytes: manifestBytes, files: files)
                            packages.append(record); known[key] = record
                            cacheOnlyRevisions.append(key)
                        }
                        unsupported += try unlistedDeclaredTree(source, base,
                            declaredFiles: Set(["manifest.json"] + manifest.files.map(\.path)),
                            budget: budget, members: &members)
                    }
                }
            }
        }
        var optional: [String: Data] = [:]
        for path in ["portable-settings.json", "toolchain-requirements.json"] {
            if try source.exists(source.fd, path) {
                let bytes = try source.read(source.fd, path, readBudget: budget)
                if path == "portable-settings.json" {
                    let value = try WorkspaceJSON.decode(WorkspaceSettings.self, from: bytes, shape: .settings)
                    try value.validate()
                } else {
                    let value = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
                        from: bytes, shape: .requirements)
                    try value.validate()
                }
                try remember(path, bytes); optional[path] = bytes
            }
        }
        if try directoryExists(source, ["attachments"]) {
            try scan(source, ["attachments"], relative: [], budget: budget, members: &members) { parts, bytes in
                let path = "attachments/" + parts.joined(separator: "/")
                try remember(path, bytes); optional[path] = bytes
            }
        }
        unsupported += try unlisted(source, [], allowed: ["authoring", "dashboards", "attachments",
            "portable-settings.json", "toolchain-requirements.json", "kits", "devices",
            "operations", "runtime", ".screenpunk.lock", "authoring.lock", "lock",
            "device-packages", "devices.json", "devices.json.lock", "public-read-approvals", "agents"],
            budget: budget, members: &members)
        guard !projects.isEmpty || !packages.isEmpty else { throw WorkspaceError.unavailable }
        var unique = Set<String>()
        for project in projects {
            guard unique.insert(project.project.projectId).inserted else { throw WorkspaceError.conflict }
        }
        let excluded = ["machine identity and device pins", "approvals and active operations",
                        "credentials and endpoints", "cached authoring kits and build jobs",
                        "device cache owner identities and draft heads; package bytes only",
                        "external editable sources require separate reviewed import"]
        let migrationId = UUID().uuidString.lowercased()
        let projectIds = projects.map { $0.project.projectId }.sorted()
        let packageRevisions = packages.map { $0.dashboardId + "/" + $0.revision }.sorted()
        let unsupportedPaths = unsupported.sorted()
        var outputMembers = Set<String>()
        var expandedBytes = 0
        func output(_ parts: [String]) throws {
            for end in 1...parts.count {
                outputMembers.insert(parts.prefix(end).joined(separator: "/"))
                guard outputMembers.count <= 50_000 else { throw WorkspaceError.limitExceeded }
            }
        }
        func outputFile(_ parts: [String], _ bytes: Data) throws {
            try output(parts)
            guard bytes.count <= 150 * 1024 * 1024 - expandedBytes else { throw WorkspaceError.limitExceeded }
            expandedBytes += bytes.count
        }
        for path in ["Screens", "Workbench/Library", "Workbench/Settings", "Workbench/History/Builds",
                     "Workbench/History/Packages", "Workbench/History/Prepared", "Workbench/History/Deployments",
                     "Workbench/Attachments", "Workbench/Toolchains", "Workbench/Transactions", "Workbench/Migrations"] {
            try output(path.split(separator: "/").map(String.init))
        }
        // The descriptor generated during apply uses a fresh UUID of the same
        // fixed length, so its encoded byte count is stable across the two calls.
        try outputFile(["workspace.json"], WorkspaceJSON.encode(WorkspaceDescriptor(name: "Screenpunk")))
        try outputFile(["Workbench", "Library", "catalog.json"],
                       WorkspaceJSON.encode(WorkspaceCatalog(projects: projects.map(\.project))))
        try outputFile(["Workbench", "Settings", "workbench.json"],
                       optional["portable-settings.json"] ?? WorkspaceJSON.encode(WorkspaceSettings()))
        try outputFile(["Workbench", "Settings", "connections.json"],
                       WorkspaceJSON.encode(WorkspaceConnections()))
        try outputFile(["Workbench", "Toolchains", "requirements.json"],
                       optional["toolchain-requirements.json"] ?? WorkspaceJSON.encode(WorkspaceToolchainRequirements()))
        for item in projects {
            let folder = item.project.location.path!.split(separator: "/").map(String.init)
            for (member, bytes) in item.files {
                try outputFile(folder + member.split(separator: "/").map(String.init), bytes)
            }
            let history = ["Workbench", "History", "Builds", item.newVersion, "source"]
            for (member, bytes) in item.includedFiles {
                try outputFile(history + member.split(separator: "/").map(String.init), bytes)
            }
            try outputFile(history + [".screenpunk-snapshot.json"],
                           JSONEncoder().encode(historyMetadata(item)))
        }
        for item in packages {
            let id = WorkbenchTransactionDigest.hex(Data((item.dashboardId + "\0" + item.revision).utf8))
            let base = ["Workbench", "History", "Packages", id]
            try outputFile(base + ["manifest.json"], item.manifestBytes)
            for (path, bytes) in item.files {
                try outputFile(base + ["files"] + path.split(separator: "/").map(String.init), bytes)
            }
        }
        for head in heads {
            try outputFile(["Workbench", "Migrations", migrationId, "legacy-heads",
                            head.dashboardId + ".json"], head.bytes)
        }
        for (path, bytes) in optional where path.hasPrefix("attachments/") {
            try outputFile(["Workbench", "Attachments"] + String(path.dropFirst("attachments/".count))
                .split(separator: "/").map(String.init), bytes)
        }
        try outputFile(["Workbench", "Migrations", migrationId, "record.json"],
                       WorkspaceJSON.encode(portableRecord(migrationId: migrationId,
                           projectIds: projectIds, packageRevisions: packageRevisions,
                           projects: projects, heads: heads,
                           cacheOnlyRevisions: cacheOnlyRevisions.sorted(),
                           excluded: excluded, unsupported: unsupportedPaths)))
        guard expandedBytes <= 150 * 1024 * 1024, members <= 10_000 else {
            throw WorkspaceError.limitExceeded
        }
        let summary = WorkspaceLegacyMigrationSummary(migrationId: migrationId,
            projectIds: projectIds, packageRevisions: packageRevisions,
            portableBytes: total, expandedBytes: expandedBytes,
            plannedMembers: outputMembers.count,
            unsupportedPortablePaths: unsupportedPaths, excludedClasses: excluded, sourcePath: path)
        return WorkspaceLegacyMigrationPlan(source: source, sourceImages: images,
            projectRecords: projects, packageRecords: packages,
            headRecords: heads, cacheOnlyRevisions: cacheOnlyRevisions.sorted(),
            optionalImages: optional, summary: summary)
    }

    func apply(_ plan: WorkspaceLegacyMigrationPlan, to destination: String,
               gate: WorkspaceOldWriterExclusionGate, timeout: TimeInterval = 120,
               cancelled: @escaping () -> Bool = { false }) throws -> WorkspaceOverview {
        guard WorkspaceValidation.absolute(destination),
              destination != plan.summary.sourcePath,
              !destination.hasPrefix(plan.summary.sourcePath + "/"),
              !plan.summary.sourcePath.hasPrefix(destination + "/") else { throw WorkspaceError.invalidPath }
        guard plan.summary.unsupportedPortablePaths.isEmpty else { throw WorkspaceError.incomplete }
        guard timeout > 0, timeout <= 3_600 else { throw WorkspaceError.limitExceeded }
        let budget = WorkspaceReadBudget(deadline: ProcessInfo.processInfo.systemUptime + timeout,
                                         cancelled: cancelled)
        return try gate.withExclusion(legacyPath: plan.source.path,
                                      device: plan.source.identity.device, inode: plan.source.identity.inode) {
            try applyExcluded(plan, to: destination, budget: budget)
        }
    }
    private func applyExcluded(_ plan: WorkspaceLegacyMigrationPlan,
                               to destination: String, budget: WorkspaceReadBudget) throws -> WorkspaceOverview {
        try budget.check()
        try plan.source.verifyRoot()
        let fresh = try inspectLegacy(at: plan.source.path, budget: budget)
        guard fresh.source.identity == plan.source.identity,
              fresh.summary.projectIds == plan.summary.projectIds,
              fresh.summary.packageRevisions == plan.summary.packageRevisions,
              fresh.summary.unsupportedPortablePaths == plan.summary.unsupportedPortablePaths,
              fresh.sourceImages == plan.sourceImages else { throw WorkspaceError.conflict }
        try budget.check()
        let parentPath = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        guard WorkspaceValidation.member(name), !name.contains("/") else { throw WorkspaceError.invalidPath }
        let parent = try WorkspaceFiles(path: parentPath, requiredPrivateRoot: false)
        guard try !parent.exists(parent.fd, name) else { throw WorkspaceError.alreadyExists }
        let stageName = ".screenpunk-migration-" + plan.summary.migrationId
        let stage = try WorkspaceFiles(path: parentPath + "/" + stageName, create: true)
        var published = false
        defer {
            if !published, (try? budget.check()) != nil {
                try? removeOwnedStage(parent: parent, name: stageName, stage: stage, budget: budget)
            }
        }
        try scaffold(stage, budget: budget)
        let descriptor = WorkspaceDescriptor(name: "Screenpunk")
        try stage.write(stage.fd, "workspace.json", data: WorkspaceJSON.encode(descriptor), expected: nil)
        let catalog = WorkspaceCatalog(projects: plan.projectRecords.map(\.project))
        let library = try stage.directory(["Workbench", "Library"]); defer { close(library) }
        try stage.write(library, "catalog.json", data: WorkspaceJSON.encode(catalog), expected: nil)
        let settings = try stage.directory(["Workbench", "Settings"]); defer { close(settings) }
        let portableSettings: Data
        if let prior = plan.optionalImages["portable-settings.json"] { portableSettings = prior }
        else { portableSettings = try WorkspaceJSON.encode(WorkspaceSettings()) }
        try stage.write(settings, "workbench.json", data: portableSettings, expected: nil)
        try stage.write(settings, "connections.json", data: WorkspaceJSON.encode(WorkspaceConnections()), expected: nil)
        let toolchains = try stage.directory(["Workbench", "Toolchains"]); defer { close(toolchains) }
        let requirements: Data
        if let prior = plan.optionalImages["toolchain-requirements.json"] { requirements = prior }
        else { requirements = try WorkspaceJSON.encode(WorkspaceToolchainRequirements()) }
        try stage.write(toolchains, "requirements.json", data: requirements, expected: nil)
        for item in plan.projectRecords {
            try budget.check()
            let folder = item.project.location.path!.split(separator: "/").map(String.init)
            for (member, bytes) in item.files {
                try writeNew(stage, folder + member.split(separator: "/").map(String.init), bytes, budget: budget)
            }
            let history = ["Workbench", "History", "Builds", item.newVersion, "source"]
            for (member, bytes) in item.includedFiles {
                try writeNew(stage, history + member.split(separator: "/").map(String.init), bytes, budget: budget)
            }
            try writeNew(stage, history + [".screenpunk-snapshot.json"],
                         try JSONEncoder().encode(historyMetadata(item)), budget: budget)
        }
        for item in plan.packageRecords {
            try budget.check()
            let objectID = WorkbenchTransactionDigest.hex(Data((item.dashboardId + "\0" + item.revision).utf8))
            let base = ["Workbench", "History", "Packages", objectID]
            try writeNew(stage, base + ["manifest.json"], item.manifestBytes, budget: budget)
            for (path, bytes) in item.files {
                try writeNew(stage, base + ["files"] + path.split(separator: "/").map(String.init), bytes,
                             budget: budget)
            }
        }
        for head in plan.headRecords {
            try writeNew(stage, ["Workbench", "Migrations", plan.summary.migrationId,
                                 "legacy-heads", head.dashboardId + ".json"], head.bytes, budget: budget)
        }
        for (path, bytes) in plan.optionalImages where path.hasPrefix("attachments/") {
            try budget.check()
            let member = String(path.dropFirst("attachments/".count))
            try writeNew(stage, ["Workbench", "Attachments"] + member.split(separator: "/").map(String.init),
                         bytes, budget: budget)
        }
        let record = portableRecord(migrationId: plan.summary.migrationId,
            projectIds: plan.summary.projectIds, packageRevisions: plan.summary.packageRevisions,
            projects: plan.projectRecords, heads: plan.headRecords,
            cacheOnlyRevisions: plan.cacheOnlyRevisions,
            excluded: plan.summary.excludedClasses,
            unsupported: plan.summary.unsupportedPortablePaths)
        try writeNew(stage, ["Workbench", "Migrations", plan.summary.migrationId, "record.json"],
                     try WorkspaceJSON.encode(record), budget: budget)
        for item in plan.projectRecords {
            let folder = item.project.location.path!.split(separator: "/").map(String.init)
            for (member, bytes) in item.files {
                try verify(stage, folder + member.split(separator: "/").map(String.init), bytes, budget)
            }
            let history = ["Workbench", "History", "Builds", item.newVersion, "source"]
            for (member, bytes) in item.includedFiles {
                try verify(stage, history + member.split(separator: "/").map(String.init), bytes, budget)
            }
            let inventory = try stage.inventory(folder, readBudget: budget,
                required: ["screenpunk.project.json", item.document.screenConfig, item.document.entry])
            let currentFiles = try Dictionary(uniqueKeysWithValues: inventory.includedFiles.map { member in
                let parts = member.split(separator: "/").map(String.init)
                return (member, try read(stage, folder + parts, maxBytes: 5 * 1024 * 1024, budget: budget))
            })
            guard try WorkbenchSourceHasher.hash(currentFiles) == item.newVersion else {
                throw WorkspaceError.conflict
            }
        }
        for item in plan.packageRecords {
            let id = WorkbenchTransactionDigest.hex(Data((item.dashboardId + "\0" + item.revision).utf8))
            let base = ["Workbench", "History", "Packages", id]
            try verify(stage, base + ["manifest.json"], item.manifestBytes, budget)
            for (path, bytes) in item.files {
                try verify(stage, base + ["files"] + path.split(separator: "/").map(String.init), bytes, budget)
            }
        }
        for head in plan.headRecords {
            try verify(stage, ["Workbench", "Migrations", plan.summary.migrationId,
                               "legacy-heads", head.dashboardId + ".json"], head.bytes, budget)
        }
        for (path, bytes) in plan.optionalImages where path.hasPrefix("attachments/") {
            let member = String(path.dropFirst("attachments/".count))
            try verify(stage, ["Workbench", "Attachments"] + member.split(separator: "/").map(String.init),
                       bytes, budget)
        }
        try budget.check()
        let inspected = try workspace.inspect(at: stage.path, readBudget: budget)
        guard inspected.catalog == catalog, inspected.coverage.missingPaths.isEmpty else {
            throw WorkspaceError.conflict
        }
        try budget.check()
        let finalCheck = try inspectLegacy(at: plan.source.path, budget: budget)
        guard finalCheck.sourceImages == plan.sourceImages,
              finalCheck.summary.unsupportedPortablePaths == plan.summary.unsupportedPortablePaths,
              finalCheck.summary.unsupportedPortablePaths.isEmpty else { throw WorkspaceError.conflict }
        try budget.check()
        guard renameatx_np(parent.fd, stageName, parent.fd, name, UInt32(RENAME_EXCL)) == 0,
              fsync(parent.fd) == 0 else { throw WorkspaceError.unavailable }
        published = true
        return try workspace.open(at: destination, readBudget: budget)
    }

    private func scaffold(_ root: WorkspaceFiles, budget: WorkspaceReadBudget) throws {
        for path in ["Screens", "Workbench/Library", "Workbench/Settings", "Workbench/History/Builds",
                     "Workbench/History/Packages", "Workbench/History/Prepared", "Workbench/History/Deployments",
                     "Workbench/Attachments", "Workbench/Toolchains", "Workbench/Transactions", "Workbench/Migrations"] {
            try budget.check()
            let directory = try root.directory(path.split(separator: "/").map(String.init), create: true)
            close(directory)
        }
    }
    private func writeNew(_ root: WorkspaceFiles, _ parts: [String], _ bytes: Data,
                          budget: WorkspaceReadBudget) throws {
        try budget.check()
        guard parts.count <= 32, bytes.count <= 50 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
        let directory = try root.directory(Array(parts.dropLast()), create: true)
        defer { close(directory) }
        let name = parts.last!
        guard WorkspaceValidation.member(name), !name.contains("/"),
              !(try root.exists(directory, name)) else { throw WorkspaceError.conflict }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WorkspaceError.unavailable }
        defer { close(fd) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                try budget.check()
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset),
                                         min(bytes.count - offset, 65_536))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkspaceError.unavailable }
                offset += count
            }
        }
        try budget.check()
        guard fsync(fd) == 0, fsync(directory) == 0 else { throw WorkspaceError.unavailable }
    }
    private func directoryExists(_ root: WorkspaceFiles, _ parts: [String]) throws -> Bool {
        guard let first = parts.first, try root.exists(root.fd, first) else { return false }
        let parent = try root.directory(Array(parts.dropLast())); defer { close(parent) }
        guard try root.exists(parent, parts.last!) else { return false }
        let opened = try root.directory(parts); close(opened); return true
    }
    private func entries(_ root: WorkspaceFiles, _ parts: [String], budget: WorkspaceReadBudget,
                         members: inout Int) throws -> [String] {
        let directory = try root.directory(parts); defer { close(directory) }
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try budget.check()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name == "." || name == ".." { continue }
            guard WorkspaceValidation.member(name), !name.contains("/"), names.count < 10_000,
                  members < 10_000 else {
                throw WorkspaceError.limitExceeded
            }
            members += 1
            names.append(name)
        }
        var collisions = WorkspacePathCollisionDetector()
        for name in names { try collisions.insert(name) }
        return names.sorted()
    }
    private func unlisted(_ root: WorkspaceFiles, _ parts: [String], allowed: Set<String>,
                          budget: WorkspaceReadBudget, members: inout Int) throws -> [String] {
        try entries(root, parts, budget: budget, members: &members)
            .filter { !allowed.contains($0) }.map { (parts + [$0]).joined(separator: "/") }
    }
    private func unlistedDeclaredTree(_ root: WorkspaceFiles, _ base: [String],
                                      declaredFiles: Set<String>, budget: WorkspaceReadBudget,
                                      members: inout Int) throws -> [String] {
        func visit(_ relative: [String]) throws -> [String] {
            let prefix = relative.isEmpty ? "" : relative.joined(separator: "/") + "/"
            let children = Set(declaredFiles.compactMap { declared -> String? in
                guard declared.hasPrefix(prefix) else { return nil }
                return declared.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            })
            var unknown: [String] = []
            for name in try entries(root, base + relative, budget: budget, members: &members) {
                let child = relative + [name]
                let member = child.joined(separator: "/")
                if !children.contains(name) {
                    unknown.append((base + child).joined(separator: "/"))
                } else if declaredFiles.contains(where: { $0.hasPrefix(member + "/") }) {
                    unknown += try visit(child)
                }
            }
            return unknown
        }
        return try visit([])
    }
    private func scan(_ root: WorkspaceFiles, _ base: [String], relative: [String],
                      budget: WorkspaceReadBudget, members: inout Int,
                      visit: ([String], Data) throws -> Void) throws {
        guard base.count + relative.count <= 32 else { throw WorkspaceError.limitExceeded }
        let directory = base + relative
        for name in try entries(root, directory, budget: budget, members: &members) {
            try { () throws in
                let parent = try root.directory(directory); defer { close(parent) }
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
                      info.st_mode & 0o7000 == 0 else { throw WorkspaceError.unsafeFile }
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    try scan(root, base, relative: relative + [name], budget: budget,
                             members: &members, visit: visit)
                } else if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 {
                    let bytes = try root.read(parent, name, maxBytes: 50 * 1024 * 1024, readBudget: budget)
                    try visit(relative + [name], bytes)
                } else { throw WorkspaceError.unsafeFile }
            }()
        }
    }
    private func read(_ root: WorkspaceFiles, _ parts: [String], maxBytes: Int = 50 * 1024 * 1024,
                      budget: WorkspaceReadBudget) throws -> Data {
        let parent = try root.directory(Array(parts.dropLast())); defer { close(parent) }
        return try root.read(parent, parts.last!, maxBytes: maxBytes, readBudget: budget)
    }
    private func verify(_ root: WorkspaceFiles, _ parts: [String], _ expected: Data,
                        _ budget: WorkspaceReadBudget) throws {
        guard try read(root, parts, maxBytes: expected.count, budget: budget) == expected else {
            throw WorkspaceError.conflict
        }
    }
    private func removeOwnedStage(parent: WorkspaceFiles, name: String, stage: WorkspaceFiles,
                                  budget: WorkspaceReadBudget) throws {
        try budget.check()
        let opened = try parent.directory([name]); defer { close(opened) }
        var info = stat()
        guard fstat(opened, &info) == 0, WorkspaceNodeID(info) == stage.identity else {
            throw WorkspaceError.conflict
        }
        try removeChildren(opened, depth: 0, budget: budget)
        guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else { throw WorkspaceError.unavailable }
    }
    private func removeChildren(_ directory: Int32, depth: Int, budget: WorkspaceReadBudget) throws {
        guard depth <= 32 else { throw WorkspaceError.limitExceeded }
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try budget.check()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name == "." || name == ".." { continue }
            guard WorkspaceValidation.member(name), !name.contains("/"), names.count < 100_000 else {
                throw WorkspaceError.unsafeFile
            }
            names.append(name)
        }
        for name in names {
            try budget.check()
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw WorkspaceError.unsafeFile
            }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw WorkspaceError.unsafeFile }
                do { defer { close(child) }; try removeChildren(child, depth: depth + 1, budget: budget) }
                guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw WorkspaceError.unavailable }
            } else {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
                      unlinkat(directory, name, 0) == 0 else { throw WorkspaceError.unsafeFile }
            }
        }
    }
}
#endif
