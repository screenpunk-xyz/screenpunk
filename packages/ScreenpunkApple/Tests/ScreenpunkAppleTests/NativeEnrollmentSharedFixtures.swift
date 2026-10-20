import XCTest
import CryptoKit
import Combine
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple

// Shared by SwiftPM acceptance tests and the iOS scene test target.
final class AuthorityJournal: CloudInstallationTransitionJournal {
    var value: DeviceManagementTransitionHistory?
    var unavailable = false
    var writeThenThrow = false
    func load() throws -> DeviceManagementTransitionHistory? {
        if unavailable { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
        return value
    }
    func save(_ history: DeviceManagementTransitionHistory) throws {
        value = history
        if writeThenThrow { unavailable = true; throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
    }
}
final class AuthorityBackend: CloudInstallationCredentialBackend, @unchecked Sendable {
    var values: [String: Data] = [:]
    var inaccessible = false
    func read(reference: String) throws -> Data? {
        if inaccessible { throw CloudInstallationCredentialError.inaccessible(status: -25308) }
        return values[reference]
    }
    func references() throws -> Set<String> {
        if inaccessible { throw CloudInstallationCredentialError.inaccessible(status: -25308) }
        return Set(values.keys)
    }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert {
        values[reference] = secret
        return .inserted
    }
}

struct FreshOwnerTokens: CloudNativeTokenProvider { func idToken() async throws -> String { "synthetic-human-token" } }
final class FreshGrantTransport: DeviceGrantCredentialTransport, NativeCloudCredentialAbsenceProbe, @unchecked Sendable {
    let rootID: UUID
    private var values: [String: DeviceGrantCredentialTransportSecret] = [:]
    private var exactBytes: [String: Data] = [:]
    init(rootID: UUID) { self.rootID = rootID }
    func inventory(maximum: Int, visit: (DeviceGrantCredentialObservation) throws -> Void) throws {
        guard values.count <= maximum else { throw DeviceManagementAuthority.Failure.staleLease }
        for value in values.values { try visit(value.observation) }
    }
    func read(account: String, maximumBytes: Int) throws -> DeviceGrantCredentialTransportSecret? {
        guard let value = values[account] else { return nil }
        guard value.observation.byteCount <= maximumBytes else { throw DeviceManagementAuthority.Failure.staleLease }
        return value
    }
    func add(account: String, bytes: Data) throws -> DeviceGrantCredentialObservation {
        guard values[account] == nil else { throw DeviceManagementAuthority.Failure.staleLease }
        let observation = try DeviceGrantCredentialObservation(account: account, persistentReference: Data(UUID().uuidString.utf8), byteCount: bytes.count)
        exactBytes[account] = bytes
        values[account] = try .init(observation: observation, bytes: bytes); return observation
    }
    func exactCredentialsForLogoutAcceptance() throws -> [DeviceOwnedInstallationResetResources.Credential] {
        try values.keys.sorted().map { account in
            guard let value = values[account], let bytes = exactBytes[account] else { throw NativeEnrollmentPromotionError.blocked }
            return .init(service: DeviceGrantCredentialNamespace(rootID: rootID).service, account: account,
                persistentReference: value.observation.persistentReference, byteCount: bytes.count,
                valueSHA256: PeerPin.hex(PeerPin.sha256(bytes)))
        }
    }
    func removeCloudCredentialExact(_ credential: DeviceOwnedInstallationResetResources.Credential) throws {
        guard credential.service == DeviceGrantCredentialNamespace(rootID: rootID).service else { throw NativeEnrollmentPromotionError.blocked }
        guard let value = values[credential.account] else {
            guard exactBytes[credential.account] == nil else { throw NativeEnrollmentPromotionError.blocked }; return
        }
        guard value.observation.persistentReference == credential.persistentReference,
            let bytes = exactBytes[credential.account], bytes.count == credential.byteCount,
            PeerPin.hex(PeerPin.sha256(bytes)) == credential.valueSHA256 else { throw NativeEnrollmentPromotionError.blocked }
        values.removeValue(forKey: credential.account); exactBytes.removeValue(forKey: credential.account)
    }
    func requireAbsent(_ credential: DeviceOwnedInstallationResetResources.Credential) throws {
        guard credential.service == DeviceGrantCredentialNamespace(rootID: rootID).service,
            values[credential.account] == nil, exactBytes[credential.account] == nil,
            !values.values.contains(where: { $0.observation.persistentReference == credential.persistentReference })
        else { throw NativeEnrollmentPromotionError.blocked }
    }

}
final class FreshCredentialStorage: NativeEnrollmentCredentialStorage, NativeCloudCredentialAbsenceProbe {
    private let original48: Data
    init(original48: Data = Data(repeating: 17, count: 48)) { self.original48 = original48 }
    private var items: [Data: NativeEnrollmentStoredCredential] = [:]
    private var exactItems: [Data: (service: Data, account: Data, payload: Data)] = [:]
    private(set) var adds = 0
    private(set) var reads = 0
    func enumerateBounded(maximum: Int) throws -> [NativeEnrollmentStoredCredential] { Array(items.values) }
    func generateOriginal48() throws -> Data { guard original48.count == 48 else { throw NativeEnrollmentPromotionError.blocked }; return original48 }
    func readExactPersistentReference(_ reference: Data) throws -> NativeEnrollmentStoredCredential? { reads += 1; return items[reference] }
    private func add(service: String, account: Data, payload: Data) -> NativeEnrollmentCredentialInsert {
        adds += 1; let ref = Data("fixture-ref-\(adds)".utf8)
        exactItems[ref] = (Data(service.utf8), account, payload)
        items[ref] = .init(service: Data(service.utf8), account: account, persistentReference: ref, payload: payload, accessible: true)
        return .inserted(ref)
    }
    func removeCloudCredentialExact(_ credential: DeviceOwnedInstallationResetResources.Credential) throws {
        guard let item = exactItems[credential.persistentReference] else {
            guard items[credential.persistentReference] == nil else { throw NativeEnrollmentPromotionError.blocked }; return
        }
        guard item.service == Data(credential.service.utf8), item.account == Data(credential.account.utf8),
            item.payload.count == credential.byteCount,
            PeerPin.hex(PeerPin.sha256(item.payload)) == credential.valueSHA256 else { throw NativeEnrollmentPromotionError.blocked }
        items.removeValue(forKey: credential.persistentReference)
        exactItems.removeValue(forKey: credential.persistentReference)
    }
    func requireAbsent(_ credential: DeviceOwnedInstallationResetResources.Credential) throws {
        guard items[credential.persistentReference] == nil,
            !exactItems.values.contains(where: { $0.service == Data(credential.service.utf8) && $0.account == Data(credential.account.utf8) })
        else { throw NativeEnrollmentPromotionError.blocked }
    }
    func insertStageOnly(account: Data, envelope: Data) throws -> NativeEnrollmentCredentialInsert { add(service: "xyz.screenpunk.installation.cloud.enrollment-stage.v1", account: account, payload: envelope) }
    func insertFinalOnly(account: Data, original48: Data) throws -> NativeEnrollmentCredentialInsert { add(service: "xyz.screenpunk.installation.cloud", account: account, payload: original48) }
}
final class FreshOwnerHTTP {
    let claim: NativeClaimInput
    var delivery: AuthorityStaticDeliveryFixture.Value?
    var deliveryPaths: [String] = []
    var unavailableDeliveryPackageIDs: Set<String> = []
    struct SequenceRequest { let path: String; let bytes: Data? }
    struct SequenceHTTPFailure: Error { let status: Int }
    var productionSequenceEnabled = false
    var sequenceEmptyCommand = false
    var sequenceObservationFailures = 0
    var sequenceRuntimeFailures = 0
    var sequenceMountFailureReportFailures = 0
    private var sequenceMountFailureAccepted = false
    var holdSequenceStatus = false
    var holdSequenceRuntime = false
    private var sequenceReceiptAccepted = false
    private let sequenceLock = NSLock()
    private var sequenceRecorded: [SequenceRequest] = []
    private var sequenceHeld: [Interceptor] = []
    var sequenceRequests: [SequenceRequest] { sequenceLock.lock(); defer { sequenceLock.unlock() }; return sequenceRecorded }
    var sequenceHeldCount: Int { sequenceLock.lock(); defer { sequenceLock.unlock() }; return sequenceHeld.count }
    func releaseSequenceRequests() {
        sequenceLock.lock(); let pending = sequenceHeld; sequenceHeld = []; sequenceLock.unlock()
        holdSequenceStatus = false; holdSequenceRuntime = false
        for request in pending { request.respond() }
    }
    private func recordSequence(_ path: String, bytes: Data?) {
        guard productionSequenceEnabled else { return }
        sequenceLock.lock(); sequenceRecorded.append(.init(path: path, bytes: bytes)); sequenceLock.unlock()
    }
    var requestCount = 0
    var capabilityRequests = 0
    private(set) var acceptedStateGenerationID: UUID?
    let installationID = UUID(), challengeID = UUID(), generationID = UUID(), activationRequestID = UUID()
    let origin = URL(string: "https://" + UUID().uuidString.lowercased() + ".fixture.test")!
    init(claim: NativeClaimInput) { self.claim = claim; Interceptor.register(self) }
    func close() { Interceptor.remove(self) }
    var configuration: URLSessionConfiguration { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Interceptor.self]; return c }
    private func activation() throws -> NativeActivationReceipt {
        try .init(installationId: installationID, deviceId: installationID, requestId: activationRequestID,
            accountId: claim.accountId, locationId: claim.locationId, transitionId: claim.transitionId, activatedAt: "2026-01-01T00:00:00Z",
            initialGeneration: .init(generationId: generationID, createdAt: "2026-01-01T00:00:00Z", renewAfter: "2026-01-31T00:00:00Z", expiresAt: "2026-04-01T00:00:00Z"))
    }
    func realtimeSessionBytes() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "transport": "firebase-rtdb",
            "firebase": ["projectId": "fixture-project", "databaseURL": "https://fixture-default-rtdb.firebaseio.com",
                "apiKey": "synthetic-public-api-key", "appId": "1:123:ios:fixture", "messagingSenderId": "123"],
            "customToken": "synthetic-custom-token", "firebaseUID": "spni:" + installationID.uuidString.lowercased() + ":" + generationID.uuidString.lowercased(),
            "installationId": installationID.uuidString, "accountId": claim.accountId.uuidString,
            "transitionId": claim.transitionId.uuidString, "credentialGenerationId": generationID.uuidString,
            "wakePath": "v1/installations/" + installationID.uuidString.lowercased() + "/wake",
            "presencePath": "v1/installations/" + installationID.uuidString.lowercased() + "/presence",
            "cursor": "7", "credentialExpiresAtMs": 1775001600000 as Int64, "reconciliationMaxSeconds": 21600,
            "presenceConnectionId": UUID().uuidString.lowercased(), "presenceSlots": (0..<8).map(String.init)])
    }
    private func requestBytes(_ request: URLRequest, limit: Int) throws -> Data? {
        if let body = request.httpBody { guard body.count <= limit else { throw CancellationError() }; return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw CancellationError() }
            if count == 0 { return data }
            guard count <= limit - data.count else { throw CancellationError() }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    private func reply(_ request: URLRequest) throws -> Data {
        requestCount += 1
        if productionSequenceEnabled, request.httpMethod == "GET" || request.url?.path == "/v1/native/installations/capabilities" {
            recordSequence(request.url!.path, bytes: nil)
        }
        if let path = request.url?.path, path.hasSuffix("/services/runtime-observations"), productionSequenceEnabled {
            deliveryPaths.append(path)
            let bytes = try XCTUnwrap(requestBytes(request, limit: 4096))
            recordSequence(path, bytes: bytes)
            if sequenceRuntimeFailures > 0 { sequenceRuntimeFailures -= 1; throw SequenceHTTPFailure(status: 503) }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let command = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(delivery).command) as? [String: Any])
            let set = try XCTUnwrap(command["resultingSet"] as? [String: Any])
            let entry = try XCTUnwrap((set["entries"] as? [[String: Any]])?.first)
            let provenance = try XCTUnwrap(entry["provenance"] as? [String: Any])
            let package = try XCTUnwrap(provenance["package"] as? [String: Any])
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true,
                object["generationId"] as? String == acceptedStateGenerationID?.uuidString.lowercased(),
                object["generationId"] as? String == command["desiredSetGenerationId"] as? String,
                object["entryId"] as? String == set["configuredEntryId"] as? String,
                object["packageDigest"] as? String == package["manifestDigest"] as? String else { throw SequenceHTTPFailure(status: 409) }
            return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "generationId": try XCTUnwrap(object["generationId"]),
                "entryId": try XCTUnwrap(object["entryId"]), "accepted": true])
        }
        if let path = request.url?.path, path.hasSuffix("/services/runtime-observations") {
            deliveryPaths.append(path)
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true,
                let bytes = try requestBytes(request, limit: 4096), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                object["entryId"] is NSNull, object["packageDigest"] is NSNull else { throw CancellationError() }
            return try JSONSerialization.data(withJSONObject: ["schemaVersion":1, "generationId":try XCTUnwrap(object["generationId"]), "entryId":NSNull(), "accepted":true])
        }
        if request.url?.path == "/v1/native/installations/capabilities" {
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true,
                let bytes = try requestBytes(request, limit: 4096), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                object["schemaVersion"] as? Int == 1, object["concurrentControlVersion"] as? Int == 1 else { throw CancellationError() }
            capabilityRequests += 1
            return try JSONSerialization.data(withJSONObject: ["schemaVersion":1,"installationId":installationID.uuidString,
                "transitionId":claim.transitionId.uuidString,"concurrentControlVersion":1])
        }
        if let path = request.url?.path, path.hasPrefix("/v1/native/installations/delivery/") {
            deliveryPaths.append(path)
            guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true else { throw CancellationError() }
            if request.httpMethod == "GET", let delivery {
                if path == "/v1/native/installations/delivery/command" {
                    if productionSequenceEnabled && (sequenceReceiptAccepted || sequenceMountFailureAccepted || sequenceEmptyCommand) { return Data("{\"command\":null,\"nextCheckSeconds\":5}".utf8) }
                    return Data("{\"command\":".utf8) + delivery.command + Data(",\"nextCheckSeconds\":5}".utf8)
                }
                if path.hasPrefix("/v1/native/installations/delivery/plan/") { return delivery.plan }
                if path.hasPrefix("/v1/native/installations/delivery/package/") {
                    if unavailableDeliveryPackageIDs.contains(request.url!.lastPathComponent) { throw SequenceHTTPFailure(status: 404) }
                    return delivery.archive.archiveBytes
                }
            }
            if request.httpMethod == "GET", path == "/v1/native/installations/delivery/command", delivery == nil {
                return Data("{\"command\":null,\"nextCheckSeconds\":5}".utf8)
            }
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true,
                let bytes = try requestBytes(request, limit: 16384), var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CancellationError() }
            recordSequence(path, bytes: bytes)
            if productionSequenceEnabled && path == "/v1/native/installations/delivery/progress" {
                if object["phase"] as? String == "failed" {
                    if sequenceMountFailureReportFailures > 0 {
                        sequenceMountFailureReportFailures -= 1; throw SequenceHTTPFailure(status: 503)
                    }
                    sequenceMountFailureAccepted = true
                }
                return try JSONSerialization.data(withJSONObject: ["operationId": try XCTUnwrap(object["operationId"]),
                    "phase": try XCTUnwrap(object["phase"]), "accepted": true])
            }
            if path == "/v1/native/installations/delivery/observations" {
                if productionSequenceEnabled && sequenceObservationFailures > 0 {
                    sequenceObservationFailures -= 1; throw SequenceHTTPFailure(status: 503)
                }
                let state = try XCTUnwrap(object["state"] as? [String: Any])
                guard let previous = object["previousGenerationId"] as? String,
                    UUID(uuidString: previous) == acceptedStateGenerationID,
                    let generation = state["generationId"] as? String,
                    let accepted = UUID(uuidString: generation), accepted != acceptedStateGenerationID else { throw CancellationError() }
                acceptedStateGenerationID = accepted
                object = ["installationId":try XCTUnwrap(state["installationId"]), "transitionId":try XCTUnwrap(state["transitionId"]),
                    "generationId":try XCTUnwrap(state["generationId"]), "accepted":true]
            } else if request.url?.path == "/v1/native/installations/delivery/state" {
                guard let generation = object["generationId"] as? String,
                    let accepted = UUID(uuidString: generation) else { throw CancellationError() }
                acceptedStateGenerationID = accepted
                object = ["installationId": try XCTUnwrap(object["installationId"]), "transitionId": try XCTUnwrap(object["transitionId"]),
                    "generationId": try XCTUnwrap(object["generationId"]), "accepted": true]
            } else if request.url?.path == "/v1/native/installations/delivery/activation" {
                object["authorizationDigest"] = String(repeating: "a", count: 64)
                object["authorizedAt"] = "2026-10-05T20:00:00Z"; object["expiresAt"] = "2026-10-05T20:00:30Z"
            } else if request.url?.path == "/v1/native/installations/delivery/receipt" {
                if productionSequenceEnabled {
                    guard object["resultingGenerationId"] as? String == acceptedStateGenerationID?.uuidString.lowercased() else { throw SequenceHTTPFailure(status: 409) }
                    sequenceReceiptAccepted = true
                }
                for key in ["activationRequestId", "authorizationDigest", "previousGenerationId", "resultingGenerationId", "renderState"] { object.removeValue(forKey: key) }
                object["receiptId"] = UUID().uuidString.lowercased(); object["receivedAt"] = "2026-10-05T20:00:31Z"
            } else { throw CancellationError() }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }

        if request.url?.path == "/v1/native/installations/realtime/session" {
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true,
                request.url?.query == nil, try requestBytes(request, limit: 1) == nil else { throw CancellationError() }
            deliveryPaths.append("/v1/native/installations/realtime/session")
            return try realtimeSessionBytes()
        }
        if request.url?.path == "/v1/native/installations/revoke" {
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true,
                let bytes = try requestBytes(request, limit: 1024),
                let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object.isEmpty else { throw CancellationError() }
            return try JSONSerialization.data(withJSONObject: ["installationId": installationID.uuidString, "revokedAt": "2026-10-15T00:00:00Z"])
        }
        if request.url?.path == "/v1/native/installations/status" {
            guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true else { throw CancellationError() }
            let receipt = try activation(), activation = try JSONSerialization.jsonObject(with: nativeEnrollmentBytes(receipt))
            let generation = try JSONSerialization.jsonObject(with: nativeEnrollmentBytes(receipt.initialGeneration))
            return try JSONSerialization.data(withJSONObject: ["kind":"current-generation", "installationId":installationID.uuidString, "accountId":claim.accountId.uuidString,
                "locationId":claim.locationId.map { $0.uuidString } as Any? ?? NSNull(), "transitionId":claim.transitionId.uuidString, "generation":generation, "activation":activation, "credential":"current", "authority":"active"])
        }
        guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-human-token",
            request.value(forHTTPHeaderField: "x-screenpunk-installation-credential")?.hasPrefix("spni1_") == true else { throw CancellationError() }
        if request.url?.path == "/v1/native/installations/claims" {
            return try nativeEnrollmentBytes(NativeClaimReceipt(installationId: installationID, requestId: claim.requestId, transitionId: claim.transitionId, challengeId: challengeID,
                accountId: claim.accountId, locationId: claim.locationId, createdAt: "2026-01-01T00:00:00Z", expiresAt: "2026-01-01T00:10:00Z", outcome: .pending))
        }
        guard request.url?.path == "/v1/native/installations/activate" else { throw CancellationError() }
        return try nativeEnrollmentBytes(activation())
    }
    final class Interceptor: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var entries: [String: FreshOwnerHTTP] = [:]
        static func register(_ f: FreshOwnerHTTP) { lock.lock(); defer { lock.unlock() }; entries[f.origin.host!] = f }
        static func remove(_ f: FreshOwnerHTTP) { lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: f.origin.host!) }
        override class func canInit(with request: URLRequest) -> Bool {
            lock.lock(); defer { lock.unlock() }; return request.url?.host.flatMap { entries[$0] } != nil
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock(); let f = request.url?.host.flatMap { Self.entries[$0] }; Self.lock.unlock()
            if let f, f.productionSequenceEnabled,
                (f.holdSequenceStatus && request.url?.path == "/v1/native/installations/status") ||
                (f.holdSequenceRuntime && request.url?.path.hasSuffix("/services/runtime-observations") == true) {
                f.sequenceLock.lock(); f.sequenceHeld.append(self); f.sequenceLock.unlock(); return
            }
            respond()
        }
        func respond() {
            Self.lock.lock(); let f = request.url?.host.flatMap { Self.entries[$0] }; Self.lock.unlock()
            do {
                guard let f else { throw CancellationError() }
                let bytes = try f.reply(request)
                var headers = ["Content-Type": "application/json"]
                if request.url!.path.hasPrefix("/v1/native/installations/delivery/plan/") {
                    headers["Content-Type"] = "application/octet-stream"
                    headers["X-Screenpunk-Plan-Association"] = try XCTUnwrap(f.delivery).header
                } else if request.url!.path.hasPrefix("/v1/native/installations/delivery/package/") { headers["Content-Type"] = "application/zip" }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
            } catch let error as FreshOwnerHTTP.SequenceHTTPFailure {
                let response = HTTPURLResponse(url: request.url!, statusCode: error.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
}

enum AuthorityStaticDeliveryFixture {
    struct Value { let command: Data, header: String, plan: Data, archive: NativeDeliveryArchiveInput }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(value)
    }
    static func make(state: [String: Any], activation: NativeActivationReceipt, connections: [ManifestConnection] = [], dashboard: UUID = UUID(), revision: UUID = UUID()) throws -> Value {
        let html = Data("<html><body>Genuine static fixture</body></html>".utf8)
        let entry = UUID(), package = UUID()
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: dashboard.uuidString.lowercased(), name: "Fixture",
            revision: revision.uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "Fixture", width: 390, height: 844, scale: 3, orientation: "portrait"), connections: connections,
            files: [.init(path: "index.html", bytes: html.count, sha256: hash(html))])
        manifest.digest = hash(try encoded(manifest)); let manifestBytes = try encoded(manifest)
        let zip = storedZIP([("manifest.json", manifestBytes), ("index.html", html)])
        let descriptor = try DeviceDeliveryPackageCandidate.validating(packageProfile: DeviceDeliveryPackageCandidate.profile,
            publicationID: UUID(), projectID: UUID(), packageID: package, dashboardID: dashboard, revision: revision,
            manifestDigest: .validating(try XCTUnwrap(manifest.digest)), manifestSHA256: .validating(hash(manifestBytes)), archiveSHA256: .validating(hash(zip)),
            compressedBytes: UInt64(zip.count), expandedBytes: UInt64(manifestBytes.count + html.count), archiveEntries: 2)
        let candidate = DeviceDeliveryEntryCandidate.validating(entryID: entry, provenance: .cloud(descriptor))
        let set = try DeviceResultingSetCandidate.validating(entries: [candidate], configuredEntryID: entry)
        let rawPlan = Data("original static fixture plan".utf8)
        let association: [String: Any] = ["schemaVersion": 1, "operationId": UUID().uuidString.lowercased(), "planId": UUID().uuidString.lowercased(),
            "installationId": try XCTUnwrap(state["installationId"]), "accountId": activation.accountId.uuidString.lowercased(),
            "locationId": activation.locationId.map { $0.uuidString.lowercased() } as Any? ?? NSNull(), "transitionId": try XCTUnwrap(state["transitionId"]),
            "planDigest": hash(rawPlan), "planByteLength": rawPlan.count]
        let exact = association
        var command = exact
        command["sequence"] = "1"; command["expectedInstalledSetGenerationId"] = try XCTUnwrap(state["generationId"])
        command["desiredSetGenerationId"] = UUID().uuidString.lowercased(); command["executionExpiresAt"] = "2026-10-05T20:00:00Z"
        command["resultingSetDigest"] = try DeviceDeliveryCandidateCodec.resultingSetDigest(set)
        command["resultingSet"] = ["schemaVersion": 1, "configuredEntryId": entry.uuidString.lowercased(), "entries": [["entryId": entry.uuidString.lowercased(), "provenance": ["kind": "cloud", "package": [
            "packageProfile": DeviceDeliveryPackageCandidate.profile, "publicationId": descriptor.publicationID.uuidString.lowercased(), "projectId": descriptor.projectID.uuidString.lowercased(),
            "packageId": package.uuidString.lowercased(), "dashboardId": dashboard.uuidString.lowercased(), "revision": revision.uuidString.lowercased(),
            "manifestDigest": descriptor.manifestDigest.text, "manifestSha256": descriptor.manifestSHA256.text, "archiveSha256": descriptor.archiveSHA256.text,
            "compressedBytes": descriptor.compressedBytes, "expandedBytes": descriptor.expandedBytes, "archiveEntries": descriptor.archiveEntries]]]]]
        let header = try JSONSerialization.data(withJSONObject: exact).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return .init(command: try JSONSerialization.data(withJSONObject: command), header: header, plan: rawPlan,
            archive: .init(entryID: entry, preparationOperationID: UUID(), archiveBytes: zip, profileID: "Fixture", revisionName: "Fixture",
                target: .init(deviceId: "fixture", name: "Fixture", orientation: .portrait, width: 390, height: 844)))
    }
    static func storedZIP(_ files: [(String, Data)]) -> Data {
        func word(_ n: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8)]) }
        func long(_ n: UInt32) -> Data { Data([UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 24)]) }
        func crc(_ bytes: Data) -> UInt32 { var n: UInt32 = 0xffffffff; for b in bytes { n ^= UInt32(b); for _ in 0..<8 { n = n & 1 == 1 ? (n >> 1) ^ 0xedb88320 : n >> 1 } }; return n ^ 0xffffffff }
        var local = Data(), central = Data()
        for (path, raw) in files {
            let name = Data(path.utf8), offset = UInt32(local.count), checksum = crc(raw)
            let localParts: [Data] = [long(0x04034b50), word(20), word(0x800), word(0), word(0), word(0), long(checksum), long(UInt32(raw.count)), long(UInt32(raw.count)), word(UInt16(name.count)), word(0), name, raw]
            for part in localParts { local.append(part) }
            let centralParts: [Data] = [long(0x02014b50), word(0x314), word(20), word(0x800), word(0), word(0), word(0), long(checksum), long(UInt32(raw.count)), long(UInt32(raw.count)), word(UInt16(name.count)), word(0), word(0), word(0), word(0), long(0x81a40000), long(offset), name]
            for part in centralParts { central.append(part) }
        }
        var result = local; result.append(central)
        let endParts: [Data] = [long(0x06054b50), word(0), word(0), word(UInt16(files.count)), word(UInt16(files.count)), long(UInt32(central.count)), long(UInt32(local.count)), word(0)]
        for part in endParts { result.append(part) }; return result
    }
}


final class LogoutAcceptanceCredentialProbe: NativeCloudCredentialAbsenceProbe, @unchecked Sendable {
    let native: FreshCredentialStorage
    let grants: FreshGrantTransport
    init(native: FreshCredentialStorage, grants: FreshGrantTransport) { self.native = native; self.grants = grants }
    func requireAbsent(_ credential: DeviceOwnedInstallationResetResources.Credential) throws {
        if credential.service == DeviceGrantCredentialNamespace(rootID: grants.rootID).service {
            try grants.requireAbsent(credential)
        } else {
            guard credential.service == "xyz.screenpunk.installation.cloud" || credential.service == "xyz.screenpunk.installation.cloud.enrollment-stage.v1"
            else { throw NativeEnrollmentPromotionError.blocked }
            try native.requireAbsent(credential)
        }
    }
}
