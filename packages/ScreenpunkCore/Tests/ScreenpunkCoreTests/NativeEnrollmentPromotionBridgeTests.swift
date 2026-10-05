import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@_spi(NativeInstallation) @testable import ScreenpunkCore

// Draft controls only; not run. Genuine journal integration controls are pending.
final class NativeEnrollmentPromotionBridgeTests: XCTestCase {
    final class Backend: NativeEnrollmentPromotionBackend, NativeEnrollmentStageBackend {
        var items: [NativeEnrollmentRawCredentialItem] = []
        var adds = 0
        var reads = 0
        var duplicate = false
        func enumerateRaw(limit: Int) throws -> [NativeEnrollmentRawCredentialItem] {
            return Array(items.prefix(limit)) // Exact limit is overflow witness, never limit-1.
        }
        func readPersistentReference(_ ref: Data) throws -> NativeEnrollmentRawCredentialItem? { reads += 1; return items.first { $0.persistentReference == ref } }
        func generate48() throws -> Data { Data(repeating: 42, count: 48) }
        func addStageOnce(account: Data, payload: Data) throws -> NativeEnrollmentStageAddResult {
            let ref = Data("fixture-stage".utf8)
            items.append(.init(service: Data(NativeEnrollmentStageEnvelope.service.utf8), account: account, persistentReference: ref, payload: payload))
            return .added(ref)
        }
        func addFinalOnce(account: Data, raw48: Data) throws -> NativeEnrollmentPromotionAddResult {
            adds += 1; if duplicate { return .duplicate }
            guard raw48.count == 48 else { throw NativeEnrollmentPromotionError.blocked }
            let ref = Data([UInt8(adds)])
            items.append(.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: account, persistentReference: ref, payload: raw48))
            return .added(ref)
        }
    }
    private func item(_ ref: UInt8, account: String = "native-final-1", accessible: Bool = true) -> NativeEnrollmentRawCredentialItem {
        .init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data(account.utf8),
              persistentReference: Data([ref]), payload: Data(repeating: 7, count: 48), accessible: accessible)
    }
    func testValidInventoryPositiveControl() throws {
        XCTAssertNoThrow(try NativeEnrollmentStageBinding.reference(Data("native-final-1".utf8)))
        XCTAssertNoThrow(try NativeEnrollmentPromotionBridge.validateInventory([item(1), item(2, account: "native-final-2")]))
    }
    func testInventoryRejectsDuplicateReferences() throws {
        XCTAssertThrowsError(try NativeEnrollmentPromotionBridge.validateInventory([item(1), item(1, account: "native-final-2")]))
    }
    func testInventoryRejectsDuplicateAccounts() throws {
        XCTAssertThrowsError(try NativeEnrollmentPromotionBridge.validateInventory([item(1), item(2)]))
    }
    func testInventoryRejectsInaccessibleAndUnknownService() throws {
        XCTAssertThrowsError(try NativeEnrollmentPromotionBridge.validateInventory([item(1, accessible: false)]))
        XCTAssertThrowsError(try NativeEnrollmentPromotionBridge.validateInventory([.init(service: Data("other".utf8), account: Data("a".utf8), persistentReference: Data([3]), payload: Data())]))
    }
    func testFakeBackendPreserves48AndDoesNotAdoptDuplicate() throws {
        let b = Backend(), raw = Data(repeating: 0xA4, count: 48)
        guard case .added(let ref) = try b.addFinalOnce(account: Data("final".utf8), raw48: raw) else { return XCTFail() }
        XCTAssertTrue(try b.readPersistentReference(ref)?.keychainPayload() == raw)
        b.duplicate = true
        guard case .duplicate = try b.addFinalOnce(account: Data("final".utf8), raw48: raw) else { return XCTFail() }
        XCTAssertEqual(b.items.count, 1)
    }
    private func finals(_ count: Int) -> [NativeEnrollmentRawCredentialItem] {
        (0..<count).map { i in
            .init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8),
                account: Data("native-final-\(i)".utf8), persistentReference: Data("ref-\(i)".utf8),
                payload: Data(repeating: 7, count: 48))
        }
    }
    func testFreeFinalCapacityPositive127() throws {
        XCTAssertNoThrow(try NativeEnrollmentPromotionBridge.validateFreeFinalSlot(finals(127)))
    }
    func testSaturatedPreflightRejectsBeforeFakeAdd() throws {
        let b = Backend(); b.items = finals(128)
        XCTAssertNoThrow(try NativeEnrollmentPromotionBridge.validateInventory(b.items))
        XCTAssertThrowsError(try NativeEnrollmentPromotionBridge.validateFreeFinalSlot(b.items))
        XCTAssertEqual(b.adds, 0) // Pure preflight; not a fabricated bridge proof.
    }
    func testOverflowWitnessRejected() throws {
        let b = Backend(); b.items = finals(194)
        let witness = try b.enumerateRaw(limit: 193)
        XCTAssertEqual(witness.count, 193)
        XCTAssertThrowsError(try NativeEnrollmentPromotionBridge.validateInventory(witness))
        XCTAssertEqual(b.adds, 0)
    }

    func testActualSwiftMaximumPromotionEncoderFitsExistingReservations() throws {
        let size = try NativeJournalCodec.promotionLayoutReservationProof()
        XCTAssertLessThanOrEqual(size.frameBytes, 8192)
        XCTAssertLessThanOrEqual(size.attemptBytes, 32768)
        XCTAssertEqual(NativeJournalCodec.nodeLimit, 771)
        XCTAssertEqual(NativeJournalCodec.pairedCompletionReservation, 16_629_760)
    }

    func testExistingPhysicalNamespaceRejectsAliasesSymlinksAndMissingWithoutCreation() throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        let temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        free(physical)
        let parent = temporary.appendingPathComponent("physical-native-" + UUID().uuidString, isDirectory: true)
        let namespace = parent.appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName, isDirectory: true)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertNoThrow(try NativeEnrollmentPhysicalDirectory.require(namespace))
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: namespace)
        XCTAssertThrowsError(try NativeEnrollmentPhysicalDirectory.require(alias))
        let missing = parent.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try NativeEnrollmentPhysicalDirectory.require(missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let leaf = parent.appendingPathComponent("regular-file")
        try Data("preserved".utf8).write(to: leaf)
        XCTAssertThrowsError(try NativeEnrollmentPhysicalDirectory.require(leaf))
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserved".utf8))
        if namespace.path.hasPrefix("/private/var/") {
            let systemAlias = URL(fileURLWithPath: String(namespace.path.dropFirst("/private".count)), isDirectory: true)
            XCTAssertThrowsError(try NativeEnrollmentPhysicalDirectory.require(systemAlias))
        }
    }

    private struct UnusedGrantBackend: DeviceGrantCredentialBackend {
        func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {}
        func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? { nil }
        func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem { throw DeviceGrantPreparationError.conflict }
    }
    private func genuineStatusFixture(firstNative: Bool = false) async throws -> (NativeOperationalInstallation, NativeActivationReceipt, Backend) {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        let temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        free(physical)
        let parent = temporary.appendingPathComponent("native-status-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("journal"), local = parent.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "native-final", format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Fixture", profile: "Fixture")
        let journal = NativeEnrollmentJournalStore(root: root, cloudRootID: UUID(), excludedLocalResetRoot: local), backend = Backend()
        let bridge = NativeEnrollmentPromotionBridge(journal: journal, backend: backend)
        let preparationID: UUID, targetHistory: DeviceManagementFormatHistory, targetEnrollment: NativeEnrollmentEvidence
        if firstNative {
            let prep = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: "native-stage", binding: binding, claimInput: input)
            preparationID = prep.preparationId; targetHistory = prep.targetHistory; targetEnrollment = prep.targetEnrollment
            try bridge.initializeFirstNative(prep, intentAttemptID: UUID())
            _ = try NativeEnrollmentStageBridge(journal: journal, backend: backend).stageFirstNativeOriginalExact(
                preparationID: prep.preparationId, stageAttemptID: UUID(), ownershipAttemptID: UUID())
            XCTAssertEqual(backend.items.count, 1) // Only actual original native48 stage; no fabricated legacy item.
        } else {
            let legacy = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "fixture-legacy", format: .legacyLocal32)
            let history = try DeviceManagementFormatHistory(transitions: [.init(transitionID: legacy.transitionID, phase: .locallyFenced)], credentials: [legacy])
            let prep = try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "native-stage", binding: binding,
                claimInput: input, history: history, enrollment: .init(), retained: [], inventory: .init(finalItems: ["fixture-legacy": .legacy32], stageItems: [:]))
            preparationID = prep.preparationId; targetHistory = prep.targetHistory; targetEnrollment = prep.targetEnrollment
            backend.items = [.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data("fixture-legacy".utf8), persistentReference: Data("fixture-legacy-reference".utf8), payload: Data(repeating: 3, count: 32))]
            _ = try journal.initializeExplicit(); _ = try journal.preparePromotionIntent(NativeEnrollmentPreparationCodec.encodeReconstructionProposal(prep), attemptID: UUID())
            _ = try NativeEnrollmentStageBridge(journal: journal, backend: backend).stageOriginalExact(preparationID: prep.preparationId, stageAttemptID: UUID(), ownershipAttemptID: UUID(), currentHistory: prep.sourceHistory, currentEnrollment: prep.sourceEnrollment)
        }
        let pair = NativeEnrollmentPairedEvidenceStore(journal: journal)
        _ = try pair.continueExact(pair.beginOriginal(preparationID: preparationID))
        let original = try bridge.beginOriginal(preparationID: preparationID, promotionAttemptID: UUID(), ownershipAttemptID: UUID(), currentHistory: targetHistory, currentEnrollment: targetEnrollment)
        let http = PromotionHTTPFixture(input: input)
        addTeardownBlock { http.close() }
        try await http.prepare(bridge, original)
        _ = try bridge.continueExact(original)
        let handle = try await http.activate(bridge, original)
        let namespace = parent.appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false)
        let roots = DeviceNativeManagedRootLocator.futureChildNames.map { namespace.appendingPathComponent($0) }
        for root in roots { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        let protected = DevicePackageProtectedScope(legacyStateRoot: local, legacyArchiveRoot: parent.appendingPathComponent("archive"), resetRoot: parent.appendingPathComponent("reset"), cloudRoot: root, managementRoot: parent.appendingPathComponent("management"), preferencesRoot: parent.appendingPathComponent("preferences"), otherProtectedRoots: [])
        let packages = DevicePackagePreparationStore(root: roots[0], rootID: UUID(), protectedScope: protected)
        let grants = DeviceGrantPreparationStore(root: roots[1], rootID: UUID(), protectedScope: protected, backend: UnusedGrantBackend())
        let structural = DeviceStructuralStore(root: roots[2], rootID: UUID())
        let provisioning = DeviceLocalProvisioningIntentStore(root: roots[3], rootID: UUID(), protectedRoots: protected.roots)
        let installation = try handle.bindManagedRoots(namespace: namespace, packages: packages, grants: grants, structural: structural, provisioning: provisioning)
        let activation = try http.activation()
        return (installation, activation, backend)
    }
    func testGenuineFirstNativePromotionCannotIssueStatusWithoutOriginalOwner() async throws {
        let (installation, activation, backend) = try await genuineStatusFixture(firstNative: true)
        XCTAssertNoThrow(try installation.requireDurableActivationAssociation(activation))
        let reads = backend.reads
        XCTAssertThrowsError(try installation.makeStatusRequest(origin: URL(string: "https://staging.example.test")!, activation: activation))
        XCTAssertEqual(backend.reads, reads)
    }
    func testFirstNativeCodecCannotBecomeOrdinaryManagementHistory() throws {
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "first-final", format: .nativeInstallationV1)
        let proposal = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: "first-stage", binding: binding,
            claimInput: .init(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "First", profile: "Actual"))
        let bytes = try NativeEnrollmentPreparationCodec.encodeFirstNativeProposal(proposal)
        let decoded = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(bytes)
        XCTAssertTrue(decoded.source.isFirstNative); XCTAssertTrue(decoded.sourceEnrollment.enrollments.isEmpty)
        XCTAssertThrowsError(try decoded.sourceHistory)
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceManagementFormatHistory.self, from: nativeEnrollmentBytes(decoded.source)))
        let sizes = try NativeJournalCodec.firstNativeLayoutReservationProof()
        XCTAssertLessThanOrEqual(sizes.intentBytes, NativeEnrollmentPreparationCodec.maximumBytes)
        XCTAssertLessThanOrEqual(sizes.frameBytes, 8192); XCTAssertLessThanOrEqual(sizes.attemptBytes, 32768)
    }
    func testPromotedCredentialCannotIssueStatusWithoutOriginalOwner() async throws {
        let (installation, activation, backend) = try await genuineStatusFixture()
        XCTAssertNoThrow(try installation.requireDurableActivationAssociation(activation))
        let reads = backend.reads
        XCTAssertThrowsError(try installation.makeStatusRequest(origin: URL(string: "https://staging.example.test")!, activation: activation))
        XCTAssertEqual(backend.reads, reads)
    }

}

