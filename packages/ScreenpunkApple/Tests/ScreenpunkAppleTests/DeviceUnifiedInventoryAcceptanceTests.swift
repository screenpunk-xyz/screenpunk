import XCTest
import Foundation
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple

final class DeviceUnifiedInventoryAcceptanceTests: XCTestCase {
    func testPendingCloudOutcomeSurvivesLocalSelectionAndRestartWithoutRollingBack() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let delivery = try UnifiedArchiveComposition.make(fixture: fixture, changedPublication: false)
        fixture.http.delivery = delivery.value
        fixture.http.unavailableDeliveryPackageIDs = [delivery.retainedPackageID]
        let pathStart = fixture.http.deliveryPaths.count
        let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: fixture.installation,
            current: fixture.current, origin: fixture.http.origin, configuration: fixture.http.configuration)
        let plan = try await command.fetchPlan(current: fixture.current, origin: fixture.http.origin,
            nativeOperationID: UUID(), configuration: fixture.http.configuration)
        _ = try plan.acceptUnified(session: fixture.common, current: fixture.current)
        let archives = try await plan.fetchArchives(current: fixture.current, origin: fixture.http.origin,
            target: delivery.value.archive.target, profileID: "Fixture", revisionName: "Fixture", configuration: fixture.http.configuration)
        try archives.prepareUnified(session: fixture.common, current: fixture.current,
            packageRootID: UUID(), grantOperationID: UUID(), grantRevisionID: UUID())
        let packagePaths = Array(fixture.http.deliveryPaths.dropFirst(pathStart)).filter { $0.contains("/delivery/package/") }
        XCTAssertEqual(packagePaths.map { URL(fileURLWithPath: $0).lastPathComponent }, [delivery.incomingPackageID])
        XCTAssertFalse(packagePaths.contains { $0.hasSuffix("/" + delivery.retainedPackageID) })
        let activation = try fixture.common.retainCloudActivationRequest(requestID: UUID(), current: fixture.current)
        let authorization = try await NativeDeliveryActivationHTTPObservation.collect(body: activation, installation: fixture.installation,
            current: fixture.current, origin: fixture.http.origin, configuration: fixture.http.configuration)
        try fixture.common.retainCloudAuthorization(requestBody: activation, observation: authorization)
        let outcome = try fixture.common.dispatchCloudAndRetainActivatedOutcome(current: fixture.current)
        let cloudState = try fixture.common.validatedAssociation()
        let priorPresentation = try fixture.common.selectedContent(operationID: UUID())
        let localGeneration = UUID()
        let owner = try OutcomeReplayLocalOwner(fixture: fixture)
        try fixture.common.selectOrRemove(operationID: UUID(), generationID: localGeneration,
            retainedEntryIDs: cloudState.entries.map(\.entryID), selected: delivery.retainedEntryID, owner: owner)
        let localState = try fixture.common.validatedAssociation()
        XCTAssertEqual(localState.generationID, localGeneration)
        XCTAssertEqual(localState.configuredEntryID, delivery.retainedEntryID)
        XCTAssertThrowsError(try fixture.common.confirmMountedLocalContent(priorPresentation))
        XCTAssertThrowsError(try fixture.current.requireInstallationAssociation(fixture.installation))
        let refreshedCurrent = try fixture.authority.prepareCurrentInstallationDispatch(fixture.context)
        let retry = try XCTUnwrap(fixture.common.restorePendingCloudOutcome(current: refreshedCurrent))
        XCTAssertEqual(retry.bytes, outcome.bytes)
        XCTAssertEqual(try fixture.common.validatedAssociation().generationID, localGeneration)
        let reopened = try fixture.authority.restoreUnifiedInventorySession(context: fixture.context,
            commonRootID: fixture.commonID, native: fixture.execution)
        let restored = try XCTUnwrap(reopened.restorePendingCloudOutcome(current: refreshedCurrent))
        XCTAssertEqual(restored.bytes, outcome.bytes)
        XCTAssertEqual(try reopened.validatedAssociation().generationID, localGeneration)
        XCTAssertEqual(try reopened.selectedContent(operationID: UUID()).entryID, delivery.retainedEntryID)
        let receipt = try await NativeDeliveryReceiptHTTPObservation.collect(body: restored, installation: fixture.installation,
            origin: fixture.http.origin, configuration: fixture.http.configuration)
        _ = try reopened.retainCloudOutcomeAcknowledgment(body: restored, observation: receipt)
        XCTAssertNil(try reopened.restorePendingCloudOutcome(current: refreshedCurrent))
        XCTAssertEqual(try reopened.validatedAssociation().generationID, localGeneration)
    }

    func testCloudDeclarationsMountAndUseOnlyExplicitLocalHomeApproval() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let before = try fixture.common.automationSourceExact().capture.snapshot
        var home = ManifestConnection(alias: "home", required: true)
        home.operations = [.init(name: "getStates", kind: "http", maxAgeSeconds: 10)]
        home.serviceCalls = [.init(domain: "light", service: "turn_on", entityIds: ["light.fixture"])]
        let delivery = try UnifiedArchiveComposition.make(fixture: fixture, changedPublication: false, connections: [home])
        fixture.http.delivery = delivery.value
        fixture.http.unavailableDeliveryPackageIDs = [delivery.retainedPackageID]
        let pathStart = fixture.http.deliveryPaths.count
        let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: fixture.installation,
            current: fixture.current, origin: fixture.http.origin, configuration: fixture.http.configuration)
        let plan = try await command.fetchPlan(current: fixture.current, origin: fixture.http.origin,
            nativeOperationID: UUID(), configuration: fixture.http.configuration)
        _ = try plan.acceptUnified(session: fixture.common, current: fixture.current)
        let archives = try await plan.fetchArchives(current: fixture.current, origin: fixture.http.origin,
            target: delivery.value.archive.target, profileID: "Fixture", revisionName: "Fixture", configuration: fixture.http.configuration)
        try archives.prepareUnified(session: fixture.common, current: fixture.current,
            packageRootID: UUID(), grantOperationID: UUID(), grantRevisionID: UUID())
        let packagePaths = Array(fixture.http.deliveryPaths.dropFirst(pathStart)).filter { $0.contains("/delivery/package/") }
        XCTAssertEqual(packagePaths.map { URL(fileURLWithPath: $0).lastPathComponent }, [delivery.incomingPackageID])
        XCTAssertFalse(packagePaths.contains { $0.hasSuffix("/" + delivery.retainedPackageID) })
        let activation = try fixture.common.retainCloudActivationRequest(requestID: UUID(), current: fixture.current)
        let authorization = try await NativeDeliveryActivationHTTPObservation.collect(body: activation, installation: fixture.installation,
            current: fixture.current, origin: fixture.http.origin, configuration: fixture.http.configuration)
        try fixture.common.retainCloudAuthorization(requestBody: activation, observation: authorization)
        _ = try fixture.common.dispatchCloudAndRetainActivatedOutcome(current: fixture.current)
        let after = try fixture.common.automationSourceExact().capture.snapshot
        XCTAssertEqual(after.entries.count, 2)
        XCTAssertEqual(after.entries.first { $0.entryID == delivery.retainedEntryID }, before.entries.first { $0.entryID == delivery.retainedEntryID },
            "Retention preserves the complete existing package, grant and resource identities")
        XCTAssertEqual(after.configuredEntryID, delivery.incomingEntryID)
        XCTAssertNotEqual(after.generationID, before.generationID)
        let approvals = DeviceCloudHomeAssistantStore(store: MemoryCredentialStore())
        let http = CloudHomeHTTP()
        let runtime = try await fixture.common.makeManagedRuntime(operationID: UUID(), http: http,
            webSocket: URLSessionWebSocketTransport(), resolver: LiteralOrResolvedDestinationResolver(), clock: SystemClock(),
            cloudHomeAssistant: { try approvals.configuration(installationID: $0, manifest: $1) })
        do { _ = try await runtime.request(alias: "home", operation: "getStates", parameters: [:]); XCTFail("Unmounted content cannot execute") } catch { }
        XCTAssertEqual(http.requests, 0)
        try fixture.common.confirmMountedLocalContent(runtime.content)
        do { _ = try await runtime.request(alias: "home", operation: "getStates", parameters: [:]); XCTFail("Declaration is not approval") } catch { }
        XCTAssertEqual(http.requests, 0)
        try approvals.approve(installationID: fixture.activation.installationId, manifest: runtime.manifest,
            origin: "http://192.168.1.40", token: "synthetic-token", allowInsecureHTTP: true)
        _ = try await runtime.request(alias: "home", operation: "getStates", parameters: [:])
        _ = try await runtime.request(alias: "home", operation: "callService", parameters: ["call": #"{"domain":"light","service":"turn_on","target":{"entity_id":"light.fixture"},"serviceData":{}}"#])
        XCTAssertEqual(http.requests, 2)
        do { _ = try await runtime.request(alias: "home", operation: "callService", parameters: ["call": #"{"domain":"light","service":"turn_on","target":{"entity_id":"light.other"},"serviceData":{}}"#]); XCTFail("Undeclared entity") } catch { }
        XCTAssertEqual(http.requests, 2)
        try approvals.revoke(installationID: fixture.activation.installationId)
        do { _ = try await runtime.request(alias: "home", operation: "getStates", parameters: [:]); XCTFail("Revoked grant") } catch { }
        XCTAssertEqual(http.requests, 2)
        await runtime.cancel()
        let reopened = try fixture.authority.restoreUnifiedInventorySession(context: fixture.context, commonRootID: fixture.commonID, native: fixture.execution)
        let restored = try await reopened.makeManagedRuntime(operationID: UUID(), http: http,
            webSocket: URLSessionWebSocketTransport(), resolver: LiteralOrResolvedDestinationResolver(), clock: SystemClock())
        XCTAssertEqual(restored.manifest.connections, [home])
        XCTAssertEqual(restored.content.entryID, runtime.content.entryID)
    }

    func testUnifiedArchiveCollectionReusesExactRetainedCloudAndFetchesOnlyNewPackage() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let before = try fixture.common.automationSourceExact().capture.snapshot
        let delivery = try UnifiedArchiveComposition.make(fixture: fixture, changedPublication: false)
        fixture.http.delivery = delivery.value
        fixture.http.unavailableDeliveryPackageIDs = [delivery.retainedPackageID]
        let pathStart = fixture.http.deliveryPaths.count
        let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: fixture.installation,
            current: fixture.current, origin: fixture.http.origin, configuration: fixture.http.configuration)
        let plan = try await command.fetchPlan(current: fixture.current, origin: fixture.http.origin,
            nativeOperationID: UUID(), configuration: fixture.http.configuration)
        _ = try plan.acceptUnified(session: fixture.common, current: fixture.current)
        let archives = try await plan.fetchArchives(current: fixture.current, origin: fixture.http.origin,
            target: delivery.value.archive.target, profileID: "Fixture", revisionName: "Fixture", configuration: fixture.http.configuration)
        try archives.prepareUnified(session: fixture.common, current: fixture.current,
            packageRootID: UUID(), grantOperationID: UUID(), grantRevisionID: UUID())
        let packagePaths = Array(fixture.http.deliveryPaths.dropFirst(pathStart)).filter { $0.contains("/delivery/package/") }
        XCTAssertEqual(packagePaths.map { URL(fileURLWithPath: $0).lastPathComponent }, [delivery.incomingPackageID])
        XCTAssertFalse(packagePaths.contains { $0.hasSuffix("/" + delivery.retainedPackageID) })
        let activation = try fixture.common.retainCloudActivationRequest(requestID: UUID(), current: fixture.current)
        let authorization = try await NativeDeliveryActivationHTTPObservation.collect(body: activation, installation: fixture.installation,
            current: fixture.current, origin: fixture.http.origin, configuration: fixture.http.configuration)
        try fixture.common.retainCloudAuthorization(requestBody: activation, observation: authorization)
        _ = try fixture.common.dispatchCloudAndRetainActivatedOutcome(current: fixture.current)
        let after = try fixture.common.automationSourceExact().capture.snapshot
        XCTAssertEqual(after.entries.count, 2)
        XCTAssertEqual(after.entries.first { $0.entryID == delivery.retainedEntryID }, before.entries.first { $0.entryID == delivery.retainedEntryID },
            "Retention preserves the complete existing package, grant and resource identities")
        XCTAssertEqual(after.configuredEntryID, delivery.incomingEntryID)
        XCTAssertNotEqual(after.generationID, before.generationID)
    }
    func testUnifiedArchiveCollectionDoesNotRetainChangedDescriptorAtSameEntry() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let before = try fixture.common.automationSourceExact().capture.snapshot
        let delivery = try UnifiedArchiveComposition.make(fixture: fixture, changedPublication: true)
        fixture.http.delivery = delivery.value
        fixture.http.unavailableDeliveryPackageIDs = [delivery.retainedPackageID]
        let pathStart = fixture.http.deliveryPaths.count
        let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: fixture.installation,
            current: fixture.current, origin: fixture.http.origin, configuration: fixture.http.configuration)
        let plan = try await command.fetchPlan(current: fixture.current, origin: fixture.http.origin,
            nativeOperationID: UUID(), configuration: fixture.http.configuration)
        _ = try plan.acceptUnified(session: fixture.common, current: fixture.current)
        do {
            _ = try await plan.fetchArchives(current: fixture.current, origin: fixture.http.origin,
                target: delivery.value.archive.target, profileID: "Fixture", revisionName: "Fixture", configuration: fixture.http.configuration)
            XCTFail("Changed publication at the same entry/package/content identity still requires its exact archive")
        } catch {
            XCTAssertEqual(error as? NativeOperationalTransportFailure, .invalidResponse)
        }
        let packagePaths = Array(fixture.http.deliveryPaths.dropFirst(pathStart)).filter { $0.contains("/delivery/package/") }
        XCTAssertEqual(packagePaths.map { URL(fileURLWithPath: $0).lastPathComponent }, [delivery.retainedPackageID])
        XCTAssertEqual(try fixture.common.automationSourceExact().capture.snapshot, before)
    }
    func testExclusiveFirstDeliveryStillFetchesAndPreparesItsCloudArchive() async throws {
        // The genuine factory performs fixed command/plan/archive IO, exclusive
        // preparation, authorization and CAS before migrating the installed A.
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let delivery = try XCTUnwrap(fixture.http.delivery)
        let package = try UnifiedArchiveComposition.packageID(in: delivery.command)
        XCTAssertEqual(fixture.http.deliveryPaths.filter { $0.contains("/delivery/package/") }.map { URL(fileURLWithPath: $0).lastPathComponent }, [package])
        let installed = try fixture.common.automationSourceExact().capture.snapshot
        XCTAssertEqual(installed.entries.count, 1)
        XCTAssertEqual(installed.configuredEntryID, delivery.archive.entryID)
        let content = try fixture.common.selectedContent(operationID: UUID())
        XCTAssertEqual(content.entryID, delivery.archive.entryID)
        XCTAssertTrue(content.assets.contains { $0.path == "index.html" })
    }
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
    func testStaleGenuineClockRejectsCloudLeaseAndPresentation() async throws {
        let clock = GenuineInventoryClock()
        let fixture = try await GenuineUnifiedInventoryFixture.make(clock: clock)
        defer { fixture.close() }
        clock.advance(30)
        XCTAssertNoThrow(try fixture.authority.validateCloudRequestStart(fixture.context))
        XCTAssertNoThrow(try fixture.current.requirePresentationCurrent())
        clock.advance(0.001)
        XCTAssertThrowsError(try fixture.authority.validateCloudRequestStart(fixture.context)) {
            XCTAssertEqual($0 as? DeviceManagementAuthority.Failure, .staleLease)
        }
        XCTAssertThrowsError(try fixture.current.requirePresentationCurrent()) {
            XCTAssertEqual($0 as? NativeEnrollmentPromotionError, .blocked)
        }
    }
}

