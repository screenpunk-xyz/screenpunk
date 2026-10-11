import XCTest
import Foundation
import CryptoKit
@_spi(NativeInstallation) @_spi(ManagedRender) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple

@MainActor final class DeviceOwnedFactoryResetAcceptanceTests: XCTestCase {
    func testNativeOfflineFlagOffResetThenFreshEnrollmentAndSecondReset() async throws {
        let fixture = try await FactoryResetFixture.make(common: false, qualified: false)
        defer { fixture.close() }
        let oldInstallation = fixture.installationID
        let oldCalendar = fixture.provider.calendar, oldPreferences = fixture.provider.preferences
        try fixture.authority.leaveCloudForeground(); fixture.http.close()
        let networkBefore = fixture.http.requestCount
        let first = try fixture.prepare()
        let firstReceipt = try await first.execute()
        XCTAssertEqual(fixture.storage.itemCount, 0, "The original synthetic credential values must actually be erased")
        XCTAssertGreaterThanOrEqual(fixture.baseSnapshots, 2, "The explicit synthetic-vault snapshot replaces production Security reads")
        XCTAssertTrue(oldCalendar.suspension.suspended)
        XCTAssertFalse(oldPreferences.isCurrentWriter)
        XCTAssertThrowsError(try oldPreferences.generation(), "The old preference handle cannot access the fresh writer generation")
        XCTAssertEqual(fixture.http.requestCount, networkBefore, "Physical reset never refreshes Cloud authority")
        try firstReceipt.validateCompletion()
        XCTAssertThrowsError(try fixture.authority.completedFactoryResetIdentity(resetID: UUID(), scopeDigest: first.scopeDigest))
        XCTAssertThrowsError(try fixture.authority.completedFactoryResetIdentity(resetID: first.resetID, scopeDigest: String(repeating: "0", count: 64)))
        try firstReceipt.consumeHandoff()
        XCTAssertThrowsError(try firstReceipt.validateCompletion(), "Handoff receipt is one-use")
        let nextAuthority = try fixture.newAuthority(qualified: false)
        XCTAssertNil(try nextAuthority.recoverFactoryReset(provider: fixture.provider, ownedCredentials: fixture.storage))
        let second = try await FactoryResetFixture.enroll(parent: fixture.parent, base: fixture.base,
            storage: fixture.storage, authority: nextAuthority, common: false)
        defer { second.http.close() }
        XCTAssertNotEqual(second.installationID, oldInstallation)
        let nextProvider = fixture.provider
        let secondPreparation = try nextAuthority.prepareFactoryReset(context: second.context, session: nil,
            native: second.execution, installation: second.installation, provider: nextProvider,
            ownedCredentials: fixture.storage, baseCredentialSnapshot: { try fixture.emptyLegacySnapshot() })
        XCTAssertNotEqual(first.resetID, secondPreparation.resetID)
        try nextAuthority.leaveCloudForeground(); second.http.close()
        let secondReceipt = try await secondPreparation.execute()
        try secondReceipt.validateCompletion()
        XCTAssertEqual(fixture.storage.itemCount, 0)
        XCTAssertThrowsError(try firstReceipt.validateCompletion(), "Old reset cannot replace the new owner")
    }
    func testCommonOfflinePendingPartialCleanupRecoveryKeepsOriginalReset() async throws {
        let fixture = try await FactoryResetFixture.make(common: true, qualified: true)
        defer { fixture.close() }
        let common = try XCTUnwrap(fixture.common)
        let local = try fixture.authority.makeConcurrentLocalContext(context: fixture.context, session: common)
        try fixture.authority.leaveCloudForeground(); fixture.http.close()
        let preparation = try fixture.prepare()
        fixture.storage.failDeletionOnce = true
        do { _ = try await preparation.execute(); XCTFail("Injected exact credential erasure failure must retain pending intent") }
        catch { XCTAssertTrue(error is FactoryResetFixtureFailure) }
        XCTAssertEqual(try fixture.resetStore.load()?.resetID, preparation.resetID)
        XCTAssertEqual(try fixture.resetStore.load()?.phase, .pending)
        XCTAssertThrowsError(try local.validate(), "Pending reset revokes independent local control")
        XCTAssertThrowsError(try common.validatedAssociation(), "Original common inventory is retired")
        XCTAssertGreaterThan(fixture.storage.itemCount, 0)
        let recoveredAuthority = try fixture.newAuthority(qualified: false)
        let recovered = try XCTUnwrap(recoveredAuthority.recoverFactoryReset(provider: fixture.provider, ownedCredentials: fixture.storage))
        XCTAssertEqual(recovered.resetID, preparation.resetID)
        let receipt = try await recovered.execute()
        try receipt.validateCompletion()
        XCTAssertThrowsError(try recoveredAuthority.completedFactoryResetIdentity(resetID: UUID(), scopeDigest: recovered.scopeDigest))
        XCTAssertThrowsError(try recoveredAuthority.completedFactoryResetIdentity(resetID: recovered.resetID, scopeDigest: String(repeating: "0", count: 64)))
        XCTAssertEqual(fixture.storage.itemCount, 0)
        XCTAssertEqual(try fixture.resetStore.load()?.phase, .completed)
        XCTAssertNil(try recoveredAuthority.recoverFactoryReset(provider: fixture.provider, ownedCredentials: fixture.storage))
    }
    func testUnknownManagedChildBlocksWithoutDeletingIt() async throws {
        let fixture = try await FactoryResetFixture.make(common: true, qualified: true)
        defer { fixture.close() }
        let unknown = fixture.namespace.appendingPathComponent("unowned-user-file")
        let bytes = Data("preserve exact unexpected content".utf8)
        try bytes.write(to: unknown)
        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertEqual(try Data(contentsOf: unknown), bytes)
        XCTAssertNil(try fixture.resetStore.load())
        XCTAssertGreaterThan(fixture.storage.itemCount, 0)
    }
}
private enum FactoryResetFixtureFailure: Error { case injected, credentialIdentity }