/// Isolated fake HTTP executes the real fixed-request collector and private IO issuer.
/// No SDK, live network or Keychain. Dispatch callbacks run outside this registry lock.
final class PromotionHTTPFixture {
    struct Provider: CloudNativeTokenProvider { func idToken() async throws -> String { "synthetic-human-token" } }
    final class Interceptor: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var fixtures: [String: PromotionHTTPFixture] = [:]
        static func register(_ f: PromotionHTTPFixture) { lock.lock(); defer { lock.unlock() }; fixtures[f.origin.host!] = f }
        static func remove(_ f: PromotionHTTPFixture) { lock.lock(); defer { lock.unlock() }; fixtures.removeValue(forKey: f.origin.host!) }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let host = request.url?.host
            Self.lock.lock(); let fixture = host.flatMap { Self.fixtures[$0] }; Self.lock.unlock()
            do {
                guard let fixture else { throw NativeEnrollmentPromotionError.blocked }
                let data = try fixture.reply(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"] )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
    let origin = URL(string: "https://" + UUID().uuidString.lowercased() + ".fixture.test")!
    let input: NativeClaimInput, installationID = UUID(), challengeID = UUID(), generationID = UUID()
    let activationRequestID = UUID(), associationAttemptID = UUID()
    private let lock = NSLock()
    private(set) var claims = 0, activations = 0
    init(input: NativeClaimInput) { self.input = input; Interceptor.register(self) }
    func close() { Interceptor.remove(self) }
    var configuration: URLSessionConfiguration { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Interceptor.self]; return c }
    func prepare(_ bridge: NativeEnrollmentPromotionBridge, _ original: NativeEnrollmentPromotionBridge.Attempt) async throws {
        try await bridge.prepareOriginalActivation(original, origin: origin, tokenProvider: Provider(), activationRequestID: activationRequestID,
            associationAttemptID: associationAttemptID, configuration: configuration)
    }
    func activate(_ bridge: NativeEnrollmentPromotionBridge, _ original: NativeEnrollmentPromotionBridge.Attempt) async throws -> NativeEnrollmentPromotionBridge.OperationalHandle {
        try await bridge.activateOriginal(original, origin: origin, tokenProvider: Provider(), configuration: configuration)
    }
    func activation() throws -> NativeActivationReceipt {
        try .init(installationId: installationID, deviceId: installationID, requestId: activationRequestID,
            accountId: input.accountId, locationId: input.locationId, transitionId: input.transitionId, activatedAt: "2026-01-01T00:00:00Z",
            initialGeneration: .init(generationId: generationID, createdAt: "2026-01-01T00:00:00Z", renewAfter: "2026-01-31T00:00:00Z", expiresAt: "2026-04-01T00:00:00Z"))
    }
    private func reply(_ request: URLRequest) throws -> Data {
        guard request.httpMethod == "POST", request.httpShouldHandleCookies == false,
            request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-human-token",
            request.value(forHTTPHeaderField: "x-screenpunk-installation-credential")?.hasPrefix("spni1_") == true else { throw NativeEnrollmentPromotionError.blocked }
        let body: Data
        if let direct = request.httpBody { body = direct }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(), buffer = [UInt8](repeating: 0, count: 512)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw NativeEnrollmentPromotionError.blocked }
                if count == 0 { break }
                guard collected.count + count <= 4096 else { throw NativeEnrollmentPromotionError.blocked }
                collected.append(contentsOf: buffer.prefix(count))
            }
            body = collected
        } else { throw NativeEnrollmentPromotionError.blocked }
        if request.url?.path == "/v1/native/installations/claims" {
            guard body == (try nativeEnrollmentBytes(input)) else { throw NativeEnrollmentPromotionError.blocked }
            lock.lock(); claims += 1; lock.unlock()
            return try nativeEnrollmentBytes(NativeClaimReceipt(installationId: installationID, requestId: input.requestId, transitionId: input.transitionId,
                challengeId: challengeID, accountId: input.accountId, locationId: input.locationId,
                createdAt: "2026-01-01T00:00:00Z", expiresAt: "2026-01-01T00:10:00Z", outcome: .pending))
        }
        guard request.url?.path == "/v1/native/installations/activate",
            body == (try nativeEnrollmentBytes(NativeActivationInput(installationId: installationID, requestId: activationRequestID,
                challengeId: challengeID, transitionId: input.transitionId))) else { throw NativeEnrollmentPromotionError.blocked }
        lock.lock(); activations += 1; lock.unlock()
        return try nativeEnrollmentBytes(activation())
    }
}
