import Foundation

// Read contracts admit only nonnegative, exactly representable JSON integers.
// Device settings additionally admit finite 0...1 brightness values at closed paths.
// This scanner rejects duplicate keys (including escaped
// aliases), invalid string encoding, excessive depth/collections and trailing input before
// Foundation decoding. It is deliberately not the future authoring/plan JSON parser.
enum WorkbenchWireJSON {
    static func object(_ data: Data, allowSourceChunk: Bool = false,
                       allowImportPayload: Bool = false,
                       allowPackageManifest: Bool = false, allowDeviceSettings: Bool = false,
                       allowMigrationPlan: Bool = false, allowWorkspacePackageChunk: Bool = false) throws -> [String: Any] {
        guard String(data: data, encoding: .utf8) != nil else { throw WorkbenchIPCError(.invalidRequest) }
        var scanner = Scanner(bytes: Array(data), allowSourceChunk: allowSourceChunk,
            allowImportPayload: allowImportPayload, allowMigrationPlan: allowMigrationPlan, allowWorkspacePackageChunk: allowWorkspacePackageChunk, allowDeviceSettings: allowDeviceSettings, allowPackageManifest: allowPackageManifest)
        try scanner.value(depth: 0); scanner.space()
        guard scanner.position == scanner.bytes.count else { throw WorkbenchIPCError(.invalidRequest) }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw WorkbenchIPCError(.invalidRequest) }
            return object
        } catch { throw WorkbenchIPCError(.invalidRequest) }
    }
    private struct Scanner {
        let bytes: [UInt8]
        let allowSourceChunk: Bool
        let allowImportPayload: Bool
        let allowMigrationPlan: Bool
        let allowWorkspacePackageChunk: Bool
        let allowDeviceSettings: Bool
        let allowPackageManifest: Bool
        var position = 0
        mutating func space() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        mutating func consume(_ byte: UInt8) throws {
            space(); guard position < bytes.count && bytes[position] == byte else { throw WorkbenchIPCError(.invalidRequest) }
            position += 1
        }
        mutating func string(maxBytes: Int = 4096) throws -> String {
            space(); let start = position; try consume(34)
            while position < bytes.count {
                let b = bytes[position]; position += 1
                if b == 34 {
                    guard position - start <= maxBytes else { throw WorkbenchIPCError(.invalidRequest) }
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
                    catch { throw WorkbenchIPCError(.invalidRequest) }
                }
                guard b >= 32 else { throw WorkbenchIPCError(.invalidRequest) }
                if b == 92 { guard position < bytes.count else { throw WorkbenchIPCError(.invalidRequest) }; position += 1 }
            }
            throw WorkbenchIPCError(.invalidRequest)
        }
        mutating func literal(_ value: String) throws {
            let expected = Array(value.utf8)
            guard position + expected.count <= bytes.count,
                  Array(bytes[position..<position + expected.count]) == expected else { throw WorkbenchIPCError(.invalidRequest) }
            position += expected.count
        }
        mutating func integer() throws {
            let start = position
            var value: UInt64 = 0
            while position < bytes.count && (48...57).contains(bytes[position]) {
                let digit = UInt64(bytes[position] - 48)
                guard value <= (9_007_199_254_740_991 - digit) / 10 else { throw WorkbenchIPCError(.invalidRequest) }
                value = value * 10 + digit
                position += 1
            }
            guard position - start == 1 || bytes[start] != 48 else { throw WorkbenchIPCError(.invalidRequest) }
        }
        private func brightnessPath(_ path: [String]) -> Bool {
            guard allowDeviceSettings else { return false }
            let prefixes = [["params", "value"], ["result", "settings", "value"]]
            return prefixes.contains { prefix in
                path == prefix + ["brightness", "fixedLevel"] ||
                path == prefix + ["brightness", "schedule", "*", "level"]
            }
        }
        mutating func brightnessNumber() throws {
            let start = position
            if bytes[position] == 45 { position += 1 }
            guard position < bytes.count, (48...57).contains(bytes[position]) else { throw WorkbenchIPCError(.invalidRequest) }
            if bytes[position] == 48 { position += 1 }
            else { while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 } }
            if position < bytes.count && bytes[position] == 46 {
                position += 1; let fraction = position
                while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 }
                guard position > fraction else { throw WorkbenchIPCError(.invalidRequest) }
            }
            if position < bytes.count && (bytes[position] == 101 || bytes[position] == 69) {
                position += 1
                if position < bytes.count && (bytes[position] == 43 || bytes[position] == 45) { position += 1 }
                let exponent = position
                while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 }
                guard position > exponent else { throw WorkbenchIPCError(.invalidRequest) }
            }
            guard position - start <= 128,
                  let value = Double(String(decoding: bytes[start..<position], as: UTF8.self)),
                  value.isFinite, (0...1).contains(value) else { throw WorkbenchIPCError(.invalidRequest) }
        }
        mutating func value(depth: Int, maxStringBytes: Int = 4096, path: [String] = []) throws {
            guard depth <= 32 else { throw WorkbenchIPCError(.invalidRequest) }; space()
            guard position < bytes.count else { throw WorkbenchIPCError(.invalidRequest) }
            switch bytes[position] {
            case 34: _ = try string(maxBytes: maxStringBytes)
            case 110: try literal("null")
            case 116: try literal("true")
            case 102: try literal("false")
            case 45, 48...57:
                if brightnessPath(path) { try brightnessNumber() }
                else { guard bytes[position] != 45 else { throw WorkbenchIPCError(.invalidRequest) }; try integer() }
            case 123:
                position += 1; space(); var keys = Set<String>()
                if position < bytes.count && bytes[position] == 125 { position += 1; return }
                while true {
                    let key = try string()
                    guard keys.insert(key).inserted, keys.count <= 64 else { throw WorkbenchIPCError(.invalidRequest) }
                    try consume(58)
                    // Only the closed project.patch change-item payload can
                    // carry a 5 MiB file through the 8 MiB frame. All other
                    // wire strings retain the 4 KiB anti-abuse bound.
                    let sourceBytesLimit = depth == 3 && key == "bytesBase64"
                        ? 6_990_510 : (allowImportPayload && depth == 1 && key == "manifestBase64"
                            ? ((4 * 1024 * 1024 + 2) / 3) * 4 + 2
                            : ((allowSourceChunk || allowImportPayload) && key == "bytesBase64" && (depth == 0 || depth == 1)
                                ? ((WorkbenchSourceChunkRequest.chunkBytes + 2) / 3) * 4 + 2 : 4096))
                    let packageBytes = allowWorkspacePackageChunk && key == "bytes" &&
                        [["chunk"], ["result", "chunk"]].contains(path)
                    if packageBytes {
                        let base64Limit = ((64 * 1024 + 2) / 3) * 4
                        // Account for JSON escapes, then enforce the decoded
                        // transport limit rather than the serialized spelling.
                        let encoded = try string(maxBytes: base64Limit * 6 + 2)
                        guard encoded.utf8.count <= base64Limit,
                              let chunk = Data(base64Encoded: encoded), chunk.count <= 64 * 1024 else {
                            throw WorkbenchIPCError(.invalidRequest)
                        }
                    } else {
                        try value(depth: depth + 1, maxStringBytes: sourceBytesLimit, path: path + [key])
                    }
                    space()
                    if position < bytes.count && bytes[position] == 125 { position += 1; return }
                    try consume(44)
                }
            case 91:
                position += 1; space(); var count = 0
                if position < bytes.count && bytes[position] == 93 { position += 1; return }
                // Migration preserves every revision. Only these closed response
                // paths may exceed the ordinary collection bound; requests and
                // unrelated response fields keep their existing limits.
                let migrationInventory = allowMigrationPlan && [
                    ["migrationPlan", "projectIds"],
                    ["migrationPlan", "packageRevisions"],
                    ["migrationPlan", "unsupportedPortablePaths"],
                    ["result", "migrationPlan", "projectIds"],
                    ["result", "migrationPlan", "packageRevisions"],
                    ["result", "migrationPlan", "unsupportedPortablePaths"]
                ].contains(path)
                let limit = migrationInventory ? 10_000 : (allowPackageManifest ? 2_000 : 128)
                while true {
                    count += 1; guard count <= limit else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    try value(depth: depth + 1, path: path + ["*"]); space()
                    if position < bytes.count && bytes[position] == 93 { position += 1; return }
                    try consume(44)
                }
            default: throw WorkbenchIPCError(.invalidRequest)
            }
        }
    }
}
