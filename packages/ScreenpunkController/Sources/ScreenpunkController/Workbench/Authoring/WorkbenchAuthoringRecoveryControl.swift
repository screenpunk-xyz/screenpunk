import Foundation
import CoreFoundation
#if os(macOS)

/// Closed authoring/recovery vocabulary. Source edits are confined to a
/// registered contained project and carry an expected source hash.
public enum WorkbenchAuthoringRecoveryMethod: String, CaseIterable, Sendable {
    case projectCreate = "project.create"
    case projectClone = "project.clone"
    case projectUnregister = "project.unregister"
    case projectRelocateContained = "project.relocateContained"
    case projectUpgradeKit = "project.upgradeKit"
    case projectInspect = "project.inspect"
    case projectPatch = "project.patch"
    case projectOpenContained = "project.openContained"
    case projectSourceExport = "project.exportSource"
    case projectSourceImport = "project.importSource"
    case projectOpenExternal = "project.openExternal"
    case projectAdoptExternal = "project.adoptExternal"
    case projectRelocateExternal = "project.relocateExternal"
    case buildRun = "build.run"
    case buildHead = "build.head"
    case packageHistory = "package.history"
    case packageExport = "package.export"
    case snapshotCreate = "workspace.snapshot"
    case workspaceRelocate = "workspace.relocate"
    case workspaceConfigGet = "workspace.configGet"
    case workspaceConfigPath = "workspace.configPath"
    case workspaceConfigSet = "workspace.configSet"
    case workspaceConfigUnset = "workspace.configUnset"
    case migrationPlan = "migration.plan"
    case migrationReview = "migration.review"
    case migrationApply = "migration.apply"
}

public enum WorkbenchAuthoringRecoveryRequest {
    indirect case selectionBound(request: WorkbenchAuthoringRecoveryRequest,
                                 workspaceId: String, selectionGeneration: Int)
    case projectCreate(name: String, kind: String)
    case projectClone(id: String, expectedSourceVersion: String, name: String?)
    case projectUnregister(id: String, expectedCatalogGeneration: Int)
    case projectRelocateContained(id: String, expectedSourceVersion: String,
                                  relativeDestination: String, expectedCatalogGeneration: Int)
    case projectUpgradeKit(id: String, expectedSourceVersion: String,
                           expectedCatalogGeneration: Int,
                           requirement: WorkspaceToolchainRequirements.Requirement)
    case projectInspect(id: String)
    case projectPatch(id: String, expectedSourceVersion: String, changes: [WorkbenchSourceChange])
    case projectOpenContained(path: String)
    case projectSourceExport(id: String, sourceVersion: String, path: String)
    case projectSourceImport(path: String, name: String?)
    case projectOpenExternal(path: String)
    case projectAdoptExternal(id: String, expectedSourceVersion: String, name: String)
    case projectRelocateExternal(id: String, expectedSourceVersion: String, path: String)
    case buildRun(id: String, expectedSourceVersion: String, baseRevision: String?)
    case buildHead(id: String)
    case packageHistory(cursor: String?)
    case packageExport(dashboardId: String, revision: String, path: String)
    case snapshotCreate(path: String, includeExternal: Bool = false, allowIncomplete: Bool = false)
    case workspaceRelocate(path: String)
    case workspaceConfigGet
    case workspaceConfigPath
    case workspaceConfigSet(key: String, value: String, expectedGeneration: Int)
    case workspaceConfigUnset(key: String, expectedGeneration: Int)
    case migrationPlan(path: String, destination: String?)
    case migrationReview(id: String)
    case migrationApply(id: String)

