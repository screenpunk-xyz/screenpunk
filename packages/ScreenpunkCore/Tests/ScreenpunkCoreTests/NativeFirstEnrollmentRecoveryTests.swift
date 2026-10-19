import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore

final class NativeFirstEnrollmentRecoveryTests: XCTestCase {
    func testOldPartialStoreBindingsSurviveAdapterRetryAndSessionRestart() async throws {
        let f = try Fixture(); defer { f.close() }
        // Reproduce the old production ordering, with genuine durable stores.
        let packages = DevicePackagePreparationStore(root: f.child("packages"), rootID: f.ids.package, protectedScope: f.scope)
        let grants = DeviceNativeGrantPreparationStore(root: f.child("grants"), rootID: f.ids.grant, protectedPaths: f.scope.roots,
            backend: try DeviceGrantCredentialTransportBackend(rootID: f.ids.grant, transport: f.grants))
        let structural = DeviceStructuralStore(root: f.child("structural"), rootID: f.ids.structural)
        try packages.initializeExplicit(); try grants.initializeExplicit(); try structural.initializeExplicit()
        let invalid = DeviceLocalProvisioningIntentStore(root: f.child("provisioning"), rootID: f.ids.provisioning, protectedRoots: f.scope.roots)
        XCTAssertThrowsError(try invalid.initializeExplicit()) { error in
            guard case DeviceLocalProvisioningIntentStore.Failure.unsafeRoot = error else { return XCTFail("Expected original duplicate-root failure") }
        }
        let packageBytes = try Data(contentsOf: f.child("packages").appendingPathComponent("root-binding.json"))
        let grantBytes = try Data(contentsOf: f.child("grants").appendingPathComponent("root-binding.json"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.journal.path).isEmpty)
        XCTAssertEqual(f.storage.items.count, 0)
        // A newly constructed session/store adapter models process restart.
        let session = try f.session(), stores = try f.stores()
        let result = try await session.resumeRetainedOriginal(origin: f.http.origin, tokenProvider: PromotionHTTPFixture.Provider(),
            activationRequestID: f.http.activationRequestID, associationAttemptID: f.http.associationAttemptID,
            stores: stores, configuration: f.http.configuration)
        XCTAssertEqual(result.activation.requestId, f.http.activationRequestID)
        XCTAssertEqual(result.activation.transitionId, f.proposal.claimInput.transitionId)
        XCTAssertEqual(result.activation.accountId, f.proposal.claimInput.accountId)
        XCTAssertNil(result.activation.locationId)
        XCTAssertEqual(try Data(contentsOf: f.child("packages").appendingPathComponent("root-binding.json")), packageBytes)
        XCTAssertEqual(try Data(contentsOf: f.child("grants").appendingPathComponent("root-binding.json")), grantBytes)
        XCTAssertEqual(f.http.claims, 1); XCTAssertEqual(f.http.activations, 1)
        XCTAssertEqual(f.storage.stageAdds, 1); XCTAssertEqual(f.storage.finalAdds, 1)
        // Retrying the same completed operation restores it without new cloud quota or credentials.
        _ = try await f.session().resumeRetainedOriginal(origin: f.http.origin, tokenProvider: PromotionHTTPFixture.Provider(),
            activationRequestID: f.http.activationRequestID, associationAttemptID: f.http.associationAttemptID,
            stores: f.stores(), configuration: f.http.configuration)
        XCTAssertEqual(f.http.claims, 1); XCTAssertEqual(f.http.activations, 1)
        XCTAssertEqual(f.storage.stageAdds, 1); XCTAssertEqual(f.storage.finalAdds, 1)
        // Skipping ordinary structural initialization does not admit changed native evidence.
        let proof = f.child("structural").appendingPathComponent("native-genesis.confirm")
        let corrupt = Data("changed-native-genesis-proof".utf8)
        try corrupt.write(to: proof)
        do {
            _ = try await f.session().resumeRetainedOriginal(origin: f.http.origin, tokenProvider: PromotionHTTPFixture.Provider(),
                activationRequestID: f.http.activationRequestID, associationAttemptID: f.http.associationAttemptID,
                stores: f.stores(), configuration: f.http.configuration)
            XCTFail("Changed native genesis must remain blocked")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: proof), corrupt)
        XCTAssertEqual(f.http.claims, 1); XCTAssertEqual(f.http.activations, 1)
        XCTAssertEqual(f.storage.stageAdds, 1); XCTAssertEqual(f.storage.finalAdds, 1)
    }
    func testAdapterDeduplicatesOnlyExactLegacyAliasAndKeepsOtherGuards() throws {
        let f = try Fixture(); defer { f.close() }
        let corrected = NativeFirstManagedStores.provisioningProtection(f.scope)
        XCTAssertEqual(corrected.count, f.scope.roots.count - 1)
        XCTAssertEqual(corrected.first, f.scope.legacyStateRoot)
        XCTAssertEqual(Array(corrected.dropFirst()), Array(f.scope.roots.dropFirst(2)))
        let distinct = DevicePackageProtectedScope(legacyStateRoot: f.scope.legacyStateRoot,
            legacyArchiveRoot: f.scope.legacyStateRoot.appendingPathComponent("archives"), resetRoot: f.scope.resetRoot,
            cloudRoot: f.scope.cloudRoot, managementRoot: f.scope.managementRoot, preferencesRoot: f.scope.preferencesRoot, otherProtectedRoots: [])
        XCTAssertEqual(NativeFirstManagedStores.provisioningProtection(distinct), distinct.roots)
        let duplicateOther = DevicePackageProtectedScope(legacyStateRoot: f.scope.legacyStateRoot, legacyArchiveRoot: f.scope.legacyArchiveRoot,
            resetRoot: f.scope.resetRoot, cloudRoot: f.scope.cloudRoot, managementRoot: f.scope.managementRoot,
            preferencesRoot: f.scope.resetRoot, otherProtectedRoots: [])
        let store = DeviceLocalProvisioningIntentStore(root: f.child("provisioning"), rootID: f.ids.provisioning,
            protectedRoots: NativeFirstManagedStores.provisioningProtection(duplicateOther))
        XCTAssertThrowsError(try store.initializeExplicit())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.child("provisioning").path).isEmpty)
    }
    func testEmptyJournalCannotRestartWithAnyInstallationCredential() async throws {
        let f = try Fixture(); defer { f.close() }
        f.storage.items.append(.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data("retained-final".utf8),
            persistentReference: Data([99]), payload: Data(repeating: 1, count: 48), accessible: true))
        do {
            _ = try await f.session().resumeRetainedOriginal(origin: f.http.origin, tokenProvider: PromotionHTTPFixture.Provider(),
                activationRequestID: f.http.activationRequestID, associationAttemptID: f.http.associationAttemptID, stores: f.stores(), configuration: f.http.configuration)
            XCTFail("An empty journal cannot adopt an existing credential")
        } catch {}
        XCTAssertEqual(f.http.claims, 0); XCTAssertEqual(f.storage.stageAdds, 0); XCTAssertEqual(f.storage.finalAdds, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.journal.path).isEmpty)
    }
    func testPartialOrUnknownJournalCannotBecomeEmptyEnrollment() async throws {
        for leaf in ["root-binding.json", "root-binding.json.stage", "unknown"] {
            let f = try Fixture(); defer { f.close() }
            let bytes = Data("preserve-unknown-original".utf8)
            try bytes.write(to: f.journal.appendingPathComponent(leaf))
            do {
                _ = try await f.session().resumeRetainedOriginal(origin: f.http.origin, tokenProvider: PromotionHTTPFixture.Provider(),
                    activationRequestID: f.http.activationRequestID, associationAttemptID: f.http.associationAttemptID, stores: f.stores(), configuration: f.http.configuration)
                XCTFail("Nonempty journal must keep strict replay")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: f.journal.appendingPathComponent(leaf)), bytes)
            XCTAssertEqual(f.http.claims, 0); XCTAssertEqual(f.storage.stageAdds, 0); XCTAssertEqual(f.storage.finalAdds, 0)
        }
    }
    func testRevokedPhysicalOwnerCannotStartAbsentJournalRecovery() async throws {
        let f = try Fixture(); defer { f.close() }
        let session = try f.session(), stores = try f.stores()
        f.owner.revoked = true
        do {
            _ = try await session.resumeRetainedOriginal(origin: f.http.origin, tokenProvider: PromotionHTTPFixture.Provider(),
                activationRequestID: f.http.activationRequestID, associationAttemptID: f.http.associationAttemptID, stores: stores, configuration: f.http.configuration)
            XCTFail("Current physical owner proof is mandatory")
        } catch {}
        XCTAssertEqual(f.http.claims, 0); XCTAssertEqual(f.storage.stageAdds, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.journal.path).isEmpty)
    }

    #if os(iOS)
    func testPhysicalAppHomeEmptyJournalRetryInitializesEveryManagedStoreBeforeHTTP() async throws {
        let f = try Fixture(); defer { f.close() }
        let journal = NativeEnrollmentJournalStore(root: f.journal, cloudRootID: f.cloudRootID, excludedLocalResetRoot: f.scope.resetRoot)
        let structural = DeviceStructuralStore(root: f.child("structural"), rootID: f.ids.structural)
        XCTAssertEqual(journal.root.path, f.journal.path)
        XCTAssertEqual(structural.root.path, f.child("structural").path)
        XCTAssertTrue(try journal.isExactlyEmptyFirstNativeRoot())
        // Model Dev11 stopping after some/all managed stores were initialized,
        // while the retained enrollment journal remains exactly empty.
        try DevicePackagePreparationStore(root: f.child("packages"), rootID: f.ids.package, protectedScope: f.scope).initializeExplicit()
        try DeviceNativeGrantPreparationStore(root: f.child("grants"), rootID: f.ids.grant, protectedPaths: f.scope.roots,
            backend: DeviceGrantCredentialTransportBackend(rootID: f.ids.grant, transport: f.grants)).initializeExplicit()
        try structural.initializeExplicit()
        try DeviceLocalProvisioningIntentStore(root: f.child("provisioning"), rootID: f.ids.provisioning,
            protectedRoots: NativeFirstManagedStores.provisioningProtection(f.scope)).initializeExplicit()
        let originalBindings = try DeviceNativeManagedRootLocator.futureChildNames.map {
            try Data(contentsOf: f.child($0).appendingPathComponent("root-binding.json"))
        }
        XCTAssertTrue(try journal.isExactlyEmptyFirstNativeRoot())
        let result = try await f.session().resumeRetainedOriginal(origin: f.http.origin, tokenProvider: PromotionHTTPFixture.Provider(),
            activationRequestID: f.http.activationRequestID, associationAttemptID: f.http.associationAttemptID,
            stores: f.stores(), configuration: f.http.configuration)
        XCTAssertEqual(result.activation.requestId, f.http.activationRequestID)
        for child in DeviceNativeManagedRootLocator.futureChildNames + ["enrollment"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.child(child).appendingPathComponent("root-binding.json").path))
        }
        for (child, bytes) in zip(DeviceNativeManagedRootLocator.futureChildNames, originalBindings) {
            XCTAssertEqual(try Data(contentsOf: f.child(child).appendingPathComponent("root-binding.json")), bytes)
        }
        XCTAssertEqual(f.http.claims, 1); XCTAssertEqual(f.http.activations, 1)
        XCTAssertEqual(f.storage.stageAdds, 1); XCTAssertEqual(f.storage.finalAdds, 1)
    }
    func testPhysicalAppHomeStructuralAndJournalRejectAliasesAndRootReplacement() throws {
        let f = try Fixture(); defer { f.close() }
        for (leaf, isJournal) in [("structural", false), ("enrollment", true)] {
            let root = f.child(leaf), alias = f.parent.appendingPathComponent(leaf + "-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            if isJournal {
                let store = NativeEnrollmentJournalStore(root: alias, cloudRootID: f.cloudRootID, excludedLocalResetRoot: f.scope.resetRoot)
                XCTAssertThrowsError(try store.isExactlyEmptyFirstNativeRoot())
                XCTAssertThrowsError(try store.initializeFirstNativeExplicit())
            } else {
                XCTAssertThrowsError(try DeviceStructuralStore(root: alias, rootID: f.ids.structural).initializeExplicit())
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
        let structural = DeviceStructuralStore(root: f.child("structural"), rootID: f.ids.structural)
        try structural.initializeExplicit()
        let retained = f.parent.appendingPathComponent("retained-structural")
        try FileManager.default.moveItem(at: structural.root, to: retained)
        try FileManager.default.createSymbolicLink(at: structural.root, withDestinationURL: retained)
        XCTAssertThrowsError(try structural.initializeExplicit())
        let journal = NativeEnrollmentJournalStore(root: f.journal, cloudRootID: f.cloudRootID, excludedLocalResetRoot: f.scope.resetRoot)
        _ = try journal.initializeFirstNativeExplicit()
        let held = f.parent.appendingPathComponent("retained-journal")
        try FileManager.default.moveItem(at: f.journal, to: held)
        try FileManager.default.createSymbolicLink(at: f.journal, withDestinationURL: held)
        XCTAssertThrowsError(try journal.isExactlyEmptyFirstNativeRoot())
        XCTAssertThrowsError(try journal.initializeFirstNativeExplicit())
    }
    func testLiveOSHomeBindingsResumeRecordedIntentWithoutRewritingBindingsOrFrames() async throws {
        let f = try Fixture(); defer { f.close() }
        guard let raw = realpath(NSHomeDirectory(), nil) else { throw NativeEnrollmentPromotionError.blocked }
        let physicalHome = String(cString: raw); free(raw)
        let systemHome = NSHomeDirectory()
        try DeviceStructuralStore(root: f.child("structural"), rootID: f.ids.structural).initializeExplicit()
        let journal = NativeEnrollmentJournalStore(root: f.journal, cloudRootID: f.cloudRootID, excludedLocalResetRoot: f.scope.resetRoot)
        _ = try journal.initializeFirstNativeExplicit()
        var originalBindings: [String: Data] = [:]
        for child in ["structural", "enrollment"] {
            let root = f.child(child), file = root.appendingPathComponent("root-binding.json")
            XCTAssertTrue(root.path.hasPrefix(physicalHome + "/"))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["canonicalPath"] = systemHome + String(root.path.dropFirst(physicalHome.count))
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            if child == "enrollment" { _ = try NativeJournalCodec.binding(bytes) }
            try bytes.write(to: file); originalBindings[child] = bytes
        }
        // This records a genuine prior first-native intent against the retained
        // binding. It does not import/adopt an unbound root or manufacture absence.
        _ = try journal.initializeFirstNativeExplicit()
        _ = try journal.prepareFirstNativePromotionIntent(NativeEnrollmentPreparationCodec.encodeFirstNativeProposal(f.proposal), attemptID: UUID())
        let framesRoot = f.journal.appendingPathComponent("frames")
        let originalFrames = try FileManager.default.contentsOfDirectory(atPath: framesRoot.path).map { name in
            (name, try Data(contentsOf: framesRoot.appendingPathComponent(name)))
        }
        XCTAssertFalse(originalFrames.isEmpty)
        let result = try await f.session().resumeRetainedOriginal(origin: f.http.origin, tokenProvider: PromotionHTTPFixture.Provider(),
            activationRequestID: f.http.activationRequestID, associationAttemptID: f.http.associationAttemptID,
            stores: f.stores(), configuration: f.http.configuration)
        XCTAssertEqual(result.activation.requestId, f.http.activationRequestID)
        XCTAssertEqual(result.activation.transitionId, f.proposal.claimInput.transitionId)
        XCTAssertEqual(result.activation.accountId, f.proposal.claimInput.accountId)
        _ = try await f.session().resumeRetainedOriginal(origin: f.http.origin, tokenProvider: PromotionHTTPFixture.Provider(),
            activationRequestID: f.http.activationRequestID, associationAttemptID: f.http.associationAttemptID,
            stores: f.stores(), configuration: f.http.configuration)
        for (child, bytes) in originalBindings {
            XCTAssertEqual(try Data(contentsOf: f.child(child).appendingPathComponent("root-binding.json")), bytes)
        }
        for (name, bytes) in originalFrames { XCTAssertEqual(try Data(contentsOf: framesRoot.appendingPathComponent(name)), bytes) }
        XCTAssertEqual(f.http.claims, 1); XCTAssertEqual(f.http.activations, 1)
        XCTAssertEqual(f.storage.stageAdds, 1); XCTAssertEqual(f.storage.finalAdds, 1)
    }
    func testLiveOSHomeSpellingDoesNotAdmitChangedBindingIDsOrInodes() throws {
        for child in ["structural", "enrollment"] {
            for field in ["directory", "lock", "rootID"] {
                let f = try Fixture(); defer { f.close() }
                if child == "structural" {
                    try DeviceStructuralStore(root: f.child(child), rootID: f.ids.structural).initializeExplicit()
                } else {
                    _ = try NativeEnrollmentJournalStore(root: f.journal, cloudRootID: f.cloudRootID,
                        excludedLocalResetRoot: f.scope.resetRoot).initializeFirstNativeExplicit()
                }
                let file = f.child(child).appendingPathComponent("root-binding.json")
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                if field == "rootID" { object[child == "structural" ? "rootID" : "cloudRootID"] = UUID().uuidString }
                else {
                    var identity = try XCTUnwrap(object[field] as? [String: Any]); identity["inode"] = 0; object[field] = identity
                }
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); try bytes.write(to: file)
                if child == "structural" {
                    XCTAssertThrowsError(try DeviceStructuralStore(root: f.child(child), rootID: f.ids.structural).initializeExplicit()) { error in
                        XCTAssertEqual(error as? DeviceStructuralStoreError, .unsafeBinding)
                    }
                } else {
                    XCTAssertThrowsError(try NativeEnrollmentJournalStore(root: f.journal, cloudRootID: f.cloudRootID,
                        excludedLocalResetRoot: f.scope.resetRoot).initializeFirstNativeExplicit()) { error in
                        XCTAssertEqual(error as? NativeEnrollmentJournalError, .unsafeRoot)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: file), bytes)
                XCTAssertEqual(f.http.claims, 0); XCTAssertEqual(f.storage.stageAdds, 0)
            }
        }
    }
    func testPhysicalAppHomePersistedAliasBindingsRemainBlockedAndUnmodified() throws {
        let f = try Fixture(); defer { f.close() }
        let alias = f.parent.appendingPathComponent("namespace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.namespace)
        let structural = DeviceStructuralStore(root: f.child("structural"), rootID: f.ids.structural)
        try structural.initializeExplicit()
        let journal = NativeEnrollmentJournalStore(root: f.journal, cloudRootID: f.cloudRootID, excludedLocalResetRoot: f.scope.resetRoot)
        _ = try journal.initializeFirstNativeExplicit()
        let originalJournalBinding = try Data(contentsOf: f.journal.appendingPathComponent("root-binding.json"))
        _ = try NativeEnrollmentJournalStore(root: f.journal, cloudRootID: f.cloudRootID,
            excludedLocalResetRoot: f.scope.resetRoot).initializeFirstNativeExplicit()
        XCTAssertEqual(try Data(contentsOf: f.journal.appendingPathComponent("root-binding.json")), originalJournalBinding)
        for child in ["structural", "enrollment"] {
            let file = f.child(child).appendingPathComponent("root-binding.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["canonicalPath"] = alias.appendingPathComponent(child).path
            let encodedAliasBinding = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            try encodedAliasBinding.write(to: file)
            if child == "structural" {
                XCTAssertThrowsError(try DeviceStructuralStore(root: f.child(child), rootID: f.ids.structural).initializeExplicit()) { error in
                        XCTAssertEqual(error as? DeviceStructuralStoreError, .unsafeBinding)
                    }
            } else {
                XCTAssertThrowsError(try NativeEnrollmentJournalStore(root: f.journal, cloudRootID: f.cloudRootID,
                    excludedLocalResetRoot: f.scope.resetRoot).initializeFirstNativeExplicit()) { error in
                    XCTAssertEqual(error as? NativeEnrollmentJournalError, .unsafeRoot)
                }
            }
            XCTAssertEqual(try Data(contentsOf: file), encodedAliasBinding)
        }
        XCTAssertEqual(f.http.claims, 0); XCTAssertEqual(f.http.activations, 0)
        XCTAssertEqual(f.storage.stageAdds, 0); XCTAssertEqual(f.storage.finalAdds, 0)
    }
    #endif

    private final class Fixture {
        let parent: URL, namespace: URL, journal: URL
        let ids: NativeManagedLocalRootIDs, scope: DevicePackageProtectedScope
        let proposal: NativeFirstEnrollmentPreparation, cloudRootID = UUID()
        let storage = Storage(), owner: Owner, http: PromotionHTTPFixture, grants: GrantTransport
        init() throws {
            guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw NativeEnrollmentPromotionError.blocked }
            let temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            free(physical)
            parent = temporary.appendingPathComponent("native-first-recovery-" + UUID().uuidString)
            namespace = parent.appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName)
            journal = namespace.appendingPathComponent("enrollment")
            try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
            for name in DeviceNativeManagedRootLocator.futureChildNames + ["enrollment"] {
                try FileManager.default.createDirectory(at: namespace.appendingPathComponent(name), withIntermediateDirectories: false)
            }
            ids = try .init(package: UUID(), grant: UUID(), structural: UUID(), provisioning: UUID(), contentGenesis: UUID())
            grants = .init(rootID: ids.grant)
            let local = parent.appendingPathComponent("local")
            scope = .init(legacyStateRoot: local, legacyArchiveRoot: local, resetRoot: parent.appendingPathComponent("reset"),
                cloudRoot: journal, managementRoot: parent.appendingPathComponent("management"), preferencesRoot: parent.appendingPathComponent("preferences"), otherProtectedRoots: [])
            let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: UUID(), locationId: nil, name: "Office iPad", profile: "iPad")
            let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: claim.transitionId,
                credentialReference: "native." + UUID().uuidString, format: .nativeInstallationV1)
            proposal = try .init(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage." + UUID().uuidString, binding: binding, claimInput: claim)
            owner = try Owner(namespace: namespace); http = PromotionHTTPFixture(input: claim)
        }
        func child(_ name: String) -> URL { namespace.appendingPathComponent(name) }
        func stores() throws -> NativeFirstManagedStores {
            try .init(namespace: namespace, ids: ids,
                protectedRoots: .init(legacyState: scope.legacyStateRoot, legacyArchive: scope.legacyArchiveRoot, reset: scope.resetRoot,
                    cloudEnrollment: journal, management: scope.managementRoot, preferences: scope.preferencesRoot), grantTransport: grants)
        }
        func session() throws -> NativeFirstEnrollmentSession {
            try .init(namespace: namespace, journalRoot: journal, cloudRootID: cloudRootID, excludedLocalResetRoot: scope.resetRoot,
                proposal: proposal, storage: storage, owner: owner)
        }
        func close() { http.close(); try? FileManager.default.removeItem(at: parent) }
    }
    private struct GrantTransport: DeviceGrantCredentialTransport {
        let rootID: UUID
        func inventory(maximum: Int, visit: (DeviceGrantCredentialObservation) throws -> Void) throws {}
        func read(account: String, maximumBytes: Int) throws -> DeviceGrantCredentialTransportSecret? { nil }
        func add(account: String, bytes: Data) throws -> DeviceGrantCredentialObservation { throw NativeEnrollmentPromotionError.blocked }
    }
    private final class Storage: NativeEnrollmentCredentialStorage {
        var items: [NativeEnrollmentStoredCredential] = []
        private var references: [Data] = []
        var stageAdds = 0, finalAdds = 0
        func enumerateBounded(maximum: Int) throws -> [NativeEnrollmentStoredCredential] { Array(items.prefix(maximum)) }
        func generateOriginal48() throws -> Data { Data(repeating: 42, count: 48) }
        func readExactPersistentReference(_ reference: Data) throws -> NativeEnrollmentStoredCredential? {
            references.firstIndex(of: reference).map { items[$0] }
        }
        func insertStageOnly(account: Data, envelope: Data) throws -> NativeEnrollmentCredentialInsert {
            stageAdds += 1
            return insert(service: NativeEnrollmentStageEnvelope.service, account: account, payload: envelope)
        }
        func insertFinalOnly(account: Data, original48: Data) throws -> NativeEnrollmentCredentialInsert {
            finalAdds += 1
            return insert(service: NativeEnrollmentStageEnvelope.finalService, account: account, payload: original48)
        }
        private func insert(service: String, account: Data, payload: Data) -> NativeEnrollmentCredentialInsert {
            let reference = Data([UInt8(items.count + 1)])
            references.append(reference)
            items.append(.init(service: Data(service.utf8), account: account, persistentReference: reference, payload: payload, accessible: true))
            return .inserted(reference)
        }
    }
    /// Synthetic owner pins the genuine physical namespace and every child. It
    /// admits no device dispatch/context; the production Apple owner is unchanged.
    private final class Owner: NativeFirstEnrollmentOwner, @unchecked Sendable {
        let nodes: [(URL, UInt64, UInt64)]
        var revoked = false, active = false
        init(namespace: URL) throws {
            nodes = try ([namespace] + (DeviceNativeManagedRootLocator.futureChildNames + ["enrollment"]).map { namespace.appendingPathComponent($0) }).map { url in
                try NativeEnrollmentPhysicalDirectory.require(url)
                var info = stat(); guard lstat(url.path, &info) == 0 else { throw NativeEnrollmentPromotionError.blocked }
                return (url, UInt64(info.st_dev), UInt64(info.st_ino))
            }
        }
        private func check() throws {
            guard !revoked else { throw NativeEnrollmentPromotionError.blocked }
            for (url, device, inode) in nodes {
                try NativeEnrollmentPhysicalDirectory.require(url)
                var info = stat(); guard lstat(url.path, &info) == 0, UInt64(info.st_dev) == device, UInt64(info.st_ino) == inode else { throw NativeEnrollmentPromotionError.blocked }
            }
        }
        func beginFixedEnrollmentStep() throws { try check(); guard !active else { throw NativeEnrollmentPromotionError.blocked }; active = true }
        func finishFixedEnrollmentStep() throws { defer { active = false }; try check(); guard active else { throw NativeEnrollmentPromotionError.blocked } }
        func validateFixedEnrollmentStep() throws { try check(); guard active else { throw NativeEnrollmentPromotionError.blocked } }
        func qualifyOperationalReads(installation: NativeOperationalInstallation, activation: NativeActivationReceipt) throws {
            try validateFixedEnrollmentStep(); try installation.requireDurableActivationAssociation(activation)
        }
        func validateCurrentDispatchOwner(_ candidate: any NativeCurrentInstallationOwner) throws { throw NativeEnrollmentPromotionError.blocked }
        func validateOperationalContext() throws { throw NativeEnrollmentPromotionError.blocked }
        func validateOperationalOrigin(_ origin: URL) throws { throw NativeEnrollmentPromotionError.blocked }
        func beginOperationalCredentialRead() throws { throw NativeEnrollmentPromotionError.blocked }
        func finishOperationalCredentialRead() throws { throw NativeEnrollmentPromotionError.blocked }
    }
}
