import Foundation
import CoreFoundation
import ScreenpunkCore
#if os(macOS)

public enum WorkbenchDeploymentMethod: String, CaseIterable, Sendable {
    case prepare = "deployment.prepare"
    case plan = "deployment.plan"
    case rollbackPlan = "deployment.rollbackPlan"
    case review = "deployment.review"
    case apply = "deployment.apply"
    case status = "deployment.status"
    case lookup = "deployment.lookup"
    case reconcile = "deployment.reconcile"
    case cancel = "deployment.cancel"
}

enum WorkbenchDeploymentRequest {
    case prepare(String, Int, String, String, String, DeviceOrientation)
    case plan(String, Int, String, [WorkbenchPreparedSelection], String, [String], [String], Int64, Bool)
    case review(String, Int, String)
    case apply(String, Int, String, String, String, String, Bool)
    case status(String, Int, String)
    case lookup(String, Int, String)
    case reconcile(String, Int, String)
    case cancel(String, Int, String, String)

    var selection: (workspaceId: String, generation: Int) {
        switch self {
        case .prepare(let id, let generation, _, _, _, _),
             .plan(let id, let generation, _, _, _, _, _, _, _),
             .review(let id, let generation, _), .apply(let id, let generation, _, _, _, _, _),
             .status(let id, let generation, _), .lookup(let id, let generation, _),
             .reconcile(let id, let generation, _),
             .cancel(let id, let generation, _, _): return (id, generation)
        }
    }
    var method: WorkbenchDeploymentMethod {
        switch self {
        case .prepare: return .prepare
        case .plan(_, _, _, _, _, _, _, _, let rollback): return rollback ? .rollbackPlan : .plan
        case .review: return .review
        case .apply: return .apply
        case .status: return .status
        case .lookup: return .lookup
        case .reconcile: return .reconcile
        case .cancel: return .cancel
        }
    }

    static func parse(_ method: WorkbenchDeploymentMethod, _ params: [String: Any]) throws -> Self {
        let common: Set<String> = ["schemaVersion", "expectedWorkspaceId", "expectedSelectionGeneration"]
        guard let version = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let workspaceId = params["expectedWorkspaceId"] as? String,
              WorkspaceValidation.id(workspaceId),
              let rawGeneration = params["expectedSelectionGeneration"] as? NSNumber,
              CFGetTypeID(rawGeneration) != CFBooleanGetTypeID(),
              rawGeneration.doubleValue == Double(rawGeneration.intValue),
              (1...WorkspaceValidation.maxUInt).contains(rawGeneration.intValue) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        let generation = rawGeneration.intValue
        func keys(_ extra: Set<String>) throws {
            guard Set(params.keys) == common.union(extra) else { throw WorkbenchIPCError(.invalidRequest) }
        }
        func id(_ key: String) throws -> String {
            guard let value = params[key] as? String, WorkspaceValidation.id(value) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return value
        }
        func ids(_ key: String, maximum: Int) throws -> [String] {
            guard let values = params[key] as? [String], values.count <= maximum,
                  values.allSatisfy(WorkspaceValidation.id) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return values
        }
        switch method {
        case .prepare:
            try keys(["deviceId", "dashboardId", "sourceRevision", "orientation"])
            guard let raw = params["orientation"] as? String,
                  let orientation = DeviceOrientation(rawValue: raw) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .prepare(workspaceId, generation, try id("deviceId"),
                try id("dashboardId"), try id("sourceRevision"), orientation)
        case .plan, .rollbackPlan:
            try keys(["deviceId", "packages", "selectedDashboardId", "removedDashboardIds",
                      "bindingIds", "lifetimeSeconds"])
            guard let raw = params["packages"] as? [[String: Any]], (1...12).contains(raw.count),
                  let lifetime = params["lifetimeSeconds"] as? NSNumber,
                  CFGetTypeID(lifetime) != CFBooleanGetTypeID(),
                  lifetime.doubleValue == Double(lifetime.int64Value),
                  (1...86_400).contains(lifetime.int64Value) else { throw WorkbenchIPCError(.invalidRequest) }
            let selections = try raw.map { value -> WorkbenchPreparedSelection in
                guard Set(value.keys) == ["dashboardId", "sourceRevision", "revision", "dataDescription"],
                      let dashboardId = value["dashboardId"] as? String,
                      let sourceRevision = value["sourceRevision"] as? String,
                      let revision = value["revision"] as? String,
                      let description = value["dataDescription"] as? String,
                      WorkspaceValidation.id(dashboardId), WorkspaceValidation.id(sourceRevision),
                      WorkspaceValidation.id(revision), description.unicodeScalars.count <= 4_096 else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                return .init(dashboardId: dashboardId, sourceRevision: sourceRevision,
                    revision: revision, dataDescription: description)
            }
            return .plan(workspaceId, generation, try id("deviceId"), selections,
                try id("selectedDashboardId"), try ids("removedDashboardIds", maximum: 12),
                try ids("bindingIds", maximum: 32), lifetime.int64Value,
                method == .rollbackPlan)
        case .review:
            try keys(["planId"])
            return .review(workspaceId, generation, try id("planId"))
        case .apply:
            let required = common.union(["planId", "expectedPlanHash",
                "expectedAuthorizationContextHash", "idempotencyKey", "approved"])
            guard Set(params.keys) == required || Set(params.keys) == required.union(["approvalMode"]),
                  params["approvalMode"] == nil ||
                    ["interactive", "scripted"].contains(params["approvalMode"] as? String ?? "") else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            guard let hash = params["expectedPlanHash"] as? String,
                  WorkspaceValidation.sha256(hash),
                  let context = params["expectedAuthorizationContextHash"] as? String,
                  WorkspaceValidation.sha256(context),
                  let approved = params["approved"] as? NSNumber,
                  CFGetTypeID(approved) == CFBooleanGetTypeID() else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .apply(workspaceId, generation, try id("planId"), hash, context,
                try id("idempotencyKey"), approved.boolValue)
        case .status:
            try keys(["operationId"])
            return .status(workspaceId, generation, try id("operationId"))
        case .lookup:
            try keys(["planId"])
            return .lookup(workspaceId, generation, try id("planId"))
        case .reconcile:
            try keys(["operationId"])
            return .reconcile(workspaceId, generation, try id("operationId"))
        case .cancel:
            try keys(["planId", "deviceId"])
            return .cancel(workspaceId, generation, try id("planId"), try id("deviceId"))
        }
    }
}