    public var method: WorkbenchAuthoringRecoveryMethod {
        switch self {
        case .selectionBound(let request, _, _): return request.method
        case .projectCreate: return .projectCreate
        case .projectClone: return .projectClone
        case .projectUnregister: return .projectUnregister
        case .projectRelocateContained: return .projectRelocateContained
        case .projectUpgradeKit: return .projectUpgradeKit
        case .projectInspect: return .projectInspect
        case .projectPatch: return .projectPatch
        case .projectOpenContained: return .projectOpenContained
        case .projectSourceExport: return .projectSourceExport
        case .projectSourceImport: return .projectSourceImport
        case .projectOpenExternal: return .projectOpenExternal
        case .projectAdoptExternal: return .projectAdoptExternal
        case .projectRelocateExternal: return .projectRelocateExternal
        case .buildRun: return .buildRun
        case .buildHead: return .buildHead
        case .packageHistory: return .packageHistory
        case .packageExport: return .packageExport
        case .snapshotCreate: return .snapshotCreate
        case .workspaceRelocate: return .workspaceRelocate
        case .workspaceConfigGet: return .workspaceConfigGet
        case .workspaceConfigPath: return .workspaceConfigPath
        case .workspaceConfigSet: return .workspaceConfigSet
        case .workspaceConfigUnset: return .workspaceConfigUnset
        case .migrationPlan: return .migrationPlan
        case .migrationReview: return .migrationReview
        case .migrationApply: return .migrationApply
        }
    }

    public var expectedSelection: (workspaceId: String, generation: Int)? {
        if case .selectionBound(_, let id, let generation) = self { return (id, generation) }
        return nil
    }

