import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DevicePackagePreparationTests: XCTestCase {
    private let rootID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))! }
    private func environment() throws -> (URL, DevicePackageProtectedScope) {
        let base = URL(fileURLWithPath: "/private/tmp/package-preparation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        for name in ["owned", "legacy", "archive", "reset", "cloud", "management", "preferences"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        return (base.appendingPathComponent("owned"), .init(legacyStateRoot: base.appendingPathComponent("legacy"),
            legacyArchiveRoot: base.appendingPathComponent("archive"), resetRoot: base.appendingPathComponent("reset"),
            cloudRoot: base.appendingPathComponent("cloud"), managementRoot: base.appendingPathComponent("management"),
            preferencesRoot: base.appendingPathComponent("preferences"), otherProtectedRoots: []))
    }
    #if canImport(CryptoKit)
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func request(_ value: Int, files supplied: [DevicePackageFile]? = nil, pretty: Bool = false) throws -> DevicePackagePreparationRequest {
        let files = supplied ?? [.init(path: "index.html", bytes: Data("<html>fixture</html>".utf8)), .init(path: "assets/app.js", bytes: Data("app".utf8))]
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: id(value + 1000).uuidString.lowercased(), name: "Fixture",
            revision: id(value + 2000).uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "explicit-profile", width: 390, height: 844, scale: 3, orientation: "portrait"), connections: [],
            files: files.sorted { $0.path < $1.path }.map { .init(path: $0.path, bytes: $0.bytes.count, sha256: hash($0.bytes)) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        manifest.digest = hash(try encoder.encode(manifest))
        if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
        let bytes = try encoder.encode(manifest)
        let revision = StoredRevision(revision: manifest.revision, dashboardId: manifest.dashboardId, name: manifest.name,
            digest: manifest.digest!, orientation: .portrait, width: 390, height: 844)
        let package = try DevicePackageQualifier.qualify(.init(manifest: bytes, files: files), expected: .init(revision: revision,
            target: .init(deviceId: "device", name: "Device"), profileID: "explicit-profile"))
        return .init(operationID: id(value), package: package)
    }
    private func store(_ environment: (URL, DevicePackageProtectedScope), boundary: @escaping (DevicePackagePreparationStore.Boundary) throws -> Void = { _ in }) -> DevicePackagePreparationStore {
        .init(root: environment.0, rootID: rootID, protectedScope: environment.1, boundary: boundary)
    }
    private func homeStore(_ env: (URL, DevicePackageProtectedScope),
        boundary: @escaping (DevicePackagePreparationStore.Boundary) throws -> Void = { _ in }) -> DevicePackagePreparationStore {
        let home = env.0.deletingLastPathComponent()
        return .init(root: env.0, rootID: rootID, protectedScope: env.1,
            contextFactory: { root, fd in
                try .syntheticCurrentAppHomeForTesting(currentRoot: root, heldRoot: fd,
                    systemHome: home.path, physicalHome: home.path)
            }, boundary: boundary)
    }
    /// Real descriptors and ordinary writer identities only; epoch changes are qualified by the
    /// separately owned APFS-remount composition case, never by rewriting issued proof graphs here.
    func testFilesystemContextCaptureFailureUsesPackageUnsafeBindingWithoutEffects() throws {
        enum CaptureFailure: Error { case expected }
        let env = try environment()
        let store = DevicePackagePreparationStore(root: env.0, rootID: rootID, protectedScope: env.1,
            contextFactory: { _, _ in throw CaptureFailure.expected })
        XCTAssertThrowsError(try store.initializeExplicit()) { error in
            XCTAssertEqual(error as? DevicePackagePreparationError, .unsafeBinding)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.0.path), [])
    }
    private final class BoundPreflightBackend: DeviceGrantCredentialBackend, @unchecked Sendable {
        var values: [String: DeviceGrantCredentialValue] = [:]
        var adds = 0
        func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {
            for key in values.keys.sorted() { try visit(values[key]!.item) }
        }
        func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? {
            guard let value = values[account] else { return nil }
            guard value.bytes.count <= maximumBytes else { throw DeviceGrantPreparationError.sizeLimit }
            return value
        }
        func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem {
            guard values[account] == nil else { throw DeviceGrantPreparationError.conflict }
            adds += 1
            let item = DeviceGrantCredentialItem(account: account, persistentReference: Data(UUID().uuidString.utf8), byteCount: bytes.count)
            values[account] = .init(item: item, bytes: bytes)
            return item
        }
    }
    func testInterruptedNestedDirectorySameOwnerBoundPreflightProjectsOnlyCapturedNilSlot() throws {
        for replaceCapturedDirectory in [false, true] {
            let env = try environment(), home = env.0.deletingLastPathComponent()
            let grantRoot = home.appendingPathComponent("bound-grants"), journalRoot = home.appendingPathComponent("bound-journal")
            for root in [grantRoot, journalRoot] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
            let backend = BoundPreflightBackend(), grantID = id(810), journalID = id(811), structuralID = id(812)
            let grants = DeviceGrantPreparationStore(root: grantRoot, rootID: grantID, protectedScope: env.1, backend: backend)
            let journal = DeviceLocalProvisioningIntentStore(root: journalRoot, rootID: journalID, protectedRoots: [env.0])
            var armed = false, creates = 0
            let packages = homeStore(env) { boundary in
                if armed && boundary == .afterCreate(.directory) {
                    creates += 1
                    if creates == 2 { armed = false; throw DevicePackagePreparationError.io(EIO) }
                }
            }
            let first = try request(81, files: [
                .init(path: "index.html", bytes: Data("<html>nested preflight</html>".utf8)),
                .init(path: "assets/nested/app.js", bytes: Data("nested".utf8))
            ])
            let entryID = id(813), owner = PairingIdentity(role: .controller, publicKey: [UInt8](repeating: 7, count: 32))
            let reference = try PackagePreparationCodec.expectedReference(first, rootID: rootID)
            let grantInput = DeviceGrantRevisionInput(schemaVersion: 1, identity: .init(rootID: grantID, revisionID: id(814)),
                owner: owner, entries: [.init(entryID: entryID, revision: first.package.revision,
                    generic: nil, homeAssistant: nil, publicReads: nil, credentialReferences: [])], credentials: [], retainedRevisions: [])
            let expected = [DeviceGrantEntryExpectation(entryID: entryID, package: first.package)]
            let inputs: [DeviceProvisioningPackageInput] = [.supplied(entryID: entryID, operationID: first.operationID, package: first.package)]
            let request = DeviceProvisioningPlanRequest(roots: .init(journalID: journalID, structuralID: structuralID, packageID: rootID, grantID: grantID),
                operationID: id(815), grantOperationID: id(816), expectedGenerationID: nil, baseline: .initialExplicit(legacyGrantSet: "opaque"),
                snapshot: .init(generationID: id(817), entries: [.init(entryID: entryID, displayName: "Nested", revision: first.package.revision,
                    packageDirectory: reference.directory)], configuredEntryID: entryID, contentOwner: owner, grantSet: "opaque"),
                owner: owner, packages: inputs, grantInput: grantInput,
                qualifiedGrant: try DeviceGrantRevisionQualifier.qualify(grantInput, expectedEntries: expected))
            let plan = try DeviceProvisioningPlanner.qualify(request)
            try packages.initializeExplicit(); try grants.initializeExplicit(); try journal.initializeExplicit()
            let receipt = try journal.stageExact(plan)
            let anchor = try DeviceBoundGrantAttemptCoordinator(journal: journal, grants: grants).stageExact(request, plan: plan, journalReceipt: receipt)
            let coordinator = DeviceBoundPackagePreparationCoordinator(journal: journal, grants: grants, packages: packages)
            armed = true
            XCTAssertThrowsError(try coordinator.preparePackagesExact(plan: plan, journalReceipt: receipt, privateAnchor: anchor, packages: inputs))
            XCTAssertEqual(creates, 2)
            let recordURL = env.0.appendingPathComponent("operations/" + first.operationID.uuidString.lowercased() + ".json")
            let recorded = try PackagePreparationCodec.record(Data(contentsOf: recordURL))
            XCTAssertNil(recorded.directoryIdentities[try XCTUnwrap(recorded.plan.directories.firstIndex(of: "assets"))])
            if replaceCapturedDirectory {
                let captured = env.0.appendingPathComponent(recorded.plan.stage + "/assets")
                try FileManager.default.moveItem(at: captured, to: captured.appendingPathExtension("displaced"))
                try FileManager.default.createDirectory(at: captured, withIntermediateDirectories: false)
                let unchanged = try Data(contentsOf: recordURL)
                XCTAssertThrowsError(try coordinator.preparePackagesExact(plan: plan, journalReceipt: receipt, privateAnchor: anchor, packages: inputs))
                XCTAssertEqual(try Data(contentsOf: recordURL), unchanged)
            } else {
                // Calls inspectBoundPackages → matchBoundItems → validatePendingResources,
                // unlike direct recommitExact. V1 failed traversing assets/nested at this point.
                let batch = try coordinator.preparePackagesExact(plan: plan, journalReceipt: receipt, privateAnchor: anchor, packages: inputs)
                try coordinator.verifyPreparedSet(batch)
                let installed = env.0.appendingPathComponent(reference.directory)
                XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("assets/nested/app.js")), Data("nested".utf8))
                XCTAssertEqual(batch.packages.count, 1)
            }
            XCTAssertEqual(backend.adds, 1) // Original private intent only; preflight adds nothing.
        }
    }
    func testSyntheticCurrentHomeReopenAndAppendPreserveHistoricalPackageBytes() throws {
        let env = try environment(), first = try request(71), second = try request(72)
        let initial = homeStore(env); try initial.initializeExplicit()
        let original = try initial.prepareExact(first)
        let bindingURL = env.0.appendingPathComponent("root-binding.json")
        let recordURL = env.0.appendingPathComponent("operations/" + first.operationID.uuidString.lowercased() + ".json")
        let binding = try Data(contentsOf: bindingURL), record = try Data(contentsOf: recordURL)
        let reopened = homeStore(env); try reopened.initializeExplicit()
        let restored = try reopened.recommitExact(first)
        XCTAssertEqual(try reopened.verify(restored).package, first.package)
        let added = try reopened.prepareExact(second)
        XCTAssertEqual(try reopened.verify(added).package, second.package)
        XCTAssertEqual(try Data(contentsOf: bindingURL), binding)
        XCTAssertEqual(try Data(contentsOf: recordURL), record)
        let third = homeStore(env); try third.initializeExplicit()
        _ = try third.recommitExact(second)
        let retained = try third.inspectRetainedTerminalExact([original.reference])
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(try Data(contentsOf: env.0.appendingPathComponent(original.reference.directory + "/manifest.json")), first.package.originalManifestBytes)
        XCTAssertEqual(try Data(contentsOf: bindingURL), binding)
        XCTAssertEqual(try Data(contentsOf: recordURL), record)
    }
    func testSyntheticCurrentHomeRejectsIncoherentRootBindingBeforePackageEffects() throws {
        let env = try environment(), initial = homeStore(env)
        try initial.initializeExplicit() // No content/terminal proof has been issued.
        let url = env.0.appendingPathComponent("root-binding.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var lock = try XCTUnwrap(object["lockIdentity"] as? [String: Any])
        let device = try XCTUnwrap(lock["device"] as? NSNumber).uint64Value
        lock["device"] = NSNumber(value: device ^ 1); object["lockIdentity"] = lock
        let malformed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try malformed.write(to: url)
        XCTAssertThrowsError(try homeStore(env).initializeExplicit()) { error in
            XCTAssertEqual(error as? DevicePackagePreparationError, .unsafeBinding)
        }
        XCTAssertEqual(try Data(contentsOf: url), malformed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.0.appendingPathComponent("operations").path), [])
    }
    func testSyntheticCurrentHomeStillRejectsCapturedLiveRootReplacement() throws {
        let env = try environment(); var armed = false
        let store = homeStore(env) { boundary in
            if armed && boundary == .afterFileSync(.file) {
                armed = false
                let displaced = env.0.appendingPathExtension("displaced")
                try FileManager.default.moveItem(at: env.0, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: env.0)
            }
        }
        try store.initializeExplicit(); armed = true
        XCTAssertThrowsError(try store.prepareExact(try request(73)))
    }
    func testExactPreparationOriginalManifestIdentityAndOldReplayPreserveLaterContent() throws {
        let env = try environment(); let store = store(env)
        try store.initializeExplicit(); let first = try request(1)
        let receipt = try store.prepareExact(first)
        XCTAssertEqual(try store.verify(receipt).package, first.package)
        let installed = env.0.appendingPathComponent(receipt.reference.directory)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("manifest.json")), first.package.originalManifestBytes)
        XCTAssertEqual(try store.diagnose(operationID: first.operationID), .terminalNeedsDurability)
        XCTAssertThrowsError(try store.prepareExact(first))
        let second = try request(2); let secondReceipt = try store.prepareExact(second)
        let later = try Data(contentsOf: env.0.appendingPathComponent(secondReceipt.reference.directory + "/manifest.json"))
        _ = try store.recommitExact(first)
        XCTAssertThrowsError(try store.verify(secondReceipt)) // Old replay cannot qualify the newer tip.
        _ = try store.recommitExact(second)
        XCTAssertEqual(try store.verify(receipt).package, first.package)
        XCTAssertEqual(try Data(contentsOf: env.0.appendingPathComponent(secondReceipt.reference.directory + "/manifest.json")), later)
        let reformatted = try request(1, pretty: true)
        XCTAssertEqual(reformatted.package.deploymentDigest, first.package.deploymentDigest)
        XCTAssertNotEqual(try PackagePreparationCodec.makePlan(reformatted, rootID: rootID, ordinal: 1).contentID, receipt.reference.contentID)
        XCTAssertThrowsError(try store.recommitExact(reformatted))
        _ = try store.recommitExact(second) // Even rejected repair attempts invalidate qualification.
        let newOperation = DevicePackagePreparationRequest(operationID: id(3), package: reformatted.package)
        let reformattedReceipt = try store.prepareExact(newOperation)
        XCTAssertNotEqual(receipt.reference.contentID, reformattedReceipt.reference.contentID)
    }
    func testLegacyDashboardLandscapePreparationReopensAndReadsExactOriginalBytes() throws {
        let env = try environment(), firstStore = store(env)
        let html = Data("<html><body>Legacy Local shape</body></html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: "google-tv-test", name: "Legacy Local",
            revision: id(9001).uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "device-synthetic-local", width: 1024, height: 768, scale: 2, orientation: "landscape"),
            connections: [], files: [.init(path: "index.html", bytes: html.count, sha256: hash(html))])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        manifest.digest = hash(try encoder.encode(manifest))
        let bytes = try encoder.encode(manifest)
        let revision = StoredRevision(revision: manifest.revision, dashboardId: manifest.dashboardId, name: manifest.name,
            digest: manifest.digest!, orientation: .landscape, width: 1024, height: 768)
        let profile = DeviceProfile(deviceId: manifest.target.profileId, name: "Synthetic", width: 768, height: 1024)
        try DevicePackageCompatibilityPreflight.validate(revision: revision, manifest: bytes, files: ["index.html": html],
            profile: profile, profileID: profile.deviceId)
        let package = try DevicePackageQualifier.qualify(.init(manifest: bytes, files: [.init(path: "index.html", bytes: html)]),
            expected: .init(revision: revision, target: profile, profileID: profile.deviceId))
        let request = DevicePackagePreparationRequest(operationID: id(9002), package: package)
        try firstStore.initializeExplicit()
        let receipt = try firstStore.prepareExact(request)
        XCTAssertEqual(try firstStore.verify(receipt).package, package)
        let reopened = store(env)
        let replay = try reopened.recommitExact(request)
        let readback = try reopened.verify(replay)
        XCTAssertEqual(readback.package.originalManifestBytes, bytes)
        XCTAssertEqual(readback.package.manifest.dashboardId, "google-tv-test")
        XCTAssertEqual(readback.package.deploymentDigest, manifest.digest)
        XCTAssertEqual(replay.reference, receipt.reference)
        XCTAssertEqual(try Data(contentsOf: env.0.appendingPathComponent(replay.reference.directory).appendingPathComponent("manifest.json")), bytes)
        let plan = try PackagePreparationCodec.makePlan(request, rootID: rootID, ordinal: 1)
        // Persisted metadata retains bounded IDs and UUID revisions when it is reopened.
        for (key, value) in [("dashboardId", "../legacy"), ("dashboardId", String(repeating: "a", count: 101)),
            ("revision", "legacy-revision")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
            var storedRevision = try XCTUnwrap(object["revision"] as? [String: Any])
            storedRevision[key] = value; object["revision"] = storedRevision
            let badPlan = try JSONDecoder().decode(PreparationPlan.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try PackagePreparationCodec.validate(badPlan)) { XCTAssertEqual($0 as? DevicePackagePreparationError, .invalidMetadata) }
        }
    }
    func testFaultBoundariesRequireExactRecommitAcrossRestart() throws {
        var points: [DevicePackagePreparationStore.Boundary] = []
        for kind in [DevicePackagePreparationStore.Kind.intent, .progress, .terminal] {
            points += [.afterWrite(kind), .afterFileSync(kind), .beforeReplace(kind), .afterReplace(kind), .afterDirectorySync(kind)]
        }
        points += [.afterWrite(.file), .afterFileSync(.file), .beforeReplace(.install), .afterReplace(.install), .afterDirectorySync(.install), .afterDirectorySync(.directory)]
        for point in points {
            let env = try environment(); let first = try request(1); var fired = false
            let interrupted = store(env) { if $0 == point && !fired { fired = true; throw DevicePackagePreparationError.io(EIO) } }
            try interrupted.initializeExplicit()
            XCTAssertThrowsError(try interrupted.prepareExact(first), "\(point)")
            XCTAssertTrue(fired, "\(point)")
            let reconstructed = store(env); try reconstructed.initializeExplicit()
            XCTAssertThrowsError(try reconstructed.prepareExact(first))
            let receipt = try reconstructed.recommitExact(first)
            XCTAssertEqual(try reconstructed.verify(receipt).package, first.package, "\(point)")
        }
    }
    func testUnrecordedCreationOrphansBlockRestartWithoutDeletionOrAdoption() throws {
        for point in [DevicePackagePreparationStore.Boundary.afterCreate(.directory), .afterCreate(.file)] {
            let env = try environment(); let first = try request(1); var fired = false
            let interrupted = store(env) { if $0 == point && !fired { fired = true; throw DevicePackagePreparationError.io(EIO) } }
            try interrupted.initializeExplicit(); XCTAssertThrowsError(try interrupted.prepareExact(first))
            let staging = env.0.appendingPathComponent("preparing-" + first.operationID.uuidString.lowercased())
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
            let before = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            let reconstructed = store(env); try reconstructed.initializeExplicit()
            XCTAssertThrowsError(try reconstructed.recommitExact(first))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), before)
            let repaired = try interrupted.recommitExact(first)
            XCTAssertEqual(try interrupted.verify(repaired).package, first.package)
        }
    }
    func testUnknownBindingResidueCannotBeIgnoredByQualifiedInstance() throws {
        let env = try environment(); let instance = store(env)
        try instance.initializeExplicit()
        let residue = env.0.appendingPathComponent("root-binding.json.pending")
        try Data("{corrupt".utf8).write(to: residue)
        XCTAssertThrowsError(try instance.prepareExact(request(1)))
        XCTAssertThrowsError(try instance.initializeExplicit())
        XCTAssertEqual(try Data(contentsOf: residue), Data("{corrupt".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.0.appendingPathComponent("operations").path), [])
    }
    func testVisibleBindingAndTerminalNeedExplicitDurabilityRepair() throws {
        let env = try environment(); let first = try request(1)
        let bindingFailure = store(env) { if $0 == .afterReplace(.binding) { throw DevicePackagePreparationError.io(EIO) } }
        XCTAssertThrowsError(try bindingFailure.initializeExplicit())
        let reconstructed = store(env)
        XCTAssertThrowsError(try reconstructed.prepareExact(first))
        try reconstructed.initializeExplicit()
        var fired = false
        let terminalFailure = store(env) { if $0 == .afterReplace(.terminal) && !fired { fired = true; throw DevicePackagePreparationError.io(EIO) } }
        try terminalFailure.initializeExplicit(); XCTAssertThrowsError(try terminalFailure.prepareExact(first))
        XCTAssertEqual(try reconstructed.diagnose(operationID: first.operationID), .terminalNeedsDurability)
        XCTAssertThrowsError(try reconstructed.prepareExact(request(2)))
        let receipt = try reconstructed.recommitExact(first)
        XCTAssertEqual(try reconstructed.verify(receipt).package, first.package)
        let fresh = store(env); try fresh.initializeExplicit()
        XCTAssertThrowsError(try fresh.verify(receipt))
        XCTAssertThrowsError(try fresh.prepareExact(request(2)))
        let freshReceipt = try fresh.recommitExact(first)
        XCTAssertEqual(try fresh.verify(freshReceipt).package, first.package)
    }
    func testAnotherInstanceUncertaintyInvalidatesPreviouslyIssuedProof() throws {
        let env = try environment(); let first = try request(1); let a = store(env)
        try a.initializeExplicit(); let original = try a.prepareExact(first)
        let b = store(env) { if $0 == .afterReplace(.terminal) { throw DevicePackagePreparationError.io(EIO) } }
        try b.initializeExplicit(); XCTAssertThrowsError(try b.recommitExact(first))
        XCTAssertThrowsError(try a.verify(original))
        XCTAssertThrowsError(try a.prepareExact(request(2)))
        _ = try a.recommitExact(first)
        XCTAssertEqual(try a.verify(original).package, first.package)
    }
    func testSameByteFileDirectoryLockAndRootReplacementAreRejected() throws {
        for kind in 0...3 {
            let env = try environment(); let first = try request(1); let store = store(env)
            try store.initializeExplicit(); let receipt = try store.prepareExact(first)
            let installed = env.0.appendingPathComponent(receipt.reference.directory)
            switch kind {
            case 0: try first.package.originalManifestBytes.write(to: installed.appendingPathComponent("manifest.json"), options: .atomic)
            case 1:
                let moved = installed.appendingPathExtension("old")
                try FileManager.default.moveItem(at: installed, to: moved)
                try FileManager.default.copyItem(at: moved, to: installed)
            case 2: try Data().write(to: env.0.appendingPathComponent("preparation.lock"), options: .atomic)
            default:
                let moved = env.0.appendingPathExtension("old")
                try FileManager.default.moveItem(at: env.0, to: moved)
                try FileManager.default.copyItem(at: moved, to: env.0)
            }
            XCTAssertThrowsError(try store.verify(receipt))
            XCTAssertThrowsError(try self.store(env).recommitExact(first))
        }
    }
    func testPreexistingContentSymlinksSpecialNodesHardlinksAndScopeSentinels() throws {
        let env = try environment(); let first = try request(1)
        let sentinel = env.1.legacyArchiveRoot.appendingPathComponent("archive-sentinel")
        try Data("preserved legacy".utf8).write(to: sentinel)
        let overlap = DevicePackagePreparationStore(root: env.1.legacyArchiveRoot, rootID: rootID, protectedScope: env.1)
        XCTAssertThrowsError(try overlap.initializeExplicit())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserved legacy".utf8))
        let unknown = env.0.appendingPathComponent("unknown")
        try Data("untouched".utf8).write(to: unknown)
        XCTAssertThrowsError(try store(env).initializeExplicit())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.0.path), ["unknown"])
        for type in 0...2 {
            let isolated = try environment(); let store = store(isolated); try store.initializeExplicit()
            var fired = false
            let corrupt = self.store(isolated) { point in
                if point == .afterCreate(.file) && !fired {
                    fired = true
                    let target = isolated.0.appendingPathComponent("preparing-" + first.operationID.uuidString.lowercased() + "/manifest.json")
                    if type == 2 {
                        XCTAssertEqual(link(target.path, isolated.0.appendingPathComponent("hard-link").path), 0)
                    } else {
                        try FileManager.default.removeItem(at: target)
                        if type == 0 { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: sentinel) }
                        else { XCTAssertEqual(mkfifo(target.path, 0o600), 0) }
                    }
                }
            }
            try corrupt.initializeExplicit(); XCTAssertThrowsError(try corrupt.prepareExact(first))
            XCTAssertTrue(fired); XCTAssertThrowsError(try self.store(isolated).recommitExact(first))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserved legacy".utf8))
        }
        let reused = try environment(); let reuseStore = store(reused); try reuseStore.initializeExplicit()
        let plan = try PackagePreparationCodec.makePlan(first, rootID: rootID, ordinal: 1)
        let leaf = reused.0.appendingPathComponent(plan.leaf)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false)
        try first.package.originalManifestBytes.write(to: leaf.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try reuseStore.prepareExact(first))
        XCTAssertEqual(try Data(contentsOf: leaf.appendingPathComponent("manifest.json")), first.package.originalManifestBytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: reused.0.appendingPathComponent("operations").path).isEmpty)
    }
    func testMetadataStrictnessPlanBoundsAndNoEffectsOnPathDepthFailure() throws {
        let env = try environment(); let store = store(env); try store.initializeExplicit()
        let first = try request(1); let record = PreparationRecord(plan: try PackagePreparationCodec.makePlan(first, rootID: rootID, ordinal: 1))
        let bytes = try PackagePreparationCodec.encode(record); let text = String(decoding: bytes, as: UTF8.self)
        for value in [text + "{}", text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schema\\u0056ersion\":1"),
                      text.replacingOccurrences(of: "\"profileID\":\"explicit-profile\"", with: "\"profileID\":\"\\uD800\""),
                      text.replacingOccurrences(of: "\"width\":390", with: "\"width\":390,\"future\":1")] {
            XCTAssertThrowsError(try PackagePreparationCodec.record(Data(value.utf8)))
        }
        XCTAssertThrowsError(try PackagePreparationCodec.object(Data(repeating: 32, count: PackagePreparationCodec.metadataLimit + 1)))
        let deep = Array(repeating: "a", count: 32).joined(separator: "/") + "/x"
        let depthRequest = try request(2, files: [.init(path: "index.html", bytes: Data([1])), .init(path: deep, bytes: Data([2]))])
        XCTAssertThrowsError(try store.prepareExact(depthRequest))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: env.0.appendingPathComponent("operations").path).isEmpty)
        let conflicting = try request(3, files: [.init(path: "index.html", bytes: Data([1])), .init(path: "a", bytes: Data([2])), .init(path: "a/b", bytes: Data([3]))])
        XCTAssertThrowsError(try store.prepareExact(conflicting))
        var files = [DevicePackageFile(path: "index.html", bytes: Data([1]))]
        for value in 1..<2000 { files.append(.init(path: "d\(value)/e\(value)/f\(value)/x", bytes: Data([1]))) }
        let manyDirectories = try request(4, files: files)
        XCTAssertThrowsError(try store.prepareExact(manyDirectories))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: env.0.appendingPathComponent("operations").path).isEmpty)
    }
    func testOneUnresolvedAndTerminalCapacityNeverPruneResourcesOrProof() throws {
        let env = try environment(); let store = store(env); try store.initializeExplicit()
        var firstReceipt: DevicePreparedPackageReceipt?
        for value in 1...128 {
            let receipt = try store.prepareExact(request(value))
            if value == 1 { firstReceipt = receipt }
        }
        XCTAssertThrowsError(try store.prepareExact(request(129))) { XCTAssertEqual($0 as? DevicePackagePreparationError, .capacity) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.0.appendingPathComponent("operations").path).count, 128)
        XCTAssertEqual(try store.verify(firstReceipt!).reference, firstReceipt!.reference)
        let originalManifest = env.0.appendingPathComponent(firstReceipt!.reference.directory + "/manifest.json")
        XCTAssertEqual(try Data(contentsOf: originalManifest), try request(1).package.originalManifestBytes)
        let pendingEnv = try environment(); var fired = false
        let interrupted = self.store(pendingEnv) { if $0 == .afterWrite(.file) && !fired { fired = true; throw DevicePackagePreparationError.io(EIO) } }
        try interrupted.initializeExplicit(); XCTAssertThrowsError(try interrupted.prepareExact(request(1)))
        XCTAssertThrowsError(try interrupted.prepareExact(request(2)))
    }
    #else
    func testPreparationContentIdentityRequiresActualCryptoKit() {
        XCTAssertThrowsError(try PackagePreparationCodec.contentID([], digest: String(repeating: "a", count: 64))) { XCTAssertEqual($0 as? DevicePackagePreparationError, .digestUnavailable) }
    }
    #endif
}