public struct WorkbenchPreparedPackageSummary: Codable, Equatable, Sendable {
    public let dashboardId: String
    public let sourceRevision: String
    public let revision: String
    public let digest: String
    public let deviceId: String
    public let orientation: String
    init(_ prepared: WorkbenchPreparedPackage) throws {
        guard let digest = prepared.manifest.digest else { throw WorkbenchDeploymentError.invalidPlan }
        dashboardId = prepared.manifest.dashboardId; sourceRevision = prepared.sourceRevision
        revision = prepared.manifest.revision; self.digest = digest
        deviceId = prepared.manifest.target.profileId; orientation = prepared.manifest.target.orientation
    }
}

public struct WorkbenchDeploymentActionResult: Codable {
    public let schemaVersion: Int
    public let kind: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let prepared: WorkbenchPreparedPackageSummary?
    public let review: WorkbenchDeploymentReview?
    public let operation: WorkbenchDeploymentOperationRecord?
    public let cancelled: Bool?

    init(_ method: WorkbenchDeploymentMethod, workspaceId: String, generation: Int,
         prepared: WorkbenchPreparedPackageSummary? = nil,
         review: WorkbenchDeploymentReview? = nil,
         operation: WorkbenchDeploymentOperationRecord? = nil,
         cancelled: Bool? = nil) {
        schemaVersion = 1; kind = method.rawValue; self.workspaceId = workspaceId
        selectionGeneration = generation; self.prepared = prepared
        self.review = review; self.operation = operation; self.cancelled = cancelled
    }
    func validate(for request: WorkbenchDeploymentRequest) throws {
        guard schemaVersion == 1, kind == request.method.rawValue,
              workspaceId == request.selection.workspaceId,
              selectionGeneration == request.selection.generation,
              [prepared != nil, review != nil, operation != nil, cancelled != nil]
                .filter({ $0 }).count == 1 else { throw WorkbenchIPCError(.invalidRequest) }
        switch request {
        case .prepare: guard prepared != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .plan, .review: guard review != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .apply, .status, .lookup, .reconcile: guard operation != nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .cancel: guard cancelled != nil || operation != nil else { throw WorkbenchIPCError(.invalidRequest) }
        }
    }
}
#endif
