import XCTest
import Foundation
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple

// Shared genuine inventory setup for SwiftPM and iOS scene tests.
/// One uptime source for the genuine fixture's cloud lease and status observation.
/// It stays still until `advance`, so a stalled runner cannot age a fresh lease past 30s.
final class GenuineInventoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
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
    static func make(clock: GenuineInventoryClock = GenuineInventoryClock(),
        prepareLocal: ((DeviceManagementAuthority, URL) throws -> DeviceLegacyMigrationSession)? = nil) async throws -> Self {
        let now: () -> TimeInterval = { clock.now() }
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: parent) } }
        let anchor = parent.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent), commandIntents: .init(root: parent.appendingPathComponent("command-intents")), concurrentControlQualified: true)
        authority.adoptCloudClock(now)
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
        try authority.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration, clock: now), context: context)
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

