import Foundation

/// Private schema-local strict parser. Encoding is a canonical native representation,
/// not a wire profile or digest; no observation or command is synthesized.
enum DeviceNativeStructuralStateCodec {
    static let maximumBytes = 65_536
    static let maximumDepth = 32
    static let maximumNodes = 4096
    typealias Failure = DeviceNativeStructuralFailure
    static func decode(_ data: Data) throws -> DeviceNativeStructuralState {
        guard data.count <= maximumBytes else { throw Failure.capacity }
        var parser = NativeStateJSONParser(bytes: Array(data))
        let o = try object(parser.parse(), keys: ["schemaVersion", "generationID", "owner", "entries", "configuredEntryID"])
        guard try integer(o["schemaVersion"]) == 2 else { throw Failure.invalidSchema }
        let w = try object(required(o["owner"]), keys: ["kind", "installationID", "accountID", "locationID", "transitionID"])
        guard try string(w["kind"]).utf8.elementsEqual("nativeInstallation".utf8) else { throw Failure.invalidSchema }
        let owner = DeviceNativeInstallationContentOwner(installationID: try id(w["installationID"]), accountID: try id(w["accountID"]), locationID: try optionalID(w["locationID"]), transitionID: try id(w["transitionID"]))
        guard case .array(let raw) = o["entries"], raw.count <= 12 else { throw Failure.invalidSchema }
        let entries = try raw.map { value -> DeviceNativeStructuralEntry in
            let e = try object(value, keys: ["entryID", "displayName", "provenance", "package", "preparedPackage"])
            guard try string(e["provenance"]).utf8.elementsEqual("cloud".utf8) else { throw Failure.invalidSchema }
            let p = try object(required(e["package"]), keys: ["packageProfile", "publicationID", "projectID", "packageID", "dashboardID", "revision", "manifestDigest", "manifestSHA256", "archiveSHA256", "compressedBytes", "expandedBytes", "archiveEntries"])
            let package = try DeviceDeliveryPackageCandidate.validating(packageProfile: string(p["packageProfile"]), publicationID: id(p["publicationID"]), projectID: id(p["projectID"]), packageID: id(p["packageID"]), dashboardID: id(p["dashboardID"]), revision: id(p["revision"]), manifestDigest: .validating(string(p["manifestDigest"])), manifestSHA256: .validating(string(p["manifestSHA256"])), archiveSHA256: .validating(string(p["archiveSHA256"])), compressedBytes: integer(p["compressedBytes"]), expandedBytes: integer(p["expandedBytes"]), archiveEntries: integer(p["archiveEntries"]))
            let r = try object(required(e["preparedPackage"]), keys: ["rootID", "contentID", "preparationOperationID", "directory"])
            return try .validating(entryID: id(e["entryID"]), displayName: string(e["displayName"]), package: package, preparedPackage: .init(rootID: id(r["rootID"]), contentID: string(r["contentID"]), preparationOperationID: id(r["preparationOperationID"]), directory: string(r["directory"])))
        }
        let selection: UUID? = if case .null = o["configuredEntryID"] { nil } else { try id(o["configuredEntryID"]) }
        return try .validating(generationID: id(o["generationID"]), owner: .nativeInstallation(owner), entries: entries, configuredEntryID: selection)
    }
    static func encode(_ state: DeviceNativeStructuralState) throws -> Data {
        guard state.entries.count <= 12 else { throw Failure.capacity }
        func uuid(_ x: UUID) -> String { x.uuidString.lowercased() }
        let entries: [[String: Any]] = state.entries.map { e in
            let p = e.package, r = e.preparedPackage
            return ["entryID": uuid(e.entryID), "displayName": e.displayName, "provenance": "cloud",
                "package": ["packageProfile": DeviceDeliveryPackageCandidate.profile, "publicationID": uuid(p.publicationID), "projectID": uuid(p.projectID), "packageID": uuid(p.packageID), "dashboardID": uuid(p.dashboardID), "revision": uuid(p.revision), "manifestDigest": p.manifestDigest.text, "manifestSHA256": p.manifestSHA256.text, "archiveSHA256": p.archiveSHA256.text, "compressedBytes": p.compressedBytes, "expandedBytes": p.expandedBytes, "archiveEntries": p.archiveEntries],
                "preparedPackage": ["rootID": uuid(r.rootID), "contentID": r.contentID, "preparationOperationID": uuid(r.preparationOperationID), "directory": r.directory]]
        }
        let w = state.owner
        let body: [String: Any] = ["schemaVersion": 2, "generationID": uuid(state.generationID), "owner": ["kind": "nativeInstallation", "installationID": uuid(w.installationID), "accountID": uuid(w.accountID), "locationID": w.locationID.map(uuid) as Any? ?? NSNull(), "transitionID": uuid(w.transitionID)], "entries": entries, "configuredEntryID": state.configuredEntryID.map(uuid) as Any? ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maximumBytes else { throw Failure.capacity }; return data
    }
    private static func optionalID(_ v: NativeStateJSON?) throws -> UUID? {
        if case .null = v { return nil }; return try id(v)
    }
    private static func required(_ v: NativeStateJSON?) throws -> NativeStateJSON { guard let v else { throw Failure.invalidSchema }; return v }
    private static func object(_ v: NativeStateJSON, keys: Set<String>) throws -> [String: NativeStateJSON] {
        guard case .object(let raw) = v, Set(raw.keys) == Set(keys.map { Data($0.utf8) }) else { throw Failure.invalidSchema }
        var result: [String: NativeStateJSON] = [:]
        for key in keys { result[key] = raw[Data(key.utf8)] }; return result
    }
    private static func string(_ v: NativeStateJSON?) throws -> String {
        guard case .string(let bytes) = v, let s = String(bytes: bytes, encoding: .utf8) else { throw Failure.invalidSchema }; return s
    }
    private static func integer(_ v: NativeStateJSON?) throws -> UInt64 { guard case .integer(let n) = v else { throw Failure.invalidSchema }; return n }
    private static func id(_ v: NativeStateJSON?) throws -> UUID {
        let s = try string(v), b = Array(s.utf8.prefix(37))
        guard b.count == 36 else { throw Failure.invalidSchema }
        for i in b.indices {
            if [8,13,18,23].contains(i) { guard b[i] == 45 else { throw Failure.invalidSchema } }
            else { guard (48...57).contains(b[i]) || (65...70).contains(b[i]) || (97...102).contains(b[i]) else { throw Failure.invalidSchema } }
        }
        guard let id = UUID(uuidString: s) else { throw Failure.invalidSchema }; return id
    }
}

private indirect enum NativeStateJSON {
    case object([Data: NativeStateJSON]), array([NativeStateJSON]), string([UInt8]), integer(UInt64), null, boolean
}

private struct NativeStateJSONParser {
    typealias Failure = DeviceNativeStructuralStateCodec.Failure
    let bytes: [UInt8]
    private var cursor = 0, nodes = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    mutating func parse() throws -> NativeStateJSON {
        let result = try value(depth: 1); whitespace()
        guard cursor == bytes.count else { throw Failure.invalidJSON }; return result
    }
    private mutating func node() throws {
        nodes += 1; guard nodes <= DeviceNativeStructuralStateCodec.maximumNodes else { throw Failure.capacity }
    }
    private mutating func value(depth: Int) throws -> NativeStateJSON {
        guard depth <= DeviceNativeStructuralStateCodec.maximumDepth else { throw Failure.capacity }
        try node(); whitespace()
        guard cursor < bytes.count else { throw Failure.invalidJSON }
        switch bytes[cursor] {
        case 123:
            cursor += 1; whitespace(); var o: [Data: NativeStateJSON] = [:]
            if take(125) { return .object(o) }
            while true {
                try node(); let key = Data(try text())
                guard !o.keys.contains(key) else { throw Failure.duplicateKey }
                whitespace(); guard take(58) else { throw Failure.invalidJSON }
                o[key] = try value(depth: depth + 1); whitespace()
                if take(125) { return .object(o) }
                guard take(44) else { throw Failure.invalidJSON }; whitespace()
            }
        case 91:
            cursor += 1; whitespace(); var a: [NativeStateJSON] = []
            if take(93) { return .array(a) }
            while true {
                // Entries are the only schema array. Refuse a thirteenth
                // element before allocating its subtree, including unknown arrays.
                guard a.count < DeviceNativeStructuralState.maximumEntries else { throw Failure.capacity }
                a.append(try value(depth: depth + 1)); whitespace()
                if take(93) { return .array(a) }
                guard take(44) else { throw Failure.invalidJSON }; whitespace()
            }
        case 34: return .string(try text())
        case 110: try literal("null"); return .null
        case 116: try literal("true"); return .boolean
        case 102: try literal("false"); return .boolean
        case 45, 48...57: return .integer(try number())
        default: throw Failure.invalidJSON
        }
    }
    private mutating func whitespace() { while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
    private mutating func take(_ b: UInt8) -> Bool {
        guard cursor < bytes.count, bytes[cursor] == b else { return false }; cursor += 1; return true
    }
    private mutating func literal(_ s: String) throws {
        for b in s.utf8 { guard take(b) else { throw Failure.invalidJSON } }
    }
    private mutating func text() throws -> [UInt8] {
        guard take(34) else { throw Failure.invalidJSON }; var out: [UInt8] = []
        while cursor < bytes.count {
            let b = bytes[cursor]; cursor += 1
            if b == 34 {
                guard String(bytes: out, encoding: .utf8) != nil else { throw Failure.invalidJSON }; return out
            }
            guard b >= 32 else { throw Failure.invalidJSON }
            if b != 92 { out.append(b); continue }
            guard cursor < bytes.count else { throw Failure.invalidJSON }
            let e = bytes[cursor]; cursor += 1
            switch e {
            case 34, 47, 92: out.append(e)
            case 98: out.append(8)
            case 102: out.append(12)
            case 110: out.append(10)
            case 114: out.append(13)
            case 116: out.append(9)
            case 117:
                let first = try hex4(); var scalar = first
                if (0xD800...0xDBFF).contains(first) {
                    guard take(92), take(117) else { throw Failure.invalidJSON }
                    let second = try hex4(); guard (0xDC00...0xDFFF).contains(second) else { throw Failure.invalidJSON }
                    scalar = 0x10000 + (first - 0xD800) * 1024 + second - 0xDC00
                } else if (0xDC00...0xDFFF).contains(first) { throw Failure.invalidJSON }
                guard let u = UnicodeScalar(scalar) else { throw Failure.invalidJSON }
                out.append(contentsOf: String(u).utf8)
            default: throw Failure.invalidJSON
            }
        }
        throw Failure.invalidJSON
    }
    private mutating func hex4() throws -> UInt32 {
        var n: UInt32 = 0
        for _ in 0..<4 {
            guard cursor < bytes.count else { throw Failure.invalidJSON }
            let b = bytes[cursor]; cursor += 1; let d: UInt32
            switch b { case 48...57: d = UInt32(b - 48); case 65...70: d = UInt32(b - 55); case 97...102: d = UInt32(b - 87); default: throw Failure.invalidJSON }
            n = n * 16 + d
        }
        return n
    }
    private mutating func number() throws -> UInt64 {
        let negative = take(45)
        let wholeStart = cursor
        guard cursor < bytes.count else { throw Failure.invalidJSON }
        if !take(48) {
            guard (49...57).contains(bytes[cursor]) else { throw Failure.invalidJSON }
            while cursor < bytes.count && (48...57).contains(bytes[cursor]) { cursor += 1 }
        }
        let wholeCount = cursor - wholeStart
        var fractionStart = cursor, fractionCount = 0
        if take(46) {
            fractionStart = cursor
            while cursor < bytes.count && (48...57).contains(bytes[cursor]) { cursor += 1 }
            fractionCount = cursor - fractionStart
            guard fractionCount > 0 else { throw Failure.invalidJSON }
        }
        var exponent = 0
        if take(101) || take(69) {
            let minus = take(45); if !minus { _ = take(43) }
            let start = cursor, saturation = DeviceNativeStructuralStateCodec.maximumBytes + 21
            while cursor < bytes.count && (48...57).contains(bytes[cursor]) {
                // Consume every exponent digit, even when already saturated.
                exponent = min(saturation, exponent * 10 + Int(bytes[cursor] - 48)); cursor += 1
            }
            guard cursor > start else { throw Failure.invalidJSON }
            if minus { exponent = -exponent }
        }
        guard !negative else { throw Failure.invalidSchema }
        let digits = wholeCount + fractionCount
        func digit(_ i: Int) -> UInt8 { bytes[i < wholeCount ? wholeStart + i : fractionStart + i - wholeCount] - 48 }
        var first: Int?, last = 0
        for i in 0..<digits where digit(i) != 0 { if first == nil { first = i }; last = i }
        // No power calculation, even for enormous exponents on zero.
        guard let first else { return 0 }
        let end = digits + exponent - fractionCount
        guard end > last, end - first <= 20 else { throw Failure.invalidSchema }
        var result: UInt64 = 0
        for i in first..<end {
            let d = i < digits ? UInt64(digit(i)) : 0
            let (a, overflowA) = result.multipliedReportingOverflow(by: 10)
            let (b, overflowB) = a.addingReportingOverflow(d)
            guard !overflowA, !overflowB else { throw Failure.invalidSchema }; result = b
        }
        return result
    }
}
