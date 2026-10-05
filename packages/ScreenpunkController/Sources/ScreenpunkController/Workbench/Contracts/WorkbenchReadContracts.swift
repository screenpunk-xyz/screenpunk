import Foundation
import CoreFoundation
import ScreenpunkCore

public struct WorkbenchWorkspaceStatus: Codable, Sendable, Equatable {
    public let state: String
    public let workspaceId: String?
    public let path: String?
    public let generation: Int?
    public let selectionGeneration: Int?
    public let coverageComplete: Bool?
    public let externalProjectCount: Int?
    public let historyAuthority: String
    public init(overview: WorkspaceOverview?) {
        state = overview == nil ? "unconfigured" : "selected"
        workspaceId = overview?.descriptor.workspaceId
        path = overview?.path
        generation = overview?.descriptor.generation
        selectionGeneration = overview?.selectionGeneration
        coverageComplete = overview?.coverage.complete
        externalProjectCount = overview?.coverage.externalProjectIds.count
        historyAuthority = "historical-only"
    }
}

public struct WorkbenchPackageSummary: Codable, Sendable, Equatable {
    public let dashboardId: String
    public let name: String
    public let currentRevision: String
    public let revisionCount: Int
    public let storage: String
    init(_ summary: DashboardSummary) {
        dashboardId = summary.dashboardId; name = summary.name
        currentRevision = summary.draftRevision; revisionCount = summary.revisionCount
        storage = "legacy-controller"
    }
}

public struct WorkbenchPackageRead: Codable, Sendable, Equatable {
    public let dashboardId: String
    public let revision: String
    public let name: String
    public let digest: String
    public let fileCount: Int
    public let bytes: Int
    public let integrity: String
    public let storage: String
}

public struct WorkbenchDeviceRead: Codable, Sendable, Equatable {
    public let deviceId: String
    public let name: String
    public let ownerMatchesCurrent: Bool
    public let reachability: String
    public let activeRevision: String?
    /// Cached observations only; these reads never probe or reconnect a device.
    public let cachedReachability: String?
    public let lastSeenAt: String?
    init(_ record: PairedDeviceRecord, currentIdentity: PairingIdentity?) {
        deviceId = record.id; name = record.displayName ?? record.device.profile.name
        ownerMatchesCurrent = currentIdentity.map { $0 == record.device.owner } ?? false
        reachability = "not-probed"
        activeRevision = record.device.activeRevision
        cachedReachability = record.device.reachable ? "reachable" : "unreachable"
        lastSeenAt = record.lastSeenAt.map { ISO8601DateFormatter().string(from: $0) }
    }
}

public struct WorkbenchCoverageRead: Codable, Sendable, Equatable {
    public let path: String
    public let complete: Bool
    public let containedProjectIds: [String]
    public let externalProjectIds: [String]
    public let unresolvedExternalProjectIds: [String]
    public let missingPaths: [String]
    public let omittedAuxiliaryPaths: [String]
    public let includedBytes: Int64
    public let notice: String
    public let valid: Bool?
    init(_ overview: WorkspaceOverview, validate: Bool) {
        path = overview.path; complete = overview.coverage.complete
        containedProjectIds = overview.coverage.containedProjectIds
        externalProjectIds = overview.coverage.externalProjectIds
        unresolvedExternalProjectIds = overview.coverage.unresolvedExternalProjectIds
        missingPaths = overview.coverage.missingPaths
        omittedAuxiliaryPaths = overview.coverage.omittedAuxiliaryPaths
        includedBytes = overview.coverage.includedBytes; notice = overview.coverage.notice
        valid = validate ? true : nil
    }
}

