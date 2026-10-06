import XCTest
import CryptoKit
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple

final class DeviceManagementAuthorityTests: XCTestCase {
    func testManagedAppearanceRevokesLeaseRenderingAndResetAndNeverBecomesLegacyAgain() throws {
        let anchor = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: anchor) }
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { XCTFail("no keys"); return Data() }), reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor))
        let lease = try XCTUnwrap(authority.refresh())
        let namespace = anchor.appendingPathComponent("xyz.screenpunk.native-managed")
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false)
        var effects = 0
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) { effects += 1 })
        XCTAssertEqual(effects, 0)
        XCTAssertFalse(authority.resetRenderingAllowed())
        XCTAssertThrowsError(try authority.resetRecoverySnapshot())
        try FileManager.default.removeItem(at: namespace)
        XCTAssertNil(try authority.refresh())
        XCTAssertThrowsError(try authority.requireLegacyNamespaceAbsent())
    }

    func testExplicitFirstEnrollmentRetainsExactRootsAndBackgroundRevokesThem() throws {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        let anchor = parent.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(),
            credentials: .init(backend: AuthorityBackend(), random: { XCTFail("fresh preparation does not generate a legacy key"); return Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent))
        try authority.prepareProductionSupportAnchor(); try authority.enterCloudForeground()
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: UUID(), locationId: UUID(), name: "Fixture", profile: "Fixture")
        let original = try authority.prepareFreshCloudEnrollmentRoots(claim: claim)
        XCTAssertTrue(try authority.prepareFreshCloudEnrollmentRoots(claim: claim) === original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: original.namespace.path)), Set(DeviceNativeManagedRootLocator.futureChildNames + ["enrollment"]))
        try authority.validateFreshCloudEnrollmentRoots(original)
        XCTAssertNil(try authority.refresh()) // Managed presence never grants Local.
        try authority.leaveCloudForeground()
        XCTAssertThrowsError(try authority.validateFreshCloudEnrollmentRoots(original))
        try authority.enterCloudForeground()
        XCTAssertThrowsError(try authority.prepareFreshCloudEnrollmentRoots(claim: claim)) // No successor adoption.
    }
    func testFirstEnrollmentOrphanNamespaceRejectsBeforeChildCreation() throws {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        let anchor = parent.appendingPathComponent("Application Support"), namespace = anchor.appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent))
        try authority.prepareProductionSupportAnchor(); try authority.enterCloudForeground()
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: UUID(), locationId: UUID(), name: "Fixture", profile: "Fixture")
        XCTAssertThrowsError(try authority.prepareFreshCloudEnrollmentRoots(claim: claim))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: namespace.path).isEmpty)
    }

    func testGenuineFirstEnrollmentHandsOffReadsThenSameOwnerStatusAndBackgroundRevocation() async throws {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString), anchor = parent.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent))
        try authority.prepareProductionSupportAnchor(); try authority.enterCloudForeground()
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: UUID(), locationId: UUID(), name: "Fixture", profile: "Fixture")
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: claim.transitionId, credentialReference: "native." + UUID().uuidString, format: .nativeInstallationV1)
        let proposal = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage." + UUID().uuidString, binding: binding, claimInput: claim)
        let roots = try authority.prepareFreshCloudEnrollmentRoots(claim: claim)
        let protection = NativeManagedProtectedRoots(legacyState: parent.appendingPathComponent("local"), legacyArchive: parent.appendingPathComponent("archive"),
            reset: parent.appendingPathComponent("reset"), cloudEnrollment: roots.journalRoot, management: parent.appendingPathComponent("management"), preferences: parent.appendingPathComponent("preferences"))
        XCTAssertEqual(roots.namespace.lastPathComponent, DeviceNativeManagedRootLocator.namespaceName, "Exact original authority namespace name")
        let physicalNamespace = try XCTUnwrap(realpath(roots.namespace.path, nil))
        XCTAssertEqual(roots.namespace.path, String(cString: physicalNamespace), "Exact original descriptor-checked physical namespace")
        free(physicalNamespace)
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protection, grantTransport: FreshGrantTransport(rootID: roots.localIDs.grant))
        let storage = FreshCredentialStorage()
        let session = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal, excludedLocalResetRoot: protection.reset, storage: storage)
        let http = FreshOwnerHTTP(claim: claim); defer { http.close() }
        let result: NativeOperationalEnrollmentResult
        do {
            result = try await session.enroll(origin: http.origin, tokenProvider: FreshOwnerTokens(), activationRequestID: http.activationRequestID,
                associationAttemptID: UUID(), stores: stores, configuration: http.configuration)
        } catch {
            let directories = DeviceNativeManagedRootLocator.futureChildNames.map { roots.namespace.appendingPathComponent($0) } + [roots.journalRoot]
            let marker = directories.map { directory in
                let leaves = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["unreadable"]
                return directory.lastPathComponent + "=" + leaves.sorted().prefix(20).joined(separator: ",")
            }.joined(separator: ";")
            XCTFail("Enrollment diagnostic adds=\(storage.adds) reads=\(storage.reads) requests=\(http.requestCount); \(marker)")
            throw error // Original capacity/error is never converted to a success or skip.
        }
        // Enrollment driver has exited: these reads must use its distinct original read handoff.
        XCTAssertNoThrow(try result.installation.requireDurableActivationAssociation(result.activation))
        let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: http.origin)
        let request = try authority.prepareCloudStatusRequest(context)
        try authority.beginCloudStatusRequest(context, requestID: request.requestID)
        let observation = try await request.performFixedTransport(origin: http.origin, configuration: http.configuration)
        try authority.acceptCloudStatus(observation, context: context)
        let dispatch = try authority.prepareCurrentInstallationDispatch(context)
        XCTAssertNoThrow(try dispatch.validateInstallationExact(installation: result.installation))
        let execution = try result.installation.makeDeliveryExecutionSession(current: dispatch)
        let stateBody = try execution.freshGenesisObservation(current: dispatch)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateBody.bytes) as? [String: Any])
        XCTAssertEqual(state["installationId"] as? String, result.activation.installationId.uuidString.lowercased())
        XCTAssertEqual((state["entries"] as? [Any])?.count, 0)
        XCTAssertEqual(storage.adds, 2)
        // A genuine prepared static command, not a manufactured session/capability.
        let delivery = try AuthorityStaticDeliveryFixture.make(state: state, activation: result.activation)
        http.delivery = delivery
        let stateACK = try await NativeDeliveryStateHTTPObservation.collect(body: stateBody, installation: result.installation,
            current: dispatch, origin: http.origin, configuration: http.configuration)
        XCTAssertNoThrow(try stateACK.requireOriginal(body: stateBody, installation: result.installation))
        let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: result.installation,
            current: dispatch, origin: http.origin, configuration: http.configuration)
        XCTAssertTrue(command.hasCommand)
        let plan = try await command.fetchPlan(current: dispatch, origin: http.origin, nativeOperationID: UUID(), configuration: http.configuration)
        let archives = try await plan.fetchArchives(current: dispatch, origin: http.origin, target: delivery.archive.target,
            profileID: "Fixture", revisionName: "Fixture", configuration: http.configuration)
        try archives.prepare(session: execution, grantOperationID: UUID(), grantRevisionID: UUID())
        let activationID = UUID()
        enum LostReply: Error { case afterDurableRetention }
        try execution.setActivationRetentionFaultForTesting { boundary in
            if case .afterRetain = boundary { throw LostReply.afterDurableRetention }
        }
        XCTAssertThrowsError(try execution.retainActivationRequest(requestID: activationID))
        let originalAttempt = try XCTUnwrap(execution.originalActivationAttemptForTesting())
        XCTAssertEqual(originalAttempt.0, activationID)
        try execution.setActivationRetentionFaultForTesting(nil)
        XCTAssertThrowsError(try execution.retainActivationRequest(requestID: UUID()))
        let body = try execution.retainActivationRequest(requestID: activationID)
        XCTAssertEqual(execution.originalActivationAttemptForTesting()?.0, originalAttempt.0)
        XCTAssertEqual(execution.originalActivationAttemptForTesting()?.1, originalAttempt.1)
        XCTAssertEqual(try execution.retainActivationRequest(requestID: activationID).bytes, body.bytes)
        let readsBeforeWrongOrigin = storage.reads
        do {
            _ = try await NativeDeliveryActivationHTTPObservation.collect(body: body, installation: result.installation, current: dispatch,
                origin: URL(string: "https://wrong.fixture.test")!, configuration: http.configuration)
            XCTFail("An alternate HTTPS origin must not receive the installation bearer")
        } catch {}
        XCTAssertEqual(storage.reads, readsBeforeWrongOrigin)
        let acceptedHTTP = try await NativeDeliveryActivationHTTPObservation.collect(body: body, installation: result.installation,
            current: dispatch, origin: http.origin, configuration: http.configuration)
        try execution.retainAuthorization(requestBody: body, observation: acceptedHTTP)
        let outcome = try execution.dispatchAndRetainActivatedOutcome(current: dispatch)
        let receipt = try await NativeDeliveryReceiptHTTPObservation.collect(body: outcome, installation: result.installation,
            origin: http.origin, configuration: http.configuration)
        _ = try execution.retainOutcomeAcknowledgment(body: outcome, observation: receipt)
        let rendered = try execution.completedStaticContent(current: dispatch)
        XCTAssertEqual(rendered.displayName, "Fixture"); XCTAssertTrue(rendered.assets.contains(where: { $0.path == "index.html" }))
        XCTAssertNoThrow(try dispatch.requirePresentationCurrent())
        XCTAssertEqual(storage.adds, 2)
        let deliveryPaths = http.deliveryPaths
        let refreshRequest = try authority.prepareCloudStatusRequest(context)
        try authority.beginCloudStatusRequest(context, requestID: refreshRequest.requestID)
        let refreshObservation = try await refreshRequest.performFixedTransport(origin: http.origin, configuration: http.configuration)
        try authority.acceptCloudStatus(refreshObservation, context: context)
        let refreshed = try authority.prepareCurrentInstallationDispatch(context)
        // Completed refresh uses the completed resource verifier, not pre-completion
        // authorization retention or a second structural dispatch/activation POST.
        let refreshedContent = try execution.completedStaticContent(current: refreshed)
        XCTAssertEqual(refreshedContent.displayName, rendered.displayName)
        XCTAssertNoThrow(try refreshed.requirePresentationCurrent())
        XCTAssertEqual(http.deliveryPaths, deliveryPaths)
        XCTAssertEqual(storage.adds, 2)
        XCTAssertTrue(deliveryPaths.contains("/v1/native/installations/delivery/state"))
        XCTAssertTrue(deliveryPaths.contains("/v1/native/installations/delivery/command"))
        XCTAssertTrue(deliveryPaths.contains(where: { $0.hasPrefix("/v1/native/installations/delivery/plan/") }))
        XCTAssertTrue(deliveryPaths.contains(where: { $0.hasPrefix("/v1/native/installations/delivery/package/") }))
        try authority.leaveCloudForeground()
        XCTAssertThrowsError(try result.installation.makeStatusRequest(origin: http.origin, activation: result.activation))
        XCTAssertThrowsError(try dispatch.validateInstallationExact(installation: result.installation))
        XCTAssertEqual(storage.adds, 2)
    }

    private func history() throws -> DeviceManagementTransitionHistory {
        try .intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: UUID().uuidString)
    }
    private func owner(_ journal: AuthorityJournal, _ backend: AuthorityBackend) -> DeviceManagementAuthority {
        .init(journal: journal, credentials: .init(backend: backend, random: { Data(repeating: 9, count: 32) }), reset: ManagementTestResetEvidence(), managedNamespace: testManagedNamespaceInspector())
    }
    func testRefreshRevokesPriorLeaseAndForeignLeaseRejected() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let first = try XCTUnwrap(authority.refresh())
        let second = try XCTUnwrap(authority.refresh())
        XCTAssertThrowsError(try authority.withLocalAuthority(first) {})
        try authority.withLocalAuthority(second) {}
        XCTAssertThrowsError(try owner(journal, backend).withLocalAuthority(second) {})
        try authority.revoke()
        XCTAssertThrowsError(try authority.withLocalAuthority(second) {})
    }
    func testPendingOrphanMissingAndInaccessibleBlock() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        backend.values["orphan"] = Data(repeating: 9, count: 32)
        XCTAssertNil(try authority.refresh())
        backend.values = [:]
        journal.value = try history()
        XCTAssertNil(try authority.refresh())
        backend.values[journal.value!.credentials[0].credentialReference] = Data(repeating: 9, count: 32)
        XCTAssertNil(try authority.refresh())
        journal.value = try journal.value!.fenced()
        let fencedAuthority = owner(journal, backend)
        XCTAssertNotNil(try fencedAuthority.refresh())
        backend.inaccessible = true
        XCTAssertNil(try authority.refresh())
        backend.inaccessible = false; journal.unavailable = true
        XCTAssertNil(try authority.refresh())
    }
    func testFreshEvidenceChangeRevokesBeforeSideEffectEvenIfNewHistoryFenced() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let lease = try XCTUnwrap(authority.refresh())
        journal.value = try history().fenced()
        backend.values[journal.value!.credentials[0].credentialReference] = Data(repeating: 9, count: 32)
        var ran = false
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) { ran = true })
        XCTAssertFalse(ran)
        XCTAssertNil(try authority.refresh())
    }
    func testObservedHistoryDisappearanceAndRollbackNeverBecomesLegacy() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend()
        let first = try history().fenced()
        let second = try first.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "next").fenced()
        journal.value = second
        for binding in second.credentials { backend.values[binding.credentialReference] = Data(repeating: 9, count: 32) }
        let authority = owner(journal, backend)
        XCTAssertNotNil(try authority.refresh())
        journal.value = first; backend.values.removeValue(forKey: "next")
        XCTAssertNil(try authority.refresh())
        journal.value = nil; backend.values = [:]
        XCTAssertNil(try authority.refresh())
    }
    func testKeyBecomingUnreadableRejectsLeaseAtOperationEntry() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let lease = try XCTUnwrap(authority.refresh())
        backend.inaccessible = true
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) { XCTFail("must not run") })
    }
    func testInitialUnavailableEvidenceCanRecoverButNeverReuseLease() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        journal.unavailable = true
        XCTAssertNil(try authority.refresh())
        journal.unavailable = false
        let lease = try XCTUnwrap(authority.refresh())
        backend.inaccessible = true
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        backend.inaccessible = false
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        XCTAssertNotNil(try authority.refresh())
    }
    func testSameFencedHistoryUnreadableKeyCanReclassifyWithNewLease() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend()
        journal.value = try history().fenced()
        backend.values[journal.value!.credentials[0].credentialReference] = Data(repeating: 9, count: 32)
        let authority = owner(journal, backend), lease = try XCTUnwrap(authority.refresh())
        backend.inaccessible = true
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        backend.inaccessible = false
        let recovered = try XCTUnwrap(authority.refresh())
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        try authority.withLocalAuthority(recovered) {}
    }
    func testJournalUncertaintyRevokesPreviouslyIssuedLease() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let lease = try XCTUnwrap(authority.refresh())
        journal.unavailable = true
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        XCTAssertNil(try authority.refresh())
    }
    func testReentrantCallsRejectWithoutInvalidatingCurrentOperation() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let lease = try XCTUnwrap(authority.refresh())
        try authority.withLocalAuthority(lease) {
            XCTAssertThrowsError(try authority.revoke()) { XCTAssertEqual($0 as? DeviceManagementAuthority.Failure, .reentrantOperation) }
            XCTAssertThrowsError(try authority.refresh())
            XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        }
        try authority.withLocalAuthority(lease) {}
    }
    func testRevocationWaitsForGatedOperationThenRejectsOldLease() throws {
        let authority = owner(AuthorityJournal(), AuthorityBackend())
        let lease = try XCTUnwrap(authority.refresh())
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let operationDone = expectation(description: "operation"), revoked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { operationDone.fulfill() }
            do { try authority.withLocalAuthority(lease) { entered.signal(); _ = release.wait(timeout: .now() + 3) } }
            catch { XCTFail("unexpected gate failure") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async { try? authority.revoke(); revoked.signal() }
        XCTAssertEqual(revoked.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        wait(for: [operationDone], timeout: 3)
        XCTAssertEqual(revoked.wait(timeout: .now() + 3), .success)
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
    }
    func testCloudFreshnessIsAnchoredAtRequestStartAndNeverExtendsForSlowResponse() {
        XCTAssertTrue(DeviceManagementAuthority.cloudStatusFresh(requestStartedAt: 100, now: 130))
        XCTAssertFalse(DeviceManagementAuthority.cloudStatusFresh(requestStartedAt: 100, now: 130.001))
        XCTAssertFalse(DeviceManagementAuthority.cloudStatusFresh(requestStartedAt: 100, now: 99))
        XCTAssertFalse(DeviceManagementAuthority.cloudStatusFresh(requestStartedAt: .nan, now: 100))
        XCTAssertFalse(DeviceManagementAuthority.cloudStatusFresh(requestStartedAt: 100, now: .infinity))
    }
    /// Explicit first-native fixture with the original owner and isolated real reset evidence.
    func testGenuineCloudContextRetiresOnResetEvidenceChangeAndCannotAdoptNewBaseline() async throws {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent("cloud-context-" + UUID().uuidString)
        let anchor = parent.appendingPathComponent("Application Support"), local = parent.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let resetDirectory = parent.appendingPathComponent("reset"), resetStore = DeviceLocalResetStore(directory: resetDirectory)
        let resetScope = try DeviceLocalResetScope(deviceRoot: local, preferencesRoot: parent.appendingPathComponent("preferences"), managementDirectory: parent.appendingPathComponent("management"), resetDirectory: resetDirectory, credentialItems: DeviceLocalResetScope.allowedCredentialItems)
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { XCTFail("No Keychain"); return Data() }),
            reset: DeviceLocalResetEvidenceAdapter(scope: resetScope, store: resetStore), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent))
        try authority.prepareProductionSupportAnchor(); try authority.enterCloudForeground()
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: UUID(), locationId: UUID(), name: "Fixture", profile: "Fixture")
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: claim.transitionId, credentialReference: "native." + UUID().uuidString, format: .nativeInstallationV1)
        let proposal = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage." + UUID().uuidString, binding: binding, claimInput: claim)
        let roots = try authority.prepareFreshCloudEnrollmentRoots(claim: claim)
        let protection = NativeManagedProtectedRoots(legacyState: local, legacyArchive: parent.appendingPathComponent("archive"),
            reset: resetDirectory, cloudEnrollment: roots.journalRoot, management: parent.appendingPathComponent("management"), preferences: parent.appendingPathComponent("preferences"))
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protection, grantTransport: FreshGrantTransport(rootID: roots.localIDs.grant))
        let session = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal, excludedLocalResetRoot: resetDirectory, storage: FreshCredentialStorage())
        let http = FreshOwnerHTTP(claim: claim); addTeardownBlock { http.close() }
        let result = try await session.enroll(origin: http.origin, tokenProvider: FreshOwnerTokens(), activationRequestID: http.activationRequestID,
            associationAttemptID: UUID(), stores: stores, configuration: http.configuration)
        let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: http.origin)
        // Real fixed status collector, same owner start and private observation; no direct receipt constructor grants admission.
        let request = try authority.prepareCloudStatusRequest(context)
        try authority.beginCloudStatusRequest(context, requestID: request.requestID)
        let observation = try await request.performFixedTransport(origin: http.origin, configuration: http.configuration)
        try authority.acceptCloudStatus(observation, context: context)
        XCTAssertNoThrow(try authority.validateCloudRequestStart(context))
        XCTAssertNoThrow(try authority.validateCloudRequestStart(context)) // unchanged actual absent record
        let pending = try DeviceLocalResetRecord(resetID: UUID(), scopeDigest: resetScope.digest)
        try resetStore.save(pending); try resetStore.save(pending.completed())
        XCTAssertThrowsError(try authority.validateCloudRequestStart(context))
        XCTAssertThrowsError(try authority.prepareCloudStatusRequest(context))
        XCTAssertThrowsError(try authority.acceptCloudStatus(observation, context: context))
        XCTAssertEqual(try resetStore.load(), try pending.completed()) // No baseline rewriting or cleanup side effect.
    }
    func testCloudForegroundEventsDoNotReadJournalsOrConstructCredentials() throws {
        let journal = AuthorityJournal(); journal.unavailable = true
        let backend = AuthorityBackend(); backend.inaccessible = true
        let authority = owner(journal, backend)
        XCTAssertNoThrow(try authority.enterCloudForeground())
        XCTAssertNoThrow(try authority.leaveCloudForeground())
        XCTAssertNoThrow(try authority.enterCloudForeground())
        XCTAssertNoThrow(try authority.revoke())
        XCTAssertTrue(backend.values.isEmpty)
    }

}

