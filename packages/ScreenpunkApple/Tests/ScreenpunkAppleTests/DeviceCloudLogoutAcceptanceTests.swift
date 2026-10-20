import XCTest
import Foundation
@_spi(ManagedRender) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple

/// Uses real native HTTP receipts, production Authority fences, and complete Local
/// package/grant/provisioning qualification. The only substituted boundary is storage/HTTP.
@MainActor final class DeviceCloudLogoutAcceptanceTests: XCTestCase {
    func testConfirmedLogoutHalfCleanupRestartAndFreshLoginPreserveUsableLocalContent() async throws {
        let entryID = UUID(), pairing = PairingIdentityFactory.make(role: .controller)
        var retainedLocal: DeviceLegacyMigrationSession?
        var localNamespace: URL?
        var retainedLocalGrants: FreshGrantTransport?
        let fixture = try await GenuineUnifiedInventoryFixture.make { authority, parent in
            let lease = try XCTUnwrap(authority.refresh())
            let ids = try NativeManagedLocalRootIDs(package: UUID(), grant: UUID(), structural: UUID(), provisioning: UUID(), contentGenesis: UUID())
            let roots = try authority.prepareLocalInventoryRoots(lease: lease, ids: ids)
            localNamespace = roots.namespace
            let localGrants = FreshGrantTransport(rootID: ids.grant)
            retainedLocalGrants = localGrants
            let local = try DeviceLegacyMigrationSession(packageRoot: roots.packageRoot, packageRootID: ids.package,
                grantRoot: roots.grantRoot, grantRootID: ids.grant, structuralRoot: roots.structuralRoot, structuralRootID: ids.structural,
                provisioningRoot: roots.provisioningRoot, provisioningRootID: ids.provisioning,
                legacyStateRoot: parent.appendingPathComponent("legacy-state"), legacyArchiveRoot: parent.appendingPathComponent("legacy-archive"),
                resetRoot: parent.appendingPathComponent("reset"), cloudRoot: parent.appendingPathComponent("Application Support/xyz.screenpunk.native-managed"),
                managementRoot: parent.appendingPathComponent("management"), preferencesRoot: parent.appendingPathComponent("preferences"),
                otherProtectedRoots: [], credentialTransport: localGrants,
                validateRoots: { try authority.validateLocalInventoryRoots(roots) })
            let screen = try Self.localScreen(entryID: entryID)
            try local.prepareAndCommit(screens: [screen], selected: entryID, owner: pairing,
                profile: .init(deviceId: "local-fixture", name: "Local"), profileID: "Fixture",
                operationID: UUID(), grantOperationID: UUID(), generationID: UUID(), grantRevisionID: UUID(),
                legacyGrantSet: nil, validateOriginal: { try authority.validateLocalInventoryRoots(roots) })
            retainedLocal = local
            return local
        }
        defer { fixture.close() }
        let local = try XCTUnwrap(retainedLocal), localRoot = try XCTUnwrap(localNamespace)
        let localBytes = try Self.files(localRoot)
        let localGrants = try XCTUnwrap(retainedLocalGrants)
        let localGrantCredentials = try localGrants.exactCredentialsForLogoutAcceptance()
        let cleanupProbe = LogoutAcceptanceCredentialProbe(native: fixture.storage, grants: fixture.nativeGrants)
        let original = try fixture.common.validatedAssociation()
        XCTAssertTrue(original.entries.contains { $0.entryID == entryID && $0.provenance == "retainedLocal" })
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        XCTAssertNil(try DeviceUnifiedInventorySession.peekDetachedMetadata(commonRoot: candidate.commonRoot, commonRootID: fixture.commonID), "Accepted intent alone must never claim confirmed logout")
        let request = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await request.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        let localContext = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        XCTAssertNoThrow(try localContext.validate())
        XCTAssertThrowsError(try fixture.authority.prepareCurrentInstallationDispatch(fixture.context))
        let detachedAssociation = try detached.detachedAssociation()
        XCTAssertEqual(detachedAssociation.metadata.retiredTransitionID, fixture.activation.transitionId)
        try detachedAssociation.validateCloudCleanupScope(namespace: retirement.namespaceURL)
        XCTAssertEqual(try detached.selectedContent(operationID: UUID()).entryID, entryID)
        XCTAssertEqual(try Self.files(localRoot), localBytes, "Detach retains the exact Local owner, grant and provisioning records")

        // Model process death after the first exact Keychain delete. No cleanup
        // capability can be minted while the second captured item remains.
        let nativeCredentials = retirement.credentials.filter { $0.service == "xyz.screenpunk.installation.cloud" || $0.service == "xyz.screenpunk.installation.cloud.enrollment-stage.v1" }
        let nativeGrantCredentials = retirement.credentials.filter { $0.service == DeviceGrantCredentialNamespace(rootID: fixture.nativeGrants.rootID).service }
        XCTAssertEqual(nativeCredentials.count, 2)
        XCTAssertEqual(nativeGrantCredentials, try fixture.nativeGrants.exactCredentialsForLogoutAcceptance())
        XCTAssertEqual(nativeGrantCredentials.count, 1, "The genuine completed static delivery owns its native grant credential")
        XCTAssertEqual(retirement.credentials.count, nativeCredentials.count + nativeGrantCredentials.count)
        XCTAssertTrue(retirement.credentials.allSatisfy { !localGrantCredentials.contains($0) })
        try fixture.storage.removeCloudCredentialExact(try XCTUnwrap(nativeCredentials.first))
        try FileManager.default.removeItem(at: retirement.namespaceURL)
        XCTAssertThrowsError(try retirement.confirmCleanup(namespace: retirement.namespaceURL, probe: cleanupProbe))
        let coldAuthority = try Self.authority(parent: fixture.parent)
        let metadata = try XCTUnwrap(DeviceUnifiedInventorySession.peekDetachedMetadata(commonRoot: candidate.commonRoot, commonRootID: fixture.commonID))
        XCTAssertFalse(metadata.cleanupCompleted)
        let coldCandidate = try coldAuthority.prepareDetachedLocalRestore(commonRootID: fixture.commonID, retiredInstallationID: metadata.retiredInstallationID)
        let reopened = try DeviceUnifiedInventorySession.restoreDetached(local: local, commonRoot: candidate.commonRoot, commonRootID: fixture.commonID,
            validateOriginal: { try coldAuthority.validateDetachedLocalResources(coldCandidate) },
            validateMutation: { try coldAuthority.validateDetachedLocalResources(coldCandidate) })
        let coldLocalContext = try coldAuthority.acceptDetachedLocalSession(reopened, context: coldCandidate)
        XCTAssertNoThrow(try coldLocalContext.validate())
        XCTAssertEqual(try reopened.selectedContent(operationID: UUID()).entryID, entryID)
        let restoredRetirement = try reopened.detachedAssociation().credentialRetirement()
        XCTAssertEqual(restoredRetirement.credentials, retirement.credentials)
        for credential in nativeCredentials { try fixture.storage.removeCloudCredentialExact(credential) }
        XCTAssertThrowsError(try restoredRetirement.confirmCleanup(namespace: restoredRetirement.namespaceURL, probe: cleanupProbe), "Remaining native grant denies cleanup completion even after both native installation items are absent")
        for credential in nativeGrantCredentials { try fixture.nativeGrants.removeCloudCredentialExact(credential) }
        XCTAssertEqual(try localGrants.exactCredentialsForLogoutAcceptance(), localGrantCredentials)
        let cleanup = try restoredRetirement.confirmCleanup(namespace: restoredRetirement.namespaceURL, probe: cleanupProbe)
        try reopened.finishCloudDetachCleanup(receipt: cleanup, operationID: UUID(), generationID: UUID())
        XCTAssertTrue(try reopened.detachedAssociation().metadata.cleanupCompleted)
        XCTAssertEqual(try Self.files(localRoot), localBytes)
        let networkBefore = fixture.http.requestCount
        let next = try await Self.enrollAfterDetach(authority: coldAuthority, detached: reopened,
            candidate: coldCandidate, parent: fixture.parent, storage: fixture.storage)
        defer { next.http.close() }
        XCTAssertNotEqual(next.installationID, fixture.activation.installationId)
        XCTAssertEqual(try next.session.selectedContent(operationID: UUID()).entryID, entryID)
        XCTAssertEqual(try next.session.validatedAssociation().configuredEntryID, entryID)
        XCTAssertEqual(try Self.files(localRoot), localBytes, "Fresh Cloud generation must preserve Local pairing and credential bindings byte for byte")
        XCTAssertEqual(try localGrants.exactCredentialsForLogoutAcceptance(), localGrantCredentials)
        XCTAssertEqual(fixture.http.requestCount, networkBefore, "Fresh login never reuses the retired installation")
        // An ordinary device-only status reconnect uses the accepted installation;
        // no token provider or human-session continuation is involved.
        let status = try coldAuthority.prepareCloudStatusRequest(next.context)
        try coldAuthority.beginCloudStatusRequest(next.context, requestID: status.requestID)
        try coldAuthority.acceptCloudStatus(await status.performFixedTransport(origin: next.http.origin, configuration: next.http.configuration), context: next.context)
        XCTAssertNoThrow(try coldAuthority.prepareCurrentInstallationDispatch(next.context))
        XCTAssertEqual(try next.session.selectedContent(operationID: UUID()).entryID, entryID)
    }