public struct WorkbenchReadResult: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case workspace, packages, package, devices, device, coverage, projects, project, projectPath, sourceVersions }
    public let schemaVersion: Int
    public let kind: Kind
    public let workspace: WorkbenchWorkspaceStatus?
    public let packages: [WorkbenchPackageSummary]?
    public let package: WorkbenchPackageRead?
    public let devices: [WorkbenchDeviceRead]?
    public let device: WorkbenchDeviceRead?
    public let coverage: WorkbenchCoverageRead?
    public let projects: [WorkspaceProject]?
    public let project: WorkspaceProject?
    public let projectPath: String?
    public let sourceVersions: [WorkbenchSourceHistoryEntry]?
    init(kind: Kind, workspace: WorkbenchWorkspaceStatus? = nil, packages: [WorkbenchPackageSummary]? = nil,
         package: WorkbenchPackageRead? = nil, devices: [WorkbenchDeviceRead]? = nil, device: WorkbenchDeviceRead? = nil,
         coverage: WorkbenchCoverageRead? = nil, projects: [WorkspaceProject]? = nil,
         project: WorkspaceProject? = nil, projectPath: String? = nil,
         sourceVersions: [WorkbenchSourceHistoryEntry]? = nil) {
        schemaVersion = 1; self.kind = kind; self.workspace = workspace; self.packages = packages
        self.package = package; self.devices = devices; self.device = device; self.coverage = coverage
        self.projects = projects; self.project = project; self.projectPath = projectPath; self.sourceVersions = sourceVersions
    }
    func validate(for method: WorkbenchReadMethod) throws {
        guard schemaVersion == 1 else { throw WorkbenchIPCError(.unsupportedVersion) }
        let present = [workspace != nil, packages != nil, package != nil, devices != nil, device != nil,
                       coverage != nil, projects != nil, project != nil, projectPath != nil, sourceVersions != nil]
        guard present.filter({ $0 }).count == 1 else { throw WorkbenchIPCError(.invalidRequest) }
        switch method {
        case .workspaceStatus: guard kind == .workspace, workspace != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .packageList: guard kind == .packages, packages != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .packageGet, .packageValidate: guard kind == .package, package != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .deviceList: guard kind == .devices, devices != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .deviceGet: guard kind == .device, device != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .workspaceCoverage, .workspaceValidate: guard kind == .coverage, coverage != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .projectList: guard kind == .projects, projects != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .projectGet: guard kind == .project, project != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .projectPath: guard kind == .projectPath, projectPath != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .projectVersions: guard kind == .sourceVersions, sourceVersions != nil else { throw WorkbenchIPCError(.invalidRequest) }
        }
    }
}

public enum WorkbenchReadMethod: String, Sendable, CaseIterable {
    case workspaceStatus = "workspace.status"
    case packageList = "package.list"
    case packageGet = "package.get"
    case packageValidate = "package.validate"
    case deviceList = "device.list"
    case deviceGet = "device.get"
    case workspaceCoverage = "workspace.coverage"
    case workspaceValidate = "workspace.validate"
    case projectList = "project.list"
    case projectGet = "project.get"
    case projectPath = "project.path"
    case projectVersions = "project.versions"
}

public enum WorkbenchMethodClass: String, Sendable { case read, workspaceMutation, deviceMutation, privilegedConfiguration, privilegedApproval }
public struct WorkbenchMethodDefinition: Sendable {
    public let name: String
    public let classification: WorkbenchMethodClass
    public let schemaVersion: Int
    public let mcpTool: String?
}

public enum WorkbenchDomainRequest: Sendable {
    case workspaceStatus, packageList, packageGet(String, String?), packageValidate(String, String?), deviceList, deviceGet(String)
    case workspaceCoverage, workspaceValidate, projectList, projectGet(String), projectPath(String), projectVersions(String)
    var method: WorkbenchReadMethod {
        switch self {
        case .workspaceStatus: return .workspaceStatus
        case .packageList: return .packageList
        case .packageGet: return .packageGet
        case .packageValidate: return .packageValidate
        case .deviceList: return .deviceList
        case .deviceGet: return .deviceGet
        case .workspaceCoverage: return .workspaceCoverage
        case .workspaceValidate: return .workspaceValidate
        case .projectList: return .projectList
        case .projectGet: return .projectGet
        case .projectPath: return .projectPath
        case .projectVersions: return .projectVersions
        }
    }
}

