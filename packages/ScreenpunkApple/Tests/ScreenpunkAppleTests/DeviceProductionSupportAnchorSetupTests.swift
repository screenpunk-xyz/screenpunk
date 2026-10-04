import XCTest
import Foundation
import Darwin
import ScreenpunkCore
@testable import ScreenpunkApple

final class DeviceProductionSupportAnchorSetupTests: XCTestCase {
    private enum Injected: Error { case failure }
    private func parent() throws -> URL {
        guard let raw = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Injected.failure }
        defer { free(raw) }
        let url = URL(fileURLWithPath: String(cString: raw), isDirectory: true).appendingPathComponent("support-setup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func anchor(_ parent: URL) -> URL { parent.appendingPathComponent("Application Support", isDirectory: true) }
    func testMissingFinalReproducesInspectorFailureThenCreatesOnlyFinalAndAllowsAbsence() throws {
        let root = try parent(), support = anchor(root)
        XCTAssertThrowsError(try DeviceManagedNamespaceInspector.fixture(existingPhysicalAnchor: support))
        let setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: root)
        try setup.prepare()
        XCTAssertTrue(setup.allowsNamespaceInspection)
        let inspector = try DeviceManagedNamespaceInspector.fixture(existingPhysicalAnchor: support)
        XCTAssertEqual(try inspector.inspect().classification, .confirmedAbsent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Application Support"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: support.path), [])
        try setup.prepare()
    }
    func testExistingAnchorDoesNotCreateOrSyncAndPreservesBytes() throws {
        let root = try parent(), support = anchor(root)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let sentinel = support.appendingPathComponent("sentinel"); try Data("retained".utf8).write(to: sentinel)
        var calls = 0
        let setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: root, boundary: { _ in calls += 1 })
        try setup.prepare(); try setup.prepare()
        XCTAssertEqual(calls, 0); XCTAssertEqual(try Data(contentsOf: sentinel), Data("retained".utf8))
    }
    func testEveryCreatedNodeBoundaryRetainsExactRetryWithoutInspectionPermission() throws {
        for target in [DeviceProductionSupportAnchorSetup.Boundary.afterCreate, .beforeChildSync, .afterChildSync, .beforeParentSync, .afterParentSync] {
            let root = try parent(); var failed = false, creations = 0
            let setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: root, boundary: { boundary in
                if boundary == .afterCreate { creations += 1 }
                if boundary == target && !failed { failed = true; throw Injected.failure }
            })
            XCTAssertThrowsError(try setup.prepare()); XCTAssertFalse(setup.allowsNamespaceInspection)
            XCTAssertThrowsError(try setup.validateForInspection())
            var first = stat(); XCTAssertEqual(lstat(anchor(root).path, &first), 0)
            try setup.prepare(); try setup.validateForInspection()
            var after = stat(); XCTAssertEqual(lstat(anchor(root).path, &after), 0)
            XCTAssertEqual(first.st_ino, after.st_ino); XCTAssertEqual(first.st_dev, after.st_dev)
            XCTAssertEqual(creations, 1); XCTAssertTrue(setup.allowsNamespaceInspection)
            XCTAssertFalse(FileManager.default.fileExists(atPath: anchor(root).appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName).path))
        }
    }
    func testReplacedCreatedNodeAndParentFailClosedWithoutRecreation() throws {
        for replaceParent in [false, true] {
            let root = try parent(); var failed = false
            let setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: root, boundary: { boundary in
                if boundary == .afterCreate && !failed { failed = true; throw Injected.failure }
            })
            XCTAssertThrowsError(try setup.prepare())
            let target = replaceParent ? root : anchor(root), moved = target.appendingPathExtension("retired")
            try FileManager.default.moveItem(at: target, to: moved)
            addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            XCTAssertThrowsError(try setup.prepare()); XCTAssertFalse(setup.allowsNamespaceInspection)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        }
    }
    func testSuccessfulSetupNeverRecreatesLaterMissingAnchor() throws {
        let root = try parent(), setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: root)
        try setup.prepare(); try FileManager.default.removeItem(at: anchor(root))
        XCTAssertThrowsError(try setup.prepare()); XCTAssertThrowsError(try setup.validateForInspection())
        XCTAssertFalse(FileManager.default.fileExists(atPath: anchor(root).path))
    }
    func testSymlinkMissingParentAndEEXISTRaceNeverAdoptOrCreateAncestors() throws {
        let root = try parent(), destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: anchor(root), withDestinationURL: destination)
        let setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: root)
        XCTAssertThrowsError(try setup.prepare()); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        let missing = root.appendingPathComponent("missing/parent")
        XCTAssertThrowsError(try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
        let raceRoot = try parent(); var races = 0
        let race = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: raceRoot, boundary: { boundary in
            if boundary == .beforeCreate { races += 1; try FileManager.default.createDirectory(at: self.anchor(raceRoot), withIntermediateDirectories: false) }
        })
        XCTAssertThrowsError(try race.prepare()); XCTAssertFalse(race.allowsNamespaceInspection)
        XCTAssertThrowsError(try race.prepare()); XCTAssertEqual(races, 1)
    }
    func testKnownManagedPresenceNeverRunsAnchorSetup() throws {
        let root = try parent()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName), withIntermediateDirectories: false)
        var calls = 0
        let setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: root, boundary: { _ in calls += 1 })
        let owner = DeviceManagementAuthority(journal: ManagementTestJournal(), credentials: .init(backend: ManagementTestCredentials(), random: { Data() }), reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: root), supportAnchorSetup: setup)
        XCTAssertNil(try owner.refresh())
        XCTAssertThrowsError(try owner.prepareProductionSupportAnchor())
        XCTAssertEqual(calls, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: anchor(root).path))
    }

    func testOwnerBlocksVisibleUncertainAnchorUntilExactSetupRetry() throws {
        let root = try parent(); var failed = false
        let setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: root, boundary: { boundary in
            if boundary == .afterParentSync && !failed { failed = true; throw Injected.failure }
        })
        XCTAssertThrowsError(try setup.prepare())
        let owner = DeviceManagementAuthority(journal: ManagementTestJournal(), credentials: .init(backend: ManagementTestCredentials(), random: { XCTFail("no credential generation"); return Data() }), reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor(root)), supportAnchorSetup: setup)
        XCTAssertNil(try owner.refresh()); XCTAssertFalse(owner.resetRenderingAllowed())
        try owner.prepareProductionSupportAnchor()
        XCTAssertNotNil(try owner.refresh())
        try FileManager.default.removeItem(at: anchor(root))
        XCTAssertNil(try owner.refresh()); XCTAssertThrowsError(try owner.prepareProductionSupportAnchor())
        XCTAssertFalse(FileManager.default.fileExists(atPath: anchor(root).path))
    }
}