private final class AuthorityJournal: CloudInstallationTransitionJournal {
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
private final class AuthorityBackend: CloudInstallationCredentialBackend, @unchecked Sendable {
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

private struct AuthorityUnusedGrantBackend: DeviceGrantCredentialBackend {
    func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {}
    func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? { nil }
    func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem { throw DeviceGrantPreparationError.conflict }
}
private final class AuthorityPromotionBackend: NativeEnrollmentStageBackend, NativeEnrollmentPromotionBackend {
    private var items: [NativeEnrollmentRawCredentialItem] = [.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data("fixture-legacy".utf8), persistentReference: Data("legacy-ref".utf8), payload: Data(repeating: 1, count: 32))]
    func enumerateRaw(limit: Int) throws -> [NativeEnrollmentRawCredentialItem] { Array(items.prefix(limit)) }
    func readPersistentReference(_ ref: Data) throws -> NativeEnrollmentRawCredentialItem? { items.first { $0.persistentReference == ref } }
    func generate48() throws -> Data { Data(repeating: 42, count: 48) }
    func addStageOnce(account: Data, payload: Data) throws -> NativeEnrollmentStageAddResult {
        let ref = Data("stage-ref".utf8); items.append(.init(service: Data(NativeEnrollmentStageEnvelope.service.utf8), account: account, persistentReference: ref, payload: payload)); return .added(ref)
    }
    func addFinalOnce(account: Data, raw48: Data) throws -> NativeEnrollmentPromotionAddResult {
        let ref = Data("final-ref".utf8); items.append(.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: account, persistentReference: ref, payload: raw48)); return .added(ref)
    }
}
private final class AuthorityPromotionHTTP {
    struct Provider: CloudNativeTokenProvider { func idToken() async throws -> String { "synthetic-human-token" } }
    final class Interceptor: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var fixtures: [String: AuthorityPromotionHTTP] = [:]
        static func register(_ f: AuthorityPromotionHTTP) { lock.lock(); defer { lock.unlock() }; fixtures[f.origin.host!] = f }
        static func remove(_ f: AuthorityPromotionHTTP) { lock.lock(); defer { lock.unlock() }; fixtures.removeValue(forKey: f.origin.host!) }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let host = request.url?.host
            Self.lock.lock(); let fixture = host.flatMap { Self.fixtures[$0] }; Self.lock.unlock()
            do {
                guard let fixture else { throw NativeEnrollmentPromotionError.blocked }
                let data = try fixture.reply(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"] )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
    let origin = URL(string: "https://" + UUID().uuidString.lowercased() + ".fixture.test")!
    let input: NativeClaimInput, installationID = UUID(), challengeID = UUID(), generationID = UUID(), remoteID = UUID()
    init(_ input: NativeClaimInput) { self.input = input; Interceptor.register(self) }
    func close() { Interceptor.remove(self) }
    var configuration: URLSessionConfiguration { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Interceptor.self]; return c }
    func activation() throws -> NativeActivationReceipt {
        try .init(installationId: installationID, deviceId: installationID, requestId: remoteID, accountId: input.accountId, locationId: input.locationId,
            transitionId: input.transitionId, activatedAt: "2026-01-01T00:00:00Z", initialGeneration: .init(generationId: generationID,
                createdAt: "2026-01-01T00:00:00Z", renewAfter: "2026-01-31T00:00:00Z", expiresAt: "2026-04-01T00:00:00Z"))
    }
    private func reply(_ request: URLRequest) throws -> Data {
        guard request.httpShouldHandleCookies == false else { throw NativeEnrollmentPromotionError.blocked }
        switch (request.httpMethod, request.url?.path) {
        case ("POST", "/v1/native/installations/claims"):
            return try nativeEnrollmentBytes(NativeClaimReceipt(installationId: installationID, requestId: input.requestId, transitionId: input.transitionId,
                challengeId: challengeID, accountId: input.accountId, locationId: input.locationId,
                createdAt: "2026-01-01T00:00:00Z", expiresAt: "2026-01-01T00:10:00Z", outcome: .pending))
        case ("POST", "/v1/native/installations/activate"): return try nativeEnrollmentBytes(activation())
        case ("GET", "/v1/native/installations/status"):
            let a = try activation()
            let value: [String: Any] = ["kind": "current-generation", "installationId": installationID.uuidString, "accountId": input.accountId.uuidString,
                "locationId": input.locationId.uuidString, "transitionId": input.transitionId.uuidString,
                "generation": try JSONSerialization.jsonObject(with: nativeEnrollmentBytes(a.initialGeneration)),
                "activation": try JSONSerialization.jsonObject(with: nativeEnrollmentBytes(a)), "credential": "current", "authority": "active"]
            return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        default: throw NativeEnrollmentPromotionError.blocked
        }
    }
}

private struct FreshOwnerTokens: CloudNativeTokenProvider { func idToken() async throws -> String { "synthetic-human-token" } }
private final class FreshGrantTransport: DeviceGrantCredentialTransport, @unchecked Sendable {
    let rootID: UUID
    private var values: [String: DeviceGrantCredentialTransportSecret] = [:]
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
        values[account] = try .init(observation: observation, bytes: bytes); return observation
    }
}
private final class FreshCredentialStorage: NativeEnrollmentCredentialStorage {
    private var items: [Data: NativeEnrollmentStoredCredential] = [:]
    private(set) var adds = 0
    private(set) var reads = 0
    func enumerateBounded(maximum: Int) throws -> [NativeEnrollmentStoredCredential] { Array(items.values) }
    func generateOriginal48() throws -> Data { Data(repeating: 17, count: 48) }
    func readExactPersistentReference(_ reference: Data) throws -> NativeEnrollmentStoredCredential? { reads += 1; return items[reference] }
    private func add(service: String, account: Data, payload: Data) -> NativeEnrollmentCredentialInsert {
        adds += 1; let ref = Data("fixture-ref-\(adds)".utf8)
        items[ref] = .init(service: Data(service.utf8), account: account, persistentReference: ref, payload: payload, accessible: true)
        return .inserted(ref)
    }
    func insertStageOnly(account: Data, envelope: Data) throws -> NativeEnrollmentCredentialInsert { add(service: "xyz.screenpunk.installation.cloud.enrollment-stage.v1", account: account, payload: envelope) }
    func insertFinalOnly(account: Data, original48: Data) throws -> NativeEnrollmentCredentialInsert { add(service: "xyz.screenpunk.installation.cloud", account: account, payload: original48) }
}
private final class FreshOwnerHTTP {
    let claim: NativeClaimInput
    var delivery: AuthorityStaticDeliveryFixture.Value?
    var deliveryPaths: [String] = []
    var requestCount = 0
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
        if let path = request.url?.path, path.hasPrefix("/v1/native/installations/delivery/") {
            deliveryPaths.append(path)
            guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true else { throw CancellationError() }
            if request.httpMethod == "GET", let delivery {
                if path == "/v1/native/installations/delivery/command" {
                    return Data("{\"command\":".utf8) + delivery.command + Data(",\"nextCheckSeconds\":5}".utf8)
                }
                if path.hasPrefix("/v1/native/installations/delivery/plan/") { return delivery.plan }
                if path.hasPrefix("/v1/native/installations/delivery/package/") { return delivery.archive.archiveBytes }
            }
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true,
                let bytes = try requestBytes(request, limit: 16384), var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CancellationError() }
            if request.url?.path == "/v1/native/installations/delivery/state" {
                object = ["installationId": try XCTUnwrap(object["installationId"]), "transitionId": try XCTUnwrap(object["transitionId"]),
                    "generationId": try XCTUnwrap(object["generationId"]), "accepted": true]
            } else if request.url?.path == "/v1/native/installations/delivery/activation" {
                object["authorizationDigest"] = String(repeating: "a", count: 64)
                object["authorizedAt"] = "2026-10-05T20:00:00Z"; object["expiresAt"] = "2026-10-05T20:00:30Z"
            } else if request.url?.path == "/v1/native/installations/delivery/receipt" {
                for key in ["activationRequestId", "authorizationDigest", "previousGenerationId", "resultingGenerationId", "renderState"] { object.removeValue(forKey: key) }
                object["receiptId"] = UUID().uuidString.lowercased(); object["receivedAt"] = "2026-10-05T20:00:31Z"
            } else { throw CancellationError() }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }

        if request.url?.path == "/v1/native/installations/status" {
            guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer spni1_") == true else { throw CancellationError() }
            let receipt = try activation(), activation = try JSONSerialization.jsonObject(with: nativeEnrollmentBytes(receipt))
            let generation = try JSONSerialization.jsonObject(with: nativeEnrollmentBytes(receipt.initialGeneration))
            return try JSONSerialization.data(withJSONObject: ["kind":"current-generation", "installationId":installationID.uuidString, "accountId":claim.accountId.uuidString,
                "locationId":claim.locationId.uuidString, "transitionId":claim.transitionId.uuidString, "generation":generation, "activation":activation, "credential":"current", "authority":"active"])
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
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
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
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
}

private enum AuthorityStaticDeliveryFixture {
    struct Value { let command: Data, header: String, plan: Data, archive: NativeDeliveryArchiveInput }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(value)
    }
    static func make(state: [String: Any], activation: NativeActivationReceipt) throws -> Value {
        let html = Data("<html><body>Genuine static fixture</body></html>".utf8)
        let dashboard = UUID(), revision = UUID(), entry = UUID(), package = UUID()
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: dashboard.uuidString.lowercased(), name: "Fixture",
            revision: revision.uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "Fixture", width: 390, height: 844, scale: 3, orientation: "portrait"), connections: [],
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
            "locationId": activation.locationId.uuidString.lowercased(), "transitionId": try XCTUnwrap(state["transitionId"]),
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
