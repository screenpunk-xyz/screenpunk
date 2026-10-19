import Foundation
import XCTest
@testable import ScreenpunkController

#if os(macOS)
private struct PreservedCopyDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

private struct PreservedCopyGate: WorkspaceOldWriterExclusionGate {
    func withExclusion<T>(legacyPath: String, device: UInt64, inode: UInt64,
                          perform: () throws -> T) throws -> T {
        guard legacyPath.hasPrefix("/private/tmp/"), device != 0, inode != 0 else {
            throw WorkspaceError.unavailable
        }
        return try perform()
    }
}

final class WorkspacePreservedLibraryCopyTests: XCTestCase {
    func testCopiedPersonalLibraryCanBeReviewedAndRecoveredWithoutAuthority() throws {
        guard let source = ProcessInfo.processInfo.environment["SCREENPUNK_MIGRATION_COPY_TEST_HOME"] else {
            throw XCTSkip("Set SCREENPUNK_MIGRATION_COPY_TEST_HOME to a disposable private copy")
        }
        guard source.hasPrefix("/private/tmp/"),
              source.hasSuffix("/legacy-controller-copy") else {
            throw WorkspaceError.invalidPath
        }
        let base = URL(fileURLWithPath: "/private/tmp/sp-preserved-copy-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: PreservedCopyDocuments(url: documents),
            machineRootPath: base.appendingPathComponent("machine").path)
        let migration = WorkspaceLegacyMigration(workspace: workspace)
        let plan = try migration.inspectLegacy(at: source, timeout: 120)
        XCTAssertEqual(plan.summary.projectIds.count, 0)
        XCTAssertEqual(plan.summary.packageRevisions.count, 236)
        let unsupportedShape = Set(plan.summary.unsupportedPortablePaths.map { path -> String in
            let parts = path.split(separator: "/")
            return "\(parts.count) components ending \(parts.last ?? "")"
        })
        XCTAssertTrue(plan.summary.unsupportedPortablePaths.isEmpty,
                      "Unsupported shape: \(unsupportedShape)")
        let output = ProcessInfo.processInfo.environment["SCREENPUNK_MIGRATION_COPY_OUTPUT"]
        if let output {
            guard output.hasPrefix("/private/tmp/screenpunk-gui-test-"),
                  !FileManager.default.fileExists(atPath: output) else {
                throw WorkspaceError.invalidPath
            }
        }
        let destination = output.map { URL(fileURLWithPath: $0) }
            ?? base.appendingPathComponent("migrated")
        _ = try migration.apply(plan, to: destination.path,
                                gate: PreservedCopyGate(), timeout: 120)
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: workspace,
            localReadTimeout: 120).list(deadline: ProcessInfo.processInfo.systemUptime + 120).count, 236)
        let heads = destination.appendingPathComponent(
            "Workbench/Migrations/\(plan.summary.migrationId)/legacy-heads")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: heads.path).count, 15)
        let record = try Data(contentsOf: destination.appendingPathComponent(
            "Workbench/Migrations/\(plan.summary.migrationId)/record.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        XCTAssertEqual((object["cacheOnlyRevisions"] as? [String])?.count, 109)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(
            "devices.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(
            "public-read-approvals").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source + "/dashboards"))
    }
}
#endif
