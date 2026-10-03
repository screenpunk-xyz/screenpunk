import Foundation
import Dispatch
import Darwin
import ScreenpunkController
import ScreenpunkCore
import ScreenpunkDistribution

public enum WorkbenchCommand {
    public static let version = "0.2.0-m1"

    public static func run(arguments: [String], serviceExecutable: Bool = false,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           localReviewTTY: (() throws -> Int32)? = nil,
                           localSecretInput: (() throws -> Data)? = nil,
                           lifecycleContext: WorkbenchLifecycleContext? = nil) -> Int32 {
        let mcpInvocation = arguments.indices.contains { index in
            arguments[index] == "mcp" && index + 1 < arguments.count && arguments[index + 1] == "serve"
        }
        var presentation = Presentation(json: arguments.contains("--json") && !mcpInvocation)
        var currentCancellation: SignalCancellation?
        do {
            let options = try Options.parse(arguments, environment: environment)
            presentation = Presentation(json: options.json && !mcpInvocation)
            var words = options.words
            if words.first == "config" { words = try workspaceConfigAlias(words) }
            if serviceExecutable {
                if words == ["--foreground"] || words == ["run", "--foreground"] { words = ["service", "run", "--foreground"] }
                else if !options.help && !options.version { throw Options.usage("screenpunk-service requires --foreground.") }
            }
            if options.version || words == ["version"] {
                let displayed = try WorkbenchProductionTrust.homebrewRoot().map {
                    try WorkbenchProductionTrust.verifyPackage($0).version
                } ?? version
                presentation.success(["version": displayed, "apiVersion": "1.0"], human: "screenpunk \(displayed)")
                return 0
            }
            if options.help || words.isEmpty || words.first == "help" {
                let topic = words.first == "help" ? words.dropFirst().first : words.first
                presentation.success(["text": try helpText(topic: topic)], human: try helpText(topic: topic))
                return 0
            }
            let known = ["setup", "workspace", "operation", "project", "screen", "build", "migration", "device", "connection", "approval", "deploy", "service", "doctor", "diagnostics", "agent", "mcp", "toolchain", "config", "install", "update", "uninstall", "package"]
            if !known.contains(words.first ?? "") { throw Options.usage("Unknown command. Use screenpunk help.") }
            if let profile = options.profile, profile != "default",
               words.count >= 3, words[0] == "workspace", words[1] == "config",
               ["set", "unset"].contains(words[2]) {
                throw Options.usage("Named --profile selects an effective read view; workspace config set/unset edits defaults and requires --profile default or no profile.")
            }
            if let profile = options.profile, profile != "default",
               words.first == "screen", ["icon-set", "archive"].contains(words.dropFirst().first ?? "") {
                throw Options.usage("Named --profile selects presentation values only; screen icons and library archive are workspace-wide. Use --profile default or no profile.")
            }
            if options.profile != nil && (["setup", "service", "doctor", "agent", "mcp", "install",
                "update", "uninstall"].contains(words.first ?? "") ||
                (words.first == "workspace" && ["init", "open"].contains(words.dropFirst().first ?? "")) ||
                (words.first == "config" && words.last == "machine")) {
                throw Options.usage("--profile applies to an already selected workspace's portable presentation settings.")
            }
            let packageRoot = WorkbenchProductionTrust.homebrewRoot()
            if words.first == "package" {
                guard [["package", "deactivate"], ["package", "rearm"]].contains(words), let packageRoot,
                      options.workspace == nil, options.home == nil, options.runtime == nil else {
                    throw Options.usage("Package deactivation requires the installed Homebrew package and fixed user paths.")
                }
                let package = try WorkbenchPackageLifecycle.checked {
                    try WorkbenchPackageLifecycle.context(root: packageRoot, options: options)
                }
                if words.last == "rearm" {
                    try WorkbenchPackageLifecycle.checked { try package.rearm() }
                    presentation.success(["status": "installed"], human: "Homebrew package ready; its service starts on first use.")
                    return 0
                }
                let interrupted = try WorkbenchPackageLifecycle.checked { try package.deactivate() }
                presentation.success(["status": "deactivated", "interruptedJobIDs": interrupted,
                    "preservedUserData": true], human: "Deactivated the package service. User data and workspaces are preserved.")
                return 0
            }
            if packageRoot != nil, ["install", "update", "uninstall"].contains(words.first ?? "") {
                throw CommandFailure("managed_by_homebrew", "Homebrew owns this Screenpunk installation.", 2,
                    nextActions: ["Use brew upgrade --cask screenpunk-cli or brew uninstall --cask screenpunk-cli."])
            }
            if packageRoot != nil, words == ["service", "run", "--foreground"], !serviceExecutable {
                throw Options.usage("Use screenpunk service start for the Homebrew-managed user service.")
            }
            if let packageRoot, words == ["service", "logs"] {
                _ = try WorkbenchProductionTrust.verifyPackage(packageRoot)
                let paths = InstallationPaths(home: FileManager.default.homeDirectoryForCurrentUser)
                let log = try WorkbenchLifecycleCLI.sanitizedLog(at: paths.machineState.appendingPathComponent("Logs/service.log"))
                presentation.success(["state": log.state, "events": log.events,
                    "redactedLineCount": log.redactedLineCount, "truncated": log.truncated],
                    human: log.events.joined(separator: "\n") + "\nRedacted lines: \(log.redactedLineCount).")
                return 0
            }
            if ["install", "update", "uninstall"].contains(words.first ?? "") {
                let context = try lifecycleContext ?? .production(options: options, environment: environment)
                try WorkbenchLifecycleCLI.run(words: words, context: context, presentation: presentation)
                return 0
            }
            if words.count == 2, words[0] == "service",
               ["enable", "disable"].contains(words[1]) {
                let context = try lifecycleContext ?? .production(options: options, environment: environment)
                try WorkbenchLifecycleCLI.serviceToggle(words[1], context: context,
                    presentation: presentation)
                return 0
            }
            if words == ["service", "logs"] {
                let context = try lifecycleContext ?? .production(options: options, environment: environment)
                try WorkbenchLifecycleCLI.serviceLogs(context: context, presentation: presentation)
                return 0
            }
            let runtime = try options.runtimeURL()
            let requestTimeout = words.first == "migration" && options.timeout == 10 ? 120 : options.timeout
            let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime, limits: WorkbenchIPCLimits(timeout: requestTimeout))
            let cancellation = SignalCancellation()
            currentCancellation = cancellation
            defer { cancellation.finish() }
            let machineRoot = runtime.appendingPathComponent("machine").path
            let documents = CLIWorkspaceDocuments(environment: environment)
            let workspace = try WorkspaceStore(documents: documents, machineRootPath: machineRoot)
            if words == ["mcp", "serve"] {
                if let packageRoot { try WorkbenchPackageLifecycle.context(root: packageRoot, options: options).start() }
                try WorkbenchMCPBridge.run(environment: broker, home: options.homeURL())
                return 0
            }
            if words == ["service", "run", "--foreground"] {
                let releaseTrust = serviceExecutable
                    ? try WorkbenchProductionTrust.installedServiceTrust(options: options) : nil
                let home = options.homeURL()
                let guiVerifier = try WorkbenchGUIVerifierPolicy.verifier(
                    executable: serviceExecutable, home: home, runtime: runtime,
                    environment: environment)
                let host = try WorkbenchServiceHost(broker: broker, home: home,
                    documents: documents, guiVerifier: guiVerifier, installedReleaseTrust: releaseTrust,
                    onShutdown: { cancellation.requestStop() })
                defer { host.stop() }
                presentation.diagnostic("Screenpunk workbench broker ready; Ctrl-C stops this foreground service.")
                cancellation.wait()
                host.stop()
                if cancellation.signalNumber == SIGINT { throw cancelled() }
                presentation.success(["status": "stopped"], human: "Service stopped.")
                return 0
            }
            if words == ["service", "start"] {
                try startService(options: options, environment: environment, broker: broker)
                presentation.success(["status": "ready"], human: "Service ready.")
                return 0
            }
            if words == ["service", "restart"] {
                do { try stopService(options: options, broker: broker) }
                catch let error as WorkbenchIPCError where error.code == .unavailable { }
                try startService(options: options, environment: environment, broker: broker)
                presentation.success(["status": "ready"], human: "Service restarted.")
                return 0
            }
            if words == ["service", "stop"] {
                try stopService(options: options, broker: broker)
                presentation.success(["status": "stopped"], human: "Service stopped.")
                return 0
            }
            if words.first == "agent" {
                try agent(words: words, options: options, broker: broker, presentation: presentation)
                return 0
            }
            let scope = brokerCredentialScope(for: words)
            let client = WorkbenchBrokerClient(environment: broker, credentialScope: scope)
            defer { client.close() }
            do { try client.connect() }
            catch let error as WorkbenchIPCError where error.code == .unavailable &&
                ((packageRoot != nil && ![["service", "status"], ["service", "lifecycle"], ["doctor"]].contains(words)) ||
                 words.first == "setup" || (words.first == "workspace" && ["init", "open"].contains(words.dropFirst().first ?? ""))) {
                try startService(options: options, environment: environment, broker: broker)
                try client.connect()
            }
            try requireHome(client: client, options: options)
            if cancellation.signalNumber != nil { throw cancelled() }
            if words.first == "config" {
                try machineConfig(words, client: client, workspace: workspace,
                    presentation: presentation)
                return 0
            }
            if words.first == "diagnostics" {
                try WorkbenchDiagnosticsCLI.export(words: words, client: client,
                    presentation: presentation)
                return 0
            }
            if words == ["toolchain", "list"] {
                let value = try client.toolchainRequirements()
                let human = value.trust == "authenticated"
                    ? "Authenticated catalog: \(value.installed?.count ?? 0) of \(value.required.count) required authoring kits installed and verified."
                    : (value.required.isEmpty
                        ? "This workspace has no pinned authoring kits. Production catalog trust is not registered."
                        : "This workspace requires \(value.required.count) pinned authoring kit(s). Installation and trust have not been assessed.")
                presentation.success(try object(value), human: human)
                return 0
            }
            if words == ["toolchain", "install", "--required"] {
                let value = try client.toolchainRequirements()
                if value.required.isEmpty {
                    presentation.success(["required": 0, "installed": 0,
                        "trust": "not_registered"],
                        human: "No pinned authoring kits are required by this workspace.")
                    return 0
                }
                guard value.trust == "authenticated" else {
                    throw CommandFailure("toolchain_trust_not_registered",
                        "Exact kit installation requires an independently registered release catalog, signer and publisher identity.", 8,
                        nextActions: ["Keep the workspace pins unchanged and install only after the production trust anchor is registered."],
                        details: ["required": String(value.required.count)])
                }
                let installed: WorkbenchToolchainInstallResult
                do {
                    installed = try client.installRequiredToolchains(
                        expectedWorkspaceId: value.workspaceId,
                        expectedSelectionGeneration: value.selectionGeneration)
                } catch let error as WorkbenchIPCError where
                    [.disconnected, .timedOut, .unavailable].contains(error.code) {
                    throw CommandFailure("outcome_unknown",
                        "Kit installation lost its broker reply; one or more verified kits may already be installed.", 7,
                        nextActions: ["Inspect toolchain list for exact installed pins before another installation attempt."],
                        details: ["workspaceId": value.workspaceId,
                                  "selectionGeneration": String(value.selectionGeneration)])
                } catch let error as WorkbenchIPCError {
                    throw CommandFailure("toolchain_install_incomplete",
                        "Not all required kits were confirmed installed (\(error.code.rawValue)). Earlier exact pins may have been installed.",
                        error.code == .resourceLimit ? 11 : 8,
                        nextActions: ["Inspect toolchain list for exact verified pins and correct the failing trust or capacity condition before retrying."],
                        details: ["workspaceId": value.workspaceId,
                                  "selectionGeneration": String(value.selectionGeneration)])
                }
                do {
                    try presentation.checkedSuccess(try object(installed),
                        human: "Installed and reverified \(installed.installed.count) required authoring kit(s).")
                } catch {
                    throw CommandFailure("toolchain_install_applied_display_failed",
                        "The required kits were installed and reverified, but the receipt could not be displayed.", 6,
                        nextActions: ["Inspect toolchain list before another installation attempt."],
                        details: ["workspaceId": installed.workspaceId])
                }
                return 0
            }
            if words == ["service", "status"] || words == ["doctor"] {
                let snapshot = try client.health()
                var result = try object(snapshot)
                var human = "Service: \(TerminalPresentation.safe(snapshot.status))\nWorkspace: \(TerminalPresentation.safe(snapshot.workspaceState))\nBuild: unavailable\nDevices: native operations on explicit request\nScreenshots: unavailable"
                if words == ["doctor"] {
                    let selected = try? client.workspaceStatus()
                    let coverage = selected?.state == "selected" ? try? client.workspaceCoverage() : nil
                    let lifecycle = try? client.serviceLifecycle()
                    result["workspaceCoverage"] = coverage.map { $0.complete ? "complete" : "incomplete" } ??
                        (selected == nil ? "unavailable" : "unconfigured")
                    result["workspaceEvidence"] = [
                        "state": selected?.state ?? "unavailable",
                        "path": selected?.path ?? "",
                        "workspaceId": selected?.workspaceId ?? "",
                        "externalProjectCount": selected?.externalProjectCount ?? 0,
                        "missingPaths": Array((coverage?.missingPaths ?? []).prefix(32)),
                        "unresolvedExternalProjectIds": Array((coverage?.unresolvedExternalProjectIds ?? []).prefix(32))
                    ] as [String: Any]
                    result["serviceEvidence"] = [
                        "state": lifecycle?.state ?? "unavailable",
                        "activeJobCount": lifecycle?.activeJobIDs.count ?? 0,
                        "guiConsumersKnown": lifecycle?.guiConsumersKnown ?? false,
                        "apiVersion": snapshot.apiVersion,
                        "controllerHomePath": snapshot.controllerHomePath ?? ""
                    ] as [String: Any]
                    let authoringRoute = snapshot.supportedMethods.contains(
                        WorkbenchAuthoringRecoveryMethod.buildRun.rawValue)
                    result["build"] = authoringRoute ? "route_available_kit_unverified" : "route_unavailable"
                    let native = try? client.nativeDoctor()
                    let requirements = try? client.toolchainRequirements()
                    result["dependencies"] = [
                        "authoringRoute": authoringRoute ? "available" : "unavailable",
                        "authoringKit": requirements?.trust == "authenticated" &&
                            requirements?.installation == "complete" &&
                            requirements?.required.isEmpty == false ? "installed_exact_pins" : "not_verified",
                        "trustedReleaseCatalog": requirements?.trust ?? "not_assessed"
                    ]
                    if let requirements {
                        result["toolchainRequirements"] = [
                            "count": requirements.required.count,
                            "trust": requirements.trust,
                            "installation": requirements.installation,
                            "installedCount": requirements.installed?.count ?? 0
                        ] as [String: Any]
                    }
                    result["identity"] = native?.identityState ?? "unknown"
                    result["identityPersistence"] = native?.identityPersistence ?? "not_assessed"
                    result["identityEvidence"] = native == nil
                        ? "Broker owner observation unavailable."
                        : "Current broker in-memory identity only; persistent Keychain identity was not assessed."
                    result["networkTransport"] = native?.networkTransport ?? "unknown"
                    result["networkAuthorization"] = native?.networkAuthorization.rawValue ?? "not_assessed"
                    result["networkEvidence"] = native == nil
                        ? "Broker owner observation unavailable; Local Network authorization was not assessed."
                        : "Broker transport attachment is observed in memory; Local Network authorization requires a separate read-only source."
                    result["screenshotAvailability"] = snapshot.screenshots
                    human += "\nWorkspace coverage: \(result["workspaceCoverage"]!)\nAuthoring: \(result["build"]!)\nIdentity: \(result["identity"]!)\nNetwork authorization: \(result["networkAuthorization"]!)"
                }
                presentation.success(result, human: human)
                return 0
            }
            if words == ["service", "lifecycle"] || words == ["service", "drain"] {
                let result = try words.last == "drain" ? client.drainService() : client.serviceLifecycle()
                let human = words.last == "drain"
                    ? "Service drained. Interrupted jobs: \(result.interruptedJobIDs.count)."
                    : "Service: \(result.state). Active jobs: \(result.activeJobIDs.count). GUI consumer evidence: \(result.guiConsumersKnown ? "verified" : "unknown")."
                presentation.success(try object(result), human: human)
                return 0
            }
            if words == ["operation", "list"] {
                let listed = try client.operationInventory()
                presentation.success(try object(listed), human:
                    "Observed \(listed.entries.count) operation(s) across workspace copies and the local deployment ledger. " +
                    "Each entry reports its durability; this inventory is incomplete across all operation domains.")
                return 0
            }
            if words == ["workspace", "operation-list"] {
                let listed = try client.workspaceOperationList()
                presentation.success(try object(listed), human:
                    "Current broker: \(listed.operations.count) observed workspace-copy operation(s). " +
                    "This process-local inventory is incomplete after a restart.")
                return 0
            }
            if words.count == 3 && words[0] == "operation" &&
                ["show", "cancel"].contains(words[1]) {
                let entry: WorkbenchOperationEntry
                do {
                    entry = try client.operationEntry(operationId: words[2],
                        requestCancel: words[1] == "cancel")
                } catch let error as WorkbenchIPCError where error.code == .unavailable ||
                    error.code == .disconnected {
                    throw CommandFailure("operation_status_unavailable",
                        "No observed operation record is available; the outcome may be unknown.", 7,
                        nextActions: ["Inspect the exact destination or device state before retrying."],
                        details: ["operationId": words[2]])
                }
                let human = "Operation \(entry.operationId): \(entry.kind), \(entry.state), " +
                    "\(entry.durability)" +
                    (entry.cancellationRequested ? ", cancellation requested" : "") + "."
                presentation.success(try object(entry), human: human)
                return 0
            }
            if words.count == 3 && words[0] == "workspace" &&
                ["operation-status", "operation-cancel"].contains(words[1]) {
                let status: WorkbenchWorkspaceOperationStatus
                do {
                    status = try ["operation-cancel", "cancel"].contains(words[1])
                        ? client.requestWorkspaceOperationCancel(operationId: words[2])
                        : client.workspaceOperationStatus(operationId: words[2])
                }
                catch let error as WorkbenchIPCError where error.code == .unavailable ||
                    error.code == .disconnected {
                    throw CommandFailure("operation_status_unavailable",
                        "The current broker has no live record for this operation. Its outcome is unknown.", 7,
                        nextActions: ["Inspect the exact destination and original workspace before another attempt. A broker restart loses live progress records."],
                        details: ["operationId": words[2]])
                }
                let human = "Operation \(status.operationId): \(status.state), \(status.phase)" +
                    (status.cancellationRequested ? ", cancellation requested" : "") + ". " +
                    "Files \(status.copiedFiles)/\(status.totalFiles), " +
                    "bytes \(status.copiedBytes)/\(status.totalBytes). " +
                    "Destination: \(status.destination)"
                presentation.success(try object(status), human: human)
                return 0
            }
            let active = try client.workspaceStatus()
            var completedLongWorkspaceMutation = false
            if let asserted = options.workspace, !["setup", "workspace"].contains(words.first ?? ""),
               active.path != WorkspacePath.canonical(asserted) {
                throw CommandFailure("workspace_not_selected", "The asserted workspace is not selected.", 6,
                    nextActions: ["Use screenpunk workspace open PATH to select it explicitly."])
            }
            let profile = try options.profile.map {
                try WorkbenchCLIProfile.resolve($0, selected: active, client: client)
            }
            if let watchedProject = try WorkbenchBuildWatchCLI.projectId(words) {
                try WorkbenchBuildWatchCLI.run(projectId: watchedProject, selected: active,
                    client: client, presentation: presentation,
                    cancelled: { cancellation.signalNumber != nil })
                return 0 // Stopping the foreground watcher leaves broker and packages intact.
            }
            if words.prefix(2).elementsEqual(["migration", "apply"]) {
                guard words.count == 3 else { throw Options.usage("migration apply requires PLAN_ID [--approved].") }
                try WorkbenchAuthoringRecoveryCLI.applyMigration(id: words[2],
                    approved: options.approved, noInput: options.noInput,
                    client: client, presentation: presentation, openTTY: localReviewTTY)
            } else if words.dropFirst().first == "edit-local", words.first == "project" {
                guard words.count == 4, !options.noInput else {
                    throw Options.usage("project edit-local requires PROJECT_ID RELATIVE_PATH and an interactive editor.")
                }
                try WorkbenchLocalEditorCLI.run(projectId: words[2], path: words[3],
                    selected: active, client: client, presentation: presentation,
                    environment: environment)
            } else if words == ["screen", "history"] {
                try WorkbenchAuthoringRecoveryCLI.presentCompleteHistory(client: client,
                    selected: active, with: presentation)
            } else if words.first == "screen",
                      let verb = words.dropFirst().first,
                      WorkbenchScreenMutationCLI.verbs.contains(verb) {
                try WorkbenchScreenMutationCLI.run(words: words, inputFile: options.inputFile,
                    client: client, presentation: presentation)
            } else if words.first == "screen", ["import", "import-package"].contains(words.dropFirst().first ?? "") {
                guard words.count == 3 else { throw Options.usage("screen import-package requires ABSOLUTE_PACKAGE_DIRECTORY.") }
                try WorkbenchPackageImportCLI.run(directory: words[2], selected: active,
                    client: client, presentation: presentation)
                completedLongWorkspaceMutation = true
            } else if let route = try WorkbenchAuthoringRecoveryCLI.route(words) {
                var params = route.params
                if route.method != .migrationPlan && route.method != .migrationReview,
                   let id = active.workspaceId,
                   let generation = active.selectionGeneration {
                    params["expectedWorkspaceId"] = id
                    params["expectedSelectionGeneration"] = generation
                }
                let longWorkspaceMutation = route.method == .snapshotCreate ||
                    route.method == .workspaceRelocate
                let operationId = longWorkspaceMutation ? UUID().uuidString.lowercased() : nil
                if let operationId {
                    FileHandle.standardError.write(Data(
                        "Workspace operation ID: \(operationId)\n".utf8))
                }
                let result: WorkbenchAuthoringRecoveryResult
                do { result = try client.performAuthoring(method: route.method,
                    params: params, operationId: operationId) }
                catch let error as WorkbenchIPCError where longWorkspaceMutation &&
                    [.disconnected, .timedOut, .publicationOutcomeUnknown].contains(error.code) {
                    let destination = params["path"] as? String ?? ""
                    throw CommandFailure("outcome_unknown",
                        "The workspace operation lost its broker reply; publication or selection may have completed.", 7,
                        nextActions: ["Inspect screenpunk workspace operation-status \(operationId ?? "") while the same broker is running, then the exact destination and original workspace before another attempt. For a large backup, stop the service and use the quiesced folder-copy procedure."],
                        details: ["destination": destination, "operationId": operationId ?? ""])
                }
                catch let error as WorkbenchIPCError where route.method == .packageExport &&
                    packageExportOutcomeUnknown(error) {
                    throw packageExportUncertainFailure(destination: params["path"] as? String ?? "")
                }
                catch let error as WorkbenchIPCError where
                    [.projectClone, .projectUnregister, .projectRelocateContained,
                     .projectUpgradeKit].contains(route.method) &&
                    [.disconnected, .timedOut, .publicationOutcomeUnknown].contains(error.code) {
                    let clone = route.method == .projectClone
                    let relocate = route.method == .projectRelocateContained
                    let kit = route.method == .projectUpgradeKit
                    throw CommandFailure("outcome_unknown",
                        clone ? "Project clone lost its broker reply; a new registered source may already exist." :
                            (relocate ? "Project relocation lost its broker reply; the catalog location may have changed." :
                                (kit ? "Kit upgrade lost its broker reply; source and pinned requirements may have changed." :
                                    "Project unregistration lost its broker reply; the catalog change may have completed.")), 7,
                        nextActions: ["Inspect project source, catalog and pinned requirements before another attempt."],
                        details: ["projectId": params["projectId"] as? String ?? "",
                                  "destination": params["relativeDestination"] as? String ?? ""])
                }
                if longWorkspaceMutation {
                    do {
                        try WorkbenchAuthoringRecoveryCLI.present(result, for: route.method,
                            with: presentation, checkedOutput: true)
                        completedLongWorkspaceMutation = true
                    } catch {
                        throw CommandFailure("operation_applied_display_failed",
                            "The workspace operation completed, but its result could not be displayed.", 6,
                            nextActions: ["Inspect the destination and selected workspace before another attempt."],
                            details: ["destination": params["path"] as? String ?? "",
                                      "operationId": operationId ?? ""])
                    }
                } else if [.packageExport, .projectClone, .projectUnregister,
                           .projectRelocateContained, .projectUpgradeKit].contains(route.method) {
                    do {
                        try WorkbenchAuthoringRecoveryCLI.present(result, for: route.method,
                            with: presentation, checkedOutput: true)
                        completedLongWorkspaceMutation = true
                    } catch {
                        let exported = route.method == .packageExport
                        let clone = route.method == .projectClone
                        let relocate = route.method == .projectRelocateContained
                        let kit = route.method == .projectUpgradeKit
                        throw CommandFailure("operation_applied_display_failed",
                            exported ? "The package export completed, but its result could not be displayed." :
                                (clone ? "Project clone completed, but its result could not be displayed." :
                                    (relocate ? "Project relocation completed, but its result could not be displayed." :
                                        (kit ? "Kit upgrade completed, but its result could not be displayed." :
                                            "Project unregistration completed, but its result could not be displayed."))), 6,
                            nextActions: exported
                                ? ["Inspect the exact destination before another export attempt."]
                                : ["Inspect project list and source folders before another attempt."],
                            details: exported
                                ? ["destination": params["path"] as? String ?? ""]
                                : ["projectId": params["projectId"] as? String ?? "",
                                   "destination": params["relativeDestination"] as? String ?? ""])
                    }
                } else {
                    try WorkbenchAuthoringRecoveryCLI.present(result, for: route.method,
                        with: presentation, profile: profile)
                }
            } else if words.first == "deploy" {
                try WorkbenchDeploymentCLI.run(words: words, options: options, client: client,
                    selected: active, presentation: presentation, openTTY: localReviewTTY)
            } else if words.first == "setup" || words.first == "workspace" {
                try workspaceCommand(words: words, options: options, store: workspace, active: active, client: client, presentation: presentation)
            } else if words.first == "project" {
                try projectCommand(words: words, active: active, client: client, presentation: presentation)
            } else if words.first == "screen" {
                try screenCommand(words: words, client: client, presentation: presentation)
            } else if words.first == "device" {
                try deviceCommand(words: words, options: options, client: client, presentation: presentation)
            } else if words.first == "connection" || words.first == "approval" {
                try connectionCommand(words: words, options: options, client: client,
                                      presentation: presentation, localReviewTTY: localReviewTTY,
                                      localSecretInput: localSecretInput)
            } else if ["toolchain", "mcp"].contains(words.first ?? "") {
                throw unavailable()
            } else { throw Options.usage("Unknown command. Use screenpunk help.") }
            if let failure = postDispatchCancellationFailure(
                signalReceived: cancellation.signalNumber != nil,
                mutationApplied: completedLongWorkspaceMutation) { throw failure }
            return 0
        } catch let failure as CommandFailure { presentation.failure(failure); return failure.exitStatus }
        catch let error as WorkbenchPackageRemovalRefusal {
            let failure = WorkbenchPackageLifecycle.failure(error)
            presentation.failure(failure); return failure.exitStatus
        }
        catch let error as PackageNotReady {
            let failure = CommandFailure("homebrew_package_not_ready",
                error == .removalPending ? "Homebrew is removing this package; service startup is blocked."
                    : "Homebrew has not committed both command artifacts for this package.", 9,
                nextActions: ["Wait for the current Brew operation to finish. If it failed, retry it or run brew reinstall --cask screenpunk-cli."])
            presentation.failure(failure); return failure.exitStatus
        }
        catch let error as PackagePreparationFailure {
            let failure = WorkbenchPackageLifecycle.failure(error)
            presentation.failure(failure); return failure.exitStatus
        }
        catch let error as PackageActivationFailure {
            let failure = WorkbenchPackageLifecycle.failure(error)
            presentation.failure(failure); return failure.exitStatus
        }
        catch let error as DistributionError {
            let failure = WorkbenchLifecycleCLI.failure(error)
            presentation.failure(failure); return failure.exitStatus
        }
        catch let error as WorkbenchIPCError {
            let failure = currentCancellation?.signalNumber != nil ? cancelled() : ipcFailure(error)
            presentation.failure(failure); return failure.exitStatus
        }
        catch let error as WorkspaceError { let failure = workspaceFailure(error); presentation.failure(failure); return failure.exitStatus }
        catch { let failure = CommandFailure("runtime_unavailable", "The workbench request could not complete.", 9); presentation.failure(failure); return failure.exitStatus }
    }

    private static func workspaceCommand(words: [String], options: Options, store: WorkspaceStore,
                                         active: WorkbenchWorkspaceStatus, client: WorkbenchBrokerClient,
                                         presentation: Presentation) throws {
        let verb = words.first == "setup" ? "setup" : (words.count > 1 ? words[1] : "show")
        switch verb {
        case "setup":
            guard words == ["setup"] else { throw Options.usage("setup accepts --workspace PATH.") }
            if let requested = options.workspace {
                let path = WorkspacePath.canonical(requested)
                let selected = try (FileManager.default.fileExists(atPath: path) ? client.openWorkspace(path: path) : client.initializeWorkspace(path: path))
                try presentWorkspace(selected, presentation: presentation)
            } else if active.state == "selected" {
                try presentWorkspace(active, presentation: presentation)
            } else {
                let path = try store.proposedPath()
                guard !FileManager.default.fileExists(atPath: path) else {
                    throw CommandFailure("workspace_conflict", "The proposed workspace path already exists; open or choose it explicitly.", 6)
                }
                try presentWorkspace(client.initializeWorkspace(path: path), presentation: presentation)
            }
        case "init", "open":
            guard words.count <= 3, words.count >= 2 else { throw Options.usage("workspace \(verb) accepts one path.") }
            let supplied = words.count == 3 ? words[2] : options.workspace
            if verb == "open" && supplied == nil { throw Options.usage("workspace open requires PATH.") }
            if let supplied, !WorkspacePath.isAbsolute(supplied) { throw Options.usage("Workspace path must be absolute.") }
            let selected = try verb == "init" ? client.initializeWorkspace(path: supplied.map(WorkspacePath.canonical)) : client.openWorkspace(path: WorkspacePath.canonical(supplied!))
            try presentWorkspace(selected, presentation: presentation)
        case "show", "path", "validate", "coverage":
            guard words.count == 2 else { throw Options.usage("workspace \(verb) takes no operands.") }
            guard active.state == "selected", let path = active.path else { throw CommandFailure("workspace_unavailable", "No workspace is selected.", 6) }
            if let asserted = options.workspace, WorkspacePath.canonical(asserted) != path {
                throw CommandFailure("workspace_not_selected", "The asserted workspace is not selected.", 6)
            }
            if verb == "path" { presentation.success(["path": path], human: TerminalPresentation.safe(path)); return }
            if verb == "show" { presentation.success(try object(active), human: "Workspace: \(TerminalPresentation.safe(path))"); return }
            let detail = try client.workspaceCoverage(validate: verb == "validate")
            presentation.success(try object(detail), human: "Workspace: \(TerminalPresentation.safe(path))\nCoverage: \(detail.complete ? "complete" : "incomplete")\n\(TerminalPresentation.safe(detail.notice))")
        default: throw unavailable()
        }
    }

    private static func projectCommand(words: [String], active: WorkbenchWorkspaceStatus, client: WorkbenchBrokerClient,
                                       presentation: Presentation) throws {
        guard words.count >= 2 else { throw Options.usage("project requires a subcommand.") }
        guard active.state == "selected" else { throw CommandFailure("workspace_unavailable", "No workspace is selected.", 6) }
        switch words[1] {
        case "list":
            guard words.count == 2 else { throw Options.usage("project list takes no operands.") }
            let projects = try client.listProjects()
            presentation.success(["projects": try projects.map(object), "count": projects.count], human: projects.isEmpty ? "No registered projects." : projects.map { "\($0.projectId)  \(TerminalPresentation.safe($0.name))" }.joined(separator: "\n"))
        case "show", "path":
            guard words.count == 3 else { throw Options.usage("project \(words[1]) requires PROJECT_ID.") }
            guard try client.listProjects().contains(where: { $0.projectId == words[2] }) else { throw CommandFailure("project_not_found", "No registered project has that ID.", 6) }
            let project = try client.getProject(words[2])
            if words[1] == "show" { presentation.success(try object(project), human: "\(TerminalPresentation.safe(project.name))  \(project.projectId)"); return }
            let path = try client.projectPath(project.projectId)
            presentation.success(["projectId": project.projectId, "path": path], human: TerminalPresentation.safe(path))
        case "versions":
            guard words.count == 3 else { throw Options.usage("project versions requires PROJECT_ID.") }
            let values = try client.projectVersions(words[2])
            presentation.success(["projectId": words[2], "versions": try values.map(object), "count": values.count],
                human: values.isEmpty ? "No source versions." : values.map { $0.sourceVersion }.joined(separator: "\n"))
        case "source":
            guard words.count == 4 else { throw Options.usage("project source requires PROJECT_ID RELATIVE_PATH.") }
            guard let workspaceId = active.workspaceId,
                  let generation = active.selectionGeneration else {
                throw CommandFailure("workspace_unavailable", "No workspace is selected.", 6)
            }
            let source = try client.sourceText(projectId: words[2], path: words[3],
                expectedWorkspaceId: workspaceId, expectedSelectionGeneration: generation)
            let encoded = try JSONEncoder().encode(source)
            presentation.success(try object(source), human: String(decoding: encoded, as: UTF8.self))
        case "source-chunk":
            guard words.count == 6, let offset = Int(words[5]),
                  let workspaceId = active.workspaceId,
                  let generation = active.selectionGeneration else {
                throw Options.usage("project source-chunk requires PROJECT_ID RELATIVE_PATH SOURCE_VERSION OFFSET.")
            }
            let chunk = try client.sourceChunk(projectId: words[2], path: words[3],
                expectedSourceVersion: words[4], offset: offset,
                expectedWorkspaceId: workspaceId, expectedSelectionGeneration: generation)
            presentation.success(try object(chunk),
                human: String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self))
        default: throw unavailable()
        }
    }

    private static func screenCommand(words: [String], client: WorkbenchBrokerClient, presentation: Presentation) throws {
        guard words.count >= 2 else { throw Options.usage("screen requires a subcommand.") }
        switch words[1] {
        case "list":
            guard words.count == 2 else { throw Options.usage("screen list takes no operands.") }
            let values = try client.listPackages()
            presentation.success(["screens": try values.map(object), "count": values.count], human: values.isEmpty ? "No cached screens." : values.map { "\($0.dashboardId)  \(TerminalPresentation.safe($0.name))" }.joined(separator: "\n"))
        case "show", "validate":
            guard words.count == 3 else { throw Options.usage("screen \(words[1]) requires DASHBOARD_ID.") }
            let value = try words[1] == "show" ? client.getPackage(dashboardId: words[2]) : client.validatePackage(dashboardId: words[2])
            presentation.success(try object(value), human: "\(TerminalPresentation.safe(value.name))  \(value.dashboardId)  \(value.integrity)")
        default: throw unavailable()
        }
    }

    private static func deviceCommand(words: [String], options: Options, client: WorkbenchBrokerClient, presentation: Presentation) throws {
        guard words.count >= 2 else { throw Options.usage("device requires a subcommand.") }
        switch words[1] {
        case "logs":
            guard words.count == 3 else { throw Options.usage("device logs requires DEVICE_ID.") }
            let value = try client.deviceLogs(deviceId: words[2])
            presentation.success(try object(value), human:
                "\(value.events.count) broker-observed event(s) for \(TerminalPresentation.safe(value.deviceId)); complete history unavailable.")
        case "discover":
            guard words.count == 2 else { throw Options.usage("device discover takes no operands.") }
            let values = try client.discoverDevices()
            presentation.success(["devices": try values.map(object), "count": values.count],
                human: values.isEmpty ? "No devices discovered." : values.map { "\($0.id)  \(TerminalPresentation.safe($0.name ?? "Device"))" }.joined(separator: "\n"))
        case "add":
            guard words.count == 2, let host = options.host, let port = options.port else { throw Options.usage("device add requires --host HOST --port PORT.") }
            let value = try client.addDevice(host: host, port: port)
            presentation.success(try object(value), human: "Endpoint added: \(TerminalPresentation.safe(value.name ?? "Device"))  \(value.id)")
        case "pair":
            guard words.count <= 3 else { throw Options.usage("device pair accepts DEVICE_ID or --host HOST --port PORT.") }
            let value: WorkbenchPairingRead
            if words.count == 3 { value = try client.beginPairing(deviceId: words[2]) }
            else if let host = options.host, let port = options.port { value = try client.beginPairing(host: host, port: port) }
            else { throw Options.usage("device pair requires DEVICE_ID or --host HOST --port PORT.") }
            presentation.success(try object(value), human: "Pairing \(value.pendingId) with \(TerminalPresentation.safe(value.deviceName))\nCompare the device and controller pins, then the matching code on the device.\nDevice pin: \(value.devicePinHex)\nController pin: \(value.controllerPinHex)\nMatching code: \(value.matchingCode)\nAfter confirming on the device, run device pairing confirm \(value.pendingId).")
        case "pairing":
            guard words.count >= 3 else { throw Options.usage("device pairing requires show, confirm or cancel.") }
            switch words[2] {
            case "show":
                guard words.count == 3 else { throw Options.usage("device pairing show takes no operands.") }
                let values = try client.pendingPairings()
                presentation.success(["pending": try values.map(object)], human: values.isEmpty ? "No pending pairings." : values.map { "\($0.pendingId)  \(TerminalPresentation.safe($0.deviceName))  \($0.matchingCode)" }.joined(separator: "\n"))
            case "confirm":
                guard words.count == 4 else { throw Options.usage("device pairing confirm requires PENDING_ID.") }
                let code = try localPairingCode(noInput: options.noInput)
                let device = try client.confirmPairing(pendingId: words[3], matchingCode: code)
                presentation.success(try object(device), human: "Paired: \(TerminalPresentation.safe(device.name))  \(device.deviceId)")
            case "cancel":
                guard words.count == 4 else { throw Options.usage("device pairing cancel requires PENDING_ID.") }
                try client.cancelPairing(pendingId: words[3])
                presentation.success(["cancelled": true, "pendingId": words[3]], human: "Pairing cancelled.")
            default: throw Options.usage("Unknown device pairing command.")
            }
        case "forget":
            guard words.count == 3 else { throw Options.usage("device forget requires DEVICE_ID.") }
            let removed = try client.forgetDevice(words[2])
            presentation.success(["deviceId": words[2], "forgotten": removed], human: removed ? "Local pairing forgotten; disconnect on the device separately." : "No local pairing found.")
        case "settings":
            guard words.count == 4 else { throw Options.usage("device settings get|set DEVICE_ID.") }
            if words[2] == "get" {
                let value = try client.deviceSettings(words[3])
                presentation.success(try object(value), human: "Settings revision: \(value.revision)\n\(TerminalPresentation.safe(String(decoding: try JSONEncoder().encode(value.value), as: UTF8.self)))")
            } else if words[2] == "set" {
                guard let path = options.inputFile, let revision = options.expectedRevision,
                      WorkspacePath.isAbsolute(path) else { throw Options.usage("device settings set requires --file ABSOLUTE_JSON --expected-revision REVISION.") }
                let url = URL(fileURLWithPath: path)
                let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
                guard let size, size.intValue <= 64 * 1024 else { throw Options.usage("Settings file exceeds 64 KiB.") }
                let settings = try JSONDecoder().decode(DeviceSettings.self, from: Data(contentsOf: url))
                try settings.validate()
                let value = try client.updateDeviceSettings(words[3], expectedRevision: revision, value: settings)
                presentation.success(try object(value), human: "Settings updated to revision \(value.revision).")
            } else { throw Options.usage("device settings get|set DEVICE_ID.") }
        case "connections":
            guard words.count == 4, words[2] == "list" else { throw Options.usage("device connections list DEVICE_ID.") }
            let value = try client.deviceConnections(words[3])
            presentation.success(try object(value), human: "Device connection inventory received.")
        case "screens":
            guard words.count == 3 else { throw Options.usage("device screens requires DEVICE_ID.") }
            let value = try client.freshDeviceScreenSet(deviceId: words[2])
            let entries = value.screens.map { entry in
                "\(entry.dashboardId)  \(entry.revision)\(entry.dashboardId == value.selectedDashboardId ? "  selected" : "")"
            }
            let human = "\(TerminalPresentation.safe(value.name))  \(value.deviceId)\nObserved: \(value.observedAt)\n"
                + (entries.isEmpty ? "No installed screens." : entries.joined(separator: "\n"))
            presentation.success(try object(value), human: human)
        case "list":
            guard words.count == 2 else { throw Options.usage("device list takes no operands.") }
            let values = try client.listDevices()
            presentation.success(["devices": try values.map(object), "count": values.count], human: values.isEmpty ? "No cached devices." : values.map { "\($0.deviceId)  \(TerminalPresentation.safe($0.name))  \($0.reachability)" }.joined(separator: "\n"))
        case "status":
            guard words.count == 3 || (words.count == 4 && words[3] == "--refresh") else { throw Options.usage("device status requires DEVICE_ID [--refresh].") }
            let value = try words.count == 4 ? client.deviceStatus(words[2], refresh: true) : client.getDevice(deviceId: words[2])
            presentation.success(try object(value), human: "\(TerminalPresentation.safe(value.name))  \(value.reachability)")
        default: throw unavailable()
        }
    }

    private static func localPairingCode(noInput: Bool) throws -> String {
        guard !noInput else { throw CommandFailure("confirmation_required", "Pairing confirmation needs local terminal input.", 7) }
        let fd = Darwin.open("/dev/tty", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw CommandFailure("confirmation_required", "Pairing confirmation needs a local terminal.", 7) }
        defer { Darwin.close(fd) }
        FileHandle.standardError.write(Data("Enter the matching code shown on the device: ".utf8))
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 32 && Darwin.read(fd, &byte, 1) == 1 {
            if byte == 10 || byte == 13 { break }
            bytes.append(byte)
        }
        guard let code = String(bytes: bytes, encoding: .utf8), !code.isEmpty else {
            throw CommandFailure("confirmation_required", "No matching code was entered.", 7)
        }
        return code
    }

    private static func connectionCommand(words: [String], options: Options,
                                          client: WorkbenchBrokerClient, presentation: Presentation,
                                          localReviewTTY: (() throws -> Int32)?,
                                          localSecretInput: (() throws -> Data)?) throws {
        guard words.count >= 2 else { throw Options.usage("connection requires a subcommand.") }
        if words[0] == "approval" {
            guard words.count == 3 else { throw Options.usage("approval show|approve|deny INTENT_ID.") }
            try connectionIntentCommand(verb: words[1], id: words[2],
                                        client: client, presentation: presentation,
                                        noInput: options.noInput, localReviewTTY: localReviewTTY)
            return
        }
        switch words[1] {
        case "home-assistant":
            guard words.count >= 3 else { throw Options.usage("connection home-assistant setup|status|cancel ...") }
            switch words[2] {
            case "setup":
                guard words.count == 7, !options.noInput, !options.approved else {
                    throw Options.usage("connection home-assistant setup DEVICE DASHBOARD REVISION ORIGIN requires controlling-terminal review; --secret-stdin may supply only the token.")
                }
                let review = try client.beginHomeAssistantReview(deviceId: words[3],
                    dashboardId: words[4], revision: words[5], origin: words[6])
                let accepted = try WorkbenchLocalApprovalTerminal.confirm(review, noInput: false,
                    openTTY: localReviewTTY ?? {
                        Darwin.open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOCTTY)
                    })
                guard accepted else {
                    throw CommandFailure("confirmation_declined", "Home Assistant setup review was declined.", 7)
                }
                let secret = try localSecretInput?() ?? localSecret(
                    stdin: options.secretStdin, noInput: false)
                do {
                    let attempt = try client.confirmHomeAssistantReview(review, secret: secret)
                    presentation.success(try object(attempt), human:
                        "Home Assistant installed for \(TerminalPresentation.safe(attempt.deviceId)) and revision \(TerminalPresentation.safe(attempt.revision)). Intent: \(attempt.intentId).")
                } catch let error as WorkbenchIPCError {
                    throw CommandFailure(error.code.rawValue, error.message, 7,
                        nextActions: ["Inspect connection home-assistant status \(review.intentId) before another setup. If the attempt is prepared or cleanup is pending, use connection home-assistant cancel \(review.intentId). An unknown device outcome must not be resent."],
                        details: ["intentId": review.intentId])
                }
            case "status", "cancel":
                guard words.count == 4, !options.secretStdin else {
                    throw Options.usage("connection home-assistant status|cancel INTENT_ID.")
                }
                let attempt = try words[2] == "status"
                    ? client.homeAssistantStatus(intentId: words[3])
                    : client.cancelHomeAssistantPrepared(intentId: words[3])
                presentation.success(try object(attempt), human:
                    "Home Assistant intent \(attempt.intentId): \(attempt.phase). Device: \(TerminalPresentation.safe(attempt.deviceId)).")
            default: throw Options.usage("Unknown Home Assistant command.")
            }
        case "configure", "request":
            guard words.count == 5, let path = options.inputFile, WorkspacePath.isAbsolute(path) else {
                throw Options.usage("connection configure|request DEVICE_ID DASHBOARD_ID REVISION --file ABSOLUTE_JSON.")
            }
            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
            guard let size, size.intValue <= 64 * 1024 else { throw Options.usage("Connection declaration exceeds 64 KiB.") }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let declaration = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(declaration.keys) == ["grant", "auth"],
                  let grantObject = declaration["grant"] as? [String: Any],
                  let authObject = declaration["auth"] as? [String: Any],
                  let grant = try? JSONDecoder().decode(ConnectionGrant.self, from: JSONSerialization.data(withJSONObject: grantObject)),
                  let auth = try? JSONDecoder().decode(ConnectionAuthBinding.self, from: JSONSerialization.data(withJSONObject: authObject)) else {
                throw Options.usage("Connection declaration must contain grant and auth objects.")
            }
            let intent: WorkbenchConnectionIntentView
            if words[1] == "request" {
                guard auth.placement == .none, !options.secretStdin else {
                    throw Options.usage("connection request accepts only an unauthenticated declaration without --secret-stdin.")
                }
                intent = try client.requestConnectionIntent(deviceId: words[2], dashboardId: words[3],
                    revision: words[4], grant: grant, auth: auth)
            } else {
                let secret = auth.placement == .none ? nil : try localSecret(stdin: options.secretStdin, noInput: options.noInput)
                intent = try client.configureConnection(deviceId: words[2], dashboardId: words[3],
                    revision: words[4], grant: grant, auth: auth, secret: secret)
            }
            presentation.success(try object(intent), human: "Connection intent \(intent.intentId)\nScope: \(TerminalPresentation.safe(intent.summary.alias)) at \(TerminalPresentation.safe(intent.summary.origin))\nDeclaration: \(intent.declarationHash)\nContext: \(intent.authorizationContextHash)\nReview and confirm on the controlling terminal with approval approve \(intent.intentId).")
        case "update":
            guard words.count == 4, let expected = Int(words[3]), expected > 0,
                  let path = options.inputFile, WorkspacePath.isAbsolute(path),
                  !options.secretStdin else {
                throw Options.usage("connection update BINDING_ID EXPECTED_GRANT_GENERATION --file ABSOLUTE_JSON (scope only; credential and endpoint unchanged).")
            }
            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
            guard let size, size.intValue <= 64 * 1024 else {
                throw Options.usage("Connection declaration exceeds 64 KiB.")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let declaration = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(declaration.keys) == ["grant", "auth"],
                  let grantObject = declaration["grant"] as? [String: Any],
                  let authObject = declaration["auth"] as? [String: Any],
                  let grant = try? JSONDecoder().decode(ConnectionGrant.self,
                      from: JSONSerialization.data(withJSONObject: grantObject)),
                  let auth = try? JSONDecoder().decode(ConnectionAuthBinding.self,
                      from: JSONSerialization.data(withJSONObject: authObject)),
                  grant.id.uuidString.lowercased() == words[2].lowercased(),
                  grant.authRef.isEmpty, auth.authRef.isEmpty else {
                throw Options.usage("Update declaration must contain the existing grant ID and empty credential references.")
            }
            let intent = try client.updateConnection(bindingId: words[2].lowercased(),
                expectedGrantGeneration: expected, grant: grant, auth: auth)
            presentation.success(try object(intent), human:
                "Connection update intent \(intent.intentId)\nExisting generation: \(expected)\nProposed scope: \(TerminalPresentation.safe(intent.summary.alias)) at \(TerminalPresentation.safe(intent.summary.origin))\nDeclaration: \(intent.declarationHash)\nReview on the controlling terminal with approval approve \(intent.intentId). The working credential remains active until confirmation.")
        case "list":
            guard words.count == 3 else { throw Options.usage("connection list DEVICE_ID.") }
            let values = try client.listConnections(deviceId: words[2])
            presentation.success(["connections": try values.map(object)], human: values.isEmpty ? "No local connection grants." : values.map { "\($0.bindingId)  \(TerminalPresentation.safe($0.alias))  \($0.localStatus)" }.joined(separator: "\n"))
        case "inspect", "describe", "test", "remove", "revoke":
            guard words.count == 3 else { throw Options.usage("connection \(words[1]) BINDING_ID.") }
            let value: WorkbenchConnectionSummary
            if words[1] == "test" { value = try client.testConnection(words[2]) }
            else if words[1] == "remove" { value = try client.removeConnection(words[2]) }
            else if words[1] == "revoke" { value = try client.revokeConnection(words[2]) }
            else { value = try client.inspectConnection(words[2]) }
            presentation.success(try object(value), human: "\(TerminalPresentation.safe(value.alias))  \(TerminalPresentation.safe(value.origin))\nLocal: \(value.localStatus)\nRemote revocation: \(value.remoteRevocation)")
        case "intent":
            guard words.count == 4 else { throw Options.usage("connection intent show|approve|deny INTENT_ID.") }
            try connectionIntentCommand(verb: words[2], id: words[3],
                                        client: client, presentation: presentation,
                                        noInput: options.noInput, localReviewTTY: localReviewTTY)
        default: throw Options.usage("Unknown connection command.")
        }
    }

    private static func connectionIntentCommand(verb: String, id: String,
                                                client: WorkbenchBrokerClient, presentation: Presentation,
                                                noInput: Bool, localReviewTTY: (() throws -> Int32)?) throws {
        guard ["show", "approve", "deny"].contains(verb) else { throw Options.usage("approval show|approve|deny INTENT_ID.") }
        if verb == "approve" {
            guard !noInput else { throw WorkbenchIPCError(.confirmationRequired) }
            let review = try client.beginConnectionReview(intentId: id)
            let accepted: Bool
            if let localReviewTTY {
                accepted = try WorkbenchLocalApprovalTerminal.confirm(review, noInput: false,
                    openTTY: localReviewTTY)
            } else {
                accepted = try WorkbenchLocalApprovalTerminal.confirm(review, noInput: false)
            }
            guard accepted else {
                throw CommandFailure("confirmation_declined", "The connection review was not approved.", 7)
            }
            let applied = try client.confirmConnectionReview(review)
            presentation.success(try object(applied), human: "Connection authorized for \(TerminalPresentation.safe(applied.summary.alias)); device receipt received.")
            return
        }
        let intent = try client.connectionIntent(id)
        if verb == "show" {
            presentation.success(try object(intent), human: "Intent: \(intent.intentId)  \(intent.state)\nDevice: \(intent.summary.deviceId)\nScope: \(TerminalPresentation.safe(intent.summary.alias))  \(TerminalPresentation.safe(intent.summary.origin))\nDeclaration: \(intent.declarationHash)\nContext: \(intent.authorizationContextHash)")
            return
        }
        let result = try client.resolveConnectionIntent(id, approve: verb == "approve")
        if let applied = result.applied {
            presentation.success(try object(applied), human: "Connection authorized for \(TerminalPresentation.safe(applied.summary.alias)); device receipt received.")
        } else {
            presentation.success(["intentId": id, "denied": true], human: "Connection intent denied.")
        }
    }

    private static func localSecret(stdin: Bool, noInput: Bool) throws -> Data {
        guard stdin || !noInput else { throw CommandFailure("credential_required", "Credential input requires a terminal or --secret-stdin.", 7) }
        let fd = stdin ? STDIN_FILENO : Darwin.open("/dev/tty", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw CommandFailure("credential_required", "No private credential input is available.", 7) }
        defer { if !stdin { Darwin.close(fd) } }
        return try readSecret(fd: fd, prompt: !stdin)
    }

    static func readSecret(fd: Int32, prompt: Bool) throws -> Data {
        var original = termios()
        let hasTTY = isatty(fd) == 1 && tcgetattr(fd, &original) == 0
        if hasTTY {
            var hidden = original
            hidden.c_lflag &= ~tcflag_t(ECHO)
            guard tcsetattr(fd, TCSANOW, &hidden) == 0 else { throw CommandFailure("credential_required", "Cannot protect terminal credential input.", 7) }
        }
        defer { if hasTTY { _ = tcsetattr(fd, TCSANOW, &original) } }
        if prompt { FileHandle.standardError.write(Data("Credential (input hidden): ".utf8)) }
        var bytes: [UInt8] = [], byte: UInt8 = 0
        while bytes.count <= 8192 && Darwin.read(fd, &byte, 1) == 1 {
            if byte == 10 || byte == 13 { break }
            bytes.append(byte)
        }
        if prompt { FileHandle.standardError.write(Data([10])) }
        guard (1...8192).contains(bytes.count) else { throw CommandFailure("credential_required", "Credential must contain 1–8192 bytes.", 7) }
        return Data(bytes)
    }

    private static func presentWorkspace(_ status: WorkbenchWorkspaceStatus, presentation: Presentation) throws {
        presentation.success(try object(status), human: "Workspace selected: \(TerminalPresentation.safe(status.path ?? "unconfigured"))")
    }
    private static func coverage(_ overview: WorkspaceOverview) -> [String: Any] {
        ["path": overview.path, "complete": overview.coverage.complete,
         "containedProjectIds": overview.coverage.containedProjectIds,
         "externalProjectIds": overview.coverage.externalProjectIds,
         "unresolvedExternalProjectIds": overview.coverage.unresolvedExternalProjectIds,
         "missingPaths": overview.coverage.missingPaths,
         "omittedAuxiliaryPaths": overview.coverage.omittedAuxiliaryPaths,
         "includedBytes": overview.coverage.includedBytes,
         "notice": overview.coverage.notice]
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw WorkbenchIPCError(.invalidRequest) }
        return result
    }
    private static func requireHome(client: WorkbenchBrokerClient, options: Options) throws {
        let expected = options.homeURL().resolvingSymlinksInPath().path
        guard try client.hello().controllerHomePath == expected else {
            throw CommandFailure("controller_home_mismatch", "This runtime belongs to a different controller home.", 5)
        }
    }
    private static func stopService(options: Options, broker: WorkbenchBrokerEnvironment) throws {
        let client = WorkbenchBrokerClient(environment: broker)
        defer { client.close() }
        try client.connect()
        try requireHome(client: client, options: options)
        _ = try client.stopService()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let probe = WorkbenchBrokerClient(environment: broker)
            if (try? probe.connect()) == nil {
                // The socket may close while a selection worker is still draining.
                // The home owner lock is released only after server.stop returns.
                if let released = try? WorkbenchServiceOwnerLock(home: options.homeURL()) {
                    withExtendedLifetime(released) {}
                    return
                }
            }
            probe.close()
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw WorkbenchIPCError(.timedOut)
    }
    private static func startService(options: Options, environment: [String: String], broker: WorkbenchBrokerEnvironment) throws {
        if let root = WorkbenchProductionTrust.homebrewRoot() {
            try WorkbenchPackageLifecycle.context(root: root, options: options).start()
            return
        }
        try WorkbenchLegacyOwnerGate.assertNoKnownWriter()
        let existing = WorkbenchBrokerClient(environment: broker)
        if (try? existing.connect()) != nil {
            defer { existing.close() }
            try requireHome(client: existing, options: options)
            return
        }
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = selfPath.deletingLastPathComponent().appendingPathComponent("screenpunk-service")
        let installed = selfPath.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/screenpunk-service")
        let executable = FileManager.default.isExecutableFile(atPath: installed.path) ? installed : sibling
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CommandFailure("service_unavailable", "The installed screenpunk-service executable is missing.", 9)
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--foreground", "--runtime-directory", broker.runtimeDirectory.path,
                           "--home", options.homeURL().path]
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let probe = WorkbenchBrokerClient(environment: broker)
            if (try? probe.connect()) != nil {
                defer { probe.close() }
                try requireHome(client: probe, options: options)
                return
            }
            if !child.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw WorkbenchIPCError(.unavailable)
    }
    private static func agent(words: [String], options: Options,
                              broker: WorkbenchBrokerEnvironment,
                              presentation: Presentation) throws {
        if words == ["agent", "list"] {
            let names = WorkbenchMCPBridge.names
            presentation.success(["tools": names, "count": names.count],
                human: names.joined(separator: "\n"))
            return
        }
        if words == ["agent", "test"] {
            let client = WorkbenchBrokerClient(environment: broker, credentialScope: .ordinary)
            defer { client.close() }
            try client.connect()
            try requireHome(client: client, options: options)
            let health = try client.health()
            presentation.success(["status": "ready", "broker": health.status,
                "toolCount": WorkbenchMCPBridge.names.count],
                human: "Agent broker ready; \(WorkbenchMCPBridge.names.count) tools available.")
            return
        }
        guard words.count == 4, words[1] == "config", words[2] == "--client",
              ["codex", "cursor", "claude", "generic"].contains(words[3]) else {
            throw Options.usage("Use agent config --client codex|cursor|claude|generic, agent list, or agent test.")
        }
        let executable = WorkbenchProductionTrust.homebrewRoot() == nil
            ? CommandLine.arguments[0] : "/opt/homebrew/bin/screenpunk"
        guard WorkspacePath.isAbsolute(executable) else {
            throw CommandFailure("installation_required", "Run the CLI by its stable absolute installed path to emit agent configuration.", 8)
        }
        var args = ["mcp", "serve", "--runtime-directory", try options.runtimeURL().path]
        if options.home != nil { args += ["--home", options.homeURL().path] }
        let client = words[3]
        let fragment: String
        if client == "codex" {
            let escapedCommand = executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let rendered = args.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ", ")
            fragment = "[mcp_servers.screenpunk]\ncommand = \"\(escapedCommand)\"\nargs = [\(rendered)]"
        } else {
            let entry: [String: Any] = client == "claude" ? ["type": "stdio", "command": executable, "args": args] : ["command": executable, "args": args]
            let config: [String: Any] = ["mcpServers": ["screenpunk": entry]]
            fragment = String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        }
        presentation.success(["client": client, "command": executable, "args": args, "configuration": fragment], human: fragment)
    }
    private static func unavailable() -> CommandFailure {
        .init("capability_unavailable", "This workflow requires an unimplemented or unreviewed domain path.", 8)
    }
    static func brokerCredentialScope(for words: [String]) -> WorkbenchBrokerCredentialScope {
        let ordinaryConnectionIntent = words.first == "connection" &&
            (words.dropFirst().first == "request" ||
             words.dropFirst().first == "update" ||
             (words.count == 4 && words[1] == "intent" && words[2] == "show"))
        return ((["connection", "approval"].contains(words.first ?? "") && !ordinaryConnectionIntent) ||
            words.prefix(2).elementsEqual(["migration", "apply"]) ||
            (words.first == "deploy" && words.dropFirst().first == "apply"))
            ? .localReview : .ordinary
    }
    static func postDispatchCancellationFailure(signalReceived: Bool,
                                                mutationApplied: Bool) -> CommandFailure? {
        signalReceived && !mutationApplied ? cancelled() : nil
    }
    static func packageExportUncertainFailure(destination: String) -> CommandFailure {
        CommandFailure("outcome_unknown",
            "The package export's publication outcome or durability is uncertain; the destination may already contain the verified package.", 7,
            nextActions: ["Inspect the exact destination and package-archive.json before another export attempt. The original package history remains authoritative."],
            details: ["destination": destination])
    }
    static func packageExportOutcomeUnknown(_ error: WorkbenchIPCError) -> Bool {
        [.disconnected, .timedOut, .unavailable, .publicationOutcomeUnknown].contains(error.code)
    }
    private static func cancelled() -> CommandFailure {
        .init("cancelled", "Cancelled; a submitted operation may have completed. Inspect its status before retrying.", 130)
    }
    private static func workspaceFailure(_ error: WorkspaceError) -> CommandFailure {
        switch error {
        case .alreadyExists: return .init("workspace_exists", "The workspace destination already exists.", 6)
        case .unavailable: return .init("workspace_unavailable", "The workspace path or selection is unavailable.", 6)
        case .incomplete: return .init("workspace_incomplete", "Workspace recovery material or required content needs review.", 6)
        case .conflict: return .init("workspace_conflict", "Workspace identity or generation changed.", 6)
        case .invalidPath, .unsafeFile: return .init("invalid_workspace_path", "The workspace path is invalid or unsafe.", 6)
        case .newerSchema: return .init("unsupported_version", "Workspace schema is newer than this CLI.", 8)
        case .invalidSchema: return .init("invalid_workspace", "Workspace metadata is invalid.", 6)
        case .limitExceeded: return .init("resource_limit", "Workspace inventory exceeds a supported limit.", 11)
        }
    }
    private static func ipcFailure(_ error: WorkbenchIPCError) -> CommandFailure {
        let status: Int32
        switch error.code {
        case .invalidConfiguration: status = 2
        case .insecureRuntime, .alreadyRunning, .unauthorizedPeer, .instanceMismatch, .incompatibleOwner: status = 5
        case .authenticationFailed: status = 4
        case .unsupportedVersion, .invalidRequest, .methodNotFound, .frameTooLarge,
             .toolchainTrustUnavailable: status = 8
        case .resourceLimit: status = 11
        case .timedOut, .confirmationRequired, .credentialCleanupRequired, .connectionValidationFailed,
             .serviceBusy, .remoteOutcomeUnknown, .publicationOutcomeUnknown: status = 7
        case .unavailable, .disconnected: status = 9
        case .workspaceExists, .workspaceConflict, .workspaceIncomplete, .invalidWorkspacePath, .migrationRequired: status = 6
        }
        let publicCode: String
        switch error.code {
        case .workspaceExists: publicCode = "workspace_exists"
        case .workspaceConflict: publicCode = "workspace_conflict"
        case .workspaceIncomplete: publicCode = "workspace_incomplete"
        case .invalidWorkspacePath: publicCode = "invalid_workspace_path"
        case .migrationRequired: publicCode = "migration_required"
        case .confirmationRequired: publicCode = "confirmation_required"
        case .credentialCleanupRequired: publicCode = "credential_cleanup_required"
        case .remoteOutcomeUnknown: publicCode = "remote_outcome_unknown"
        case .publicationOutcomeUnknown: publicCode = "outcome_unknown"
        case .toolchainTrustUnavailable: publicCode = "toolchain_trust_not_registered"
        default: publicCode = error.code.rawValue
        }
        let actions: [String]
        if error.code == .toolchainTrustUnavailable {
            actions = ["Install only through an authenticated release catalog and verified publisher. Keep the current source and kit pins unchanged."]
        } else if error.code == .publicationOutcomeUnknown {
            actions = ["Inspect the exact project, workspace, destination or device state before any retry. Do not replay the mutation solely because the reply failed."]
        } else if error.code == .unavailable || error.code == .disconnected {
            actions = ["Start screenpunk service start or service run --foreground."]
        } else { actions = [] }
        return .init(publicCode, error.message, status, nextActions: actions)
    }
    static func workspaceConfigAlias(_ words: [String]) throws -> [String] {
        guard words.first == "config", words.count >= 4,
              words.suffix(2).first == "--scope" else {
            throw Options.usage("config requires get|path|set|unset ... --scope workspace|machine.")
        }
        if words.last == "machine" { return words }
        guard words.last == "workspace" else { throw Options.usage("config scope must be workspace or machine.") }
        return ["workspace", "config"] + words.dropFirst().dropLast(2)
    }

    private static func machineConfig(_ words: [String], client: WorkbenchBrokerClient,
                                      workspace: WorkspaceStore,
                                      presentation: Presentation) throws {
        guard words.last == "machine", words.suffix(2).first == "--scope" else {
            throw Options.usage("Machine config requires --scope machine.")
        }
        if words == ["config", "path", "--scope", "machine"] {
            let path = workspace.selection.machineRootPath + "/bootstrap.json"
            presentation.success(["scope": "machine", "kind": "workspaceSelectionPointer",
                "path": path, "coverage": "selection-pointer-only"],
                human: "Machine workspace selection pointer: \(TerminalPresentation.safe(path))")
            return
        }
        if words == ["config", "get", "--scope", "machine"] {
            let selected = try client.workspaceStatus()
            presentation.success(["scope": "machine", "kind": "workspaceSelectionPointer",
                "coverage": "selection-pointer-only", "state": selected.state,
                "workspaceId": selected.workspaceId ?? "", "path": selected.path ?? "",
                "selectionGeneration": selected.selectionGeneration ?? 0,
                "managedBy": "workspace init|open|relocate"],
                human: "Machine workspace selection: \(TerminalPresentation.safe(selected.state)). Use workspace open to change it.")
            return
        }
        if words.count >= 2, ["set", "unset"].contains(words[1]) {
            throw CommandFailure("unsupported_machine_config_key",
                "Machine selection, device endpoints, connection bindings and service policy are changed through their reviewed commands.", 8,
                nextActions: ["Use workspace open, device controls, connection controls or service enable/disable for the corresponding field."])
        }
        throw Options.usage("Machine config supports get|path --scope machine; use specialized commands for changes.")
    }

    private static func helpText(topic: String?) throws -> String {
        if let topic, !["service", "doctor", "version", "help", "workspace", "setup", "operation",
                         "project", "screen", "build", "migration", "device", "connection",
                         "approval", "deploy", "agent", "mcp", "config", "diagnostics", "toolchain",
                         "install", "update", "uninstall"].contains(topic) { throw unavailable() }
        return """
        screenpunk — Mac workbench CLI (\(version))
        Commands:
          setup [--workspace PATH]           Select existing or create proposed workspace
          workspace init [PATH]              Create and select a new workspace
          workspace open PATH                Validate and select existing workspace
          workspace show|path|validate|coverage
          workspace snapshot --out ABS_DEST [--include-external] [--allow-incomplete]
                                             Export a bounded portable snapshot
          workspace relocate --to ABS_DEST Copy, verify and select a contained workspace
          workspace operation-status UUID     Read live copy progress and reconciled outcome
          workspace operation-cancel UUID     Request cooperative copy cancellation
          operation list|show UUID|cancel UUID
                                             Bounded local copy/deployment inventory; partial coverage
          workspace config get|path|set KEY VALUE GENERATION|unset KEY GENERATION
          config get|path|set|unset ... --scope workspace
          config get --scope workspace --profile NAME
                                             Resolve named portable presentation over workspace defaults
                                             config set/unset edits defaults; use --profile default
          config get|path --scope machine  Read the local workspace-selection pointer
          diagnostics export --out ABS_NEW_FILE
          toolchain list                    List portable kit pins without trusting them
          toolchain install --required      Install only after production trust registration
          project list|show ID|path ID        Read registered source projects
          project create NAME [web|react]|inspect ID|versions ID
          project unregister ID --generation WORKSPACE_GENERATION
                                             Remove only the catalog entry; retain source/history
          project relocate ID --source-version HASH --to Screens/NAME --generation CATALOG_GENERATION
                                             Register an already prepared contained folder; retain original
          project upgrade-kit ID --source-version HASH --catalog-entry ID --kit-version VERSION --inventory SHA256 --generation CATALOG_GENERATION
                                             Requires an authenticated installed kit and exact workspace pin
          project export-source ID --source-version HASH --out ABSOLUTE_DESTINATION
          project import-source ABSOLUTE_ARCHIVE [--to Screens/NAME]
          project open-external ABSOLUTE_PROJECT_PATH --external
          project adopt ID --source-version HASH --to Screens/NAME
          project relocate ID --source-version HASH --to ABS_PATH --external
                                             Rebind a verified external source folder
          project source ID REL_PATH         Read bounded selected-workspace source text
          project source-chunk ID PATH HASH OFFSET
                                             Read one version-checked source file chunk
          project edit ID HASH PATH ABS_INPUT|remove-file ID HASH PATH
          project edit-local ID REL_PATH      Edit a private draft with SCREENPUNK_EDITOR or TextEdit, then submit with source-version check
          project open-contained ABS_PATH
          screen list|show ID|validate ID     Read verified cached legacy packages
          screen history                     Read retained workspace packages
          screen import-package ABSOLUTE_DIRECTORY
                                             Import a measured historical package (`screen import` alias)
          screen export-package ID --revision REV --out ABS_DEST
                                             Export one verified immutable package revision
          screen source-rename|package-rename|package-duplicate|package-orientation|icon-set --file ABSOLUTE_JSON
                                             Submit a closed, exact-version screen mutation request
          screen archive|react-source-associate --file ABSOLUTE_JSON
                                             Archive library visibility or attach exact React source
          build run ID HASH [BASE_REV]|head ID
          build --watch PROJECT_ID            Debounced build-only source watch; Ctrl-C stops watcher
          deploy prepare DEVICE DASHBOARD SOURCE_REV ORIENTATION
          deploy plan|rollback DEVICE DASHBOARD SOURCE_REV PREPARED_REV
          deploy review|apply PLAN_ID [--approved]
          deploy lookup PLAN_ID               Recover operation ID without sending
          deploy status|reconcile OPERATION_ID|cancel PLAN_ID DEVICE_ID
          migration plan ABS_SOURCE ABS_DEST Review copy, exclusions and destination
          migration review|apply PLAN_ID     Recheck or apply reviewed plan (apply supports --approved)
          device discover|add --host HOST --port PORT
          device list|status ID [--refresh]   Cached or explicit live status
          device pair ID|--host HOST --port PORT
          device pairing show|confirm|cancel [PENDING_ID]
          device forget ID                   Forget local pairing only
          device settings get ID             Read device-owned settings
          device settings set ID --file JSON --expected-revision REV
          device connections list ID         Read device connection inventory
          device screens ID                  Read fresh pinned installed screen set
          device logs ID                     Read bounded broker-observed events for one device
          connection configure DEVICE DASHBOARD REV --file JSON [--secret-stdin]
          connection home-assistant setup DEVICE DASHBOARD REV ORIGIN [--secret-stdin]
          connection home-assistant status|cancel INTENT_ID
          connection request DEVICE DASHBOARD REV --file JSON
                                             Propose a no-credential intent for local review
          connection list DEVICE|inspect ID|test ID|revoke ID|remove ID
          connection update ID GRANT_GENERATION --file JSON  Review scope change; keep endpoint and credential
          approval show|approve|deny INTENT_ID
                                             Approve requires exact scope review on a controlling TTY
          service status|lifecycle|drain     Inspect and drain local broker work
          service start|stop|restart         Manage local broker
          service enable|disable             Change verified installed user-service start policy
          service logs                       Show redacted installed service events
          service run --foreground           Run broker in foreground
          install plan ARCHIVE                Review a verified release archive
          install apply ARCHIVE TOKEN         Install after exact plan confirmation
          update check|plan ARCHIVE           Review an upgrade
          update install ARCHIVE TOKEN        Stage, drain, switch and health-check
          update rollback plan ARCHIVE        Review a retained, verified prior version
          update rollback apply ARCHIVE TOKEN Recheck, switch and health-check that version
          uninstall plan|apply [TOKEN]        Review or remove owned installation; retain data
          agent config --client CLIENT       Print codex, cursor, claude or generic command fragment
          agent list|test                    List the configured tool catalog or test broker access
          doctor|version|help [topic]
        Options: --json --no-input --approved --timeout SECONDS --workspace PATH --home PATH
                 --runtime-directory PATH --profile NAME --verbose --help --version
        """
    }
}