public enum WorkbenchDomainMethodRegistry {
    public static let definitions: [WorkbenchMethodDefinition] = [
        .init(name: "workspace.status", classification: .read, schemaVersion: 1, mcpTool: "get_workspace"),
        .init(name: "package.list", classification: .read, schemaVersion: 1, mcpTool: "list_dashboards"),
        .init(name: "package.get", classification: .read, schemaVersion: 1, mcpTool: "get_dashboard"),
        .init(name: "package.validate", classification: .read, schemaVersion: 1, mcpTool: "validate_dashboard"),
        .init(name: "device.list", classification: .read, schemaVersion: 1, mcpTool: "list_devices"),
        .init(name: "device.get", classification: .read, schemaVersion: 1, mcpTool: "get_device"),
        .init(name: "workspace.coverage", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "workspace.validate", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "project.list", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "project.get", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "project.path", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "project.versions", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: WorkbenchSourceTextRequest.method, classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: WorkbenchSourceChunkRequest.method, classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "workspace.open", classification: .workspaceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "workspace.init", classification: .workspaceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "package.prepare", classification: .workspaceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.discover", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.add", classification: .deviceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.pairBegin", classification: .deviceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.pairPending", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.pairConfirm", classification: .deviceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.pairCancel", classification: .deviceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.forget", classification: .deviceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.status", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.settingsGet", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.settingsSet", classification: .deviceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.connections", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "device.screenSet", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "deployment.apply", classification: .deviceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "connection.configure", classification: .privilegedConfiguration, schemaVersion: 1, mcpTool: nil),
        .init(name: "connection.intentRequest", classification: .workspaceMutation, schemaVersion: 1, mcpTool: nil),
        .init(name: "connection.intentInspect", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "connection.intentResolve", classification: .privilegedApproval, schemaVersion: 1, mcpTool: nil),
        .init(name: "connection.list", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "connection.inspect", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "connection.test", classification: .read, schemaVersion: 1, mcpTool: nil),
        .init(name: "connection.remove", classification: .privilegedConfiguration, schemaVersion: 1, mcpTool: nil)
    ]
    public static var availableReadMethods: [String] { WorkbenchReadMethod.allCases.map(\.rawValue) }
    public static let availableWorkspaceMethods = ["workspace.init", "workspace.open"]
    public static func parse(method: String, params: [String: Any], domainAvailable: Bool) throws -> WorkbenchDomainRequest {
        guard domainAvailable, let selected = WorkbenchReadMethod(rawValue: method) else { throw WorkbenchIPCError(.methodNotFound) }
        guard let version = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue.rounded(.towardZero) == version.doubleValue else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        guard version.intValue == 1 else { throw WorkbenchIPCError(.unsupportedVersion) }
        switch selected {
        case .workspaceStatus, .packageList, .deviceList, .workspaceCoverage, .workspaceValidate, .projectList:
            guard Set(params.keys) == ["schemaVersion"] else { throw WorkbenchIPCError(.invalidRequest) }
            switch selected {
            case .workspaceStatus: return .workspaceStatus
            case .packageList: return .packageList
            case .deviceList: return .deviceList
            case .workspaceCoverage: return .workspaceCoverage
            case .workspaceValidate: return .workspaceValidate
            case .projectList: return .projectList
            default: throw WorkbenchIPCError(.invalidRequest)
            }
        case .projectGet, .projectPath, .projectVersions:
            guard Set(params.keys) == ["schemaVersion", "projectId"],
                  let id = params["projectId"] as? String, WorkspaceValidation.id(id) else { throw WorkbenchIPCError(.invalidRequest) }
            switch selected {
            case .projectGet: return .projectGet(id)
            case .projectPath: return .projectPath(id)
            default: return .projectVersions(id)
            }
        case .packageGet, .packageValidate:
            let keys = Set(params.keys)
            guard keys == ["schemaVersion", "dashboardId"] || keys == ["schemaVersion", "dashboardId", "revision"],
                  let id = params["dashboardId"] as? String, WorkspaceValidation.id(id),
                  params["revision"] == nil || ((params["revision"] as? String).map(WorkspaceValidation.id) == true) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let revision = params["revision"] as? String
            return selected == .packageGet ? .packageGet(id, revision) : .packageValidate(id, revision)
        case .deviceGet:
            guard Set(params.keys) == ["schemaVersion", "deviceId"],
                  let id = params["deviceId"] as? String, WorkspaceValidation.id(id) else { throw WorkbenchIPCError(.invalidRequest) }
            return .deviceGet(id)
        }
    }
}

/// Shared pre-dispatch boundary for both future MCP stdio adapters. The tool
/// name is fixed by registration, never a caller-supplied broker method.
public enum WorkbenchMCPReadPolicy {
    public static func route(tool: String, arguments: [String: Any]) throws -> (method: String, params: [String: Any]) {
        let method: WorkbenchReadMethod
        var fields = arguments
        switch tool {
        case "get_workspace": method = .workspaceStatus
        case "list_dashboards": method = .packageList
        case "get_dashboard": method = .packageGet
        case "validate_dashboard": method = .packageValidate
        case "list_devices": method = .deviceList
        case "get_device":
            method = .deviceGet
            if let probe = fields.removeValue(forKey: "probe") {
                guard let value = probe as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), !value.boolValue else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
            }
        default: throw WorkbenchIPCError(.methodNotFound)
        }
        guard fields["schemaVersion"] == nil else { throw WorkbenchIPCError(.invalidRequest) }
        fields["schemaVersion"] = 1
        _ = try WorkbenchDomainMethodRegistry.parse(method: method.rawValue, params: fields, domainAvailable: true)
        return (method.rawValue, fields)
    }
}
