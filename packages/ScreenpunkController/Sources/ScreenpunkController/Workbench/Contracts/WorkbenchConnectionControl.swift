import Foundation
import CoreFoundation
import ScreenpunkCore
#if os(macOS)

public enum WorkbenchSecretReference {
    /// A fresh credential slot per intent prevents a failed request from
    /// replacing a working grant's exact Keychain item.
    public static func make(ownerPin: String, deviceId: String, credentialId: UUID) -> String {
        func shortHash(_ text: String) -> String {
            String(DeploymentDigest.sha256Hex(Data(text.utf8)).prefix(32))
        }
        return "w1:\(shortHash(ownerPin)):\(shortHash(deviceId)):\(credentialId.uuidString.lowercased())"
    }
}

public struct WorkbenchConnectionActionResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: String
    public let intent: WorkbenchConnectionIntentView?
    public let summary: WorkbenchConnectionSummary?
    public let summaries: [WorkbenchConnectionSummary]?
    public let scopeDraft: WorkbenchConnectionScopeDraft?
    public let applied: WorkbenchConnectionApplyResult?
    public let denied: Bool?
    init(kind: String, intent: WorkbenchConnectionIntentView? = nil,
         summary: WorkbenchConnectionSummary? = nil, summaries: [WorkbenchConnectionSummary]? = nil,
         scopeDraft: WorkbenchConnectionScopeDraft? = nil,
         applied: WorkbenchConnectionApplyResult? = nil, denied: Bool? = nil) {
        schemaVersion = 1; self.kind = kind; self.intent = intent; self.summary = summary
        self.summaries = summaries; self.scopeDraft = scopeDraft; self.applied = applied; self.denied = denied
    }
    func validate(for method: WorkbenchConnectionControlMethod) throws {
        guard schemaVersion == 1, kind == method.resultKind,
              [intent != nil, summary != nil, summaries != nil, scopeDraft != nil,
               applied != nil, denied != nil].filter({ $0 }).count == 1 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if let scopeDraft { try scopeDraft.validate() }
    }
}

public enum WorkbenchConnectionControlMethod: String, CaseIterable, Sendable {
    case configure = "connection.configure"
    case update = "connection.update"
    case intentRequest = "connection.intentRequest"
    case intentInspect = "connection.intentInspect"
    case intentResolve = "connection.intentResolve"
    case list = "connection.list"
    case inspect = "connection.inspect"
    case scopeDraft = "connection.scopeDraft"
    case test = "connection.test"
    case remove = "connection.remove"
    case revoke = "connection.revoke"
    var resultKind: String {
        switch self {
        case .configure, .update, .intentRequest, .intentInspect: return "intent"
        case .intentResolve: return "resolution"
        case .list: return "summaries"
        case .scopeDraft: return "scope_draft"
        case .inspect, .test, .remove, .revoke: return "summary"
        }
    }
}