final class WorkbenchServiceOwnerLock {
    private let fd: Int32
    init(home: URL) throws {
        let directory = Darwin.open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw WorkbenchIPCError(.insecureRuntime) }
        defer { Darwin.close(directory) }
        let lock = openat(directory, "workbench-owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WorkbenchIPCError(.insecureRuntime) }
        var statValue = stat()
        guard fstat(lock, &statValue) == 0, statValue.st_uid == geteuid(),
              statValue.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              statValue.st_mode & 0o7777 == 0o600, statValue.st_nlink == 1 else {
            Darwin.close(lock); throw WorkbenchIPCError(.insecureRuntime)
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock); throw WorkbenchIPCError(.alreadyRunning)
        }
        fd = lock
    }
    deinit { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
}

struct CLIWorkspaceDocuments: WorkspaceDocumentsResolver {
    let environment: [String: String]
    func documentsDirectory() throws -> URL {
        if let path = environment["SCREENPUNK_DOCUMENTS_DIRECTORY"] {
            guard WorkspacePath.isAbsolute(path) else { throw WorkspaceError.invalidPath }
            return URL(fileURLWithPath: WorkspacePath.canonical(path), isDirectory: true)
        }
        return try SystemWorkspaceDocumentsResolver().documentsDirectory()
    }
}

private final class SignalCancellation {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var received: Int32?
    private var sources: [DispatchSourceSignal] = []
    private var previous: [Int32: sig_t] = [:]
    var signalNumber: Int32? { lock.lock(); defer { lock.unlock() }; return received }
    init() {
        for number in [SIGINT, SIGTERM] {
            previous[number] = Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock(); if self.received == nil { self.received = number }; self.lock.unlock()
                self.semaphore.signal()
            }
            sources.append(source); source.resume()
        }
    }
    func requestStop() { semaphore.signal() }
    func wait() { semaphore.wait() }
    func finish() { for source in sources { source.cancel() }; for (number, handler) in previous { Darwin.signal(number, handler) }; sources.removeAll() }
}