/// Synthetic holder that stores the actual original enrolled values. Its exact
/// reference deletion checks and removes those same values, rather than treating
/// Security's item-not-found response as successful fixture cleanup.
private final class ResetOriginalCredentialStorage: NativeEnrollmentCredentialStorage, DeviceOwnedResetCredentialCleanup {
    private struct Item { let service: Data; let account: Data; let payload: Data; let value: NativeEnrollmentStoredCredential }
    private let lock = NSRecursiveLock()
    private var items: [Data: Item] = [:]
    private var sequence = 0
    var failDeletionOnce = false
    var itemCount: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    func enumerateBounded(maximum: Int) throws -> [NativeEnrollmentStoredCredential] {
        lock.lock(); defer { lock.unlock() }; guard items.count <= maximum else { throw FactoryResetFixtureFailure.credentialIdentity }; return items.values.map(\.value)
    }
    func generateOriginal48() throws -> Data { Data(repeating: 73, count: 48) }
    func readExactPersistentReference(_ reference: Data) throws -> NativeEnrollmentStoredCredential? { lock.lock(); defer { lock.unlock() }; return items[reference]?.value }
    private func insert(service: String, account: Data, payload: Data) -> NativeEnrollmentCredentialInsert {
        lock.lock(); defer { lock.unlock() }; sequence += 1
        let ref = Data(("owned-reset-fixture-ref-" + String(sequence)).utf8)
        items[ref] = .init(service: Data(service.utf8), account: account, payload: payload, value: .init(service: Data(service.utf8), account: account, persistentReference: ref, payload: payload, accessible: true))
        return .inserted(ref)
    }
    func insertStageOnly(account: Data, envelope: Data) throws -> NativeEnrollmentCredentialInsert {
        insert(service: "xyz.screenpunk.installation.cloud.enrollment-stage.v1", account: account, payload: envelope)
    }
    func insertFinalOnly(account: Data, original48: Data) throws -> NativeEnrollmentCredentialInsert {
        insert(service: "xyz.screenpunk.installation.cloud", account: account, payload: original48)
    }
    func deleteExact(_ item: DeviceFactoryResetManifest.Credential) throws {
        lock.lock(); defer { lock.unlock() }; if failDeletionOnce { failDeletionOnce = false; throw FactoryResetFixtureFailure.injected }
        guard let original = items[item.persistentReference] else { return }
        guard original.service == Data(item.service.utf8), original.account == Data(item.account.utf8),
            original.payload.count == item.byteCount, SHA256.hash(data: original.payload).map({ String(format: "%02x", $0) }).joined() == item.valueSHA256 else { throw FactoryResetFixtureFailure.credentialIdentity }
        items.removeValue(forKey: item.persistentReference)
    }
    func verifyOwnedServicesAbsent(_ services: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }; guard !items.values.contains(where: { services.contains(String(decoding: $0.service, as: UTF8.self)) }) else {
            throw FactoryResetFixtureFailure.credentialIdentity
        }
    }
}

