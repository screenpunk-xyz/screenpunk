import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ScreenpunkCore

final class DeviceLegacyInventoryMigrationTests: XCTestCase {
    private final class Backend: DeviceGrantCredentialBackend {
        var values: [String: DeviceGrantCredentialValue] = [:]
        func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {
            guard values.count <= maximum else { throw DeviceGrantPreparationError.sizeLimit }
            for key in values.keys.sorted() { try visit(values[key]!.item) }
        }
        func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? {
            guard let value = values[account] else { return nil }
            guard value.bytes.count <= maximumBytes else { throw DeviceGrantPreparationError.sizeLimit }; return value
        }
        func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem {
            guard values[account] == nil else { throw DeviceGrantPreparationError.conflict }
            let item = DeviceGrantCredentialItem(account: account, persistentReference: Data(UUID().uuidString.utf8), byteCount: bytes.count)
            values[account] = .init(item: item, bytes: bytes); return item
        }
    }
    private enum Revoked: Error { case original }
    func testGenuineDurableEmptyLegacyInventoryRestoresWithoutAnotherCredentialAdd() throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("legacy-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let ids = DeviceProvisioningRoots(journalID: UUID(), structuralID: UUID(), packageID: UUID(), grantID: UUID())
        let owner = PairingIdentity(role: .controller, publicKey: [UInt8](repeating: 7, count: 32))
        let scope = DevicePackageProtectedScope(legacyStateRoot: base.appendingPathComponent("protected/state"),
            legacyArchiveRoot: base.appendingPathComponent("protected/archive"), resetRoot: base.appendingPathComponent("protected/reset"),
            cloudRoot: base.appendingPathComponent("protected/cloud"), managementRoot: base.appendingPathComponent("protected/management"),
            preferencesRoot: base.appendingPathComponent("protected/preferences"), otherProtectedRoots: [])
        let backend = Backend()
        var journalBoundary = "none"
        func stores() throws -> (DevicePackagePreparationStore, DeviceGrantPreparationStore, DeviceStructuralStore, DeviceLocalProvisioningIntentStore) {
            for name in ["packages", "grants", "structural", "journal"] {
                let path = base.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: path.path) { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            }
            return (.init(root: base.appendingPathComponent("packages"), rootID: ids.packageID, protectedScope: scope),
                .init(root: base.appendingPathComponent("grants"), rootID: ids.grantID, protectedScope: scope, backend: backend),
                .init(root: base.appendingPathComponent("structural"), rootID: ids.structuralID),
                .init(root: base.appendingPathComponent("journal"), rootID: ids.journalID, protectedRoots: scope.roots, boundary: { journalBoundary = String(describing: $0) }))
        }
        let (p,g,s,j) = try stores(), generation = UUID(), operation = UUID()
        let profile = DeviceProfile(deviceId: "fixture", name: "Fixture", orientation: .portrait, width: 390, height: 844)
        let binding: DeviceBoundRestoredRuntimeBinding
        do { binding = try DeviceLegacyInventoryMigration.prepareAndCommit(screens: [], selected: nil, owner: owner,
            profile: profile, profileID: "iPhone", roots: ids, operationID: operation, grantOperationID: UUID(),
            generationID: generation, grantRevisionID: UUID(), legacyGrantSet: nil, journal: j, packages: p, grants: g,
            structural: s, validateOriginal: {}) } catch { XCTFail("Migration failed at journal boundary: \(journalBoundary)"); throw error }
        XCTAssertEqual(binding.generationID, generation)
        XCTAssertTrue(try StructuralStoreCodec.envelope(binding.envelopeBytes).snapshot.entries.isEmpty)
        let additions = backend.values.count
        let (p2,g2,s2,j2) = try stores()
        let restored = try DeviceLocalCompleteSetRestoreCoordinator(packageStore: p2, grantStore: g2, structuralStore: s2).restoreLatestBoundCompletedExact(journal: j2)
        XCTAssertEqual(restored.generationID, generation)
        XCTAssertEqual(restored.operationID, operation)
        XCTAssertEqual(backend.values.count, additions)
        XCTAssertThrowsError(try DeviceLegacyInventoryMigration.prepareAndCommit(screens: [], selected: nil, owner: owner,
            profile: profile, profileID: "iPhone", roots: ids, operationID: UUID(), grantOperationID: UUID(),
            generationID: UUID(), grantRevisionID: UUID(), legacyGrantSet: nil, journal: j2, packages: p2, grants: g2,
            structural: s2, validateOriginal: { throw Revoked.original }))
        XCTAssertEqual(backend.values.count, additions)
    }
}
