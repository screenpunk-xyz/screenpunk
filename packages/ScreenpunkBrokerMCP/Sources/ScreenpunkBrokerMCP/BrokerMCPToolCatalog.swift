import Foundation
import ScreenpunkController

/// One tool catalog for both stdio transports. Every tool still dispatches
/// through LegacyBrokerAdapter's closed name and field policy.
public struct BrokerMCPToolDescriptor {
    public let name: String
    public let description: String
    public let schema: JSONValue
    public let readOnly: Bool
    public let destructive: Bool
    public let idempotent: Bool?
    public let openWorld: Bool
}

public enum BrokerMCPToolCatalog {
    public static let registeredNames = Set(tools().map(\.name))
    public static func tools() -> [BrokerMCPToolDescriptor] {
        let catalog = MCPCatalog.load()
        let byName = Dictionary(uniqueKeysWithValues: catalog.tools.map { ($0.name, $0) })
        // Only advertised routes with a typed broker implementation are
        // callable. Legacy catalog entries needing a native helper remain
        // accessible as explicit capability errors, not advertised success.
        let names = LegacyBrokerAdapter.readTools.union(["get_help"])
            .union(LegacyBrokerAdapter.workspaceTools)
            .union(LegacyBrokerAdapter.extraReadTools)
            .union(LegacyBrokerAdapter.workspacePackageTools)
            .union(LegacyBrokerAdapter.connectionIntentTools)
            .union(LegacyBrokerAdapter.packageImportTools)
            .union(LegacyBrokerAdapter.screenMutationTools)
            .union(LegacyBrokerAdapter.managementTools)
            .union(LegacyBrokerAdapter.authoringTools.keys)
            .union(LegacyBrokerAdapter.deploymentTools.keys)
        return names.sorted().map { name in
            let legacy = byName[name]
            let authoringRead = ["inspect_workspace_project", "get_workspace_build",
                "list_workspace_package_history", "get_workspace_config",
                "get_workspace_config_path"].contains(name)
            let deploymentRead = ["review_deployment", "get_deployment_status",
                "lookup_deployment"].contains(name)
            let isAuthoring = LegacyBrokerAdapter.authoringTools[name] != nil
            let isDeployment = LegacyBrokerAdapter.deploymentTools[name] != nil
            let isWorkspace = LegacyBrokerAdapter.workspaceTools.contains(name)
            let isConnectionIntent = LegacyBrokerAdapter.connectionIntentTools.contains(name)
            let isPackageImport = LegacyBrokerAdapter.packageImportTools.contains(name)
            let isScreenMutation = LegacyBrokerAdapter.screenMutationTools.contains(name)
            let isManagement = LegacyBrokerAdapter.managementTools.contains(name)
            let isNewRead = LegacyBrokerAdapter.extraReadTools.contains(name) ||
                LegacyBrokerAdapter.workspacePackageTools.contains(name) ||
                name == "get_workspace" || name == "get_connection_intent" ||
                name == "get_workspace_package_import_status"
            let readOnly = isScreenMutation ? false :
                isManagement ? LegacyBrokerAdapter.managementReadTools.contains(name) :
                isAuthoring ? authoringRead : isDeployment ? deploymentRead :
                isWorkspace || name == "request_connection_intent" ||
                    (isPackageImport && name != "get_workspace_package_import_status") ? false :
                isNewRead ? true : (legacy?.readOnlyHint ?? true)
            let destructive = isScreenMutation ? name == "archive_screen" :
                isManagement ? ["cancel_workspace_operation", "cancel_device_pairing"].contains(name) :
                isAuthoring ? !authoringRead : name == "apply_deployment" ||
                (legacy?.destructiveHint ?? false)
            let schema: JSONValue
            if isScreenMutation { schema = LegacyBrokerAdapter.screenMutationSchema(name) }
            else if isAuthoring { schema = LegacyBrokerAdapter.authoringSchema(name) }
            else if isDeployment { schema = LegacyBrokerAdapter.deploymentSchema(name) }
            else if isWorkspace { schema = LegacyBrokerAdapter.workspaceSchema(name) }
            else if isConnectionIntent { schema = LegacyBrokerAdapter.connectionIntentSchema(name) }
            else if isPackageImport { schema = LegacyBrokerAdapter.packageImportSchema(name) }
            else if isManagement { schema = LegacyBrokerAdapter.managementSchema(name) }
            else if LegacyBrokerAdapter.extraReadTools.contains(name) {
                schema = LegacyBrokerAdapter.extraReadSchema(name)
            } else if LegacyBrokerAdapter.workspacePackageTools.contains(name) {
                schema = LegacyBrokerAdapter.packageSchema(name)
            } else if name == "get_workspace" { schema = LegacyBrokerAdapter.emptySchema }
            else { schema = MCPToolSchemas.inputSchema(for: name) }
            let description: String
            if name == "apply_deployment" {
                description = "Agent assertion of explicit user approval for the exact reviewed plan and authorization context; broker validates both at admission."
            } else if isDeployment {
                description = "Typed broker deployment workflow; review the exact plan before approval."
            } else if isWorkspace {
                description = "Select a broker workspace; initialization uses the broker default when no path is supplied."
            } else if name == "request_connection_intent" {
                description = "Request a pending no-credential connection intent for later trusted local review; this does not provision or approve the connection."
            } else if name == "get_connection_intent" {
                description = "Read one broker-created connection intent, including its target, state, and expiry."
            } else if isPackageImport {
                description = "Bounded selected-workspace package import step; begin with a validated manifest, send ordered hashed file chunks, then commit or abort. No source or deployment authority is imported."
            } else if name == "archive_screen" {
                description = "Hide one exact screen from the active portable library; source, package history and installed device contents remain unchanged."
            } else if name == "associate_react_source" {
                description = "Attach one exact contained React source version to a verified package identity without granting executable or device authority."
            } else if isScreenMutation {
                description = "Change selected-workspace source or portable package presentation with exact identity and generation checks; existing history remains available."
            } else if name == "export_workspace_source" {
                description = "Export one verified current or retained editable source version to an explicit empty destination."
            } else if name == "import_workspace_source" {
                description = "Import a verified editable-source archive as a new contained project with new identities."
            } else if name == "open_external_screen_project" || name == "relocate_external_screen_project" {
                description = "Explicit external-source registration or rebind; outside-workspace source remains excluded from portable backups."
            } else if name == "unregister_workspace_project" {
                description = "Remove a project from the catalog using generation CAS; existing source and history are retained."
            } else if name == "confirm_device_pairing" {
                description = "Confirm a pending pairing after comparing the device code; broker owns the device identity and final check."
            } else if name == "get_workspace_toolchain_requirements" {
                description = "Read portable kit pins only; this does not establish installed or trusted executable status."
            } else if name == "create_workspace_snapshot" {
                description = "Copy the selected portable workspace to an explicit destination; external-source coverage options are explicit."
            } else if isAuthoring || isNewRead || isManagement {
                description = "Typed selected-workspace broker operation."
            } else if let legacy {
                let supported = LegacyBrokerAdapter.readTools.contains(name) || name == "get_help"
                description = supported ? legacy.description :
                    legacy.description + " (Requires a compatible typed broker route or native preview helper.)"
            } else {
                description = "Typed broker operation."
            }
            return .init(name: name, description: description, schema: schema,
                readOnly: readOnly, destructive: destructive,
                idempotent: legacy?.idempotentHint ?? (readOnly ? true : nil),
                openWorld: legacy?.openWorldHint ?? false)
        }
    }
}
