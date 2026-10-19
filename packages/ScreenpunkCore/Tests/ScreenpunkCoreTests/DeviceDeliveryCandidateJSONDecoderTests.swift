import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(CryptoKit)
import CryptoKit
#endif

// Reuses the unchanged, commit-pinned synthetic resources from the typed codec
// tests. JSONSerialization below is test-fixture construction only, never the
// production decoder or a durable/authority loader.
final class DeviceDeliveryCandidateJSONDecoderTests: XCTestCase {
    private typealias Decoder = DeviceDeliveryCandidateJSONDecoder
    private let empty = "{\"schemaVersion\":1,\"entries\":[],\"configuredEntryId\":null}"
    private func bytes(_ s: String) -> Data { Data(s.utf8) }
    private func fixtures(_ name: String) throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(document["cases"] as? [[String: Any]])
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func set() throws -> [String: Any] {
        for fixture in try fixtures("resulting-set-codec-fixtures") {
            let v = try XCTUnwrap(fixture["value"] as? [String: Any])
            let entries = try XCTUnwrap(v["entries"] as? [[String: Any]])
            if entries.contains(where: { ($0["provenance"] as? [String: Any])?["kind"] as? String == "cloud" }) { return v }
        }
        throw NSError(domain: "missing synthetic cloud fixture", code: 1)
    }
    private func editPackage(_ value: [String: Any], _ edit: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var value = value
        var entries = try XCTUnwrap(value["entries"] as? [[String: Any]])
        let i = try XCTUnwrap(entries.firstIndex { ($0["provenance"] as? [String: Any])?["kind"] as? String == "cloud" })
        var provenance = try XCTUnwrap(entries[i]["provenance"] as? [String: Any])
        var p = try XCTUnwrap(provenance["package"] as? [String: Any]); edit(&p)
        provenance["package"] = p; entries[i]["provenance"] = provenance; value["entries"] = entries; return value
    }
    private func packageNumber(_ field: String, _ token: String) throws -> Data {
        let value = try editPackage(set()) { $0[field] = 1 }
        let text = String(decoding: try json(value), as: UTF8.self)
        let needle = "\"\(field)\":1"
        XCTAssertTrue(text.contains(needle))
        return bytes(text.replacingOccurrences(of: needle, with: "\"\(field)\":\(token)"))
    }
    private func encodedHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func testAllCommittedGoldenInputsDecodeToIdenticalFramedBytesAndHashes() throws {
        for name in ["native-delivery-codec-fixtures", "resulting-set-codec-fixtures"] {
            let cases = try fixtures(name); XCTAssertEqual(cases.count, 6)
            for fixture in cases {
                let value = try XCTUnwrap(fixture["value"] as? [String: Any]), data = try json(value)
                let expected = try XCTUnwrap(fixture["hex"] as? String)
                if name == "native-delivery-codec-fixtures" {
                    let input = try Decoder.decodeObservation(data)
                    XCTAssertEqual(encodedHex(try DeviceDeliveryCandidateCodec.observationBytes(input)), expected)
                    #if canImport(CryptoKit)
                    XCTAssertEqual(try DeviceDeliveryCandidateCodec.observationDigest(input), fixture["observationDigest"] as? String)
                    #endif
                } else {
                    let input = try Decoder.decodeResultingSet(data)
                    XCTAssertEqual(encodedHex(try DeviceDeliveryCandidateCodec.resultingSetBytes(input)), expected)
                    #if canImport(CryptoKit)
                    XCTAssertEqual(try DeviceDeliveryCandidateCodec.resultingSetDigest(input), fixture["resultingSetDigest"] as? String)
                    #endif
                }
            }
        }
    }
    func testExactIntegerAliasesAndCanonicalSchemaVersion() throws {
        let baseline = try DeviceDeliveryCandidateCodec.resultingSetBytes(Decoder.decodeResultingSet(bytes(empty)))
        for token in ["1", "1.0", "1e0", "10e-1", "1000.00e-3", "0.001e3", "1E+0000"] {
            XCTAssertEqual(try DeviceDeliveryCandidateCodec.resultingSetBytes(Decoder.decodeResultingSet(bytes(empty.replacingOccurrences(of: ":1", with: ":" + token)))), baseline)
            for field in ["compressedBytes", "expandedBytes", "archiveEntries"] {
                let input = try Decoder.decodeResultingSet(packageNumber(field, token))
                let normal = try Decoder.decodeResultingSet(packageNumber(field, "1"))
                XCTAssertEqual(try DeviceDeliveryCandidateCodec.resultingSetBytes(input), try DeviceDeliveryCandidateCodec.resultingSetBytes(normal))
            }
        }
    }
    func testFractionRoundingAliasesZeroMinusAndFieldLimitsFailClosed() throws {
        for field in ["compressedBytes", "expandedBytes", "archiveEntries"] {
            for token in ["1.00000000000000001", "1e-1", "0", "0.0", "0e999", "-0", "-0.0", "-1", "18446744073709551616", "1e999", "1e-999"] {
                XCTAssertThrowsError(try Decoder.decodeResultingSet(packageNumber(field, token)), "\(field):\(token)")
            }
        }
        for (field, maximum) in [("compressedBytes", 26_214_400), ("expandedBytes", 52_428_800), ("archiveEntries", 2000)] {
            XCTAssertNoThrow(try Decoder.decodeResultingSet(packageNumber(field, "\(maximum).00e0")))
            XCTAssertThrowsError(try Decoder.decodeResultingSet(packageNumber(field, "\(maximum + 1)")))
        }
        XCTAssertThrowsError(try Decoder.decodeResultingSet(packageNumber("compressedBytes", "26214400.000000001")))
        for token in ["0", "-0", "-1", "2", "1.00000000000000001", "1e-1"] {
            XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes(empty.replacingOccurrences(of: ":1", with: ":" + token))))
        }
    }
    func testLongBoundedNumberTokensAndSaturatingExponentScan() throws {
        let zeros = String(repeating: "0", count: 4096)
        XCTAssertNoThrow(try Decoder.decodeResultingSet(bytes(empty.replacingOccurrences(of: ":1", with: ":1e+" + zeros))))
        XCTAssertNoThrow(try Decoder.decodeResultingSet(bytes(empty.replacingOccurrences(of: ":1", with: ":1." + zeros))))
        XCTAssertNoThrow(try Decoder.decodeResultingSet(bytes(empty.replacingOccurrences(of: ":1", with: ":0." + zeros + "1e4097"))))
        for token in ["1e" + String(repeating: "9", count: 4096), "1e-" + String(repeating: "9", count: 4096), "0e" + String(repeating: "9", count: 4096)] {
            XCTAssertThrowsError(try Decoder.decodeResultingSet(packageNumber("archiveEntries", token)))
        }
        // A saturated exponent must still be fully scanned and grammar checked.
        XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes(empty.replacingOccurrences(of: ":1", with: ":1e" + String(repeating: "9", count: 4096) + "x"))))
    }
    func testJSONGrammarUTF8EscapesSurrogatesAndTrailingBytes() throws {
        for raw in ["", "[]", "true", "null", empty + "x", empty + "{}", "\u{FEFF}" + empty,
            empty.replacingOccurrences(of: ":1", with: ":01"), empty.replacingOccurrences(of: ":1", with: ":+1"),
            empty.replacingOccurrences(of: ":1", with: ":1."), empty.replacingOccurrences(of: ":1", with: ":1e"),
            empty.replacingOccurrences(of: ":1", with: ":1e+"), empty.replacingOccurrences(of: ":1", with: ":NaN"),
            "{\"schemaVersion\":1,\"entries\":[],\"configuredEntryId\":null,}",
            "{\"schemaVersion\":1,\"entries\":[,],\"configuredEntryId\":null}",
            "{\"\\uD800\":1}", "{\"\\uDC00\":1}", "{\"\\uD800\\u0041\":1}", "{\"\\x41\":1}", "{\"a\n\":1}"] {
            XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes(raw)), raw)
        }
        let invalidUTF8: [[UInt8]] = [[0xFF], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]]
        for invalid in invalidUTF8 {
            var raw = bytes("{\""); raw.append(contentsOf: invalid); raw.append(bytes("\":1}"))
            XCTAssertThrowsError(try Decoder.decodeResultingSet(raw))
        }
        XCTAssertNoThrow(try Decoder.decodeResultingSet(bytes(" \t\r\n" + empty + "\n")))
        // Valid scalar escapes are parsed, then refused as unknown schema keys.
        XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes("{\"\\uD83D\\uDE00\":1}"))) { XCTAssertEqual($0 as? Decoder.Failure, .invalidSchema) }
    }
    func testDuplicateDecodedKeysUnknownFieldsAndExactASCIIIdentity() throws {
        for prefix in ["{\"schemaVersion\":1,", "{\"\\u0073chemaVersion\":1,"] {
            XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes(prefix + empty.dropFirst()))) { XCTAssertEqual($0 as? Decoder.Failure, .duplicateKey) }
        }
        XCTAssertNoThrow(try Decoder.decodeResultingSet(bytes(empty.replacingOccurrences(of: "schemaVersion", with: "\\u0073chemaVersion"))))
        for key in ["schemaVersion\u{0301}", "ＳchemaVersion", "unknown"] {
            XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes(empty.replacingOccurrences(of: "schemaVersion", with: key))))
        }
        let source = String(decoding: try json(set()), as: UTF8.self)
        for key in ["entryId", "kind", "packageProfile", "compressedBytes", "manifestDigest"] {
            let needle = "\"\(key)\":"
            let changed = source.replacingOccurrences(of: needle, with: needle + "null," + needle)
            XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes(changed))) { XCTAssertEqual($0 as? Decoder.Failure, .duplicateKey) }
        }
        var wrong = try set(); wrong["installationId"] = "00000000-0000-4000-8000-000000000001"
        XCTAssertThrowsError(try Decoder.decodeResultingSet(json(wrong)))
    }
    func testRequiredFieldsAndProvenanceUnionAreExact() throws {
        let original = try set()
        for key in original.keys { var v = original; v.removeValue(forKey: key); XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v))) }
        let packageKeys = ["packageProfile", "publicationId", "projectId", "packageId", "dashboardId", "revision", "manifestDigest", "manifestSha256", "archiveSha256", "compressedBytes", "expandedBytes", "archiveEntries"]
        for key in packageKeys {
            XCTAssertThrowsError(try Decoder.decodeResultingSet(json(editPackage(original) { $0.removeValue(forKey: key) })))
        }
        XCTAssertThrowsError(try Decoder.decodeResultingSet(json(editPackage(original) { $0["unknown"] = 1 })))
        var v = original, a = try XCTUnwrap(original["entries"] as? [[String: Any]])
        a[0]["unknown"] = 1; v["entries"] = a; XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v)))
        a = try XCTUnwrap(original["entries"] as? [[String: Any]])
        var p = try XCTUnwrap(a[0]["provenance"] as? [String: Any]); p["kind"] = "other"; a[0]["provenance"] = p; v["entries"] = a
        XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v)))
        p["kind"] = "retainedLocal"; a[0]["provenance"] = p; v["entries"] = a; XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v)))
        let wrongTypes: [Any] = [true, NSNull(), "1", [Any](), [String: Any]()]
        for value in wrongTypes {
            var wrong = original; wrong["schemaVersion"] = value; XCTAssertThrowsError(try Decoder.decodeResultingSet(json(wrong)))
        }
    }
    func testAllUUIDAndHashLexicalFieldsAndEscapedValidSpellings() throws {
        let original = try set()
        for key in ["publicationId", "projectId", "packageId", "dashboardId", "revision"] {
            for bad in ["urn:uuid:00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000001\n", "00000000000040008000000000000001", "00000000-0000-4000-8000-00000000000Ｋ"] {
                XCTAssertThrowsError(try Decoder.decodeResultingSet(json(editPackage(original) { $0[key] = bad })))
            }
        }
        for key in ["manifestDigest", "manifestSha256", "archiveSha256"] {
            for bad in [String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "a", count: 64) + "\n"] {
                XCTAssertThrowsError(try Decoder.decodeResultingSet(json(editPackage(original) { $0[key] = bad })))
            }
        }
        let upper = try editPackage(original) { p in for k in ["publicationId", "projectId", "packageId", "dashboardId", "revision"] { p[k] = (p[k] as? String)?.uppercased() } }
        XCTAssertEqual(try DeviceDeliveryCandidateCodec.resultingSetBytes(Decoder.decodeResultingSet(json(upper))), try DeviceDeliveryCandidateCodec.resultingSetBytes(Decoder.decodeResultingSet(json(original))))
        let text = String(decoding: try json(original), as: UTF8.self)
        XCTAssertEqual(try DeviceDeliveryCandidateCodec.resultingSetBytes(Decoder.decodeResultingSet(bytes(text.replacingOccurrences(of: "manifestDigest", with: "\\u006danifestDigest")))), try DeviceDeliveryCandidateCodec.resultingSetBytes(Decoder.decodeResultingSet(json(original))))
    }
    func testObservationAndRetainedIdentityFieldsDoNotAcceptLexicalAliases() throws {
        let observation = try XCTUnwrap(fixtures("native-delivery-codec-fixtures").first?["value"] as? [String: Any])
        for key in ["installationId", "transitionId", "generationId"] {
            for bad in ["urn:uuid:00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000001\n", "00000000-0000-4000-8000-00000000000g"] {
                var v = observation; v[key] = bad; XCTAssertThrowsError(try Decoder.decodeObservation(json(v)))
            }
            var v = observation; v.removeValue(forKey: key); XCTAssertThrowsError(try Decoder.decodeObservation(json(v)))
        }
        var wrong = observation; wrong["extra"] = 1; XCTAssertThrowsError(try Decoder.decodeObservation(json(wrong)))
        let token = "00000000-0000-4000-8000-000000000001", hash = String(repeating: "a", count: 64)
        let original: [String: Any] = ["schemaVersion": 1, "configuredEntryId": token, "entries": [["entryId": token,
            "provenance": ["kind": "retainedLocal", "retainedEntryId": token, "manifestDigest": hash]]]]
        XCTAssertNoThrow(try Decoder.decodeResultingSet(json(original)))
        for field in ["entryId", "retainedEntryId", "configuredEntryId"] {
            var v = original, entries = try XCTUnwrap(v["entries"] as? [[String: Any]])
            var provenance = try XCTUnwrap(entries[0]["provenance"] as? [String: Any])
            let bad = "urn:uuid:" + token
            if field == "entryId" { entries[0][field] = bad }
            else if field == "retainedEntryId" { provenance[field] = bad; entries[0]["provenance"] = provenance }
            else { v[field] = bad }
            v["entries"] = entries; XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v)))
        }
        for field in ["kind", "retainedEntryId", "manifestDigest"] {
            let text = String(decoding: try json(original), as: UTF8.self), needle = "\"\(field)\":"
            XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes(text.replacingOccurrences(of: needle, with: needle + "null," + needle)))) {
                XCTAssertEqual($0 as? Decoder.Failure, .duplicateKey)
            }
        }
        var badHash = original, entries = try XCTUnwrap(badHash["entries"] as? [[String: Any]])
        var provenance = try XCTUnwrap(entries[0]["provenance"] as? [String: Any]); provenance["manifestDigest"] = hash + "\n"
        entries[0]["provenance"] = provenance; badHash["entries"] = entries; XCTAssertThrowsError(try Decoder.decodeResultingSet(json(badHash)))
        provenance["manifestDigest"] = hash; provenance["package"] = [:] as [String: Any]
        entries[0]["provenance"] = provenance; badHash["entries"] = entries; XCTAssertThrowsError(try Decoder.decodeResultingSet(json(badHash)))
    }
    func testSelectionDuplicatesAndThirteenthEntryRejection() throws {
        var v = try set(), a = try XCTUnwrap(v["entries"] as? [[String: Any]])
        let first = try XCTUnwrap(a.first)
        v["entries"] = [first, first]; XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v)))
        var duplicateDashboard = first; duplicateDashboard["entryId"] = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        v["entries"] = [first, duplicateDashboard]; XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v)))
        v = try set(); v["configuredEntryId"] = NSNull(); XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v)))
        v["configuredEntryId"] = "ffffffff-ffff-ffff-ffff-ffffffffffff"; XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v)))
        v = try set(); a = Array(repeating: first, count: 13); v["entries"] = a
        XCTAssertThrowsError(try Decoder.decodeResultingSet(json(v))) { XCTAssertEqual($0 as? Decoder.Failure, .capacity) }
    }
    func testRawByteDepthAndNodeBudgetsBeforeUnboundedTree() throws {
        let padding = Decoder.maximumBytes - bytes(empty).count
        XCTAssertNoThrow(try Decoder.decodeResultingSet(bytes(empty + String(repeating: " ", count: padding))))
        XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes(empty + String(repeating: " ", count: padding + 1)))) { XCTAssertEqual($0 as? Decoder.Failure, .capacity) }
        XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes(String(repeating: "[", count: 9) + "null" + String(repeating: "]", count: 9)))) { XCTAssertEqual($0 as? Decoder.Failure, .capacity) }
        let members = (0..<600).map { "\"k\($0)\":null" }.joined(separator: ",")
        XCTAssertThrowsError(try Decoder.decodeResultingSet(bytes("{" + members + "}"))) { XCTAssertEqual($0 as? Decoder.Failure, .capacity) }
    }
}
