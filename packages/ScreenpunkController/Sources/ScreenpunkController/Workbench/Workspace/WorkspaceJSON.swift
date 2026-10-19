import Foundation

/// Bounded raw parser for portable workspace metadata. Codable alone accepts unknown fields
/// and Foundation JSON parsing accepts duplicate keys; neither is sufficient for open/restore.
enum WorkspaceJSON {
    enum Shape { case descriptor, project, catalog, settings, connections, requirements, sourceKitPin, selection }
    static func object(from data: Data) throws -> [String: Any] {
        guard data.count <= 5 * 1024 * 1024,
              String(data: data, encoding: .utf8) != nil else { throw WorkspaceError.limitExceeded }
        var scanner = Scanner(bytes: Array(data), allowGeneralNumbers: true)
        try scanner.value(depth: 0); scanner.space()
        guard scanner.position == scanner.bytes.count,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkspaceError.invalidSchema
        }
        return object
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, shape: Shape) throws -> T {
        guard data.count <= 8 * 1024 * 1024, String(data: data, encoding: .utf8) != nil else { throw WorkspaceError.limitExceeded }
        var scanner = Scanner(bytes: Array(data)); try scanner.value(depth: 0); scanner.space()
        guard scanner.position == scanner.bytes.count else { throw WorkspaceError.invalidSchema }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkspaceError.invalidSchema }
        try fields(object, shape: shape)
        do { return try JSONDecoder().decode(type, from: data) } catch { throw WorkspaceError.invalidSchema }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 8 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
        return data
    }
    private static func keys(_ object: [String: Any], _ expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw WorkspaceError.invalidSchema }
    }
    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw WorkspaceError.invalidSchema }; return result
    }
    private static func array(_ value: Any?) throws -> [[String: Any]] {
        guard let result = value as? [[String: Any]] else { throw WorkspaceError.invalidSchema }; return result
    }
    private static func fields(_ value: [String: Any], shape: Shape) throws {
        switch shape {
        case .descriptor:
            try keys(value, ["schemaVersion", "workspaceId", "name", "generation", "paths", "defaults", "recovery"])
            try keys(object(value["paths"]), ["screens", "workbench"])
            try keys(object(value["defaults"]), ["projectKind", "template"])
            try keys(object(value["recovery"]), ["scope", "externalProjectPolicy"])
        case .project:
            try keys(value, ["schemaVersion", "projectId", "dashboardId", "name", "kind", "kitVersion", "entry", "screenConfig"])
        case .catalog:
            let base: Set<String> = ["schemaVersion", "generation", "projects"]
            if (value["schemaVersion"] as? Int) == 2 {
                try keys(value, base.union(["archivedDashboardIds"]))
                guard value["archivedDashboardIds"] is [String] else {
                    throw WorkspaceError.invalidSchema
                }
            } else { try keys(value, base) }
            for project in try array(value["projects"]) {
                try keys(project, ["projectId", "dashboardId", "name", "location", "collectionIds", "sortOrder"])
                let location = try object(project["location"])
                if location["kind"] as? String == "workspace" { try keys(location, ["kind", "path"]) }
                else if location["kind"] as? String == "external" { try keys(location, ["kind", "referenceId"]) }
                else { throw WorkspaceError.invalidSchema }
            }
        case .settings:
            let base: Set<String> = ["schemaVersion", "generation", "presentation", "profiles"]
            if (value["schemaVersion"] as? Int) == 2 {
                try keys(value, base.union(["screenIcons"]))
                _ = try object(value["screenIcons"])
            } else {
                try keys(value, base)
            }
            _ = try object(value["presentation"])
            for profile in try object(value["profiles"]).values { _ = try object(profile) }
        case .connections:
            try keys(value, ["schemaVersion", "connections"])
            for item in try array(value["connections"]) { try keys(item, ["serviceId", "kind", "label"]) }
        case .requirements:
            try keys(value, ["schemaVersion", "required"])
            for item in try array(value["required"]) { try keys(item, ["catalogEntryId", "kitVersion", "platform", "inventoryHash"]) }
        case .sourceKitPin:
            try keys(value, ["schemaVersion", "catalogEntryId", "kitVersion", "platform", "inventoryHash"])
        case .selection:
            try keys(value, ["schemaVersion", "activePath", "workspaceId", "selectionGeneration", "bindingId", "rootDevice", "rootInode", "externalBindings"])
            for item in try object(value["externalBindings"]).values {
                try keys(object(item), ["path", "device", "inode"])
            }
        }
    }
    private struct Scanner {
        let bytes: [UInt8]
        var allowGeneralNumbers = false
        var position = 0
        mutating func space() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        mutating func consume(_ byte: UInt8) throws { space(); guard position < bytes.count && bytes[position] == byte else { throw WorkspaceError.invalidSchema }; position += 1 }
        mutating func string() throws -> String {
            space(); let start = position; try consume(34)
            while position < bytes.count {
                let b = bytes[position]; position += 1
                if b == 34 {
                    guard position - start <= 16_386 else { throw WorkspaceError.limitExceeded }
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
                    catch { throw WorkspaceError.invalidSchema }
                }
                guard b >= 32 else { throw WorkspaceError.invalidSchema }
                if b == 92 { guard position < bytes.count else { throw WorkspaceError.invalidSchema }; position += 1 }
            }
            throw WorkspaceError.invalidSchema
        }
        mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard position + expected.count <= bytes.count, Array(bytes[position..<position + expected.count]) == expected else { throw WorkspaceError.invalidSchema }
            position += expected.count
        }
        mutating func number() throws {
            let start = position
            if allowGeneralNumbers {
                if bytes[position] == 45 { position += 1 }
                guard position < bytes.count, bytes[position] >= 48,
                      bytes[position] <= 57 else { throw WorkspaceError.invalidSchema }
                while position < bytes.count {
                    let next = bytes[position]
                    guard [43, 45, 46, 69, 101].contains(next) ||
                          (next >= 48 && next <= 57) else { break }
                    position += 1
                    guard position - start <= 64 else { throw WorkspaceError.limitExceeded }
                }
                return // Foundation validates the complete JSON number grammar.
            }
            guard bytes[position] >= 48 && bytes[position] <= 57 else { throw WorkspaceError.invalidSchema }
            if bytes[position] == 48 { position += 1 }
            else { while position < bytes.count && bytes[position] >= 48 && bytes[position] <= 57 { position += 1 } }
            guard position - start <= 16, let value = Int(String(decoding: bytes[start..<position], as: UTF8.self)), value <= WorkspaceValidation.maxUInt else { throw WorkspaceError.invalidSchema }
            if position < bytes.count && [46, 69, 101].contains(bytes[position]) { throw WorkspaceError.invalidSchema }
        }
        mutating func value(depth: Int) throws {
            guard depth <= 32 else { throw WorkspaceError.limitExceeded }; space()
            guard position < bytes.count else { throw WorkspaceError.invalidSchema }
            switch bytes[position] {
            case 34: _ = try string()
            case 48...57: try number()
            case 45 where allowGeneralNumbers: try number()
            case 110: try literal("null")
            case 116: try literal("true")
            case 102: try literal("false")
            case 123:
                position += 1; space(); var found = Set<String>()
                if position < bytes.count && bytes[position] == 125 { position += 1; return }
                while true {
                    let key = try string()
                    guard found.insert(key).inserted, found.count <= 100_000 else { throw WorkspaceError.invalidSchema }
                    try consume(58); try value(depth: depth + 1); space()
                    if position < bytes.count && bytes[position] == 125 { position += 1; return }
                    try consume(44)
                }
            case 91:
                position += 1; space(); var count = 0
                if position < bytes.count && bytes[position] == 93 { position += 1; return }
                while true {
                    count += 1; guard count <= 100_000 else { throw WorkspaceError.limitExceeded }
                    try value(depth: depth + 1); space()
                    if position < bytes.count && bytes[position] == 93 { position += 1; return }
                    try consume(44)
                }
            default: throw WorkspaceError.invalidSchema
            }
        }
    }
}
