import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

@MainActor final class DeviceLocalResetReopeningTests: XCTestCase {
    func testExactCompletionReopensBothDomainsAndOldObjectsRemainTerminal() async throws {
        let f = try ReopeningFixture()
        let oldCalendar = f.domains.calendar, oldPreferences = f.domains.preferences
        let otherPreferences = ScreenPreferenceStore(root: f.scope.authorityScope.preferencesRoot)
        XCTAssertEqual(oldPreferences.canonicalRoot, otherPreferences.canonicalRoot)
        XCTAssertEqual(oldPreferences.writerGeneration, otherPreferences.writerGeneration)
        let oldArchiveGeneration = try oldPreferences.generation()
        try oldPreferences.set(dashboard: "screen", key: "key", value: "old", generation: oldArchiveGeneration)
        let bridge = HomeAssistantWebBridge(runtime: nil, revision: "fixture", preferenceStore: oldPreferences, calendarService: oldCalendar, onHealth: { _ in })
        let coordinator = try f.coordinator()
        try await coordinator.begin(context: f.context(), resetID: UUID())
        let capability = try XCTUnwrap(coordinator.reopeningCapability)
        XCTAssertThrowsError(try oldCalendar.snapshot()); XCTAssertThrowsError(try oldPreferences.generation())
        try f.domains.open(capability)
        XCTAssertTrue(try f.domains.calendar.snapshot().accounts.isEmpty)
        let next = try f.domains.preferences.generation()
        XCTAssertNotEqual(next, oldArchiveGeneration)
        try f.domains.preferences.set(dashboard: "screen", key: "key", value: "fresh", generation: next)
        for old in [oldPreferences, otherPreferences] {
            XCTAssertThrowsError(try old.generation())
            XCTAssertThrowsError(try old.set(dashboard: "screen", key: "key", value: "late", generation: oldArchiveGeneration))
            old.suspendForReset() // A retired handle cannot retire the replacement generation.
        }
        XCTAssertEqual(try f.domains.preferences.get(dashboard: "screen", key: "key", generation: next) as? String, "fresh")
        XCTAssertTrue(bridge.calendarService === oldCalendar)
        XCTAssertThrowsError(try bridge.calendarService.snapshot())
        XCTAssertThrowsError(try f.domains.open(capability))
    }
    func testDifferentBundleAndRootCannotConsumeCapability() async throws {
        let f = try ReopeningFixture(), other = try ReopeningFixture()
        let first = try f.coordinator()
        try await first.begin(context: f.context(), resetID: UUID())
        let capability = try XCTUnwrap(first.reopeningCapability)
        _ = try other.domains.retireForReset()
        XCTAssertThrowsError(try other.domains.open(capability))
        XCTAssertThrowsError(try other.domains.calendar.snapshot())
        XCTAssertThrowsError(try other.domains.preferences.generation())
        try f.domains.open(capability)
        XCTAssertThrowsError(try other.domains.open(capability))
    }
    func testPreparationFailureKeepsBothSuspendedAndCapabilityUnconsumed() async throws {
        let f = try ReopeningFixture(), coordinator = try f.coordinator()
        try await coordinator.begin(context: f.context(), resetID: UUID())
        let capability = try XCTUnwrap(coordinator.reopeningCapability)
        let preferences = f.scope.authorityScope.preferencesRoot
        try FileManager.default.removeItem(at: preferences)
        try FileManager.default.createSymbolicLink(at: preferences, withDestinationURL: f.base)
        XCTAssertThrowsError(try f.domains.open(capability))
        XCTAssertThrowsError(try f.domains.calendar.snapshot())
        XCTAssertThrowsError(try f.domains.preferences.generation())
        try FileManager.default.removeItem(at: preferences)
        try f.domains.open(capability)
        XCTAssertNoThrow(try f.domains.preferences.generation())
        XCTAssertNoThrow(try f.domains.calendar.snapshot())
    }
    func testCompletionUncertaintyRetainsReceiptAndMintsOnlyAfterExactRecovery() async throws {
        let f = try ReopeningFixture(), coordinator = try f.coordinator()
        f.reset.failCompletion = true
        do { try await coordinator.begin(context: f.context(), resetID: UUID()); XCTFail("uncertain") } catch {}
        XCTAssertNil(coordinator.reopeningCapability)
        XCTAssertThrowsError(try f.domains.calendar.snapshot())
        XCTAssertEqual(f.cleanups, 1)
        try await coordinator.retry()
        XCTAssertEqual(f.cleanups, 1)
        try f.domains.open(XCTUnwrap(coordinator.reopeningCapability))
        XCTAssertEqual(f.reset.methods, ["save", "save", "save"])
    }
    func testCancellationDuringCompletedSaveRetainsSessionForExplicitCapabilityRecovery() async throws {
        let f = try ReopeningFixture(), coordinator = try f.coordinator()
        f.reset.onCompletedSave = { withUnsafeCurrentTask { $0?.cancel() } }
        let context = try f.context()
        let task = Task { try await coordinator.begin(context: context, resetID: UUID()) }
        try await task.value
        XCTAssertEqual(f.reset.record?.phase, .completed)
        XCTAssertNil(coordinator.reopeningCapability)
        XCTAssertThrowsError(try f.domains.preferences.generation())
        let reattached = try f.coordinator()
        f.reset.onCompletedSave = nil
        try await reattached.retry()
        XCTAssertEqual(f.cleanups, 1); XCTAssertEqual(f.retirements, 1)
        XCTAssertEqual(f.reset.methods, ["save", "save"])
        try f.domains.open(XCTUnwrap(reattached.reopeningCapability))
        XCTAssertNoThrow(try f.domains.preferences.generation())
        XCTAssertNoThrow(try f.domains.calendar.snapshot())
    }
    func testProviderSeamRejectsMixedDefaultBindingsAndCustomServiceInDefaultDomain() throws {
        let f = try ReopeningFixture(), other = try ReopeningFixture()
        let provider = try DeviceLocalResetWriterProvider(calendar: f.domains.calendar, preferences: f.domains.preferences)
        XCTAssertThrowsError(try DeviceLocalResetWriterDomains(scope: other.scope.authorityScope,
            calendar: provider.calendar, preferences: other.domains.preferences, provider: provider))
        XCTAssertThrowsError(try DeviceLocalResetWriterDomains(scope: f.scope.authorityScope,
            calendar: other.domains.calendar, preferences: provider.preferences, provider: provider))
        let customInDefaultDomain = GoogleCalendarDeviceService(store: MemoryCredentialStore(), suspension: provider.calendar.suspension)
        XCTAssertThrowsError(try DeviceLocalResetWriterDomains(scope: other.scope.authorityScope,
            calendar: customInDefaultDomain, preferences: other.domains.preferences, provider: provider))
        let customInDefaultPreferenceDomain = ScreenPreferenceStore(root: provider.preferences.canonicalRoot)
        XCTAssertThrowsError(try DeviceLocalResetWriterDomains(scope: f.scope.authorityScope,
            calendar: other.domains.calendar, preferences: customInDefaultPreferenceDomain, provider: provider))
        XCTAssertFalse(provider.calendar.suspension.suspended)
        XCTAssertNoThrow(try provider.preferences.generation())
    }
    func testTwoBundlesWithIdenticalGenerationsCannotShareRetirementCapability() async throws {
        let f = try ReopeningFixture()
        let second = try DeviceLocalResetWriterDomains(scope: f.scope.authorityScope, calendar: f.domains.calendar, preferences: f.domains.preferences)
        _ = try second.retireForReset()
        let coordinator = try f.coordinator()
        try await coordinator.begin(context: f.context(), resetID: UUID())
        let capability = try XCTUnwrap(coordinator.reopeningCapability)
        XCTAssertThrowsError(try second.open(capability))
        XCTAssertThrowsError(try f.domains.preferences.generation())
        try f.domains.open(capability)
        XCTAssertThrowsError(try second.open(capability))
        XCTAssertNoThrow(try f.domains.preferences.generation())
    }
    func testIsolatedDefaultProviderReplacesBothDefaultsWhileOldInstancesStayRetired() async throws {
        let f = try ReopeningFixture()
        let provider = try DeviceLocalResetWriterProvider(calendar: f.domains.calendar, preferences: f.domains.preferences)
        let bundle = try DeviceLocalResetWriterDomains(scope: f.scope.authorityScope, provider: provider)
        let oldCalendar = provider.calendar, oldPreferences = provider.preferences
        let coordinator = try DeviceLocalResetCoordinator(scope: f.scope.authorityScope, authority: f.owner,
            retireWriters: { _ in try bundle.retireForReset() }, receiptCleanup: { try f.adapter.execute($0) })
        try await coordinator.begin(context: f.context(), resetID: UUID())
        try bundle.open(XCTUnwrap(coordinator.reopeningCapability))
        XCTAssertTrue(provider.calendar === bundle.calendar); XCTAssertTrue(provider.preferences === bundle.preferences)
        XCTAssertFalse(provider.calendar === oldCalendar); XCTAssertFalse(provider.preferences === oldPreferences)
        XCTAssertThrowsError(try oldCalendar.snapshot()); XCTAssertThrowsError(try oldPreferences.generation())
        XCTAssertNoThrow(try provider.calendar.snapshot()); XCTAssertNoThrow(try provider.preferences.generation())
    }
    func testCompletedFreshRecoveryCannotMintOrSuspend() async throws {
        let f = try ReopeningFixture()
        f.reset.record = try .init(resetID: UUID(), scopeDigest: f.scope.authorityScope.digest, phase: .completed)
        let coordinator = try f.coordinator()
        try await coordinator.recover()
        XCTAssertNil(coordinator.reopeningCapability)
        XCTAssertEqual(f.retirements, 0); XCTAssertEqual(f.cleanups, 0)
        XCTAssertNoThrow(try f.domains.calendar.snapshot())
    }
    func testGenericQualifiedCleanupCannotMintReopening() async throws {
        let f = try ReopeningFixture()
        let coordinator = try DeviceLocalResetCoordinator(scope: f.scope.authorityScope, authority: f.owner,
            suspend: { _ in _ = try f.domains.retireForReset() }, qualifiedCleanup: { try f.adapter.execute($0) })
        try await coordinator.begin(context: f.context(), resetID: UUID())
        XCTAssertNil(coordinator.reopeningCapability)
    }
    func testCancellationAfterVerifiedCleanupNeedsExplicitRecoveryAndNeverRepeatsCleanup() async throws {
        let f = try ReopeningFixture(), coordinator = try f.coordinator(cancelAfterCleanup: true)
        let context = try f.context()
        let task = Task { try await coordinator.begin(context: context, resetID: UUID()) }
        do { try await task.value; XCTFail("cancelled") } catch {}
        XCTAssertNil(coordinator.reopeningCapability)
        XCTAssertEqual(f.reset.record?.phase, .pending)
        XCTAssertEqual(f.cleanups, 1)
        try await coordinator.retry()
        XCTAssertEqual(f.cleanups, 1)
        try f.domains.open(XCTUnwrap(coordinator.reopeningCapability))
    }
    func testNewPendingResetInvalidatesUnconsumedOlderCapability() async throws {
        let f = try ReopeningFixture(), first = try f.coordinator()
        try await first.begin(context: f.context(), resetID: UUID())
        let old = try XCTUnwrap(first.reopeningCapability)
        let newPending = try DeviceLocalResetRecord(resetID: UUID(), scopeDigest: f.scope.authorityScope.digest)
        try f.context().beginLocalReset(record: newPending)
        XCTAssertThrowsError(try f.domains.open(old))
        XCTAssertThrowsError(try f.domains.preferences.generation())
        XCTAssertThrowsError(try f.domains.calendar.snapshot())
    }
    func testOldBridgeRequestsCannotAcquireNewCalendarService() async throws {
        let transport = ReopeningTransport(), f = try ReopeningFixture(transport: transport)
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: "screen", name: "Fixture", revision: "revision", entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "fixture", width: 400, height: 400, scale: 1, orientation: "portrait"), connections: [.init(alias: "googleCalendar", required: true)], files: [.init(path: "index.html", bytes: 0, sha256: String(repeating: "0", count: 64))])
        let navigation = try DashboardEventRuntime(manifest: manifest, revision: "revision", settings: .init(), homeAssistant: nil, connections: nil)
        let old = HomeAssistantWebBridge(runtime: nil, navigation: navigation, revision: "revision", preferenceStore: f.domains.preferences, calendarService: f.domains.calendar, onHealth: { _ in XCTFail("old bridge published") })
        let coordinator = try f.coordinator()
        try await coordinator.begin(context: f.context(), resetID: UUID())
        try f.domains.open(XCTUnwrap(coordinator.reopeningCapability))
        try f.seedCalendar(expired: false)
        let request: [String: Any] = ["protocolVersion": 1, "kind": "request", "method": "connections.request", "alias": "googleCalendar", "operation": "events", "parameters": ["timeMin": "2026-10-03T00:00:00Z", "timeMax": "2026-10-04T00:00:00Z"]]
        old.handleValidatedBody(request, id: "old")
        for _ in 0..<30 { await Task.yield() }
        let oldCount = await transport.count(); XCTAssertEqual(oldCount, 0)
        let fresh = HomeAssistantWebBridge(runtime: nil, navigation: navigation, revision: "revision", preferenceStore: f.domains.preferences, calendarService: f.domains.calendar, onHealth: { _ in })
        fresh.handleValidatedBody(request, id: "fresh")
        for _ in 0..<100 { if await transport.count() == 1 { break }; await Task.yield() }
        let freshCount = await transport.count(); XCTAssertEqual(freshCount, 1)
    }
    func testCancellationIgnoringOldRefreshCannotWriteAfterReopening() async throws {
        let transport = ReopeningDelayedTransport(), f = try ReopeningFixture(transport: transport)
        try f.seedCalendar(expired: true)
        let old = f.domains.calendar
        let task = Task { try await old.reloadCalendars(accountID: "fixture") }
        await transport.waitForRequest()
        let coordinator = try f.coordinator()
        try await coordinator.begin(context: f.context(), resetID: UUID())
        try f.domains.open(XCTUnwrap(coordinator.reopeningCapability))
        await transport.release()
        do { try await task.value; XCTFail("late response") } catch {}
        XCTAssertNil(try f.credentials.secret(for: GoogleCalendarDeviceService.storageKey))
        XCTAssertTrue(try f.domains.calendar.snapshot().accounts.isEmpty)
    }
    func testReceiptFromPriorResetCannotCompleteNewDriver() async throws {
        let f = try ReopeningFixture(); var receipt: DeviceLocalResetCleanupReceipt?
        let first = try DeviceLocalResetCoordinator(scope: f.scope.authorityScope, authority: f.owner,
            retireWriters: { _ in try f.domains.retireForReset() }, receiptCleanup: { permit in
                let value = try f.adapter.execute(permit); receipt = value; return value
            })
        try await first.begin(context: f.context(), resetID: UUID())
        try f.domains.open(XCTUnwrap(first.reopeningCapability))
        let second = try DeviceLocalResetCoordinator(scope: f.scope.authorityScope, authority: f.owner,
            retireWriters: { _ in try f.domains.retireForReset() }, receiptCleanup: { _ in try XCTUnwrap(receipt) })
        do { try await second.begin(context: f.context(), resetID: UUID()); XCTFail("stale receipt") } catch {}
        XCTAssertNil(second.reopeningCapability)
        XCTAssertEqual(f.reset.record?.phase, .pending)
    }
    func testOldCapabilityCannotReopenLaterGeneration() async throws {
        let f = try ReopeningFixture(), first = try f.coordinator()
        try await first.begin(context: f.context(), resetID: UUID())
        let old = try XCTUnwrap(first.reopeningCapability)
        try f.domains.open(old)
        let second = try f.coordinator()
        try await second.begin(context: f.context(), resetID: UUID())
        XCTAssertThrowsError(try f.domains.open(old))
        XCTAssertThrowsError(try f.domains.calendar.snapshot())
        XCTAssertThrowsError(try f.domains.preferences.generation())
        try f.domains.open(XCTUnwrap(second.reopeningCapability))
    }
}
@MainActor private final class ReopeningFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let scope: DeviceLocalResetCleanupScope
    let reset: ReopeningResetEvidence
    let owner: DeviceManagementAuthority
    let domains: DeviceLocalResetWriterDomains
    let credentials = MemoryCredentialStore()
    var retirements = 0
    var cleanups = 0
    var adapter: DeviceLocalResetCleanup { .init(scope: scope, credentials: ReopeningCredentialCleanup(store: credentials)) }
    init(transport: any HTTPTransport = ReopeningTransport()) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let original = try DeviceLocalResetScope(deviceRoot: base.appendingPathComponent("device"), preferencesRoot: base.appendingPathComponent("preferences"), managementDirectory: base.appendingPathComponent("management"), resetDirectory: base.appendingPathComponent("reset"), credentialItems: DeviceLocalResetScope.allowedCredentialItems)
        scope = try .init(base: original, anchor: base)
        reset = .init(scope.authorityScope.digest)
        owner = .init(journal: ReopeningJournal(), credentials: .init(backend: ReopeningCloudCredentials(), random: { Data() }), reset: reset)
        domains = try .init(scope: scope.authorityScope, calendar: .init(store: credentials, transport: transport, suspension: GoogleCalendarSuspensionDomain()), preferences: .init(root: original.preferencesRoot))
        _ = try domains.preferences.generation()
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    func seedCalendar(expired: Bool) throws {
        let account = GoogleCalendarAccount(id: "fixture", email: "fixture@example.com", clientID: "123-fixture.apps.googleusercontent.com", accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: expired ? .distantPast : .distantFuture, calendars: [.init(id: "calendar", summary: "Calendar")])
        try credentials.put(JSONEncoder().encode(GoogleCalendarState(accounts: [account], selections: ["screen": [.init(accountID: "fixture", calendarID: "calendar")]])), for: GoogleCalendarDeviceService.storageKey)
    }
    func context() throws -> DeviceManagementContext { .init(authority: owner, lease: try XCTUnwrap(owner.refresh())) }
    func coordinator(cancelAfterCleanup: Bool = false) throws -> DeviceLocalResetCoordinator {
        try .init(scope: scope.authorityScope, authority: owner, retireWriters: { [self] _ in
            retirements += 1; return try domains.retireForReset()
        }, receiptCleanup: { [self] permit in
            cleanups += 1
            let receipt = try adapter.execute(permit)
            if cancelAfterCleanup { withUnsafeCurrentTask { $0?.cancel() } }
            return receipt
        })
    }
}
private struct ReopeningCredentialCleanup: DeviceLocalResetCredentialCleanup {
    let store: MemoryCredentialStore
    func delete(_ item: DeviceLocalResetScope.CredentialItem) throws { if item.service == GoogleCalendarDeviceService.storageService { try store.delete(item.account) } }
    func isAbsent(_ item: DeviceLocalResetScope.CredentialItem) throws -> Bool { try store.secret(for: item.account) == nil }
}
private final class ReopeningResetEvidence: DeviceLocalResetEvidence {
    let scopeDigest: String
    var record: DeviceLocalResetRecord?
    var uncertain = false
    var failCompletion = false
    var onCompletedSave: (() -> Void)?
    var methods: [String] = []
    init(_ digest: String) { scopeDigest = digest }
    func load() throws -> DeviceLocalResetRecord? { if uncertain { throw DeviceLocalResetStoreError.writeOutcomeUncertain }; return record }
    func save(_ record: DeviceLocalResetRecord) throws { try write(record, method: "save") }
    func beginNewReset(_ record: DeviceLocalResetRecord) throws { try write(record, method: "begin") }
    private func write(_ record: DeviceLocalResetRecord, method: String) throws {
        methods.append(method); self.record = record
        if record.phase == .completed { onCompletedSave?() }
        if record.phase == .completed && failCompletion { failCompletion = false; uncertain = true; throw DeviceLocalResetStoreError.writeOutcomeUncertain }
        uncertain = false
    }
}
private struct ReopeningJournal: CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionHistory? { nil }
    func save(_ history: DeviceManagementTransitionHistory) throws { fatalError() }
}
private struct ReopeningCloudCredentials: CloudInstallationCredentialBackend {
    func read(reference: String) throws -> Data? { nil }
    func references() throws -> Set<String> { [] }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { fatalError() }
}

private actor ReopeningTransport: HTTPTransport {
    private var calls = 0
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        calls += 1; return .init(status: 200, body: Data("{\"items\":[]}".utf8))
    }
    func count() -> Int { calls }
}
private actor ReopeningDelayedTransport: HTTPTransport {
    private var waiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<HTTPTransportResponse, Never>?
    private var entered = false
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        entered = true; waiter?.resume(); waiter = nil
        return await withCheckedContinuation { response = $0 }
    }
    func waitForRequest() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
    func release() { response?.resume(returning: .init(status: 200, body: Data(#"{"access_token":"late","expires_in":3600,"token_type":"Bearer"}"#.utf8))); response = nil }
}