    public static func parse(method: WorkbenchAuthoringRecoveryMethod,
                             params: [String: Any]) throws -> Self {
        guard let version = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        let hasId = params.keys.contains("expectedWorkspaceId")
        let hasGeneration = params.keys.contains("expectedSelectionGeneration")
        guard hasId == hasGeneration else { throw WorkbenchIPCError(.invalidRequest) }
        if hasId {
            guard let id = params["expectedWorkspaceId"] as? String, WorkspaceValidation.id(id),
                  let generation = params["expectedSelectionGeneration"] as? NSNumber,
                  CFGetTypeID(generation) != CFBooleanGetTypeID(),
                  generation.doubleValue == Double(generation.intValue), generation.intValue >= 0 else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            var unbound = params
            unbound.removeValue(forKey: "expectedWorkspaceId")
            unbound.removeValue(forKey: "expectedSelectionGeneration")
            return .selectionBound(request: try parse(method: method, params: unbound),
                                   workspaceId: id, selectionGeneration: generation.intValue)
        }
        func keys(_ expected: Set<String>) throws {
            guard Set(params.keys) == expected else { throw WorkbenchIPCError(.invalidRequest) }
        }
        func id(_ name: String) throws -> String {
            guard let value = params[name] as? String, WorkspaceValidation.id(value) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return value
        }
        func path() throws -> String {
            guard let value = params["path"] as? String, WorkspaceValidation.absolute(value) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return value
        }
        switch method {
        case .projectCreate:
            try keys(["schemaVersion", "name", "kind"])
            guard let name = params["name"] as? String, WorkspaceValidation.text(name),
                  !name.isEmpty, name.utf8.count <= 120,
                  let kind = params["kind"] as? String,
                  ["web", "react"].contains(kind) else { throw WorkbenchIPCError(.invalidRequest) }
            return .projectCreate(name: name, kind: kind)
        case .projectClone:
            let fields = Set(params.keys)
            guard fields == ["schemaVersion", "projectId", "expectedSourceVersion"] ||
                  fields == ["schemaVersion", "projectId", "expectedSourceVersion", "name"],
                  let source = params["expectedSourceVersion"] as? String,
                  WorkspaceValidation.sha256(source) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let name = params["name"] as? String
            guard params["name"] == nil ||
                  (name.map { WorkspaceValidation.member($0) && !$0.contains("/") &&
                    !$0.hasPrefix(".") && $0.utf8.count <= 120 } == true) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .projectClone(id: try id("projectId"), expectedSourceVersion: source,
                name: name)
        case .projectUnregister:
            try keys(["schemaVersion", "projectId", "expectedCatalogGeneration"])
            guard let expected = params["expectedCatalogGeneration"] as? NSNumber,
                  CFGetTypeID(expected) != CFBooleanGetTypeID(),
                  expected.doubleValue == Double(expected.intValue),
                  expected.intValue >= 0,
                  expected.intValue < WorkspaceValidation.maxUInt else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .projectUnregister(id: try id("projectId"),
                expectedCatalogGeneration: expected.intValue)
        case .projectRelocateContained:
            try keys(["schemaVersion", "projectId", "expectedSourceVersion",
                      "relativeDestination", "expectedCatalogGeneration"])
            guard let source = params["expectedSourceVersion"] as? String,
                  WorkspaceValidation.sha256(source),
                  let relative = params["relativeDestination"] as? String,
                  WorkspaceValidation.member(relative),
                  relative.split(separator: "/").count == 2,
                  relative.hasPrefix("Screens/"),
                  let expected = params["expectedCatalogGeneration"] as? NSNumber,
                  CFGetTypeID(expected) != CFBooleanGetTypeID(),
                  expected.doubleValue == Double(expected.intValue),
                  expected.intValue >= 0,
                  expected.intValue < WorkspaceValidation.maxUInt else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .projectRelocateContained(id: try id("projectId"),
                expectedSourceVersion: source, relativeDestination: relative,
                expectedCatalogGeneration: expected.intValue)
        case .projectUpgradeKit:
            try keys(["schemaVersion", "projectId", "expectedSourceVersion",
                      "expectedCatalogGeneration", "catalogEntryId", "kitVersion", "inventoryHash"])
            guard let source = params["expectedSourceVersion"] as? String,
                  WorkspaceValidation.sha256(source),
                  let entry = params["catalogEntryId"] as? String,
                  WorkspaceValidation.id(entry),
                  let version = params["kitVersion"] as? String,
                  WorkspaceValidation.id(version),
                  let inventory = params["inventoryHash"] as? String,
                  WorkspaceValidation.sha256(inventory),
                  let expected = params["expectedCatalogGeneration"] as? NSNumber,
                  CFGetTypeID(expected) != CFBooleanGetTypeID(),
                  expected.doubleValue == Double(expected.intValue),
                  expected.intValue >= 0,
                  expected.intValue < WorkspaceValidation.maxUInt else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .projectUpgradeKit(id: try id("projectId"), expectedSourceVersion: source,
                expectedCatalogGeneration: expected.intValue,
                requirement: .init(catalogEntryId: entry, kitVersion: version,
                    platform: "darwin-arm64", inventoryHash: inventory))
        case .projectInspect, .buildHead:
            try keys(["schemaVersion", "projectId"])
            let value = try id("projectId")
            return method == .projectInspect ? .projectInspect(id: value) : .buildHead(id: value)
        case .projectPatch:
            try keys(["schemaVersion", "projectId", "expectedSourceVersion", "changes"])
            let projectId = try id("projectId")
            guard let source = params["expectedSourceVersion"] as? String,
                  WorkspaceValidation.sha256(source),
                  let raw = params["changes"] as? [[String: Any]], (1...16).contains(raw.count) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            var changes: [WorkbenchSourceChange] = []
            var seen = Set<String>()
            for item in raw {
                let fields = Set(item.keys)
                guard fields == ["path", "bytesBase64"] || fields == ["path", "delete"],
                      let path = item["path"] as? String,
                      WorkspaceValidation.member(path), !WorkspaceFiles.fixedSourceExcludes(path),
                      path != "screenpunk.project.json", path != "screenpunk.lock.json",
                      seen.insert(path).inserted else { throw WorkbenchIPCError(.invalidRequest) }
                if fields.contains("delete") {
                    guard let value = item["delete"] as? NSNumber,
                          CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    changes.append(.init(path: path, bytes: nil))
                } else {
                    guard let encoded = item["bytesBase64"] as? String,
                          encoded.utf8.count <= 6_990_508,
                          let bytes = Data(base64Encoded: encoded), bytes.count <= 5 * 1024 * 1024,
                          bytes.base64EncodedString() == encoded else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    changes.append(.init(path: path, bytes: bytes))
                }
            }
            return .projectPatch(id: projectId, expectedSourceVersion: source, changes: changes)
        case .projectOpenContained:
            try keys(["schemaVersion", "path"])
            return .projectOpenContained(path: try path())
        case .projectSourceExport:
            try keys(["schemaVersion", "projectId", "sourceVersion", "path"])
            guard let source = params["sourceVersion"] as? String,
                  WorkspaceValidation.sha256(source) else { throw WorkbenchIPCError(.invalidRequest) }
            return .projectSourceExport(id: try id("projectId"), sourceVersion: source, path: try path())
        case .projectSourceImport:
            let fields = Set(params.keys)
            guard fields == ["schemaVersion", "path"] ||
                  fields == ["schemaVersion", "path", "name"] else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let name = params["name"] as? String
            guard params["name"] == nil ||
                  (name.map { WorkspaceValidation.text($0) && !$0.isEmpty && $0.utf8.count <= 120 } == true) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .projectSourceImport(path: try path(), name: name)
        case .projectOpenExternal:
            try keys(["schemaVersion", "path", "explicitExternal"])
            guard let explicit = params["explicitExternal"] as? NSNumber,
                  CFGetTypeID(explicit) == CFBooleanGetTypeID(), explicit.boolValue else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .projectOpenExternal(path: try path())
        case .projectAdoptExternal:
            try keys(["schemaVersion", "projectId", "expectedSourceVersion", "name"])
            guard let source = params["expectedSourceVersion"] as? String,
                  WorkspaceValidation.sha256(source),
                  let name = params["name"] as? String,
                  WorkspaceValidation.text(name), !name.isEmpty, name.utf8.count <= 120 else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .projectAdoptExternal(id: try id("projectId"),
                expectedSourceVersion: source, name: name)
        case .projectRelocateExternal:
            try keys(["schemaVersion", "projectId", "expectedSourceVersion", "path", "explicitExternal"])
            guard let source = params["expectedSourceVersion"] as? String,
                  WorkspaceValidation.sha256(source),
                  let explicit = params["explicitExternal"] as? NSNumber,
                  CFGetTypeID(explicit) == CFBooleanGetTypeID(), explicit.boolValue else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .projectRelocateExternal(id: try id("projectId"),
                expectedSourceVersion: source, path: try path())
        case .buildRun:
            let fields = Set(params.keys)
            guard fields == ["schemaVersion", "projectId", "expectedSourceVersion"] ||
                  fields == ["schemaVersion", "projectId", "expectedSourceVersion", "baseRevision"] else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let projectId = try id("projectId")
            guard let source = params["expectedSourceVersion"] as? String,
                  WorkspaceValidation.sha256(source),
                  params["baseRevision"] == nil ||
                    ((params["baseRevision"] as? String).map(WorkspaceValidation.id) == true) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .buildRun(id: projectId, expectedSourceVersion: source,
                             baseRevision: params["baseRevision"] as? String)
        case .packageHistory:
            let fields = Set(params.keys)
            guard fields == ["schemaVersion"] || fields == ["schemaVersion", "cursor"] else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let cursor = params["cursor"] as? String
            guard params["cursor"] == nil ||
                    (cursor != nil && (try? WorkbenchWorkspacePackageCursor.parse(cursor!)) != nil) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .packageHistory(cursor: cursor)
        case .packageExport:
            try keys(["schemaVersion", "dashboardId", "revision", "path"])
            return .packageExport(dashboardId: try id("dashboardId"),
                revision: try id("revision"), path: try path())
        case .snapshotCreate:
            let fields = Set(params.keys)
            guard fields == ["schemaVersion", "path"] ||
                  fields == ["schemaVersion", "path", "includeExternal", "allowIncomplete"] else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let includeExternal: Bool, allowIncomplete: Bool
            if fields.contains("includeExternal") {
                guard let include = params["includeExternal"] as? NSNumber,
                      let allow = params["allowIncomplete"] as? NSNumber,
                      CFGetTypeID(include) == CFBooleanGetTypeID(),
                      CFGetTypeID(allow) == CFBooleanGetTypeID() else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                includeExternal = include.boolValue; allowIncomplete = allow.boolValue
            } else { includeExternal = false; allowIncomplete = false }
            return .snapshotCreate(path: try path(), includeExternal: includeExternal,
                allowIncomplete: allowIncomplete)
        case .workspaceRelocate:
            try keys(["schemaVersion", "path"])
            return .workspaceRelocate(path: try path())
        case .workspaceConfigGet, .workspaceConfigPath:
            try keys(["schemaVersion"])
            return method == .workspaceConfigGet ? .workspaceConfigGet : .workspaceConfigPath
        case .workspaceConfigSet, .workspaceConfigUnset:
            let expectedKeys: Set<String> = method == .workspaceConfigSet
                ? ["schemaVersion", "key", "value", "expectedGeneration"]
                : ["schemaVersion", "key", "expectedGeneration"]
            try keys(expectedKeys)
            guard let key = params["key"] as? String,
                  ["theme", "view", "sort", "defaultCollection"].contains(key),
                  let number = params["expectedGeneration"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue),
                  number.intValue >= 0,
                  number.intValue < WorkspaceValidation.maxUInt else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            if method == .workspaceConfigSet {
                guard let value = params["value"] as? String,
                      WorkspaceValidation.text(value) else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                return .workspaceConfigSet(key: key, value: value,
                    expectedGeneration: number.intValue)
            }
            return .workspaceConfigUnset(key: key, expectedGeneration: number.intValue)
        case .migrationPlan:
            guard Set(params.keys) == ["schemaVersion", "path"] ||
                  Set(params.keys) == ["schemaVersion", "path", "destination"] else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let destination = params["destination"] as? String
            guard params["destination"] == nil ||
                    (destination.map(WorkspaceValidation.absolute) == true) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .migrationPlan(path: try path(), destination: destination)
        case .migrationApply:
            try keys(["schemaVersion", "migrationId"])
            return .migrationApply(id: try id("migrationId"))
        case .migrationReview:
            try keys(["schemaVersion", "migrationId"])
            return .migrationReview(id: try id("migrationId"))
        }
    }
}

