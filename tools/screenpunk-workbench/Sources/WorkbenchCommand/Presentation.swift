import Foundation
import Darwin
import ScreenpunkController

/// Display-only escaping. Structured JSON values retain their exact Unicode text.
public enum TerminalPresentation {
    public static func safe(_ text: String) -> String {
        var output = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let unsafe = value < 0x20 || (0x7f...0x9f).contains(value)
                || (0x202a...0x202e).contains(value) || (0x2066...0x2069).contains(value)
                || value == 0x061c || value == 0x200e || value == 0x200f
                || value == 0x2028 || value == 0x2029
            let next = unsafe ? String(format: "\\u{%04X}", value) : String(scalar)
            if used + next.utf8.count > 4096 { output += " [truncated]"; break }
            output += next; used += next.utf8.count
        }
        return output
    }
}

struct Presentation {
    let json: Bool
    let requestID = UUID().uuidString.lowercased()
    func diagnostic(_ value: String) {
        _ = Self.write(Data((TerminalPresentation.safe(value) + "\n").utf8), to: STDERR_FILENO)
    }
    func success(_ result: [String: Any], human: String) {
        if json { _ = envelope(["apiVersion": "1.0", "requestId": requestID, "ok": true, "result": result]) }
        else { _ = Self.write(Data((human + "\n").utf8), to: STDOUT_FILENO) }
    }
    /// Mutations that have already been confirmed use this checked writer so
    /// closed stdout becomes a Swift error and the caller can report outcome.
    func checkedSuccess(_ result: [String: Any], human: String) throws {
        let bytes: Data
        if json {
            let envelope: [String: Any] = ["apiVersion": "1.0", "requestId": requestID,
                "ok": true, "result": result]
            guard JSONSerialization.isValidJSONObject(envelope) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) + Data([10])
        } else { bytes = Data((human + "\n").utf8) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(STDOUT_FILENO,
                    raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkbenchIPCError(.unavailable) }
                offset += count
            }
        }
    }
    func failure(_ failure: CommandFailure) {
        if json {
            let delivered = envelope(["apiVersion": "1.0", "requestId": requestID, "ok": false, "error": [
                "code": failure.code, "message": failure.message, "retryable": false,
                "details": failure.details, "nextActions": failure.nextActions
            ]])
            if !delivered { diagnostic("\(failure.code): \(failure.message)") }
        } else {
            diagnostic("\(failure.code): \(failure.message)")
            for key in failure.details.keys.sorted() { diagnostic("\(key): \(failure.details[key]!)") }
            for action in failure.nextActions { diagnostic(action) }
        }
    }
    @discardableResult private func envelope(_ value: [String: Any]) -> Bool {
        // All values originate from closed DTOs or tool-local fixed messages.
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return false }
        return Self.write(data + Data([10]), to: STDOUT_FILENO)
    }
    private static func write(_ bytes: Data, to fd: Int32) -> Bool {
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
