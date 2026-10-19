import XCTest
@testable import ScreenpunkCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class DeviceGrantRevisionQualificationTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    private var owner: PairingIdentity { .init(role: .controller, publicKey: [UInt8](repeating: 7, count: 32)) }
    private let secret = Data("QUALIFICATION_PRIVATE_CANARY_19".utf8)
    private func encode<T: Encodable>(_ item: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]; return try e.encode(item) }
    private func input(_ entries: [DeviceGrantEntryInput], credentials: [DeviceGrantCredentialInput] = [], retained: [DeviceGrantRevisionIdentity] = [], owner suppliedOwner: PairingIdentity? = nil) -> DeviceGrantRevisionInput {
        .init(schemaVersion: 1, identity: .init(rootID: id(1), revisionID: id(2)), owner: suppliedOwner ?? owner,
              entries: entries, credentials: credentials, retainedRevisions: retained)
    }
    #if canImport(CryptoKit)
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func package(_ n: Int = 10, name: String = "Fixture", operationName: String = "read", genericConnectionCount: Int = 1) throws -> QualifiedDevicePackage {
        var home = ManifestConnection(alias: "home", required: false)
        home.serviceCalls = [.init(domain: "light", service: "turn_on", entityIds: ["light.one"])]
        home.cameraEntities = ["camera.one"]
        var publicConnection = ManifestConnection(alias: "weather", required: false)
        publicConnection.publicHTTP = .init(origin: "https://example.com", operations: [.init(name: "forecast", path: "/forecast", response: "json")])
        let data = Data("<html></html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: id(n).uuidString.lowercased(), name: name,
            revision: id(n + 100).uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "profile", width: 390, height: 844, scale: 3, orientation: "portrait"),
            connections: (0..<genericConnectionCount).map { .init(alias: genericConnectionCount == 1 ? "api" : "api\($0)", required: false, operations: [.init(name: operationName, kind: "http")]) } + [home,publicConnection],
            files: [.init(path: "index.html", bytes: data.count, sha256: hash(data))])
        manifest.digest = hash(try encode(manifest))
        let revision = StoredRevision(revision: manifest.revision, dashboardId: manifest.dashboardId, name: name,
            digest: manifest.digest!, orientation: .portrait, width: 390, height: 844)
        return try DevicePackageQualifier.qualify(.init(manifest: encode(manifest), files: [.init(path: "index.html", bytes: data)]),
            expected: .init(revision: revision, target: .init(deviceId: "device", name: "Device"), profileID: "profile"))
    }
    private func entry(_ package: QualifiedDevicePackage, n: Int = 10, generic: Bool = false, home schema: Int? = nil, publicReads: Bool = false) throws -> DeviceGrantEntryInput {
        let revision = package.revision
        var configuration: ConnectionProvisioning?
        var home: HomeAssistantProvisioning?
        var refs: [DeviceGrantCredentialReference] = []
        if generic {
            let grant = ConnectionGrant(schemaVersion: 1, id: id(400 + n), alias: "api", origin: "https://example.com", transport: .http,
                authRef: "existing-logical-ref", lan: false, allowInsecureHTTP: false,
                operations: [.init(name: "read", kind: .http, method: .GET, path: "/states", idempotent: true, write: false)])
            configuration = .init(dashboardId: revision.dashboardId, revision: revision.revision, provisioningId: "explicit-approval",
                entries: [.init(grant: grant, binding: .init(authRef: grant.authRef, placement: .bearer), secret: secret)])
            refs.append(.init(credentialRevisionID: id(600 + n), kind: .generic, key: grant.authRef))
        }
        if let schema {
            home = .init(schemaVersion: schema, dashboardId: revision.dashboardId, connectionId: "existing-home-id", provisioningId: "existing-provisioning",
                revision: revision.revision, origin: "https://example.com", token: String(decoding: secret, as: UTF8.self))
            if schema >= 2 { home?.serviceCalls = package.manifest.connections.first(where: { $0.alias == "home" })?.serviceCalls }
            if schema == 3 { home?.cameraEntities = ["camera.one"] }
            refs.append(.init(credentialRevisionID: id(800 + n), kind: .homeAssistant, key: "existing-home-id"))
        }
        return .init(entryID: id(n), revision: revision, generic: configuration, homeAssistant: home,
            publicReads: publicReads ? try .init(manifest: package.manifest) : nil, credentialReferences: refs)
    }
    private func credentials(_ entry: DeviceGrantEntryInput) -> [DeviceGrantCredentialInput] { entry.credentialReferences.map { .init(revisionID: $0.credentialRevisionID, bytes: secret) } }
    private func expectation(_ p: QualifiedDevicePackage, n: Int = 10) -> DeviceGrantEntryExpectation { .init(entryID: id(n), package: p) }

    func testCompleteInventoryIncludesExplicitNoGrantsAndLegitimateEmptySet() throws {
        let p = try package(); let e = try entry(p)
        let result = try DeviceGrantRevisionQualifier.qualify(input([e]), expectedEntries: [expectation(p)])
        XCTAssertFalse(result.publicMetadataBytes.isEmpty)
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([]), expectedEntries: [expectation(p)]))
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e,e]), expectedEntries: [expectation(p)]))
        XCTAssertNoThrow(try DeviceGrantRevisionQualifier.qualify(input([]), expectedEntries: []))
    }
    func testGenericHAAndPublicCapabilitiesUseExactQualifiedDeclarations() throws {
        let p = try package(); let e = try entry(p, generic: true, home: 3, publicReads: true)
        let typed = try DeviceGrantRevisionQualifier.qualify(input([e], credentials: credentials(e)), expectedEntries: [expectation(p)])
        let raw = try DeviceGrantRevisionQualifier.qualify(encode(input([e], credentials: credentials(e))), expectedEntries: [expectation(p)])
        XCTAssertTrue(typed.exactlyMatches(raw))
        var badHome = e.homeAssistant!; badHome.serviceCalls = [.init(domain: "switch", service: "turn_on", entityIds: ["switch.one"])]
        let bad = DeviceGrantEntryInput(entryID: e.entryID, revision: e.revision, generic: e.generic, homeAssistant: badHome, publicReads: e.publicReads, credentialReferences: e.credentialReferences)
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([bad], credentials: credentials(e)), expectedEntries: [expectation(p)]))
        var generic = e.generic!; generic.entries[0].grant.operations[0].name = "write"
        let undeclared = DeviceGrantEntryInput(entryID: e.entryID, revision: e.revision, generic: generic, homeAssistant: e.homeAssistant, publicReads: e.publicReads, credentialReferences: e.credentialReferences)
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([undeclared], credentials: credentials(e)), expectedEntries: [expectation(p)]))
    }
    func testSecretBytesAreExcludedFromMetadataDescriptionsReflectionAndHashes() throws {
        let p = try package(); let e = try entry(p, generic: true, home: 3)
        let supplied = input([e], credentials: credentials(e)); let qualified = try DeviceGrantRevisionQualifier.qualify(supplied, expectedEntries: [expectation(p)])
        let metadata = String(decoding: qualified.publicMetadataBytes, as: UTF8.self)
        for canary in [String(decoding: secret, as: UTF8.self),secret.base64EncodedString(),hash(secret)] { XCTAssertFalse(metadata.contains(canary)) }
        let object = try JSONSerialization.jsonObject(with: qualified.publicMetadataBytes) as! [String: Any]
        XCTAssertNil(object["credentials"])
        let entries = object["entries"] as! [[String: Any]]
        XCTAssertNil((entries[0]["homeAssistant"] as! [String: Any])["token"])
        XCTAssertNil((((entries[0]["generic"] as! [String: Any])["entries"] as! [[String: Any]])[0])["secret"])
        for description in [String(describing: supplied), String(reflecting: supplied),String(reflecting: e),String(reflecting: supplied.credentials[0]),String(reflecting: qualified)] {
            XCTAssertFalse(description.contains(String(decoding: secret, as: UTF8.self))); XCTAssertFalse(description.contains(secret.base64EncodedString()))
        }
        XCTAssertEqual(Mirror(reflecting: qualified).children.count, 0)
        XCTAssertEqual(Mirror(reflecting: supplied).children.count, 0)
    }
    func testMissingDuplicateConflictingUnreferencedAndWrongKindSecretsFail() throws {
        let p = try package(); let e = try entry(p, generic: true)
        let expected = [expectation(p)]; let c = credentials(e)
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e]), expectedEntries: expected))
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e], credentials: c+c), expectedEntries: expected))
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e], credentials: [.init(revisionID: c[0].revisionID, bytes: Data("different".utf8))]), expectedEntries: expected))
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e], credentials: c + [.init(revisionID: id(900), bytes: secret)]), expectedEntries: expected))
        let bad = DeviceGrantEntryInput(entryID: e.entryID, revision: e.revision, generic: e.generic, homeAssistant: nil, publicReads: nil,
            credentialReferences: [.init(credentialRevisionID: c[0].revisionID, kind: .homeAssistant, key: "existing-logical-ref")])
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([bad], credentials: c), expectedEntries: expected))
    }
    func testUnauthenticatedGrantsAndShortCommonTokensUseSchemaProjection() throws {
        let p = try package(); let authenticated = try entry(p, generic: true)
        var configuration = authenticated.generic!
        configuration.entries[0].binding.placement = .none
        configuration.entries[0].secret = nil
        let noAuth = DeviceGrantEntryInput(entryID: authenticated.entryID, revision: authenticated.revision,
            generic: configuration, homeAssistant: nil, publicReads: nil, credentialReferences: [])
        XCTAssertNoThrow(try DeviceGrantRevisionQualifier.qualify(input([noAuth]), expectedEntries: [expectation(p)]))
        configuration = authenticated.generic!
        configuration.entries[0].secret = Data("a".utf8)
        configuration.provisioningId = "a"
        let short = DeviceGrantEntryInput(entryID: authenticated.entryID, revision: authenticated.revision,
            generic: configuration, homeAssistant: nil, publicReads: nil, credentialReferences: authenticated.credentialReferences)
        let qualified = try DeviceGrantRevisionQualifier.qualify(input([short], credentials: [.init(revisionID: id(610), bytes: Data("a".utf8))]), expectedEntries: [expectation(p)])
        let metadata = try JSONSerialization.jsonObject(with: qualified.publicMetadataBytes) as! [String: Any]
        let publicEntry = (metadata["entries"] as! [[String: Any]])[0]
        let publicGeneric = publicEntry["generic"] as! [String: Any]
        XCTAssertEqual(publicGeneric["provisioningId"] as? String, "a")
        XCTAssertNil((publicGeneric["entries"] as! [[String: Any]])[0]["secret"])
        XCTAssertNil(metadata["credentials"])
        let tooMany = input(Array(repeating: noAuth, count: 13))
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(encode(tooMany), expectedEntries: [])) { XCTAssertEqual($0 as? DeviceGrantRevisionQualificationError, .sizeLimit) }
    }
    func testAggregateInlineSharingBoundAgreesForTypedAndRawAtExactBoundary() throws {
        let sharedID = id(900), bytes = Data(repeating: 65, count: 8192)
        func fixture(_ counts: [Int], homeOnLast: Bool = false) throws -> (DeviceGrantRevisionInput, [DeviceGrantEntryExpectation]) {
            var entries: [DeviceGrantEntryInput] = [], expected: [DeviceGrantEntryExpectation] = []
            for (offset, count) in counts.enumerated() {
                let n = 10 + offset, p = try package(n, genericConnectionCount: count)
                let grants: [ConnectionProvisioning.Entry] = (0..<count).map { index in
                    let grant = ConnectionGrant(schemaVersion: 1, id: id(20000 + offset * 32 + index),
                        alias: count == 1 ? "api" : "api\(index)", origin: "https://example.com", transport: .http,
                        authRef: "ref\(index)", lan: false, allowInsecureHTTP: false,
                        operations: [.init(name: "read", kind: .http, method: .GET, path: "/states", idempotent: true, write: false)])
                    return .init(grant: grant, binding: .init(authRef: grant.authRef, placement: .bearer), secret: bytes)
                }
                let config = ConnectionProvisioning(dashboardId: p.revision.dashboardId, revision: p.revision.revision,
                    provisioningId: "explicit-approval-\(offset)", entries: grants)
                var refs = grants.map { DeviceGrantCredentialReference(credentialRevisionID: sharedID, kind: .generic, key: $0.grant.authRef) }
                var home: HomeAssistantProvisioning?
                if homeOnLast && offset == counts.count - 1 {
                    home = .init(schemaVersion: 1, dashboardId: p.revision.dashboardId, connectionId: "home-id", provisioningId: "explicit-home",
                        revision: p.revision.revision, origin: "https://example.com", token: String(decoding: bytes, as: UTF8.self))
                    refs.append(.init(credentialRevisionID: sharedID, kind: .homeAssistant, key: "home-id"))
                }
                entries.append(.init(entryID: id(n), revision: p.revision, generic: config, homeAssistant: home, publicReads: nil, credentialReferences: refs))
                expected.append(expectation(p,n:n))
            }
            return (input(entries, credentials: [.init(revisionID: sharedID, bytes: bytes)]), expected)
        }
        let atLimit = try fixture([32,32,32,32]) // 128 explicit bindings, one unique 8KiB credential.
        let typed = try DeviceGrantRevisionQualifier.qualify(atLimit.0, expectedEntries: atLimit.1)
        let raw = try DeviceGrantRevisionQualifier.qualify(encode(atLimit.0), expectedEntries: atLimit.1)
        XCTAssertTrue(typed.exactlyMatches(raw))
        let overLimit = try fixture([32,32,32,32,1])
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(overLimit.0, expectedEntries: overLimit.1)) { XCTAssertEqual($0 as? DeviceGrantRevisionQualificationError, .sizeLimit) }
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(encode(overLimit.0), expectedEntries: overLimit.1)) { XCTAssertEqual($0 as? DeviceGrantRevisionQualificationError, .sizeLimit) }
        let mixedAtLimit = try fixture([32,32,32,31], homeOnLast: true)
        let mixedTyped = try DeviceGrantRevisionQualifier.qualify(mixedAtLimit.0, expectedEntries: mixedAtLimit.1)
        let mixedRaw = try DeviceGrantRevisionQualifier.qualify(encode(mixedAtLimit.0), expectedEntries: mixedAtLimit.1)
        XCTAssertTrue(mixedTyped.exactlyMatches(mixedRaw))
        let mixedOverLimit = try fixture([32,32,32,32], homeOnLast: true)
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(mixedOverLimit.0, expectedEntries: mixedOverLimit.1)) { XCTAssertEqual($0 as? DeviceGrantRevisionQualificationError, .sizeLimit) }
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(encode(mixedOverLimit.0), expectedEntries: mixedOverLimit.1)) { XCTAssertEqual($0 as? DeviceGrantRevisionQualificationError, .sizeLimit) }
    }
    func testExplicitSharedCredentialIdentityAcrossEntriesAndKindsRequiresExactBytes() throws {
        let firstPackage = try package(10), secondPackage = try package(11)
        let first = try entry(firstPackage, generic: true, home: 3), second = try entry(secondPackage, n: 11, generic: true)
        let sharedID = id(900)
        func shared(_ e: DeviceGrantEntryInput, generic: ConnectionProvisioning? = nil, refs: [DeviceGrantCredentialReference]? = nil) -> DeviceGrantEntryInput {
            .init(entryID: e.entryID, revision: e.revision, generic: generic ?? e.generic, homeAssistant: e.homeAssistant,
                publicReads: e.publicReads, credentialReferences: refs ?? e.credentialReferences.map { .init(credentialRevisionID: sharedID, kind: $0.kind, key: $0.key) })
        }
        let entries = [shared(first),shared(second)]
        let credentials = [DeviceGrantCredentialInput(revisionID: sharedID, bytes: secret)]
        let expected = [expectation(firstPackage),expectation(secondPackage,n:11)]
        XCTAssertNoThrow(try DeviceGrantRevisionQualifier.qualify(input(entries, credentials: credentials), expectedEntries: expected))
        XCTAssertNoThrow(try DeviceGrantRevisionQualifier.qualify(encode(input(entries, credentials: credentials)), expectedEntries: expected))
        var conflicting = second.generic!; conflicting.entries[0].secret = Data("different-valid-secret".utf8)
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([shared(first),shared(second,generic:conflicting)], credentials: credentials), expectedEntries: expected))
        let duplicate = shared(first,refs: entries[0].credentialReferences + [entries[0].credentialReferences[0]])
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([duplicate,entries[1]], credentials: credentials), expectedEntries: expected))
        let missing = shared(first,refs: [entries[0].credentialReferences[0]])
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([missing,entries[1]], credentials: credentials), expectedEntries: expected))
    }
    func testExactUTF8RevisionNamesAndCredentialKeysRejectCanonicalEquivalence() throws {
        let p = try package(name: "Caf\u{e9}"); let e = try entry(p, generic: true)
        var revision = e.revision; revision.name = "Cafe\u{301}"
        let wrong = DeviceGrantEntryInput(entryID: e.entryID, revision: revision, generic: e.generic, homeAssistant: nil, publicReads: nil, credentialReferences: e.credentialReferences)
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([wrong], credentials: credentials(e)), expectedEntries: [expectation(p)]))
        var config = e.generic!; config.entries[0].grant.authRef = "r\u{e9}f"; config.entries[0].binding.authRef = "re\u{301}f"
        let wrongBinding = DeviceGrantEntryInput(entryID: e.entryID, revision: e.revision, generic: config, homeAssistant: nil, publicReads: nil,
            credentialReferences: [.init(credentialRevisionID: id(610), kind: .generic, key: "r\u{e9}f")])
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([wrongBinding], credentials: [.init(revisionID: id(610), bytes: secret)]), expectedEntries: [expectation(p)]))
        config.entries[0].binding.authRef = "r\u{e9}f"
        let wrongRef = DeviceGrantEntryInput(entryID: e.entryID, revision: e.revision, generic: config, homeAssistant: nil, publicReads: nil,
            credentialReferences: [.init(credentialRevisionID: id(610), kind: .generic, key: "re\u{301}f")])
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([wrongRef], credentials: [.init(revisionID: id(610), bytes: secret)]), expectedEntries: [expectation(p)]))
    }
    func testLegacyHASchemaIsPreservedWithoutInferringOwnerOrMigration() throws {
        let p = try package(); let e = try entry(p, home: 1)
        let otherOwner = PairingIdentity(role: .controller, publicKey: [UInt8](repeating: 9, count: 32))
        let q = try DeviceGrantRevisionQualifier.qualify(input([e], credentials: credentials(e), owner: otherOwner), expectedEntries: [expectation(p)])
        XCTAssertEqual(q.owner, otherOwner) // Consistent supplied evidence does not authenticate this owner.
        let entries = (try JSONSerialization.jsonObject(with: q.publicMetadataBytes) as! [String: Any])["entries"] as! [[String: Any]]
        XCTAssertEqual((entries[0]["homeAssistant"] as! [String: Any])["schemaVersion"] as? Int, 1)
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e], credentials: credentials(e), owner: .init(role: .controller, publicKey: [])), expectedEntries: [expectation(p)]))
    }
    func testRetainedReferenceInventoryPreservesReferencesButDoesNotProveStorage() throws {
        let p = try package(); let e = try entry(p)
        let retained = DeviceGrantRevisionIdentity(rootID: id(1), revisionID: id(700))
        let q = try DeviceGrantRevisionQualifier.qualify(input([e], retained: [retained]), expectedEntries: [expectation(p)])
        XCTAssertEqual(q.retainedRevisions, [retained])
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e], retained: [retained,retained]), expectedEntries: [expectation(p)]))
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e], retained: [.init(rootID: id(3), revisionID: id(700))]), expectedEntries: [expectation(p)]))
    }
    func testStrictRawShapeUnicodeDuplicateKeysAndMalformedTokens() throws {
        let p = try package(); let e = try entry(p); let bytes = try encode(input([e])); let text = String(decoding: bytes, as: UTF8.self)
        let invalid = [text+" true", text.replacingOccurrences(of: "\"role\":\"controller\"", with: "\"role\":\"controller\",\"r\\u006fle\":\"controller\""), text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schema\\u0056ersion\":1"),
            text.replacingOccurrences(of: "\"name\":\"Fixture\"", with: "\"name\":\"\\ud800\""),
            text.replacingOccurrences(of: "\"name\":\"Fixture\"", with: "\"name\":\"Fixture\",\"future\":true"),
            text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":01")]
        for raw in invalid { XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(Data(raw.utf8), expectedEntries: [expectation(p)])) }
        XCTAssertThrowsError(try DeviceGrantRevisionPreflight.validate(Data([0xff])))
        XCTAssertNoThrow(try DeviceGrantRevisionPreflight.validate(Data("{\"multibyte-é\":\"\\ud83d\\ude00\",\"exponent\":1e2}".utf8)))
        XCTAssertThrowsError(try DeviceGrantRevisionPreflight.validate(Data((String(repeating: "[", count: 33)+"0"+String(repeating: "]", count: 33)).utf8)))
        XCTAssertThrowsError(try DeviceGrantRevisionPreflight.validate(Data(("["+Array(repeating: "0", count: 65537).joined(separator: ",")+"]").utf8)))
    }
    func testBeforeEncodingBoundsAndPublicMetadataCeilingFailClosed() throws {
        let p = try package(); let e = try entry(p)
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input(Array(repeating: e, count: 13)), expectedEntries: []))
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e], credentials: [.init(revisionID: id(900), bytes: Data(repeating: 65, count: 8193))]), expectedEntries: [expectation(p)]))
        let excessive = (0..<129).map { DeviceGrantCredentialInput(revisionID: id(1000+$0), bytes: Data(repeating: 65, count: 8192)) }
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([e], credentials: excessive), expectedEntries: [expectation(p)]))
        XCTAssertThrowsError(try DeviceGrantRevisionPreflight.decode(Data(repeating: 32, count: DeviceGrantRevisionQualifier.privateLimit+1)))
        var generic = try entry(p, generic: true).generic!
        generic.entries[0].grant.operations[0].path = "/"+String(repeating: "a", count: DeviceGrantRevisionQualifier.publicLimit)
        let large = DeviceGrantEntryInput(entryID: e.entryID, revision: e.revision, generic: generic, homeAssistant: nil, publicReads: nil,
            credentialReferences: [.init(credentialRevisionID: id(610), kind: .generic, key: "existing-logical-ref")])
        XCTAssertThrowsError(try DeviceGrantRevisionQualifier.qualify(input([large], credentials: [.init(revisionID: id(610), bytes: secret)]), expectedEntries: [expectation(p)]))
    }
    #else
    func testRawBoundsAndMalformedInputWithoutCryptoKit() throws {
        XCTAssertThrowsError(try DeviceGrantRevisionPreflight.decode(Data([0xff])))
        XCTAssertThrowsError(try DeviceGrantRevisionPreflight.decode(Data(repeating: 32, count: DeviceGrantRevisionQualifier.privateLimit+1)))
    }
    #endif
}