public struct WorkbenchBuildRead: Codable, Sendable, Equatable {
    public let projectId: String
    public let dashboardId: String
    public let sourceVersion: String
    public let revision: String
    public let digest: String
    public let diagnostics: String
}

public struct WorkbenchPackageHistoryRead: Codable, Sendable, Equatable {
    public let dashboardId: String
    public let revision: String
    public let digest: String
    public let name: String
    public let fileCount: Int
    public let provenance: String
}

public struct WorkbenchProjectUnregisterRead: Codable, Sendable, Equatable {
    public let projectId: String
    public let workspaceId: String
    public let generation: Int
    public let selectionGeneration: Int
    public let sourceRetained: Bool
    public let historyRetained: Bool

    init(projectId: String, overview: WorkspaceOverview) throws {
        guard let selection = overview.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        self.projectId = projectId
        workspaceId = overview.descriptor.workspaceId
        generation = overview.catalog.generation
        selectionGeneration = selection
        sourceRetained = true; historyRetained = true
    }
}

public struct WorkbenchSnapshotRead: Codable, Sendable, Equatable {
    public let path: String
    public let workspaceId: String
    public let generation: Int
    public let fileCount: Int
    public let includedBytes: Int64
    public let complete: Bool
    public let scope: String
    public let excludedExternalProjectIds: [String]
    public let unregisteredScreenPaths: [String]
    public let omittedAuxiliaryPaths: [String]
}