enum UnifiedArchiveComposition {
    struct Delivery {
        let value: AuthorityStaticDeliveryFixture.Value
        let retainedEntryID: UUID, incomingEntryID: UUID
        let retainedPackageID: String, incomingPackageID: String
    }
    static func object(_ bytes: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    static func entries(in command: Data) throws -> [[String: Any]] {
        let body = try object(command), set = try XCTUnwrap(body["resultingSet"] as? [String: Any])
        return try XCTUnwrap(set["entries"] as? [[String: Any]])
    }
    static func packageID(in command: Data) throws -> String {
        let entry = try XCTUnwrap(entries(in: command).first)
        let provenance = try XCTUnwrap(entry["provenance"] as? [String: Any])
        return try XCTUnwrap((provenance["package"] as? [String: Any])?["packageId"] as? String)
    }
    static func make(fixture: GenuineUnifiedInventoryFixture, changedPublication: Bool, connections: [ManifestConnection] = [], dashboard: UUID = UUID(), revision: UUID = UUID()) throws -> Delivery {
        let original = try XCTUnwrap(fixture.http.delivery)
        let state = try fixture.common.validatedAssociation()
        let next = try AuthorityStaticDeliveryFixture.make(state: ["installationId": fixture.activation.installationId.uuidString.lowercased(),
            "transitionId": fixture.activation.transitionId.uuidString.lowercased(), "generationId": state.generationID.uuidString.lowercased()], activation: fixture.activation, connections: connections, dashboard: dashboard, revision: revision)
        var retained = try XCTUnwrap(entries(in: original.command).first)
        let retainedID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(retained["entryId"] as? String)))
        let retainedPackage = try packageID(in: original.command)
        let incoming = try XCTUnwrap(entries(in: next.command).first)
        var body = try object(next.command)
        let result: [String: Any]
        if changedPublication {
            var provenance = try XCTUnwrap(retained["provenance"] as? [String: Any])
            var package = try XCTUnwrap(provenance["package"] as? [String: Any])
            package["publicationId"] = UUID().uuidString.lowercased()
            provenance["package"] = package; retained["provenance"] = provenance
            result = ["schemaVersion": 1, "entries": [retained], "configuredEntryId": retainedID.uuidString.lowercased()]
        } else {
            result = ["schemaVersion": 1, "entries": [retained, incoming], "configuredEntryId": next.archive.entryID.uuidString.lowercased()]
        }
        body["sequence"] = "2"; body["removeEntryIds"] = [] as [String]; body["resultingSet"] = result
        body["resultingSetDigest"] = try DeviceDeliveryCandidateCodec.resultingSetDigest(
            DeviceDeliveryCandidateJSONDecoder.decodeResultingSet(JSONSerialization.data(withJSONObject: result)))
        return .init(value: .init(command: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]),
            header: next.header, plan: next.plan, archive: changedPublication ? original.archive : next.archive),
            retainedEntryID: retainedID, incomingEntryID: next.archive.entryID,
            retainedPackageID: retainedPackage, incomingPackageID: try packageID(in: next.command))
    }
}

// Substitutes the already-approved LAN peer boundary only; production authority
// still admits the Local intent and performs its fixed inventory mutation.
final class OutcomeReplayLocalOwner: NativeUnifiedLocalInventoryOwner {
    let commonRootID: UUID
    let peerPinHex = String(repeating: "7", count: 64)
    let authority: DeviceManagementAuthority
    let checkpoint: DeviceCommandIntentCoordinator.Checkpoint?
    init(fixture: GenuineUnifiedInventoryFixture) throws {
        commonRootID = fixture.commonID; authority = fixture.authority
        checkpoint = try authority.acceptUnifiedLocalIntent(peerPinHex: peerPinHex, validateApproved: {})
    }
    func performFixedUnifiedLocalDispatch(command: NativeInstallationUnifiedLocalDispatchCommand) throws -> NativeInstallationUnifiedLocalDispatchResult {
        try authority.performFixedUnifiedLocalDispatch(command: command, peerPinHex: peerPinHex, checkpoint: checkpoint) {
            try command.performDuringFixedOwner()
        }
    }
}

private final class CloudHomeHTTP: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func record() { lock.lock(); count += 1; lock.unlock() }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        record()
        return .init(status: 200, body: Data("[]".utf8), headers: [:])
    }
}
