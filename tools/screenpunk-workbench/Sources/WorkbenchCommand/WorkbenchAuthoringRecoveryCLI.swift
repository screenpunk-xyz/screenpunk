import Foundation
import Darwin
import ScreenpunkController

/// Command-side parser for the closed authoring/recovery broker methods. The
/// entrypoint only calls this after connecting to the authenticated broker.
enum WorkbenchAuthoringRecoveryCLI {
    struct Route {
        let method: WorkbenchAuthoringRecoveryMethod
        let params: [String: Any]
    }

    static func route(_ words: [String]) throws -> Route? {
        if let portable = try WorkbenchPortableSourceCLI.route(words) { return portable }
        if let clone = try WorkbenchProjectCloneCLI.route(words) { return clone }
        if let rebind = try WorkbenchExternalRebindCLI.route(words) { return rebind }
        if let config = try WorkbenchWorkspaceConfigurationCLI.route(words) { return config }
        guard words.count >= 2 else { return nil }
        let method: WorkbenchAuthoringRecoveryMethod
        var fields: [String: Any] = ["schemaVersion": 1]
        switch (words[0], words[1]) {
        case ("project", "create"):
            guard words.count == 3 || words.count == 4 else {
                throw Options.usage("project create requires NAME [web|react].")
            }
            method = .projectCreate; fields["name"] = words[2]
            fields["kind"] = words.count == 4 ? words[3] : "web"
        case ("project", "inspect"):
            guard words.count == 3 else { throw Options.usage("project inspect requires PROJECT_ID.") }
            method = .projectInspect; fields["projectId"] = words[2]
        case ("project", "unregister"):
            guard words.count == 5, words[3] == "--generation",
                  let generation = Int(words[4]), generation >= 0 else {
                throw Options.usage("project unregister requires PROJECT_ID --generation WORKSPACE_GENERATION.")
            }
            method = .projectUnregister
            fields["projectId"] = words[2]
            fields["expectedCatalogGeneration"] = generation
        case ("project", "relocate"):
            guard words.count == 9, words[3] == "--source-version",
                  words[5] == "--to", words[7] == "--generation",
                  let generation = Int(words[8]), generation >= 0 else {
                throw Options.usage("project relocate requires PROJECT_ID --source-version HASH --to Screens/NAME --generation CATALOG_GENERATION. Prepare the destination folder first.")
            }
            method = .projectRelocateContained
            fields["projectId"] = words[2]
            fields["expectedSourceVersion"] = words[4]
            fields["relativeDestination"] = words[6]
            fields["expectedCatalogGeneration"] = generation
        case ("project", "upgrade-kit"):
            guard words.count == 13, words[3] == "--source-version",
                  words[5] == "--catalog-entry", words[7] == "--kit-version",
                  words[9] == "--inventory", words[11] == "--generation",
                  let generation = Int(words[12]), generation >= 0 else {
                throw Options.usage("project upgrade-kit requires PROJECT_ID --source-version HASH --catalog-entry ID --kit-version VERSION --inventory SHA256 --generation CATALOG_GENERATION.")
            }
            method = .projectUpgradeKit
            fields["projectId"] = words[2]
            fields["expectedSourceVersion"] = words[4]
            fields["catalogEntryId"] = words[6]
            fields["kitVersion"] = words[8]
            fields["inventoryHash"] = words[10]
            fields["expectedCatalogGeneration"] = generation
        case ("project", "edit"):
            guard words.count == 6 else {
                throw Options.usage("project edit requires PROJECT_ID EXPECTED_SOURCE_VERSION RELATIVE_PATH ABSOLUTE_INPUT_FILE.")
            }
            method = .projectPatch
            fields["projectId"] = words[2]; fields["expectedSourceVersion"] = words[3]
            fields["changes"] = [["path": words[4], "bytesBase64": try readInput(words[5]).base64EncodedString()]]
        case ("project", "remove-file"):
            guard words.count == 5 else {
                throw Options.usage("project remove-file requires PROJECT_ID EXPECTED_SOURCE_VERSION RELATIVE_PATH.")
            }
            method = .projectPatch
            fields["projectId"] = words[2]; fields["expectedSourceVersion"] = words[3]
            fields["changes"] = [["path": words[4], "delete": true]]
        case ("project", "open-contained"):
            guard words.count == 3 else { throw Options.usage("project open-contained requires ABSOLUTE_PATH.") }
            method = .projectOpenContained; fields["path"] = words[2]
        case ("build", "run"):
            guard words.count == 4 || words.count == 5 else {
                throw Options.usage("build run requires PROJECT_ID EXPECTED_SOURCE_VERSION [BASE_REVISION].")
            }
            method = .buildRun; fields["projectId"] = words[2]
            fields["expectedSourceVersion"] = words[3]
            if words.count == 5 { fields["baseRevision"] = words[4] }
        case ("build", "head"):
            guard words.count == 3 else { throw Options.usage("build head requires PROJECT_ID.") }
            method = .buildHead; fields["projectId"] = words[2]
        case ("screen", "history"):
            guard words.count == 2 else { throw Options.usage("screen history takes no operands.") }
            method = .packageHistory
        case ("screen", "export-package"):
            guard words.count == 7, words[3] == "--revision", words[5] == "--out" else {
                throw Options.usage("screen export-package DASHBOARD_ID --revision REVISION --out ABSOLUTE_DESTINATION.")
            }
            method = .packageExport
            fields["dashboardId"] = words[2]; fields["revision"] = words[4]
            fields["path"] = words[6]
        case ("workspace", "snapshot"), ("workspace", "export"):
            method = .snapshotCreate
            if words.count == 3, !words[2].hasPrefix("--") {
                fields["path"] = words[2]
            } else {
                guard words.count >= 4, words[2] == "--out" else {
                    throw Options.usage("workspace snapshot requires --out ABSOLUTE_DESTINATION [--include-external] [--allow-incomplete].")
                }
                fields["path"] = words[3]
                let flags = Array(words.dropFirst(4))
                guard flags.count == Set(flags).count,
                      Set(flags).isSubset(of: ["--include-external", "--allow-incomplete"]) else {
                    throw Options.usage("Invalid workspace snapshot flags.")
                }
                fields["includeExternal"] = flags.contains("--include-external")
                fields["allowIncomplete"] = flags.contains("--allow-incomplete")
            }
        case ("workspace", "relocate"):
            guard words.count == 4, words[2] == "--to" else {
                throw Options.usage("workspace relocate requires --to ABSOLUTE_DESTINATION.")
            }
            method = .workspaceRelocate; fields["path"] = words[3]
        case ("migration", "plan"):
            guard words.count == 3 || words.count == 4 else {
                throw Options.usage("migration plan requires ABSOLUTE_SOURCE [ABSOLUTE_DESTINATION].")
            }
            method = .migrationPlan; fields["path"] = words[2]
            if words.count == 4 { fields["destination"] = words[3] }
        case ("migration", "review"):
            guard words.count == 3 else { throw Options.usage("migration review requires PLAN_ID.") }
            method = .migrationReview; fields["migrationId"] = words[2]
        default: return nil
        }
        do { _ = try WorkbenchAuthoringRecoveryRequest.parse(method: method, params: fields) }
        catch { throw Options.usage("Invalid authoring or recovery command input.") }
        return .init(method: method, params: fields)
    }

