import CryptoKit
import Foundation
import ScreenpunkCore
import XCTest

@testable import ScreenpunkController

/// Native oracle only. This never invokes the compiler, a renderer, a device, or a ZIP tool.
final class PackageCompatibilityFixtureTests: XCTestCase {
    private let acceptedCommit = "276c94b89ac7c6feb0e742116eaf2ebf55775240"
    private let sourceInventorySHA256 = "9640e0e519cbb394d64c0b61bb3ba27a8af7c004ce10df3cf6d6c0daf41f906b"
    private let sourceVerificationPolicy =
        "Ordinary verification pins historical SOURCE.json, corpus and generator integrity and recomputes exact native observations; only explicit export requires all current production source bytes to match the accepted historical inventory."
    private let dashboardID = "11111111-1111-4111-8111-111111111111"
    private let revisionID = "22222222-2222-4222-8222-222222222222"
    private var rawParserManifest: Data?
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var fixtures: URL { repository.appendingPathComponent("sdk/test/fixtures/native-package") }
    private var testPath: String {
        "packages/ScreenpunkController/Tests/ScreenpunkControllerTests/PackageCompatibilityFixtureTests.swift"
    }

    private struct SourceInventory: Codable {
        var repository: String
        var commit: String
        var entries: [SourceEntry]
    }
    private struct SourceEntry: Codable {
        var path: String
        var gitBlobSha1: String
        var sha256: String
        var bytes: Int
        var gitMode: String
    }
    private struct Asset: Codable {
        var path: String
        var base64: String
        var bytes: Int
        var sha256: String
    }
    private struct Vector {
        var id: String
        var input: Data
        var assets: [String: Data]
    }
    private struct Observation: Codable {
        var id: String
        var inputManifestUTF8: String
        var assets: [Asset]
        var decodeAccepted: Bool
        var decodeIssue: String?
        var validationIssues: [String]?
        var canonicalUTF8: String?
        var digest: String?
        var persistedManifestUTF8: String?
        var sortedInventoryUTF8: String?
        var encodeIssue: String?
    }
    private struct Probe: Codable {
        var id: String
        var declaredFileCount: Int
        var declaredExpandedBytes: Int
        var materializedAssets: Bool
        var validationIssues: [String]
    }
    private struct ParserObservation: Codable {
        var inputArgumentsUTF8: String
        var normalizedRevision: String
        var actualPersistedWriterVerified: Bool
        var resolved: Observation
    }
    private struct Corpus: Codable {
        var schemaVersion: Int
        var sourceCommit: String
        var acceptanceScope: String
        var cases: [Observation]
        var inventoryProbes: [Probe]
        var parser: ParserObservation
    }
    private struct Provenance: Codable {
        var schemaVersion: Int
        var sourceRepository: String
        var sourceCommit: String
        var sourceInventorySha256: String
        var sourceVerificationPolicy: String
        var corpusSha256: String
        var generatorPath: String
        var generatorSha256: String
        var generationCommand: String
        var swiftVersion: String
        var operatingSystem: String
        var architecture: String
        var generatedAtUTC: String
        var acceptanceScope: String
        var parserRevisionNormalization: String
        var prettyManifestSemantics: String
        var zipBytesQualified: Bool
        var compiledGalleryQualified: Bool
        var renderingQualified: Bool
        var userSourceQualified: Bool
    }

