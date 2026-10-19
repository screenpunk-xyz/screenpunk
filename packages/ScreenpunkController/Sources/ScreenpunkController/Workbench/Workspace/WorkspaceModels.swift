import Foundation

public enum WorkspaceError: Error, Equatable {
    case invalidPath, unsafeFile, invalidSchema, newerSchema, conflict, alreadyExists, unavailable, limitExceeded, incomplete
}

/// A publication returned successfully, but the follow-up read needed to
/// construct its response did not. Callers must inspect current state before
/// attempting the mutation again.
public struct WorkspaceAppliedMutationReadUnavailable: Error, Equatable, Sendable {
    public let operation: String
    public let workspaceId: String
    public let projectId: String?
    public init(operation: String, workspaceId: String, projectId: String? = nil) {
        self.operation = operation; self.workspaceId = workspaceId; self.projectId = projectId
    }
}

public struct WorkspaceDescriptor: Codable, Equatable, Sendable {
    public struct Paths: Codable, Equatable, Sendable { public let screens: String; public let workbench: String }
    public struct Defaults: Codable, Equatable, Sendable { public let projectKind: String; public let template: String }
    public struct Recovery: Codable, Equatable, Sendable { public let scope: String; public let externalProjectPolicy: String }
    public let schemaVersion: Int
    public let workspaceId: String
    public let name: String
    public let generation: Int
    public let paths: Paths
    public let defaults: Defaults
    public let recovery: Recovery
    init(name: String) {
        schemaVersion = 1; workspaceId = UUID().uuidString.lowercased(); self.name = name; generation = 1
        paths = Paths(screens: "Screens", workbench: "Workbench")
        defaults = Defaults(projectKind: "react", template: "blank")
        recovery = Recovery(scope: "authoring", externalProjectPolicy: "explicit")
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw schemaVersion > 1 ? WorkspaceError.newerSchema : WorkspaceError.invalidSchema }
        guard WorkspaceValidation.id(workspaceId), WorkspaceValidation.text(name), generation >= 0,
              generation <= WorkspaceValidation.maxUInt, paths.screens == "Screens", paths.workbench == "Workbench",
              ["react", "web"].contains(defaults.projectKind), ["blank", "earthquakes", "gallery"].contains(defaults.template),
              recovery.scope == "authoring", recovery.externalProjectPolicy == "explicit"
        else { throw WorkspaceError.invalidSchema }
    }
}

public struct WorkspaceProjectLocation: Codable, Equatable, Sendable {
    public let kind: String
    public let path: String?
    public let referenceId: String?
    public static func contained(_ path: String) -> Self { .init(kind: "workspace", path: path, referenceId: nil) }
    public static func external(_ referenceId: String) -> Self { .init(kind: "external", path: nil, referenceId: referenceId) }
    func validate() throws {
        if kind == "workspace" {
            guard referenceId == nil, let path, WorkspaceValidation.member(path), path.hasPrefix("Screens/"), path.split(separator: "/").count == 2 else { throw WorkspaceError.invalidSchema }
        } else if kind == "external" {
            guard path == nil, let referenceId, WorkspaceValidation.id(referenceId) else { throw WorkspaceError.invalidSchema }
        } else { throw WorkspaceError.invalidSchema }
    }
}

public struct WorkspaceProject: Codable, Equatable, Sendable {
    public let projectId: String
    public let dashboardId: String
    public let name: String
    public let location: WorkspaceProjectLocation
    public let collectionIds: [String]
    public let sortOrder: Int
    public init(projectId: String, dashboardId: String, name: String, location: WorkspaceProjectLocation,
                collectionIds: [String] = [], sortOrder: Int = 0) {
        self.projectId = projectId; self.dashboardId = dashboardId; self.name = name; self.location = location
        self.collectionIds = collectionIds; self.sortOrder = sortOrder
    }
    func validate() throws {
        try location.validate()
        guard WorkspaceValidation.id(projectId), WorkspaceValidation.id(dashboardId), WorkspaceValidation.text(name),
              collectionIds.count <= 256, collectionIds.allSatisfy(WorkspaceValidation.id), Set(collectionIds).count == collectionIds.count,
              sortOrder >= 0, sortOrder <= WorkspaceValidation.maxUInt else { throw WorkspaceError.invalidSchema }
    }
}

