import Foundation
import CryptoKit
import CoreFoundation

enum ToolchainTrustError: Error, Equatable {
    case trustUnavailable, catalogStateMissing, invalidCatalog, unknownSigner, signatureInvalid, staleCatalog
    case revokedSigner, expiredSigner, unknownPublisher, unknownKit, requirementMismatch
    case kitMissing, unsafePath, inventoryMismatch, artifactMismatch, publisherUnverified, limitExceeded
    case conflictingCatalog
}

struct ToolchainPublisher: Codable, Equatable, Hashable {
    let teamIdentifier: String
    let signingIdentifier: String
    func validate() throws {
        guard teamIdentifier.utf8.count == 10,
              teamIdentifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              WorkspaceValidation.id(signingIdentifier) else { throw ToolchainTrustError.invalidCatalog }
    }
}

struct ToolchainInventoryItem: Codable, Equatable {
    let path: String
    let sha256: String
    let bytes: Int
    let role: String
    let publisher: ToolchainPublisher?
}

struct ToolchainCatalogEntry: Codable, Equatable {
    let catalogEntryId: String
    let kind: String
    let version: String
    let platform: String
    let artifactSha256: String
    let artifactBytes: Int
    let downloadURL: String
    /// A measured member of an authenticated standalone distribution. Exactly one
    /// of this path and downloadURL is populated; neither is an authority source.
    let embeddedArtifactPath: String?
    let publisher: ToolchainPublisher
    let inventoryHash: String
    let inventory: [ToolchainInventoryItem]
    let protocolMajor: Int?

    init(catalogEntryId: String, kind: String, version: String, platform: String,
         artifactSha256: String, artifactBytes: Int, downloadURL: String,
         embeddedArtifactPath: String? = nil, publisher: ToolchainPublisher,
         inventoryHash: String, inventory: [ToolchainInventoryItem], protocolMajor: Int?) {
        self.catalogEntryId = catalogEntryId; self.kind = kind; self.version = version
        self.platform = platform; self.artifactSha256 = artifactSha256
        self.artifactBytes = artifactBytes; self.downloadURL = downloadURL
        self.embeddedArtifactPath = embeddedArtifactPath; self.publisher = publisher
        self.inventoryHash = inventoryHash; self.inventory = inventory
        self.protocolMajor = protocolMajor
    }

    func validate() throws {
        guard WorkspaceValidation.id(catalogEntryId), WorkspaceValidation.id(version),
              ["authoringKit", "runtime", "legacyHelper"].contains(kind), platform == "darwin-arm64",
              WorkspaceValidation.sha256(artifactSha256), (0...1_073_741_824).contains(artifactBytes),
              downloadURL.utf8.count <= 2048,
              ((embeddedArtifactPath == nil && !downloadURL.isEmpty) ||
               (downloadURL.isEmpty && embeddedArtifactPath != nil)),
              embeddedArtifactPath.map({ path in
                  path.hasPrefix("Resources/Toolchains/") && path.hasSuffix(".tar") &&
                  WorkspaceValidation.member(path) &&
                  path == path.precomposedStringWithCanonicalMapping
              }) ?? true,
              WorkspaceValidation.sha256(inventoryHash),
              inventory.count <= 100_000 else { throw ToolchainTrustError.invalidCatalog }
        try publisher.validate()
        if kind == "authoringKit" {
            guard protocolMajor == nil else { throw ToolchainTrustError.invalidCatalog }
        } else {
            guard let protocolMajor, (1...65_535).contains(protocolMajor) else { throw ToolchainTrustError.invalidCatalog }
        }
        var previous: String?
        var normalized = Set<String>()
        var files = Set<String>()
        var directories: [String: String] = [:]
        var expanded = 0
        for item in inventory {
            guard WorkspaceValidation.member(item.path), item.path == item.path.precomposedStringWithCanonicalMapping,
                  WorkspaceValidation.sha256(item.sha256), item.bytes >= 0,
                  item.bytes <= 2_147_483_648 - expanded else { throw ToolchainTrustError.invalidCatalog }
            if let previous {
                guard ToolchainCanonical.utf8Less(previous, item.path) else { throw ToolchainTrustError.invalidCatalog }
            }
            previous = item.path
            let key = WorkspaceValidation.portableKey(item.path)
            guard normalized.insert(key).inserted else { throw ToolchainTrustError.invalidCatalog }
            files.insert(key)
            let parts = item.path.split(separator: "/").map(String.init)
            for index in 1..<parts.count {
                let directory = parts.prefix(index).joined(separator: "/")
                let canonical = WorkspaceValidation.portableKey(directory)
                if let earlier = directories[canonical], earlier != directory { throw ToolchainTrustError.invalidCatalog }
                directories[canonical] = directory
            }
            if item.role == "executable" {
                guard let publisher = item.publisher else { throw ToolchainTrustError.invalidCatalog }
                try publisher.validate()
            } else {
                guard item.role == "resource", item.publisher == nil else { throw ToolchainTrustError.invalidCatalog }
            }
            expanded += item.bytes
        }
        if kind == "authoringKit" {
            let byPath = Dictionary(uniqueKeysWithValues: inventory.map { ($0.path, $0.role) })
            guard byPath["bin/node"] == "executable", byPath["scripts/build.mjs"] == "resource",
                  byPath["kit.json"] == "resource" else { throw ToolchainTrustError.invalidCatalog }
        }
        guard !files.isEmpty, files.isDisjoint(with: directories.keys),
              try ToolchainCanonical.inventoryHash(inventory) == inventoryHash else {
            throw ToolchainTrustError.invalidCatalog
        }
    }
}

