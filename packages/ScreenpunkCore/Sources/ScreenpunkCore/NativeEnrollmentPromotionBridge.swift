import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Exact existing physical directory validation, never caller-path rewriting.
/// Foundation can normalize /private/var to the /var symlink even after resolution.
/// This check is not a capability; original owner/descriptor checks remain mandatory.
enum NativeEnrollmentPhysicalDirectory {
    static func require(_ url: URL) throws {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
            !path.utf8.contains(0), !path.hasSuffix("/"), !path.contains("//"),
            path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
            let physical = realpath(path, nil) else { throw NativeEnrollmentPromotionError.blocked }
        defer { free(physical) }
        guard path.utf8.elementsEqual(String(cString: physical).utf8) else { throw NativeEnrollmentPromotionError.blocked }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw NativeEnrollmentPromotionError.blocked }
        defer { close(fd) }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard next >= 0 else { throw NativeEnrollmentPromotionError.blocked }
            close(fd); fd = next
        }
    }
}

// Unmounted original-only promotion. Genuine journal checkpoints bind every backend call.
// No production factory, durable-proof callback, secret getter or admission.
// enumerateRaw MUST return every dedicated-service item when count <= limit.
// Above limit, return exactly limit items as an overflow witness or throw;
// never silently truncate below limit. Include inaccessible/unknown items.
protocol NativeEnrollmentPromotionBackend: AnyObject {
    func enumerateRaw(limit: Int) throws -> [NativeEnrollmentRawCredentialItem]
    func readPersistentReference(_ reference: Data) throws -> NativeEnrollmentRawCredentialItem?
    func addFinalOnce(account: Data, raw48: Data) throws -> NativeEnrollmentPromotionAddResult
}
enum NativeEnrollmentPromotionAddResult { case added(Data), duplicate }
enum NativeEnrollmentPromotionError: Error, Equatable { case blocked, conflict, outcomeUncertain }
final class NativeEnrollmentPromotionBridge {
    private let journal: NativeEnrollmentJournalStore
    private let backend: any NativeEnrollmentPromotionBackend
    private let lock = NSLock()
    private var original: Attempt?
    private var reservation: UUID?
    private var firstInitialization: (bytes: Data, attemptID: UUID)?
    private var firstRootInitializationAttempted = false
    private var firstRootInitialized = false
    private func reserveBegin() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard reservation == nil, original == nil else { throw NativeEnrollmentPromotionError.conflict }
        let token = UUID(); reservation = token; return token
    }
    private func reserveDriver(_ a: Attempt) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard reservation == nil, original === a else { throw NativeEnrollmentPromotionError.conflict }
        let token = UUID(); reservation = token; return token
    }
    private func check(_ token: UUID, attempt: Attempt? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard reservation == token, attempt == nil || original === attempt else { throw NativeEnrollmentPromotionError.conflict }
    }
    private func release(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if reservation == token { reservation = nil }
    }
    private func publish(_ a: Attempt, token: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard reservation == token, original == nil else { throw NativeEnrollmentPromotionError.conflict }
        original = a
    }
    private func hasEnteredAdd(_ a: Attempt, token: UUID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard reservation == token, original === a else { throw NativeEnrollmentPromotionError.conflict }
        return a.enteredAdd
    }
    private func enterAdd(_ a: Attempt, token: UUID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard reservation == token, original === a else { throw NativeEnrollmentPromotionError.conflict }
        if a.enteredAdd { return false }; a.enteredAdd = true; return true
    }
    private func capture(_ ref: Data, attempt a: Attempt, token: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard reservation == token, original === a, a.reference == nil, (1...1024).contains(ref.count) else {
            throw NativeEnrollmentPromotionError.outcomeUncertain
        }
        a.reference = ref
    }
    private func reference(_ a: Attempt, token: UUID) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard reservation == token, original === a, let ref = a.reference else { throw NativeEnrollmentPromotionError.outcomeUncertain }
        return ref
    }
    init(journal: NativeEnrollmentJournalStore, backend: any NativeEnrollmentPromotionBackend) {
        self.journal = journal; self.backend = backend
    }
    final class Attempt: CustomReflectable {
        let checkpoint: NativeEnrollmentJournalStore.PromotionCheckpoint
        fileprivate let envelope: NativeEnrollmentStageEnvelope
        fileprivate let baseline: [NativeEnrollmentRawCredentialItem]
        fileprivate let ownershipID: UUID
        fileprivate var enteredAdd = false
        fileprivate var reference: Data?
        fileprivate var remoteActivationID: UUID?, associationAttemptID: UUID?
        fileprivate var claimObservation: NativeOriginalClaimObservation?
        fileprivate var activationObservation: NativeOriginalActivationObservation?
        fileprivate init(_ c: NativeEnrollmentJournalStore.PromotionCheckpoint,
                         _ e: NativeEnrollmentStageEnvelope, _ b: [NativeEnrollmentRawCredentialItem], _ id: UUID) {
            checkpoint = c; envelope = e; baseline = b; ownershipID = id
        }
        var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    }
    /// Explicit first-native source. Complete inventory is checked before any
    /// journal initialization and again against the original durable intent.
    func initializeFirstNative(_ proposal: NativeFirstEnrollmentPreparation, intentAttemptID: UUID) throws {
        _ = try NativeJournalCodec.firstNativeLayoutReservationProof()
        let bytes = try NativeEnrollmentPreparationCodec.encodeFirstNativeProposal(proposal)
        let token = try reserveBegin(); defer { release(token) }
        lock.lock()
        if let prior = firstInitialization {
            guard prior.bytes == bytes, prior.attemptID == intentAttemptID else { lock.unlock(); throw NativeEnrollmentPromotionError.conflict }
        } else { firstInitialization = (bytes, intentAttemptID) }
        lock.unlock()
        let before = try inventory(token: token)
        guard before.isEmpty else { throw NativeEnrollmentPromotionError.blocked }
        // No backend callback executes under journal or bridge locks.
        try check(token)
        lock.lock()
        let initialize = !firstRootInitializationAttempted
        if initialize { firstRootInitializationAttempted = true }
        let initialized = firstRootInitialized
        lock.unlock()
        if initialize {
            _ = try journal.initializeFirstNativeExplicit(); try check(token)
            lock.lock(); firstRootInitialized = true; lock.unlock()
        } else if !initialized { throw NativeEnrollmentPromotionError.outcomeUncertain }
        try check(token)
        _ = try journal.prepareFirstNativePromotionIntent(bytes, attemptID: intentAttemptID)
        try check(token)
        let checkpoint = try journal.captureStageIntent(preparationID: proposal.preparationId)
        guard checkpoint.step.proposal.source.isFirstNative, try inventory(token: token).isEmpty else { throw NativeEnrollmentPromotionError.blocked }
        try journal.verifyStageCheckpoint(checkpoint); try check(token)
    }
    func beginOriginal(preparationID: UUID, promotionAttemptID: UUID, ownershipAttemptID: UUID,
                       currentHistory: DeviceManagementFormatHistory, currentEnrollment: NativeEnrollmentEvidence) throws -> Attempt {
        let token = try reserveBegin(); defer { release(token) }
        let c = try journal.capturePromotionOriginal(preparationID: preparationID, promotionAttemptID: promotionAttemptID,
            ownershipAttemptID: ownershipAttemptID, currentHistory: currentHistory, currentEnrollment: currentEnrollment)
        try check(token)
        let items = try inventory(token: token); try Self.validateFreeFinalSlot(items)
        try journal.verifyPromotionOriginal(c); try check(token)
        guard let stage = try backend.readPersistentReference(c.stagePersistentReference) else { throw NativeEnrollmentPromotionError.blocked }
        try check(token)
        try journal.verifyPromotionOriginal(c); try check(token)
        guard stage.accessible, stage.persistentReference == c.stagePersistentReference,
              stage.service == Data(NativeEnrollmentStageEnvelope.service.utf8), stage.account == c.binding.stage,
              items.filter({ $0.persistentReference == stage.persistentReference }) == [stage],
              !items.contains(where: { $0.service == Data(NativeEnrollmentStageEnvelope.finalService.utf8) && $0.account == c.binding.final }) else {
            throw NativeEnrollmentPromotionError.blocked
        }
        try journal.verifyPromotionInventory(c, inventory: items); try check(token)
        let a = Attempt(c, try NativeEnrollmentStageEnvelope.qualify(stage.keychainPayload(), expected: c.binding), items, ownershipAttemptID)
        try publish(a, token: token); return a
    }
    private func retainActivationIDs(_ a: Attempt, driver: UUID, remote: UUID, association: UUID) throws -> NativeOriginalClaimObservation? {
        lock.lock(); defer { lock.unlock() }
        guard reservation == driver, original === a else { throw NativeEnrollmentPromotionError.conflict }
        if let prior = a.remoteActivationID {
            guard prior == remote, a.associationAttemptID == association else { throw NativeEnrollmentPromotionError.conflict }
        } else {
            guard remote != association, remote != a.envelope.binding.input.requestId, association != a.ownershipID else { throw NativeEnrollmentPromotionError.conflict }
            a.remoteActivationID = remote; a.associationAttemptID = association
        }
        return a.claimObservation
    }
    private func activationSnapshot(_ a: Attempt, driver: UUID) throws -> (NativeOriginalClaimObservation?, NativeOriginalActivationObservation?) {
        lock.lock(); defer { lock.unlock() }
        guard reservation == driver, original === a else { throw NativeEnrollmentPromotionError.conflict }
        return (a.claimObservation, a.activationObservation)
    }
    private func captureClaim(_ value: NativeOriginalClaimObservation, attempt a: Attempt, driver: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard reservation == driver, original === a, a.claimObservation == nil else { throw NativeEnrollmentPromotionError.conflict }
        a.claimObservation = value
    }
    private func captureActivation(_ value: NativeOriginalActivationObservation, attempt a: Attempt, driver: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard reservation == driver, original === a, a.activationObservation == nil else { throw NativeEnrollmentPromotionError.conflict }
        a.activationObservation = value
    }
    /// Explicit human operation; fixed request lineage, no public receipt-to-proof conversion.
    func prepareOriginalActivation(_ a: Attempt, origin: URL, tokenProvider: any CloudNativeTokenProvider,
        activationRequestID: UUID, associationAttemptID: UUID) async throws {
        try await prepareOriginalActivation(a, origin: origin, tokenProvider: tokenProvider,
            activationRequestID: activationRequestID, associationAttemptID: associationAttemptID, configuration: nil)
    }
    // Internal synthetic transport seam; production callers cannot supply URLProtocol/session configuration.
    func prepareOriginalActivation(_ a: Attempt, origin: URL, tokenProvider: any CloudNativeTokenProvider,
        activationRequestID: UUID, associationAttemptID: UUID, configuration: URLSessionConfiguration?) async throws {
        try Task.checkCancellation()
        let root = try NativeOperationalInstallation.validatedOrigin(origin)
        let driver = try reserveDriver(a); defer { release(driver) }
        let retained = try retainActivationIDs(a, driver: driver, remote: activationRequestID, association: associationAttemptID)
        if let retained {
            _ = try await tokenProvider.idToken(); try Task.checkCancellation(); try check(driver, attempt: a)
            try journal.commitPromotionActivationProposal(a.checkpoint, observation: retained); try check(driver, attempt: a); return
        }
        try journal.verifyPromotionOriginal(a.checkpoint); try check(driver, attempt: a)
        let material = try originalStageMaterial(a, driver: driver)
        let token = try await tokenProvider.idToken()
        try Task.checkCancellation(); try check(driver, attempt: a); try journal.verifyPromotionOriginal(a.checkpoint)
        let body = try nativeEnrollmentBytes(a.envelope.binding.input)
        let request = try Self.humanRequest(root: root, path: "/v1/native/installations/claims", body: body, token: token, raw48: material)
        let bytes = try await Self.fixedHumanTransport(request, root: root, configuration: configuration)
        try Task.checkCancellation(); try check(driver, attempt: a)
        // A scoped SDK provider must still belong to the same human after HTTP returns.
        _ = try await tokenProvider.idToken()
        try Task.checkCancellation(); try check(driver, attempt: a); try journal.verifyPromotionOriginal(a.checkpoint)
        let claim = try Self.pendingClaim(bytes)
        let proposal = try NativeJournalActivationProposal(claim: claim, input: .init(installationId: claim.installationId,
            requestId: activationRequestID, challengeId: claim.challengeId, transitionId: claim.transitionId))
        guard proposal.matches(a.envelope.binding) else { throw NativeEnrollmentPromotionError.blocked }
        let observation = NativeOriginalClaimObservation(original: a.checkpoint, proposal: proposal, associationAttemptID: associationAttemptID)
        try captureClaim(observation, attempt: a, driver: driver)
        try journal.commitPromotionActivationProposal(a.checkpoint, observation: observation); try check(driver, attempt: a)
    }
    /// Requires phase4 durable proposal and phase5 exact raw ownership. Lost receipt save repairs locally.
    func activateOriginal(_ a: Attempt, origin: URL, tokenProvider: any CloudNativeTokenProvider) async throws -> OperationalHandle {
        try await activateOriginal(a, origin: origin, tokenProvider: tokenProvider, configuration: nil)
    }
    func activateOriginal(_ a: Attempt, origin: URL, tokenProvider: any CloudNativeTokenProvider,
        configuration: URLSessionConfiguration?) async throws -> OperationalHandle {
        try Task.checkCancellation()
        let root = try NativeOperationalInstallation.validatedOrigin(origin)
        let driver = try reserveDriver(a); defer { release(driver) }
        let (claim, retained) = try activationSnapshot(a, driver: driver)
        guard let claim else { throw NativeEnrollmentPromotionError.blocked }
        let ref = try reference(a, token: driver)
        let observation: NativeOriginalActivationObservation
        if let retained {
            _ = try await tokenProvider.idToken(); try Task.checkCancellation(); try check(driver, attempt: a)
            observation = retained
        } else {
            _ = try journal.qualifyOriginalFinalOwnership(a.checkpoint, finalPersistentReference: ref, ownershipAttemptID: a.ownershipID)
            let material = try originalStageMaterial(a, driver: driver)
            let token = try await tokenProvider.idToken()
            try Task.checkCancellation(); try check(driver, attempt: a)
            _ = try journal.qualifyOriginalFinalOwnership(a.checkpoint, finalPersistentReference: ref, ownershipAttemptID: a.ownershipID)
            let body = try nativeEnrollmentBytes(claim.proposal.activationInput.value)
            let request = try Self.humanRequest(root: root, path: "/v1/native/installations/activate", body: body, token: token, raw48: material)
            let bytes = try await Self.fixedHumanTransport(request, root: root, configuration: configuration)
            try Task.checkCancellation(); try check(driver, attempt: a)
            _ = try await tokenProvider.idToken()
            try Task.checkCancellation(); try check(driver, attempt: a)
            _ = try journal.qualifyOriginalFinalOwnership(a.checkpoint, finalPersistentReference: ref, ownershipAttemptID: a.ownershipID)
            let receipt = try Self.activationReceipt(bytes)
            _ = try NativeJournalActivationAssociation(proposal: claim.proposal, receipt: receipt, finalOwnershipAttemptID: a.ownershipID)
            observation = NativeOriginalActivationObservation(original: a.checkpoint, receipt: receipt)
            try captureActivation(observation, attempt: a, driver: driver)
        }
        try Task.checkCancellation(); try check(driver, attempt: a)
        try journal.commitOriginalActivationAssociation(a.checkpoint, observation: observation); try check(driver, attempt: a)
        let proof = try journal.qualifyOriginalFinalOwnership(a.checkpoint, finalPersistentReference: ref, ownershipAttemptID: a.ownershipID)
        try journal.qualifyOriginalActivationAssociation(a.checkpoint, activation: observation.receipt)
        return OperationalHandle(journal, backend, proof, original: a.checkpoint, finalReference: ref, ownershipID: a.ownershipID)
    }
    private func originalStageMaterial(_ a: Attempt, driver: UUID) throws -> Data {
        try journal.verifyPromotionOriginalOrOwnFinalOwnership(a.checkpoint); try check(driver, attempt: a)
        guard let stage = try backend.readPersistentReference(a.checkpoint.stagePersistentReference) else { throw NativeEnrollmentPromotionError.blocked }
        try check(driver, attempt: a); try journal.verifyPromotionOriginalOrOwnFinalOwnership(a.checkpoint)
        guard stage.accessible, stage.persistentReference == a.checkpoint.stagePersistentReference,
            stage.service == Data(NativeEnrollmentStageEnvelope.service.utf8), stage.account == a.envelope.binding.stage else { throw NativeEnrollmentPromotionError.blocked }
        let current = try NativeEnrollmentStageEnvelope.qualify(stage.keychainPayload(), expected: a.envelope.binding)
        guard current.keychainPayload() == a.envelope.keychainPayload() else { throw NativeEnrollmentPromotionError.blocked }
        return Data(current.keychainPayload().suffix(48))
    }
    private static func humanRequest(root: URL, path: String, body: Data, token: String, raw48: Data) throws -> URLRequest {
        guard raw48.count == 48, body.count <= 4096, !token.isEmpty, token.utf8.count <= 16384,
            token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw NativeEnrollmentPromotionError.blocked }
        var request = URLRequest(url: root.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let material = raw48.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        request.setValue("spni1_" + material, forHTTPHeaderField: "x-screenpunk-installation-credential")
        return request
    }
    private static func fixedHumanTransport(_ request: URLRequest, root: URL, configuration: URLSessionConfiguration?) async throws -> Data {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let driver = NativeOperationalStatusRequest.Driver(origin: root, path: request.url!.path, byteLimit: 4096)
        let session = URLSession(configuration: config, delegate: driver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler { try await driver.run(request, session: session) } onCancel: { driver.cancel() }
    }
    private static func pendingClaim(_ bytes: Data) throws -> NativeClaimReceipt {
        let root = try StructuralStoreCodec.object(bytes, limit: 16384)
        let wrapped = try JSONSerialization.data(withJSONObject: ["kind": "claim", "claim": root], options: [.sortedKeys])
        guard case .claim(let claim) = try NativeInstallationStatusCodec.decode(wrapped), claim.outcome == .pending else { throw NativeEnrollmentPromotionError.blocked }
        return claim
    }
    private static func activationReceipt(_ bytes: Data) throws -> NativeActivationReceipt {
        let activation = try StructuralStoreCodec.object(bytes, limit: 16384)
        guard let generation = activation["initialGeneration"] else { throw NativeEnrollmentPromotionError.blocked }
        var wrapped: [String: Any] = ["kind": "current-generation", "activation": activation, "generation": generation, "credential": "current", "authority": "active"]
        for key in ["installationId", "accountId", "locationId", "transitionId"] { wrapped[key] = activation[key] }
        let encoded = try JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys])
        guard case .currentGeneration(let current) = try NativeInstallationStatusCodec.decode(encoded) else { throw NativeEnrollmentPromotionError.blocked }
        return current.activation
    }
    func continueExact(_ a: Attempt) throws -> OperationalHandle {
        let token = try reserveDriver(a); defer { release(token) }
        // Capacity/baseline preflight is read-only BEFORE even phase4 effects.
        let firstAdd = try !hasEnteredAdd(a, token: token)
        if firstAdd {
            let before = try inventory(token: token, attempt: a)
            try Self.validateFreeFinalSlot(before)
            try journal.verifyPromotionOriginal(a.checkpoint); try check(token, attempt: a)
            guard same(before, a.baseline) else { throw NativeEnrollmentPromotionError.blocked }
        }
        // Exact phase4 acknowledgment MUST precede final add; no fresh checkpoint.
        try journal.commitPromotionAttempt(a.checkpoint); try check(token, attempt: a)
        try journal.verifyPromotionOriginalOrOwnFinalOwnership(a.checkpoint); try check(token, attempt: a)
        // Recheck after phase4, before marking add entered. A no-add preflight
        // failure remains retryable using this same exact original.
        if firstAdd {
            let nowBeforeAdd = try inventory(token: token, attempt: a)
            try Self.validateFreeFinalSlot(nowBeforeAdd)
            try journal.verifyPromotionOriginal(a.checkpoint); try check(token, attempt: a)
            guard same(nowBeforeAdd, a.baseline) else { throw NativeEnrollmentPromotionError.blocked }
            guard try enterAdd(a, token: token) else { throw NativeEnrollmentPromotionError.conflict }
            let result = try backend.addFinalOnce(account: a.envelope.binding.final,
                raw48: Data(a.envelope.keychainPayload().suffix(48)))
            try check(token, attempt: a)
            switch result {
            case .duplicate: throw NativeEnrollmentPromotionError.outcomeUncertain
            case .added(let ref):
                try capture(ref, attempt: a, token: token)
            }
            try journal.verifyPromotionOriginal(a.checkpoint); try check(token, attempt: a)
        }
        let ref = try reference(a, token: token)
        let item = try qualifyFinal(a, ref, token: token)
        try journal.commitOriginalFinalOwnership(a.checkpoint, finalPersistentReference: ref, ownershipAttemptID: a.ownershipID)
        try check(token, attempt: a)
        guard try qualifyFinal(a, ref, token: token) == item else { throw NativeEnrollmentPromotionError.blocked }
        let proof = try journal.qualifyOriginalFinalOwnership(a.checkpoint, finalPersistentReference: ref, ownershipAttemptID: a.ownershipID)
        try check(token, attempt: a)
        return OperationalHandle(journal, backend, proof, original: a.checkpoint, finalReference: ref, ownershipID: a.ownershipID)
    }
    private func qualifyFinal(_ a: Attempt, _ ref: Data, token: UUID) throws -> NativeEnrollmentRawCredentialItem {
        guard let item = try backend.readPersistentReference(ref) else { throw NativeEnrollmentPromotionError.blocked }
        try check(token, attempt: a)
        try journal.verifyPromotionOriginalOrOwnFinalOwnership(a.checkpoint); try check(token, attempt: a)
        guard item.accessible, item.persistentReference == ref, item.service == Data(NativeEnrollmentStageEnvelope.finalService.utf8),
              item.account == a.envelope.binding.final, item.keychainPayload().count == 48,
              a.envelope.exactMaterial(item.keychainPayload()) else { throw NativeEnrollmentPromotionError.blocked }
        let now = try inventory(token: token, attempt: a)
        try journal.verifyPromotionOriginalOrOwnFinalOwnership(a.checkpoint); try check(token, attempt: a)
        guard same(now, a.baseline + [item]) else { throw NativeEnrollmentPromotionError.blocked }; return item
    }
    private func inventory(token: UUID, attempt: Attempt? = nil) throws -> [NativeEnrollmentRawCredentialItem] {
        let items = try backend.enumerateRaw(limit: 193)
        try check(token, attempt: attempt); try Self.validateInventory(items); return items
    }
    static func validateFreeFinalSlot(_ items: [NativeEnrollmentRawCredentialItem]) throws {
        try validateInventory(items)
        guard items.filter({ $0.service == Data(NativeEnrollmentStageEnvelope.finalService.utf8) }).count < 128 else {
            throw NativeEnrollmentPromotionError.blocked
        }
    }
    static func validateInventory(_ items: [NativeEnrollmentRawCredentialItem]) throws {
        let s = Data(NativeEnrollmentStageEnvelope.service.utf8), f = Data(NativeEnrollmentStageEnvelope.finalService.utf8)
        guard items.count <= 192, items.filter({ $0.service == s }).count <= 64, items.filter({ $0.service == f }).count <= 128,
              Set(items.map(\.persistentReference)).count == items.count else { throw NativeEnrollmentPromotionError.blocked }
        for i in items {
            guard i.accessible, (1...1024).contains(i.persistentReference.count), i.service == s || i.service == f,
                  items.filter({ $0.service == i.service && $0.account == i.account }).count == 1 else { throw NativeEnrollmentPromotionError.blocked }
            _ = try NativeEnrollmentStageBinding.reference(i.account)
        }
    }
    private func same(_ a: [NativeEnrollmentRawCredentialItem], _ b: [NativeEnrollmentRawCredentialItem]) -> Bool {
        a.count == b.count && a.allSatisfy { i in b.filter { $0.persistentReference == i.persistentReference } == [i] }
    }
    final class OperationalHandle: CustomReflectable {
        fileprivate let journal: NativeEnrollmentJournalStore
        private let backend: any NativeEnrollmentPromotionBackend
        private let proof: NativeEnrollmentJournalStore.FinalOwnershipQualification
        fileprivate let original: NativeEnrollmentJournalStore.PromotionCheckpoint
        private let finalReference: Data, ownershipID: UUID
        fileprivate init(_ j: NativeEnrollmentJournalStore, _ b: any NativeEnrollmentPromotionBackend,
                         _ p: NativeEnrollmentJournalStore.FinalOwnershipQualification, original: NativeEnrollmentJournalStore.PromotionCheckpoint,
                         finalReference: Data, ownershipID: UUID) {
            journal = j; backend = b; proof = p; self.original = original; self.finalReference = finalReference; self.ownershipID = ownershipID
        }
        fileprivate func verifiedMaterial() throws -> Data {
            _ = try journal.qualifyOriginalFinalOwnership(original, finalPersistentReference: finalReference, ownershipAttemptID: ownershipID)
            // Backend callbacks run outside every journal lock.
            guard let item = try backend.readPersistentReference(finalReference), item.accessible,
                item.persistentReference == finalReference, item.service == Data(NativeEnrollmentStageEnvelope.finalService.utf8),
                item.account == original.binding.final, item.keychainPayload().count == 48 else { throw NativeEnrollmentPromotionError.blocked }
            guard let stage = try backend.readPersistentReference(original.stagePersistentReference), stage.accessible,
                stage.persistentReference == original.stagePersistentReference, stage.service == Data(NativeEnrollmentStageEnvelope.service.utf8),
                stage.account == original.binding.stage else { throw NativeEnrollmentPromotionError.blocked }
            let envelope = try NativeEnrollmentStageEnvelope.qualify(stage.keychainPayload(), expected: original.binding)
            guard envelope.exactMaterial(item.keychainPayload()) else { throw NativeEnrollmentPromotionError.blocked }
            _ = try journal.qualifyOriginalFinalOwnership(original, finalPersistentReference: finalReference, ownershipAttemptID: ownershipID)
            return item.keychainPayload()
        }
        func bindManagedRoots(namespace: URL, packages: DevicePackagePreparationStore, grants: DeviceGrantPreparationStore,
            structural: DeviceStructuralStore, provisioning: DeviceLocalProvisioningIntentStore) throws -> NativeOperationalInstallation {
            try NativeEnrollmentPhysicalDirectory.require(namespace)
            let descriptors = try [packages.resourceGateDescriptor, grants.resourceGateDescriptor, structural.resourceGateDescriptor, provisioning.resourceGateDescriptor]
            let names = DeviceNativeManagedRootLocator.futureChildNames
            guard namespace.lastPathComponent == DeviceNativeManagedRootLocator.namespaceName,
                Set(descriptors.map(\.rootID)).count == 4,
                zip(descriptors, names).allSatisfy({ $0.0.path.utf8.elementsEqual(namespace.appendingPathComponent($0.1).path.utf8) }) else { throw NativeEnrollmentPromotionError.blocked }
            let inspector = try DeviceManagedNamespaceInspector.fixture(existingPhysicalAnchor: namespace.deletingLastPathComponent())
            let evidence = try inspector.inspect()
            guard evidence.classification == .managedPresent else { throw NativeEnrollmentPromotionError.blocked }
            _ = try verifiedMaterial()
            let gate = DeviceLocalResourceGate(packageStore: packages, grantStore: grants, structuralStore: structural)
            guard try inspector.inspect() == evidence else { throw NativeEnrollmentPromotionError.blocked }
            return NativeOperationalInstallation(self, inspector: inspector, evidence: evidence, gate: gate, provisioning: provisioning)
        }
        func bindNativeManagedRoots(namespace: URL, stores: NativeFirstManagedStores) throws -> NativeOperationalInstallation {
            try NativeEnrollmentPhysicalDirectory.require(namespace)
            let descriptors = try [stores.packages.resourceGateDescriptor, stores.grants.resourceGateDescriptor,
                stores.structural.resourceGateDescriptor, stores.provisioning.resourceGateDescriptor]
            guard stores.genesis != nil, namespace.lastPathComponent == DeviceNativeManagedRootLocator.namespaceName,
                Set(descriptors.map(\.rootID)).count == 4,
                zip(descriptors, DeviceNativeManagedRootLocator.futureChildNames).allSatisfy({ $0.0.path.utf8.elementsEqual(namespace.appendingPathComponent($0.1).path.utf8) }) else { throw NativeEnrollmentPromotionError.blocked }
            let inspector = try DeviceManagedNamespaceInspector.fixture(existingPhysicalAnchor: namespace.deletingLastPathComponent())
            let evidence = try inspector.inspect()
            guard evidence.classification == .managedPresent else { throw NativeEnrollmentPromotionError.blocked }
            _ = try verifiedMaterial()
            guard try inspector.inspect() == evidence else { throw NativeEnrollmentPromotionError.blocked }
            return NativeOperationalInstallation(self, inspector: inspector, evidence: evidence, gate: nil,
                provisioning: stores.provisioning, nativeStores: stores)
        }
        var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
        // The only credential consumer is the fixed request constructor below.
    }
}

