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
