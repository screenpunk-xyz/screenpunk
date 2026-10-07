import Foundation
import CoreFoundation
import ScreenpunkController

/// The legacy executable is a protocol facade, never another controller owner.
public final class LegacyBrokerAdapter {
    static let readTools: Set<String> = ["get_workspace", "list_dashboards", "get_dashboard",
                                         "validate_dashboard", "list_devices", "get_device"]
    static let extraReadTools: Set<String> = ["list_screen_projects", "get_screen_project",
                                              "get_screen_project_versions", "get_workspace_source_file",
                                              "get_device_screen_set",
                                              "get_device_settings", "get_device_connection_inventory",
                                              "refresh_device_status"]
    static let workspaceTools: Set<String> = ["initialize_workspace", "open_workspace"]
    static let workspacePackageTools: Set<String> = ["list_workspace_packages", "get_workspace_package",
                                                      "get_workspace_package_file"]
    static let connectionIntentTools: Set<String> = ["request_connection_intent", "get_connection_intent"]
    static let packageImportTools: Set<String> = ["begin_workspace_package_import",
        "send_workspace_package_import_chunk", "get_workspace_package_import_status",
        "commit_workspace_package_import", "abort_workspace_package_import"]
    static let screenMutationTools: Set<String> = ["rename_screen_source",
        "rename_screen_package", "duplicate_screen_package",
        "set_screen_package_orientation", "set_screen_icon",
        "archive_screen", "associate_react_source"]
    static let authoringTools: [String: WorkbenchAuthoringRecoveryMethod] = [
        "create_workspace_project": .projectCreate,
        "clone_workspace_project": .projectClone,
        "unregister_workspace_project": .projectUnregister,
        "open_screen_project": .projectOpenContained,
        "inspect_workspace_project": .projectInspect,
        "patch_workspace_project": .projectPatch,
        "export_workspace_source": .projectSourceExport,
        "import_workspace_source": .projectSourceImport,
        "open_external_screen_project": .projectOpenExternal,
        "adopt_external_screen_project": .projectAdoptExternal,
        "relocate_external_screen_project": .projectRelocateExternal,
        "run_workspace_build": .buildRun,
        "get_workspace_build": .buildHead,
        "list_workspace_package_history": .packageHistory,
        "export_workspace_package": .packageExport,
        "create_workspace_snapshot": .snapshotCreate,
        "relocate_workspace": .workspaceRelocate,
        "get_workspace_config": .workspaceConfigGet,
        "get_workspace_config_path": .workspaceConfigPath,
        "set_workspace_config": .workspaceConfigSet,
        "unset_workspace_config": .workspaceConfigUnset
    ]
    static let deploymentTools: [String: WorkbenchDeploymentMethod] = [
        "prepare_deployment": .prepare, "plan_deployment": .plan,
        "review_deployment": .review, "apply_deployment": .apply,
        "get_deployment_status": .status, "lookup_deployment": .lookup,
        "reconcile_deployment": .reconcile
    ]
    let client: WorkbenchBrokerClient
    let packageImportRegistry = PackageImportManifestRegistry()
    private let ownsClient: Bool