/// Opaque original promotion + configured actual store topology. No public initializer.
@_spi(NativeInstallation) public final class NativeOperationalInstallation: @unchecked Sendable, CustomReflectable {
    fileprivate let handle: NativeEnrollmentPromotionBridge.OperationalHandle
    fileprivate var originalEnrollmentOwner: (any NativeFirstEnrollmentOwner)?
    private let inspector: DeviceManagedNamespaceInspector
    private let evidence: DeviceManagedNamespaceEvidence
    private let gate: DeviceLocalResourceGate?
    private let provisioning: DeviceLocalProvisioningIntentStore
    private let nativeStores: NativeFirstManagedStores?
    fileprivate init(_ handle: NativeEnrollmentPromotionBridge.OperationalHandle, inspector: DeviceManagedNamespaceInspector,
        evidence: DeviceManagedNamespaceEvidence, gate: DeviceLocalResourceGate?, provisioning: DeviceLocalProvisioningIntentStore, nativeStores: NativeFirstManagedStores? = nil) {
        self.handle = handle; self.inspector = inspector; self.evidence = evidence; self.gate = gate; self.provisioning = provisioning; self.nativeStores = nativeStores
    }
    /// Internal mechanics binding only; current dispatch and durable delivery
    /// authorization are separately required by the execution consumer.
    func deliveryExecutionStoreBinding() throws -> NativeDeliveryExecutionStoreBinding {
        guard let stores = nativeStores, let genesis = stores.genesis else { throw NativeEnrollmentPromotionError.blocked }
        let activation = try handle.journal.acceptedOriginalActivation(handle.original)
        try requireDurableActivationAssociation(activation)
        guard try inspector.inspect() == evidence else { throw NativeEnrollmentPromotionError.blocked }
        return .init(packages: stores.packages, grants: stores.grants, structural: stores.structural,
            journal: stores.provisioning, genesis: genesis)
    }
    public func makeDeliveryExecutionSession(current: NativeCurrentInstallationDispatch) throws -> NativeDeliveryExecutionSession {
        try current.validateInstallationExact(installation: self)
        let activation = try handle.journal.acceptedOriginalActivation(handle.original)
        let session = try NativeDeliveryExecutionSession.make(stores: deliveryExecutionStoreBinding(), installation: self, activation: activation)
        try current.validateInstallationExact(installation: self); return session
    }
    public func makeCurrentDispatch(observation: NativeOperationalStatusObservation, owner: any NativeCurrentInstallationOwner) throws -> NativeCurrentInstallationDispatch {
        guard let originalEnrollmentOwner else { throw NativeEnrollmentPromotionError.blocked }
        try originalEnrollmentOwner.validateCurrentDispatchOwner(owner)
        try observation.requireFresh(for: self)
        _ = try deliveryExecutionStoreBinding()
        try owner.validateCurrentInstallationDispatch(installation: self)
        let activation = try handle.journal.acceptedOriginalActivation(handle.original)
        try requireDurableActivationAssociation(activation)
        try originalEnrollmentOwner.validateCurrentDispatchOwner(owner)
        return NativeCurrentInstallationDispatch(installation: self, observation: observation, owner: owner, activation: activation)
    }
    fileprivate func validateDeliveryAssociation(_ association: DeviceNativeDeliveryCommandBinding.Association) throws {
        let activation = try handle.journal.acceptedOriginalActivation(handle.original)
        try requireDurableActivationAssociation(activation)
        guard association.installationID == activation.installationId, association.accountID == activation.accountId,
            association.locationID == activation.locationId, association.transitionID == activation.transitionId,
            try inspector.inspect() == evidence else { throw NativeEnrollmentPromotionError.blocked }
    }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    public func verifyManagedNamespace(_ ownerEvidence: DeviceManagedNamespaceEvidence) throws {
        guard ownerEvidence == evidence, try inspector.inspect() == evidence else { throw NativeEnrollmentPromotionError.blocked }
    }
    public func requireDurableActivationAssociation(_ activation: NativeActivationReceipt) throws {
        try handle.journal.qualifyOriginalActivationAssociation(handle.original, activation: activation)
        _ = try handle.verifiedMaterial()
    }
    public func validateActivation(_ activation: NativeActivationReceipt) throws {
        let binding = handle.original.binding
        guard activation.accountId == binding.input.accountId, activation.locationId == binding.input.locationId,
            activation.transitionId == binding.binding.transitionID else { throw NativeEnrollmentPromotionError.blocked }
    }
    public func makeStatusRequest(origin: URL, activation: NativeActivationReceipt) throws -> NativeOperationalStatusRequest {
        let root = try Self.validatedOrigin(origin)
        guard let owner = originalEnrollmentOwner else { throw NativeEnrollmentPromotionError.blocked }
        try owner.validateOperationalOrigin(root)
        try validateActivation(activation); try requireDurableActivationAssociation(activation)
        guard try inspector.inspect() == evidence else { throw NativeEnrollmentPromotionError.blocked }
        let material = try handle.verifiedMaterial()
        guard try inspector.inspect() == evidence else { throw NativeEnrollmentPromotionError.blocked }
        var request = URLRequest(url: root.appendingPathComponent("v1/native/installations/status"))
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        let bearer = material.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        request.setValue("Bearer spni1_" + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try owner.validateOperationalOrigin(root)
        return NativeOperationalStatusRequest(request, installation: self, activation: activation)
    }
    public static func validatedOrigin(_ origin: URL) throws -> URL {
        guard let c = URLComponents(url: origin, resolvingAgainstBaseURL: false), c.scheme == "https", let host = c.host, !host.isEmpty,
            c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.percentEncodedPath.isEmpty || c.percentEncodedPath == "/",
            c.port == nil || (1...65535).contains(c.port!) else { throw NativeEnrollmentPromotionError.blocked }
        return origin
    }
}

/// One fixed request. No header/credential getter, serializer or arbitrary route.
enum NativeOperationalTransportFailure: Error, Equatable { case invalidResponse, responseTooLarge, redirected, transport }
@_spi(NativeInstallation) public final class NativeOperationalStatusRequest: @unchecked Sendable, CustomReflectable {
    private let request: URLRequest
    private let installation: NativeOperationalInstallation
    private let activation: NativeActivationReceipt
    public let requestID = UUID()
    fileprivate init(_ request: URLRequest, installation: NativeOperationalInstallation, activation: NativeActivationReceipt) {
        self.request = request; self.installation = installation; self.activation = activation
    }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    public func requireOrigin(_ origin: URL) throws {
        let origin = try NativeOperationalInstallation.validatedOrigin(origin)
        guard let owner = installation.originalEnrollmentOwner else { throw NativeEnrollmentPromotionError.blocked }
        try owner.validateOperationalOrigin(origin)
        guard let url = request.url, url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port else { throw NativeEnrollmentPromotionError.blocked }
    }
    func makeDataTask(in session: URLSession) -> URLSessionDataTask { session.dataTask(with: request) }
    public func performFixedTransport(origin: URL) async throws -> NativeOperationalStatusObservation {
        try Task.checkCancellation(); try requireOrigin(origin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return try await performFixedTransport(origin: origin, configuration: configuration)
    }
    // Module-internal synthetic URLProtocol seam only; never a public IO-proof constructor.
    func performFixedTransport(origin: URL, configuration: URLSessionConfiguration) async throws -> NativeOperationalStatusObservation {
        try Task.checkCancellation(); try requireOrigin(origin)
        try installation.requireDurableActivationAssociation(activation)
        let driver = Driver(origin: origin)
        let session = URLSession(configuration: configuration, delegate: driver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let startedAt = ProcessInfo.processInfo.systemUptime // Original request start, never response arrival.
        let bytes = try await withTaskCancellationHandler {
            try await driver.run(self, session: session)
        } onCancel: { driver.cancel() }
        try Task.checkCancellation(); try requireOrigin(origin)
        try installation.requireDurableActivationAssociation(activation)
        return try decodeCurrentStatus(bytes, startedAt: startedAt)
    }
    /// Owned per-request collector; cancellation before continuation installation is retained.
    final class Driver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let origin: URL
        private let path: String
        private let byteLimit: Int
        private let mimeType: String
        private var receivedAssociationHeader: String?
        private var continuation: CheckedContinuation<Data, Error>?
        private var task: URLSessionDataTask?
        private var bytes = Data()
        private var finished = false, cancelled = false, responseAccepted = false
        init(origin: URL, path: String = "/v1/native/installations/status", byteLimit: Int = 16384, mimeType: String = "application/json") { self.origin = origin; self.path = path; self.byteLimit = byteLimit; self.mimeType = mimeType }
        func planAssociationHeader() -> String? { lock.lock(); defer { lock.unlock() }; return receivedAssociationHeader }
        func run(_ request: NativeOperationalStatusRequest, session: URLSession) async throws -> Data {
            try await run(request.request, session: session)
        }
        func run(_ request: URLRequest, session: URLSession) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished, !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let task = session.dataTask(with: request); self.task = task
                lock.unlock(); task.resume()
            }
        }
        func cancel() {
            lock.lock(); cancelled = true; let task = task; lock.unlock()
            task?.cancel(); finish(.failure(CancellationError()))
        }
        private func finish(_ result: Result<Data, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; let continuation = continuation; self.continuation = nil; let task = task; self.task = nil
            lock.unlock(); task?.cancel(); continuation?.resume(with: result)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil); finish(.failure(NativeOperationalTransportFailure.redirected))
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                let url = http.url, url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
                url.path == path, url.query == nil, url.fragment == nil,
                response.expectedContentLength <= byteLimit, response.mimeType == mimeType else {
                completionHandler(.cancel); finish(.failure(NativeOperationalTransportFailure.invalidResponse)); return
            }
            var association: String?
            if mimeType == "application/octet-stream" {
                guard let raw = http.value(forHTTPHeaderField: "X-Screenpunk-Plan-Association"), raw.utf8.prefix(1367).count <= 1366 else {
                    completionHandler(.cancel); finish(.failure(NativeOperationalTransportFailure.invalidResponse)); return
                }
                association = raw
            }
            lock.lock(); receivedAssociationHeader = association; responseAccepted = !finished && !cancelled; let allowed = responseAccepted; lock.unlock()
            completionHandler(allowed ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do { try append(data) } catch { finish(.failure(error)) }
        }
        func append(_ data: Data) throws {
            lock.lock(); defer { lock.unlock() }
            guard !finished, !cancelled else { throw CancellationError() }
            guard data.count <= byteLimit - bytes.count else { throw NativeOperationalTransportFailure.responseTooLarge }
            bytes.append(data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); let accepted = responseAccepted, bytes = bytes, cancelled = cancelled; lock.unlock()
            if cancelled { finish(.failure(CancellationError())) }
            else if error != nil { finish(.failure(NativeOperationalTransportFailure.transport)) }
            else if !accepted { finish(.failure(NativeOperationalTransportFailure.invalidResponse)) }
            else { finish(.success(bytes)) }
        }
    }
    fileprivate func decodeCurrentStatus(_ bytes: Data, startedAt: TimeInterval) throws -> NativeOperationalStatusObservation {
        guard case .currentGeneration(let current) = try NativeInstallationStatusCodec.decode(bytes),
            current.credential == .current, current.authority == .active,
            current.installationId == activation.installationId, current.accountId == activation.accountId,
            current.locationId == activation.locationId, current.transitionId == activation.transitionId,
            try nativeEnrollmentBytes(current.activation) == nativeEnrollmentBytes(activation),
            try nativeEnrollmentBytes(current.generation) == nativeEnrollmentBytes(activation.initialGeneration) else { throw NativeEnrollmentPromotionError.blocked }
        return .init(requestID: requestID, installation: installation, startedAt: startedAt)
    }
}
@_spi(NativeInstallation) public final class NativeOperationalStatusObservation: @unchecked Sendable {
    public let requestID: UUID
    private static let currentProcess = UUID()
    private let installation: NativeOperationalInstallation
    private let startedAt: TimeInterval, issuedProcess: UUID
    fileprivate init(requestID: UUID, installation: NativeOperationalInstallation, startedAt: TimeInterval) {
        self.requestID = requestID; self.installation = installation; self.startedAt = startedAt; issuedProcess = Self.currentProcess
    }
    fileprivate func requireFresh(for installation: NativeOperationalInstallation) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard self.installation === installation, issuedProcess == Self.currentProcess, startedAt.isFinite, now.isFinite,
            startedAt >= 0, now >= startedAt, now - startedAt <= 30 else { throw NativeEnrollmentPromotionError.blocked }
    }
    fileprivate func remainingPresentationTime(for installation: NativeOperationalInstallation) throws -> TimeInterval {
        try requireFresh(for: installation)
        return max(0, 30 - (ProcessInfo.processInfo.systemUptime - startedAt))
    }
    public func belongs(to expected: NativeOperationalInstallation) -> Bool { installation === expected }
}

