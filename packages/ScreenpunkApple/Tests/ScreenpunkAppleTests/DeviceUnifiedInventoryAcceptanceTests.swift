import XCTest
import Foundation
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple

final class DeviceUnifiedInventoryAcceptanceTests: XCTestCase {
    func testGenuineMountRequiresExactPresentationAndPersistsFailureAndRecovery() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let first = try fixture.common.selectedContent(operationID: UUID())
        XCTAssertNil(try fixture.common.mountedAssociation(), "Prepared content has no mounted receipt")
        XCTAssertEqual(try fixture.common.mountStateAssociation().state, "preparing")
        let candidate = try fixture.common.selectedContent(operationID: UUID())
        XCTAssertThrowsError(try fixture.common.confirmMountedLocalContent(first), "Only the exact current presentation may confirm a mount")
        XCTAssertThrowsError(try fixture.common.confirmMountFailure(candidate, code: "candidate_load_failed"), "Unknown failure codes cannot enter durable device state")
        try fixture.common.confirmMountFailure(candidate, code: "navigation_failed")
        XCTAssertNil(try fixture.common.mountedAssociation(), "A failed preload cannot become active")
        XCTAssertEqual(try fixture.common.mountStateAssociation().state, "failed")
        XCTAssertEqual(try fixture.common.mountStateAssociation().failureCode, "navigation_failed")
        let reopened = try fixture.authority.restoreUnifiedInventorySession(context: fixture.context,
            commonRootID: fixture.commonID, native: fixture.execution)
        XCTAssertEqual(try reopened.validatedAssociation().generationID, fixture.generation)
        XCTAssertEqual(try reopened.mountStateAssociation().state, "failed")
        let recovered = try reopened.selectedContent(operationID: UUID())
        try reopened.confirmMountedLocalContent(recovered)
        let mounted = try XCTUnwrap(reopened.mountedAssociation())
        XCTAssertEqual(mounted.generationID, recovered.generationID)
        XCTAssertEqual(mounted.entryID, recovered.entryID)
        XCTAssertTrue(mounted.currentlyConfigured)
        XCTAssertEqual(try reopened.mountStateAssociation().state, "ready")
        let secondReopen = try fixture.authority.restoreUnifiedInventorySession(context: fixture.context,
            commonRootID: fixture.commonID, native: fixture.execution)
        XCTAssertEqual(try secondReopen.validatedAssociation().generationID, fixture.generation)
        XCTAssertEqual(try secondReopen.mountedAssociation()?.generationID, mounted.generationID)
        XCTAssertEqual(try secondReopen.mountStateAssociation().state, "ready")
        let hiddenRestartCandidate = try secondReopen.selectedContent(operationID: UUID())
        XCTAssertThrowsError(try secondReopen.verifyRuntimePresentationMountedExact(hiddenRestartCandidate),
            "A persisted mount receipt must not authorize a new hidden renderer before its actual callback")
        try secondReopen.confirmMountedLocalContent(hiddenRestartCandidate)
        XCTAssertNoThrow(try secondReopen.verifyRuntimePresentationMountedExact(hiddenRestartCandidate))
    }
    func testGenuineCloudCommonInventoryReopensAndKeepsScreenWhenCloudForegroundEnds() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let active = try fixture.common.selectedContent(operationID: UUID())
        XCTAssertEqual(active.displayName, "Fixture")
        XCTAssertEqual(active.generationID, fixture.generation)
        XCTAssertTrue(active.assets.contains { $0.path == "index.html" })
        // Reopen through the same genuine owner. No new genesis or migration intent.
        let reopened = try fixture.authority.restoreUnifiedInventorySession(context: fixture.context, commonRootID: fixture.commonID, native: fixture.execution)
        XCTAssertEqual(try reopened.validatedAssociation().generationID, fixture.generation)
        let restored = try reopened.selectedContent(operationID: UUID())
        XCTAssertEqual(restored.generationID, active.generationID)
        XCTAssertEqual(restored.entryID, active.entryID)
        try fixture.authority.leaveCloudForeground()
        XCTAssertThrowsError(try fixture.authority.prepareCurrentInstallationDispatch(fixture.context))
        XCTAssertThrowsError(try fixture.current.requirePresentationCurrent(), "The retained command handle cannot authorize activation after cloud foreground ends")
        // Loss of cloud command admission leaves qualified common resources readable.
        let retained = try reopened.selectedContent(operationID: UUID())
        XCTAssertEqual(retained.entryID, active.entryID)
        XCTAssertEqual(retained.generationID, active.generationID)
        try reopened.confirmMountedLocalContent(retained)
        XCTAssertEqual(try reopened.mountedAssociation()?.generationID, active.generationID)
        XCTAssertEqual(try reopened.mountedAssociation()?.entryID, active.entryID)
        XCTAssertEqual(fixture.storage.adds, 2, "Neither reopen nor cloud disconnect duplicates credentials")
    }
    func testGenuineLeaseClockAcceptsFreshStatus() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        fixture.clock.advance(by: 8)
        XCTAssertNoThrow(try fixture.current.requirePresentationCurrent())
        XCTAssertNoThrow(try fixture.authority.validateCloudRequestStart(fixture.context))
    }
    func testGenuineLeaseClockRejectsExpiredStatus() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        fixture.clock.advance(by: 30.001)
        XCTAssertThrowsError(try fixture.current.requirePresentationCurrent()) {
            XCTAssertEqual($0 as? NativeEnrollmentPromotionError, .blocked)
        }
        XCTAssertThrowsError(try fixture.authority.validateCloudRequestStart(fixture.context)) {
            XCTAssertEqual($0 as? DeviceManagementAuthority.Failure, .staleLease)
        }
    }
    func testGenuineLeaseClockAcceptsTheThirtySecondBoundary() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        fixture.clock.advance(by: 30)
        XCTAssertNoThrow(try fixture.current.requirePresentationCurrent(), "Age of exactly 30 seconds stays inside the lease")
        XCTAssertNoThrow(try fixture.authority.validateCloudRequestStart(fixture.context))
    }
}