@MainActor private final class FactoryResetFixture {
    struct Enrolled {
        let authority: DeviceManagementAuthority
        let context: DeviceManagementAuthority.CloudInstallationContext
        let installation: NativeOperationalInstallation
        let installationID: UUID
        let execution: NativeDeliveryExecutionSession
        let common: DeviceUnifiedInventorySession?
        let namespace: URL
        let http: FreshOwnerHTTP
    }
    let parent: URL
    let base: DeviceLocalResetScope
    let storage: ResetOriginalCredentialStorage
    let legacy = MemoryCredentialStore()
    let provider: DeviceLocalResetWriterProvider
    let enrolled: Enrolled
    var baseSnapshots = 0
    var authority: DeviceManagementAuthority { enrolled.authority }
    var context: DeviceManagementAuthority.CloudInstallationContext { enrolled.context }
    var common: DeviceUnifiedInventorySession? { enrolled.common }
    var http: FreshOwnerHTTP { enrolled.http }
    var namespace: URL { enrolled.namespace }
    var installationID: UUID { enrolled.installationID }
    var resetStore: DeviceLocalResetStore { .init(directory: base.resetDirectory) }
    init(parent: URL, base: DeviceLocalResetScope, storage: ResetOriginalCredentialStorage,
        provider: DeviceLocalResetWriterProvider, enrolled: Enrolled) {
        self.parent = parent; self.base = base; self.storage = storage; self.provider = provider; self.enrolled = enrolled
    }
    func close() { http.close(); try? FileManager.default.removeItem(at: parent) }
    func emptyLegacySnapshot() throws -> [DeviceFactoryResetManifest.Credential] {
        baseSnapshots += 1
        for item in base.credentialItems { XCTAssertNil(try legacy.secret(for: item.account)) }
        return []
    }
    func prepare() throws -> DeviceOwnedFactoryResetPreparation {
        do {
            return try authority.prepareFactoryReset(context: context, session: common, native: enrolled.execution,
                installation: enrolled.installation, provider: provider, ownedCredentials: storage,
                baseCredentialSnapshot: { try self.emptyLegacySnapshot() })
        } catch {
            FileHandle.standardError.write(Data(("Reset fixture preparation failure type: " + String(reflecting: type(of: error)) + "\n").utf8))
            throw error
        }
    }
    func newProvider() throws -> DeviceLocalResetWriterProvider {
        try .init(calendar: GoogleCalendarDeviceService(store: legacy, suspension: GoogleCalendarSuspensionDomain()),
            preferences: ScreenPreferenceStore(root: base.preferencesRoot))
    }
    func newAuthority(qualified: Bool) throws -> DeviceManagementAuthority {
        try Self.authority(parent: parent, base: base, qualified: qualified)
    }
    static func authority(parent: URL, base: DeviceLocalResetScope, qualified: Bool) throws -> DeviceManagementAuthority {
        let anchor = base.deviceRoot.deletingLastPathComponent()
        let store = DeviceLocalResetStore(directory: base.resetDirectory)
        let configured = try DeviceLocalResetLifecycle.restoredProductionScope(base: base, anchor: anchor, store: store)
        let evidence = DeviceLocalResetEvidenceAdapter(owned: configured.authorityScope, base: base, store: store)
        let result = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: evidence, managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent),
            commandIntents: .init(root: base.deviceRoot.appendingPathComponent("command-intents")), concurrentControlQualified: qualified)
        try result.prepareProductionSupportAnchor()
        return result
    }
    static func make(common: Bool, qualified: Bool) async throws -> FactoryResetFixture {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent("owned-reset-" + UUID().uuidString)
        let anchor = parent.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        let base = try DeviceLocalResetScope(deviceRoot: anchor.appendingPathComponent("device-state"),
            preferencesRoot: anchor.appendingPathComponent("preferences"), managementDirectory: anchor.appendingPathComponent("management"),
            resetDirectory: anchor.appendingPathComponent("reset"), credentialItems: DeviceLocalResetScope.allowedCredentialItems)
        try FileManager.default.createDirectory(at: base.deviceRoot.appendingPathComponent("command-intents"), withIntermediateDirectories: true)
        let storage = ResetOriginalCredentialStorage()
        do {
            let authority = try Self.authority(parent: parent, base: base, qualified: qualified)
            let result = try await enroll(parent: parent, base: base, storage: storage, authority: authority, common: common)
            let provider = try DeviceLocalResetWriterProvider(calendar: GoogleCalendarDeviceService(store: MemoryCredentialStore(), suspension: GoogleCalendarSuspensionDomain()),
                preferences: ScreenPreferenceStore(root: base.preferencesRoot))
            return .init(parent: parent, base: base, storage: storage, provider: provider, enrolled: result)
        } catch { try? FileManager.default.removeItem(at: parent); throw error }
    }
    static func enroll(parent: URL, base: DeviceLocalResetScope, storage: ResetOriginalCredentialStorage,
        authority: DeviceManagementAuthority, common wantsCommon: Bool) async throws -> Enrolled {
        try authority.enterCloudForeground()
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: UUID(), locationId: nil, name: "Fixture", profile: "Fixture")
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: claim.transitionId,
            credentialReference: "native." + UUID().uuidString, format: .nativeInstallationV1)
        let proposal = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage." + UUID().uuidString,
            binding: binding, claimInput: claim)
        let roots = try authority.prepareFreshCloudEnrollmentRoots(claim: claim)
        let protected = NativeManagedProtectedRoots(legacyState: base.deviceRoot, legacyArchive: parent.appendingPathComponent("legacy-archive"),
            reset: base.resetDirectory, cloudEnrollment: roots.journalRoot, management: base.managementDirectory, preferences: base.preferencesRoot)
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protected,
            grantTransport: FreshGrantTransport(rootID: roots.localIDs.grant))
        let session = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal, excludedLocalResetRoot: base.resetDirectory, storage: storage)
        let http = FreshOwnerHTTP(claim: claim)
        do {
            let result = try await session.enroll(origin: http.origin, tokenProvider: FreshOwnerTokens(), activationRequestID: http.activationRequestID,
                associationAttemptID: UUID(), stores: stores, configuration: http.configuration)
            let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: http.origin)
            let status = try authority.prepareCloudStatusRequest(context)
            try authority.beginCloudStatusRequest(context, requestID: status.requestID)
            try authority.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration), context: context)
            let current = try authority.prepareCurrentInstallationDispatch(context)
            let execution = try result.installation.makeDeliveryExecutionSession(current: current)
            _ = try execution.freshGenesisObservation(current: current)
            var common: DeviceUnifiedInventorySession?
            if wantsCommon {
                let shared = try authority.makeUnifiedInventorySession(context: context, current: current, commonRootID: UUID(), native: execution)
                try shared.migrate(current: current, operationID: UUID(), generationID: UUID(), admissionEnabled: authority.qualifiedConcurrentControl(context: context))
                common = shared
            }
            return .init(authority: authority, context: context, installation: result.installation, installationID: result.activation.installationId,
                execution: execution, common: common, namespace: roots.namespace, http: http)
        } catch { http.close(); throw error }
    }
}