    private static func authority(parent: URL) throws -> DeviceManagementAuthority {
        DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: parent.appendingPathComponent("Application Support")),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent), commandIntents: .init(root: parent.appendingPathComponent("command-intents")), concurrentControlQualified: true)
    }
    private static func localScreen(entryID: UUID) throws -> DeviceLegacyMigrationScreen {
        let html = Data("<html><body>Retained paired Local screen</body></html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString.lowercased(), name: "Retained Local",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "Fixture", width: 390, height: 844, scale: 3, orientation: "portrait"), connections: [],
            files: [.init(path: "index.html", bytes: html.count, sha256: PeerPin.hex(PeerPin.sha256(html)))])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        manifest.digest = PeerPin.hex(PeerPin.sha256(try encoder.encode(manifest)))
        let revision = StoredRevision(revision: manifest.revision, dashboardId: manifest.dashboardId, name: manifest.name,
            digest: try XCTUnwrap(manifest.digest), orientation: .portrait, width: 390, height: 844)
        return .init(entryID: entryID, packageOperationID: UUID(), displayName: "Retained Local", revision: revision,
            manifest: try encoder.encode(manifest), files: ["index.html": html], homeAssistant: nil, generic: nil, publicReads: nil)
    }
    private static func files(_ root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        while let url = enumerator.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }
    private static func enrollAfterDetach(authority: DeviceManagementAuthority, detached: DeviceUnifiedInventorySession,
        candidate: DeviceManagementAuthority.DetachedLocalContext, parent: URL, storage: FreshCredentialStorage) async throws
        -> (session: DeviceUnifiedInventorySession, context: DeviceManagementAuthority.CloudInstallationContext, installationID: UUID, http: FreshOwnerHTTP) {
        try authority.enterCloudForeground()
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: UUID(), locationId: nil, name: "Fresh login", profile: "Fixture")
        let ids = try NativeManagedLocalRootIDs(package: UUID(), grant: UUID(), structural: UUID(), provisioning: UUID(), contentGenesis: UUID())
        let roots = try authority.prepareCloudEnrollmentAfterDetach(context: candidate, association: detached.detachedAssociation(),
            claim: claim, cloudRootID: UUID(), localIDs: ids)
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: claim.transitionId,
            credentialReference: "native." + UUID().uuidString.lowercased(), format: .nativeInstallationV1)
        let proposal = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage." + UUID().uuidString.lowercased(), binding: binding, claimInput: claim)
        let protected = NativeManagedProtectedRoots(legacyState: parent.appendingPathComponent("local"), legacyArchive: parent.appendingPathComponent("archive"),
            reset: parent.appendingPathComponent("reset"), cloudEnrollment: roots.journalRoot, management: parent.appendingPathComponent("management"), preferences: parent.appendingPathComponent("preferences"))
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protected, grantTransport: FreshGrantTransport(rootID: ids.grant))
        let enrollment = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal, excludedLocalResetRoot: protected.reset, storage: storage)
        let http = FreshOwnerHTTP(claim: claim)
        var succeeded = false; defer { if !succeeded { http.close() } }
        let result = try await enrollment.enroll(origin: http.origin, tokenProvider: FreshOwnerTokens(), activationRequestID: http.activationRequestID,
            associationAttemptID: UUID(), stores: stores, configuration: http.configuration)
        let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: http.origin)
        let status = try authority.prepareCloudStatusRequest(context)
        try authority.beginCloudStatusRequest(context, requestID: status.requestID)
        try authority.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration), context: context)
        let current = try authority.prepareCurrentInstallationDispatch(context)
        let native = try result.installation.makeDeliveryExecutionSession(current: current)
        let attached = try authority.reattachCloudInventory(detached: detached, detachedContext: candidate, context: context,
            native: native, current: current, operationID: UUID(), generationID: UUID())
        succeeded = true
        return (attached, context, result.activation.installationId, http)
    }
}