    public convenience init() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let runtime = base.appendingPathComponent("xyz.screenpunk.workbench", isDirectory: true)
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let client = WorkbenchBrokerClient(environment: environment, credentialScope: .ordinary)
        try client.connect()
        let home = DashboardPackageStore.defaultRoot().resolvingSymlinksInPath().path
        do { try self.init(client: client, expectedControllerHomePath: home, ownsClient: true) }
        catch {
            client.close()
            throw error
        }
    }

    /// The caller keeps ownership of an already connected ordinary client.
    /// The home assertion prevents the configured MCP process from attaching
    /// to a different controller home through a reused runtime directory.
    public convenience init(client: WorkbenchBrokerClient,
                            expectedControllerHomePath: String) throws {
        try self.init(client: client, expectedControllerHomePath: expectedControllerHomePath,
            ownsClient: false)
    }

    private init(client: WorkbenchBrokerClient, expectedControllerHomePath: String,
                 ownsClient: Bool) throws {
        guard try client.hello().controllerHomePath ==
                URL(fileURLWithPath: expectedControllerHomePath).resolvingSymlinksInPath().path else {
            throw LegacyBrokerError.controllerHomeMismatch
        }
        self.client = client; self.ownsClient = ownsClient
    }

    deinit { if ownsClient { client.close() } }

    public static let resourceURIs: [String] = ["screenpunk://help/onboarding",
        "screenpunk://workbench/workspace", "screenpunk://workbench/capabilities",
        "screenpunk://projects/{id}", "screenpunk://deployments/plans/{id}"]

    public func resource(_ uri: String) -> (text: String, isError: Bool) {
        do {
            switch uri {
            case "screenpunk://workbench/workspace": return (try Self.json(client.workspaceStatus()), false)
            case "screenpunk://workbench/capabilities": return (try Self.json(client.capabilities()), false)
            default:
                let projectPrefix = "screenpunk://projects/"
                let planPrefix = "screenpunk://deployments/plans/"
                if uri.hasPrefix(projectPrefix) {
                    let id = String(uri.dropFirst(projectPrefix.count))
                    guard !id.isEmpty, !id.contains("/") else { throw WorkbenchIPCError(.invalidRequest) }
                    return (try Self.json(client.getProject(id)), false)
                }
                if uri.hasPrefix(planPrefix) {
                    let id = String(uri.dropFirst(planPrefix.count))
                    guard !id.isEmpty, !id.contains("/") else { throw WorkbenchIPCError(.invalidRequest) }
                    let selected = try client.workspaceStatus()
                    guard selected.state == "selected", let workspaceId = selected.workspaceId,
                          let generation = selected.selectionGeneration else {
                        throw WorkbenchIPCError(.workspaceConflict)
                    }
                    let result = try client.performDeployment(method: .review, params: [
                        "schemaVersion": 1, "expectedWorkspaceId": workspaceId,
                        "expectedSelectionGeneration": generation, "planId": id])
                    return (try Self.json(result), false)
                }
                if uri.hasPrefix("screenpunk://authoring/") {
                    return ("capability_unavailable: Authoring resource requires a compatible broker route.", true)
                }
                guard uri.hasPrefix("screenpunk://help/") else { throw WorkbenchIPCError(.invalidRequest) }
                let topic = String(uri.dropFirst("screenpunk://help/".count))
                guard !topic.isEmpty, !topic.contains("/") else { throw WorkbenchIPCError(.invalidRequest) }
                return (HelpCatalog.topic(id: topic).body, false)
            }
        } catch {
            return ("workbench_resource_unavailable: \(error.localizedDescription)", true)
        }
    }

    public func call(name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        guard BrokerMCPToolCatalog.registeredNames.contains(name) else {
            return ("capability_unavailable: No registered typed broker tool has this name.", true)
        }
        if name == "get_help" {
            guard Set(arguments.keys).isSubset(of: ["topic"]),
                  arguments["topic"] == nil || arguments["topic"] is String else {
                return ("workbench_help_unavailable: invalid tool arguments", true)
            }
            let topic = HelpCatalog.topic(id: arguments["topic"] as? String ?? "onboarding")
            return ("\(topic.title)\n\n\(topic.body)", false)
        }
        if Self.workspaceTools.contains(name) {
            var submitted = false
            do {
                guard Set(arguments.keys).isSubset(of: ["path"]),
                      name == "initialize_workspace" || arguments["path"] != nil,
                      arguments["path"] == nil || arguments["path"] is String else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                let value: WorkbenchWorkspaceStatus
                if name == "initialize_workspace" {
                    submitted = true
                    value = try client.initializeWorkspace(path: arguments["path"] as? String)
                } else {
                    guard let path = arguments["path"] as? String else { throw WorkbenchIPCError(.invalidRequest) }
                    submitted = true
                    value = try client.openWorkspace(path: path)
                }
                return (try Self.json(value), false)
            } catch {
                if let uncertain = LegacyMutationOutcome.uncertain(name: name,
                    arguments: arguments, error: error, submitted: submitted) {
                    return (uncertain, true)
                }
                return ("workbench_workspace_unavailable: \(error.localizedDescription)", true)
            }
        }
        if Self.readTools.contains(name) || Self.extraReadTools.contains(name) || Self.workspacePackageTools.contains(name) {
            do {
                if Self.extraReadTools.contains(name) {
                    return try extraRead(name: name, arguments: arguments)
                }
                if ["list_dashboards", "get_dashboard", "validate_dashboard"].contains(name) ||
                    Self.workspacePackageTools.contains(name) {
                    return try workspacePackageRead(name: name, arguments: arguments)
                }
                let result = try client.requestMCPRead(tool: name, arguments: arguments)
                let data = try JSONEncoder().encode(result)
                return (String(decoding: data, as: UTF8.self), false)
            } catch {
                return ("workbench_read_unavailable: \(error.localizedDescription)", true)
            }
        }
        if Self.connectionIntentTools.contains(name) {
            let submission = LegacyMutationSubmission()
            do { return try connectionIntentCall(name: name, arguments: arguments,
                submission: submission) }
            catch {
                if name == "request_connection_intent",
                   let uncertain = LegacyMutationOutcome.uncertain(name: name,
                       arguments: arguments, error: error, submitted: submission.submitted) {
                    return (uncertain, true)
                }
                return ("workbench_connection_intent_unavailable: \(error.localizedDescription)", true)
            }
        }
        if Self.packageImportTools.contains(name) {
            let submission = LegacyMutationSubmission()
            do { return try packageImportCall(name: name, arguments: arguments,
                submission: submission) }
            catch {
                if name != "get_workspace_package_import_status",
                   let uncertain = LegacyMutationOutcome.uncertain(name: name,
                       arguments: arguments, error: error, submitted: submission.submitted) {
                    return (uncertain, true)
                }
                return ("workbench_package_import_unavailable: \(error.localizedDescription)", true)
            }
        }
        if Self.screenMutationTools.contains(name) {
            let submission = LegacyMutationSubmission()
            do {
                guard arguments["schemaVersion"] == nil else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                var params = arguments; params["schemaVersion"] = 1
                let result: String
                switch name {
                case "rename_screen_source":
                    _ = try WorkbenchScreenRenameRequest.parse(params)
                    result = try submission.send { try Self.json(client.renameScreenSource(params: params)) }
                case "rename_screen_package":
                    _ = try WorkbenchScreenPackageRenameRequest.parse(params)
                    result = try submission.send { try Self.json(client.renameScreenPackage(params: params)) }
                case "duplicate_screen_package":
                    _ = try WorkbenchScreenPackageDuplicateRequest.parse(params)
                    result = try submission.send { try Self.json(client.duplicateScreenPackage(params: params)) }
                case "set_screen_package_orientation":
                    _ = try WorkbenchScreenPackageOrientationRequest.parse(params)
                    result = try submission.send { try Self.json(client.setScreenPackageOrientation(params: params)) }
                case "archive_screen":
                    _ = try WorkbenchScreenArchiveRequest.parse(params)
                    result = try submission.send { try Self.json(client.archiveScreen(params: params)) }
                case "associate_react_source":
                    _ = try WorkbenchReactSourceAssociationRequest.parse(params)
                    result = try submission.send { try Self.json(client.associateReactSource(params: params)) }
                default:
                    _ = try WorkbenchScreenIconRequest.parse(params)
                    result = try submission.send { try Self.json(client.setScreenIcon(params: params)) }
                }
                return (result, false)
            } catch {
                if let uncertain = LegacyMutationOutcome.uncertain(name: name,
                    arguments: arguments, error: error, submitted: submission.submitted) {
                    return (uncertain, true)
                }
                return ("workbench_screen_mutation_unavailable: \(error.localizedDescription)", true)
            }
        }
        if Self.managementTools.contains(name) {
            do { return try managementCall(name: name, arguments: arguments) }
            catch {
                if !Self.managementReadTools.contains(name),
                   let uncertain = LegacyMutationOutcome.uncertain(name: name,
                       arguments: arguments, error: error, submitted: true) {
                    return (uncertain, true)
                }
                return ("workbench_management_unavailable: \(error.localizedDescription)", true)
            }
        }
        if let method = Self.deploymentTools[name] {
            let mutating = ![WorkbenchDeploymentMethod.review, .status,
                .lookup].contains(method)
            var submitted = false
            do {
                var params = try Self.deploymentParams(name: name, arguments: arguments)
                let selected = try client.workspaceStatus()
                guard selected.state == "selected", let id = selected.workspaceId,
                      let generation = selected.selectionGeneration else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                if let expected = params["expectedWorkspaceId"] as? String, expected != id {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                if let expected = params["expectedSelectionGeneration"] as? Int, expected != generation {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                params["expectedWorkspaceId"] = id
                params["expectedSelectionGeneration"] = generation
                submitted = true
                let result = try client.performDeployment(method: method, params: params)
                return (try Self.json(result), false)
            } catch {
                if mutating, let uncertain = LegacyMutationOutcome.uncertain(name: name,
                    arguments: arguments, error: error, submitted: submitted) {
                    return (uncertain, true)
                }
                return ("workbench_deployment_unavailable: \(error.localizedDescription)", true)
            }
        }
        if let method = Self.authoringTools[name] {
            let mutating = ![WorkbenchAuthoringRecoveryMethod.projectInspect,
                .buildHead, .packageHistory, .workspaceConfigGet,
                .workspaceConfigPath].contains(method)
            var submitted = false
            do {
                var params = try Self.authoringParams(method: method, arguments: arguments)
                if params["expectedWorkspaceId"] == nil {
                    let selected = try client.workspaceStatus()
                    guard selected.state == "selected", let id = selected.workspaceId,
                          let generation = selected.selectionGeneration else {
                        throw WorkbenchIPCError(.workspaceConflict)
                    }
                    params["expectedWorkspaceId"] = id
                    params["expectedSelectionGeneration"] = generation
                }
                _ = try WorkbenchAuthoringRecoveryRequest.parse(method: method, params: params)
                submitted = true
                let result = try client.performAuthoring(method: method, params: params)
                let data = try JSONEncoder().encode(result)
                return (String(decoding: data, as: UTF8.self), false)
            } catch {
                if mutating, let uncertain = LegacyMutationOutcome.uncertain(name: name,
                    arguments: arguments, error: error, submitted: submitted) {
                    return (uncertain, true)
                }
                return ("workbench_authoring_unavailable: \(error.localizedDescription)", true)
            }
        }
        if name == "preview_dashboard" || name == "interact_preview" {
            return ("preview_required: A compatible native preview helper is not attached to this broker.", true)
        }
        return ("capability_unavailable: This legacy tool needs a typed broker route; no independent controller will be started.", true)
    }

    private func extraRead(name: String, arguments: [String: Any]) throws -> (String, Bool) {
        switch name {
        case "list_screen_projects":
            guard arguments.isEmpty else { throw WorkbenchIPCError(.invalidRequest) }
            return (try Self.json(client.listProjects()), false)
        case "get_screen_project", "get_screen_project_versions":
            guard Set(arguments.keys) == ["projectId"], let id = arguments["projectId"] as? String else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            if name == "get_screen_project" { return (try Self.json(client.getProject(id)), false) }
            return (try Self.json(client.projectVersions(id)), false)
        case "get_workspace_source_file":
            let selected = try client.workspaceStatus()
            guard selected.state == "selected", let workspaceId = selected.workspaceId,
                  let generation = selected.selectionGeneration else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            let request = try Self.sourceChunkRequest(arguments: arguments,
                workspaceId: workspaceId, selectionGeneration: generation)
            let chunk = try client.sourceChunk(projectId: request.projectId, path: request.path,
                expectedSourceVersion: request.expectedSourceVersion, offset: request.offset,
                expectedWorkspaceId: workspaceId, expectedSelectionGeneration: generation)
            let current = try client.workspaceStatus()
            guard current.workspaceId == workspaceId,
                  current.selectionGeneration == generation else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            return (try Self.json(chunk), false)
        case "get_device_screen_set", "get_device_settings", "get_device_connection_inventory",
             "refresh_device_status":
            guard Set(arguments.keys) == ["deviceId"], let id = arguments["deviceId"] as? String else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            switch name {
            case "get_device_screen_set": return (try Self.json(client.freshDeviceScreenSet(deviceId: id)), false)
            case "get_device_settings": return (try Self.json(client.deviceSettings(id)), false)
            case "get_device_connection_inventory": return (try Self.json(client.deviceConnections(id)), false)
            default: return (try Self.json(client.deviceStatus(id, refresh: true)), false)
            }
        default: throw WorkbenchIPCError(.invalidRequest)
        }
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func workspacePackageRead(name: String, arguments: [String: Any]) throws -> (String, Bool) {
        let selected = try client.workspaceStatus()
        guard selected.state == "selected" else { throw WorkbenchIPCError(.workspaceConflict) }
        if name == "list_dashboards" || name == "list_workspace_packages" {
            guard arguments.isEmpty else { throw WorkbenchIPCError(.invalidRequest) }
            let packages = try client.listWorkspacePackages(in: selected)
            let data = try JSONSerialization.data(withJSONObject: [(name == "list_dashboards" ? "dashboards" : "packages"): packages.map { item in
                ["dashboardId": item.dashboardId, "revision": item.revision, "name": item.name,
                 "digest": item.digest, "storage": item.storage, "provenance": item.provenance]
            }], options: [.sortedKeys])
            return (String(decoding: data, as: UTF8.self), false)
        }
        let file = name == "get_workspace_package_file"
        let allowed: Set<String> = file ? ["dashboardId", "revision", "path", "offset"] : ["dashboardId", "revision"]
        guard Set(arguments.keys).isSubset(of: allowed),
              let id = arguments["dashboardId"] as? String else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if arguments.keys.contains("revision"), !(arguments["revision"] is String) {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if file {
            guard Set(arguments.keys) == allowed,
                  let revision = arguments["revision"] as? String,
                  let path = arguments["path"] as? String,
                  let offset = arguments["offset"] as? Int else { throw WorkbenchIPCError(.invalidRequest) }
            let chunk = try client.workspacePackageFile(dashboardId: id, revision: revision,
                path: path, offset: offset, in: selected)
            let current = try client.workspaceStatus()
            guard current.workspaceId == selected.workspaceId,
                  current.selectionGeneration == selected.selectionGeneration else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            let data = try JSONEncoder().encode(chunk)
            return (String(decoding: data, as: UTF8.self), false)
        }
        let revision: String
        if let explicit = arguments["revision"] as? String {
            revision = explicit
        } else {
            let matches = try client.listWorkspacePackages(in: selected).filter { $0.dashboardId == id }
            guard matches.count == 1 else { throw WorkbenchIPCError(.invalidRequest) }
            revision = matches[0].revision
        }
        let package = try client.workspacePackage(dashboardId: id, revision: revision, in: selected)
        let current = try client.workspaceStatus()
        guard current.workspaceId == selected.workspaceId,
              current.selectionGeneration == selected.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let object: [String: Any] = name == "validate_dashboard"
            ? ["ok": true, "dashboardId": id, "revision": revision, "digest": package.digest,
               "storage": package.storage, "provenance": package.provenance]
            : ["dashboardId": id, "revision": revision, "name": package.name,
               "digest": package.digest, "fileCount": package.fileCount,
               "storage": package.storage, "provenance": package.provenance]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (String(decoding: data, as: UTF8.self), false)
    }

    static func packageSchema(_ name: String) -> JSONValue {
        func string() -> JSONValue { .object(["type": .string("string")]) }
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        if name != "list_workspace_packages" {
            properties = ["dashboardId": string(), "revision": string()]
            required = ["dashboardId", "revision"]
        }
        if name == "get_workspace_package_file" {
            properties["path"] = string()
            properties["offset"] = .object(["type": .string("integer"), "minimum": .int(0)])
            required += ["path", "offset"]
        }
        return .object(["type": .string("object"), "properties": .object(properties),
                        "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    static func authoringParams(method: WorkbenchAuthoringRecoveryMethod,
                                arguments: [String: Any]) throws -> [String: Any] {
        guard arguments["schemaVersion"] == nil else { throw WorkbenchIPCError(.invalidRequest) }
        var params = arguments
        params["schemaVersion"] = 1
        _ = try WorkbenchAuthoringRecoveryRequest.parse(method: method, params: params)
        return params
    }

    static func authoringSchema(_ name: String) -> JSONValue {
        func string() -> JSONValue { .object(["type": .string("string")]) }
        var properties: [String: JSONValue]
        let required: [String]
        switch name {
        case "create_workspace_project":
            properties = ["name": string(), "kind": .object(["type": .string("string"),
                "enum": .array([.string("web"), .string("react")])])]
            required = ["name", "kind"]
        case "clone_workspace_project":
            properties = ["projectId": string(), "expectedSourceVersion": string(), "name": string()]
            required = ["projectId", "expectedSourceVersion"]
        case "unregister_workspace_project":
            properties = ["projectId": string(), "expectedCatalogGeneration": .object([
                "type": .string("integer"), "minimum": .int(0)])]
            required = ["projectId", "expectedCatalogGeneration"]
        case "open_screen_project":
            properties = ["path": string()]; required = ["path"]
        case "inspect_workspace_project", "get_workspace_build":
            properties = ["projectId": string()]; required = ["projectId"]
        case "patch_workspace_project":
            let path = JSONValue.object(["type": .string("string"), "minLength": .int(1),
                                         "maxLength": .int(4096),
                                         "description": .string("Included relative source member; broker rejects excluded and unsafe paths.")])
            let bytes = JSONValue.object(["type": .string("string"), "maxLength": .int(6_990_508),
                                          "contentEncoding": .string("base64"),
                                          "pattern": .string("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"),
                                          "description": .string("Canonical base64 of at most 5 MiB decoded bytes; broker enforces project quota and source CAS.")])
            let write = JSONValue.object(["type": .string("object"),
                "properties": .object(["path": path, "bytesBase64": bytes]),
                "required": .array([.string("path"), .string("bytesBase64")]),
                "additionalProperties": .bool(false)])
            let remove = JSONValue.object(["type": .string("object"),
                "properties": .object(["path": path,
                    "delete": .object(["type": .string("boolean"), "const": .bool(true)])]),
                "required": .array([.string("path"), .string("delete")]),
                "additionalProperties": .bool(false)])
            properties = ["projectId": string(),
                          "expectedSourceVersion": .object(["type": .string("string"),
                              "pattern": .string("^[0-9a-f]{64}$")]),
                          "changes": .object(["type": .string("array"),
                              "minItems": .int(1), "maxItems": .int(16),
                              "items": .object(["oneOf": .array([write, remove])])])]
            required = ["projectId", "expectedSourceVersion", "changes"]
        case "run_workspace_build":
            properties = ["projectId": string(), "expectedSourceVersion": string(), "baseRevision": string()]
            required = ["projectId", "expectedSourceVersion"]
        case "export_workspace_source":
            properties = ["projectId": string(), "sourceVersion": string(), "path": string()]
            required = ["projectId", "sourceVersion", "path"]
        case "import_workspace_source":
            properties = ["path": string(), "name": string()]; required = ["path"]
        case "open_external_screen_project":
            properties = ["path": string(), "explicitExternal": .object([
                "type": .string("boolean"), "const": .bool(true)])]
            required = ["path", "explicitExternal"]
        case "adopt_external_screen_project":
            properties = ["projectId": string(), "expectedSourceVersion": string(), "name": string()]
            required = ["projectId", "expectedSourceVersion", "name"]
        case "relocate_external_screen_project":
            properties = ["projectId": string(), "expectedSourceVersion": string(),
                "path": string(), "explicitExternal": .object([
                    "type": .string("boolean"), "const": .bool(true)])]
            required = ["projectId", "expectedSourceVersion", "path", "explicitExternal"]
        case "export_workspace_package":
            properties = ["dashboardId": string(), "revision": string(), "path": string()]
            required = ["dashboardId", "revision", "path"]
        case "create_workspace_snapshot":
            properties = ["path": string(), "includeExternal": .object(["type": .string("boolean")]),
                "allowIncomplete": .object(["type": .string("boolean")])]
            required = ["path"]
        case "relocate_workspace":
            properties = ["path": string()]; required = ["path"]
        case "get_workspace_config", "get_workspace_config_path":
            properties = [:]; required = []
        case "set_workspace_config":
            properties = ["key": .object(["type": .string("string"), "enum": .array(
                ["theme", "view", "sort", "defaultCollection"].map(JSONValue.string))]),
                "value": string(), "expectedGeneration": .object([
                    "type": .string("integer"), "minimum": .int(0)])]
            required = ["key", "value", "expectedGeneration"]
        case "unset_workspace_config":
            properties = ["key": .object(["type": .string("string"), "enum": .array(
                ["theme", "view", "sort", "defaultCollection"].map(JSONValue.string))]),
                "expectedGeneration": .object(["type": .string("integer"), "minimum": .int(0)])]
            required = ["key", "expectedGeneration"]
        default:
            properties = [:]; required = []
        }
        properties["expectedWorkspaceId"] = string()
        properties["expectedSelectionGeneration"] = .object(["type": .string("integer"),
                                                               "minimum": .int(0)])
        var shape: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties),
                        "required": .array(required.map(JSONValue.string)),
                        "dependentRequired": .object([
                            "expectedWorkspaceId": .array([.string("expectedSelectionGeneration")]),
                            "expectedSelectionGeneration": .array([.string("expectedWorkspaceId")])]),
                        "additionalProperties": .bool(false)]
        if name == "create_workspace_snapshot" {
            shape["dependentRequired"] = .object([
                "expectedWorkspaceId": .array([.string("expectedSelectionGeneration")]),
                "expectedSelectionGeneration": .array([.string("expectedWorkspaceId")]),
                "includeExternal": .array([.string("allowIncomplete")]),
                "allowIncomplete": .array([.string("includeExternal")])])
        }
        return .object(shape)
    }

    static func extraReadSchema(_ name: String) -> JSONValue {
        if name == "get_workspace_source_file" {
            let string: JSONValue = .object(["type": .string("string")])
            return .object(["type": .string("object"), "properties": .object([
                "projectId": string, "path": string,
                "expectedSourceVersion": .object(["type": .string("string"),
                    "pattern": .string("^[0-9a-f]{64}$")]),
                "offset": .object(["type": .string("integer"), "minimum": .int(0),
                    "maximum": .int(WorkbenchSourceChunkRequest.maximumFileBytes)]),
                "expectedWorkspaceId": string,
                "expectedSelectionGeneration": .object(["type": .string("integer"),
                    "minimum": .int(1)])]),
                "required": .array([.string("projectId"), .string("path"),
                    .string("expectedSourceVersion"), .string("offset")]),
                "dependentRequired": .object([
                    "expectedWorkspaceId": .array([.string("expectedSelectionGeneration")]),
                    "expectedSelectionGeneration": .array([.string("expectedWorkspaceId")])]),
                "additionalProperties": .bool(false)])
        }
        let field = ["get_device_screen_set", "get_device_settings",
                     "get_device_connection_inventory", "refresh_device_status"].contains(name)
            ? "deviceId" : "projectId"
        let needsField = name != "list_screen_projects"
        return .object(["type": .string("object"),
                        "properties": .object(needsField ? [field: .object(["type": .string("string")])] : [:]),
                        "required": .array(needsField ? [.string(field)] : []),
                        "additionalProperties": .bool(false)])
    }

    static func sourceChunkRequest(arguments: [String: Any], workspaceId: String,
                                   selectionGeneration: Int) throws -> WorkbenchSourceChunkRequest {
        let required: Set<String> = ["projectId", "path", "expectedSourceVersion", "offset"]
        let selection: Set<String> = ["expectedWorkspaceId", "expectedSelectionGeneration"]
        let keys = Set(arguments.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(selection)),
              keys.intersection(selection).isEmpty || keys.intersection(selection) == selection,
              let projectId = arguments["projectId"] as? String,
              let path = arguments["path"] as? String,
              let version = arguments["expectedSourceVersion"] as? String,
              let offset = arguments["offset"] as? NSNumber,
              CFGetTypeID(offset) != CFBooleanGetTypeID(),
              offset.doubleValue == Double(offset.intValue) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if keys.contains("expectedWorkspaceId") {
            guard arguments["expectedWorkspaceId"] as? String == workspaceId,
                  let generation = arguments["expectedSelectionGeneration"] as? NSNumber,
                  CFGetTypeID(generation) != CFBooleanGetTypeID(),
                  generation.doubleValue == Double(generation.intValue),
                  generation.intValue == selectionGeneration else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
        }
        return try WorkbenchSourceChunkRequest(expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: selectionGeneration, projectId: projectId,
            path: path, expectedSourceVersion: version, offset: offset.intValue)
    }

    static let emptySchema: JSONValue = .object(["type": .string("object"),
        "properties": .object([:]), "additionalProperties": .bool(false)])

    static func screenMutationSchema(_ name: String) -> JSONValue {
        let string: JSONValue = .object(["type": .string("string")])
        let integer: JSONValue = .object(["type": .string("integer"), "minimum": .int(0)])
        var properties: [String: JSONValue] = [
            "expectedWorkspaceId": string,
            "expectedSelectionGeneration": integer,
            "expectedCatalogGeneration": integer]
        var required = ["expectedWorkspaceId", "expectedSelectionGeneration",
            "expectedCatalogGeneration"]
        if name == "rename_screen_source" || name == "associate_react_source" {
            properties["projectId"] = string
            properties["expectedSourceVersion"] = string
            required += ["projectId", "expectedSourceVersion"]
            if name == "rename_screen_source" {
                properties["name"] = string; required.append("name")
            } else {
                properties["dashboardId"] = string
                properties["expectedRevision"] = string
                properties["expectedDigest"] = string
                required += ["dashboardId", "expectedRevision", "expectedDigest"]
            }
        } else {
            properties["dashboardId"] = string
            required.append("dashboardId")
            if name != "set_screen_icon" && name != "archive_screen" {
                properties["expectedRevision"] = string
                properties["expectedDigest"] = string
                required += ["expectedRevision", "expectedDigest"]
            }
            switch name {
            case "rename_screen_package", "duplicate_screen_package":
                properties["name"] = string; required.append("name")
            case "set_screen_package_orientation":
                properties["support"] = .object(["type": .string("string"),
                    "enum": .array([.string("portrait"), .string("landscape"), .string("both")])])
                required.append("support")
            default:
                if name == "set_screen_icon" {
                    properties["symbol"] = string; required.append("symbol")
                } else {
                    properties["expectedRevision"] = string
                    properties["expectedDigest"] = string
                    properties["projectId"] = string
                    properties["expectedSourceVersion"] = string
                }
            }
        }
        var schema: [String: JSONValue] = ["type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false)]
        if name == "archive_screen" {
            schema["oneOf"] = .array([
                .object(["required": .array([.string("expectedRevision"), .string("expectedDigest")])]),
                .object(["required": .array([.string("projectId"), .string("expectedSourceVersion")])])])
        }
        return .object(schema)
    }

    static func workspaceSchema(_ name: String) -> JSONValue {
        .object(["type": .string("object"),
                 "properties": .object(["path": .object(["type": .string("string")])]),
                 "required": .array(name == "open_workspace" ? [.string("path")] : []),
                 "additionalProperties": .bool(false)])
    }

    static func deploymentParams(name: String, arguments: [String: Any]) throws -> [String: Any] {
        guard let method = deploymentTools[name], arguments["schemaVersion"] == nil else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        let common: Set<String> = ["expectedWorkspaceId", "expectedSelectionGeneration"]
        let required: Set<String>
        switch method {
        case .prepare: required = ["deviceId", "dashboardId", "sourceRevision", "orientation"]
        case .plan: required = ["deviceId", "packages", "selectedDashboardId", "removedDashboardIds", "bindingIds", "lifetimeSeconds"]
        case .review, .lookup: required = ["planId"]
        case .apply: required = ["planId", "expectedPlanHash", "expectedAuthorizationContextHash", "idempotencyKey", "approved"]
        case .status, .reconcile: required = ["operationId"]
        default: throw WorkbenchIPCError(.invalidRequest)
        }
        let keys = Set(arguments.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(common)),
              keys.contains("expectedWorkspaceId") == keys.contains("expectedSelectionGeneration") else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if method == .apply {
            guard let approved = arguments["approved"] as? NSNumber,
                  CFGetTypeID(approved) == CFBooleanGetTypeID(), approved.boolValue,
                  let hash = arguments["expectedAuthorizationContextHash"] as? String,
                  hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                throw WorkbenchIPCError(.confirmationRequired)
            }
        }
        var params = arguments
        params["schemaVersion"] = 1
        return params
    }

    static func deploymentSchema(_ name: String) -> JSONValue {
        func string() -> JSONValue { .object(["type": .string("string")]) }
        var fields: [String: JSONValue] = [:]
        var required: [String] = []
        switch deploymentTools[name] {
        case .prepare:
            fields = ["deviceId": string(), "dashboardId": string(), "sourceRevision": string(),
                      "orientation": .object(["type": .string("string"), "enum": .array([.string("portrait"), .string("landscape")])])]
            required = ["deviceId", "dashboardId", "sourceRevision", "orientation"]
        case .plan:
            let package = JSONValue.object(["type": .string("object"), "properties": .object([
                "dashboardId": string(), "sourceRevision": string(), "revision": string(), "dataDescription": string()]),
                "required": .array([.string("dashboardId"), .string("sourceRevision"), .string("revision"), .string("dataDescription")]),
                "additionalProperties": .bool(false)])
            fields = ["deviceId": string(), "packages": .object(["type": .string("array"), "items": package,
                "minItems": .int(1), "maxItems": .int(12)]), "selectedDashboardId": string(),
                "removedDashboardIds": .object(["type": .string("array"), "items": string(), "maxItems": .int(12)]),
                "bindingIds": .object(["type": .string("array"), "items": string(), "maxItems": .int(32)]),
                "lifetimeSeconds": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(86_400)])]
            required = ["deviceId", "packages", "selectedDashboardId", "removedDashboardIds", "bindingIds", "lifetimeSeconds"]
        case .review, .lookup: fields = ["planId": string()]; required = ["planId"]
        case .apply:
            fields = ["planId": string(), "expectedPlanHash": string(), "expectedAuthorizationContextHash": string(),
                      "idempotencyKey": string(), "approved": .object(["type": .string("boolean"), "const": .bool(true)])]
            required = ["planId", "expectedPlanHash", "expectedAuthorizationContextHash", "idempotencyKey", "approved"]
        case .status, .reconcile: fields = ["operationId": string()]; required = ["operationId"]
        default: break
        }
        fields["expectedWorkspaceId"] = string()
        fields["expectedSelectionGeneration"] = .object(["type": .string("integer"), "minimum": .int(1)])
        return .object(["type": .string("object"), "properties": .object(fields),
                        "required": .array(required.map(JSONValue.string)),
                        "dependentRequired": .object([
                            "expectedWorkspaceId": .array([.string("expectedSelectionGeneration")]),
                            "expectedSelectionGeneration": .array([.string("expectedWorkspaceId")])]),
                        "additionalProperties": .bool(false)])
    }
}

private enum LegacyBrokerError: LocalizedError {
    case controllerHomeMismatch
    var errorDescription: String? { "Broker controller home does not match this MCP executable's configured home." }
}
