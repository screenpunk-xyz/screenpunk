import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DeviceOwnedRootRemovalTests: XCTestCase {
    private enum Injected: Error { case crash }
    private func fixture() throws -> (anchor: URL, root: URL, foreign: URL, plan: DeviceLocalFilesystemCleanupPlan) {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Injected.crash }
        let temporary = URL(fileURLWithPath: String(cString: physical)); free(physical)
        let anchor = temporary.appendingPathComponent(UUID().uuidString)
        let root = anchor.appendingPathComponent("owned"), foreign = anchor.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: root.appendingPathComponent("nested/content"))
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: foreign.appendingPathComponent("sentinel"))
        addTeardownBlock { try? FileManager.default.removeItem(at: anchor) }
        var identity = stat()
        guard lstat(root.path, &identity) == 0 else { throw Injected.crash }
        let plan = try DeviceLocalFilesystemCleanupPlan(anchor: anchor,
            roots: [.init(directory: root, mode: .ownedDirectory(device: UInt64(truncatingIfNeeded: identity.st_dev), inode: UInt64(truncatingIfNeeded: identity.st_ino)))],
            protectedRoots: [foreign])
        return (anchor, root, foreign, plan)
    }
    func testExactRootAbsentAfterCleanupAndIdempotentReplayPreservesForeignSibling() throws {
        let f = try fixture()
        try DeviceLocalFilesystemCleanup(plan: f.plan).execute()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        try DeviceLocalFilesystemCleanup(plan: f.plan).execute()
        XCTAssertEqual(try String(contentsOf: f.foreign.appendingPathComponent("sentinel")), "foreign")
    }
    func testChangedRootIsRejectedBeforeDeletingAnyReplacementContents() throws {
        let f = try fixture(), old = f.anchor.appendingPathComponent("original-retired")
        try FileManager.default.moveItem(at: f.root, to: old)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: f.root.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: f.plan).execute()) {
            XCTAssertEqual($0 as? DeviceLocalFilesystemCleanupError, .changedDirectory)
        }
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("sentinel")), "replacement")
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("nested/content")), "owned")
    }
    func testCrashAfterRootUnlinkRetriesSameManifestWithoutAdoptingForeignSibling() throws {
        let f = try fixture()
        let interrupted = DeviceLocalFilesystemCleanup(plan: f.plan, boundary: { boundary, path in
            if boundary == .afterUnlink, path == f.root.path { throw Injected.crash }
        })
        XCTAssertThrowsError(try interrupted.execute())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        try DeviceLocalFilesystemCleanup(plan: f.plan).execute()
        XCTAssertEqual(try String(contentsOf: f.foreign.appendingPathComponent("sentinel")), "foreign")
    }
    func testEmptyOwnedContainerPreservesUnknownChildAndRemovesOnlyAfterVerifiedEmpty() throws {
        let f = try fixture()
        var identity = stat(); XCTAssertEqual(lstat(f.root.path, &identity), 0)
        let empty = try DeviceLocalFilesystemCleanupPlan(anchor: f.anchor,
            roots: [.init(directory: f.root, mode: .ownedEmptyDirectory(device: UInt64(truncatingIfNeeded: identity.st_dev), inode: UInt64(truncatingIfNeeded: identity.st_ino)))],
            protectedRoots: [f.foreign])
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: empty).execute())
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("nested/content")), "owned")
        try FileManager.default.moveItem(at: f.root.appendingPathComponent("nested"), to: f.anchor.appendingPathComponent("known-child-retired"))
        try DeviceLocalFilesystemCleanup(plan: empty).execute()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        XCTAssertEqual(try String(contentsOf: f.foreign.appendingPathComponent("sentinel")), "foreign")
    }
    func testDirectoryReplacementAtFinalUnlinkCannotRetireNewRoot() throws {
        let f = try fixture(), retired = f.anchor.appendingPathComponent("old")
        let interrupted = DeviceLocalFilesystemCleanup(plan: f.plan, boundary: { boundary, path in
            if boundary == .beforeUnlink, path == f.root.path {
                try FileManager.default.moveItem(at: f.root, to: retired)
                try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
                try Data("retained".utf8).write(to: f.root.appendingPathComponent("sentinel"))
            }
        })
        XCTAssertThrowsError(try interrupted.execute())
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("sentinel")), "retained")
    }
}