    static func present(_ result: WorkbenchAuthoringRecoveryResult, for method: WorkbenchAuthoringRecoveryMethod,
                        with presentation: Presentation, checkedOutput: Bool = false,
                        profile: WorkbenchCLIProfile? = nil) throws {
        try result.validate(for: method)
        let data = try JSONEncoder().encode(result)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        var displayed = method == .workspaceConfigPath
            ? TerminalPresentation.safe(result.configuration!.path) : try human(result)
        if method == .workspaceConfigGet, let profile {
            guard let configuration = result.configuration,
                  configuration.workspaceId == profile.workspaceId,
                  configuration.generation == profile.configurationGeneration else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            object["selectedProfile"] = profile.name
            object["effectivePresentation"] = profile.effectivePresentation
            object["presentationPrecedence"] = "named-profile-over-workspace-defaults"
            displayed += "\nProfile: \(TerminalPresentation.safe(profile.name))"
            for (key, value) in profile.effectivePresentation.sorted(by: { $0.key < $1.key }) {
                displayed += "\nEffective \(key): \(TerminalPresentation.safe(value))"
            }
        }
        if checkedOutput { try presentation.checkedSuccess(object, human: displayed) }
        else { presentation.success(object, human: displayed) }
    }

    static func applyMigration(id: String, approved: Bool, noInput: Bool,
                               client: WorkbenchBrokerClient, presentation: Presentation,
                               openTTY: (() throws -> Int32)? = nil) throws {
        let fields: [String: Any] = ["schemaVersion": 1, "migrationId": id]
        let reviewed = try client.performAuthoring(method: .migrationReview, params: fields)
        guard let frozen = reviewed.migrationPlan, frozen.migrationId == id,
              frozen.applyAvailable, frozen.destinationPath != nil,
              frozen.unsupportedPortablePaths.isEmpty else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        if !approved {
            guard !noInput else { throw WorkbenchIPCError(.confirmationRequired) }
            let fd = try openTTY?() ?? Darwin.open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOCTTY)
            guard fd >= 0 else { throw WorkbenchIPCError(.confirmationRequired) }
            defer { Darwin.close(fd) }
            let lines = try migrationReviewLines(frozen)
            for line in lines {
                let bytes = Data((line + "\n").utf8)
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw WorkbenchIPCError(.unavailable) }
                        offset += count
                    }
                }
            }
            let prompt = Data("Type MIGRATE to copy, verify and select this exact destination (default no): ".utf8)
            _ = prompt.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, prompt.count) }
            var answer: [UInt8] = [], byte: UInt8 = 0
            while answer.count < 16 && Darwin.read(fd, &byte, 1) == 1 {
                if byte == 10 || byte == 13 { break }
                answer.append(byte)
            }
            guard String(bytes: answer, encoding: .utf8) == "MIGRATE" else {
                throw CommandFailure("confirmation_declined", "Migration review was not approved.", 7)
            }
            client.close()
            try client.connect()
            let current = try client.performAuthoring(method: .migrationReview, params: fields)
            guard current.migrationPlan == frozen else { throw WorkbenchIPCError(.workspaceConflict) }
        }
        let applied: WorkbenchAuthoringRecoveryResult
        do { applied = try client.performAuthoring(method: .migrationApply, params: fields) }
        catch {
            throw CommandFailure("migration_outcome_unknown",
                "The reviewed migration was submitted, but its outcome is unknown. Inspect the selected workspace and destination before planning any further migration.",
                9, nextActions: ["Run workspace show and inspect the destination; retain the original legacy source."],
                details: ["migrationId": id, "destinationPath": frozen.destinationPath ?? ""])
        }
        do { try present(applied, for: .migrationApply, with: presentation) }
        catch {
            throw CommandFailure("migration_applied_display_failed",
                "The migration completed and selected its destination, but the result could not be displayed.",
                9, details: ["migrationId": id, "destinationPath": frozen.destinationPath ?? ""])
        }
    }

    /// Preserve the command's complete-history meaning by consuming bounded
    /// broker pages. A large history fails explicitly before emitting output.
    static func presentCompleteHistory(client: WorkbenchBrokerClient,
                                       selected: WorkbenchWorkspaceStatus,
                                       with presentation: Presentation) throws {
        guard selected.state == "selected", let id = selected.workspaceId,
              let generation = selected.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        var values: [WorkbenchPackageHistoryRead] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["schemaVersion": 1,
                "expectedWorkspaceId": id, "expectedSelectionGeneration": generation]
            if let cursor { params["cursor"] = cursor }
            let page = try client.performAuthoring(method: .packageHistory, params: params)
            guard let packages = page.packages, let hasMore = page.hasMore,
                  values.count + packages.count <= 4_096,
                  !hasMore || page.nextCursor != nil else {
                throw WorkbenchIPCError(.resourceLimit)
            }
            values += packages
            cursor = page.nextCursor
        } while cursor != nil
        let encoded = try JSONEncoder().encode(values)
        let packages = try JSONSerialization.jsonObject(with: encoded)
        presentation.success(["schemaVersion": 1, "kind": "packageHistory",
            "packages": packages, "count": values.count, "complete": true,
            "ordering": "history-object-id-ascending"],
            human: values.isEmpty ? "No retained workspace packages." : values.map {
                "\($0.dashboardId)  \($0.revision)  \(TerminalPresentation.safe($0.name))"
            }.joined(separator: "\n"))
    }

    static func human(_ result: WorkbenchAuthoringRecoveryResult) throws -> String {
        switch result.kind {
        case .authoringProject:
            guard let project = result.project else { throw WorkbenchIPCError(.invalidRequest) }
            return "\(project.project.projectId)  \(TerminalPresentation.safe(project.project.name))\nSource: \(project.sourceVersion)\nPath: \(TerminalPresentation.safe(project.path))"
        case .sourceArchive:
            guard let archive = result.sourceArchive else { throw WorkbenchIPCError(.invalidRequest) }
            return "Source archive: \(TerminalPresentation.safe(archive.archivePath))\nSource: \(archive.sourceVersion)\nFiles: \(archive.fileCount)"
        case .packageExport:
            guard let exported = result.packageExport else { throw WorkbenchIPCError(.invalidRequest) }
            return "Package export: \(TerminalPresentation.safe(exported.path))\nRevision: \(exported.revision)\nDigest: \(exported.digest)\nFiles: \(exported.fileCount)"
        case .projectUnregistered:
            guard let removed = result.projectUnregistered else { throw WorkbenchIPCError(.invalidRequest) }
            return "Project \(removed.projectId) unregistered. Source and history retained. Workspace generation: \(removed.generation)."
        case .sourceLocation:
            guard let location = result.sourceLocation else { throw WorkbenchIPCError(.invalidRequest) }
            return "\(location.project.projectId)  \(TerminalPresentation.safe(location.project.name))\nSource: \(location.sourceVersion)\nPath: \(TerminalPresentation.safe(location.path))\nBackup coverage: \(location.backupCoverage)"
        case .buildHead:
            guard let build = result.build else { throw WorkbenchIPCError(.invalidRequest) }
            return "Project: \(build.projectId)\nRevision: \(build.revision)\nDigest: \(build.digest)"
        case .packageHistory:
            let values = result.packages ?? []
            return values.isEmpty ? "No retained workspace packages." : values.map {
                "\($0.dashboardId)  \($0.revision)  \(TerminalPresentation.safe($0.name))"
            }.joined(separator: "\n")
        case .workspaceSnapshot:
            guard let snapshot = result.snapshot else { throw WorkbenchIPCError(.invalidRequest) }
            let shown = snapshot.omittedAuxiliaryPaths.prefix(20).map(TerminalPresentation.safe)
            let remainder = snapshot.omittedAuxiliaryPaths.count - shown.count
            let omissions = shown.isEmpty ? "none" : shown.joined(separator: ", ")
                + (remainder > 0 ? " (+\(remainder) more; see Workbench/snapshot-manifest.json)" : "")
            return "Snapshot: \(TerminalPresentation.safe(snapshot.path))\nScope: portable authoring content\nPortable coverage complete: \(snapshot.complete)\nFiles: \(snapshot.fileCount)\nOmitted auxiliary paths (\(snapshot.omittedAuxiliaryPaths.count)): \(omissions)"
        case .workspaceRelocation:
            guard let relocation = result.relocation else { throw WorkbenchIPCError(.invalidRequest) }
            let unresolved = relocation.unresolvedExternalProjectIds.isEmpty ? "none" :
                relocation.unresolvedExternalProjectIds.map(TerminalPresentation.safe).joined(separator: ", ")
            return "Relocated workspace: \(TerminalPresentation.safe(relocation.path))\nOriginal retained: \(TerminalPresentation.safe(relocation.originalPath))\nFiles copied: \(relocation.fileCount)\nExternal projects requiring explicit local rebind: \(unresolved)"
        case .workspaceConfiguration:
            guard let configuration = result.configuration else { throw WorkbenchIPCError(.invalidRequest) }
            if configuration.path.isEmpty { throw WorkbenchIPCError(.invalidRequest) }
            let fields = configuration.presentation.sorted { $0.key < $1.key }.map {
                "\($0.key): \(TerminalPresentation.safe($0.value))"
            }
            return "Workspace: \(TerminalPresentation.safe(configuration.workspaceId))\nConfig path: \(TerminalPresentation.safe(configuration.path))\nGeneration: \(configuration.generation)"
                + (fields.isEmpty ? "" : "\n" + fields.joined(separator: "\n"))
        case .migrationPlan:
            guard let plan = result.migrationPlan else { throw WorkbenchIPCError(.invalidRequest) }
            return try migrationReviewLines(plan).joined(separator: "\n")
        case .migrationApplied:
            guard let applied = result.migrationApplied else { throw WorkbenchIPCError(.invalidRequest) }
            return "Migrated workspace selected: \(TerminalPresentation.safe(applied.path ?? "unknown"))\nOriginal legacy data retained."
        }
    }

    private static func migrationReviewLines(_ plan: WorkbenchMigrationPlanRead) throws -> [String] {
        var lines = ["Plan: \(plan.migrationId)",
            "Legacy source: " + (try exactReviewText(plan.sourcePath)),
            "Destination: " + (try exactReviewText(plan.destinationPath ?? "not selected")),
            "Projects: \(plan.projectIds.count)", "Packages: \(plan.packageRevisions.count)",
            "Source bytes: \(plan.portableBytes)", "Expanded bytes: \(plan.expandedBytes)",
            "Members: \(plan.plannedMembers)"]
        for value in plan.projectIds { lines.append("Project: " + (try exactReviewText(value))) }
        for value in plan.packageRevisions { lines.append("Package: " + (try exactReviewText(value))) }
        for value in plan.unsupportedPortablePaths {
            lines.append("Unsupported portable path: " + (try exactReviewText(value)))
        }
        for value in plan.excludedClasses { lines.append("Excluded: " + (try exactReviewText(value))) }
        lines += ["Originals preserved: yes", "Apply available: \(plan.applyAvailable)"]
        return lines
    }

    /// Approval selectors must be fully visible. TerminalPresentation.safe
    /// intentionally truncates general diagnostics; that is unsuitable here.
    private static func exactReviewText(_ value: String) throws -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let unsafe = code < 0x20 || (0x7f...0x9f).contains(code) ||
                (0x202a...0x202e).contains(code) || (0x2066...0x2069).contains(code) ||
                code == 0x061c || code == 0x200e || code == 0x200f ||
                code == 0x2028 || code == 0x2029
            escaped += unsafe ? String(format: "\\u{%04X}", code) : String(scalar)
            guard escaped.utf8.count <= 4096 else {
                throw CommandFailure("migration_review_too_large",
                    "The complete migration source, destination or omission cannot be displayed safely; review the JSON plan and use an explicit assertion only after checking its full scope.", 7)
            }
        }
        return escaped
    }

    private static func readInput(_ path: String) throws -> Data {
        let maximum = 5 * 1024 * 1024
        guard WorkspaceValidation.absolute(path) else { throw Options.usage("Input file requires an absolute path.") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Options.usage("Input file is unavailable or is a symlink.") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              (0...Int64(maximum)).contains(metadata.st_size) else {
            throw Options.usage("Input must be a regular file of at most 5 MiB.")
        }
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while bytes.count <= maximum {
            let countLimit = min(chunk.count, maximum + 1 - bytes.count)
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, countLimit)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Options.usage("Could not read input file.") }
            if count == 0 { break }
            bytes.append(contentsOf: chunk.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              bytes.count == metadata.st_size, bytes.count <= maximum,
              after.st_dev == metadata.st_dev, after.st_ino == metadata.st_ino,
              after.st_size == metadata.st_size,
              after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else {
            throw Options.usage("Input file changed or exceeded 5 MiB.")
        }
        return bytes
    }
}
