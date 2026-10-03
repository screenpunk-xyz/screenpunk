import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class DevicePackageQualificationTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private let dashboardID = "11111111-1111-4111-8111-111111111111"
    private let revisionID = "22222222-2222-4222-8222-222222222222"
    #if canImport(CryptoKit)
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func encoded(_ manifest: DashboardManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
    private func fixture(orientation: DeviceOrientation = .portrait, name: String = "Fixture") throws -> (DevicePackageBytes, DevicePackageExpectation) {
        let bytes = Data("<html>fixture</html>".utf8)
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: dashboardID, name: name, revision: revisionID,
            entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "explicit-profile", width: orientation == .portrait ? 390 : 844,
            height: orientation == .portrait ? 844 : 390, scale: 3, orientation: orientation.rawValue), connections: [],
            files: [.init(path: "index.html", bytes: bytes.count, sha256: hash(bytes))])
        return try input(manifest, files: [.init(path: "index.html", bytes: bytes)])
    }
    private func input(_ value: DashboardManifest, files: [DevicePackageFile]) throws -> (DevicePackageBytes, DevicePackageExpectation) {
        var manifest = value; manifest.digest = nil; manifest.files.sort { $0.path < $1.path }
        manifest.digest = hash(try encoded(manifest))
        let revision = StoredRevision(revision: manifest.revision, dashboardId: manifest.dashboardId, name: manifest.name,
            digest: manifest.digest!, orientation: DeviceOrientation(rawValue: manifest.target.orientation)!, width: manifest.target.width, height: manifest.target.height)
        return (.init(manifest: try encoded(manifest), files: files), .init(revision: revision,
            target: .init(deviceId: "not-an-owner-or-profile-identity", name: "Device", width: 390, height: 844), profileID: manifest.target.profileId))
    }
    private func qualify(_ pair: (DevicePackageBytes, DevicePackageExpectation)) throws -> QualifiedDevicePackage {
        try DevicePackageQualifier.qualify(pair.0, expected: pair.1)
    }
    private func changed(_ pair: (DevicePackageBytes, DevicePackageExpectation), _ edit: (inout DashboardManifest) -> Void) throws -> (DevicePackageBytes, DevicePackageExpectation) {
        var manifest = try JSONDecoder().decode(DashboardManifest.self, from: pair.0.manifest); edit(&manifest)
        return try input(manifest, files: pair.0.files)
    }
    func testExactBytesExplicitProfileAndBothViewportOrientations() throws {
        for orientation in [DeviceOrientation.portrait, .landscape] {
            let pair = try fixture(orientation: orientation)
            let result = try qualify(pair)
            XCTAssertEqual(result.originalManifestBytes, pair.0.manifest)
            XCTAssertEqual(result.manifestSHA256, hash(pair.0.manifest))
            XCTAssertEqual(result.deploymentDigest, pair.1.revision.digest)
            XCTAssertEqual(result.manifest.target.profileId, "explicit-profile")
            XCTAssertEqual(result.files, pair.0.files)
            XCTAssertFalse(String(decoding: result.canonicalManifestBytes, as: UTF8.self).contains("\"digest\""))
        }
    }
    func testCommittedNativeCanonicalFixtureParity() throws {
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("sdk/test/fixtures/native-package/CORPUS.json"))) as! [String: Any]
        let chosen: Set<String> = ["minimal-resolved-gallery", "nested-keys-forward", "nested-keys-reversed", "ascii-file-order", "unicode-composed", "unicode-decomposed", "unicode-supplementary-escaping", "unicode-dictionary-order", "optional-empty-behavior", "optional-explicit-false", "double-fraction", "double-precision", "double-negative-zero"]
        var count = 0
        for observation in corpus["cases"] as! [[String: Any]] where chosen.contains(observation["id"] as! String) {
            let bytes = Data((observation["persistedManifestUTF8"] as! String).utf8)
            let manifest = try JSONDecoder().decode(DashboardManifest.self, from: bytes)
            let assets = try (observation["assets"] as! [[String: Any]]).map { row -> DevicePackageFile in
                guard let bytes = Data(base64Encoded: row["base64"] as! String) else { throw DevicePackageQualificationError.invalidManifest }
                return .init(path: row["path"] as! String, bytes: bytes)
            }
            let pair = try input(manifest, files: assets)
            let result = try DevicePackageQualifier.qualify(.init(manifest: bytes, files: assets.reversed()), expected: pair.1)
            XCTAssertEqual(result.deploymentDigest, observation["digest"] as? String, observation["id"] as! String)
            XCTAssertEqual(String(decoding: result.canonicalManifestBytes, as: UTF8.self), observation["canonicalUTF8"] as? String)
            XCTAssertEqual(result.originalManifestBytes, bytes)
            count += 1
        }
        XCTAssertEqual(count, chosen.count)
    }
    func testNumericUnicodeCanonicalFixturesAndStrictDomainBoundaries() throws {
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("sdk/test/fixtures/native-package-numeric-unicode/CORPUS.json"))) as! [String: Any]
        let chosen: Set<String> = ["dictionary-ascii-forward", "dictionary-unicode-forward", "dictionary-ascii-reverse", "dictionary-unicode-reverse", "dictionary-equivalent-single-composed", "dictionary-equivalent-single-decomposed", "double-small-switch", "double-large-switch", "double-zero-parameters", "double-range-and-rounding", "raw-number-9007199254740993", "target-fractional", "target-scaleUpper", "target-scaleUpperDown", "target-scalePositiveMinimum", "target-safeAreaAboveZero"]
        let rejected: Set<String> = ["target-scaleUpperUp", "target-scaleZero", "target-scaleNegativeZero", "target-safeAreaBelowZero", "raw-number-1e400", "raw-int-overflow"]
        var counts = (0, 0)
        for observation in corpus["observations"] as! [[String: Any]] {
            let name = observation["id"] as! String
            if chosen.contains(name) {
                let bytes = Data((observation["prettyManifestUTF8"] as! String).utf8)
                let manifest = try JSONDecoder().decode(DashboardManifest.self, from: bytes)
                let pair = try input(manifest, files: [.init(path: "index.html", bytes: Data("x".utf8))])
                let result = try DevicePackageQualifier.qualify(.init(manifest: bytes, files: pair.0.files), expected: pair.1)
                XCTAssertEqual(result.deploymentDigest, observation["digest"] as? String, name)
                XCTAssertEqual(String(decoding: result.canonicalManifestBytes, as: UTF8.self), observation["canonicalUTF8"] as? String, name)
                counts.0 += 1
            } else if rejected.contains(name) {
                let text = observation["rawInputManifestUTF8"] as? String ?? observation["prettyManifestUTF8"] as! String
                let pair = try fixture()
                XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: Data(text.utf8), files: pair.0.files), expected: pair.1), name)
                counts.1 += 1
            }
        }
        XCTAssertEqual(counts.0, chosen.count); XCTAssertEqual(counts.1, rejected.count)
    }
    func testAssetSetLengthHashDigestAndNativeIdentityMismatch() throws {
        let pair = try fixture()
        let files: [[DevicePackageFile]] = [[], pair.0.files + [.init(path: "extra.js", bytes: Data([1]))],
            [.init(path: "wrong.html", bytes: pair.0.files[0].bytes)],
            [.init(path: "index.html", bytes: Data(repeating: 1, count: pair.0.files[0].bytes.count))],
            [.init(path: "index.html", bytes: Data([1]))]]
        for files in files { XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: pair.0.manifest, files: files), expected: pair.1)) }
        for edit in [{ (m: inout DashboardManifest) in m.name = "Different" }, { m in m.revision = "33333333-3333-4333-8333-333333333333" }, { m in m.dashboardId = "44444444-4444-4444-8444-444444444444" }] {
            let changed = try changed(pair, edit)
            XCTAssertThrowsError(try DevicePackageQualifier.qualify(changed.0, expected: pair.1))
        }
        let corrupt = String(decoding: pair.0.manifest, as: UTF8.self).replacingOccurrences(of: pair.1.revision.digest, with: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: Data(corrupt.utf8), files: pair.0.files), expected: pair.1))
        var revision = pair.1.revision; revision.digest = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(pair.0, expected: .init(revision: revision, target: pair.1.target, profileID: pair.1.profileID)))
        XCTAssertThrowsError(try qualify(changed(pair) { $0.entrypoint = "missing.html" }))
    }
    func testExactPathsDuplicateAndReservedManifestReject() throws {
        let pair = try fixture()
        for path in ["/index.html", "a//index.html", "./index.html", "a/../index.html", "foo..bar.html", "%69ndex.html", "a\\index.html", "é.html", "a/", "manifest.json", "", String(repeating: "a", count: 1025)] {
            let result = try changed(pair) { $0.files[0].path = path; $0.entrypoint = path }
            let input = DevicePackageBytes(manifest: result.0.manifest, files: [.init(path: path, bytes: pair.0.files[0].bytes)])
            XCTAssertThrowsError(try DevicePackageQualifier.qualify(input, expected: result.1), path)
        }
        let duplicate = try changed(pair) { $0.files.append($0.files[0]) }
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: duplicate.0.manifest, files: pair.0.files + pair.0.files), expected: duplicate.1))
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: pair.0.manifest, files: pair.0.files + pair.0.files), expected: pair.1))
    }
    func testStrictNestedJSONDuplicatesSurrogatesAndUnsupportedFields() throws {
        let pair = try fixture(name: "🙂")
        let text = String(decoding: pair.0.manifest, as: UTF8.self)
        let bad = [text + "{}", text + ",", text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schema\\u0056ersion\":1"),
            text.replacingOccurrences(of: "\"width\":390", with: "\"width\":390,\"w\\u0069dth\":390"),
            text.replacingOccurrences(of: "\"width\":390", with: "\"width\":390,\"future\":true"),
            text.replacingOccurrences(of: "🙂", with: "\\uD800"), text.replacingOccurrences(of: "🙂", with: "\\uDC00"),
            text.replacingOccurrences(of: "\"width\":390", with: "\"width\":true"),
            text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1e+"),
            text.replacingOccurrences(of: "\"target\":{", with: "\"deviceBehavior\":{\"audio\":{\"autoplay\":true,\"future\":1}},\"target\":{")]
        for text in bad { XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: Data(text.utf8), files: pair.0.files), expected: pair.1)) }
        let validPair = text.replacingOccurrences(of: "🙂", with: "\\uD83D\\uDE42")
        XCTAssertNoThrow(try DevicePackageQualifier.qualify(.init(manifest: Data(validPair.utf8), files: pair.0.files), expected: pair.1))
        var invalidUTF8 = pair.0.manifest; invalidUTF8.append(255)
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: invalidUTF8, files: pair.0.files), expected: pair.1))
        for text in ["{\"x\":" + String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33) + "}",
                     "{\"x\":[" + Array(repeating: "0", count: 65_536).joined(separator: ",") + "]}",
                     "{\"é\":1,\"\\u00e9\":2}"] {
            XCTAssertThrowsError(try DevicePackageManifestPreflight.decode(Data(text.utf8)))
        }
    }
    func testCanonicallyEquivalentExpectedNameAndProfileDoNotMatchExactUTF8() throws {
        let pair = try fixture(name: "Café")
        var revision = pair.1.revision; revision.name = "Cafe\u{301}"
        XCTAssertEqual(revision.name, pair.1.revision.name) // Swift equality alone loses this distinction.
        XCTAssertFalse(revision.name.utf8.elementsEqual(pair.1.revision.name.utf8))
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(pair.0, expected: .init(revision: revision,
            target: pair.1.target, profileID: pair.1.profileID))) { XCTAssertEqual($0 as? DevicePackageQualificationError, .identityMismatch) }
        let profilePair = try changed(pair) { $0.target.profileId = "Café" }
        XCTAssertNoThrow(try qualify(profilePair))
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(profilePair.0, expected: .init(revision: profilePair.1.revision,
            target: profilePair.1.target, profileID: "Cafe\u{301}"))) { XCTAssertEqual($0 as? DevicePackageQualificationError, .targetMismatch) }
        XCTAssertEqual(try qualify(pair).deploymentDigest, pair.1.revision.digest)
    }
    func testBoundsBeforeParsingAndExpectedTargetValidation() throws {
        let pair = try fixture()
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: Data(repeating: 32, count: DevicePackageQualifier.manifestLimit + 1), files: pair.0.files), expected: pair.1)) { XCTAssertEqual($0 as? DevicePackageQualificationError, .sizeLimit) }
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: pair.0.manifest, files: Array(repeating: pair.0.files[0], count: PackageLimits.maxFiles + 1)), expected: pair.1)) { XCTAssertEqual($0 as? DevicePackageQualificationError, .sizeLimit) }
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(.init(manifest: pair.0.manifest, files: [.init(path: "index.html", bytes: Data(repeating: 0, count: PackageLimits.expandedBytes))]), expected: pair.1)) { XCTAssertEqual($0 as? DevicePackageQualificationError, .sizeLimit) }
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(pair.0, expected: .init(revision: pair.1.revision, target: pair.1.target, profileID: "wrong-explicit-profile"))) { XCTAssertEqual($0 as? DevicePackageQualificationError, .targetMismatch) }
        var target = pair.1.target; target.width = 1
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(pair.0, expected: .init(revision: pair.1.revision, target: target, profileID: pair.1.profileID)))
        var revision = pair.1.revision; revision.width = 0
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(pair.0, expected: .init(revision: revision, target: pair.1.target, profileID: pair.1.profileID))) { XCTAssertEqual($0 as? DevicePackageQualificationError, .invalidExpectation) }
        revision = pair.1.revision; revision.digest = revision.digest.uppercased()
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(pair.0, expected: .init(revision: revision, target: pair.1.target, profileID: pair.1.profileID)))
    }
    #else
    func testUnsupportedCryptoPlatformFailsClosed() throws {
        let revision = StoredRevision.offlineFixture
        let input = DevicePackageBytes(manifest: Data("{}".utf8), files: [.init(path: "index.html", bytes: Data([1]))])
        let expected = DevicePackageExpectation(revision: revision, target: .init(deviceId: "device", name: "Device"), profileID: "fixture-phone")
        XCTAssertThrowsError(try DevicePackageQualifier.qualify(input, expected: expected)) { XCTAssertEqual($0 as? DevicePackageQualificationError, .digestUnavailable) }
    }
    #endif
}
