import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@_spi(NativeFilesystem) @testable import ScreenpunkCore

final class DeviceFilesystemTraversalTests: XCTestCase {
    func testOnlyExactSystemHomeOrItsPhysicalSpellingMapsToContainerRoot() throws {
        let system = "/var/mobile/Containers/Data/Application/fixture", physical = "/private/var/mobile/Containers/Data/Application/fixture"
        for root in [system, physical] {
            let plan = try DeviceFilesystemTraversal.confined(path: root + "/Library/Application Support/store", systemHome: system, physicalHome: physical)
            XCTAssertEqual(plan.rootPath, physical)
            XCTAssertEqual(plan.components, ["Library", "Application Support", "store"])
        }
        for path in ["/", "/private/var", system + "-other/Library", system + "/../other", system + "//Library", system + "/Library/.", system + "/Library/", system + "/bad\0node"] {
            XCTAssertThrowsError(try DeviceFilesystemTraversal.confined(path: path, systemHome: system, physicalHome: physical))
        }
    }
    func testRootItselfHasNoTraversalComponentsAndBoundsAreNotRelaxed() throws {
        let home = "/owned/home"
        let plan = try DeviceFilesystemTraversal.confined(path: home, systemHome: home, physicalHome: home)
        XCTAssertEqual(plan.components, []); XCTAssertEqual(plan.rootPath, home)
        XCTAssertThrowsError(try DeviceFilesystemTraversal.confined(path: home + "/" + String(repeating: "a/", count: 129) + "b", systemHome: home, physicalHome: home))
        XCTAssertThrowsError(try DeviceFilesystemTraversal.confined(path: home + "/" + String(repeating: "b", count: 4096), systemHome: home, physicalHome: home))
    }
    private func currentHomeFixture<T>(_ body: (URL, URL, Int32, stat) throws -> T) throws -> T {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        let root = home.appendingPathComponent("Library/store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(fd) }
        var raw = stat(); guard fstat(fd, &raw) == 0 else { throw CocoaError(.fileReadUnknown) }
        return try body(home, root, fd, raw)
    }
    func testHistoricalMountEpochsLinkOnlyExactInodesOnVerifiedCurrentHomeDevice() throws {
        try currentHomeFixture { home, root, fd, raw in
            let context = try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(currentRoot: root,
                heldRoot: fd, systemHome: home.path, physicalHome: home.path)
            let current = UInt64(truncatingIfNeeded: raw.st_dev), inode = UInt64(raw.st_ino)
            let oldA = current &+ 1, oldB = current &+ 2
            for historical in [oldA, oldB] {
                XCTAssertTrue(context.matchesDurableIdentity(recordedDevice: historical, recordedInode: inode,
                    observedDevice: current, observedInode: inode))
                XCTAssertFalse(context.matchesDurableIdentity(recordedDevice: historical, recordedInode: inode,
                    observedDevice: current, observedInode: inode &+ 1))
                XCTAssertFalse(context.matchesDurableIdentity(recordedDevice: historical, recordedInode: inode,
                    observedDevice: historical, observedInode: inode), "A current node cannot cross to a different live mount")
            }
            XCTAssertTrue(context.acceptsCurrentDevice(current)); XCTAssertFalse(context.acceptsCurrentDevice(oldA))
            XCTAssertTrue(context.matchesRecordedRootPath("screenpunk-app-home:v1/Library/store"))
            XCTAssertTrue(context.matchesRecordedRootPath(root.path))
            XCTAssertFalse(context.matchesRecordedRootPath("screenpunk-app-home:v1/Library/other"))
            XCTAssertFalse(context.matchesRecordedRootPath("screenpunk-app-home:v1/Library/../store"))
            XCTAssertFalse(context.matchesRecordedRootPath(home.deletingLastPathComponent().appendingPathComponent("other").path))
        }
    }
    func testCurrentHomeCaptureRejectsOutsideRootWrongHeldNodeAndSymlinkAncestor() throws {
        try currentHomeFixture { home, root, fd, _ in
            let other = home.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            XCTAssertThrowsError(try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(currentRoot: other,
                heldRoot: fd, systemHome: home.path, physicalHome: home.path))
            XCTAssertThrowsError(try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(currentRoot: root,
                heldRoot: fd, systemHome: other.path, physicalHome: other.path))
            let link = home.appendingPathComponent("shortcut", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
            XCTAssertThrowsError(try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(
                currentRoot: link.appendingPathComponent("store"), heldRoot: fd, systemHome: home.path, physicalHome: home.path))
            let moved = home.appendingPathComponent("held-original", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: moved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            XCTAssertThrowsError(try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(currentRoot: root,
                heldRoot: fd, systemHome: home.path, physicalHome: home.path), "Same path cannot replace the held root descriptor")
        }
    }
    func testProductionContextIsCurrentIOSHomeScopedAndNonIOSRemainsStrict() throws {
        try currentHomeFixture { _, root, fd, raw in
            let context = try DevicePersistedFilesystemContext.capture(currentRoot: root, heldRoot: fd)
            let device = UInt64(truncatingIfNeeded: raw.st_dev), inode = UInt64(raw.st_ino)
            XCTAssertTrue(context.matchesDurableIdentity(recordedDevice: device, recordedInode: inode,
                observedDevice: device, observedInode: inode))
            #if os(iOS)
            XCTAssertTrue(context.matchesDurableIdentity(recordedDevice: device &+ 1, recordedInode: inode,
                observedDevice: device, observedInode: inode))
            #else
            XCTAssertFalse(context.matchesDurableIdentity(recordedDevice: device &+ 1, recordedInode: inode,
                observedDevice: device, observedInode: inode))
            XCTAssertFalse(context.matchesRecordedRootPath("screenpunk-app-home:v1/Library/store"))
            XCTAssertEqual(try context.planCurrentPath(root.path).rootPath, "/")
            XCTAssertTrue(context.recordedPath(root.path, matchesCurrentPath: root.path))
            XCTAssertFalse(context.recordedPath("screenpunk-app-home:v1/Library/store", matchesCurrentPath: root.path))
            #endif
        }
    }

    func testPublicationTargetIsPinnedAndCannotBorrowAnotherSameHomeRoot() throws {
        try currentHomeFixture { home, root, fd, _ in
            let final = root.deletingLastPathComponent().appendingPathComponent("final", isDirectory: true)
            let ordinary = try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(currentRoot: root,
                heldRoot: fd, systemHome: home.path, physicalHome: home.path)
            XCTAssertFalse(ordinary.matchesRecordedRootPath(final.path))
            let publication = try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(currentRoot: root,
                heldRoot: fd, systemHome: home.path, physicalHome: home.path, plannedPublicationRoot: final)
            XCTAssertTrue(publication.matchesRecordedRootPath(final.path))
            XCTAssertFalse(publication.matchesRecordedRootPath(root.path))
            XCTAssertFalse(publication.matchesRecordedRootPath(root.deletingLastPathComponent().appendingPathComponent("other").path))
            XCTAssertThrowsError(try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(currentRoot: root,
                heldRoot: fd, systemHome: home.path, physicalHome: home.path,
                plannedPublicationRoot: home.appendingPathComponent("different-parent/final")))
        }
    }

    func testAcquisitionContextKeepsLivePathsDistinctFromRecordedContainerLocators() throws {
        try currentHomeFixture { sandbox, _, _, _ in
            let parent = sandbox.appendingPathComponent("Containers/Data/Application", isDirectory: true)
            let home = parent.appendingPathComponent("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", isDirectory: true)
            let root = home.appendingPathComponent("Library/store", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
            defer { close(fd) }
            let context = try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(currentRoot: root,
                heldRoot: fd, systemHome: home.path, physicalHome: home.path)
            let plan = try context.planCurrentPath(root.path)
            XCTAssertEqual(plan.rootPath, home.path)
            XCTAssertEqual(plan.components, ["Library", "store"])
            let old = parent.appendingPathComponent("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB").path + "/Library/store"
            XCTAssertTrue(context.recordedPath(old, matchesCurrentPath: root.path))
            XCTAssertTrue(context.recordedPath("screenpunk-app-home:v1/Library/store", matchesCurrentPath: root.path))
            XCTAssertThrowsError(try context.planCurrentPath(old))
            XCTAssertFalse(context.recordedPath(old, matchesCurrentPath: old), "Recorded relocation must never admit the live side")
            for bad in [home.path + "-other/Library/store", home.path + "/../store", home.path + "//Library/store",
                        home.path + "/Library/.", home.path + "/bad\0node", "screenpunk-app-home:v1/Library/store"] {
                XCTAssertThrowsError(try context.planCurrentPath(bad), bad)
            }
            XCTAssertFalse(context.recordedPath("screenpunk-app-home:v1/Library/../store", matchesCurrentPath: root.path))
            XCTAssertFalse(context.recordedPaths([old], matchCurrentPaths: [root.path, root.path]))
            XCTAssertFalse(context.recordedPaths([old, "screenpunk-app-home:v1/Library/other"], matchCurrentPaths: [root.path, root.path]))
            let link = home.appendingPathComponent("shortcut", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
            XCTAssertThrowsError(try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(
                currentRoot: link.appendingPathComponent("store"), heldRoot: fd,
                systemHome: home.path, physicalHome: home.path), "Lexical plans cannot authorize a symlinked traversal")
        }
    }

    private func packageScope(in home: URL) -> DevicePackageProtectedScope {
        .init(legacyStateRoot: home.appendingPathComponent("legacy"), legacyArchiveRoot: home.appendingPathComponent("archive"),
            resetRoot: home.appendingPathComponent("reset"), cloudRoot: home.appendingPathComponent("cloud"),
            managementRoot: home.appendingPathComponent("management"), preferencesRoot: home.appendingPathComponent("preferences"),
            otherProtectedRoots: [])
    }

    /// PackageStore walks every absolute component without following links on
    /// macOS too. Foundation may spell the owned temporary home through /var.
    private func physicalPackageHomeFixture<T>(_ body: (URL, URL, Int32, stat) throws -> T) throws -> T {
        try currentHomeFixture { home, root, fd, identity in
            func physicalURL(_ url: URL) throws -> URL {
                guard let raw = realpath(url.path, nil) else { throw CocoaError(.fileReadUnknown) }
                defer { free(raw) }
                guard strnlen(raw, 4097) <= 4096 else { throw CocoaError(.fileReadUnknown) }
                return URL(fileURLWithPath: String(cString: raw), isDirectory: true)
            }
            return try body(physicalURL(home), physicalURL(root), fd, identity)
        }
    }

    func testHeldPackageAcquisitionRejectsRootAndProtectedPathReplacementAfterHomeCapture() throws {
        for replaceRoot in [true, false] {
            try physicalPackageHomeFixture { home, root, _, _ in
                let scope = packageScope(in: home)
                try FileManager.default.createDirectory(at: scope.legacyStateRoot, withIntermediateDirectories: false)
                let protectedSentinel = scope.legacyStateRoot.appendingPathComponent("sentinel")
                try Data("protected".utf8).write(to: protectedSentinel)
                let displaced = home.appendingPathComponent("displaced", isDirectory: true)
                var captured = 0, replaced = false
                let store = DevicePackagePreparationStore(root: root, rootID: UUID(), protectedScope: scope,
                    contextFactory: { current, held in
                        captured += 1
                        return try .syntheticCurrentAppHomeForTesting(currentRoot: current, heldRoot: held,
                            systemHome: home.path, physicalHome: home.path)
                    }, boundary: { boundary in
                        guard boundary == .afterFileSync(.binding), !replaced else { return }
                        replaced = true
                        if replaceRoot {
                            try FileManager.default.moveItem(at: root, to: displaced)
                            try Data("held".utf8).write(to: displaced.appendingPathComponent("sentinel"))
                            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                            try Data("replacement".utf8).write(to: root.appendingPathComponent("sentinel"))
                        } else {
                            try FileManager.default.moveItem(at: scope.legacyStateRoot, to: displaced)
                            try FileManager.default.createSymbolicLink(at: scope.legacyStateRoot, withDestinationURL: root)
                        }
                    })
                XCTAssertThrowsError(try store.initializeExplicit())
                XCTAssertEqual(captured, 1); XCTAssertTrue(replaced)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("root-binding.json").path))
                if replaceRoot {
                    XCTAssertEqual(try Data(contentsOf: displaced.appendingPathComponent("sentinel")), Data("held".utf8))
                    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sentinel")), Data("replacement".utf8))
                    XCTAssertEqual(try Data(contentsOf: protectedSentinel), Data("protected".utf8))
                } else {
                    XCTAssertEqual(try Data(contentsOf: displaced.appendingPathComponent("sentinel")), Data("protected".utf8))
                }
            }
        }
    }

    func testPackageAcquisitionsRecaptureHomeAndRecoverAfterCaptureFailure() throws {
        enum CaptureFailure: Error { case expected }
        try physicalPackageHomeFixture { home, root, _, _ in
            var captures = 0
            let store = DevicePackagePreparationStore(root: root, rootID: UUID(), protectedScope: packageScope(in: home),
                contextFactory: { current, held in
                    captures += 1
                    if captures == 2 { throw CaptureFailure.expected }
                    return try .syntheticCurrentAppHomeForTesting(currentRoot: current, heldRoot: held,
                        systemHome: home.path, physicalHome: home.path)
                })
            try store.initializeExplicit()
            let binding = try Data(contentsOf: root.appendingPathComponent("root-binding.json"))
            XCTAssertThrowsError(try store.initializeExplicit()) { error in
                XCTAssertEqual(error as? DevicePackagePreparationError, .unsafeBinding)
            }
            XCTAssertEqual(captures, 2)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("root-binding.json")), binding)
            try store.initializeExplicit()
            XCTAssertEqual(captures, 3)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("root-binding.json")), binding)
        }
    }

    /// Frozen grammar from qualified build45, independent of the byte scanner.
    private func build45PathGrammar(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096 && !path.utf8.contains(0) &&
        !path.hasSuffix("/") && !path.contains("//") && path.split(separator: "/").count <= 128 &&
        path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }

    private func assertConfinementMatchesBuild45(_ path: String, systemHome: String, physicalHome: String,
        file: StaticString = #filePath, line: UInt = #line) {
        let expected = build45PathGrammar(path) && build45PathGrammar(systemHome) && build45PathGrammar(physicalHome)
            && (path == physicalHome || path.hasPrefix(physicalHome + "/") || path == systemHome || path.hasPrefix(systemHome + "/"))
        let actual = (try? DeviceFilesystemTraversal.confined(path: path, systemHome: systemHome, physicalHome: physicalHome)) != nil
        XCTAssertEqual(actual, expected, String(reflecting: path), file: file, line: line)
    }

    func testASCIIPathGrammarMatchesBuild45AtSizeComponentAndDelimiterBoundaries() {
        let home = "/owned/home"
        let paths = ["", "/", "relative", home, home + "/", home + "//screen", home + "/.", home + "/..",
            home + "/...", home + "/a/./b", home + "/a/../b", home + "/.a/..b", home + "/screen.html",
            home + "-other/screen", home + "/a b", home + "/a\\b", home + "/a%2fb", home + "/bad\0node"]
        for path in paths { assertConfinementMatchesBuild45(path, systemHome: home, physicalHome: home) }
        for value in 0...127 {
            let path = home + "/a" + String(UnicodeScalar(value)!) + "b"
            assertConfinementMatchesBuild45(path, systemHome: home, physicalHome: home)
        }
        for count in [127, 128, 129] {
            let path = "/" + Array(repeating: "a", count: count).joined(separator: "/")
            assertConfinementMatchesBuild45(path, systemHome: "/a", physicalHome: "/a")
        }
        for count in [4095, 4096, 4097] {
            let path = "/" + String(repeating: "a", count: count - 1)
            assertConfinementMatchesBuild45(path, systemHome: path, physicalHome: path)
        }
        for badHome in ["", "/", "/owned/home/", "/owned/../home", "/owned//home", "/owned/bad\0home"] {
            assertConfinementMatchesBuild45(home + "/screen", systemHome: badHome, physicalHome: home)
            assertConfinementMatchesBuild45(home + "/screen", systemHome: home, physicalHome: badHome)
        }
    }

    func testGeneratedPathGrammarMatchesBuild45IncludingCombiningDelimiters() {
        let homes = ["/owned/home", "/owned/caf\u{e9}", "/owned/e\u{301}", "/owned/\u{301}home"]
        let components = ["", "a", ".", "..", "...", "b.", "a b", "\u{e9}", "e\u{301}", "\u{301}",
            ".\u{301}", "..\u{301}", "\u{1f642}", "\u{7f}", "a\0b"]
        for home in homes {
            for first in components {
                for separator in ["/", "//", "/\u{301}"] {
                    for second in components {
                        assertConfinementMatchesBuild45(home + "/" + first + separator + second,
                            systemHome: home, physicalHome: home)
                    }
                }
            }
            let physical = "/physical" + home
            assertConfinementMatchesBuild45(home + "/screen", systemHome: home, physicalHome: physical)
            assertConfinementMatchesBuild45(physical + "/screen", systemHome: home, physicalHome: physical)
        }
        let combiningBoundary = "/" + Array(repeating: "a", count: 128).joined(separator: "/") + "/\u{301}"
        assertConfinementMatchesBuild45(combiningBoundary, systemHome: "/a", physicalHome: "/a")
        for count in [4093, 4094, 4096] {
            let path = "/" + String(repeating: "a", count: count) + "\u{e9}"
            assertConfinementMatchesBuild45(path, systemHome: path, physicalHome: path)
        }
    }

}