    private func encoded<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func text(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .utf8), "Native fixture bytes must be UTF-8")
    }
    private func regular(_ url: URL, maximum: Int = 4 * 1024 * 1024) throws -> Data {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let size = try XCTUnwrap(properties.fileSize)
        guard size <= maximum else { throw CocoaError(.fileReadTooLarge) }
        let bytes = try Data(contentsOf: url)
        guard bytes.count == size else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }
    private func verifySource(checkCurrent: Bool) throws -> Data {
        let data = try regular(fixtures.appendingPathComponent("SOURCE.json"))
        guard DeploymentDigest.sha256Hex(data) == sourceInventorySHA256 else { throw CocoaError(.fileReadCorruptFile) }
        let inventory = try JSONDecoder().decode(SourceInventory.self, from: data)
        XCTAssertEqual(inventory.repository, "https://github.com/screenpunk-xyz/screenpunk")
        XCTAssertEqual(inventory.commit, acceptedCommit)
        XCTAssertEqual(inventory.entries.count, 70)
        XCTAssertEqual(inventory.entries.map(\.path), inventory.entries.map(\.path).sorted())
        for entry in inventory.entries {
            guard !entry.path.hasPrefix("/"),
                !entry.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                    $0.isEmpty || $0 == "." || $0 == ".."
                })
            else { throw CocoaError(.fileReadInvalidFileName) }
            XCTAssertEqual(entry.gitMode, "100644")
            if checkCurrent {
                let bytes = try regular(repository.appendingPathComponent(entry.path))
                guard bytes.count == entry.bytes, DeploymentDigest.sha256Hex(bytes) == entry.sha256 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                var blob = Data("blob \(bytes.count)\0".utf8)
                blob.append(bytes)
                XCTAssertEqual(
                    Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined(), entry.gitBlobSha1,
                    entry.path)
            }
        }
        return data
    }
    private func assets() -> [String: Data] {
        // Small package assets, deliberately not compiler output or bundle notices.
        [
            "index.html": Data("<!doctype html><div id=\"root\"></div>".utf8),
            "screen.js": Data("(()=>{})();\n".utf8), "screen.css": Data("body{margin:0}\n".utf8),
            "THIRD-PARTY-NOTICES.txt": Data("Native metadata fixture; no compiled dependencies.\n".utf8),
        ]
    }
    private func inventory(_ assets: [String: Data]) -> [ManifestFile] {
        assets.map { ManifestFile(path: $0.key, bytes: $0.value.count, sha256: DeploymentDigest.sha256Hex($0.value)) }
            .sorted { $0.path < $1.path }
    }
    private func manifest(_ assets: [String: Data]? = nil) -> DashboardManifest {
        DashboardManifest(
            schemaVersion: 1, dashboardId: dashboardID, name: "Component gallery", revision: revisionID,
            entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(
                profileId: "fixture-phone", width: 390, height: 844,
                scale: 3, orientation: "portrait", safeArea: SafeAreaInsets(top: 47, right: 0, bottom: 34, left: 0)),
            connections: [], files: inventory(assets ?? self.assets()))
    }
    private func eventManifest() -> DashboardManifest {
        var value = manifest()
        value.connections = [
            ManifestConnection(
                alias: "events", required: false, operations: [ManifestOperation(name: "read", kind: "ws")])
        ]
        value.eventRules = [
            ManifestEventRule(
                id: "notice", name: "Notice",
                source: EventSource(
                    mode: .live, alias: "events", operation: "read",
                    parameters: ["2": .number(2), "10": .number(10), "a": .string("text")]),
                condition: EventCondition(field: ["active"], equals: .bool(true)),
                defaults: EventRuleDefaults(pageId: "default"))
        ]
        return value
    }
    private func issue(_ error: Error) -> String {
        let keyPath: ([CodingKey]) -> String = { $0.map(\.stringValue).joined(separator: ".") }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "keyNotFound:\(keyPath(context.codingPath + [key]))"
        case DecodingError.typeMismatch(_, let context): return "typeMismatch:\(keyPath(context.codingPath))"
        case DecodingError.valueNotFound(_, let context): return "valueNotFound:\(keyPath(context.codingPath))"
        case DecodingError.dataCorrupted(let context): return "dataCorrupted:\(keyPath(context.codingPath))"
        case EncodingError.invalidValue(_, let context): return "invalidValue:\(keyPath(context.codingPath))"
        default: return String(reflecting: type(of: error))
        }
    }
    private func validation(_ manifest: DashboardManifest) -> [String] {
        do {
            try PackageValidator.validate(manifest)
            return []
        } catch let error as PackageValidationError { return error.issues.map(\.rawValue).sorted() } catch {
            return [issue(error)]
        }
    }
    private func observe(_ vector: Vector) throws -> Observation {
        var record = Observation(
            id: vector.id, inputManifestUTF8: try text(vector.input),
            assets: vector.assets.map {
                Asset(
                    path: $0.key, base64: $0.value.base64EncodedString(), bytes: $0.value.count,
                    sha256: DeploymentDigest.sha256Hex($0.value))
            }.sorted { $0.path < $1.path }, decodeAccepted: false)
        let value: DashboardManifest
        do {
            value = try JSONDecoder().decode(DashboardManifest.self, from: vector.input)
            record.decodeAccepted = true
        } catch {
            record.decodeIssue = issue(error)
            return record
        }
        record.validationIssues = validation(value)
        do {
            // Direct calls into the unchanged native digest implementation.
            record.canonicalUTF8 = try text(DeploymentDigest.canonicalJSON(value))
            record.digest = try DeploymentDigest.digest(for: value)
            var persisted = value
            persisted.files.sort { $0.path < $1.path }
            persisted.digest = record.digest
            record.persistedManifestUTF8 = try text(encoded(persisted, pretty: true))
            record.sortedInventoryUTF8 = try text(encoded(persisted.files))
        } catch { record.encodeIssue = issue(error) }
        return record
    }
    private func mutate(_ input: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func permutedJSON(_ object: Any, reverse: Bool) throws -> String {
        if let dictionary = object as? [String: Any] {
            let keys = dictionary.keys.sorted()
            return "{"
                + (try (reverse ? Array(keys.reversed()) : keys).map { key in
                    try permutedJSON(key, reverse: reverse) + ":" + permutedJSON(dictionary[key]!, reverse: reverse)
                }).joined(separator: ",") + "}"
        }
        if let values = object as? [Any] {
            return "[" + (try values.map { try permutedJSON($0, reverse: reverse) }).joined(separator: ",") + "]"
        }
        return try text(
            JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
    }
    private func vectors() throws -> [Vector] {
        let files = assets()
        let base = try encoded(manifest())
        var result = [Vector(id: "minimal-resolved-gallery", input: base, assets: files)]
        let event = try encoded(eventManifest())
        let eventObject = try JSONSerialization.jsonObject(with: event)
        for reverse in [false, true] {
            result.append(
                Vector(
                    id: reverse ? "nested-keys-reversed" : "nested-keys-forward",
                    input: Data(try permutedJSON(eventObject, reverse: reverse).utf8), assets: files))
        }
        let caseFiles = [
            "A.js": Data("A".utf8), "a.js": Data("a".utf8), "_.js": Data("_".utf8), "index.html": files["index.html"]!,
        ]
        var caseManifest = manifest(caseFiles)
        caseManifest.files.reverse()
        result.append(Vector(id: "ascii-file-order", input: try encoded(caseManifest), assets: caseFiles))
        for (id, name) in [
            ("unicode-composed", "Café"), ("unicode-decomposed", "Cafe\u{301}"),
            ("unicode-supplementary-escaping", "雪 🙂 / quote\" backslash\\ newline\n tab\t \u{2028}\u{2029}"),
        ] {
            var value = manifest()
            value.name = name
            result.append(Vector(id: id, input: try encoded(value), assets: files))
        }
        var unicodeKeys = eventManifest()
        unicodeKeys.eventRules![0].source.parameters = [
            "雪": .string("snow"), "😀": .string("face"), "é": .string("accent"), "a": .string("letter"),
        ]
        result.append(Vector(id: "unicode-dictionary-order", input: try encoded(unicodeKeys), assets: files))
        for (id, change) in [
            (
                "optional-null",
                { (v: inout [String: Any]) in
                    for key in ["pages", "defaultPageId", "eventRules", "deviceBehavior"] { v[key] = NSNull() }
                }
            ),
            ("optional-empty-behavior", { (v: inout [String: Any]) in v["deviceBehavior"] = [String: Any]() }),
            (
                "optional-empty-arrays",
                { (v: inout [String: Any]) in
                    v["pages"] = []
                    v["eventRules"] = []
                }
            ),
            (
                "optional-explicit-false",
                { (v: inout [String: Any]) in v["deviceBehavior"] = ["audio": ["autoplay": false]] }
            ),
            (
                "optional-invalid-audio-null",
                { (v: inout [String: Any]) in v["deviceBehavior"] = ["audio": ["autoplay": NSNull()]] }
            ),
            ("required-null-name", { (v: inout [String: Any]) in v["name"] = NSNull() }),
        ] {
            result.append(Vector(id: id, input: try mutate(base, change), assets: files))
        }
        // Literal JSON representations are inputs, never precomputed native output.
        for (id, literal) in [
            ("double-integer", "3.0"), ("double-fraction", "1.25"), ("double-small-exponent", "1e-7"),
            ("double-large-exponent", "1e+21"), ("double-negative-zero", "-0.0"),
            ("double-precision", "1.2345678901234567"), ("double-unsafe-integer", "9007199254740993"),
            ("double-overflow-decode", "1e400"),
        ] {
            let raw = try text(event).replacingOccurrences(of: "\"a\":\"text\"", with: "\"a\":\(literal)")
            XCTAssertNotEqual(raw, try text(event))
            result.append(Vector(id: id, input: Data(raw.utf8), assets: files))
        }
        for (id, change) in [
            ("invalid-schema", { (v: inout DashboardManifest) in v.schemaVersion = 2 }),
            ("invalid-orientation", { (v: inout DashboardManifest) in v.target.orientation = "square" }),
            ("missing-entrypoint", { (v: inout DashboardManifest) in v.entrypoint = "missing.html" }),
            ("duplicate-file", { (v: inout DashboardManifest) in v.files.append(v.files[0]) }),
            ("empty-inventory", { (v: inout DashboardManifest) in v.files = [] }),
            ("negative-file-size", { (v: inout DashboardManifest) in v.files[0].bytes = -1 }),
        ] {
            var value = manifest()
            change(&value)
            result.append(Vector(id: id, input: try encoded(value), assets: files))
        }
        for (id, filePath) in [
            ("native-path-dotdot-substring", "foo..bar"), ("native-path-empty-component", "src//value.js"),
            ("native-path-dot-component", "src/./value.js"), ("native-path-unicode-nfd", "Cafe\u{301}.js"),
            ("rejected-path-traversal", "../value.js"), ("rejected-path-encoded-traversal", "%2E%2E/value.js"),
        ] {
            var value = manifest()
            value.files.append(
                ManifestFile(path: filePath, bytes: 1, sha256: DeploymentDigest.sha256Hex(Data("x".utf8))))
            var expanded = files
            expanded[filePath] = Data("x".utf8)
            result.append(Vector(id: id, input: try encoded(value), assets: expanded))
        }
        var zeroFiles = files
        zeroFiles["empty.css"] = Data()
        result.append(Vector(id: "native-zero-byte-file", input: try encoded(manifest(zeroFiles)), assets: zeroFiles))
        return result
    }
    private func probes() -> [Probe] {
        let hash = DeploymentDigest.sha256Hex(Data("x".utf8))
        let specifications = [
            ("inventory-at-2000", 2000, 1), ("inventory-over-2000", 2001, 1),
            ("expanded-at-50MiB", 1, PackageLimits.expandedBytes),
            ("expanded-over-50MiB", 1, PackageLimits.expandedBytes + 1),
        ]
        return specifications.map { id, count, bytes in
            var value = manifest()
            value.files = (0..<count).map {
                ManifestFile(path: $0 == 0 ? "index.html" : "file-\($0).txt", bytes: bytes, sha256: hash)
            }
            return Probe(
                id: id, declaredFileCount: count, declaredExpandedBytes: count * bytes, materializedAssets: false,
                validationIssues: validation(value))
        }
    }
    private func parser(id: String, target: JSONValue? = nil) throws -> ParserObservation {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "screenpunk-native-package-parser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ControllerService(store: try DashboardPackageStore(root: root))
        let gallery = try regular(repository.appendingPathComponent("authoring/templates/gallery/screen.json"))
        var arguments = try XCTUnwrap(try JSONValue.parse(gallery).object)
        arguments["dashboardId"] = .string(dashboardID)
        if let target { arguments["target"] = target }
        arguments["files"] = .array(
            assets().sorted { $0.key < $1.key }.map {
                .object(["path": .string($0.key), "base64": .string($0.value.base64EncodedString())])
            })
        let input = JSONValue.object(arguments)
        let record = try service.updateDashboard(arguments: input)
        let actual = try regular(record.packageDirectory.appendingPathComponent("manifest.json"))
        rawParserManifest = actual
        XCTAssertEqual(
            actual, try encoded(record.manifest, pretty: true),
            "Verify actual native persisted writer before normalizing its random revision")
        var normalized = record.manifest
        normalized.revision = revisionID
        normalized.digest = nil
        let observation = try observe(Vector(id: id, input: try encoded(normalized), assets: record.files))
        XCTAssertEqual(observation.validationIssues, [])
        return ParserObservation(
            inputArgumentsUTF8: try text(input.data()), normalizedRevision: revisionID,
            actualPersistedWriterVerified: true, resolved: observation)
    }
    private func corpus() throws -> Corpus {
        let observations = try vectors().map(observe)
        XCTAssertEqual(Set(observations.map(\.id)).count, observations.count)
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        XCTAssertEqual(byID["nested-keys-forward"]?.canonicalUTF8, byID["nested-keys-reversed"]?.canonicalUTF8)
        XCTAssertEqual(byID["minimal-resolved-gallery"]?.canonicalUTF8, byID["optional-null"]?.canonicalUTF8)
        XCTAssertNotEqual(
            Data((byID["unicode-composed"]?.canonicalUTF8 ?? "").utf8),
            Data((byID["unicode-decomposed"]?.canonicalUTF8 ?? "").utf8))
        XCTAssertEqual(byID["native-zero-byte-file"]?.validationIssues, [])
        XCTAssertEqual(byID["optional-empty-arrays"]?.validationIssues, ["validationFailed"])
        XCTAssertEqual(byID["optional-explicit-false"]?.validationIssues, [])
        XCTAssertEqual(byID["double-overflow-decode"]?.decodeAccepted, false)
        XCTAssertEqual(byID["rejected-path-traversal"]?.validationIssues, ["pathTraversal"])
        XCTAssertEqual(byID["ascii-file-order"]?.sortedInventoryUTF8?.contains("\"path\":\"A.js\""), true)
        let defaultParser = try parser(id: "controller-gallery-default-resolution")
        XCTAssertEqual(defaultParser.resolved.canonicalUTF8, byID["minimal-resolved-gallery"]?.canonicalUTF8)
        return Corpus(
            schemaVersion: 1, sourceCommit: acceptedCommit,
            acceptanceScope:
                "Native model decoding, canonical encoding and PackageValidator observations only; no ZIP, compiler, rendering, or device acceptance",
            cases: observations,
            inventoryProbes: probes(), parser: defaultParser)
    }
    private func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try text(bytes).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func testFrozenNativePackageOracle() throws {
        let exportDestination = ProcessInfo.processInfo.environment["SCREENPUNK_EXPORT_NATIVE_PACKAGE_ORACLE"]
        let sources = try verifySource(checkCurrent: exportDestination != nil)
        let value = try corpus()
        let corpusBytes = try encoded(value, pretty: true)
        if let destination = exportDestination {
            guard destination.hasPrefix("/") else { throw CocoaError(.fileWriteInvalidFileName) }
            let output = URL(fileURLWithPath: destination, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let provenance = Provenance(
                schemaVersion: 1, sourceRepository: "https://github.com/screenpunk-xyz/screenpunk",
                sourceCommit: acceptedCommit,
                sourceInventorySha256: sourceInventorySHA256, sourceVerificationPolicy: sourceVerificationPolicy,
                corpusSha256: DeploymentDigest.sha256Hex(corpusBytes),
                generatorPath: testPath,
                generatorSha256: DeploymentDigest.sha256Hex(try regular(repository.appendingPathComponent(testPath))),
                generationCommand:
                    "CLANG_MODULE_CACHE_PATH=/absolute/owned/clang SWIFT_MODULECACHE_PATH=/absolute/owned/swift SWIFTPM_MODULECACHE_OVERRIDE=/absolute/owned/swift SCREENPUNK_EXPORT_NATIVE_PACKAGE_ORACLE=/absolute/new/owned/output swift test --package-path packages/ScreenpunkController --disable-sandbox --disable-automatic-resolution --scratch-path /absolute/owned/scratch --cache-path /absolute/owned/cache --filter PackageCompatibilityFixtureTests",
                swiftVersion: try command("/usr/bin/xcrun", ["swift", "--version"]),
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: try command("/usr/bin/uname", ["-m"]),
                generatedAtUTC: ISO8601DateFormatter().string(from: Date()), acceptanceScope: value.acceptanceScope,
                parserRevisionNormalization:
                    "ControllerService creates a random revision. Actual persisted bytes are first compared with the unchanged native writer format; then only revision is replaced with the explicit fixture UUID and digest is recomputed through DeploymentDigest. Exported parser bytes are normalized native re-encoding, not the original persisted file.",
                prettyManifestSemantics:
                    "persistedManifestUTF8 records JSONEncoder with the native store's prettyPrinted/sortedKeys/withoutEscapingSlashes flags, sorted inventory, and native digest. Rejected vectors are encoding observations, never persisted or accepted packages.",
                zipBytesQualified: false, compiledGalleryQualified: false, renderingQualified: false,
                userSourceQualified: false)
            try sources.write(to: output.appendingPathComponent("SOURCE.json"), options: .withoutOverwriting)
            try corpusBytes.write(to: output.appendingPathComponent("CORPUS.json"), options: .withoutOverwriting)
            try encoded(provenance, pretty: true).write(
                to: output.appendingPathComponent("PROVENANCE.json"), options: .withoutOverwriting)
            // Local-only evidence retains the exact random-revision file before
            // normalization. Never copy these runtime artifacts into the corpus.
            let raw = try XCTUnwrap(rawParserManifest)
            try raw.write(
                to: output.appendingPathComponent("LOCAL-ONLY-native-parser-raw.json"), options: .withoutOverwriting)
            let rawEvidence = [
                "scope":
                    "Local-only unmodified ControllerService persisted manifest; random revision; not a deterministic fixture",
                "sha256": DeploymentDigest.sha256Hex(raw),
                "sourceCommit": acceptedCommit,
                "normalizedFixtureDigest": value.parser.resolved.digest ?? "",
            ]
            try encoded(rawEvidence, pretty: true).write(
                to: output.appendingPathComponent("LOCAL-ONLY-native-parser-evidence.json"),
                options: .withoutOverwriting)
            print("Native package oracle exported to \(output.path); corpus SHA256 \(provenance.corpusSha256)")
        } else {
            let frozen = try regular(fixtures.appendingPathComponent("CORPUS.json"))
            XCTAssertEqual(
                corpusBytes, frozen,
                "Native bytes changed: review source/toolchain and explicitly regenerate a candidate; never rewrite checksums alone"
            )
            let provenance = try JSONDecoder().decode(
                Provenance.self, from: regular(fixtures.appendingPathComponent("PROVENANCE.json")))
            XCTAssertEqual(provenance.sourceCommit, acceptedCommit)
            XCTAssertEqual(provenance.sourceInventorySha256, sourceInventorySHA256)
            XCTAssertEqual(provenance.sourceVerificationPolicy, sourceVerificationPolicy)
            XCTAssertEqual(provenance.corpusSha256, DeploymentDigest.sha256Hex(frozen))
            XCTAssertEqual(provenance.generatorPath, testPath)
            XCTAssertEqual(
                provenance.generatorSha256,
                DeploymentDigest.sha256Hex(try regular(repository.appendingPathComponent(testPath))))
            XCTAssertFalse(provenance.swiftVersion.isEmpty)
            XCTAssertFalse(provenance.operatingSystem.isEmpty)
            XCTAssertEqual(provenance.architecture, "arm64")
            XCTAssertFalse(
                provenance.zipBytesQualified || provenance.compiledGalleryQualified || provenance.renderingQualified
                    || provenance.userSourceQualified)
        }
    }
}
