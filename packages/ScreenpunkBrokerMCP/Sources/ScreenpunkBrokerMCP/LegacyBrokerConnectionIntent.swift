import Foundation
import CoreFoundation
import ScreenpunkCore
import ScreenpunkController

extension LegacyBrokerAdapter {
    struct ConnectionIntentProposal {
        let deviceId: String
        let dashboardId: String
        let revision: String
        let grant: ConnectionGrant
        let auth: ConnectionAuthBinding
    }

    func connectionIntentCall(name: String, arguments: [String: Any],
                              submission: LegacyMutationSubmission) throws -> (String, Bool) {
        let selected = try client.workspaceStatus()
        guard selected.state == "selected", let workspaceId = selected.workspaceId,
              let generation = selected.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        try Self.checkIntentSelection(arguments, workspaceId: workspaceId, generation: generation)
        let intent: WorkbenchConnectionIntentView
        if name == "request_connection_intent" {
            let proposal = try Self.connectionIntentProposal(arguments)
            intent = try submission.send {
                try client.requestConnectionIntent(deviceId: proposal.deviceId,
                    dashboardId: proposal.dashboardId, revision: proposal.revision,
                    grant: proposal.grant, auth: proposal.auth)
            }
            try Self.validateIntentView(intent, target: proposal)
        } else if name == "get_connection_intent" {
            guard Set(arguments.keys).isSubset(of: ["intentId", "expectedWorkspaceId",
                                                    "expectedSelectionGeneration"]),
                  let id = arguments["intentId"] as? String,
                  WorkspaceValidation.id(id) else { throw WorkbenchIPCError(.invalidRequest) }
            intent = try client.connectionIntent(id)
            guard intent.intentId == id else { throw WorkbenchIPCError(.invalidRequest) }
            try Self.validateIntentView(intent, target: nil)
        } else { throw WorkbenchIPCError(.methodNotFound) }
        // The request has an authenticated broker receipt at this point. A
        // later selection read must not turn that applied intent into a false
        // failure; the inspection path still checks selection freshness.
        if name == "get_connection_intent" {
            let current = try client.workspaceStatus()
            guard current.workspaceId == workspaceId,
                  current.selectionGeneration == generation else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
        }
        return (String(decoding: try JSONEncoder().encode(intent), as: UTF8.self), false)
    }

    static func checkIntentSelection(_ arguments: [String: Any], workspaceId: String,
                                     generation: Int) throws {
        let keys = Set(arguments.keys)
        let pair: Set<String> = ["expectedWorkspaceId", "expectedSelectionGeneration"]
        guard keys.intersection(pair).isEmpty || keys.intersection(pair) == pair else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if keys.contains("expectedWorkspaceId") {
            guard arguments["expectedWorkspaceId"] as? String == workspaceId,
                  let claimed = arguments["expectedSelectionGeneration"] as? NSNumber,
                  CFGetTypeID(claimed) != CFBooleanGetTypeID(),
                  claimed.doubleValue == Double(claimed.intValue),
                  claimed.intValue == generation else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
        }
    }

