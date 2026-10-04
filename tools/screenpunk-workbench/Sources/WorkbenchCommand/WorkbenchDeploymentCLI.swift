import Foundation
import Darwin
import ScreenpunkController

enum WorkbenchDeploymentCLI {
    static func run(words: [String], options: Options, client: WorkbenchBrokerClient,
                    selected: WorkbenchWorkspaceStatus, presentation: Presentation,
                    openTTY: (() throws -> Int32)?) throws {
        guard words.count >= 2, selected.state == "selected",
              let workspaceId = selected.workspaceId,
              let generation = selected.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let base: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": workspaceId,
            "expectedSelectionGeneration": generation]
        func params(_ more: [String: Any]) -> [String: Any] {
            base.merging(more) { _, replacement in replacement }
        }
        func present(_ value: WorkbenchDeploymentActionResult, human: String) throws {
            let bytes = try JSONEncoder().encode(value)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            presentation.success(object, human: human)
        }
        let verb = words[1]
        guard !options.approved || verb == "apply" else {
            throw Options.usage("--approved applies only to deploy apply.")
        }
        switch verb {
        case "prepare":
            guard words.count == 6, options.inputFile == nil else {
                throw Options.usage("deploy prepare DEVICE_ID DASHBOARD_ID SOURCE_REVISION ORIENTATION")
            }
            let value = try client.performDeployment(method: .prepare, params: params([
                "deviceId": words[2], "dashboardId": words[3],
                "sourceRevision": words[4], "orientation": words[5]]))
            guard let prepared = value.prepared else { throw WorkbenchIPCError(.invalidRequest) }
            try present(value, human: "Prepared \(prepared.dashboardId) source \(prepared.sourceRevision) as \(prepared.revision) digest \(prepared.digest).")
        case "plan", "rollback":
            guard words.count == 6 || (words.count == 3 && options.inputFile != nil) else {
                throw Options.usage("deploy \(verb) DEVICE_ID DASHBOARD_ID SOURCE_REVISION PREPARED_REVISION, or DEVICE_ID --file ABS_SET_JSON")
            }
            let deviceId = words[2]
            let plan: [String: Any]
            if let path = options.inputFile {
                plan = try readSetFile(path)
            } else {
                plan = ["packages": [["dashboardId": words[3], "sourceRevision": words[4],
                    "revision": words[5], "dataDescription": "Explicit retained prepared package"]],
                    "selectedDashboardId": words[3], "removedDashboardIds": [String](),
                    "bindingIds": [String](), "lifetimeSeconds": 3600]
            }
            let method: WorkbenchDeploymentMethod = verb == "rollback" ? .rollbackPlan : .plan
            let value = try client.performDeployment(method: method,
                params: params(plan.merging(["deviceId": deviceId]) { _, replacement in replacement }))
            guard let review = value.review else { throw WorkbenchIPCError(.invalidRequest) }
            try present(value, human: WorkbenchDeploymentPresentation.render(review))
        case "review":
            guard words.count == 3 else { throw Options.usage("deploy review PLAN_ID") }
            let value = try client.performDeployment(method: .review,
                params: params(["planId": words[2]]))
            guard let review = value.review else { throw WorkbenchIPCError(.invalidRequest) }
            try present(value, human: WorkbenchDeploymentPresentation.render(review))
        case "apply":
            guard words.count == 3 else { throw Options.usage("deploy apply PLAN_ID [--approved]") }
            let review = try client.performDeployment(method: .review,
                params: params(["planId": words[2]]))
            guard let frozen = review.review else { throw WorkbenchIPCError(.invalidRequest) }
            if !options.approved {
                guard !options.noInput else { throw WorkbenchIPCError(.confirmationRequired) }
                let accepted = try WorkbenchDeploymentTerminal.confirm(frozen,
                    openTTY: openTTY ?? {
                        Darwin.open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOCTTY)
                    })
                guard accepted else {
                    throw CommandFailure("confirmation_declined", "The exact deployment was not approved.", 7)
                }
                // The broker's idle socket budget is shorter than a legitimate
                // paged human review. Reauthenticate and verify the same frozen
                // scope before sending the approved assertion.
                client.close()
                try client.connect()
                let current = try client.performDeployment(method: .review,
                    params: params(["planId": words[2]]))
                guard current.review == frozen else { throw WorkbenchIPCError(.workspaceConflict) }
            }
            guard let context = frozen.authorizationContextHash else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            let value = try client.performDeployment(method: .apply, params: params([
                "planId": words[2], "expectedPlanHash": frozen.planHash,
                "expectedAuthorizationContextHash": context,
                "idempotencyKey": "cli-" + words[2].lowercased(), "approved": true,
                "approvalMode": options.approved ? "scripted" : "interactive"]))
            guard let operation = value.operation else { throw WorkbenchIPCError(.invalidRequest) }
            try present(value, human: "Operation \(operation.operationId): \(operation.state.rawValue). Send attempted: \(operation.sendAttempted).")
        case "status", "lookup", "reconcile":
            guard words.count == 3 else {
                throw Options.usage("deploy \(verb) \(verb == "lookup" ? "PLAN_ID" : "OPERATION_ID")")
            }
            let method: WorkbenchDeploymentMethod = verb == "status" ? .status :
                (verb == "lookup" ? .lookup : .reconcile)
            let value = try client.performDeployment(method: method,
                params: params([verb == "lookup" ? "planId" : "operationId": words[2]]))
            if verb == "lookup", let absence = value.absence {
                try present(value, human: "No deployment operation has been admitted for plan \(absence.planId).")
                return
            }
            guard let operation = value.operation else { throw WorkbenchIPCError(.invalidRequest) }
            try present(value, human: "Operation \(operation.operationId): \(operation.state.rawValue). Send attempted: \(operation.sendAttempted).")
        case "cancel":
            guard words.count == 4 else { throw Options.usage("deploy cancel PLAN_ID DEVICE_ID") }
            let value = try client.performDeployment(method: .cancel,
                params: params(["planId": words[2], "deviceId": words[3]]))
            try present(value, human: value.operation.map {
                "Cancellation requested for operation \($0.operationId); current state \($0.state.rawValue)."
            } ?? "Plan cancelled before send.")
        default: throw Options.usage("Unknown deploy command.")
        }
    }

    private static func readSetFile(_ path: String) throws -> [String: Any] {
        guard WorkspaceValidation.absolute(path) else { throw Options.usage("--file requires an absolute path.") }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Options.usage("The set file is unavailable or is a symlink.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              (1...65_536).contains(info.st_size) else {
            throw Options.usage("The set file must be a regular JSON file of at most 64 KiB.")
        }
        var data = Data(); var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let read = Darwin.read(fd, &chunk, chunk.count)
            if read < 0 && errno == EINTR { continue }
            guard read >= 0, data.count + read <= 65_536 else { throw Options.usage("The set file exceeds 64 KiB.") }
            if read == 0 { break }
            data.append(contentsOf: chunk.prefix(read))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["packages", "selectedDashboardId", "removedDashboardIds",
                                   "bindingIds", "lifetimeSeconds"] else {
            throw Options.usage("The set file must contain only the exact full-set plan fields.")
        }
        return object
    }
}

