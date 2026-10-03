import XCTest
@testable import ScreenpunkCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DeviceLocalFilesystemCleanupTests: XCTestCase {
    enum Injected: Error { case failure }
    struct Fixture {
        let anchor: URL, device: URL, preferences: URL, management: URL, reset: URL
        init() throws {
            guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Injected.failure }
            let temporary = URL(fileURLWithPath: String(cString: physical)); free(physical)
            anchor = temporary.appendingPathComponent(UUID().uuidString)
            device = anchor.appendingPathComponent("device"); preferences = anchor.appendingPathComponent("preferences")
            management = anchor.appendingPathComponent("management"); reset = anchor.appendingPathComponent("reset")
            for root in [device, preferences, management, reset] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            try Data("protected".utf8).write(to: management.appendingPathComponent("journal"))
            try Data("pending".utf8).write(to: reset.appendingPathComponent("intent"))
            try Data("lock".utf8).write(to: preferences.appendingPathComponent("preferences.lock"))
            try Data("unrelated".utf8).write(to: preferences.appendingPathComponent("unrelated"))
        }
        func plan(depth: Int = 32, entries: Int = 10000) throws -> DeviceLocalFilesystemCleanupPlan {
            try .init(anchor: anchor, roots: [.init(directory: device, mode: .directoryContents), .init(directory: preferences, mode: .namedFiles(["preferences-v1.json", "approved-temp"]))], protectedRoots: [management, reset], maximumDepth: depth, maximumEntries: entries)
        }
    }
    private func fixture() throws -> Fixture {
        let value = try Fixture(); addTeardownBlock { try? FileManager.default.removeItem(at: value.anchor) }; return value
    }
    private func sentinels(_ f: Fixture) throws {
        XCTAssertEqual(try String(contentsOf: f.management.appendingPathComponent("journal")), "protected")
        XCTAssertEqual(try String(contentsOf: f.reset.appendingPathComponent("intent")), "pending")
        XCTAssertEqual(try String(contentsOf: f.preferences.appendingPathComponent("preferences.lock")), "lock")
        XCTAssertEqual(try String(contentsOf: f.preferences.appendingPathComponent("unrelated")), "unrelated")
    }
    func testNestedCleanupExactNamesLinksAndIdempotentReplayPreserveRootsAndProtectedData() throws {
        let f = try fixture(), nested = f.device.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("device".utf8).write(to: nested.appendingPathComponent("content"))
        try FileManager.default.createSymbolicLink(at: f.device.appendingPathComponent("outside-link"), withDestinationURL: f.management)
        try Data("prefs".utf8).write(to: f.preferences.appendingPathComponent("preferences-v1.json"))
        try Data().write(to: f.preferences.appendingPathComponent("approved-temp"))
        let cleanup = DeviceLocalFilesystemCleanup(plan: try f.plan())
        try cleanup.execute(); try cleanup.execute()
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.device.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.device.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.preferences.appendingPathComponent("preferences-v1.json").path))
        try sentinels(f)
    }
    func testPlanRejectsOverlapEscapeAndNonExactNamesAndMetadataIsDeterministic() throws {
        let f = try fixture()
        for root in [f.anchor, f.management, f.management.appendingPathComponent("child"), f.anchor.deletingLastPathComponent()] {
            XCTAssertThrowsError(try DeviceLocalFilesystemCleanupPlan(anchor: f.anchor, roots: [.init(directory: root, mode: .directoryContents)], protectedRoots: [f.management]))
        }
        for names in [["../archive"], [""], ["a/b"], ["."], ["x", "x"], ["bad\0name"]] {
            XCTAssertThrowsError(try DeviceLocalFilesystemCleanupPlan(anchor: f.anchor, roots: [.init(directory: f.preferences, mode: .namedFiles(names))], protectedRoots: []))
        }
        let a = try f.plan()
        let b = try DeviceLocalFilesystemCleanupPlan(anchor: f.anchor, roots: [.init(directory: f.preferences, mode: .namedFiles(["approved-temp", "preferences-v1.json"])), .init(directory: f.device, mode: .directoryContents)], protectedRoots: [f.reset, f.management])
        XCTAssertEqual(a.canonicalMetadata, b.canonicalMetadata)
        let changed = try DeviceLocalFilesystemCleanupPlan(anchor: f.anchor, roots: [.init(directory: f.device, mode: .namedFiles(["archive"]))], protectedRoots: [f.management, f.reset])
        XCTAssertNotEqual(a.canonicalMetadata, changed.canonicalMetadata)
        try sentinels(f)
    }
    func testRootAndAncestorSymlinksFailWithoutFollowingThem() throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.device)
        try FileManager.default.createSymbolicLink(at: f.device, withDestinationURL: f.management)
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: f.plan()).execute())
        let alias = f.anchor.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.management)
        let plan = try DeviceLocalFilesystemCleanupPlan(anchor: f.anchor, roots: [.init(directory: alias.appendingPathComponent("child"), mode: .directoryContents)], protectedRoots: [f.reset])
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: plan).execute()); try sentinels(f)
    }
    func testSpecialNodesAndNamedDirectoriesFailClosed() throws {
        let f = try fixture()
        let fifo = f.device.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: f.plan()).execute())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifo.path))
        try FileManager.default.removeItem(at: fifo)
        try FileManager.default.createDirectory(at: f.preferences.appendingPathComponent("preferences-v1.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: f.plan()).execute()); try sentinels(f)
    }
    func testDepthAndGlobalEntryLimitsFailWithoutCompletion() throws {
        let f = try fixture(), nested = f.device.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data().write(to: nested.appendingPathComponent("leaf"))
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: f.plan(depth: 1)).execute())
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: f.plan(entries: 2)).execute())
        try sentinels(f)
    }
    func testPartialUnlinkFailuresReplayAndSynchronizeEveryModifiedParent() throws {
        for target in [DeviceLocalFilesystemCleanup.Boundary.beforeUnlink, .afterUnlink, .beforeSync, .afterSync] {
            let f = try fixture(); try Data().write(to: f.device.appendingPathComponent("first")); try Data().write(to: f.device.appendingPathComponent("second"))
            var injected = false
            let failing = DeviceLocalFilesystemCleanup(plan: try f.plan()) { boundary, path in
                if boundary == target, !injected, path.hasPrefix(f.device.path) { injected = true; throw Injected.failure }
            }
            XCTAssertThrowsError(try failing.execute()); XCTAssertTrue(injected); try sentinels(f)
            var synced = Set<String>()
            try DeviceLocalFilesystemCleanup(plan: f.plan()) { boundary, path in if boundary == .afterSync { synced.insert(path) } }.execute()
            XCTAssertTrue(synced.contains(f.device.path)); XCTAssertTrue(synced.contains(f.preferences.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.device.path), []); try sentinels(f)
        }
    }
    func testMissingRootsAndNamedFilesRequireParentSynchronization() throws {
        let f = try fixture(); try FileManager.default.removeItem(at: f.device)
        var synced = Set<String>()
        try DeviceLocalFilesystemCleanup(plan: f.plan()) { boundary, path in if boundary == .afterSync { synced.insert(path) } }.execute()
        XCTAssertTrue(synced.contains(f.anchor.path)); XCTAssertTrue(synced.contains(f.preferences.path))
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: f.plan()) { boundary, path in if boundary == .beforeSync, path == f.anchor.path { throw Injected.failure } }.execute())
        try sentinels(f)
    }
    func testReplacementAfterOpeningDirectoryCannotDeleteOldOrReplacementContents() throws {
        let f = try fixture(); try Data("old".utf8).write(to: f.device.appendingPathComponent("sentinel"))
        let moved = f.anchor.appendingPathComponent("moved")
        var replaced = false
        let cleanup = DeviceLocalFilesystemCleanup(plan: try f.plan()) { boundary, path in
            if boundary == .afterOpen, path == f.device.path, !replaced {
                replaced = true; try FileManager.default.moveItem(at: f.device, to: moved)
                try FileManager.default.createDirectory(at: f.device, withIntermediateDirectories: false)
                try Data("new".utf8).write(to: f.device.appendingPathComponent("sentinel"))
            }
        }
        XCTAssertThrowsError(try cleanup.execute())
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("sentinel")), "old")
        XCTAssertEqual(try String(contentsOf: f.device.appendingPathComponent("sentinel")), "new"); try sentinels(f)
    }
    func testReplacementBeforeUnlinkCannotDeleteNewFile() throws {
        let f = try fixture(), path = f.device.appendingPathComponent("file"), moved = f.anchor.appendingPathComponent("moved-file")
        try Data("old".utf8).write(to: path)
        XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: f.plan()) { boundary, candidate in
            if boundary == .beforeUnlink, candidate == path.path {
                try FileManager.default.moveItem(at: path, to: moved); try Data("new".utf8).write(to: path)
            }
        }.execute())
        XCTAssertEqual(try String(contentsOf: path), "new"); XCTAssertEqual(try String(contentsOf: moved), "old"); try sentinels(f)
    }
    func testObservedMountBoundaryRejectsRootAndChildBeforeUnlink() throws {
        let f = try fixture(), leaf = f.device.appendingPathComponent("leaf")
        try Data("keep".utf8).write(to: leaf)
        for mount in [f.device.path, leaf.path] {
            let cleanup = DeviceLocalFilesystemCleanup(plan: try f.plan(), observedDevice: { path, device in path == mount ? device &+ 1 : device }, boundary: { _, _ in })
            XCTAssertThrowsError(try cleanup.execute()) { XCTAssertEqual($0 as? DeviceLocalFilesystemCleanupError, .crossedMount) }
            XCTAssertEqual(try String(contentsOf: leaf), "keep"); try sentinels(f)
        }
    }
    func testTraversalBoundaryFailuresNeverTouchProtectedSentinelsAndReplay() throws {
        for target in [DeviceLocalFilesystemCleanup.Boundary.afterOpen, .beforeEnumerate, .beforeInspect] {
            let f = try fixture(); try Data().write(to: f.device.appendingPathComponent("leaf"))
            var injected = false
            XCTAssertThrowsError(try DeviceLocalFilesystemCleanup(plan: f.plan()) { boundary, path in
                if boundary == target, path.hasPrefix(f.device.path) { injected = true; throw Injected.failure }
            }.execute())
            XCTAssertTrue(injected); try sentinels(f)
            try DeviceLocalFilesystemCleanup(plan: f.plan()).execute(); try sentinels(f)
        }
    }

}
