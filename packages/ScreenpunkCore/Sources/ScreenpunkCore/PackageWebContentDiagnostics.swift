import Foundation

/// Authoring diagnostics for the host's fixed CSP, not an HTML sanitizer or
/// a replacement for WebKit enforcement. Does not execute package content.
public enum PackageWebContentDiagnostics {
    public struct Issue: Equatable, Sendable {
        public let path: String
        public let line: Int
        public let reason: String
        public var message: String { "\(path):\(line): \(reason)" }
    }

    public static func inspect(files: [String: Data], shouldContinue: () -> Bool = { true }) -> [Issue] {
        var issues: [Issue] = []
        for path in files.keys.sorted() where path.lowercased().hasSuffix(".html") {
            guard let bytes = files[path] else { continue }
            guard shouldContinue() else {
                issues.append(.init(path: path, line: 1, reason: "HTML inspection did not complete; compatibility is unverified."))
                break
            }
            issues += inspectHTML(path: path, bytes: Array(bytes), limit: 16 - issues.count,
                                  shouldContinue: shouldContinue)
            if issues.count >= 16 { break }
        }
        return issues
    }

    private static func inspectHTML(path: String, bytes: [UInt8], limit: Int,
                                    shouldContinue: () -> Bool) -> [Issue] {
        var result: [Issue] = []
        var offset = 0
        var line = 1
        var expired = false
        var nextCheck = 0
        func check(_ index: Int) -> Bool {
            if expired { return false }
            if index >= nextCheck {
                nextCheck = index + 4096
                expired = !shouldContinue()
            }
            return !expired
        }
        func lower(_ b: UInt8) -> UInt8 { (65...90).contains(b) ? b + 32 : b }
        func space(_ b: UInt8) -> Bool { b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }
        func matches(_ value: String, at index: Int) -> Bool {
            let expected = Array(value.utf8)
            return index + expected.count <= bytes.count && expected.indices.allSatisfy { lower(bytes[index + $0]) == expected[$0] }
        }
        func advance(to end: Int) {
            while offset < end && check(offset) { if bytes[offset] == 10 { line += 1 }; offset += 1 }
        }
        func issue(_ reason: String, at sourceLine: Int) {
            if result.count < limit { result.append(.init(path: path, line: sourceLine, reason: reason)) }
        }
        while offset < bytes.count && result.count < limit && check(offset) {
            guard bytes[offset] == 60 else { advance(to: offset + 1); continue }
            if matches("<!--", at: offset) {
                var end = offset + 4
                while end < bytes.count && check(end) && !(bytes[end] == 45 && matches("-->", at: end)) { end += 1 }
                advance(to: min(end + 3, bytes.count)); continue
            }
            let tagLine = line
            var cursor = offset + 1
            guard cursor < bytes.count, (65...90).contains(bytes[cursor]) || (97...122).contains(bytes[cursor]) else {
                advance(to: cursor); continue
            }
            let nameStart = cursor
            while cursor < bytes.count && check(cursor) && !space(bytes[cursor]) && bytes[cursor] != 62 && bytes[cursor] != 47 { cursor += 1 }
            let tag = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
            var attributes: [String: String] = [:]
            while cursor < bytes.count && check(cursor) && bytes[cursor] != 62 {
                if space(bytes[cursor]) || bytes[cursor] == 47 { cursor += 1; continue }
                let start = cursor
                while cursor < bytes.count && check(cursor) && !space(bytes[cursor]) && ![61, 62, 47].contains(bytes[cursor]) { cursor += 1 }
                guard cursor > start else { cursor += 1; continue }
                let name = String(decoding: bytes[start..<cursor], as: UTF8.self).lowercased()
                while cursor < bytes.count && check(cursor) && space(bytes[cursor]) { cursor += 1 }
                var value = ""
                if cursor < bytes.count && bytes[cursor] == 61 {
                    cursor += 1
                    while cursor < bytes.count && check(cursor) && space(bytes[cursor]) { cursor += 1 }
                    if cursor < bytes.count && [34, 39].contains(bytes[cursor]) {
                        let quote = bytes[cursor]; cursor += 1
                        let start = cursor
                        while cursor < bytes.count && check(cursor) && bytes[cursor] != quote { cursor += 1 }
                        value = String(decoding: bytes[start..<cursor], as: UTF8.self)
                        if cursor < bytes.count { cursor += 1 }
                    } else {
                        let start = cursor
                        while cursor < bytes.count && check(cursor) && !space(bytes[cursor]) && bytes[cursor] != 62 { cursor += 1 }
                        value = String(decoding: bytes[start..<cursor], as: UTF8.self)
                    }
                }
                // HTML uses the first duplicate attribute.
                if attributes[name] == nil { attributes[name] = value }
            }
            guard cursor < bytes.count && !expired else { break }
            advance(to: cursor + 1)
            if attributes["style"] != nil {
                issue("Inline style attribute is blocked by style-src 'self'; move CSS into a packaged .css file and use a class.", at: tagLine)
            }
            if attributes.keys.contains(where: { $0.hasPrefix("on") && $0.count > 2 }) {
                issue("Inline event handler is blocked by script-src 'self'; use addEventListener in a packaged .js file.", at: tagLine)
            }
            if tag == "plaintext" { break }
            if ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript"].contains(tag) {
                let bodyStart = offset
                var end = offset
                while end < bytes.count && check(end) {
                    if bytes[end] == 60 && matches("</" + tag, at: end) {
                        let after = end + tag.utf8.count + 2
                        if after == bytes.count || space(bytes[after]) || [47, 62].contains(bytes[after]) { break }
                    }
                    end += 1
                }
                let hasContent = bytes[bodyStart..<end].contains { !space($0) }
                if tag == "style" && hasContent {
                    issue("Inline <style> is blocked by style-src 'self'; use <link rel=\"stylesheet\" href=\"styles.css\"> and include styles.css in the package.", at: tagLine)
                }
                let type = (attributes["type"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let executable = type.isEmpty || type == "module" || type == "importmap" || type == "speculationrules" ||
                    ["text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript", "application/x-javascript", "text/jscript", "text/livescript"].contains(type) || type.hasPrefix("text/javascript1.")
                if tag == "script" && attributes["src"] == nil && hasContent && executable {
                    issue("Inline <script> is blocked by script-src 'self'; use <script src=\"app.js\"></script> and include app.js in the package.", at: tagLine)
                }
                advance(to: end)
            }
        }
        if result.count < limit && (expired || !shouldContinue()) {
            issue("HTML inspection did not complete; compatibility is unverified.", at: line)
        }
        return result
    }
}