public struct WorkspaceCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generation: Int
    public let projects: [WorkspaceProject]
    public let archivedDashboardIds: [String]
    init(generation: Int = 1, projects: [WorkspaceProject] = [],
         archivedDashboardIds: [String] = []) {
        schemaVersion = 2; self.generation = generation; self.projects = projects
        self.archivedDashboardIds = archivedDashboardIds
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generation, projects, archivedDashboardIds
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generation = try container.decode(Int.self, forKey: .generation)
        projects = try container.decode([WorkspaceProject].self, forKey: .projects)
        archivedDashboardIds = try container.decodeIfPresent([String].self,
            forKey: .archivedDashboardIds) ?? []
    }
    func validate() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else {
            throw schemaVersion > 2 ? WorkspaceError.newerSchema : WorkspaceError.invalidSchema
        }
        guard generation >= 0, generation <= WorkspaceValidation.maxUInt, projects.count <= 100_000 else { throw WorkspaceError.limitExceeded }
        guard (schemaVersion == 2 || archivedDashboardIds.isEmpty),
              archivedDashboardIds.count <= 100_000,
              archivedDashboardIds == archivedDashboardIds.sorted(),
              Set(archivedDashboardIds).count == archivedDashboardIds.count,
              archivedDashboardIds.allSatisfy(WorkspaceValidation.id) else {
            throw WorkspaceError.invalidSchema
        }
        var ids = Set<String>(), dashboards = Set<String>(), locations = Set<String>(), references = Set<String>()
        for project in projects {
            try project.validate()
            guard ids.insert(project.projectId).inserted, dashboards.insert(project.dashboardId).inserted else { throw WorkspaceError.invalidSchema }
            if let path = project.location.path {
                guard locations.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw WorkspaceError.conflict }
            }
            if let reference = project.location.referenceId {
                guard references.insert(reference).inserted else { throw WorkspaceError.conflict }
            }
        }
    }
}

/// This initial portable settings contract admits presentation only; no operational authority.
public struct WorkspaceSettings: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generation: Int
    public let presentation: [String: String]
    public let profiles: [String: [String: String]]
    public let screenIcons: [String: String]
    init(generation: Int = 1, presentation: [String: String] = [:],
         profiles: [String: [String: String]] = [:], screenIcons: [String: String] = [:]) {
        schemaVersion = 2; self.generation = generation; self.presentation = presentation
        self.profiles = profiles; self.screenIcons = screenIcons
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generation, presentation, profiles, screenIcons
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generation = try container.decode(Int.self, forKey: .generation)
        presentation = try container.decode([String: String].self, forKey: .presentation)
        profiles = try container.decode([String: [String: String]].self, forKey: .profiles)
        screenIcons = try container.decodeIfPresent([String: String].self,
            forKey: .screenIcons) ?? [:]
    }
    func validate() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else {
            throw schemaVersion > 2 ? WorkspaceError.newerSchema : WorkspaceError.invalidSchema
        }
        guard generation >= 0, generation <= WorkspaceValidation.maxUInt, profiles.count <= 64,
              Self.valid(presentation),
              profiles.allSatisfy({ WorkspaceValidation.id($0.key) && Self.valid($0.value) }),
              (schemaVersion == 2 || screenIcons.isEmpty), screenIcons.count <= 2_000,
              screenIcons.allSatisfy({ WorkspaceValidation.id($0.key) && Self.validSymbol($0.value) })
        else { throw WorkspaceError.invalidSchema }
    }
    static func validSymbol(_ value: String) -> Bool {
        guard (1...120).contains(value.utf8.count) else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
            }
        }
    }
    private static func valid(_ preferences: [String: String]) -> Bool {
        let keys: Set<String> = ["theme", "view", "sort", "defaultCollection"]
        return preferences.count <= 4 && preferences.allSatisfy { key, value in
            guard keys.contains(key), WorkspaceValidation.text(value) else { return false }
            switch key {
            case "theme": return ["system", "light", "dark"].contains(value)
            case "view": return ["grid", "list"].contains(value)
            case "sort": return ["name", "recent", "manual"].contains(value)
            case "defaultCollection": return WorkspaceValidation.id(value)
            default: return false
            }
        }
    }
}

