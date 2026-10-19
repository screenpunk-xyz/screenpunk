import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import ScreenpunkController

final class DurableToolchainInstallTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let hostPublisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "test.build-host")
    private let servicePublisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "test.build-service")
    private let nodePublisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "test.node")
    private var temporary: URL!
    private var catalogRoot: URL!
    private var installedRoot: URL!
    private var signingKey: Curve25519.Signing.PrivateKey!
    private var replacementKey: Curve25519.Signing.PrivateKey!
    private var anchor: MemoryTrustAnchor!

    override func setUpWithError() throws {
        temporary = URL(fileURLWithPath: "/private/tmp/sp-durable-f1-" + UUID().uuidString)
        catalogRoot = temporary.appendingPathComponent("catalog")
        installedRoot = temporary.appendingPathComponent("kits")
        try FileManager.default.createDirectory(at: catalogRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: installedRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        signingKey = Curve25519.Signing.PrivateKey()
        replacementKey = Curve25519.Signing.PrivateKey()
        anchor = MemoryTrustAnchor()
    }

    override func tearDownWithError() throws {
        if let temporary {
            if let walker = FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: nil) {
                for case let url as URL in walker {
                    var info = stat()
                    if lstat(url.path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                        _ = chmod(url.path, 0o700)
                    }
                }
            }
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testRestartHighWaterHistoricalPinRollbackAndRevocation() throws {
        let fixture = try makeFixture()
        let old = try sign(fixture.entry, sequence: 1)
        let new = try sign(fixture.entry, sequence: 2)
        let first = try store()
        try first.accept(old)
        try first.accept(new)
        let reopened = try store()
        try reopened.withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 1) // deterministic historical representative
        }
        let earlierUnknown = try sign(fixture.entry, sequence: 0)
        expect(.staleCatalog) { try reopened.accept(earlierUnknown) }

        let checkpoint = try XCTUnwrap(anchor.read())
        let active = catalogRoot.appendingPathComponent("catalog.\(checkpoint.slot)")
        try Data("restored-state".utf8).write(to: active)
        expect(.trustUnavailable) {
            try reopened.withResolved(requirement(fixture.entry)) { _, _ in }
        }
        expect(.revokedSigner) {
            let revokedStore = try store(revoked: true, root: temporary.appendingPathComponent("revoked-catalog"),
                                         anchor: MemoryTrustAnchor())
            try revokedStore.accept(old)
        }
    }

    func testRemovingCatalogFilesWhileKeepingCheckpointBlocksSameOfflineEnvelope() throws {
        let fixture = try makeFixture()
        let envelope = try sign(fixture.entry, sequence: 1)
        try store().accept(envelope)
        let checkpoint = try XCTUnwrap(anchor.read())
        let originalJournal = try Data(contentsOf: catalogRoot.appendingPathComponent("catalog.\(checkpoint.slot)"))
        // Reproduce the disposable Studio reset without touching a real Keychain:
        // only catalog files disappear; the same device-local checkpoint remains.
        for slot in 0...1 {
            let file = catalogRoot.appendingPathComponent("catalog.\(slot)")
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        expect(.catalogStateMissing) { try store().accept(envelope) }
        XCTAssertEqual(try anchor.read(), checkpoint)
        for slot in 0...1 {
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                catalogRoot.appendingPathComponent("catalog.\(slot)").path))
        }
        let recovered = try store()
        try recovered.restoreMissingExactJournal(from: envelope)
        XCTAssertEqual(try anchor.read(), checkpoint)
        XCTAssertEqual(try Data(contentsOf: catalogRoot.appendingPathComponent("catalog.\(checkpoint.slot)")), originalJournal)
        try recovered.accept(envelope)
        try recovered.withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 1)
        }
    }

    func testExactJournalRecoveryCannotReplaceLostHistoryOrRevocations() throws {
        let fixture = try makeFixture()
        let envelope = try sign(fixture.entry, sequence: 1)
        let durable = try store()
        try durable.accept(envelope)
        try durable.accept(sign(fixture.entry, sequence: 2))
        let historyCheckpoint = try XCTUnwrap(anchor.read())
        let active = catalogRoot.appendingPathComponent("catalog.\(historyCheckpoint.slot)")
        let historyJournal = try Data(contentsOf: active)
        try FileManager.default.removeItem(at: active)
        expect(.catalogStateMissing) { try durable.restoreMissingExactJournal(from: envelope) }
        XCTAssertEqual(try anchor.read(), historyCheckpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
        try historyJournal.write(to: active)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: active.path)
        try durable.recordReleaseRevocations(["fixture"])
        let revokedCheckpoint = try XCTUnwrap(anchor.read())
        let revoked = catalogRoot.appendingPathComponent("catalog.\(revokedCheckpoint.slot)")
        try FileManager.default.removeItem(at: revoked)
        expect(.catalogStateMissing) { try durable.restoreMissingExactJournal(from: envelope) }
        XCTAssertEqual(try anchor.read(), revokedCheckpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: revoked.path))
    }

    func testExactJournalRecoveryRejectsChangedEnvelopeAndLeavesExistingJournalUntouched() throws {
        let fixture = try makeFixture()
        let envelope = try sign(fixture.entry, sequence: 1)
        let durable = try store()
        try durable.accept(envelope)
        let checkpoint = try XCTUnwrap(anchor.read())
        let active = catalogRoot.appendingPathComponent("catalog.\(checkpoint.slot)")
        let original = try Data(contentsOf: active)
        try durable.restoreMissingExactJournal(from: sign(fixture.entry, sequence: 2))
        XCTAssertEqual(try Data(contentsOf: active), original)
        try FileManager.default.removeItem(at: active)
        expect(.catalogStateMissing) {
            try durable.restoreMissingExactJournal(from: sign(fixture.entry, sequence: 2))
        }
        XCTAssertEqual(try anchor.read(), checkpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    }

    func testExactJournalRecoveryRestoresCommittedEmptyStateAfterInterruptedFirstAcceptance() throws {
        let fixture = try makeFixture()
        let envelope = try sign(fixture.entry, sequence: 1)
        let durable = try store()
        anchor.failAtCommit = 3 // first acceptance failed after the empty state was anchored
        expect(.trustUnavailable) { try durable.accept(envelope) }
        let checkpoint = try XCTUnwrap(anchor.read())
        let original = try Data(contentsOf: catalogRoot.appendingPathComponent("catalog.\(checkpoint.slot)"))
        for slot in 0...1 {
            let file = catalogRoot.appendingPathComponent("catalog.\(slot)")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        try durable.restoreMissingExactJournal(from: envelope)
        XCTAssertEqual(try anchor.read(), checkpoint)
        XCTAssertEqual(try Data(contentsOf: catalogRoot.appendingPathComponent("catalog.\(checkpoint.slot)")), original)
        try durable.accept(envelope)
        try durable.withResolved(requirement(fixture.entry)) { _, _ in }
    }

    func testSignedEquivocationPersistsAcrossProcessSessions() throws {
        let fixture = try makeFixture()
        let original = try sign(fixture.entry, sequence: 2)
        let alternate = ToolchainCatalogEntry(catalogEntryId: fixture.entry.catalogEntryId,
            kind: fixture.entry.kind, version: fixture.entry.version, platform: fixture.entry.platform,
            artifactSha256: String(repeating: "d", count: 64), artifactBytes: fixture.entry.artifactBytes,
            downloadURL: fixture.entry.downloadURL, publisher: fixture.entry.publisher,
            inventoryHash: fixture.entry.inventoryHash, inventory: fixture.entry.inventory, protocolMajor: nil)
        let durable = try store()
        try durable.accept(original)
        expect(.conflictingCatalog) { try durable.accept(sign(alternate, sequence: 2)) }
        expect(.conflictingCatalog) {
            try store().withResolved(requirement(fixture.entry)) { _, _ in }
        }
    }

    func testInterruptedCheckpointKeepsPriorStateAndInterleavedClientsAdvance() throws {
        let fixture = try makeFixture()
        let old = try sign(fixture.entry, sequence: 1)
        let new = try sign(fixture.entry, sequence: 2)
        let first = try store()
        let second = try store()
        try first.accept(old)
        anchor.failNextCommit = true
        expect(.trustUnavailable) { try second.accept(new) }
        try store().withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 1)
        }
        try second.accept(new)
        try store().withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 1)
        }
        let unknown = try sign(fixture.entry, sequence: 0)
        expect(.staleCatalog) { try first.accept(unknown) }

        let revoked = try store(revoked: true)
        expect(.revokedSigner) {
            try revoked.withResolved(requirement(fixture.entry)) { _, _ in }
        }
        try second.recordReleaseRevocations(["fixture"])
        expect(.revokedSigner) {
            try store().withResolved(requirement(fixture.entry)) { _, _ in }
        }
    }

    func testExplicitInstallHistoricalOfflineCacheAndTamper() throws {
        let fixture = try makeFixture()
        let durable = try store()
        try durable.accept(sign(fixture.entry, sequence: 1))
        try durable.accept(sign(fixture.entry, sequence: 2))
        let fetcher = FixtureFetcher(bytes: fixture.archive)
        let installer = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: fetcher, bundleSignature: FixtureBundleSignature(),
            capacityProvider: FixtureCapacity(total: 1_000_000_000,
                highAvailable: 500_000_000))
        expect(.kitMissing) { _ = try installer.installed(requirement(fixture.entry)) }
        let first = try installer.install(requirement(fixture.entry))
        XCTAssertTrue(first.bundlePath.hasSuffix("/Host/ScreenpunkBuildHost.app"))
        expect(.publisherUnverified) {
            try MacOSToolchainHostBundleSignatureVerifier().verify(bundlePath: first.bundlePath,
                                                                   expected: hostPublisher)
        }
        XCTAssertEqual(fetcher.calls, 1)
        _ = try installer.install(requirement(fixture.entry))
        XCTAssertEqual(fetcher.calls, 1)

        let script = URL(fileURLWithPath: first.kit.installedPath).appendingPathComponent("scripts/build.mjs")
        let kitRoot = URL(fileURLWithPath: first.kit.installedPath)
        XCTAssertEqual(chmod(kitRoot.path, 0o700), 0)
        XCTAssertEqual(chmod(script.deletingLastPathComponent().path, 0o700), 0)
        XCTAssertEqual(chmod(script.path, 0o600), 0)
        try Data("tampered".utf8).write(to: script)
        XCTAssertEqual(chmod(script.path, 0o400), 0)
        XCTAssertEqual(chmod(script.deletingLastPathComponent().path, 0o500), 0)
        XCTAssertEqual(chmod(kitRoot.path, 0o500), 0)
        expect(.inventoryMismatch) { _ = try installer.installed(requirement(fixture.entry)) }
        expect(.inventoryMismatch) { _ = try installer.install(requirement(fixture.entry)) }
        XCTAssertEqual(fetcher.calls, 1)
    }

    func testEmbeddedOfflineKitRequiresSignedCatalogAndExactArchive() throws {
        let fixture = try makeFixture()
        let member = "Resources/Toolchains/authoring-1.0.0-darwin-arm64.tar"
        let entry = ToolchainCatalogEntry(catalogEntryId: fixture.entry.catalogEntryId,
            kind: fixture.entry.kind, version: fixture.entry.version,
            platform: fixture.entry.platform, artifactSha256: fixture.entry.artifactSha256,
            artifactBytes: fixture.entry.artifactBytes, downloadURL: "",
            embeddedArtifactPath: member, publisher: fixture.entry.publisher,
            inventoryHash: fixture.entry.inventoryHash, inventory: fixture.entry.inventory,
            protocolMajor: nil)
        let release = temporary.appendingPathComponent("verified-release")
        let tar = release.appendingPathComponent(member)
        try FileManager.default.createDirectory(at: tar.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fixture.archive.write(to: tar)
        let durable = try store(origins: [])
        let fetcher = FixtureFetcher(bytes: fixture.archive)
        let installer = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: fetcher, bundleSignature: FixtureBundleSignature(),
            capacityProvider: FixtureCapacity(total: 1_000_000_000,
                highAvailable: 500_000_000))
        expect(.unknownKit) { _ = try installer.installOffline(requirement(entry), verifiedReleaseRoot: release) }

        let signed = try sign(entry, sequence: 1)
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: signed) as? [String: Any])
        forged["signatureBase64"] = Data(repeating: 0, count: 64).base64EncodedString()
        expect(.signatureInvalid) { try durable.accept(JSONSerialization.data(withJSONObject: forged)) }
        expect(.unknownKit) { _ = try installer.installOffline(requirement(entry), verifiedReleaseRoot: release) }

        try durable.accept(signed)
        expect(.trustUnavailable) { _ = try installer.install(requirement(entry)) }
        try FileManager.default.removeItem(at: tar)
        try FileManager.default.createSymbolicLink(at: tar, withDestinationURL: temporary)
        expect(.unsafePath) { _ = try installer.installOffline(requirement(entry), verifiedReleaseRoot: release) }
        try FileManager.default.removeItem(at: tar)
        try Data(repeating: 0, count: fixture.archive.count).write(to: tar)
        expect(.artifactMismatch) { _ = try installer.installOffline(requirement(entry), verifiedReleaseRoot: release) }
        try fixture.archive.write(to: tar)
        let configured = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: fetcher, bundleSignature: FixtureBundleSignature(),
            capacityProvider: FixtureCapacity(total: 1_000_000_000,
                highAvailable: 500_000_000), installedReleaseRoot: release)
        let installed = try configured.install(requirement(entry))
        XCTAssertTrue(installed.bundlePath.hasSuffix("/Host/ScreenpunkBuildHost.app"))
        XCTAssertEqual(fetcher.calls, 0)
        _ = try installer.installOffline(requirement(entry), verifiedReleaseRoot: release)
        _ = try installer.installed(requirement(entry))
    }

    /// Explicit opt-in only: exercise a real mounted release under disposable roots
    /// with an in-memory checkpoint, never the user's installed kit or Keychain.
    func testMountedSignedReleaseOfflineImportWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENPUNK_SIGNED_RELEASE_ROOT"] else {
            throw XCTSkip("Set SCREENPUNK_SIGNED_RELEASE_ROOT to a verified mounted release.")
        }
        let release = URL(fileURLWithPath: path)
        guard path.hasPrefix("/private/tmp/screenpunk-cli-mounted") else {
            XCTFail("Release input must be the read-only private mount")
            return
        }
        let envelope = try Data(contentsOf: release.appendingPathComponent(
            "Resources/Toolchains/catalog-envelope.json"))
        let (signed, _) = try ToolchainCatalogJSON.decode(envelope)
        let key = try XCTUnwrap(Data(base64Encoded:
            "LGC9mox5gIz0zhOleiR4X+atIl5pKyL5cFSN11SMCTU="))
        let publishers = ["xyz.screenpunk.build-host", "xyz.screenpunk.build-service",
            "xyz.screenpunk.authoring.node", "xyz.screenpunk.authoring.esbuild",
            "xyz.screenpunk.authoring.fsevents"].map {
            ToolchainPublisher(teamIdentifier: "77KASWDGM6", signingIdentifier: $0)
        }
        let policy = try ToolchainTrustPolicy(signers: ["screenpunk-release-2026-09":
            ToolchainTrustedSigner(publicKey: key,
                validFrom: Date(timeIntervalSince1970: 1_790_726_400),
                validUntil: Date(timeIntervalSince1970: 1_853_971_200), revoked: false)],
            channel: "stable", acceptedSequence: 0,
            knownHistoricalEnvelopeHashes: [], allowedOrigins: [],
            approvedPublishers: Set(publishers), installedKitRoot: installedRoot.path)
        let durable = try DurableToolchainCatalogStore(root: catalogRoot.path,
            basePolicy: policy, anchor: anchor!, now: Date.init,
            nativeSignature: MacOSToolchainSignatureVerifier())
        try durable.accept(envelope)
        let checkpoint = try XCTUnwrap(anchor.read())
        let journal = catalogRoot.appendingPathComponent("catalog.\(checkpoint.slot)")
        let originalJournal = try Data(contentsOf: journal)
        try FileManager.default.removeItem(at: journal)
        expect(.catalogStateMissing) { try durable.accept(envelope) }
        try durable.restoreMissingExactJournal(from: envelope)
        XCTAssertEqual(try anchor.read(), checkpoint)
        XCTAssertEqual(try Data(contentsOf: journal), originalJournal)
        try durable.accept(envelope)
        let entries = signed.payload.entries.filter { $0.kind == "authoringKit" }
        XCTAssertEqual(entries.count, 1)
        let realCapacity = ProcessInfo.processInfo.environment["SCREENPUNK_TEST_REAL_CAPACITY"] == "1"
        let capacity: any ToolchainCapacityProviding = realCapacity
            ? MacOSToolchainCapacityProvider()
            : FixtureCapacity(total: 10_000_000_000, highAvailable: 5_000_000_000)
        print("mounted_release_capacity_mode=\(realCapacity ? "real" : "fixture")")
        let installer = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: ToolchainHTTPSArtifactFetcher(),
            bundleSignature: MacOSToolchainHostBundleSignatureVerifier(),
            capacityProvider: capacity,
            installedReleaseRoot: release)
        for entry in entries {
            XCTAssertEqual(entry.embeddedArtifactPath,
                "Resources/Toolchains/authoring-1.0.0-darwin-arm64.tar")
            let pin = requirement(entry)
            let installed = try installer.install(pin)
            XCTAssertTrue(installed.bundlePath.hasSuffix("/Host/ScreenpunkBuildHost.app"))
            _ = try installer.installed(pin)
        }
    }

    func testAuthenticatedInstalledKitUpgradesThroughPublicBrokerRoute() throws {
        let fixture = try makeFixture()
        let durable = try store()
        try durable.accept(sign(fixture.entry, sequence: 2))
        let installer = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: FixtureFetcher(bytes: fixture.archive), bundleSignature: FixtureBundleSignature(),
            capacityProvider: FixtureCapacity(total: 1_000_000_000,
                highAvailable: 500_000_000))
        let documents = temporary.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: InstalledKitDocuments(url: documents),
            machineRootPath: temporary.appendingPathComponent("machine").path)
        _ = try workspace.create(at: temporary.appendingPathComponent("visible").path)
        let created = try WorkbenchContainedAuthoring(workspace: workspace)
            .create(name: "React", kind: "react", trustedKitVersion: "builtin-react-1")
        try JSONEncoder().encode(WorkspaceToolchainRequirements(
            required: [requirement(fixture.entry)])).write(to: temporary.appendingPathComponent(
                "visible/Workbench/Toolchains/requirements.json"), options: .atomic)
        let before = try XCTUnwrap(workspace.current())
        let controller = try ControllerService.bootstrap(root: temporary.appendingPathComponent("legacy"),
            deviceDirectoryURL: temporary.appendingPathComponent("devices.json"))
        let environment = try WorkbenchBrokerEnvironment(
            runtimeDirectory: temporary.appendingPathComponent("runtime"))
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace, native: nil,
            dispatchObserver: nil, mutationGate: {}, trustedCatalog: durable,
            toolchainInstaller: installer)
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect(); defer { client.close() }
        let missing = try client.toolchainRequirements()
        XCTAssertEqual(missing.trust, "authenticated")
        XCTAssertEqual(missing.installation, "incomplete")
        XCTAssertEqual(missing.installed, [])
        XCTAssertThrowsError(try client.installRequiredToolchains(
            expectedWorkspaceId: missing.workspaceId,
            expectedSelectionGeneration: missing.selectionGeneration + 1)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        _ = try client.reconnectIfPeerClosed()
        let receipt = try client.installRequiredToolchains(
            expectedWorkspaceId: missing.workspaceId,
            expectedSelectionGeneration: missing.selectionGeneration)
        XCTAssertTrue(receipt.complete)
        XCTAssertEqual(receipt.installed, [requirement(fixture.entry)])
        XCTAssertEqual(try client.toolchainRequirements().installation, "complete")
        let installed = try installer.installed(requirement(fixture.entry))
        let params: [String: Any] = [
            "schemaVersion": 1, "projectId": created.project.projectId,
            "expectedSourceVersion": created.sourceVersion,
            "expectedCatalogGeneration": before.catalog.generation,
            "catalogEntryId": fixture.entry.catalogEntryId,
            "kitVersion": fixture.entry.version,
            "inventoryHash": fixture.entry.inventoryHash,
            "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": before.selectionGeneration]
        let upgraded = try XCTUnwrap(client.performAuthoring(method: .projectUpgradeKit,
            params: params).project)
        XCTAssertNotEqual(upgraded.sourceVersion, created.sourceVersion)
        let after = try XCTUnwrap(workspace.current())
        XCTAssertEqual(after.catalog.generation, before.catalog.generation + 1)
        XCTAssertEqual(after.descriptor.generation, after.catalog.generation)
        XCTAssertEqual(after.settings.generation, after.catalog.generation)
        let pin = try JSONDecoder().decode(WorkbenchSourceKitPin.self,
            from: Data(contentsOf: URL(fileURLWithPath: upgraded.path + "/screenpunk.lock.json")))
        XCTAssertEqual(pin.requirement, requirement(fixture.entry))
        let requirements = try JSONDecoder().decode(WorkspaceToolchainRequirements.self,
            from: Data(contentsOf: temporary.appendingPathComponent(
                "visible/Workbench/Toolchains/requirements.json")))
        XCTAssertEqual(requirements.required, [requirement(fixture.entry)])
        XCTAssertThrowsError(try client.performAuthoring(method: .projectUpgradeKit, params: params)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        _ = try client.reconnectIfPeerClosed()
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.kit.installedPath))

        // A changed installed byte must fail verification before any second project mutation.
        let second = try WorkbenchContainedAuthoring(workspace: workspace)
            .create(name: "Second React", kind: "react", trustedKitVersion: "builtin-react-1")
        let secondBefore = try XCTUnwrap(workspace.current())
        let script = URL(fileURLWithPath: installed.kit.installedPath)
            .appendingPathComponent("scripts/build.mjs")
        let kitRoot = URL(fileURLWithPath: installed.kit.installedPath)
        XCTAssertEqual(chmod(kitRoot.path, 0o700), 0)
        XCTAssertEqual(chmod(script.deletingLastPathComponent().path, 0o700), 0)
        XCTAssertEqual(chmod(script.path, 0o600), 0)
        try Data("tampered".utf8).write(to: script)
        XCTAssertEqual(chmod(script.path, 0o400), 0)
        XCTAssertEqual(chmod(script.deletingLastPathComponent().path, 0o500), 0)
        XCTAssertEqual(chmod(kitRoot.path, 0o500), 0)
        var tamperedParams = params
        tamperedParams["projectId"] = second.project.projectId
        tamperedParams["expectedSourceVersion"] = second.sourceVersion
        tamperedParams["expectedCatalogGeneration"] = secondBefore.catalog.generation
        tamperedParams["expectedSelectionGeneration"] = secondBefore.selectionGeneration
        XCTAssertThrowsError(try client.performAuthoring(method: .projectUpgradeKit,
            params: tamperedParams)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .toolchainTrustUnavailable)
        }
        XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: workspace)
            .get(second.project.projectId).sourceVersion, second.sourceVersion)
        XCTAssertEqual(try XCTUnwrap(workspace.current()).catalog.generation,
            secondBefore.catalog.generation)
    }

    func testInstalledReleaseRegistrationRejectsMissingIndependentSigner() throws {
        XCTAssertThrowsError(try WorkbenchInstalledReleaseTrust(signers: [],
            channel: "stable", acceptedSequence: 1,
            knownHistoricalEnvelopeHashes: [],
            allowedOrigins: ["https://releases.example.test"],
            approvedPublishers: [.init(teamIdentifier: "TESTTEAM00",
                signingIdentifier: "test.build-host")],
            catalogRoot: catalogRoot.path, installedKitRoot: installedRoot.path,
            keychainService: "private.test", keychainAccount: "private.test")) {
            XCTAssertEqual($0 as? ToolchainTrustError, .trustUnavailable)
        }
    }

    func testUnsafeArchiveAndInterruptedFetchNeverPublish() throws {
        let fixture = try makeFixture()
        let malicious = try makeFixture(archiveOverride: tar(fixture.files, linkAt: "kit.json"))
        let durable = try store()
        try durable.accept(sign(malicious.entry, sequence: 2))
        let installer = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: FixtureFetcher(bytes: malicious.archive), bundleSignature: FixtureBundleSignature(),
            capacityProvider: FixtureCapacity(total: 1_000_000_000,
                highAvailable: 500_000_000))
        expect(.artifactMismatch) { _ = try installer.install(requirement(malicious.entry)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            installedRoot.appendingPathComponent(malicious.entry.catalogEntryId + "-" + malicious.entry.inventoryHash.prefix(16)).path))

        let secondRoot = temporary.appendingPathComponent("second-catalog")
        let second = try store(root: secondRoot, anchor: MemoryTrustAnchor())
        try second.accept(sign(fixture.entry, sequence: 2))
        let interrupted = ToolchainKitInstaller(catalog: second, installedRoot: installedRoot.path,
            fetcher: FixtureFetcher(bytes: fixture.archive, interrupt: true), bundleSignature: FixtureBundleSignature(),
            capacityProvider: FixtureCapacity(total: 1_000_000_000,
                highAvailable: 500_000_000))
        expect(.artifactMismatch) { _ = try interrupted.install(requirement(fixture.entry)) }
        let entries = try FileManager.default.contentsOfDirectory(atPath: installedRoot.path)
        XCTAssertTrue(entries.isEmpty, "Interrupted install retained \(entries)")
    }

    func testOversizeFetchStopsBeforeArchiveLimit() throws {
        let fixture = try makeFixture()
        let durable = try store()
        try durable.accept(sign(fixture.entry, sequence: 2))
        var extra = fixture.archive
        extra.append(1)
        let installer = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: FixtureFetcher(bytes: extra), bundleSignature: FixtureBundleSignature())
        expect(.limitExceeded) { _ = try installer.install(requirement(fixture.entry)) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: installedRoot.path).isEmpty)
    }

    func testHostBundleRejectsUnmirroredEmbeddedContent() throws {
        let fixture = try makeFixture(extraEmbedded: true)
        let durable = try store()
        try durable.accept(sign(fixture.entry, sequence: 2))
        expect(.inventoryMismatch) {
            try durable.withResolved(requirement(fixture.entry)) { _, approved in
                try ToolchainHostBundleContract.validate(approved)
            }
        }
    }

    func testDiskHeadroomRejectsInitialAndConcurrentCapacityLoss() throws {
        let fixture = try makeFixture()
        let durable = try store()
        try durable.accept(sign(fixture.entry, sequence: 2))
        let fetcher = FixtureFetcher(bytes: fixture.archive)
        let low = FixtureCapacity(total: 1_000_000, highAvailable: 100_000)
        let first = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: fetcher, bundleSignature: FixtureBundleSignature(), capacityProvider: low)
        expect(.limitExceeded) { _ = try first.install(requirement(fixture.entry)) }
        XCTAssertEqual(fetcher.calls, 0)

        let falling = FixtureCapacity(total: 1_000_000_000, highAvailable: 500_000_000,
                                      lowAvailable: 100_000, dropAfter: 5)
        let second = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: fetcher, bundleSignature: FixtureBundleSignature(), capacityProvider: falling)
        expect(.limitExceeded) { _ = try second.install(requirement(fixture.entry)) }
        XCTAssertEqual(fetcher.calls, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: installedRoot.path).isEmpty)

        let overflow = FixtureCapacity(total: Int64.max, highAvailable: Int64.max,
                                       block: Int64.max)
        let third = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: fetcher, bundleSignature: FixtureBundleSignature(), capacityProvider: overflow)
        expect(.limitExceeded) { _ = try third.install(requirement(fixture.entry)) }
    }

    func testInstallationHeadroomUsesExactPeakThresholdEvenOnLargeVolume() throws {
        let fixture = try makeFixture()
        let durable = try store()
        try durable.accept(sign(fixture.entry, sequence: 2))
        let fetcher = FixtureFetcher(bytes: fixture.archive)
        let total: Int64 = 1_000_000_000_000
        var directories = Set<String>()
        for item in fixture.entry.inventory {
            let parts = item.path.split(separator: "/")
            for count in 1..<parts.count {
                directories.insert(parts.prefix(count).joined(separator: "/"))
            }
        }
        let expanded = fixture.entry.inventory.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        let metadata = Int64(fixture.entry.inventory.count + directories.count + 16) * 4096
        let peak = Int64(fixture.entry.artifactBytes) + expanded + metadata
        let expectedReserve = max(Int64(128) * 1024 * 1024,
                                  peak / 10 + (peak % 10 == 0 ? 0 : 1))
        let threshold = peak + expectedReserve
        XCTAssertLessThan(threshold, total / 10,
            "This fixture must distinguish import-peak headroom from whole-volume headroom.")
        let belowMargin = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: fetcher, bundleSignature: FixtureBundleSignature(),
            capacityProvider: FixtureCapacity(total: total,
                highAvailable: threshold - 1))
        expect(.limitExceeded) { _ = try belowMargin.install(requirement(fixture.entry)) }
        XCTAssertEqual(fetcher.calls, 0)

        let adequate = ToolchainKitInstaller(catalog: durable, installedRoot: installedRoot.path,
            fetcher: fetcher, bundleSignature: FixtureBundleSignature(),
            capacityProvider: FixtureCapacity(total: total,
                highAvailable: threshold))
        _ = try adequate.install(requirement(fixture.entry))
        XCTAssertEqual(fetcher.calls, 1)
        _ = try adequate.installed(requirement(fixture.entry))
    }

    func testRevokedExpiredAndRetiredSignerAllowValidReplacement() throws {
        let fixture = try makeFixture()
        let signers = ["fixture": trusted(signingKey, until: instant.addingTimeInterval(5)),
                       "replacement": trusted(replacementKey, until: instant.addingTimeInterval(100))]
        let clock = FixtureClock(instant)
        let durable = try store(signers: signers, clock: { clock.date })
        try durable.accept(sign(fixture.entry, sequence: 1))
        try durable.accept(sign(fixture.entry, sequence: 2,
                                signerID: "replacement", key: replacementKey))
        clock.date = instant.addingTimeInterval(10)
        try store(signers: signers, clock: { clock.date }).withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 2)
        }
        try durable.recordReleaseRevocations(["fixture"])
        let retired = try store(signers: ["replacement": signers["replacement"]!],
                                clock: { clock.date })
        try retired.withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 2)
        }
        expect(.unknownSigner) { try retired.accept(sign(fixture.entry, sequence: 3)) }
    }

    func testRevocationBeforeReplacementDoesNotBlockRefresh() throws {
        let fixture = try makeFixture()
        let signers = ["fixture": trusted(signingKey), "replacement": trusted(replacementKey)]
        let durable = try store(signers: signers)
        try durable.accept(sign(fixture.entry, sequence: 1))
        try durable.recordReleaseRevocations(["fixture"])
        try durable.accept(sign(fixture.entry, sequence: 2,
                                signerID: "replacement", key: replacementKey))
        try store(signers: signers).withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 2)
        }
    }

    func testNeverUsedRevokedSignerCanRetireBeforeReplacementRefresh() throws {
        let fixture = try makeFixture()
        let signers = ["fixture": trusted(signingKey), "replacement": trusted(replacementKey)]
        let durable = try store(signers: signers)
        // No envelope from fixture has populated evidenceKeys yet.
        try durable.recordReleaseRevocations(["fixture"])
        let retired = try store(signers: ["replacement": signers["replacement"]!])
        try retired.accept(sign(fixture.entry, sequence: 1,
                                signerID: "replacement", key: replacementKey))
        try retired.withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 1)
        }
        expect(.unknownSigner) { try retired.accept(sign(fixture.entry, sequence: 2)) }
        expect(.revokedSigner) {
            try durable.accept(sign(fixture.entry, sequence: 2))
        }
    }

    func testRetiredSignerConflictEvidenceStillPoisonsExactPin() throws {
        let fixture = try makeFixture()
        let signers = ["fixture": trusted(signingKey), "replacement": trusted(replacementKey)]
        let durable = try store(signers: signers)
        try durable.accept(sign(fixture.entry, sequence: 1))
        try durable.recordReleaseRevocations(["fixture"])
        let changed = ToolchainCatalogEntry(catalogEntryId: fixture.entry.catalogEntryId,
            kind: fixture.entry.kind, version: fixture.entry.version, platform: fixture.entry.platform,
            artifactSha256: String(repeating: "d", count: 64), artifactBytes: fixture.entry.artifactBytes,
            downloadURL: fixture.entry.downloadURL, publisher: fixture.entry.publisher,
            inventoryHash: fixture.entry.inventoryHash, inventory: fixture.entry.inventory, protocolMajor: nil)
        expect(.conflictingCatalog) {
            try durable.accept(sign(changed, sequence: 2,
                                    signerID: "replacement", key: replacementKey))
        }
        expect(.conflictingCatalog) {
            try durable.accept(sign(changed, sequence: 2,
                                    signerID: "replacement", key: replacementKey))
        }
        expect(.conflictingCatalog) {
            try store(signers: signers).accept(sign(fixture.entry, sequence: 3,
                signerID: "replacement", key: replacementKey))
        }
        expect(.revokedSigner) {
            try durable.withResolved(requirement(fixture.entry)) { _, _ in }
        }
    }

    func testExpiredOrRemovedSignerDoesNotBlockLaterReplacementAcceptance() throws {
        let fixture = try makeFixture()
        let signers = ["fixture": trusted(signingKey, until: instant.addingTimeInterval(5)),
                       "replacement": trusted(replacementKey, until: instant.addingTimeInterval(100))]
        let clock = FixtureClock(instant)
        let expiredRoot = temporary.appendingPathComponent("expired-catalog")
        let expiredAnchor = MemoryTrustAnchor()
        try store(root: expiredRoot, anchor: expiredAnchor, signers: signers,
                  clock: { clock.date }).accept(sign(fixture.entry, sequence: 1))
        clock.date = instant.addingTimeInterval(10)
        let afterExpiry = try store(root: expiredRoot, anchor: expiredAnchor, signers: signers,
                                    clock: { clock.date })
        try afterExpiry.accept(sign(fixture.entry, sequence: 2,
                                    signerID: "replacement", key: replacementKey))
        try afterExpiry.withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 2)
        }

        let removedRoot = temporary.appendingPathComponent("removed-catalog")
        let removedAnchor = MemoryTrustAnchor()
        try store(root: removedRoot, anchor: removedAnchor, signers: signers)
            .accept(sign(fixture.entry, sequence: 1))
        let onlyNew = try store(root: removedRoot, anchor: removedAnchor,
            signers: ["replacement": signers["replacement"]!])
        try onlyNew.accept(sign(fixture.entry, sequence: 2,
                                signerID: "replacement", key: replacementKey))
        try onlyNew.withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 2)
        }
    }

    func testTrustedFloorIncreaseAndFirstCheckpointRetry() throws {
        let fixture = try makeFixture()
        anchor.failNextCommit = true
        let initial = try store()
        expect(.trustUnavailable) { try initial.accept(sign(fixture.entry, sequence: 1)) }
        XCTAssertNil(try anchor.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogRoot.appendingPathComponent("catalog.0").path))
        try initial.accept(sign(fixture.entry, sequence: 1))
        let raised = try store(floor: 2)
        try raised.accept(sign(fixture.entry, sequence: 2))
        expect(.staleCatalog) { try raised.accept(sign(fixture.entry, sequence: 0)) }
        try raised.withResolved(requirement(fixture.entry)) { _, approved in
            XCTAssertEqual(approved.catalogSequence, 1) // known historical exact pin remains offline
        }

        let restored = temporary.appendingPathComponent("restored-catalog")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let checkpoint = try XCTUnwrap(anchor.read())
        try FileManager.default.copyItem(at: catalogRoot.appendingPathComponent("catalog.\(checkpoint.slot)"),
                                         to: restored.appendingPathComponent("catalog.0"))
        let unanchored = try store(root: restored, anchor: MemoryTrustAnchor())
        expect(.trustUnavailable) { try unanchored.accept(sign(fixture.entry, sequence: 3)) }

        let secondRoot = temporary.appendingPathComponent("bootstrap-interrupted")
        let secondAnchor = MemoryTrustAnchor()
        secondAnchor.failAtCommit = 2
        let secondStore = try store(root: secondRoot, anchor: secondAnchor)
        expect(.trustUnavailable) { try secondStore.accept(sign(fixture.entry, sequence: 1)) }
        XCTAssertEqual(try secondAnchor.read(), .bootstrapping)
        try secondStore.accept(sign(fixture.entry, sequence: 1))
        try secondStore.withResolved(requirement(fixture.entry)) { _, _ in }
    }

    func testRepeatedStoreConstructionDoesNotLeakDescriptors() throws {
        func descriptors() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
        let before = descriptors()
        for _ in 0..<20 { _ = try store() }
        XCTAssertEqual(descriptors(), before)
    }

    private func store(revoked: Bool = false, root: URL? = nil,
                       anchor selectedAnchor: MemoryTrustAnchor? = nil,
                       signers overrideSigners: [String: ToolchainTrustedSigner]? = nil,
                       floor: Int = 1, clock: (() -> Date)? = nil,
                       origins: Set<String> = ["https://releases.example.test"]) throws -> DurableToolchainCatalogStore {
        let directory = root ?? catalogRoot!
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let signer = ToolchainTrustedSigner(publicKey: signingKey.publicKey.rawRepresentation,
            validFrom: instant.addingTimeInterval(-100), validUntil: instant.addingTimeInterval(100), revoked: revoked)
        let policy = try ToolchainTrustPolicy(signers: overrideSigners ?? ["fixture": signer],
            channel: "stable", acceptedSequence: floor,
            knownHistoricalEnvelopeHashes: [], allowedOrigins: origins,
            approvedPublishers: [hostPublisher, servicePublisher, nodePublisher], installedKitRoot: installedRoot.path)
        return try DurableToolchainCatalogStore(root: directory.path, basePolicy: policy,
            anchor: selectedAnchor ?? anchor!, now: clock ?? { [instant] in instant },
            nativeSignature: FixtureExecutableSignature())
    }

    private func makeFixture(archiveOverride: Data? = nil, extraEmbedded: Bool = false) throws -> Fixture {
        let root: [String: Data] = ["bin/node": Data("node".utf8),
            "scripts/build.mjs": Data("build".utf8), "kit.json": Data("kit".utf8)]
        var files = root
        files[ToolchainHostBundleContract.bundle + "/Contents/MacOS/ScreenpunkBuildHost"] = Data("host".utf8)
        files[ToolchainHostBundleContract.service + "/Contents/MacOS/ScreenpunkBuildService"] = Data("service".utf8)
        for (path, bytes) in root {
            files[ToolchainHostBundleContract.embeddedKits + "/kit-1/" + path] = bytes
        }
        if extraEmbedded {
            files[ToolchainHostBundleContract.embeddedKits + "/kit-1/unmirrored.txt"] = Data("extra".utf8)
        }
        let inventory = files.keys.sorted(by: ToolchainCanonical.utf8Less).map { path -> ToolchainInventoryItem in
            let publisher: ToolchainPublisher? = path.hasSuffix("/bin/node") || path == "bin/node" ? nodePublisher :
                (path.hasSuffix("/ScreenpunkBuildHost") ? hostPublisher :
                    (path.hasSuffix("/ScreenpunkBuildService") ? servicePublisher : nil))
            return ToolchainInventoryItem(path: path, sha256: sha(files[path]!), bytes: files[path]!.count,
                role: publisher == nil ? "resource" : "executable", publisher: publisher)
        }
        let archive = archiveOverride ?? tar(files)
        let entry = ToolchainCatalogEntry(catalogEntryId: "kit-1", kind: "authoringKit", version: "1.0.0",
            platform: "darwin-arm64", artifactSha256: sha(archive), artifactBytes: archive.count,
            downloadURL: "https://releases.example.test/kit.tar", publisher: hostPublisher,
            inventoryHash: try ToolchainCanonical.inventoryHash(inventory), inventory: inventory, protocolMajor: nil)
        return Fixture(entry: entry, archive: archive, files: files)
    }

    private func sign(_ entry: ToolchainCatalogEntry, sequence: Int,
                      signerID: String = "fixture", key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let payload = ToolchainCatalogPayload(catalogVersion: 1, catalogId: "release", channel: "stable",
                                              sequence: sequence, entries: [entry])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
        var message = Data("screenpunk/release-catalog/v1".utf8)
        message.append(0); message.append(try ToolchainCanonical.encode(object))
        let signature = try (key ?? signingKey).signature(for: message)
        let envelope = ToolchainCatalogEnvelope(signatureVersion: 1, algorithm: "Ed25519",
            signerKeyId: signerID, signatureBase64: signature.base64EncodedString(), payload: payload)
        return try JSONEncoder().encode(envelope)
    }
    private func trusted(_ key: Curve25519.Signing.PrivateKey,
                         until: Date? = nil) -> ToolchainTrustedSigner {
        ToolchainTrustedSigner(publicKey: key.publicKey.rawRepresentation,
            validFrom: instant.addingTimeInterval(-100),
            validUntil: until ?? instant.addingTimeInterval(100), revoked: false)
    }
    private func requirement(_ entry: ToolchainCatalogEntry) -> WorkspaceToolchainRequirements.Requirement {
        .init(catalogEntryId: entry.catalogEntryId, kitVersion: entry.version,
              platform: entry.platform, inventoryHash: entry.inventoryHash)
    }
    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func expect(_ error: ToolchainTrustError, _ operation: () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? ToolchainTrustError, error, file: file, line: line)
        }
    }

    private struct Fixture { let entry: ToolchainCatalogEntry; let archive: Data; let files: [String: Data] }

    private func tar(_ files: [String: Data], linkAt: String? = nil) -> Data {
        var output = Data()
        for path in files.keys.sorted(by: ToolchainCanonical.utf8Less) {
            let bytes = files[path]!
            var header = [UInt8](repeating: 0, count: 512)
            let components = path.split(separator: "/")
            let name = String(components.last!)
            let prefix = components.dropLast().joined(separator: "/")
            put(name, into: &header, at: 0, length: 100)
            put(prefix, into: &header, at: 345, length: 155)
            putOctal(0o600, into: &header, at: 100, length: 8)
            putOctal(0, into: &header, at: 108, length: 8)
            putOctal(0, into: &header, at: 116, length: 8)
            putOctal(bytes.count, into: &header, at: 124, length: 12)
            putOctal(0, into: &header, at: 136, length: 12)
            for index in 148..<156 { header[index] = 32 }
            header[156] = path == linkAt ? 50 : 48
            put("ustar", into: &header, at: 257, length: 6)
            put("00", into: &header, at: 263, length: 2)
            putOctal(header.reduce(0, { $0 + Int($1) }), into: &header, at: 148, length: 8)
            output.append(contentsOf: header)
            output.append(bytes)
            output.append(Data(repeating: 0, count: (512 - bytes.count % 512) % 512))
        }
        output.append(Data(repeating: 0, count: 1024))
        return output
    }
    private func put(_ value: String, into bytes: inout [UInt8], at position: Int, length: Int) {
        let data = Array(value.utf8)
        precondition(data.count <= length)
        for (index, byte) in data.enumerated() { bytes[position + index] = byte }
    }
    private func putOctal(_ value: Int, into bytes: inout [UInt8], at position: Int, length: Int) {
        let padded = String(value, radix: 8)
        precondition(padded.count < length)
        put(String(repeating: "0", count: length - padded.count - 1) + padded, into: &bytes,
            at: position, length: length)
    }
}