struct ToolchainCatalogPayload: Codable, Equatable {
    let catalogVersion: Int
    let catalogId: String
    let channel: String
    let sequence: Int
    let entries: [ToolchainCatalogEntry]
    func validate() throws {
        guard catalogVersion == 1, WorkspaceValidation.id(catalogId), ["stable", "beta"].contains(channel),
              sequence >= 0, sequence <= WorkspaceValidation.maxUInt, entries.count <= 128 else {
            throw ToolchainTrustError.invalidCatalog
        }
        var ids = Set<String>()
        for entry in entries {
            try entry.validate()
            guard ids.insert(entry.catalogEntryId).inserted else { throw ToolchainTrustError.invalidCatalog }
        }
    }
}

struct ToolchainCatalogEnvelope: Codable {
    let signatureVersion: Int
    let algorithm: String
    let signerKeyId: String
    let signatureBase64: String
    let payload: ToolchainCatalogPayload
}

/// The M0 typed encoding, not JSON canonicalization. JSON text order/spacing is irrelevant.
enum ToolchainCanonical {
    static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
    static func encode(_ value: Any) throws -> Data {
        var output = Data()
        try append(value, to: &output)
        return output
    }
    static func hash(domain: String, value: Any) throws -> String {
        var bytes = Data("screenpunk/\(domain)/v1".utf8)
        bytes.append(0)
        bytes.append(try encode(value))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func inventoryHash(_ inventory: [ToolchainInventoryItem]) throws -> String {
        let json = try JSONEncoder().encode(inventory)
        let value = try JSONSerialization.jsonObject(with: json)
        return try hash(domain: "inventory", value: value)
    }
    private static func length(_ count: Int, to output: inout Data) throws {
        guard count >= 0, count <= WorkspaceValidation.maxUInt else { throw ToolchainTrustError.invalidCatalog }
        var big = UInt64(count).bigEndian
        withUnsafeBytes(of: &big) { output.append(contentsOf: $0) }
    }
    private static func append(_ value: Any, to output: inout Data) throws {
        if value is NSNull { output.append(UInt8(ascii: "n")); return }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                output.append(UInt8(ascii: number.boolValue ? "t" : "f")); return
            }
            let integer = number.int64Value
            guard integer >= 0, integer <= WorkspaceValidation.maxUInt,
                  number.stringValue == String(integer) else { throw ToolchainTrustError.invalidCatalog }
            output.append(UInt8(ascii: "i"))
            try length(Int(integer), to: &output)
            return
        }
        if let string = value as? String {
            let bytes = Data(string.utf8)
            output.append(UInt8(ascii: "s"))
            try length(bytes.count, to: &output)
            output.append(bytes)
            return
        }
        if let array = value as? [Any] {
            output.append(UInt8(ascii: "a"))
            try length(array.count, to: &output)
            for item in array { try append(item, to: &output) }
            return
        }
        if let object = value as? [String: Any] {
            output.append(UInt8(ascii: "o"))
            try length(object.count, to: &output)
            for key in object.keys.sorted(by: utf8Less) {
                try append(key, to: &output)
                try append(object[key]!, to: &output)
            }
            return
        }
        throw ToolchainTrustError.invalidCatalog
    }
}