    static func connectionIntentProposal(_ arguments: [String: Any]) throws -> ConnectionIntentProposal {
        let required: Set<String> = ["deviceId", "dashboardId", "revision", "grant", "auth"]
        let pair: Set<String> = ["expectedWorkspaceId", "expectedSelectionGeneration"]
        guard required.isSubset(of: Set(arguments.keys)),
              Set(arguments.keys).isSubset(of: required.union(pair)),
              let deviceId = arguments["deviceId"] as? String, WorkspaceValidation.id(deviceId),
              let dashboardId = arguments["dashboardId"] as? String, WorkspaceValidation.id(dashboardId),
              let revision = arguments["revision"] as? String, WorkspaceValidation.id(revision),
              let grantObject = arguments["grant"] as? [String: Any],
              let authObject = arguments["auth"] as? [String: Any],
              Set(grantObject.keys) == ["schemaVersion", "id", "alias", "origin", "transport",
                                        "authRef", "lan", "allowInsecureHTTP", "operations"],
              Set(authObject.keys) == ["authRef", "placement"],
              let bytes = try? JSONSerialization.data(withJSONObject: arguments),
              bytes.count <= ConnectionBounds.parameterBytes,
              let grantBytes = try? JSONSerialization.data(withJSONObject: grantObject),
              let authBytes = try? JSONSerialization.data(withJSONObject: authObject),
              let grant = try? JSONDecoder().decode(ConnectionGrant.self, from: grantBytes),
              let auth = try? JSONDecoder().decode(ConnectionAuthBinding.self, from: authBytes),
              grant.authRef.isEmpty, auth.authRef.isEmpty, auth.placement == .none,
              auth.fieldName == nil,
              (try? JSONValue.from(grantObject)) ==
                  (try? JSONValue.from(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)))),
              (try? JSONValue.from(authObject)) ==
                  (try? JSONValue.from(JSONSerialization.jsonObject(with: JSONEncoder().encode(auth)))) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        var validationGrant = grant
        validationGrant.authRef = "opaque-validation-placeholder"
        try ConnectionGrantValidator.validate(validationGrant)
        return .init(deviceId: deviceId, dashboardId: dashboardId, revision: revision,
                     grant: grant, auth: auth)
    }

    static func validateIntentView(_ intent: WorkbenchConnectionIntentView,
                                   target: ConnectionIntentProposal?) throws {
        func hash(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        guard WorkspaceValidation.id(intent.intentId),
              hash(intent.declarationHash), hash(intent.authorizationContextHash),
              intent.expiresAt.timeIntervalSince1970.isFinite,
              !intent.state.isEmpty,
              WorkspaceValidation.id(intent.summary.deviceId),
              WorkspaceValidation.id(intent.summary.dashboardId),
              WorkspaceValidation.id(intent.summary.revision) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if let target {
            guard intent.state == "pending", intent.expiresAt > Date(),
                  WorkbenchConnectionIntentAttestation.matchesRequest(intent,
                    deviceId: target.deviceId, dashboardId: target.dashboardId,
                    revision: target.revision, grant: target.grant, auth: target.auth) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
    }

    /// Mirrors the broker's redacted review address grammar. Unknown query
    /// selectors are not reviewable, and credential query values are hidden.
    private static func reviewAddress(origin: String, path: String) -> String? {
        let selectors: Set<String> = ["target", "view", "scope", "device", "entity", "area",
            "room", "mode", "resource", "filter", "name", "state", "zone", "group"]
        let credentials: Set<String> = ["access_token", "api_key", "apikey", "token",
            "password", "auth", "authorization", "key", "secret", "client_secret",
            "access_key", "signature", "credential", "session", "private_key"]
        guard var components = URLComponents(string: origin + path),
              components.scheme != nil, components.host != nil else { return nil }
        components.user = nil; components.password = nil
        if let items = components.queryItems {
            var rendered: [URLQueryItem] = []
            for item in items {
                let key = item.name.lowercased()
                if credentials.contains(key) {
                    rendered.append(URLQueryItem(name: item.name,
                        value: item.value == nil ? nil : "REDACTED"))
                } else if selectors.contains(key), item.name.utf8.count <= 64,
                          item.value.map({ value in
                            value.utf8.count <= 128 && value.utf8.allSatisfy {
                                (48...57).contains($0) || (65...90).contains($0) ||
                                (97...122).contains($0) || [45, 46, 95, 126, 46].contains($0)
                            }
                          }) ?? true {
                    rendered.append(item)
                } else { return nil }
            }
            components.queryItems = rendered
        }
        return components.url?.absoluteString
    }

    static func connectionIntentSchema(_ name: String) -> JSONValue {
        func string() -> JSONValue { .object(["type": .string("string")]) }
        let id: JSONValue = .object(["type": .string("string"), "minLength": .int(1),
            "maxLength": .int(100), "pattern": .string("^[A-Za-z0-9][A-Za-z0-9._-]*$")])
        let uuid: JSONValue = .object(["type": .string("string"), "format": .string("uuid")])
        let selection: [String: JSONValue] = [
            "expectedWorkspaceId": string(),
            "expectedSelectionGeneration": .object(["type": .string("integer"), "minimum": .int(1)])]
        var fields: [String: JSONValue]
        let required: [String]
        if name == "request_connection_intent" {
            let operation: JSONValue = .object(["type": .string("object"), "properties": .object([
                "name": string(), "kind": .object(["type": .string("string"),
                    "enum": .array([.string("http"), .string("ws")])]),
                "method": .object(["type": .string("string"), "enum": .array(
                    ["GET", "POST", "PUT", "PATCH", "DELETE"].map(JSONValue.string))]),
                "path": string(), "idempotent": .object(["type": .string("boolean")]),
                "write": .object(["type": .string("boolean")]),
                "maxAgeSeconds": .object(["type": .string("integer"), "minimum": .int(0)])]),
                "required": .array(["name", "kind", "method", "path", "idempotent", "write"].map(JSONValue.string)),
                "additionalProperties": .bool(false)])
            let grant: JSONValue = .object(["type": .string("object"), "properties": .object([
                "schemaVersion": .object(["type": .string("integer"), "const": .int(1)]),
                "id": uuid, "alias": string(), "origin": string(),
                "transport": .object(["type": .string("string"),
                    "enum": .array([.string("http"), .string("ws")])]),
                "authRef": .object(["type": .string("string"), "const": .string("")]),
                "lan": .object(["type": .string("boolean")]),
                "allowInsecureHTTP": .object(["type": .string("boolean")]),
                "operations": .object(["type": .string("array"), "minItems": .int(1),
                    "maxItems": .int(32), "items": operation])]),
                "required": .array(["schemaVersion", "id", "alias", "origin", "transport",
                    "authRef", "lan", "allowInsecureHTTP", "operations"].map(JSONValue.string)),
                "additionalProperties": .bool(false)])
            let auth: JSONValue = .object(["type": .string("object"), "properties": .object([
                "authRef": .object(["type": .string("string"), "const": .string("")]),
                "placement": .object(["type": .string("string"), "const": .string("none")])]),
                "required": .array([.string("authRef"), .string("placement")]),
                "additionalProperties": .bool(false)])
            fields = ["deviceId": id, "dashboardId": id, "revision": id,
                      "grant": grant, "auth": auth]
            required = ["deviceId", "dashboardId", "revision", "grant", "auth"]
        } else {
            fields = ["intentId": id]
            required = ["intentId"]
        }
        fields.merge(selection) { current, _ in current }
        return .object(["type": .string("object"), "properties": .object(fields),
            "required": .array(required.map(JSONValue.string)),
            "dependentRequired": .object([
                "expectedWorkspaceId": .array([.string("expectedSelectionGeneration")]),
                "expectedSelectionGeneration": .array([.string("expectedWorkspaceId")])]),
            "additionalProperties": .bool(false)])
    }
}