enum WorkbenchConnectionControlRequest {
    case configure(String, String, String, ConnectionGrant, ConnectionAuthBinding, Data?)
    case update(String, Int, ConnectionGrant, ConnectionAuthBinding)
    case intentRequest(String, String, String, ConnectionGrant, ConnectionAuthBinding)
    case intentInspect(String), intentResolve(String, Bool)
    case list(String), inspect(String), test(String), remove(String), revoke(String)
    case scopeDraft(String, String, Int)
    var method: WorkbenchConnectionControlMethod {
        switch self {
        case .configure: return .configure
        case .update: return .update
        case .intentRequest: return .intentRequest
        case .intentInspect: return .intentInspect
        case .intentResolve: return .intentResolve
        case .list: return .list
        case .inspect: return .inspect
        case .scopeDraft: return .scopeDraft
        case .test: return .test
        case .remove: return .remove
        case .revoke: return .revoke
        }
    }
    static func parse(method: WorkbenchConnectionControlMethod, params: [String: Any]) throws -> Self {
        guard let version = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else { throw WorkbenchIPCError(.unsupportedVersion) }
        let keys = Set(params.keys)
        func exact(_ names: String...) throws {
            guard keys == Set(names).union(["schemaVersion"]) else { throw WorkbenchIPCError(.invalidRequest) }
        }
        func id(_ name: String) throws -> String {
            guard let value = params[name] as? String, WorkspaceValidation.id(value) else { throw WorkbenchIPCError(.invalidRequest) }
            return value
        }
        switch method {
        case .update:
            try exact("bindingId", "expectedGrantGeneration", "grant", "auth")
            let binding = try id("bindingId")
            guard let expected = params["expectedGrantGeneration"] as? NSNumber,
                  CFGetTypeID(expected) != CFBooleanGetTypeID(),
                  expected.doubleValue == Double(expected.intValue),
                  expected.intValue > 0,
                  expected.intValue < WorkspaceValidation.maxUInt else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            var declaration = params
            declaration.removeValue(forKey: "bindingId")
            declaration.removeValue(forKey: "expectedGrantGeneration")
            declaration["deviceId"] = binding
            declaration["dashboardId"] = binding
            declaration["revision"] = binding
            guard case let .configure(_, _, _, grant, auth, secret) =
                try parse(method: .configure, params: declaration),
                  secret == nil, grant.id.uuidString.lowercased() == binding else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .update(binding, expected.intValue, grant, auth)
        case .intentRequest:
            guard keys == ["schemaVersion", "deviceId", "dashboardId", "revision", "grant", "auth"],
                  case let .configure(deviceId, dashboardId, revision, grant, auth, secret) =
                    try parse(method: .configure, params: params),
                  secret == nil, auth.placement == .none else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .intentRequest(deviceId, dashboardId, revision, grant, auth)
        case .configure:
            guard keys == ["schemaVersion", "deviceId", "dashboardId", "revision", "grant", "auth"] ||
                  keys == ["schemaVersion", "deviceId", "dashboardId", "revision", "grant", "auth", "secretBase64"],
                  let grantObject = params["grant"] as? [String: Any],
                  let authObject = params["auth"] as? [String: Any],
                  Set(grantObject.keys) == ["schemaVersion", "id", "alias", "origin", "transport", "authRef", "lan", "allowInsecureHTTP", "operations"],
                  (Set(authObject.keys) == ["authRef", "placement"] || Set(authObject.keys) == ["authRef", "placement", "fieldName"]),
                  let grantData = try? JSONSerialization.data(withJSONObject: grantObject),
                  let authData = try? JSONSerialization.data(withJSONObject: authObject),
                  let grant = try? JSONDecoder().decode(ConnectionGrant.self, from: grantData),
                  let auth = try? JSONDecoder().decode(ConnectionAuthBinding.self, from: authData),
                  grant.authRef.isEmpty, auth.authRef.isEmpty,
                  try JSONValue.from(grantObject) == JSONValue.from(WorkbenchWireJSON.object(JSONEncoder().encode(grant))),
                  try JSONValue.from(authObject) == JSONValue.from(WorkbenchWireJSON.object(JSONEncoder().encode(auth))) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let secret: Data?
            if params["secretBase64"] != nil {
                guard let text = params["secretBase64"] as? String else { throw WorkbenchIPCError(.invalidRequest) }
                guard text.utf8.count <= 11_000, let data = Data(base64Encoded: text),
                      (1...8192).contains(data.count) else { throw WorkbenchIPCError(.invalidRequest) }
                secret = data
            } else { secret = nil }
            return .configure(try id("deviceId"), try id("dashboardId"), try id("revision"), grant, auth, secret)
        case .intentInspect: try exact("intentId"); return .intentInspect(try id("intentId"))
        case .intentResolve:
            try exact("intentId", "approve")
            guard let approve = params["approve"] as? NSNumber,
                  CFGetTypeID(approve) == CFBooleanGetTypeID() else { throw WorkbenchIPCError(.invalidRequest) }
            return .intentResolve(try id("intentId"), approve.boolValue)
        case .list: try exact("deviceId"); return .list(try id("deviceId"))
        case .inspect: try exact("bindingId"); return .inspect(try id("bindingId"))
        case .scopeDraft:
            try exact("bindingId", "workspaceId", "selectionGeneration")
            guard let generation = params["selectionGeneration"] as? NSNumber,
                  CFGetTypeID(generation) != CFBooleanGetTypeID(),
                  generation.doubleValue == Double(generation.intValue),
                  generation.intValue > 0,
                  generation.intValue < WorkspaceValidation.maxUInt else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .scopeDraft(try id("bindingId"), try id("workspaceId"), generation.intValue)
        case .test: try exact("bindingId"); return .test(try id("bindingId"))
        case .remove: try exact("bindingId"); return .remove(try id("bindingId"))
        case .revoke: try exact("bindingId"); return .revoke(try id("bindingId"))
        }
    }
}
#endif