public struct WorkbenchSourceLocationRead: Codable, Sendable, Equatable {
    public let project: WorkspaceProject
    public let path: String
    public let sourceVersion: String
    public let backupCoverage: String
    public init(project: WorkspaceProject, path: String, sourceVersion: String,
                backupCoverage: String) {
        self.project = project; self.path = path; self.sourceVersion = sourceVersion
        self.backupCoverage = backupCoverage
    }
}

public struct WorkbenchMigrationPlanRead: Codable, Sendable, Equatable {
    public let migrationId: String
    public let sourcePath: String
    public let destinationPath: String?
    public let projectIds: [String]
    public let packageRevisions: [String]
    public let portableBytes: Int
    public let expandedBytes: Int
    public let plannedMembers: Int
    public let unsupportedPortablePaths: [String]
    public let excludedClasses: [String]
    public let applyAvailable: Bool
}

public struct WorkbenchAuthoringRecoveryResult: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case authoringProject, sourceArchive, sourceLocation, workspaceConfiguration,
             buildHead, packageHistory, workspaceSnapshot, workspaceRelocation,
             migrationPlan, migrationApplied, packageExport, projectUnregistered
    }
    public let schemaVersion: Int
    public let kind: Kind
    public let project: WorkbenchSourceProject?
    public let sourceArchive: WorkbenchPortableSourceArchiveReceipt?
    public let sourceLocation: WorkbenchSourceLocationRead?
    public let configuration: WorkbenchWorkspaceConfigurationRead?
    public let build: WorkbenchBuildRead?
    public let packages: [WorkbenchPackageHistoryRead]?
    public let hasMore: Bool?
    public let nextCursor: String?
    public let ordering: String?
    public let snapshot: WorkbenchSnapshotRead?
    public let relocation: WorkspaceRelocationResult?
    public let migrationPlan: WorkbenchMigrationPlanRead?
    public let migrationApplied: WorkbenchWorkspaceStatus?
    public let packageExport: WorkbenchPortablePackageExportReceipt?
    public let projectUnregistered: WorkbenchProjectUnregisterRead?

    init(kind: Kind, project: WorkbenchSourceProject? = nil,
         sourceArchive: WorkbenchPortableSourceArchiveReceipt? = nil,
         sourceLocation: WorkbenchSourceLocationRead? = nil,
         configuration: WorkbenchWorkspaceConfigurationRead? = nil,
         build: WorkbenchBuildRead? = nil,
         packages: [WorkbenchPackageHistoryRead]? = nil, hasMore: Bool? = nil,
         nextCursor: String? = nil, snapshot: WorkbenchSnapshotRead? = nil,
         relocation: WorkspaceRelocationResult? = nil,
         migrationPlan: WorkbenchMigrationPlanRead? = nil,
         migrationApplied: WorkbenchWorkspaceStatus? = nil,
         packageExport: WorkbenchPortablePackageExportReceipt? = nil,
         projectUnregistered: WorkbenchProjectUnregisterRead? = nil) {
        schemaVersion = 1; self.kind = kind; self.project = project
        self.sourceArchive = sourceArchive; self.sourceLocation = sourceLocation; self.build = build
        self.configuration = configuration
        self.packages = packages; self.hasMore = hasMore; self.nextCursor = nextCursor
        ordering = packages == nil ? nil : "history-object-id-ascending"
        self.snapshot = snapshot; self.relocation = relocation; self.migrationPlan = migrationPlan
        self.migrationApplied = migrationApplied
        self.packageExport = packageExport
        self.projectUnregistered = projectUnregistered
    }
    public func validate(for method: WorkbenchAuthoringRecoveryMethod) throws {
        guard schemaVersion == 1 else { throw WorkbenchIPCError(.invalidRequest) }
        let expected: Kind
        switch method {
        case .projectCreate, .projectClone, .projectRelocateContained, .projectUpgradeKit,
             .projectInspect, .projectPatch, .projectOpenContained,
             .projectSourceImport: expected = .authoringProject
        case .projectUnregister: expected = .projectUnregistered
        case .projectSourceExport: expected = .sourceArchive
        case .projectOpenExternal, .projectAdoptExternal,
             .projectRelocateExternal: expected = .sourceLocation
        case .workspaceConfigGet, .workspaceConfigPath,
             .workspaceConfigSet, .workspaceConfigUnset: expected = .workspaceConfiguration
        case .buildRun, .buildHead: expected = .buildHead
        case .packageHistory: expected = .packageHistory
        case .packageExport: expected = .packageExport
        case .snapshotCreate: expected = .workspaceSnapshot
        case .workspaceRelocate: expected = .workspaceRelocation
        case .migrationPlan, .migrationReview: expected = .migrationPlan
        case .migrationApply: expected = .migrationApplied
        }
        let present = [project != nil, sourceArchive != nil, sourceLocation != nil,
                       configuration != nil, build != nil, packages != nil, snapshot != nil,
                       relocation != nil, migrationPlan != nil, migrationApplied != nil,
                       packageExport != nil, projectUnregistered != nil]
        let selected: Int
        switch expected {
        case .authoringProject: selected = 0
        case .sourceArchive: selected = 1
        case .sourceLocation: selected = 2
        case .workspaceConfiguration: selected = 3
        case .buildHead: selected = 4
        case .packageHistory: selected = 5
        case .workspaceSnapshot: selected = 6
        case .workspaceRelocation: selected = 7
        case .migrationPlan: selected = 8
        case .migrationApplied: selected = 9
        case .packageExport: selected = 10
        case .projectUnregistered: selected = 11
        }
        guard kind == expected, present[selected], present.filter({ $0 }).count == 1 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if expected == .sourceArchive {
            guard let archive = sourceArchive,
                  WorkspaceValidation.absolute(archive.archivePath),
                  WorkspaceValidation.sha256(archive.sourceVersion),
                  WorkspaceValidation.id(archive.projectId),
                  WorkspaceValidation.id(archive.dashboardId),
                  (1...2_000).contains(archive.fileCount),
                  (0...25 * 1024 * 1024).contains(archive.includedBytes) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
        if expected == .packageExport {
            guard let receipt = packageExport,
                  WorkspaceValidation.absolute(receipt.path),
                  WorkspaceValidation.id(receipt.dashboardId),
                  WorkspaceValidation.id(receipt.revision),
                  WorkspaceValidation.sha256(receipt.digest),
                  (1...2_000).contains(receipt.fileCount),
                  (0...50 * 1024 * 1024).contains(receipt.includedBytes) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
        if expected == .projectUnregistered {
            guard let value = projectUnregistered,
                  WorkspaceValidation.id(value.projectId),
                  WorkspaceValidation.id(value.workspaceId),
                  value.generation >= 0, value.generation < WorkspaceValidation.maxUInt,
                  value.selectionGeneration > 0,
                  value.sourceRetained, value.historyRetained else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
        if expected == .sourceLocation {
            guard let location = sourceLocation,
                  (try? location.project.validate()) != nil,
                  WorkspaceValidation.absolute(location.path),
                  WorkspaceValidation.sha256(location.sourceVersion),
                  ((method == .projectOpenExternal || method == .projectRelocateExternal) &&
                    location.project.location.kind == "external" &&
                    location.backupCoverage == "outside-workspace-backup-coverage") ||
                  (method == .projectAdoptExternal &&
                    location.project.location.kind == "workspace" &&
                    location.backupCoverage == "included-in-workspace-backup") else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
        if expected == .workspaceConfiguration {
            guard let configuration,
                  WorkspaceValidation.absolute(configuration.path),
                  WorkspaceValidation.id(configuration.workspaceId),
                  configuration.generation >= 0,
                  configuration.generation <= WorkspaceValidation.maxUInt,
                  configuration.presentation.count <= 4,
                  configuration.profiles.count <= 64,
                  configuration.presentation.allSatisfy({
                    ["theme", "view", "sort", "defaultCollection"].contains($0.key) &&
                    WorkspaceValidation.text($0.value)
                  }) else { throw WorkbenchIPCError(.invalidRequest) }
        }
        if expected == .workspaceRelocation {
            guard let relocation,
                  WorkspaceValidation.absolute(relocation.path),
                  WorkspaceValidation.absolute(relocation.originalPath),
                  relocation.path != relocation.originalPath,
                  WorkspaceValidation.id(relocation.workspaceId),
                  relocation.generation >= 0,
                  relocation.generation <= WorkspaceValidation.maxUInt,
                  (1...1_000_000).contains(relocation.fileCount),
                  (0...64 * 1024 * 1024 * 1024).contains(relocation.copiedBytes),
                  relocation.unresolvedExternalProjectIds.count <= 10_000,
                  relocation.unresolvedExternalProjectIds.allSatisfy(WorkspaceValidation.id) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
        if expected == .migrationApplied {
            guard let migrated = migrationApplied, migrated.state == "selected",
                  migrated.workspaceId != nil, migrated.path != nil else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
        if expected == .packageHistory {
            guard let packages, packages.count <= 128, let hasMore,
                  ordering == "history-object-id-ascending",
                  hasMore == (nextCursor != nil),
                  (nextCursor == nil || (try? WorkbenchWorkspacePackageCursor.parse(nextCursor!)) != nil) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        } else if hasMore != nil || nextCursor != nil || ordering != nil {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}
#endif