private struct InstalledKitDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

private final class MemoryTrustAnchor: ToolchainTrustAnchoring {
    private var value: ToolchainTrustCheckpoint?
    var failNextCommit = false
    var failAtCommit: Int?
    private var commits = 0
    func read() throws -> ToolchainTrustCheckpoint? { value }
    func commit(_ checkpoint: ToolchainTrustCheckpoint) throws {
        commits += 1
        if failAtCommit == commits { throw ToolchainTrustError.trustUnavailable }
        if failNextCommit { failNextCommit = false; throw ToolchainTrustError.trustUnavailable }
        value = checkpoint
    }
}

private final class FixtureClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private final class FixtureFetcher: ToolchainArtifactFetching {
    let bytes: Data
    let interrupt: Bool
    var calls = 0
    init(bytes: Data, interrupt: Bool = false) { self.bytes = bytes; self.interrupt = interrupt }
    func fetch(_ url: URL, writeChunk: @escaping (Data) throws -> Void) throws {
        XCTAssertEqual(url.host, "releases.example.test")
        calls += 1
        let amount = interrupt ? min(512, bytes.count) : bytes.count
        try writeChunk(bytes.prefix(amount))
        if interrupt { throw ToolchainTrustError.artifactMismatch }
    }
}

private struct FixtureExecutableSignature: ToolchainExecutableSignatureVerifying {
    func verify(fd: Int32, path: String, expected: ToolchainPublisher) throws {
        let valid = path.hasSuffix("/bin/node") ? expected.signingIdentifier == "test.node" :
            (path.hasSuffix("/ScreenpunkBuildHost") ? expected.signingIdentifier == "test.build-host" :
                path.hasSuffix("/ScreenpunkBuildService") && expected.signingIdentifier == "test.build-service")
        guard valid else { throw ToolchainTrustError.publisherUnverified }
    }
}
private struct FixtureBundleSignature: ToolchainHostBundleSignatureVerifying {
    func verify(bundlePath: String, expected: ToolchainPublisher) throws {
        guard expected.signingIdentifier == "test.build-host",
              FileManager.default.fileExists(atPath: bundlePath + "/Contents/MacOS/ScreenpunkBuildHost") else {
            throw ToolchainTrustError.publisherUnverified
        }
    }
}

private final class FixtureCapacity: ToolchainCapacityProviding {
    let total: Int64
    let highAvailable: Int64
    let lowAvailable: Int64
    let dropAfter: Int
    let block: Int64
    private var reads = 0
    init(total: Int64, highAvailable: Int64, lowAvailable: Int64? = nil,
         dropAfter: Int = .max, block: Int64 = 4096) {
        self.total = total; self.highAvailable = highAvailable
        self.lowAvailable = lowAvailable ?? highAvailable
        self.dropAfter = dropAfter; self.block = block
    }
    func capacity(directoryFD: Int32) throws -> ToolchainVolumeCapacity {
        reads += 1
        return ToolchainVolumeCapacity(totalBytes: total,
            availableBytes: reads > dropAfter ? lowAvailable : highAvailable,
            blockBytes: block)
    }
}