enum WorkbenchDeploymentTerminal {
    static func confirm(_ review: WorkbenchDeploymentReview,
                        openTTY: () throws -> Int32) throws -> Bool {
        let fd = try openTTY()
        guard fd >= 0 else { throw WorkbenchIPCError(.confirmationRequired) }
        defer { Darwin.close(fd) }
        var settings = termios()
        guard isatty(fd) == 1, tcgetattr(fd, &settings) == 0 else {
            throw WorkbenchIPCError(.confirmationRequired)
        }
        let expiry = ISO8601DateFormatter().date(from: review.plan.expiresAt)
        guard let expiry, expiry > Date() else { throw WorkbenchIPCError(.confirmationRequired) }
        let deadline = ProcessInfo.processInfo.systemUptime + min(300, expiry.timeIntervalSinceNow)
        let rendered = WorkbenchDeploymentPresentation.render(review)
        guard rendered.utf8.count <= 256 * 1024 else { throw WorkbenchIPCError(.confirmationRequired) }
        let lines = rendered.components(separatedBy: "\n").flatMap(wrap)
        for start in stride(from: 0, to: lines.count, by: 16) {
            let end = min(start + 16, lines.count)
            try write(fd, lines[start..<end].joined(separator: "\n") + "\n")
            if end < lines.count {
                try write(fd, "Press Enter to view the remaining exact deployment scope (anything else cancels): ")
                guard try line(fd, deadline: deadline).isEmpty else { return false }
            }
        }
        try write(fd, "Type APPROVE to install this exact screen set (default no): ")
        return try line(fd, deadline: deadline) == "APPROVE"
    }

    private static func wrap(_ line: String) -> [String] {
        var output: [String] = []; var current = ""
        for scalar in line.unicodeScalars {
            let part = String(scalar)
            if current.utf8.count + part.utf8.count > 160 {
                output.append(current); current = "    "
            }
            current += part
        }
        output.append(current)
        return output
    }
    private static func write(_ fd: Int32, _ value: String) throws {
        let bytes = Array(value.utf8)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkbenchIPCError(.confirmationRequired) }
                offset += count
            }
        }
    }
    private static func line(_ fd: Int32, deadline: TimeInterval) throws -> String {
        var bytes: [UInt8] = []
        while bytes.count <= 128 {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WorkbenchIPCError(.confirmationRequired)
            }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&event, 1, 1000)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw WorkbenchIPCError(.confirmationRequired) }
            if ready == 0 { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw WorkbenchIPCError(.confirmationRequired) }
            if byte == 10 || byte == 13 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        throw WorkbenchIPCError(.confirmationRequired)
    }
}
