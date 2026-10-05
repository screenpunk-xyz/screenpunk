import XCTest
@testable import ScreenpunkCore

/// Shape provenance: accepted cloud e7029fecc86a48934f48ca55604ce92c22dd2604,
/// contracts/index.ts and native-installations-http/lifecycle/client tests.
/// Synthetic observations only; no network/provider/credential storage.
final class NativeInstallationStatusCodecTests: XCTestCase {
    private let id = "11111111-1111-1111-1111-111111111111"
    private let next = "22222222-2222-2222-2222-222222222222"
    private func generation(_ id: String) -> [String: Any] {
        ["generationId": id, "createdAt": "2026-01-01T00:00:00Z", "renewAfter": "2026-01-31T00:00:00Z", "expiresAt": "2026-04-01T00:00:00Z"]
    }
    private func current() -> [String: Any] {
        let a: [String: Any] = ["installationId": id, "deviceId": id, "requestId": next, "accountId": id,
            "locationId": id, "transitionId": id, "activatedAt": "2026-01-01T00:00:00Z", "initialGeneration": generation(id)]
        return ["kind": "current-generation", "installationId": id, "accountId": id, "locationId": id,
            "transitionId": id, "generation": generation(next), "activation": a, "credential": "current", "authority": "active"]
    }
    private func claim() -> [String: Any] {
        ["kind": "claim", "claim": ["installationId": id, "requestId": next, "transitionId": id, "challengeId": next,
            "accountId": id, "locationId": id, "createdAt": "2026-01-01T00:00:00Z", "expiresAt": "2026-01-01T00:10:00Z", "outcome": "pending"]]
    }
    private func bytes(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
    func testThreeBranchesAndDifferentCurrentGeneration() throws {
        guard case .currentGeneration(let c) = try NativeInstallationStatusCodec.decode(bytes(current())) else { return XCTFail() }
        XCTAssertNotEqual(c.generation.generationId, c.activation.initialGeneration.generationId)
        guard case .claim = try NativeInstallationStatusCodec.decode(bytes(claim())) else { return XCTFail() }
        let rotation: [String: Any] = ["kind": "historical-rotation", "rotation": ["installationId": id, "transitionId": id,
            "requestId": next, "previousGenerationId": id, "generation": generation(next), "rotatedAt": "2026-01-01T00:00:00Z"]]
        guard case .historicalRotation = try NativeInstallationStatusCodec.decode(bytes(rotation)) else { return XCTFail() }
    }
    func testExpiredAndRevokedRemainObservations() throws {
        for credential in ["current", "expired", "revoked"] {
            for authority in ["active", "revoked"] {
                var o = current(); o["credential"] = credential; o["authority"] = authority
                guard case .currentGeneration(let c) = try NativeInstallationStatusCodec.decode(bytes(o)) else { return XCTFail() }
                XCTAssertEqual(c.credential.rawValue, credential); XCTAssertEqual(c.authority.rawValue, authority)
            }
        }
    }
    func testURNAndCaseNormalizeRelationships() throws {
        var o = current(); o["installationId"] = "URN:UUID:" + id.uppercased()
        XCTAssertNoThrow(try NativeInstallationStatusCodec.decode(bytes(o)))
        o["installationId"] = "urn:uuid:" + next
        XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(bytes(o)))
    }
    func testClosedNestedKeysAndDiscriminator() throws {
        var o = current(); o["claim"] = [:]; XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(bytes(o)))
        o = current(); var g = generation(next); g["extra"] = true; o["generation"] = g
        XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(bytes(o)))
        o = current(); var a = o["activation"] as! [String: Any]; a["extra"] = true; o["activation"] = a
        XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(bytes(o)))
        o = current(); o["kind"] = "future"; XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(bytes(o)))
    }
    func testDuplicateUTF8SurrogateAndDepthRejectedBeforeDecode() throws {
        let bad = [Data("{\"kind\":\"claim\",\"kind\":\"claim\"}".utf8),
            Data("{\"kind\":\"claim\",\"k\\u0069nd\":\"claim\"}".utf8),
            Data("{\"kind\":\"\\ud800\"}".utf8), Data([123,34,107,34,58,34,255,34,125]),
            Data((String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34)).utf8)]
        for b in bad { XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(b)) }
    }
    func testLongFractionBoundAndGregorianFailure() throws {
        var o = claim(), c = o["claim"] as! [String: Any]
        let fraction = String(repeating: "0", count: 220)
        c["createdAt"] = "2026-01-01T00:00:00." + fraction + "Z"
        c["expiresAt"] = "2026-01-01T00:10:00." + fraction + "Z"; o["claim"] = c
        XCTAssertNoThrow(try NativeInstallationStatusCodec.decode(bytes(o)))
        c["createdAt"] = "2026-01-01T00:00:00." + String(repeating: "0", count: 236) + "Z"; o["claim"] = c
        XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(bytes(o)))
        c["createdAt"] = "2026-02-30T00:00:00Z"; o["claim"] = c
        XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(bytes(o)))
    }
    func testLocalEnvelopeCapAndSanitizedFailure() throws {
        var b = try bytes(current()); b.append(Data(repeating: 32, count: 16384 - b.count))
        XCTAssertNoThrow(try NativeInstallationStatusCodec.decode(b))
        b.append(32)
        XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(b)) { XCTAssertEqual($0 as? NativeInstallationStatusCodec.Failure, .capacity) }
        XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(Data("secret-invalid".utf8))) {
            XCTAssertEqual($0 as? NativeInstallationStatusCodec.Failure, .invalidJSON)
        }
    }
    func testAlphabeticUUIDCaseAndURNRelationshipNormalization() throws {
        let alphabetic = "abcdefab-cdef-abcd-efab-cdefabcdefab"
        for spelling in [alphabetic, alphabetic.uppercased(), "URN:UUID:" + alphabetic.uppercased()] {
            var o = current(), activation = o["activation"] as! [String: Any]
            o["installationId"] = spelling
            activation["installationId"] = alphabetic
            activation["deviceId"] = alphabetic.uppercased()
            o["activation"] = activation
            guard case .currentGeneration(let c) = try NativeInstallationStatusCodec.decode(bytes(o)) else { return XCTFail() }
            XCTAssertEqual(c.installationId, UUID(uuidString: alphabetic))
            o["installationId"] = "urn:uuid:" + next
            XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(bytes(o)))
        }
    }
    func testUnsupportedAJVTimestampSpellingsFailClosed() throws {
        let unsupported = ["2026-01-01t00:00:00Z", "2026-01-01T00:00:00z",
            "2026-01-01 00:00:00Z", "2026-01-01T00:00:60Z", "2026-01-01T00:00:00+24:00"]
        // Existing model supports valid offsets; reject unsupported/out-of-range
        // offset syntax without narrowing that accepted evidence behavior.
        for time in unsupported {
            var o = claim(), c = o["claim"] as! [String: Any]
            c["createdAt"] = time; o["claim"] = c
            XCTAssertThrowsError(try NativeInstallationStatusCodec.decode(bytes(o)))
        }
    }

}