/// Raw parsing rejects duplicate/escaped duplicate keys and unsupported numbers before Codable.
enum ToolchainCatalogJSON {
    // Two immutable offline kit inventories must fit one monotonic envelope.
    static let maximumEnvelopeBytes = 16 * 1024 * 1024
    static func decode(_ data: Data) throws -> (ToolchainCatalogEnvelope, Any) {
        guard data.count <= maximumEnvelopeBytes, String(data: data, encoding: .utf8) != nil else {
            throw ToolchainTrustError.limitExceeded
        }
        var scanner = Scanner(bytes: Array(data))
        try scanner.value(depth: 0); scanner.space()
        guard scanner.position == scanner.bytes.count else { throw ToolchainTrustError.invalidCatalog }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data) }
        catch { throw ToolchainTrustError.invalidCatalog }
        guard let object = parsed as? [String: Any] else { throw ToolchainTrustError.invalidCatalog }
        try shape(object)
        let envelope: ToolchainCatalogEnvelope
        do { envelope = try JSONDecoder().decode(ToolchainCatalogEnvelope.self, from: data) }
        catch { throw ToolchainTrustError.invalidCatalog }
        guard envelope.signatureVersion == 1, envelope.algorithm == "Ed25519",
              WorkspaceValidation.id(envelope.signerKeyId),
              envelope.signatureBase64.utf8.count == 88,
              let signature = Data(base64Encoded: envelope.signatureBase64), signature.count == 64,
              signature.base64EncodedString() == envelope.signatureBase64 else {
            throw ToolchainTrustError.invalidCatalog
        }
        try envelope.payload.validate()
        return (envelope, object["payload"]!)
    }
    private static func keys(_ object: [String: Any], _ expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw ToolchainTrustError.invalidCatalog }
    }
    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw ToolchainTrustError.invalidCatalog }
        return value
    }
    private static func array(_ value: Any?) throws -> [[String: Any]] {
        guard let value = value as? [[String: Any]] else { throw ToolchainTrustError.invalidCatalog }
        return value
    }
    private static func shape(_ envelope: [String: Any]) throws {
        try keys(envelope, ["signatureVersion", "algorithm", "signerKeyId", "signatureBase64", "payload"])
        let payload = try object(envelope["payload"])
        try keys(payload, ["catalogVersion", "catalogId", "channel", "sequence", "entries"])
        for entry in try array(payload["entries"]) {
            let kind = entry["kind"] as? String
            let base: Set<String> = ["catalogEntryId", "kind", "version", "platform", "artifactSha256", "artifactBytes",
                                     "downloadURL", "publisher", "inventoryHash", "inventory"]
            let source = entry["embeddedArtifactPath"] == nil ? base : base.union(["embeddedArtifactPath"])
            try keys(entry, kind == "authoringKit" ? source : source.union(["protocolMajor"]))
            try keys(try object(entry["publisher"]), ["teamIdentifier", "signingIdentifier"])
            for item in try array(entry["inventory"]) {
                let role = item["role"] as? String
                let required: Set<String> = ["path", "sha256", "bytes", "role"]
                try keys(item, role == "executable" ? required.union(["publisher"]) : required)
                if role == "executable" { try keys(try object(item["publisher"]), ["teamIdentifier", "signingIdentifier"]) }
            }
        }
    }
    private struct Scanner {
        let bytes: [UInt8]
        var position = 0
        mutating func space() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        mutating func consume(_ byte: UInt8) throws {
            space(); guard position < bytes.count, bytes[position] == byte else { throw ToolchainTrustError.invalidCatalog }
            position += 1
        }
        mutating func string() throws -> String {
            space(); let start = position; try consume(34)
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                if byte == 34 {
                    guard position - start <= 16_386 else { throw ToolchainTrustError.limitExceeded }
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
                    catch { throw ToolchainTrustError.invalidCatalog }
                }
                guard byte >= 32 else { throw ToolchainTrustError.invalidCatalog }
                if byte == 92 { guard position < bytes.count else { throw ToolchainTrustError.invalidCatalog }; position += 1 }
            }
            throw ToolchainTrustError.invalidCatalog
        }
        mutating func literal(_ value: String) throws {
            let expected = Array(value.utf8)
            guard position + expected.count <= bytes.count,
                  Array(bytes[position..<position + expected.count]) == expected else { throw ToolchainTrustError.invalidCatalog }
            position += expected.count
        }
        mutating func number() throws {
            let start = position
            guard bytes[position] >= 48 && bytes[position] <= 57 else { throw ToolchainTrustError.invalidCatalog }
            if bytes[position] == 48 { position += 1 }
            else { while position < bytes.count && bytes[position] >= 48 && bytes[position] <= 57 { position += 1 } }
            guard position - start <= 16,
                  let number = Int(String(decoding: bytes[start..<position], as: UTF8.self)),
                  number <= WorkspaceValidation.maxUInt else { throw ToolchainTrustError.invalidCatalog }
            if position < bytes.count, [46, 69, 101].contains(bytes[position]) { throw ToolchainTrustError.invalidCatalog }
        }
        mutating func value(depth: Int) throws {
            guard depth <= 32 else { throw ToolchainTrustError.limitExceeded }
            space(); guard position < bytes.count else { throw ToolchainTrustError.invalidCatalog }
            switch bytes[position] {
            case 34: _ = try string()
            case 48...57: try number()
            case 110: try literal("null")
            case 116: try literal("true")
            case 102: try literal("false")
            case 123:
                position += 1; space(); var seen = Set<String>()
                if position < bytes.count, bytes[position] == 125 { position += 1; return }
                while true {
                    let key = try string()
                    guard seen.insert(key).inserted, seen.count <= 100_000 else { throw ToolchainTrustError.invalidCatalog }
                    try consume(58); try value(depth: depth + 1); space()
                    if position < bytes.count, bytes[position] == 125 { position += 1; return }
                    try consume(44)
                }
            case 91:
                position += 1; space(); var count = 0
                if position < bytes.count, bytes[position] == 93 { position += 1; return }
                while true {
                    count += 1; guard count <= 100_000 else { throw ToolchainTrustError.limitExceeded }
                    try value(depth: depth + 1); space()
                    if position < bytes.count, bytes[position] == 93 { position += 1; return }
                    try consume(44)
                }
            default: throw ToolchainTrustError.invalidCatalog
            }
        }
    }
}
