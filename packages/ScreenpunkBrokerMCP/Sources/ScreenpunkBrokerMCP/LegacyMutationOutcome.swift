import Foundation
import ScreenpunkController

/// The marker is set at the actual mutation call boundary, after local parsing
/// and read-only broker preflight. It stays set if transport loses the reply.
final class LegacyMutationSubmission {
    private(set) var submitted = false

    func send<T>(_ mutation: () throws -> T) rethrows -> T {
        submitted = true
        return try mutation()
    }
}

/// A request that crossed the broker call boundary is never replayed by MCP.
/// A transport loss or explicit publication uncertainty needs an inspection
/// hint, not an ordinary "unavailable" result that suggests retrying.
enum LegacyMutationOutcome {
    static func uncertain(name: String, arguments: [String: Any],
                          error: Error, submitted: Bool) -> String? {
        guard submitted else { return nil }
        if let broker = error as? WorkbenchIPCError,
           ![.disconnected, .timedOut, .unavailable,
             .publicationOutcomeUnknown, .remoteOutcomeUnknown].contains(broker.code) {
            return nil
        }
        let inspection: String
        switch name {
        case "initialize_workspace", "open_workspace", "relocate_workspace":
            inspection = "Call get_workspace and inspect the requested workspace destination."
        case "set_workspace_config", "unset_workspace_config":
            inspection = "Call get_workspace_config before changing settings again."
        case "rename_screen_source":
            inspection = "Call get_screen_project and inspect its source version before another rename."
        case "rename_screen_package", "duplicate_screen_package",
             "set_screen_package_orientation":
            inspection = "Call list_workspace_packages and inspect package revisions before another change."
        case "set_screen_icon":
            inspection = "Call get_workspace_config before changing the icon again."
        case "archive_screen":
            inspection = "Call list_workspace_packages or list_screen_projects, then inspect retained history before another archive."
        case "associate_react_source":
            inspection = "Call get_screen_project and inspect its source version and package identity before another attachment."
        case "run_workspace_build":
            inspection = "Call get_workspace_build and inspect retained package history."
        case "export_workspace_source", "export_workspace_package", "create_workspace_snapshot":
            inspection = "Inspect the explicit export destination before starting another export."
        case "commit_workspace_package_import":
            inspection = "Inspect the import status and selected-workspace package history."
        case "begin_workspace_package_import", "send_workspace_package_import_chunk",
             "abort_workspace_package_import":
            inspection = "Inspect the upload status before sending another package import step."
        case "apply_deployment":
            inspection = "Call lookup_deployment with the original planId, then inspect or reconcile its operation."
        case "prepare_deployment", "plan_deployment", "reconcile_deployment":
            inspection = "Inspect the deployment plan or operation status before another submission."
        case "request_connection_intent":
            inspection = "Inspect current connection intents before creating another request."
        case "begin_device_pairing", "confirm_device_pairing", "cancel_device_pairing":
            inspection = "Call get_pending_pairings and inspect device status before repeating pairing."
        case "cancel_workspace_operation":
            inspection = "Call get_workspace_operation_status before sending another cancellation."
        case "clone_workspace_project", "create_workspace_project", "import_workspace_source",
             "open_screen_project", "open_external_screen_project":
            inspection = "Call list_screen_projects and inspect the destination project."
        case "unregister_workspace_project", "adopt_external_screen_project",
             "relocate_external_screen_project", "patch_workspace_project":
            inspection = "Call get_screen_project and inspect the selected-workspace catalog."
        default:
            inspection = "Inspect current broker state before submitting this operation again."
        }
        let project = (arguments["projectId"] as? String).flatMap { boundedIdentifier($0) }
        let plan = (arguments["planId"] as? String).flatMap { boundedIdentifier($0) }
        let upload = (arguments["uploadId"] as? String).flatMap { boundedIdentifier($0) }
        let destinationTools: Set<String> = ["initialize_workspace", "open_workspace",
            "relocate_workspace", "export_workspace_source", "export_workspace_package",
            "create_workspace_snapshot", "relocate_external_screen_project"]
        let destination = destinationTools.contains(name)
            ? (arguments["path"] as? String).flatMap { boundedIdentifier(String($0.split(separator: "/").last ?? "")) }
            : nil
        let scope = (project.map { " projectId=\($0);" } ?? "") +
            (plan.map { " planId=\($0);" } ?? "") +
            (upload.map { " uploadId=\($0);" } ?? "") +
            (destination.map { " destinationLeaf=\($0);" } ?? "")
        return "workbench_mutation_outcome_unknown: \(name)\(scope) the broker may have applied this request. \(inspection) Do not replay it blindly."
    }

    private static func boundedIdentifier(_ value: String) -> String? {
        guard (1...120).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
        else { return nil }
        return value
    }
}
