import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import ScreenpunkCore

/// Ordinary runs exercise every phase on one filesystem. Only the separately
/// reviewed image driver qualifies real mount changes; no identities are edited.
final class DeviceCompletedLocalFilesystemEpochTests: XCTestCase {
    private let ownerMarker = "Screenpunk/01a12675/completed-local-epoch-v1"
    private let storeNames = ["packages", "grants", "structural", "journal"]
    private enum Failure: Error { case invalidFixture, invalidPhase, changedHistory }
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    private var owner: PairingIdentity { .init(role: .controller, publicKey: [UInt8](repeating: 7, count: 32)) }
    private var roots: DeviceProvisioningRoots { .init(journalID: id(1), structuralID: id(2), packageID: id(3), grantID: id(4)) }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private struct Node: Codable {
        let inode: UInt64, device: UInt64
        let bytes: Data?
    }
    private struct Oracle: Codable {
        let ordinal: Int, operationID: UUID, generationID: UUID, envelope: Data
        let credentialCount: Int, history: [String: Node], observedDevices: [UInt64]
    }
    /// Synthetic credentials survive separate test processes, with immutable
    /// add-only files and stable references. This never accesses Keychain.
    private final class Backend: DeviceGrantCredentialBackend, @unchecked Sendable {
        private struct Value: Codable { let item: DeviceGrantCredentialItem; let bytes: Data }
        let root: URL
        init(root: URL) { self.root = root }
        private func path(_ account: String) throws -> URL {
            guard !account.isEmpty, account.utf8.count <= 256 else { throw Failure.invalidFixture }
            return root.appendingPathComponent(Data(account.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json")
        }
        func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            guard names.count <= maximum, names.count <= 32 else { throw DeviceGrantPreparationError.sizeLimit }
            for name in names {
                guard name.hasSuffix(".json") else { throw Failure.invalidFixture }
                let value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: root.appendingPathComponent(name)))
                guard try path(value.item.account).lastPathComponent == name else { throw Failure.invalidFixture }
                try visit(value.item)
            }
        }
        func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? {
            let url = try path(account)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
            guard value.item.account == account, value.item.byteCount == value.bytes.count,
                value.bytes.count <= maximumBytes else { throw DeviceGrantPreparationError.sizeLimit }
            return .init(item: value.item, bytes: value.bytes)
        }
        func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem {
            guard bytes.count <= 512 * 1024 else { throw DeviceGrantPreparationError.sizeLimit }
            let url = try path(account)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw DeviceGrantPreparationError.conflict }
            let item = DeviceGrantCredentialItem(account: account, persistentReference: Data(UUID().uuidString.utf8), byteCount: bytes.count)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Value(item: item, bytes: bytes)).write(to: url, options: .withoutOverwriting)
            return item
        }
        var count: Int { get throws { try FileManager.default.contentsOfDirectory(atPath: root.path).count } }
    }
    private final class Effects { var count = 0 }
    private struct Stores {
        let packages: DevicePackagePreparationStore, grants: DeviceGrantPreparationStore
        let structural: DeviceStructuralStore, journal: DeviceLocalProvisioningIntentStore, backend: Backend
        let effects: Effects
        var coordinator: DeviceLocalCompleteSetCommitCoordinator { .init(packageStore: packages, grantStore: grants, structuralStore: structural) }
        func restore() throws -> DeviceBoundRestoredRuntimeBinding {
            let result = try DeviceLocalCompleteSetRestoreCoordinator(packageStore: packages, grantStore: grants, structuralStore: structural).restoreLatestBoundCompletedExact(journal: journal)
            try DeviceLocalResourceGate(packageStore: packages, grantStore: grants, structuralStore: structural).verifyBoundRestoredRuntimeBinding(result)
            return result
        }
    }
    private func stores(_ home: URL) throws -> Stores {
        let protected = home.appendingPathComponent("protected")
        let credentials = home.appendingPathComponent("credentials")
        let scope = DevicePackageProtectedScope(legacyStateRoot: protected.appendingPathComponent("state"), legacyArchiveRoot: protected.appendingPathComponent("archive"), resetRoot: protected.appendingPathComponent("reset"), cloudRoot: protected.appendingPathComponent("cloud"), managementRoot: protected.appendingPathComponent("management"), preferencesRoot: protected.appendingPathComponent("preferences"), otherProtectedRoots: [credentials, home.appendingPathComponent("oracle")])
        // StructuralStore standardizes its non-iOS URL; the other stores retain
        // the supplied physical spelling. Model both spellings of this SAME home,
        // as production does, and let the helper verify the held descriptor.
        let systemHome = home.standardizedFileURL.path
        guard let physical = realpath(home.path, nil) else { throw Failure.invalidFixture }
        let physicalHome = String(cString: physical); free(physical)
        let context: (URL, Int32) throws -> DevicePersistedFilesystemContext = { root, fd in
            do {
                return try .syntheticCurrentAppHomeForTesting(currentRoot: root, heldRoot: fd, systemHome: systemHome, physicalHome: physicalHome)
            } catch {
                print("EPOCH_CONTEXT_CAPTURE_FAILED root=\(root.path) systemHome=\(systemHome) physicalHome=\(physicalHome) error=\(error)")
                throw error
            }
        }
        let backend = Backend(root: credentials), effects = Effects()
        return .init(packages: .init(root: home.appendingPathComponent("packages"), rootID: roots.packageID, protectedScope: scope, contextFactory: context, boundary: { _ in effects.count += 1 }),
            grants: .init(root: home.appendingPathComponent("grants"), rootID: roots.grantID, protectedScope: scope, backend: backend, contextFactory: context, boundary: { _ in effects.count += 1 }),
            structural: .init(root: home.appendingPathComponent("structural"), rootID: roots.structuralID, contextFactory: context, boundary: { _ in effects.count += 1 }),
            journal: .init(root: home.appendingPathComponent("journal"), rootID: roots.journalID, protectedRoots: scope.roots, contextFactory: context, boundary: { _ in effects.count += 1 }), backend: backend, effects: effects)
    }
    private func identity(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT != S_IFLNK else { throw Failure.invalidFixture }
        return value
    }
    private func history(_ home: URL) throws -> [String: Node] {
        let device = UInt64(truncatingIfNeeded: try identity(home).st_dev)
        var result: [String: Node] = [:]
        let mutable: Set<String> = ["grants/head.json", "journal/head.json", "structural/structural-envelope.json"]
        for store in storeNames {
            let paths = [store] + (try FileManager.default.subpathsOfDirectory(atPath: home.appendingPathComponent(store).path)).map { store + "/" + $0 }
            for path in paths where !mutable.contains(path) {
                let url = home.appendingPathComponent(path), raw = try identity(url)
                guard UInt64(truncatingIfNeeded: raw.st_dev) == device, raw.st_mode & S_IFMT == S_IFDIR || raw.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidFixture }
                result[path] = .init(inode: UInt64(raw.st_ino), device: UInt64(truncatingIfNeeded: raw.st_dev), bytes: raw.st_mode & S_IFMT == S_IFREG ? try Data(contentsOf: url) : nil)
            }
        }
        return result
    }
    private func allStoreBytes(_ home: URL) throws -> [String: Data] {
        var bytes: [String: Data] = [:]
        for store in storeNames {
            for path in try FileManager.default.subpathsOfDirectory(atPath: home.appendingPathComponent(store).path) {
                let relative = store + "/" + path, url = home.appendingPathComponent(relative)
                if try identity(url).st_mode & S_IFMT == S_IFREG { bytes[relative] = try Data(contentsOf: url) }
            }
        }
        return bytes
    }
    private func assertHistory(_ old: [String: Node], _ current: [String: Node]) throws {
        for (path, node) in old {
            guard let now = current[path], now.inode == node.inode, now.bytes == node.bytes else { throw Failure.changedHistory }
        }
    }
    #if canImport(CryptoKit)
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func package(_ n: Int) throws -> QualifiedDevicePackage {
        let html = Data("<html>epoch package \(n)</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: id(100+n).uuidString.lowercased(), name: "Epoch \(n)", revision: id(200+n).uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "profile", width: 390, height: 844, scale: 3, orientation: "portrait"), connections: [.init(alias: "api", required: false, operations: [.init(name: "read", kind: "http")])], files: [.init(path: "index.html", bytes: html.count, sha256: hash(html))])
        manifest.digest = hash(try encode(manifest))
        let revision = StoredRevision(revision: manifest.revision, dashboardId: manifest.dashboardId, name: manifest.name, digest: manifest.digest!, orientation: .portrait, width: 390, height: 844)
        return try DevicePackageQualifier.qualify(.init(manifest: encode(manifest), files: [.init(path: "index.html", bytes: html)]), expected: .init(revision: revision, target: .init(deviceId: "device", name: "Device"), profileID: "profile"))
    }
    private func request(_ ordinal: Int, stores: Stores, previous: DeviceLocalCompleteSetCommitAcknowledgment?) throws -> DeviceProvisioningPlanRequest {
        let count = ordinal + 2
        var packages: [DeviceProvisioningPackageInput] = [], entries: [DeviceGrantEntryInput] = [], installed: [DeviceStructuralEntry] = [], expectations: [DeviceGrantEntryExpectation] = [], credentials: [DeviceGrantCredentialInput] = []
        for n in 0..<count {
            let value = try package(n), entryID = id(400+n)
            let reference = try PackagePreparationCodec.expectedReference(.init(operationID: id(300+n), package: value), rootID: roots.packageID)
            if ordinal > 0 && n < count-1 {
                let verified = try XCTUnwrap(stores.packages.inspectRetainedTerminalExact([reference]).first)
                XCTAssertEqual(verified.package, value)
                packages.append(.retained(entryID: entryID, reference: reference, verified: verified))
            } else { packages.append(.supplied(entryID: entryID, operationID: id(300+n), package: value)) }
            expectations.append(.init(entryID: entryID, package: value))
            installed.append(.init(entryID: entryID, displayName: "Epoch screen \(n)", revision: value.revision, packageDirectory: reference.directory))
            let secret = Data("SYNTHETIC_EPOCH_CREDENTIAL_\(n)".utf8)
            let grant = ConnectionGrant(schemaVersion: 1, id: id(500+n), alias: "api", origin: "https://example.com", transport: .http, authRef: "logical", lan: false, allowInsecureHTTP: false, operations: [.init(name: "read", kind: .http, method: .GET, path: "/states", idempotent: true, write: false)])
            let provisioning = ConnectionProvisioning(dashboardId: value.revision.dashboardId, revision: value.revision.revision, provisioningId: "explicit-test-approval", entries: [.init(grant: grant, binding: .init(authRef: "logical", placement: .bearer), secret: secret)])
            entries.append(.init(entryID: entryID, revision: value.revision, generic: provisioning, homeAssistant: nil, publicReads: nil, credentialReferences: [.init(credentialRevisionID: id(600+n), kind: .generic, key: "logical")]))
            credentials.append(.init(revisionID: id(600+n), bytes: secret))
        }
        let input = DeviceGrantRevisionInput(schemaVersion: 1, identity: .init(rootID: roots.grantID, revisionID: id(700+ordinal)), owner: owner, entries: entries, credentials: credentials, retainedRevisions: [])
        return .init(roots: roots, operationID: id(800+ordinal), grantOperationID: id(900+ordinal), expectedGenerationID: previous?.generationID, baseline: previous.map { .expectedEnvelope($0.envelopeBytes) } ?? .initialExplicit(legacyGrantSet: "opaque"), snapshot: .init(generationID: id(1000+ordinal), entries: installed, configuredEntryID: installed.last?.entryID, contentOwner: owner, grantSet: "opaque"), owner: owner, packages: packages, grantInput: input, qualifiedGrant: try DeviceGrantRevisionQualifier.qualify(input, expectedEntries: expectations))
    }
    private func progress(_ label: String) { print("EPOCH_PROGRESS " + label) }
    /// Read-only restore deliberately cannot release successor capacity. Replay
    /// the actual retained private terminal through the genuine commit/completion
    /// APIs after the LAST restore, then retain that same-instance qualification.
    private func requalifyPredecessor(stores: Stores, home: URL, expected: Oracle) throws -> DeviceLocalCompleteSetCommitAcknowledgment {
        let originalBytes = try allStoreBytes(home), originalHistory = try history(home)
        let additions = try stores.backend.count
        let preparation = DeviceBoundPackagePreparationCoordinator(journal: stores.journal, grants: stores.grants, packages: stores.packages)
        let recovery = try preparation.inspectGrantTerminalRecoveryExact()
        progress("predecessor-recovery-inspected-ok")
        let terminal = try preparation.recommitGrantTerminalExact(recovery)
        progress("predecessor-terminal-requalified-ok")
        let acknowledgment = try stores.coordinator.commitBoundTerminalExact(terminal, journal: stores.journal)
        progress("predecessor-structural-replay-ok")
        XCTAssertEqual(acknowledgment.operationID, expected.operationID)
        XCTAssertEqual(acknowledgment.generationID, expected.generationID)
        XCTAssertEqual(acknowledgment.envelopeBytes, expected.envelope)
        let completion = try stores.coordinator.completeProvisioningExact(terminal, acknowledgment: acknowledgment, journal: stores.journal)
        progress("predecessor-completion-republished-ok")
        try stores.journal.verifyCompletion(completion)
        progress("predecessor-completion-verified-ok")
        XCTAssertEqual(try stores.backend.count, additions)
        XCTAssertEqual(try allStoreBytes(home), originalBytes)
        try assertHistory(originalHistory, history(home))
        // No restore may occur here or before successor stageExact: it would
        // intentionally clear the genuine completion qualification again.
        return acknowledgment
    }
    private func complete(_ request: DeviceProvisioningPlanRequest, stores: Stores, successor: Bool) throws -> DeviceLocalCompleteSetCommitAcknowledgment {
        let plan = try DeviceProvisioningPlanner.qualify(request)
        progress("plan-ok")
        let pending = try stores.journal.stageExact(plan)
        progress("stage-ok")
        let preparation = DeviceBoundPackagePreparationCoordinator(journal: stores.journal, grants: stores.grants, packages: stores.packages)
        let anchor: DeviceBoundGrantPrivateAttempt
        let receipt: DeviceLocalProvisioningIntentStore.Receipt
        // Use the same genuine bound preparation sequence as the existing
        // completed-restore fixture, including successor ancestry qualification.
        if successor {
            let staged = try preparation.prepareSuccessorPrivateAttemptExact(request, plan: plan, journalReceipt: pending)
            anchor = staged.privateAnchor; receipt = staged.journalReceipt
        } else {
            anchor = try DeviceBoundGrantAttemptCoordinator(journal: stores.journal, grants: stores.grants).stageExact(request, plan: plan, journalReceipt: pending)
            receipt = pending
        }
        progress("private-attempt-ok")
        let batch = try preparation.preparePackagesExact(plan: plan, journalReceipt: receipt, privateAnchor: anchor, packages: request.packages)
        progress("package-batch-ok")
        let completed = try preparation.completeCredentialsExact(batch)
        progress("credentials-ok")
        let terminal = try preparation.closeGrantTerminalExact(completed)
        progress("terminal-ok")
        let ack = try stores.coordinator.commitBoundTerminalExact(terminal, journal: stores.journal)
        progress("structural-commit-ok")
        let completion = try stores.coordinator.completeProvisioningExact(terminal, acknowledgment: ack, journal: stores.journal)
        progress("provisioning-completion-ok")
        try stores.journal.verifyCompletion(completion)
        progress("verify-completion-ok")
        return ack
    }
    private func phase(_ name: String, home: URL) throws {
        progress("phase-" + name + "-begin")
        let oracleURL = home.appendingPathComponent("oracle/state.json"), current = try stores(home)
        let before = try history(home), device = UInt64(truncatingIfNeeded: try identity(home).st_dev)
        let old = FileManager.default.fileExists(atPath: oracleURL.path) ? try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: oracleURL)) : nil
        if name == "create" {
            guard old == nil else { throw Failure.invalidPhase }
            try current.packages.initializeExplicit()
            progress("initialize-packages-ok")
            try current.grants.initializeExplicit()
            progress("initialize-grants-ok")
            try current.structural.initializeExplicit()
            progress("initialize-structural-ok")
            try current.journal.initializeExplicit()
            progress("initialize-provisioning-ok")
        } else {
            guard let old else { throw Failure.invalidPhase }
            try assertHistory(old.history, before)
            if name == "reject-drift" {
                guard old.observedDevices.last != device else { throw Failure.invalidPhase }
                let exactBytes = try allStoreBytes(home), additions = try current.backend.count
                do { _ = try current.restore(); XCTFail("Strict comparator admitted actual device drift") }
                catch let error as DeviceGrantPreparationError { XCTAssertEqual(error, .unsafeBinding) }
                // A different error propagates: setup/compile/other failure is not RED evidence.
                XCTAssertEqual(current.effects.count, 0)
                XCTAssertEqual(try allStoreBytes(home), exactBytes)
                try assertHistory(before, history(home))
                XCTAssertEqual(try current.backend.count, additions)
                print("EPOCH_RED_DURABLE_IDENTITY_REJECTED_BEFORE_EFFECTS")
                return
            }
            let additions = try current.backend.count, restored = try current.restore()
            progress("fresh-restore-ok")
            XCTAssertEqual(restored.operationID, old.operationID); XCTAssertEqual(restored.generationID, old.generationID); XCTAssertEqual(restored.envelopeBytes, old.envelope)
            XCTAssertEqual(try current.backend.count, additions)
            try assertHistory(before, history(home))
            if name == "probe" || name == "restore" {
                if name == "restore" { guard old.ordinal == 2 else { throw Failure.invalidPhase } }
                let fresh = try stores(home), replay = try fresh.restore()
                progress("fresh-restore-replay-ok")
                XCTAssertEqual(replay.envelopeBytes, old.envelope)
                XCTAssertEqual(try fresh.backend.count, old.credentialCount)
                for n in 0..<(old.ordinal+2) {
                    let value = try package(n), reference = try PackagePreparationCodec.expectedReference(.init(operationID: id(300+n), package: value), rootID: roots.packageID)
                    XCTAssertEqual(try fresh.packages.inspectRetainedTerminalExact([reference]).first?.package, value)
                }
                try assertHistory(old.history, history(home))
                XCTAssertEqual(restored.operationID, replay.operationID)
                return
            }
        }
        guard name == "create" || name == "append" else { throw Failure.invalidPhase }
        let ordinal = old.map { $0.ordinal+1 } ?? 0
        guard ordinal <= 2 else { throw Failure.invalidPhase }
        // The earlier phase validation performed the LAST restore. Complete
        // genuine predecessor replay BEFORE capturing the new request/baseline.
        let previous: DeviceLocalCompleteSetCommitAcknowledgment? = try old.map {
            try requalifyPredecessor(stores: current, home: home, expected: $0)
        }
        let input = try request(ordinal, stores: current, previous: previous)
        XCTAssertEqual(input.expectedGenerationID, old?.generationID)
        let ack = try complete(input, stores: current, successor: old != nil)
        XCTAssertEqual(ack.operationID, input.operationID); XCTAssertEqual(ack.generationID, input.snapshot.generationID)
        let fresh = try stores(home), restored = try fresh.restore()
        progress("fresh-restore-ok")
        XCTAssertEqual(restored.envelopeBytes, ack.envelopeBytes)
        let snapshot = try StructuralStoreCodec.envelope(restored.envelopeBytes).snapshot
        XCTAssertEqual(snapshot.entries.map(\.entryID), (0..<(ordinal+2)).map { id(400+$0) })
        XCTAssertEqual(snapshot.entries.map(\.displayName), (0..<(ordinal+2)).map { "Epoch screen \($0)" })
        XCTAssertEqual(snapshot.configuredEntryID, id(400+ordinal+1))
        let after = try history(home); try assertHistory(before, after)
        XCTAssertEqual(try fresh.backend.count, (ordinal+2) + (ordinal+1))
        let oracle = Oracle(ordinal: ordinal, operationID: ack.operationID, generationID: ack.generationID, envelope: ack.envelopeBytes, credentialCount: try fresh.backend.count, history: after, observedDevices: (old?.observedDevices ?? []) + [device])
        try encode(oracle).write(to: oracleURL, options: .atomic)
    }
    func testGenuineCompletedGraphAcrossFreshStoreEpochPhases() throws {
        let env = ProcessInfo.processInfo.environment
        if let path = env["SCREENPUNK_COMPLETED_EPOCH_ROOT"] {
            guard let name = env["SCREENPUNK_COMPLETED_EPOCH_PHASE"], ["create", "append", "restore", "probe", "reject-drift"].contains(name) else { throw Failure.invalidPhase }
            let home = URL(fileURLWithPath: path, isDirectory: true)
            guard try String(contentsOf: home.appendingPathComponent(".screenpunk-epoch-fixture-owner"), encoding: .utf8) == ownerMarker else { throw Failure.invalidFixture }
            try phase(name, home: home)
        } else {
            guard env["SCREENPUNK_COMPLETED_EPOCH_PHASE"] == nil else { throw Failure.invalidPhase }
            let raw = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(raw) }
            let home = URL(fileURLWithPath: String(cString: raw)).appendingPathComponent("completed-local-epochs-"+UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: home) }
            for name in storeNames + ["credentials", "oracle", "protected"] { try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: false) }
            for name in ["create", "append", "append", "restore"] { try phase(name, home: home) }
        }
    }
    #else
    func testGenuineCompletedGraphAcrossFreshStoreEpochPhases() throws { throw Failure.invalidFixture }
    #endif
}
