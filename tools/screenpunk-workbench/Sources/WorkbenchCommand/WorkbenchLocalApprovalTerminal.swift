import Foundation
import Darwin
import ScreenpunkController

/// Controlling-TTY workflow for a broker-frozen local review. This is native
/// client behavior under the same-user trust model, not human attestation.
enum WorkbenchLocalApprovalTerminal {
    static func confirm(_ review: WorkbenchHomeAssistantReview, noInput: Bool,
                        openTTY: () throws -> Int32 = {
                            Darwin.open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOCTTY)
                        }) throws -> Bool {
        guard !noInput else { throw WorkbenchIPCError(.confirmationRequired) }
        try review.validate()
        let fd = try openTTY()
        guard fd >= 0 else { throw WorkbenchIPCError(.confirmationRequired) }
        defer { Darwin.close(fd) }
        var settings = termios()
        guard isatty(fd) == 1, tcgetattr(fd, &settings) == 0 else {
            throw WorkbenchIPCError(.confirmationRequired)
        }
        let seconds = min(300, max(0, review.reviewExpiresAt.timeIntervalSinceNow))
        guard seconds > 0 else { throw WorkbenchIPCError(.confirmationRequired) }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let declaration = String(decoding: try encoder.encode(review.declaration), as: UTF8.self)
        var lines = [
            "Screenpunk Home Assistant setup review — new device credential and scoped revision",
            "Controller owner pin: \(escapeComplete(review.ownerPin))",
            "Device: \(escapeComplete(review.deviceId))  Device peer pin: \(escapeComplete(review.devicePin))",
            "Pairing epoch: \(escapeComplete(review.pairingEpoch))",
            "Workspace: \(escapeComplete(review.workspaceId))  Selection: \(review.selectionGeneration)",
            "Dashboard: \(escapeComplete(review.dashboardId))  Revision: \(escapeComplete(review.revision))",
            "Package digest: \(escapeComplete(review.packageDigest))",
            "Home Assistant origin: \(escapeComplete(review.origin))",
            "Connection ID: \(escapeComplete(review.connectionId))",
            "Authentication: bearer token entered after this review; stored in local Keychain",
            "API check: authenticated /api/, redirects denied, 16,384-byte response limit, 10-second timeout",
            "Exact home declaration: \(escapeComplete(declaration))",
            "Declaration hash: \(review.declarationHash)",
            "Authorization context hash: \(review.authorizationContextHash)",
            "Intent: \(review.intentId)  Review expires: \(ISO8601DateFormatter().string(from: review.reviewExpiresAt))"
        ]
        guard lines.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1024 else {
            throw WorkbenchIPCError(.confirmationRequired)
        }
        lines = lines.flatMap { wrap($0, width: 160) }
        for start in stride(from: 0, to: lines.count, by: 16) {
            let end = min(start + 16, lines.count)
            try write(fd, lines[start..<end].joined(separator: "\n") + "\n")
            if end < lines.count {
                try write(fd, "Press Enter to view the remaining scope (anything else cancels): ")
                guard try line(fd, deadline: deadline).isEmpty else { return false }
            }
        }
        try write(fd, "Type APPROVE to validate and install this exact Home Assistant scope (default no): ")
        return try line(fd, deadline: deadline) == "APPROVE"
    }

    static func confirm(_ review: WorkbenchConnectionReview, noInput: Bool,
                        openTTY: () throws -> Int32 = {
                            Darwin.open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOCTTY)
                        }) throws -> Bool {
        guard !noInput else { throw WorkbenchIPCError(.confirmationRequired) }
        let fd = try openTTY()
        guard fd >= 0 else { throw WorkbenchIPCError(.confirmationRequired) }
        defer { Darwin.close(fd) }
        var settings = termios()
        guard isatty(fd) == 1, tcgetattr(fd, &settings) == 0 else {
            throw WorkbenchIPCError(.confirmationRequired)
        }
        let seconds = min(300, max(0, review.reviewExpiresAt.timeIntervalSinceNow))
        guard seconds > 0 else { throw WorkbenchIPCError(.confirmationRequired) }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        // Review authority must never be silently shortened. The general
        // diagnostic presenter truncates at 4096 bytes, which can hide the
        // end of a long operation path before the approval prompt.
        let safe = escapeComplete
        let expires = ISO8601DateFormatter().string(from: review.reviewExpiresAt)
        var lines = [
            "Screenpunk local connection review — new grant; no removals",
            "Untrusted label: [\(safe(review.summary.alias))]",
            "Controller owner pin: \(safe(review.ownerPin))",
            "Owner epoch: \(safe(review.ownerEpoch))",
            "Device: \(safe(review.summary.deviceId))",
            "Device peer pin: \(safe(review.devicePin))",
            "Pairing epoch: \(safe(review.pairingEpoch))",
            "Dashboard: \(safe(review.summary.dashboardId))  Revision: \(safe(review.summary.revision))",
            "Physical endpoint: \(safe(review.endpoint))",
            "Network permission: \(safe(review.summary.origin))",
            "Transport: \(safe(review.summary.transport))",
            "Authentication: \(safe(review.summary.authenticationPlacement)) \(safe(review.summary.authenticationField ?? ""))",
            "Redirect policy: \(safe(review.summary.redirectPolicy))",
            "Limits: \(review.summary.maximumResponseBytes) bytes, \(review.summary.timeoutSeconds) seconds",
            "Credential generation: \(review.credentialGeneration)  Grant generation: \(review.grantGeneration)",
            "Declaration hash: \(safe(review.declarationHash))",
            "Authorization context hash: \(safe(review.authorizationContextHash))",
            "Intent: \(safe(review.intentId))  Review expires: \(safe(expires))",
            "Operations (\(review.summary.operations.count)):",
        ]
        for (index, operation) in review.summary.operations.enumerated() {
            lines.append("\(index + 1). \(safe(operation.name))  \(safe(operation.method))  \(safe(operation.address))  writes=\(operation.writes)")
        }
        guard lines.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1024 else {
            throw WorkbenchIPCError(.confirmationRequired)
        }
        lines = lines.flatMap { wrap($0, width: 160) }
        for start in stride(from: 0, to: lines.count, by: 16) {
            let end = min(start + 16, lines.count)
            try write(fd, lines[start..<end].joined(separator: "\n") + "\n")
            if end < lines.count {
                try write(fd, "Press Enter to view the remaining scope (anything else cancels): ")
                guard try line(fd, deadline: deadline).isEmpty else { return false }
            }
        }
        try write(fd, "Type APPROVE to authorize this exact grant (default no): ")
        return try line(fd, deadline: deadline) == "APPROVE"
    }

    private static func escapeComplete(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let unsafe = code < 0x20 || (0x7f...0x9f).contains(code)
                || (0x202a...0x202e).contains(code) || (0x2066...0x2069).contains(code)
                || code == 0x061c || code == 0x200e || code == 0x200f
                || code == 0x2028 || code == 0x2029
            output += unsafe ? String(format: "\\u{%04X}", code) : String(scalar)
        }
        return output
    }

    private static func wrap(_ line: String, width: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for scalar in line.unicodeScalars {
            let part = String(scalar)
            if current.utf8.count + part.utf8.count > width {
                result.append(current)
                current = "    "
            }
            current += part
        }
        result.append(current)
        return result
    }

    private static func write(_ fd: Int32, _ value: String) throws {
        let bytes = Array(value.utf8)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw WorkbenchIPCError(.confirmationRequired) }
                offset += written
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
