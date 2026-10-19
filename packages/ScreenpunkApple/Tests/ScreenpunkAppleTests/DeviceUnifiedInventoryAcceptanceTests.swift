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
    let nativeGrants: FreshGrantTransport
    let http: FreshOwnerHTTP
    let installation: NativeOperationalInstallation
    let activation: NativeActivationReceipt
    var cloudAbsenceProbe: any NativeCloudCredentialAbsenceProbe { LogoutAcceptanceCredentialProbe(native: storage, grants: nativeGrants) }
    func removeCloudCredentialExact(_ credential: DeviceOwnedInstallationResetResources.Credential) throws {
        if credential.service == DeviceGrantCredentialNamespace(rootID: nativeGrants.rootID).service {
            try nativeGrants.removeCloudCredentialExact(credential)
        } else {
            guard credential.service == "xyz.screenpunk.installation.cloud" || credential.service == "xyz.screenpunk.installation.cloud.enrollment-stage.v1" else { throw NativeEnrollmentPromotionError.blocked }
            try storage.removeCloudCredentialExact(credential)
        }
    }
    func close() { http.close(); try? FileManager.default.removeItem(at: parent) }
    static func make(prepareLocal: ((DeviceManagementAuthority, URL) throws -> DeviceLegacyMigrationSession)? = nil) async throws -> Self {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: parent) } }
        let anchor = parent.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent), commandIntents: .init(root: parent.appendingPathComponent("command-intents")), concurrentControlQualified: true)
        try authority.prepareProductionSupportAnchor()
        let local = try prepareLocal?(authority, parent)
        try authority.enterCloudForeground()
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: UUID(), locationId: nil, name: "Fixture", profile: "Fixture")
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: claim.transitionId,
            credentialReference: "native." + UUID().uuidString, format: .nativeInstallationV1)
        let proposal = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage." + UUID().uuidString,
            binding: binding, claimInput: claim)
        let roots = try authority.prepareFreshCloudEnrollmentRoots(claim: claim)
        let protection = NativeManagedProtectedRoots(legacyState: parent.appendingPathComponent("local"), legacyArchive: parent.appendingPathComponent("archive"),
            reset: parent.appendingPathComponent("reset"), cloudEnrollment: roots.journalRoot,
            management: parent.appendingPathComponent("management"), preferences: parent.appendingPathComponent("preferences"))
        let nativeGrants = FreshGrantTransport(rootID: roots.localIDs.grant)
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protection,
            grantTransport: nativeGrants)
        let storage = FreshCredentialStorage()
        let enrollment = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal, excludedLocalResetRoot: protection.reset, storage: storage)
        let http = FreshOwnerHTTP(claim: claim)
        defer { if !completed { http.close() } }
        let result = try await enrollment.enroll(origin: http.origin, tokenProvider: FreshOwnerTokens(),
            activationRequestID: http.activationRequestID, associationAttemptID: UUID(), stores: stores, configuration: http.configuration)
        let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: http.origin)
        let status = try authority.prepareCloudStatusRequest(context)
        try authority.beginCloudStatusRequest(context, requestID: status.requestID)
        try authority.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration), context: context)
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
        let common = try authority.makeUnifiedInventorySession(context: context, current: current, commonRootID: commonID, local: local, native: execution)
        let generation = UUID()
        try common.migrate(current: current, operationID: UUID(), generationID: generation,
            admissionEnabled: authority.qualifiedConcurrentControl(context: context))
        completed = true
        return .init(authority: authority, context: context, current: current, common: common, execution: execution, parent: parent, commonID: commonID, generation: generation, storage: storage, nativeGrants: nativeGrants, http: http, installation: result.installation, activation: result.activation)
    }
}

private enum UnifiedArchiveComposition {
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
    static func make(fixture: GenuineUnifiedInventoryFixture, changedPublication: Bool) throws -> Delivery {
        let original = try XCTUnwrap(fixture.http.delivery)
        let state = try fixture.common.validatedAssociation()
        let next = try AuthorityStaticDeliveryFixture.make(state: ["installationId": fixture.activation.installationId.uuidString.lowercased(),
            "transitionId": fixture.activation.transitionId.uuidString.lowercased(), "generationId": state.generationID.uuidString.lowercased()], activation: fixture.activation)
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
private final class OutcomeReplayLocalOwner: NativeUnifiedLocalInventoryOwner {
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