public struct WorkspaceToolchainRequirements: Codable, Equatable, Sendable {
    public struct Requirement: Codable, Equatable, Sendable {
        public let catalogEntryId: String
        public let kitVersion: String
        public let platform: String
        public let inventoryHash: String
    }
    public let schemaVersion: Int
    public let required: [Requirement]
    init() { schemaVersion = 1; required = [] }
    init(required: [Requirement]) { schemaVersion = 1; self.required = required }
    func validate() throws {
        guard schemaVersion == 1 else { throw schemaVersion > 1 ? WorkspaceError.newerSchema : WorkspaceError.invalidSchema }
        guard required.count <= 128, required.allSatisfy({ WorkspaceValidation.id($0.catalogEntryId) && WorkspaceValidation.id($0.kitVersion) && $0.platform == "darwin-arm64" && WorkspaceValidation.sha256($0.inventoryHash) }),
              Set(required.map(\.catalogEntryId)).count == required.count else { throw WorkspaceError.invalidSchema }
    }
}

public struct WorkspaceCoverage: Equatable, Sendable {
    public let scope = "authoring"
    public let complete: Bool
    public let containedProjectIds: [String]
    public let externalProjectIds: [String]
    public let unresolvedExternalProjectIds: [String]
    public let missingPaths: [String]
    public let omittedAuxiliaryPaths: [String]
    public let includedBytes: Int64
    public let notice: String
    init(contained: [String], external: [String], unresolved: [String], missing: [String],
         omitted: [String] = [], includedBytes: Int64 = 0) {
        containedProjectIds = contained.sorted(); externalProjectIds = external.sorted(); unresolvedExternalProjectIds = unresolved.sorted(); missingPaths = missing.sorted()
        omittedAuxiliaryPaths = omitted.sorted(); self.includedBytes = includedBytes
        complete = external.isEmpty && missing.isEmpty
        notice = external.isEmpty ? "Contained workspace authoring coverage only." : "Outside workspace backup coverage: external current source is not included."
    }
}

public enum WorkspaceValidation {
    public static let maxUInt = 9_007_199_254_740_991
    static func portableKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
    }
    public static func id(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...100).contains(bytes.count) && bytes.enumerated().allSatisfy { offset, byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || (offset > 0 && [46, 95, 45].contains(byte))
        }
    }
    public static func text(_ value: String) -> Bool { value.unicodeScalars.count <= 4096 && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) }
    public static func sha256(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    public static func member(_ value: String) -> Bool {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && value.utf8.count <= 4096 && pieces.count <= 32 && pieces.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) } && !(pieces.first?.contains(":") ?? false)
    }
    public static func absolute(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.utf8.contains(0) && path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct WorkspaceConnections: Codable, Equatable, Sendable {
    public struct LogicalService: Codable, Equatable, Sendable {
        public let serviceId: String
        public let kind: String
        public let label: String
    }
    public let schemaVersion: Int
    public let connections: [LogicalService]
    init() { schemaVersion = 1; connections = [] }
    func validate() throws {
        guard schemaVersion == 1 else { throw schemaVersion > 1 ? WorkspaceError.newerSchema : WorkspaceError.invalidSchema }
        guard connections.count <= 1000, connections.allSatisfy({ WorkspaceValidation.id($0.serviceId) && WorkspaceValidation.id($0.kind) && WorkspaceValidation.text($0.label) }),
              Set(connections.map(\.serviceId)).count == connections.count else { throw WorkspaceError.invalidSchema }
    }
}

/// Proposed ordinary project descriptor from spec §4; distinct from deployment manifests.
public struct WorkspaceProjectDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let projectId: String
    public let dashboardId: String
    public let name: String
    public let kind: String
    public let kitVersion: String
    public let entry: String
    public let screenConfig: String
    func validate(matching project: WorkspaceProject) throws {
        guard schemaVersion == 1 else { throw schemaVersion > 1 ? WorkspaceError.newerSchema : WorkspaceError.invalidSchema }
        guard projectId == project.projectId, dashboardId == project.dashboardId,
              WorkspaceValidation.text(name), ["react", "web"].contains(kind), WorkspaceValidation.id(kitVersion),
              WorkspaceValidation.member(entry), WorkspaceValidation.member(screenConfig),
              entry != screenConfig, screenConfig == "screen.json",
              (kind == "react" ? [".tsx", ".ts", ".jsx", ".js"].contains(where: entry.hasSuffix) :
                   [".html", ".htm"].contains(where: entry.hasSuffix)) else { throw WorkspaceError.invalidSchema }
    }
}
