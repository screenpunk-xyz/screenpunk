import CryptoKit
import Foundation
import ScreenpunkCore
import XCTest

@testable import ScreenpunkController

/// Native serialization and metadata observations; no package-asset materialization or execution.
final class PackageNumericUnicodeFixtureTests: XCTestCase {
    private let commit = "859f9c2f492fea87ab64e49b3ea9037339e17478"
    private let sourceHash = "11392325a6d04115658bba754e5f5490b83c412469d13f04c8ef0bb137b83ef4"
    private let exportVariable = "SCREENPUNK_EXPORT_NUMERIC_UNICODE_ORACLE"
    private let samplesPerCollision = 64
    private let groups = [
        "dictionary-ascii-case-numeric-order", "dictionary-bmp-supplementary-order",
        "inventory-bmp-supplementary-order", "dictionary-canonical-equivalent-single",
        "dictionary-canonical-equivalent-collision", "inventory-canonical-equivalent-single-and-collision",
        "double-small-format-switch", "double-large-format-switch", "double-zero-field-types",
        "double-rounding-range-edges", "target-double-field-parity",
    ]
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var fixtures: URL { repository.appendingPathComponent("sdk/test/fixtures/native-package-numeric-unicode") }
    private let generatorPath =
        "packages/ScreenpunkController/Tests/ScreenpunkControllerTests/PackageNumericUnicodeFixtureTests.swift"
    private struct Source: Codable {
        var repository: String
        var commit: String
        var entries: [Entry]
    }
    private struct Entry: Codable {
        var path: String
        var gitBlobSha1: String
        var sha256: String
        var bytes: Int
        var gitMode: String
    }
    private struct Sample: Codable {
        var path: String
        var rawLexeme: String
        var requestedBinary64: String?
        var decodedBinary64: String?
        var decodedInteger: String?
    }
    private struct Vector {
        var id: String
        var group: String
        var input: String
        var samples: [Sample] = []
        var collision: Bool = false
    }
    private struct Member: Codable {
        var key: String
        var keyUTF8Hex: String
        var nativeScalarUTF8: String
    }
    private struct Observation: Codable {
        var id: String
        var group: String
        var rawInputManifestUTF8: String
        var samples: [Sample]
        var decodeAccepted: Bool
        var decodeIssue: String?
        var validationIssues: [String]?
        var decodedDictionaryMembersByRawUTF8: [Member]?
        var canonicalUTF8: String?
        var digest: String?
        var prettyManifestUTF8: String?
        var sortedFileInventoryUTF8: String?
        var encodeIssue: String?
    }
    private struct Comparison: Codable {
        var left: String
        var right: String
        var swiftEqual: Bool
        var swiftLeftLess: Bool
        var swiftRightLess: Bool
        var nsStringDefaultResult: Int
        var nsStringLiteralResult: Int
    }
    private struct Corpus: Codable {
        var schemaVersion: Int
        var sourceCommit: String
        var scope: String
        var groups: [String]
        var comparisons: [Comparison]
        var observations: [Observation]
    }
    private struct Collision: Codable {
        var id: String
        var rawInputManifestUTF8: String
        var alternatives: [Observation]
    }
    private struct CollisionCorpus: Codable {
        var schemaVersion: Int
        var scope: String
        var historicalSamplesPerInput: Int
        var collisions: [Collision]
    }
    private func encoded<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func text(_ bytes: Data) throws -> String { try XCTUnwrap(String(data: bytes, encoding: .utf8)) }
    private func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private func bits(_ value: Double) -> String { String(format: "%016llx", value.bitPattern) }
    private func regular(_ url: URL) throws -> Data {
        let p = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard p.isRegularFile == true, p.isSymbolicLink != true, let size = p.fileSize, size <= 4 * 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let bytes = try Data(contentsOf: url)
        guard size == bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }
    private func verifySource(current: Bool) throws -> Data {
        let bytes = try regular(fixtures.appendingPathComponent("SOURCE.json"))
        guard DeploymentDigest.sha256Hex(bytes) == sourceHash else { throw CocoaError(.fileReadCorruptFile) }
        let source = try JSONDecoder().decode(Source.self, from: bytes)
        XCTAssertEqual(source.commit, commit)
        XCTAssertEqual(source.repository, "https://github.com/screenpunk-xyz/screenpunk")
        XCTAssertEqual(source.entries.count, 75)
        XCTAssertEqual(source.entries.map(\.path), source.entries.map(\.path).sorted())
        for e in source.entries {
            guard !e.path.hasPrefix("/"),
                !e.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                    $0.isEmpty || $0 == "." || $0 == ".."
                })
            else { throw CocoaError(.fileReadInvalidFileName) }
            XCTAssertEqual(e.gitMode, "100644")
            if current {
                let value = try regular(repository.appendingPathComponent(e.path))
                guard value.count == e.bytes, DeploymentDigest.sha256Hex(value) == e.sha256 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                var blob = Data("blob \(value.count)\0".utf8)
                blob.append(value)
                XCTAssertEqual(hex(Insecure.SHA1.hash(data: blob)), e.gitBlobSha1, e.path)
            }
        }
        return bytes
    }
    private func base(event: Bool = true) -> DashboardManifest {
        var m = DashboardManifest(
            schemaVersion: 1, dashboardId: "11111111-1111-4111-8111-111111111111", name: "Numeric Unicode fixture",
            revision: "22222222-2222-4222-8222-222222222222", entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(
                profileId: "fixture-phone", width: 390, height: 844, scale: 3, orientation: "portrait",
                safeArea: SafeAreaInsets(top: 47, right: 0, bottom: 34, left: 0)),
            connections: [],
            files: [ManifestFile(path: "index.html", bytes: 1, sha256: DeploymentDigest.sha256Hex(Data("x".utf8)))])
        if event {
            m.connections = [
                ManifestConnection(
                    alias: "events", required: false, operations: [ManifestOperation(name: "read", kind: "ws")])
            ]
            m.eventRules = [
                ManifestEventRule(
                    id: "notice", name: "Notice", source: EventSource(mode: .live, alias: "events", operation: "read"),
                    condition: EventCondition(field: ["active"], equals: .bool(true)),
                    defaults: EventRuleDefaults(pageId: "default"))
            ]
        }
        return m
    }
    private func replaced(_ input: String, _ old: String, _ new: String) throws -> String {
        XCTAssertEqual(input.components(separatedBy: old).count, 2, "Replacement must be unique")
        guard input.components(separatedBy: old).count == 2 else { throw CocoaError(.fileReadCorruptFile) }
        return input.replacingOccurrences(of: old, with: new)
    }
    private func dictionary(
        _ id: String, group: String, members: [(String, String)], collision: Bool = false, samples: [Sample] = []
    ) throws -> Vector {
        let raw = "{" + (try members.map { try text(encoded($0.0)) + ":" + $0.1 }).joined(separator: ",") + "}"
        return Vector(
            id: id, group: group,
            input: try replaced(text(encoded(base())), "\"parameters\":{}", "\"parameters\":" + raw), samples: samples,
            collision: collision)
    }
    private func numerical(_ id: String, group: String, values: [(String, Double)]) throws -> Vector {
        XCTAssertLessThanOrEqual(values.count, 32)
        let samples = values.map {
            Sample(
                path: "eventRules.0.source.parameters." + $0.0, rawLexeme: String($0.1), requestedBinary64: bits($0.1))
        }
        return try dictionary(id, group: group, members: values.map { ($0.0, String($0.1)) }, samples: samples)
    }
    private func inventory(_ id: String, group: String, paths: [String]) throws -> Vector {
        var m = base(event: false)
        // An array preserves equivalent spellings/collisions; no Dictionary or filesystem materialization.
        m.files += paths.map { ManifestFile(path: $0, bytes: 1, sha256: DeploymentDigest.sha256Hex(Data("x".utf8))) }
        return Vector(id: id, group: group, input: try text(encoded(m)))
    }
    private func vectors() throws -> [Vector] {
        var v: [Vector] = []
        let ascii = [("A", "1"), ("a", "2"), ("_", "3"), ("10", "10"), ("2", "2")]
        let unicode = [("\u{e000}", "1"), ("\u{10000}", "2"), ("\u{ffff}", "3"), ("😀", "4")]
        for reverse in [false, true] {
            let suffix = reverse ? "reverse" : "forward"
            v.append(
                try dictionary(
                    "dictionary-ascii-" + suffix, group: groups[0], members: reverse ? ascii.reversed() : ascii))
            v.append(
                try dictionary(
                    "dictionary-unicode-" + suffix, group: groups[1], members: reverse ? unicode.reversed() : unicode))
            let paths = unicode.map { $0.0 + ".js" }
            v.append(
                try inventory(
                    "inventory-unicode-" + suffix, group: groups[2], paths: reverse ? paths.reversed() : paths))
            let pairs = [("é", "1"), ("e\u{301}", "2")]
            v.append(
                try dictionary(
                    "dictionary-equivalent-collision-" + suffix, group: groups[4],
                    members: reverse ? pairs.reversed() : pairs, collision: true))
            v.append(
                try inventory(
                    "inventory-equivalent-collision-" + suffix, group: groups[5],
                    paths: reverse ? ["Cafe\u{301}.js", "Café.js"] : ["Café.js", "Cafe\u{301}.js"]))
        }
        for (id, spelling) in [("composed", "é"), ("decomposed", "e\u{301}")] {
            v.append(
                try dictionary(
                    "dictionary-equivalent-single-" + id, group: groups[3], members: [(spelling, "1"), ("z", "3")]))
            v.append(
                try inventory(
                    "inventory-equivalent-single-" + id, group: groups[5], paths: ["Caf" + spelling + ".js", "Cafz.js"])
            )
        }
        var small = [1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3].enumerated().map { ("power" + String($0.offset), $0.element) }
        for (label, n) in [("six", 1e-6), ("four", 1e-4)] {
            small += [(label + "Down", n.nextDown), (label + "Up", n.nextUp), (label + "Negative", -n)]
        }
        v.append(try numerical("double-small-switch", group: groups[6], values: small))
        var large = [1e14, 1e15, 1e16, 1e17, 1e20, 1e21, 1e22].enumerated().map {
            ("power" + String($0.offset), $0.element)
        }
        for (label, n) in [("sixteen", 1e16), ("twentyOne", 1e21)] {
            large += [(label + "Down", n.nextDown), (label + "Up", n.nextUp), (label + "Negative", -n)]
        }
        v.append(try numerical("double-large-switch", group: groups[7], values: large))
        v.append(
            try numerical("double-zero-parameters", group: groups[8], values: [("positive", 0), ("negative", -0.0)]))
        for (id, token) in [("positive", "0"), ("negative", "-0")] {
            var input = try text(encoded(base()))
            input = try replaced(input, "\"equals\":true", "\"equals\":" + token)
            input = try replaced(input, "\"top\":47", "\"top\":" + token)
            input = try replaced(input, "\"priority\":0", "\"priority\":" + token)
            v.append(
                Vector(
                    id: "zero-typed-fields-" + id, group: groups[8], input: input,
                    samples: [
                        Sample(path: "eventRules.0.condition.equals", rawLexeme: token),
                        Sample(path: "target.safeArea.top", rawLexeme: token),
                        Sample(path: "eventRules.0.priority", rawLexeme: token),
                    ]))
        }
        var publicManifest = base(event: false)
        var connection = ManifestConnection(alias: "publicData", required: false)
        connection.publicHTTP = PublicReadDeclaration(
            origin: "https://data.example.org",
            operations: [PublicReadOperation(name: "read", path: "/values", response: "json", staleSeconds: 0)])
        publicManifest.connections = [connection]
        v.append(
            Vector(
                id: "zero-int-staleSeconds", group: groups[8],
                input: try replaced(text(encoded(publicManifest)), "\"staleSeconds\":0", "\"staleSeconds\":-0"),
                samples: [Sample(path: "connections.0.publicHTTP.operations.0.staleSeconds", rawLexeme: "-0")]))
        v.append(
            try numerical(
                "double-range-and-rounding", group: groups[9],
                values: [
                    ("tenth", 0.1), ("fifth", 0.2), ("sum", 0.30000000000000004), ("oneDown", Double(1).nextDown),
                    ("oneUp", Double(1).nextUp), ("twoDown", Double(2).nextDown), ("twoUp", Double(2).nextUp),
                    ("subnormal", Double.leastNonzeroMagnitude), ("normal", Double.leastNormalMagnitude),
                    ("greatest", Double.greatestFiniteMagnitude),
                ]))
        for token in ["9007199254740991", "9007199254740992", "9007199254740993", "1e400"] {
            v.append(
                try dictionary(
                    "raw-number-" + token, group: groups[9], members: [("value", token)],
                    samples: [Sample(path: "eventRules.0.source.parameters.value", rawLexeme: token)]))
        }
        v.append(
            Vector(
                id: "raw-int-overflow", group: groups[9],
                input: try replaced(text(encoded(base())), "\"width\":390", "\"width\":9223372036854775808"),
                samples: [Sample(path: "target.width", rawLexeme: "9223372036854775808")]))
        for (id, scale, top) in [
            ("fractional", 1.25, 0.5), ("scaleUpperDown", Double(8).nextDown, 0), ("scaleUpper", 8, 0),
            ("scaleUpperUp", Double(8).nextUp, 0), ("scalePositiveMinimum", Double.leastNonzeroMagnitude, 0),
            ("scaleZero", 0, 0), ("scaleNegativeZero", -0.0, 0),
            ("safeAreaBelowZero", 3, -Double.leastNonzeroMagnitude),
            ("safeAreaAboveZero", 3, Double.leastNonzeroMagnitude),
        ] {
            var input = try text(encoded(base()))
            input = try replaced(input, "\"scale\":3", "\"scale\":" + String(scale))
            input = try replaced(input, "\"top\":47", "\"top\":" + String(top))
            v.append(
                Vector(
                    id: "target-" + id, group: groups[10], input: input,
                    samples: [
                        Sample(path: "target.scale", rawLexeme: String(scale), requestedBinary64: bits(scale)),
                        Sample(path: "target.safeArea.top", rawLexeme: String(top), requestedBinary64: bits(top)),
                    ]))
        }
        XCTAssertEqual(Set(v.map(\.group)), Set(groups))
        XCTAssertEqual(Set(v.map(\.id)).count, v.count)
        return v
    }
    private func issue(_ error: Error) -> String {
        func path(_ keys: [CodingKey]) -> String { keys.map(\.stringValue).joined(separator: ".") }
        switch error {
        case DecodingError.keyNotFound(let key, let c): return "keyNotFound:" + path(c.codingPath + [key])
        case DecodingError.typeMismatch(_, let c): return "typeMismatch:" + path(c.codingPath)
        case DecodingError.valueNotFound(_, let c): return "valueNotFound:" + path(c.codingPath)
        case DecodingError.dataCorrupted(let c): return "dataCorrupted:" + path(c.codingPath)
        case EncodingError.invalidValue(_, let c): return "invalidValue:" + path(c.codingPath)
        default: return String(reflecting: type(of: error))
        }
    }
    private func observe(_ v: Vector) throws -> Observation {
        var o = Observation(
            id: v.id, group: v.group, rawInputManifestUTF8: v.input, samples: v.samples, decodeAccepted: false)
        let m: DashboardManifest
        do {
            m = try JSONDecoder().decode(DashboardManifest.self, from: Data(v.input.utf8))
            o.decodeAccepted = true
        } catch {
            o.decodeIssue = issue(error)
            return o
        }
        do {
            try PackageValidator.validate(m)
            o.validationIssues = []
        } catch let e as PackageValidationError { o.validationIssues = e.issues.map(\.rawValue).sorted() } catch {
            o.validationIssues = [issue(error)]
        }
        if let parameters = m.eventRules?.first?.source.parameters {
            o.decodedDictionaryMembersByRawUTF8 = try parameters.map {
                Member(key: $0.key, keyUTF8Hex: hex($0.key.utf8), nativeScalarUTF8: try text(encoded($0.value)))
            }.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        }
        for i in o.samples.indices {
            let path = o.samples[i].path
            var number: Double?
            if path.hasPrefix("eventRules.0.source.parameters."),
                case .number(let n)? = m.eventRules?.first?.source.parameters[
                    String(path.dropFirst("eventRules.0.source.parameters.".count))]
            {
                number = n
            } else if path == "eventRules.0.condition.equals",
                case .number(let n)? = m.eventRules?.first?.condition?.equals
            {
                number = n
            } else if path == "target.scale" {
                number = m.target.scale
            } else if path == "target.safeArea.top" {
                number = m.target.safeArea?.top
            } else if path == "eventRules.0.priority" {
                o.samples[i].decodedInteger = m.eventRules.map { String($0[0].priority) }
            } else if path == "target.width" {
                o.samples[i].decodedInteger = String(m.target.width)
            } else if path == "connections.0.publicHTTP.operations.0.staleSeconds" {
                o.samples[i].decodedInteger = m.connections[0].publicHTTP.map { String($0.operations[0].staleSeconds) }
            }
            if let n = number {
                o.samples[i].decodedBinary64 = bits(n)
                if let expected = o.samples[i].requestedBinary64 {
                    XCTAssertEqual(bits(n), expected, v.id + ":" + path)
                }
            }
        }
        do {
            o.canonicalUTF8 = try text(DeploymentDigest.canonicalJSON(m))
            o.digest = try DeploymentDigest.digest(for: m)
            var pretty = m
            pretty.files.sort { $0.path < $1.path }
            pretty.digest = o.digest
            o.prettyManifestUTF8 = try text(encoded(pretty, pretty: true))
            o.sortedFileInventoryUTF8 = try text(encoded(pretty.files))
        } catch { o.encodeIssue = issue(error) }
        return o
    }
    private func comparisons() -> [Comparison] {
        let pairs: [(String, String)] = [
            ("A", "a"), ("_", "a"), ("\u{e000}", "\u{10000}"), ("é", "e\u{301}"), ("e\u{301}", "z"),
        ]
        return pairs.map { pair in
            let (left, right) = pair
            let nsDefault = (left as NSString).compare(right).rawValue
            let nsLiteral = (left as NSString).compare(right, options: NSString.CompareOptions.literal).rawValue
            return Comparison(
                left: left, right: right, swiftEqual: left == right, swiftLeftLess: left < right,
                swiftRightLess: right < left, nsStringDefaultResult: nsDefault, nsStringLiteralResult: nsLiteral)
        }
    }
    private func command(_ executable: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return try text(bytes).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func testFrozenNumericUnicodeOracle() throws {
        let export = ProcessInfo.processInfo.environment[exportVariable]
        let source = try verifySource(current: export != nil)
        let all = try vectors()
        let stable = try all.filter { !$0.collision }.map(observe)
        let scope =
            "Native serialization/manifest metadata only; synthetic one-byte inventory, no materialized assets, parser, archive, compiler, runtime or untrusted-source qualification"
        let corpus = try encoded(
            Corpus(
                schemaVersion: 1, sourceCommit: commit, scope: scope, groups: groups, comparisons: comparisons(),
                observations: stable), pretty: true)
        // Repeated decodes retain actual collision outcomes. Never fabricate a stable winner.
        let collisionVectors = all.filter(\.collision)
        let runs = try collisionVectors.map { v in (v, try (0..<samplesPerCollision).map { _ in try observe(v) }) }
        if let export {
            guard export.hasPrefix("/") else { throw CocoaError(.fileWriteInvalidFileName) }
            let out = URL(fileURLWithPath: export, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: out.path) else { throw CocoaError(.fileWriteFileExists) }
            var alternatives: [Collision] = []
            for (v, observations) in runs {
                var unique: [Data] = []
                for o in observations {
                    let bytes = try encoded(o)
                    if !unique.contains(bytes) { unique.append(bytes) }
                }
                unique.sort { $0.lexicographicallyPrecedes($1) }
                alternatives.append(
                    Collision(
                        id: v.id, rawInputManifestUTF8: v.input,
                        alternatives: try unique.map { try JSONDecoder().decode(Observation.self, from: $0) }))
            }
            let collisions = try encoded(
                CollisionCorpus(
                    schemaVersion: 1,
                    scope:
                        "Actual sampled native alternatives, not an asserted exhaustive set or deterministic winner; ordinary verification checks each new observation against this reviewed set",
                    historicalSamplesPerInput: samplesPerCollision, collisions: alternatives), pretty: true)
            let provenance = [
                "sourceCommit": commit, "sourceRepository": "https://github.com/screenpunk-xyz/screenpunk",
                "sourceInventorySha256": sourceHash, "corpusSha256": DeploymentDigest.sha256Hex(corpus),
                "collisionCorpusSha256": DeploymentDigest.sha256Hex(collisions), "generatorPath": generatorPath,
                "generatorSha256": DeploymentDigest.sha256Hex(
                    try regular(repository.appendingPathComponent(generatorPath))),
                "sourceVerificationPolicy":
                    "Historical SOURCE and generator/corpus/collision provenance always checked; matching all current source bytes is explicit export only",
                "generationCommand":
                    "env CLANG_MODULE_CACHE_PATH=/absolute/owned/clang SWIFT_MODULECACHE_PATH=/absolute/owned/swift SWIFTPM_MODULECACHE_OVERRIDE=/absolute/owned/swift SCREENPUNK_EXPORT_NUMERIC_UNICODE_ORACLE=/absolute/new/owned/output swift test --package-path packages/ScreenpunkController --disable-sandbox --disable-automatic-resolution --scratch-path /absolute/owned/build --cache-path /absolute/owned/cache --filter PackageNumericUnicodeFixtureTests",
                "swiftVersion": try command("/usr/bin/xcrun", ["swift", "--version"]),
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": try command("/usr/bin/uname", ["-m"]),
                "generatedAtUTC": ISO8601DateFormatter().string(from: Date()),
                "scope": scope,
                "normalization":
                    "None. Explicit fixed manifest IDs; input member/file order and original Unicode spellings retained; native decode/encode observed unchanged",
                "prettyManifestSemantics":
                    "Native prettyPrinted/sortedKeys/withoutEscapingSlashes re-encoding, not a ControllerStore persisted file; rejected vectors never accepted packages",
            ]
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            for (name, bytes) in [
                ("SOURCE.json", source), ("CORPUS.json", corpus), ("COLLISIONS.json", collisions),
                ("PROVENANCE.json", try encoded(provenance, pretty: true)),
            ] {
                try bytes.write(to: out.appendingPathComponent(name), options: .withoutOverwriting)
            }
            let raw = try encoded(runs.flatMap { $0.1 }, pretty: true)
            try raw.write(
                to: out.appendingPathComponent("LOCAL-ONLY-collision-samples.json"), options: .withoutOverwriting)
            print(
                "Numeric Unicode export: \(stable.count) stable vectors, \(alternatives.map { $0.alternatives.count }) collision alternatives; corpus \(DeploymentDigest.sha256Hex(corpus)); collisions \(DeploymentDigest.sha256Hex(collisions))"
            )
        } else {
            let frozen = try regular(fixtures.appendingPathComponent("CORPUS.json"))
            XCTAssertEqual(
                corpus, frozen,
                "Native behavior changed; review an explicit new candidate, never rewrite checksums alone")
            let bytes = try regular(fixtures.appendingPathComponent("COLLISIONS.json"))
            let collisions = try JSONDecoder().decode(CollisionCorpus.self, from: bytes)
            XCTAssertEqual(collisions.collisions.map(\.id), collisionVectors.map(\.id))
            XCTAssertEqual(collisions.historicalSamplesPerInput, samplesPerCollision)
            for (v, observations) in runs {
                let historical = try XCTUnwrap(collisions.collisions.first { $0.id == v.id })
                XCTAssertEqual(historical.rawInputManifestUTF8, v.input)
                let allowed = try historical.alternatives.map { try encoded($0) }
                for o in observations {
                    XCTAssertTrue(
                        allowed.contains(try encoded(o)),
                        "New collision outcome: review exact native bytes rather than choose a winner")
                }
            }
            let p = try JSONDecoder().decode(
                [String: String].self, from: regular(fixtures.appendingPathComponent("PROVENANCE.json")))
            XCTAssertEqual(p["sourceCommit"], commit)
            XCTAssertEqual(p["sourceInventorySha256"], sourceHash)
            XCTAssertEqual(p["corpusSha256"], DeploymentDigest.sha256Hex(frozen))
            XCTAssertEqual(p["collisionCorpusSha256"], DeploymentDigest.sha256Hex(bytes))
            XCTAssertEqual(p["generatorPath"], generatorPath)
            XCTAssertEqual(
                p["generatorSha256"],
                DeploymentDigest.sha256Hex(try regular(repository.appendingPathComponent(generatorPath))))
            XCTAssertFalse(try XCTUnwrap(p["swiftVersion"]).isEmpty)
            XCTAssertFalse(try XCTUnwrap(p["operatingSystem"]).isEmpty)
        }
    }
}
