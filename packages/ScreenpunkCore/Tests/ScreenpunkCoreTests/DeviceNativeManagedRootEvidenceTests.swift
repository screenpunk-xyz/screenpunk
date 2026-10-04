import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DeviceNativeManagedRootEvidenceTests: XCTestCase {
    private func ownedParent() throws -> URL {
        guard let raw = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw NSError(domain: "fixture realpath", code: Int(errno)) }
        let physical = String(cString: raw); free(raw)
        let root = URL(fileURLWithPath: physical, isDirectory: true).appendingPathComponent("managed-evidence-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func child(_ parent: URL) -> URL { parent.appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName, isDirectory: true) }
    private func inspector(_ parent: URL) throws -> DeviceManagedNamespaceInspector { try .fixture(existingPhysicalAnchor: parent) }
    private func names(_ parent: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() }

    func testCheckedAbsenceIsStableTypedEvidenceAndCreatesNothing() throws {
        let parent = try ownedParent(), sentinel = parent.appendingPathComponent("sentinel")
        let bytes = Data("unrelated sentinel".utf8); try bytes.write(to: sentinel)
        let before = try names(parent), check = try inspector(parent)
        let first = try check.inspect(), second = try check.inspect()
        XCTAssertEqual(first.classification, .confirmedAbsent); XCTAssertEqual(first, second)
        XCTAssertEqual(try names(parent), before); XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child(parent).path))
        let locator = try DeviceNativeManagedRootLocator.existingPhysicalAnchor(parent)
        XCTAssertEqual(locator.namespaceURL.path, child(parent).path)
        XCTAssertEqual(DeviceNativeManagedRootLocator.futureChildNames, ["packages", "grants", "structural", "provisioning"])
    }
    func testEveryNamespacePresenceBlocksIncludingEmptyPartialAndOrphan() throws {
        let parent = try ownedParent(), check = try inspector(parent), root = child(parent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(try check.inspect().classification, .managedPresent)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("grants"), withIntermediateDirectories: false)
        XCTAssertEqual(try check.inspect().classification, .managedPresent)
        try Data("orphan".utf8).write(to: root.appendingPathComponent("unknown.pending"))
        let before = try names(root)
        XCTAssertEqual(try check.inspect().classification, .managedPresent)
        XCTAssertEqual(try names(root), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("packages").path))
    }
    func testRegularFileAndDanglingOrExistingSymlinkArePresenceNotAbsence() throws {
        let parent = try ownedParent(), check = try inspector(parent), root = child(parent)
        try Data("not a directory".utf8).write(to: root)
        XCTAssertEqual(try check.inspect().classification, .managedPresent)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: "missing-target")
        XCTAssertEqual(try check.inspect().classification, .managedPresent)
        try FileManager.default.removeItem(at: root)
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: target.path)
        XCTAssertEqual(try check.inspect().classification, .managedPresent)
        XCTAssertTrue(try names(target).isEmpty)
    }
    func testRemovedExpectedNamespaceMustBeRememberedByOwnerHighwater() throws {
        let parent = try ownedParent(), check = try inspector(parent)
        let originalAbsent = try check.inspect()
        try FileManager.default.createDirectory(at: child(parent), withIntermediateDirectories: false)
        let present = try check.inspect(); XCTAssertEqual(present.classification, .managedPresent)
        try FileManager.default.removeItem(at: child(parent))
        let later = try check.inspect(); XCTAssertEqual(later.classification, .confirmedAbsent)
        XCTAssertNotEqual(present, later)
        // The Core observer is intentionally stateless. Apple owns a sticky
        // highwater, so equality with earlier absence cannot erase observed presence.
        XCTAssertEqual(originalAbsent, later)
    }
    func testAnchorReplacementChangesAbsenceEvidenceAndMissingAnchorThrows() throws {
        let parent = try ownedParent(), anchor = parent.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        let check = try inspector(anchor), before = try check.inspect()
        let retained = parent.appendingPathComponent("retained-support", isDirectory: true)
        try FileManager.default.moveItem(at: anchor, to: retained)
        XCTAssertThrowsError(try check.inspect())
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        let after = try check.inspect(); XCTAssertEqual(after.classification, .confirmedAbsent); XCTAssertNotEqual(before, after)
        XCTAssertTrue(try names(retained).isEmpty); XCTAssertTrue(try names(anchor).isEmpty)
        try FileManager.default.removeItem(at: anchor)
        try FileManager.default.createSymbolicLink(atPath: anchor.path, withDestinationPath: retained.path)
        XCTAssertThrowsError(try check.inspect())
    }
    func testAncestorReplacementChangesFullCheckedChain() throws {
        let parent = try ownedParent(), support = parent.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let check = try inspector(support), before = try check.inspect()
        let held = parent.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: parent, to: held)
        defer { try? FileManager.default.removeItem(at: held) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        XCTAssertNotEqual(before, try check.inspect())
        XCTAssertTrue(try names(support).isEmpty)
    }
    func testCallerAliasesAndMalformedLocatorsAreNotSilentlyNormalized() throws {
        let parent = try ownedParent(), target = parent.appendingPathComponent("physical", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: target.path)
        XCTAssertThrowsError(try inspector(alias))
        for suffix in ["/./physical", "/physical/..", "//physical"] {
            let url = try XCTUnwrap(URL(string: "file://" + parent.path + suffix))
            XCTAssertThrowsError(try inspector(url))
        }
        for text in ["https://example.invalid/support", "file://remote.invalid/support", "file://" + parent.path + "?q=1", "file://" + parent.path + "#fragment"] {
            XCTAssertThrowsError(try inspector(XCTUnwrap(URL(string: text))))
        }
        XCTAssertThrowsError(try inspector(URL(fileURLWithPath: "/")))
        XCTAssertThrowsError(try inspector(URL(fileURLWithPath: "/" + String(repeating: "x", count: 4096))))
        XCTAssertThrowsError(try inspector(URL(fileURLWithPath: parent.path + "/" + String(repeating: "a/", count: 65) + "z")))
        XCTAssertThrowsError(try inspector(URL(fileURLWithPath: parent.path + "/missing")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("missing").path))
    }
    func testNonDirectoryAnchorAndReplacedAncestorFailClosedWithoutEffects() throws {
        let parent = try ownedParent(), file = parent.appendingPathComponent("file")
        try Data("anchor sentinel".utf8).write(to: file)
        XCTAssertThrowsError(try inspector(file).inspect())
        XCTAssertEqual(try Data(contentsOf: file), Data("anchor sentinel".utf8))
        let anchor = parent.appendingPathComponent("anchor", isDirectory: true)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        let check = try inspector(anchor)
        try FileManager.default.removeItem(at: anchor)
        try Data("replacement".utf8).write(to: anchor)
        XCTAssertThrowsError(try check.inspect())
        XCTAssertEqual(try Data(contentsOf: anchor), Data("replacement".utf8))
    }
}
