import Foundation
import Darwin
import ScreenpunkController

enum WorkbenchDiagnosticsCLI {
    static func export(words: [String], client: WorkbenchBrokerClient,
                       presentation: Presentation) throws {
        guard words.count == 4, words[1] == "export", words[2] == "--out",
              WorkspaceValidation.absolute(words[3]), words[3].utf8.count <= 4096 else {
            throw Options.usage("diagnostics export requires --out ABSOLUTE_NEW_FILE.")
        }
        let health = try client.health()
        let lifecycle = try? client.serviceLifecycle()
        let selected = try? client.workspaceStatus()
        let coverage = selected?.state == "selected" ? try? client.workspaceCoverage() : nil
        let report: [String: Any] = [
            "schemaVersion": 1,
            "screenpunkVersion": WorkbenchCommand.version,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "service": [
                "status": health.status,
                "lifecycle": lifecycle?.state ?? "unavailable",
                "activeJobCount": lifecycle?.activeJobIDs.count ?? 0,
                "guiConsumerEvidence": lifecycle?.guiConsumersKnown == true ? "verified" : "unknown"
            ],
            "workspace": [
                "state": selected?.state ?? health.workspaceState,
                "coverage": coverage.map { $0.complete ? "complete" : "incomplete" } ?? "unavailable",
                "missingPathCount": coverage?.missingPaths.count ?? 0,
                "unresolvedExternalProjectCount": coverage?.unresolvedExternalProjectIds.count ?? 0
            ],
            "dependencies": [
                "authoringRoute": health.supportedMethods.contains(
                    WorkbenchAuthoringRecoveryMethod.buildRun.rawValue) ? "available" : "unavailable",
                "authoringKit": "not_verified",
                "trustedReleaseCatalog": "not_registered"
            ],
            "identityProbe": "not_performed",
            "networkAuthorizationProbe": "not_performed",
            "screenshotAvailability": health.screenshots
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        guard data.count <= 16 * 1024 else { throw WorkbenchIPCError(.resourceLimit) }
        try writeNew(data, to: words[3])
        do {
            try presentation.checkedSuccess(["path": words[3], "bytes": data.count,
                "redaction": "fixed-fields-no-paths-or-secrets"],
                human: "Wrote bounded diagnostic report to \(TerminalPresentation.safe(words[3])).")
        } catch {
            throw CommandFailure("diagnostics_written_display_failed",
                "The diagnostic file was written, but the result could not be displayed.", 6,
                nextActions: ["Inspect the existing file before retrying with a new destination."],
                details: ["path": words[3]])
        }
    }

    private static func writeNew(_ data: Data, to path: String) throws {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw WorkbenchIPCError(.invalidWorkspacePath) }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw WorkbenchIPCError(.unavailable) }
        defer { Darwin.close(directory) }
        for part in components.dropLast() {
            let next = Darwin.openat(directory, part,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw WorkbenchIPCError(.invalidWorkspacePath) }
            Darwin.close(directory); directory = next
        }
        let name = components.last!
        let fd = Darwin.openat(directory, name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WorkbenchIPCError(.invalidWorkspacePath) }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < data.count {
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset),
                        data.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw WorkbenchIPCError(.unavailable) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw WorkbenchIPCError(.unavailable) }
            Darwin.close(fd)
        } catch {
            Darwin.close(fd)
            _ = unlinkat(directory, name, 0)
            throw error
        }
    }
}