final class NativeOriginalClaimObservation {
    private let original: NativeEnrollmentJournalStore.PromotionCheckpoint
    let proposal: NativeJournalActivationProposal, associationAttemptID: UUID
    fileprivate init(original: NativeEnrollmentJournalStore.PromotionCheckpoint, proposal: NativeJournalActivationProposal, associationAttemptID: UUID) {
        self.original = original; self.proposal = proposal; self.associationAttemptID = associationAttemptID
    }
    func belongs(to checkpoint: NativeEnrollmentJournalStore.PromotionCheckpoint) -> Bool { original === checkpoint }
}
final class NativeOriginalActivationObservation {
    private let original: NativeEnrollmentJournalStore.PromotionCheckpoint
    let receipt: NativeActivationReceipt
    fileprivate init(original: NativeEnrollmentJournalStore.PromotionCheckpoint, receipt: NativeActivationReceipt) { self.original = original; self.receipt = receipt }
    func belongs(to checkpoint: NativeEnrollmentJournalStore.PromotionCheckpoint) -> Bool { original === checkpoint }
}

// Platform storage SPI supplies raw observations only. There is no public raw
// getter, checkpoint constructor, or observation-to-authority conversion.
@_spi(NativeInstallation) public struct NativeEnrollmentStoredCredential: CustomStringConvertible, CustomReflectable {
    fileprivate let raw: NativeEnrollmentRawCredentialItem
    public init(service: Data, account: Data, persistentReference: Data, payload: Data, accessible: Bool) {
        raw = .init(service: service, account: account, persistentReference: persistentReference, payload: payload, accessible: accessible)
    }
    public var description: String { "NativeEnrollmentStoredCredential(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [] as [(label: String?, value: Any)]) }
}
@_spi(NativeInstallation) public enum NativeEnrollmentCredentialInsert { case inserted(Data), duplicate }
@_spi(NativeInstallation) public protocol NativeEnrollmentCredentialStorage: AnyObject {
    func enumerateBounded(maximum: Int) throws -> [NativeEnrollmentStoredCredential]
    func generateOriginal48() throws -> Data
    func readExactPersistentReference(_ reference: Data) throws -> NativeEnrollmentStoredCredential?
    func insertStageOnly(account: Data, envelope: Data) throws -> NativeEnrollmentCredentialInsert
    func insertFinalOnly(account: Data, original48: Data) throws -> NativeEnrollmentCredentialInsert
}
private final class NativeEnrollmentStorageAdapter: NativeEnrollmentStageBackend, NativeEnrollmentPromotionBackend {
    let storage: any NativeEnrollmentCredentialStorage
    let owner: any NativeFirstEnrollmentOwner
    init(_ storage: any NativeEnrollmentCredentialStorage, owner: any NativeFirstEnrollmentOwner) { self.storage = storage; self.owner = owner }
    private func observed<T>(_ operation: () throws -> T) throws -> T {
        try owner.validateFixedEnrollmentStep(); let value = try operation(); try owner.validateFixedEnrollmentStep(); return value
    }
    func enumerateRaw(limit: Int) throws -> [NativeEnrollmentRawCredentialItem] {
        let observed = try self.observed { try storage.enumerateBounded(maximum: limit) }
        guard observed.count <= limit else { throw NativeEnrollmentPromotionError.blocked }
        return observed.map(\.raw)
    }
    func generate48() throws -> Data { try observed { try storage.generateOriginal48() } }
    func readPersistentReference(_ reference: Data) throws -> NativeEnrollmentRawCredentialItem? {
        if (try? owner.validateFixedEnrollmentStep()) != nil {
            return try observed { try storage.readExactPersistentReference(reference)?.raw }
        }
        try owner.beginOperationalCredentialRead()
        do {
            let value = try storage.readExactPersistentReference(reference)?.raw
            try owner.finishOperationalCredentialRead(); return value
        } catch { try? owner.finishOperationalCredentialRead(); throw error }
    }
    func addStageOnce(account: Data, payload: Data) throws -> NativeEnrollmentStageAddResult {
        switch try observed({ try storage.insertStageOnly(account: account, envelope: payload) }) {
        case .inserted(let reference): return .added(reference); case .duplicate: return .duplicate
        }
    }
    func addFinalOnce(account: Data, raw48: Data) throws -> NativeEnrollmentPromotionAddResult {
        switch try observed({ try storage.insertFinalOnly(account: account, original48: raw48) }) {
        case .inserted(let reference): return .added(reference); case .duplicate: return .duplicate
        }
    }
}

/// Mandatory platform owner for the original fixed enrollment. Implementations
/// reserve synchronously without keeping a lock across backend callbacks/awaits.
@_spi(NativeInstallation) public protocol NativeFirstEnrollmentOwner: AnyObject, Sendable {
    func beginFixedEnrollmentStep() throws
    func finishFixedEnrollmentStep() throws
    func validateFixedEnrollmentStep() throws
    func qualifyOperationalReads(installation: NativeOperationalInstallation, activation: NativeActivationReceipt) throws
    func validateCurrentDispatchOwner(_ candidate: any NativeCurrentInstallationOwner) throws
    func validateOperationalContext() throws
    func validateOperationalOrigin(_ origin: URL) throws
    func beginOperationalCredentialRead() throws
    func finishOperationalCredentialRead() throws
}
private struct NativeFirstOwnerTokens: CloudNativeTokenProvider {
    let provider: any CloudNativeTokenProvider
    let owner: any NativeFirstEnrollmentOwner
    func idToken() async throws -> String {
        try Task.checkCancellation(); try owner.validateFixedEnrollmentStep()
        let token = try await provider.idToken()
        try Task.checkCancellation(); try owner.validateFixedEnrollmentStep(); return token
    }
}
/// A live original first-enrollment operation, not a restart importer or admission lease.
/// All roots/IDs are explicit; the platform's SAME authority owns their initialization.
@_spi(NativeInstallation) public final class NativeFirstEnrollmentSession {
    private let proposal: NativeFirstEnrollmentPreparation
    private let namespace: URL
    private let owner: any NativeFirstEnrollmentOwner
    private var intentComplete = false
    private let journal: NativeEnrollmentJournalStore
    private let stage: NativeEnrollmentStageBridge
    private let pair: NativeEnrollmentPairedEvidenceStore
    private let promotion: NativeEnrollmentPromotionBridge
    private let stageID = UUID(), stageOwnershipID = UUID(), promotionID = UUID(), finalOwnershipID = UUID()
    private let intentID = UUID()
    private let driverLock = NSLock()
    private var driving = false
    private var pairOriginal: NativeEnrollmentPairedEvidenceStore.Attempt?
    private var promotionOriginal: NativeEnrollmentPromotionBridge.Attempt?
    private var stageComplete = false
    private var pairComplete = false
    public static func validateFirstNativeLayout(_ proposal: NativeFirstEnrollmentPreparation) throws {
        _ = try NativeJournalCodec.firstNativeLayoutReservationProof()
        let bytes = try NativeEnrollmentPreparationCodec.encodeFirstNativeProposal(proposal)
        _ = try NativeJournalCodec.reservation(intentBytes: bytes.count)
    }
    public init(namespace: URL, journalRoot: URL, cloudRootID: UUID, excludedLocalResetRoot: URL,
        proposal: NativeFirstEnrollmentPreparation, storage: any NativeEnrollmentCredentialStorage, owner: any NativeFirstEnrollmentOwner) throws {
        try Self.validateFirstNativeLayout(proposal)
        try NativeEnrollmentPhysicalDirectory.require(namespace)
        try NativeEnrollmentPhysicalDirectory.require(journalRoot)
        guard namespace.lastPathComponent == DeviceNativeManagedRootLocator.namespaceName,
            journalRoot.path == namespace.appendingPathComponent("enrollment").path else { throw NativeEnrollmentPromotionError.blocked }
        let inspector = try DeviceManagedNamespaceInspector.fixture(existingPhysicalAnchor: namespace.deletingLastPathComponent())
        guard try inspector.inspect().classification == .managedPresent else { throw NativeEnrollmentPromotionError.blocked }
        let adapter = NativeEnrollmentStorageAdapter(storage, owner: owner)
        self.namespace = namespace; self.proposal = proposal; self.owner = owner
        journal = .init(root: journalRoot, cloudRootID: cloudRootID, excludedLocalResetRoot: excludedLocalResetRoot)
        stage = .init(journal: journal, backend: adapter); pair = .init(journal: journal)
        promotion = .init(journal: journal, backend: adapter)
    }
    private func fixedStep<T>(_ operation: () throws -> T) throws -> T {
        try owner.beginFixedEnrollmentStep()
        do { let result = try operation(); try owner.finishFixedEnrollmentStep(); return result }
        catch { try? owner.finishFixedEnrollmentStep(); throw error }
    }
    private func fixedNetworkStep<T>(_ operation: () async throws -> T) async throws -> T {
        try owner.beginFixedEnrollmentStep()
        do { let result = try await operation(); try Task.checkCancellation(); try owner.finishFixedEnrollmentStep(); return result }
        catch { try? owner.finishFixedEnrollmentStep(); throw error }
    }
    private func beginDriver() throws {
        driverLock.lock(); defer { driverLock.unlock() }
        guard !driving else { throw NativeEnrollmentPromotionError.conflict }; driving = true
    }
    private func endDriver() { driverLock.lock(); driving = false; driverLock.unlock() }
    /// Only explicit user invocation. Failed IO retains this exact operation/IDs.
    /// The returned association remains inert until current foreground status qualifies it.
    public func enroll(origin: URL, tokenProvider: any CloudNativeTokenProvider, activationRequestID: UUID,
        associationAttemptID: UUID, stores: NativeFirstManagedStores) async throws -> NativeOperationalEnrollmentResult {
        try await enroll(origin: origin, tokenProvider: tokenProvider, activationRequestID: activationRequestID,
            associationAttemptID: associationAttemptID, stores: stores, configuration: nil)
    }
    // Internal synthetic transport seam; public production entry has no custom session/configuration.
    func enroll(origin: URL, tokenProvider: any CloudNativeTokenProvider, activationRequestID: UUID,
        associationAttemptID: UUID, stores: NativeFirstManagedStores, configuration: URLSessionConfiguration?) async throws -> NativeOperationalEnrollmentResult {
        try beginDriver(); defer { endDriver() }
        let tokens = NativeFirstOwnerTokens(provider: tokenProvider, owner: owner)
        try Task.checkCancellation()
        try fixedStep { try stores.initializeRootsExact() }
        if !intentComplete {
            try fixedStep { try promotion.initializeFirstNative(proposal, intentAttemptID: intentID) }; intentComplete = true
        }
        if !stageComplete {
            _ = try fixedStep { try stage.stageFirstNativeOriginalExact(preparationID: proposal.preparationId, stageAttemptID: stageID, ownershipAttemptID: stageOwnershipID) }
            stageComplete = true
        }
        try Task.checkCancellation()
        if !pairComplete {
            if pairOriginal == nil { pairOriginal = try fixedStep { try pair.beginOriginal(preparationID: proposal.preparationId) } }
            guard let original = pairOriginal else { throw NativeEnrollmentPromotionError.blocked }
            _ = try fixedStep { try pair.continueExact(original) }; pairComplete = true
        }
        if promotionOriginal == nil {
            promotionOriginal = try fixedStep { try promotion.beginOriginal(preparationID: proposal.preparationId, promotionAttemptID: promotionID,
                ownershipAttemptID: finalOwnershipID, currentHistory: proposal.targetHistory, currentEnrollment: proposal.targetEnrollment) }
        }
        guard let original = promotionOriginal else { throw NativeEnrollmentPromotionError.blocked }
        try Task.checkCancellation()
        try await fixedNetworkStep { try await promotion.prepareOriginalActivation(original, origin: origin, tokenProvider: tokens,
            activationRequestID: activationRequestID, associationAttemptID: associationAttemptID, configuration: configuration) }
        try Task.checkCancellation()
        _ = try fixedStep { try promotion.continueExact(original) }
        let handle = try await fixedNetworkStep { try await promotion.activateOriginal(original, origin: origin, tokenProvider: tokens, configuration: configuration) }
        try Task.checkCancellation()
        let activation = try fixedStep { try journal.acceptedOriginalActivation(original.checkpoint) }
        try fixedStep { try stores.initializeGenuineEmptyContent(activation: activation) }
        let installation = try fixedStep { try handle.bindNativeManagedRoots(namespace: namespace, stores: stores) }
        installation.originalEnrollmentOwner = owner
        try fixedStep { try owner.qualifyOperationalReads(installation: installation, activation: activation) }
        return NativeOperationalEnrollmentResult(installation: installation, activation: activation, stores: stores)
    }
}
@_spi(NativeInstallation) public struct NativeOperationalEnrollmentResult {
    public let installation: NativeOperationalInstallation
    public let activation: NativeActivationReceipt
    fileprivate let stores: NativeFirstManagedStores
    fileprivate init(installation: NativeOperationalInstallation, activation: NativeActivationReceipt, stores: NativeFirstManagedStores) {
        self.installation = installation; self.activation = activation; self.stores = stores
    }
}

/// Explicit local store identities; none is a server installation/generation ID.
@_spi(NativeInstallation) public struct NativeManagedLocalRootIDs: Sendable {
    public let package: UUID, grant: UUID, structural: UUID, provisioning: UUID, contentGenesis: UUID
    public init(package: UUID, grant: UUID, structural: UUID, provisioning: UUID, contentGenesis: UUID) throws {
        guard Set([package, grant, structural, provisioning, contentGenesis]).count == 5 else { throw NativeEnrollmentPromotionError.conflict }
        self.package = package; self.grant = grant; self.structural = structural; self.provisioning = provisioning; self.contentGenesis = contentGenesis
    }
}
@_spi(NativeInstallation) public struct NativeManagedProtectedRoots: Sendable {
    public let legacyState: URL, legacyArchive: URL, reset: URL, cloudEnrollment: URL, management: URL, preferences: URL
    public init(legacyState: URL, legacyArchive: URL, reset: URL, cloudEnrollment: URL, management: URL, preferences: URL) {
        self.legacyState = legacyState; self.legacyArchive = legacyArchive; self.reset = reset
        self.cloudEnrollment = cloudEnrollment; self.management = management; self.preferences = preferences
    }
}
/// Actual stores behind one opaque topology. Construction is explicit and creates
/// no directories; SAME platform authority must first create/qualify those nodes.
@_spi(NativeInstallation) public final class NativeFirstManagedStores {
    fileprivate let packages: DevicePackagePreparationStore, grants: DeviceNativeGrantPreparationStore
    fileprivate let structural: DeviceStructuralStore, provisioning: DeviceLocalProvisioningIntentStore
    private let contentGeneration: UUID
    fileprivate var genesis: DeviceStructuralStore.NativeGenesisCheckpoint?
    private var genesisActivation: Data?
    public init(namespace: URL, ids: NativeManagedLocalRootIDs, protectedRoots: NativeManagedProtectedRoots,
        grantTransport: any DeviceGrantCredentialTransport) throws {
        try NativeEnrollmentPhysicalDirectory.require(namespace)
        guard namespace.lastPathComponent == DeviceNativeManagedRootLocator.namespaceName else { throw NativeEnrollmentPromotionError.blocked }
        let roots = DeviceNativeManagedRootLocator.futureChildNames.map { namespace.appendingPathComponent($0) }
        let scope = DevicePackageProtectedScope(legacyStateRoot: protectedRoots.legacyState, legacyArchiveRoot: protectedRoots.legacyArchive,
            resetRoot: protectedRoots.reset, cloudRoot: protectedRoots.cloudEnrollment, managementRoot: protectedRoots.management,
            preferencesRoot: protectedRoots.preferences, otherProtectedRoots: [])
        packages = .init(root: roots[0], rootID: ids.package, protectedScope: scope)
        grants = .init(root: roots[1], rootID: ids.grant, protectedPaths: scope.roots,
            backend: try DeviceGrantCredentialTransportBackend(rootID: ids.grant, transport: grantTransport))
        structural = .init(root: roots[2], rootID: ids.structural)
        provisioning = .init(root: roots[3], rootID: ids.provisioning, protectedRoots: scope.roots)
        contentGeneration = ids.contentGenesis
    }
    fileprivate func initializeRootsExact() throws {
        try packages.initializeExplicit(); try grants.initializeExplicit()
        try structural.initializeExplicit(); try provisioning.initializeExplicit()
    }
    fileprivate func initializeGenuineEmptyContent(activation: NativeActivationReceipt) throws {
        let bytes = try nativeEnrollmentBytes(activation)
        if let prior = genesisActivation { guard prior == bytes else { throw NativeEnrollmentPromotionError.conflict } }
        else { genesisActivation = bytes } // Retain the ORIGINAL operation before persistence.
        let owner = DeviceNativeInstallationContentOwner(installationID: activation.installationId, accountID: activation.accountId,
            locationID: activation.locationId, transitionID: activation.transitionId)
        let state = try DeviceNativeStructuralState.validating(generationID: contentGeneration, owner: .nativeInstallation(owner), entries: [], configuredEntryID: nil)
        genesis = try structural.initializeNativeGenesisExplicit(state)
    }
}

/// Authenticated fixed-route IO provenance, distinct from parsed authorization bytes.
/// Only the fixed collector below can construct this observation.
@_spi(NativeInstallation) public final class NativeDeliveryActivationHTTPObservation: @unchecked Sendable, CustomReflectable {
    private let body: NativeDeliveryDurableBody
    private let installation: NativeOperationalInstallation
    private let response: Data
    private init(body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation, response: Data) {
        self.body = body; self.installation = installation; self.response = response
    }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    func validatedResponse(for body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation) throws -> Data {
        guard installation === self.installation, self.body.matchesOriginalBody(body) else { throw NativeEnrollmentPromotionError.blocked }
        try body.requireOriginalInstallation(installation)
        return response
    }
    public static func collect(body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation,
        current: NativeCurrentInstallationDispatch, origin: URL) async throws -> NativeDeliveryActivationHTTPObservation {
        try await collect(body: body, installation: installation, current: current, origin: origin, configuration: nil)
    }
    // Synthetic transport seam is module-internal only. Production cannot supply a session/protocol.
    static func collect(body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation,
        current: NativeCurrentInstallationDispatch, origin: URL, configuration: URLSessionConfiguration?) async throws -> NativeDeliveryActivationHTTPObservation {
        try Task.checkCancellation()
        _ = try body.requireActivationOriginal(installation: installation)
        let root = try NativeOperationalInstallation.validatedOrigin(origin)
        guard let originalOwner = installation.originalEnrollmentOwner else { throw NativeEnrollmentPromotionError.blocked }
        try originalOwner.validateOperationalOrigin(root)
        try current.validateInstallationExact(installation: installation)
        let material = try installation.handle.verifiedMaterial()
        try current.validateInstallationExact(installation: installation)
        try originalOwner.validateOperationalOrigin(root)
        var request = URLRequest(url: root.appendingPathComponent("v1/native/installations/delivery/activation"))
        request.httpMethod = "POST"; request.httpBody = body.bytes; request.httpShouldHandleCookies = false
        let bearer = material.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        request.setValue("Bearer spni1_" + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let driver = NativeOperationalStatusRequest.Driver(origin: root, path: request.url!.path, byteLimit: 4096)
        let session = URLSession(configuration: config, delegate: driver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let bytes = try await withTaskCancellationHandler { try await driver.run(request, session: session) } onCancel: { driver.cancel() }
        try Task.checkCancellation()
        guard bytes.count <= 4096 else { throw NativeOperationalTransportFailure.responseTooLarge }
        _ = try body.requireActivationOriginal(installation: installation)
        try current.validateInstallationExact(installation: installation)
        try originalOwner.validateOperationalOrigin(root)
        return .init(body: body, installation: installation, response: bytes)
    }
}

/// Authenticated fixed-route IO provenance, distinct from parsed authorization bytes.
/// Only the fixed collector below can construct this observation.
@_spi(NativeInstallation) public final class NativeDeliveryReceiptHTTPObservation: @unchecked Sendable, CustomReflectable {
    private let body: NativeDeliveryDurableBody
    private let installation: NativeOperationalInstallation
    private let response: Data
    private init(body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation, response: Data) {
        self.body = body; self.installation = installation; self.response = response
    }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    func validatedResponse(for body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation) throws -> Data {
        guard installation === self.installation, self.body.matchesOriginalBody(body) else { throw NativeEnrollmentPromotionError.blocked }
        try body.requireOriginalInstallation(installation)
        return response
    }
    public static func collect(body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation,
        origin: URL) async throws -> NativeDeliveryReceiptHTTPObservation {
        try await collect(body: body, installation: installation, origin: origin, configuration: nil)
    }
    // Synthetic transport seam is module-internal only. Production cannot supply a session/protocol.
    static func collect(body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation,
        origin: URL, configuration: URLSessionConfiguration?) async throws -> NativeDeliveryReceiptHTTPObservation {
        try Task.checkCancellation()
        _ = try body.requireOutcomeOriginal(installation: installation)
        guard let owner = installation.originalEnrollmentOwner else { throw NativeEnrollmentPromotionError.blocked }
        try owner.validateOperationalContext()
        let root = try NativeOperationalInstallation.validatedOrigin(origin)
        guard let originalOwner = installation.originalEnrollmentOwner else { throw NativeEnrollmentPromotionError.blocked }
        try originalOwner.validateOperationalOrigin(root)
        let material = try installation.handle.verifiedMaterial()
        try owner.validateOperationalContext()
        try originalOwner.validateOperationalOrigin(root)
        var request = URLRequest(url: root.appendingPathComponent("v1/native/installations/delivery/receipt"))
        request.httpMethod = "POST"; request.httpBody = body.bytes; request.httpShouldHandleCookies = false
        let bearer = material.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        request.setValue("Bearer spni1_" + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let driver = NativeOperationalStatusRequest.Driver(origin: root, path: request.url!.path, byteLimit: 16384)
        let session = URLSession(configuration: config, delegate: driver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let bytes = try await withTaskCancellationHandler { try await driver.run(request, session: session) } onCancel: { driver.cancel() }
        try Task.checkCancellation()
        guard bytes.count <= 16384 else { throw NativeOperationalTransportFailure.responseTooLarge }
        _ = try body.requireOutcomeOriginal(installation: installation)
        try owner.validateOperationalContext()
        try originalOwner.validateOperationalOrigin(root)
        return .init(body: body, installation: installation, response: bytes)
    }
}

@_spi(NativeInstallation) public protocol NativeCurrentInstallationOwner: AnyObject, Sendable {
    func validateCurrentInstallationDispatch(installation: NativeOperationalInstallation) throws
    func performFixedStructuralDispatch(current: NativeCurrentInstallationDispatch, command: NativeInstallationStructuralDispatchCommand) throws -> NativeInstallationStructuralDispatchResult
}
/// Current same-process permission only. It does not authenticate delivery
/// activationRequestID/authorizationDigest; the retained authorization owner does.
@_spi(NativeInstallation) public final class NativeCurrentInstallationDispatch: @unchecked Sendable {
    private let installation: NativeOperationalInstallation
    private let owner: any NativeCurrentInstallationOwner
    private let observation: NativeOperationalStatusObservation
    private let activation: NativeActivationReceipt
    fileprivate init(installation: NativeOperationalInstallation, observation: NativeOperationalStatusObservation, owner: any NativeCurrentInstallationOwner, activation: NativeActivationReceipt) {
        self.installation = installation; self.owner = owner; self.observation = observation; self.activation = activation
    }
    public func requirePresentationCurrent() throws { try validateInstallationExact(installation: installation) }
    public func waitForPresentationExpiry() async throws {
        let remaining = try observation.remainingPresentationTime(for: installation)
        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
    func performFixedStructuralDispatch(_ command: NativeInstallationStructuralDispatchCommand) throws -> NativeInstallationStructuralDispatchResult {
        try validateInstallationExact(installation: installation)
        try command.beginFixedInvocation(current: self)
        defer { command.endFixedInvocation() }
        return try owner.performFixedStructuralDispatch(current: self, command: command)
    }
    // Called only inside the nominal fixed command; owner admission is already held.
    func validateFixedCommandEvidence(installation: NativeOperationalInstallation,
        association: DeviceNativeDeliveryCommandBinding.Association) throws {
        guard installation === self.installation else { throw NativeEnrollmentPromotionError.blocked }
        try observation.requireFresh(for: installation)
        // Exact association was qualified before admission. This inner check is pure:
        // no journal/backend read and no recursive operational-owner validation.
        guard association.installationID == activation.installationId,
            association.accountID == activation.accountId, association.locationID == activation.locationId,
            association.transitionID == activation.transitionId else { throw NativeEnrollmentPromotionError.blocked }
        try observation.requireFresh(for: installation)
    }
    func validateInstallationExact(installation: NativeOperationalInstallation) throws {
        guard installation === self.installation else { throw NativeEnrollmentPromotionError.blocked }
        try observation.requireFresh(for: installation)
        try owner.validateCurrentInstallationDispatch(installation: installation)
        _ = try installation.deliveryExecutionStoreBinding()
        try observation.requireFresh(for: installation)
        try owner.validateCurrentInstallationDispatch(installation: installation)
    }
    func validateDeliveryDispatchExact(installation: NativeOperationalInstallation,
        association: DeviceNativeDeliveryCommandBinding.Association,
        activationRequestID: UUID, authorizationDigest: String) throws {
        guard installation === self.installation, authorizationDigest.utf8.count == 64,
            authorizationDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw NativeEnrollmentPromotionError.blocked }
        try observation.requireFresh(for: installation)
        try owner.validateCurrentInstallationDispatch(installation: installation)
        try installation.validateDeliveryAssociation(association)
        try observation.requireFresh(for: installation)
        try owner.validateCurrentInstallationDispatch(installation: installation)
        // The caller must separately verify exact persisted authorization against
        // activationRequestID before invoking this live-permission check.
        _ = activationRequestID
    }
}


/// Fixed original-context requests only. No URL, bearer or caller-response proof escape.
private enum NativeFixedDeliveryCollector {
    static func run(installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch,
        origin: URL, path: String, method: String = "GET", body: Data? = nil,
        limit: Int, mime: String = "application/json", timeout: TimeInterval = 30,
        configuration: URLSessionConfiguration? = nil) async throws -> (Data, String?) {
        try Task.checkCancellation()
        guard let owner = installation.originalEnrollmentOwner else { throw NativeEnrollmentPromotionError.blocked }
        let root = try NativeOperationalInstallation.validatedOrigin(origin)
        try owner.validateOperationalOrigin(root)
        try current.validateInstallationExact(installation: installation)
        let material = try installation.handle.verifiedMaterial()
        try owner.validateOperationalOrigin(root)
        try current.validateInstallationExact(installation: installation)
        var request = URLRequest(url: root.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        let bearer = material.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        request.setValue("Bearer spni1_" + bearer, forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let driver = NativeOperationalStatusRequest.Driver(origin: root, path: request.url!.path, byteLimit: limit, mimeType: mime)
        let session = URLSession(configuration: config, delegate: driver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let start = ProcessInfo.processInfo.systemUptime
        let bytes = try await withTaskCancellationHandler { try await driver.run(request, session: session) } onCancel: { driver.cancel() }
        try Task.checkCancellation()
        let end = ProcessInfo.processInfo.systemUptime
        guard end >= start, end - start <= timeout else { throw NativeOperationalTransportFailure.transport }
        try owner.validateOperationalOrigin(root)
        try current.validateInstallationExact(installation: installation)
        return (bytes, driver.planAssociationHeader())
    }
}

@_spi(NativeInstallation) public final class NativeDeliveryStateHTTPObservation: @unchecked Sendable {
    private let installation: NativeOperationalInstallation, body: NativeDeliveryDurableBody
    private init(installation: NativeOperationalInstallation, body: NativeDeliveryDurableBody) { self.installation = installation; self.body = body }
    public static func collect(body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation,
        current: NativeCurrentInstallationDispatch, origin: URL) async throws -> NativeDeliveryStateHTTPObservation {
        try await collect(body: body, installation: installation, current: current, origin: origin, configuration: nil)
    }
    static func collect(body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation,
        current: NativeCurrentInstallationDispatch, origin: URL, configuration: URLSessionConfiguration?) async throws -> NativeDeliveryStateHTTPObservation {
        try body.requireStateOriginal(installation: installation)
        guard body.bytes.count <= 16384 else { throw NativeDeliveryExecutionError.bounds }
        let (bytes, _) = try await NativeFixedDeliveryCollector.run(installation: installation, current: current, origin: origin,
            path: "v1/native/installations/delivery/state", method: "POST", body: body.bytes, limit: 16384, configuration: configuration)
        typealias C = DeviceNativeDeliveryAttachmentCodec
        let ack = try C.object(bytes, limit: 16384, keys: ["installationId", "transitionId", "generationId", "accepted"])
        let original = try C.object(body.bytes, limit: 16384, keys: ["schemaVersion", "installationId", "transitionId", "generationId", "entries", "configuredEntryId"])
        guard let accepted = ack["accepted"] as? NSNumber, CFGetTypeID(accepted) == CFBooleanGetTypeID(), accepted.boolValue,
            try C.uuid(ack["installationId"]) == C.uuid(original["installationId"]),
            try C.uuid(ack["transitionId"]) == C.uuid(original["transitionId"]),
            try C.uuid(ack["generationId"]) == C.uuid(original["generationId"]) else { throw NativeDeliveryExecutionError.association }
        return .init(installation: installation, body: body)
    }
    public func requireOriginal(body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation) throws {
        guard self.installation === installation, self.body.matchesOriginalBody(body) else { throw NativeDeliveryExecutionError.association }
    }
}

@_spi(NativeInstallation) public final class NativeDeliveryCommandHTTPObservation: @unchecked Sendable {
    private let installation: NativeOperationalInstallation
    private let command: Data?
    public let nextCheckSeconds: Int
    private init(installation: NativeOperationalInstallation, command: Data?, next: Int) {
        self.installation = installation; self.command = command; nextCheckSeconds = next
    }
    public var hasCommand: Bool { command != nil }
    public static func collect(installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch,
        origin: URL) async throws -> NativeDeliveryCommandHTTPObservation {
        try await collect(installation: installation, current: current, origin: origin, configuration: nil)
    }
    static func collect(installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch,
        origin: URL, configuration: URLSessionConfiguration?) async throws -> NativeDeliveryCommandHTTPObservation {
        let (bytes, _) = try await NativeFixedDeliveryCollector.run(installation: installation, current: current, origin: origin,
            path: "v1/native/installations/delivery/command", limit: 17 * 1024, configuration: configuration)
        let poll = try DeviceNativeDeliveryHTTPCodec.commandPoll(bytes)
        return .init(installation: installation, command: poll.commandBytes, next: poll.nextCheckSeconds)
    }
    public func fetchPlan(current: NativeCurrentInstallationDispatch, origin: URL,
        nativeOperationID: UUID) async throws -> NativeDeliveryPlanHTTPObservation {
        try await fetchPlan(current: current, origin: origin, nativeOperationID: nativeOperationID, configuration: nil)
    }
    func fetchPlan(current: NativeCurrentInstallationDispatch, origin: URL,
        nativeOperationID: UUID, configuration: URLSessionConfiguration?) async throws -> NativeDeliveryPlanHTTPObservation {
        guard let command else { throw NativeDeliveryExecutionError.phase }
        typealias C = DeviceNativeDeliveryAttachmentCodec
        let fields: Set<String> = ["schemaVersion", "operationId", "planId", "planDigest", "planByteLength", "installationId", "accountId", "locationId", "transitionId", "sequence", "expectedInstalledSetGenerationId", "desiredSetGenerationId", "resultingSet", "resultingSetDigest", "executionExpiresAt"]
        let object = try C.object(command, limit: 16384, keys: fields)
        let planID = try C.uuid(object["planId"])
        let (bytes, header) = try await NativeFixedDeliveryCollector.run(installation: installation, current: current, origin: origin,
            path: "v1/native/installations/delivery/plan/" + planID.uuidString.lowercased(), limit: 65536, mime: "application/octet-stream", configuration: configuration)
        guard let header else { throw NativeDeliveryExecutionError.association }
        let stores = try installation.deliveryExecutionStoreBinding()
        let binding = try DeviceNativeDeliveryCommandBinding.bind(command: command, associationHeader: header, rawPlan: bytes,
            nativeOperationID: nativeOperationID, journalRootID: stores.journal.rootID)
        try installation.validateDeliveryAssociation(binding.association)
        try current.validateInstallationExact(installation: installation)
        return .init(installation: installation, binding: binding, header: header)
    }
}

@_spi(NativeInstallation) public final class NativeDeliveryPlanHTTPObservation: @unchecked Sendable {
    private let installation: NativeOperationalInstallation
    private let binding: DeviceNativeDeliveryCommandBinding
    private let header: String
    private let preparationIDs: [UUID: UUID]
    fileprivate init(installation: NativeOperationalInstallation, binding: DeviceNativeDeliveryCommandBinding, header: String) {
        self.installation = installation; self.binding = binding; self.header = header
        preparationIDs = Dictionary(uniqueKeysWithValues: binding.resultingSet.entries.map { ($0.entryID, UUID()) })
    }
    public func fetchArchives(current: NativeCurrentInstallationDispatch, origin: URL,
        target: DeviceProfile, profileID: String, revisionName: String) async throws -> NativeDeliveryArchiveHTTPObservation {
        try await fetchArchives(current: current, origin: origin, target: target, profileID: profileID, revisionName: revisionName, configuration: nil)
    }
    func fetchArchives(current: NativeCurrentInstallationDispatch, origin: URL,
        target: DeviceProfile, profileID: String, revisionName: String, configuration: URLSessionConfiguration?) async throws -> NativeDeliveryArchiveHTTPObservation {
        var archives: [NativeDeliveryArchiveInput] = []
        for entry in binding.resultingSet.entries {
            guard case .cloud(let descriptor) = entry.provenance, let preparationID = preparationIDs[entry.entryID] else { throw NativeDeliveryExecutionError.association }
            let path = "v1/native/installations/delivery/package/" + binding.association.operationID.uuidString.lowercased() + "/" + descriptor.packageID.uuidString.lowercased()
            let (bytes, _) = try await NativeFixedDeliveryCollector.run(installation: installation, current: current, origin: origin,
                path: path, limit: 25 * 1024 * 1024, mime: "application/zip", timeout: 10, configuration: configuration)
            guard UInt64(bytes.count) == descriptor.compressedBytes,
                try DeviceNativeDeliveryAttachmentCodec.hash(bytes) == descriptor.archiveSHA256.text else { throw NativeDeliveryExecutionError.association }
            archives.append(.init(entryID: entry.entryID, preparationOperationID: preparationID, archiveBytes: bytes,
                profileID: profileID, revisionName: revisionName, target: target))
        }
        return .init(plan: self, archives: archives)
    }
    fileprivate func prepare(session: NativeDeliveryExecutionSession, archives: [NativeDeliveryArchiveInput],
        grantOperationID: UUID, grantRevisionID: UUID) throws {
        try session.prepareStaticFirstDelivery(command: binding.commandBytes, associationHeader: header, rawPlan: binding.planBytes,
            nativeOperationID: binding.nativeOperationID, grantOperationID: grantOperationID, grantRevisionID: grantRevisionID, archives: archives)
    }
}
@_spi(NativeInstallation) public final class NativeDeliveryArchiveHTTPObservation: @unchecked Sendable {
    private let plan: NativeDeliveryPlanHTTPObservation
    private let archives: [NativeDeliveryArchiveInput]
    fileprivate init(plan: NativeDeliveryPlanHTTPObservation, archives: [NativeDeliveryArchiveInput]) { self.plan = plan; self.archives = archives }
    public func prepare(session: NativeDeliveryExecutionSession, grantOperationID: UUID, grantRevisionID: UUID) throws {
        // Actual archive qualification occurs inside this fixed native pipeline, never HTTP proof alone.
        try plan.prepare(session: session, archives: archives, grantOperationID: grantOperationID, grantRevisionID: grantRevisionID)
    }
}
