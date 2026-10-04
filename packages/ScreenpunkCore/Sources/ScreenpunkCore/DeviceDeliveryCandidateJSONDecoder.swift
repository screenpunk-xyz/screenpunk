import Foundation

/// Strict, unmounted candidate JSON input policy. Decoding supplies typed values
/// only: no durable schema, route approval, resource proof or authority.
enum DeviceDeliveryCandidateJSONDecoder {
    static let maximumBytes = 65_536
    static let maximumDepth = 8
    static let maximumNodes = 1024
    enum Failure: Error, Equatable { case capacity, invalidJSON, duplicateKey, invalidSchema }

    static func decodeObservation(_ data: Data) throws -> DeviceDeliveryObservationCandidate {
        let o = try object(parse(data), keys: ["schemaVersion", "installationId", "transitionId", "generationId", "entries", "configuredEntryId"])
        try version(o)
        return try .validating(installationID: id(o["installationId"]), transitionID: id(o["transitionId"]),
            generationID: id(o["generationId"]), entries: entries(o["entries"]), configuredEntryID: selection(o["configuredEntryId"]))
    }
    static func decodeResultingSet(_ data: Data) throws -> DeviceResultingSetCandidate {
        let o = try object(parse(data), keys: ["schemaVersion", "entries", "configuredEntryId"])
        try version(o)
        return try .validating(entries: entries(o["entries"]), configuredEntryID: selection(o["configuredEntryId"]))
    }
    private static func parse(_ data: Data) throws -> DeliveryJSON {
        // Data.count is checked BEFORE any snapshot, decoded string or tree copy.
        guard data.count <= maximumBytes else { throw Failure.capacity }
        var parser = DeliveryJSONParser(bytes: Array(data))
        return try parser.parse()
    }
    private static func object(_ v: DeliveryJSON, keys: Set<String>) throws -> [String: DeliveryJSON] {
        guard case .object(let raw) = v,
            Set(raw.keys) == Set(keys.map { Data($0.utf8) }) else { throw Failure.invalidSchema }
        // Only exact known ASCII keys enter a String-keyed container. Neither
        // Swift Unicode equality nor normalization can qualify an unknown key.
        var result: [String: DeliveryJSON] = [:]
        for key in keys { result[key] = raw[Data(key.utf8)] }
        return result
    }
    private static func version(_ o: [String: DeliveryJSON]) throws {
        guard try integer(o["schemaVersion"]) == 1 else { throw Failure.invalidSchema }
    }
    private static func string(_ v: DeliveryJSON?) throws -> String {
        guard case .string(let bytes) = v, let s = String(bytes: bytes, encoding: .utf8) else { throw Failure.invalidSchema }
        return s
    }
    private static func integer(_ v: DeliveryJSON?) throws -> UInt64 {
        guard case .integer(let n) = v else { throw Failure.invalidSchema }; return n
    }
    private static func id(_ v: DeliveryJSON?) throws -> UUID {
        guard case .string(let b) = v, b.count == 36 else { throw Failure.invalidSchema }
        for i in b.indices {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                guard b[i] == 45 else { throw Failure.invalidSchema }
            } else {
                guard (48...57).contains(b[i]) || (65...70).contains(b[i]) || (97...102).contains(b[i]) else { throw Failure.invalidSchema }
            }
        }
        guard let value = UUID(uuidString: String(decoding: b, as: UTF8.self)) else { throw Failure.invalidSchema }
        return value
    }
    private static func hash(_ v: DeliveryJSON?) throws -> DeviceDeliveryCandidateHash { try .validating(string(v)) }
    private static func selection(_ v: DeliveryJSON?) throws -> UUID? {
        if case .null = v { return nil }; return try id(v)
    }
    private static func entries(_ v: DeliveryJSON?) throws -> [DeviceDeliveryEntryCandidate] {
        guard case .array(let values) = v, values.count <= DeviceResultingSetCandidate.maximumEntries else { throw Failure.invalidSchema }
        return try values.map { value in
            let e = try object(value, keys: ["entryId", "provenance"])
            guard let raw = e["provenance"], case .object(let p) = raw else { throw Failure.invalidSchema }
            let kind = try string(p[Data("kind".utf8)])
            let provenance: DeviceDeliveryEntryProvenanceCandidate
            if kind.utf8.elementsEqual("cloud".utf8) {
                let o = try object(raw, keys: ["kind", "package"])
                guard let package = o["package"] else { throw Failure.invalidSchema }
                let x = try object(package, keys: ["packageProfile", "publicationId", "projectId", "packageId", "dashboardId", "revision",
                    "manifestDigest", "manifestSha256", "archiveSha256", "compressedBytes", "expandedBytes", "archiveEntries"])
                provenance = .cloud(try .validating(packageProfile: string(x["packageProfile"]), publicationID: id(x["publicationId"]),
                    projectID: id(x["projectId"]), packageID: id(x["packageId"]), dashboardID: id(x["dashboardId"]), revision: id(x["revision"]),
                    manifestDigest: hash(x["manifestDigest"]), manifestSHA256: hash(x["manifestSha256"]), archiveSHA256: hash(x["archiveSha256"]),
                    compressedBytes: integer(x["compressedBytes"]), expandedBytes: integer(x["expandedBytes"]), archiveEntries: integer(x["archiveEntries"])))
            } else if kind.utf8.elementsEqual("retainedLocal".utf8) {
                let o = try object(raw, keys: ["kind", "retainedEntryId", "manifestDigest"])
                provenance = .retainedLocal(retainedEntryID: try id(o["retainedEntryId"]), manifestDigest: try hash(o["manifestDigest"]))
            } else { throw Failure.invalidSchema }
            return .validating(entryID: try id(e["entryId"]), provenance: provenance)
        }
    }
}

private indirect enum DeliveryJSON {
    case object([Data: DeliveryJSON]), array([DeliveryJSON]), string([UInt8]), integer(UInt64), null, boolean
}

private struct DeliveryJSONParser {
    typealias Failure = DeviceDeliveryCandidateJSONDecoder.Failure
    let bytes: [UInt8]
    private var cursor = 0, nodes = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    mutating func parse() throws -> DeliveryJSON {
        let result = try value(depth: 1); whitespace()
        guard cursor == bytes.count else { throw Failure.invalidJSON }; return result
    }
    private mutating func node() throws {
        nodes += 1; guard nodes <= DeviceDeliveryCandidateJSONDecoder.maximumNodes else { throw Failure.capacity }
    }
    private mutating func value(depth: Int) throws -> DeliveryJSON {
        guard depth <= DeviceDeliveryCandidateJSONDecoder.maximumDepth else { throw Failure.capacity }
        try node(); whitespace()
        guard cursor < bytes.count else { throw Failure.invalidJSON }
        switch bytes[cursor] {
        case 123:
            cursor += 1; whitespace(); var o: [Data: DeliveryJSON] = [:]
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
            cursor += 1; whitespace(); var a: [DeliveryJSON] = []
            if take(93) { return .array(a) }
            while true {
                // The only candidate array is entries. Refuse the thirteenth
                // element before allocating its subtree, including unknown arrays.
                guard a.count < DeviceResultingSetCandidate.maximumEntries else { throw Failure.capacity }
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
            let start = cursor, saturation = DeviceDeliveryCandidateJSONDecoder.maximumBytes + 21
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