/// One uptime for the genuine fixture. Setup does not advance it, so wall time cannot age the 30-second lease.
final class GenuineLeaseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(by seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; instant += seconds }
}

struct GenuineUnifiedInventoryFixture {
    let authority: DeviceManagementAuthority
    let context: DeviceManagementAuthority.CloudInstallationContext
    let current: NativeCurrentInstallationDispatch
    let common: DeviceUnifiedInventorySession
    let execution: NativeDeliveryExecutionSession
    let parent: URL
    let commonID: UUID
    let generation: UUID
    let storage: FreshCredentialStorage
    let http: FreshOwnerHTTP
    let clock: GenuineLeaseClock
    func close() { http.close(); try? FileManager.default.removeItem(at: parent) }
    static func make(clock: GenuineLeaseClock = GenuineLeaseClock()) async throws -> Self {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: parent) } }
        let anchor = parent.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent), commandIntents: .init(root: parent.appendingPathComponent("command-intents")), concurrentControlQualified: true)
        authority.adoptUnifiedLeaseClock { clock.now() }
        try authority.prepareProductionSupportAnchor(); try authority.enterCloudForeground()
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: UUID(), locationId: nil, name: "Fixture", profile: "Fixture")
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: claim.transitionId,
            credentialReference: "native." + UUID().uuidString, format: .nativeInstallationV1)
        let proposal = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage." + UUID().uuidString,
            binding: binding, claimInput: claim)
        let roots = try authority.prepareFreshCloudEnrollmentRoots(claim: claim)
        let protection = NativeManagedProtectedRoots(legacyState: parent.appendingPathComponent("local"), legacyArchive: parent.appendingPathComponent("archive"),
            reset: parent.appendingPathComponent("reset"), cloudEnrollment: roots.journalRoot,
            management: parent.appendingPathComponent("management"), preferences: parent.appendingPathComponent("preferences"))
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protection,
            grantTransport: FreshGrantTransport(rootID: roots.localIDs.grant))
        let storage = FreshCredentialStorage()
        let enrollment = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal, excludedLocalResetRoot: protection.reset, storage: storage)
        let http = FreshOwnerHTTP(claim: claim)
        defer { if !completed { http.close() } }
        let result = try await enrollment.enroll(origin: http.origin, tokenProvider: FreshOwnerTokens(),
            activationRequestID: http.activationRequestID, associationAttemptID: UUID(), stores: stores, configuration: http.configuration)
        let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: http.origin)
        let status = try authority.prepareCloudStatusRequest(context)
        try authority.beginCloudStatusRequest(context, requestID: status.requestID)
        try authority.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration, uptime: { clock.now() }), context: context)
        let current = try authority.prepareCurrentInstallationDispatch(context)
        let execution = try result.installation.makeDeliveryExecutionSession(current: current)
        let stateBody = try execution.freshGenesisObservation(current: current)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateBody.bytes) as? [String: Any])
        let delivery = try AuthorityStaticDeliveryFixture.make(state: state, activation: result.activation); http.delivery = delivery
        let stateACK = try await NativeDeliveryStateHTTPObservation.collect(body: stateBody, installation: result.installation,
            current: current, origin: http.origin, configuration: http.configuration)
        try stateACK.requireOriginal(body: stateBody, installation: result.installation)
        let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: result.installation, current: current,
            origin: http.origin, configuration: http.configuration)
        let plan = try await command.fetchPlan(current: current, origin: http.origin, nativeOperationID: UUID(), configuration: http.configuration)
        let archives = try await plan.fetchArchives(current: current, origin: http.origin, target: delivery.archive.target,
            profileID: "Fixture", revisionName: "Fixture", configuration: http.configuration)
        try archives.prepare(session: execution, grantOperationID: UUID(), grantRevisionID: UUID())
        let activationBody = try execution.retainActivationRequest(requestID: UUID())
        let authorization = try await NativeDeliveryActivationHTTPObservation.collect(body: activationBody, installation: result.installation,
            current: current, origin: http.origin, configuration: http.configuration)
        try execution.retainAuthorization(requestBody: activationBody, observation: authorization)
        let outcome = try execution.dispatchAndRetainActivatedOutcome(current: current)
        let receipt = try await NativeDeliveryReceiptHTTPObservation.collect(body: outcome, installation: result.installation,
            origin: http.origin, configuration: http.configuration)
        _ = try execution.retainOutcomeAcknowledgment(body: outcome, observation: receipt)
        let commonID = UUID()
        let common = try authority.makeUnifiedInventorySession(context: context, current: current, commonRootID: commonID, native: execution)
        let generation = UUID()
        try common.migrate(current: current, operationID: UUID(), generationID: generation,
            admissionEnabled: authority.qualifiedConcurrentControl(context: context))
        completed = true
        return .init(authority: authority, context: context, current: current, common: common, execution: execution, parent: parent, commonID: commonID, generation: generation, storage: storage, http: http, clock: clock)
    }
}
