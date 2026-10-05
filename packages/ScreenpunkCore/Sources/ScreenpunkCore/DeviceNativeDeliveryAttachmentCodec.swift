import Foundation
import CoreFoundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Exact nonauthorizing attachment representation. No receipt outcome or permission decoder.
enum DeviceNativeDeliveryAttachmentCodec {
    enum Failure: Error, Equatable { case capacity, invalidJSON, duplicateKey, invalidSchema, digestUnavailable }
    static let maximumBytes = 32768, maximumDepth = 16, maximumNodes = 4096
    static func object(_ bytes: Data, limit: Int, keys: Set<String>) throws -> [String: Any] {
        guard bytes.count <= limit else { throw Failure.capacity }
        var parser = AttachmentJSONParser(bytes: Array(bytes)); _ = try parser.parse()
        guard let o = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(o.keys.map { Data($0.utf8) }) == Set(keys.map { Data($0.utf8) }) else { throw Failure.invalidSchema }
        return o
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try DeviceLocalCompleteSetBounds.encode(value, maximum: maximumBytes)
    }
    static func hash(_ bytes: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #else
        throw Failure.digestUnavailable
        #endif
    }
    static func uuid(_ value: Any?) throws -> UUID {
        guard let s = value as? String, s.utf8.count == 36,
              let id = UUID(uuidString: s), s.utf8.elementsEqual(id.uuidString.lowercased().utf8) else { throw Failure.invalidSchema }
        return id
    }
    static func hashText(_ value: Any?) throws -> String {
        guard let s = value as? String else { throw Failure.invalidSchema }
        _ = try DeviceDeliveryCandidateHash.validating(s); return s
    }
    static func integer(_ value: Any?, maximum: UInt64) throws -> UInt64 {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let integer = UInt64(n.stringValue), integer > 0, integer <= maximum else { throw Failure.invalidSchema }
        return integer
    }
}

private indirect enum AttachmentJSON {
    case object([Data: AttachmentJSON]), array([AttachmentJSON]), string([UInt8]), integer(UInt64), null, boolean
}

private struct AttachmentJSONParser {
    typealias Failure = DeviceNativeDeliveryAttachmentCodec.Failure
    let bytes: [UInt8]
    private var cursor = 0, nodes = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    mutating func parse() throws -> AttachmentJSON {
        let result = try value(depth: 1); whitespace()
        guard cursor == bytes.count else { throw Failure.invalidJSON }; return result
    }
    private mutating func node() throws {
        nodes += 1; guard nodes <= DeviceNativeDeliveryAttachmentCodec.maximumNodes else { throw Failure.capacity }
    }
    private mutating func value(depth: Int) throws -> AttachmentJSON {
        guard depth <= DeviceNativeDeliveryAttachmentCodec.maximumDepth else { throw Failure.capacity }
        try node(); whitespace()
        guard cursor < bytes.count else { throw Failure.invalidJSON }
        switch bytes[cursor] {
        case 123:
            cursor += 1; whitespace(); var o: [Data: AttachmentJSON] = [:]
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
            cursor += 1; whitespace(); var a: [AttachmentJSON] = []
            if take(93) { return .array(a) }
            while true {
                // Entries are the only schema array. Refuse a thirteenth
                // element before allocating its subtree, including unknown arrays.
                guard a.count < 12 else { throw Failure.capacity }
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
            let start = cursor, saturation = DeviceNativeDeliveryAttachmentCodec.maximumBytes + 21
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
