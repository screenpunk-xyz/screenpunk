import Foundation

/// Native schema2-only strict preflight. No public generic parser or legacy decoder changes.
/// Canonically equivalent decoded object keys are rejected as ambiguous before Foundation maps them.
enum DeviceNativeGrantRevisionPreflight {
    static func validate(_ bytes: Data) throws {
        guard bytes.count <= DeviceNativeGrantRevisionQualifier.privateLimit else { throw DeviceNativeGrantRevisionQualificationError.sizeLimit }
        guard String(data: bytes, encoding: .utf8) != nil else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
        try bytes.withUnsafeBytes { raw in
            var scanner = Scanner(bytes: raw.bindMemory(to: UInt8.self), remaining: 65_536)
            try scanner.value(depth: 0); scanner.space()
            guard scanner.index == scanner.bytes.count else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
        }
    }
    static func decode(_ bytes: Data) throws -> DeviceNativeGrantRevisionInput {
        try validate(bytes)
        do {
            let raw = try JSONSerialization.jsonObject(with: bytes)
            try rawBounds(raw)
            let decoded = try JSONDecoder().decode(DeviceNativeGrantRevisionInput.self, from: bytes)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let canonical = try encoder.encode(decoded)
            try knownShape(raw, JSONSerialization.jsonObject(with: canonical))
            return decoded
        } catch let error as DeviceNativeGrantRevisionQualificationError { throw error }
        catch { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
    }
    /// Check allocation-bearing typed arrays and base64 sizes BEFORE JSONDecoder copies credentials.
    /// Foundation's raw object is itself bounded by the prior 4MiB/depth/node lexical preflight.
    private static func rawBounds(_ raw: Any) throws {
        guard let root = raw as? [String: Any] else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
        func array(_ object: [String: Any], _ key: String, _ maximum: Int, required: Bool = false) throws -> [Any] {
            guard let value = object[key] else { if required { throw DeviceNativeGrantRevisionQualificationError.invalidInput }; return [] }
            guard let values = value as? [Any], values.count <= maximum else { throw DeviceNativeGrantRevisionQualificationError.sizeLimit }; return values
        }
        func map(_ raw: Any) throws -> [String: Any] { guard let object = raw as? [String: Any] else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }; return object }
        var uniqueBytes = 0, inlineBytes = 0
        func base64Size(_ value: Any, total: inout Int) throws {
            guard let value = value as? String, !value.isEmpty, value.utf8.count <= 10_924, value.utf8.count % 4 == 0,
                  value.range(of: "^[A-Za-z0-9+/]+={0,2}\\z", options: .regularExpression) != nil else { throw DeviceNativeGrantRevisionQualificationError.sizeLimit }
            let padding = value.hasSuffix("==") ? 2 : (value.hasSuffix("=") ? 1 : 0)
            let size = value.utf8.count / 4 * 3 - padding
            guard size > 0, size <= DeviceNativeGrantRevisionQualifier.secretLimit,
                  size <= DeviceNativeGrantRevisionQualifier.aggregateSecretLimit - total else { throw DeviceNativeGrantRevisionQualificationError.sizeLimit }; total += size
        }
        let entries = try array(root, "entries", 12, required: true)
        for item in try array(root, "credentials", 396, required: true) { try base64Size(map(item)["bytes"] as Any, total: &uniqueBytes) }
        _ = try array(root, "retainedRevisions", 128, required: true)
        let owner=try map(root["owner"] as Any)
        guard Set(owner.keys.map{Data($0.utf8)}) == Set(["kind","installationID","accountID","locationID","transitionID"].map{Data($0.utf8)}),
              let kind=owner["kind"] as? String,kind.utf8.elementsEqual("nativeInstallation".utf8) else{throw DeviceNativeGrantRevisionQualificationError.invalidInput}
        for field in ["installationID","accountID","locationID","transitionID"] {
            guard let value=owner[field] as? String,value.utf8.count == 36,let id=UUID(uuidString:value),value.utf8.elementsEqual(id.uuidString.lowercased().utf8) else{throw DeviceNativeGrantRevisionQualificationError.invalidInput}
        }
        for entry in entries {
            let entry = try map(entry); _ = try array(entry, "credentialReferences", 33, required: true)
            if let generic = entry["generic"] {
                for item in try array(map(generic), "entries", 32, required: true) {
                    let item = try map(item)
                    if let secret = item["secret"] { try base64Size(secret, total: &inlineBytes) }
                    if let grant = item["grant"] { _ = try array(map(grant), "operations", 32, required: true) }
                }
            }
            if let home = entry["homeAssistant"] {
                let home = try map(home)
                guard let token = home["token"] as? String, token.utf8.count <= DeviceNativeGrantRevisionQualifier.secretLimit,
                      token.utf8.count <= DeviceNativeGrantRevisionQualifier.aggregateSecretLimit - inlineBytes else { throw DeviceNativeGrantRevisionQualificationError.sizeLimit }
                inlineBytes += token.utf8.count
                for call in try array(home, "serviceCalls", 128) { _ = try array(map(call), "entityIds", 128, required: true) }
                _ = try array(home, "cameraEntities", 16)
            }
            if let reads = entry["publicReads"] {
                for connection in try array(map(reads), "connections", 8, required: true) {
                    let connection = try map(connection)
                    // PublicReadProvisioning rejects other capability kinds; avoid allocating those arrays.
                    guard connection["operations"] == nil, connection["serviceCalls"] == nil, connection["cameraEntities"] == nil else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
                    if let declaration = connection["publicHTTP"] {
                        for operation in try array(map(declaration), "operations", 16, required: true) {
                            let operation = try map(operation)
                            if let parameters = operation["parameters"] {
                                let parameters = try map(parameters); guard parameters.count <= 12 else { throw DeviceNativeGrantRevisionQualificationError.sizeLimit }
                                for parameter in parameters.values { _ = try array(map(parameter), "values", 64) }
                            }
                        }
                    }
                }
            }
        }
    }
    /// Native Codable shape defines this new input schema. Explicit null optional fields are excluded
    /// from its representation; absent optionals are canonical. Nested unknown fields never disappear.
    private static func knownShape(_ raw: Any, _ canonical: Any) throws {
        if let object = raw as? [String: Any] {
            guard let expected = canonical as? [String: Any], Set(object.keys) == Set(expected.keys) else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
            for (key, value) in object { try knownShape(value, expected[key]!) }
        } else if let array = raw as? [Any] {
            guard let expected = canonical as? [Any], array.count == expected.count else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
            for (item, expectedItem) in zip(array, expected) { try knownShape(item, expectedItem) }
        } else if canonical is [String: Any] || canonical is [Any] { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
    }
    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>; var remaining: Int; var index = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func require(_ byte: UInt8) throws { guard index < bytes.count, bytes[index] == byte else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }; index += 1 }
        mutating func value(depth: Int) throws {
            space(); remaining -= 1
            guard depth <= 32, remaining >= 0, index < bytes.count else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
            switch bytes[index] {
            case 123:
                index += 1; space(); var keys = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    remaining -= 1;guard remaining >= 0 else{throw DeviceNativeGrantRevisionQualificationError.invalidInput}
                    let key = try string(); guard keys.insert(key).inserted else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
                    space(); try require(58); try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 125 { index += 1; return }
                    try require(44); space()
                }
            case 91:
                index += 1; space()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 93 { index += 1; return }
                    try require(44)
                }
            case 34: _ = try string()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            default:
                let start = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                guard text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
            }
        }
        mutating func literal(_ value: String) throws { for byte in value.utf8 { try require(byte) } }
        mutating func hex() throws -> UInt16 {
            var result: UInt16 = 0
            for _ in 0..<4 {
                guard index < bytes.count else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
                let byte = bytes[index]; index += 1
                let value: UInt16
                switch byte { case 48...57: value = UInt16(byte-48); case 65...70: value = UInt16(byte-55); case 97...102: value = UInt16(byte-87); default: throw DeviceNativeGrantRevisionQualificationError.invalidInput }
                result = result * 16 + value
            }
            return result
        }
        mutating func string() throws -> String {
            let start = index; try require(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                guard byte >= 32 else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
                if byte == 92 {
                    guard index < bytes.count else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
                    let escape = bytes[index]; index += 1
                    if escape == 117 {
                        let scalar = try hex()
                        if (0xD800...0xDBFF).contains(scalar) {
                            try require(92); try require(117); let low = try hex()
                            guard (0xDC00...0xDFFF).contains(low) else { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
                        } else if (0xDC00...0xDFFF).contains(scalar) { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
                    } else if ![34,92,47,98,102,110,114,116].contains(escape) { throw DeviceNativeGrantRevisionQualificationError.invalidInput }
                }
            }
            throw DeviceNativeGrantRevisionQualificationError.invalidInput
        }
    }
}
