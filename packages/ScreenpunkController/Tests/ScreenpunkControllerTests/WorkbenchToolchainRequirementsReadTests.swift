#if os(macOS)
import XCTest
import Foundation
@testable import ScreenpunkController

private struct ToolchainReadDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

final class WorkbenchToolchainRequirementsReadTests: XCTestCase {
    func testPortablePinIsReportedWithoutClaimingInstallationOrTrust() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-toolchain-read-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: ToolchainReadDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        let selected = try workspace.create(at: root.appendingPathComponent("visible").path)
        let pin = String(repeating: "a", count: 64)
        let payload = Data("""
        {"schemaVersion":1,"required":[{"catalogEntryId":"kit-1","kitVersion":"v1","platform":"darwin-arm64","inventoryHash":"\(pin)"}]}
        """.utf8)
        try payload.write(to: root.appendingPathComponent(
            "visible/Workbench/Toolchains/requirements.json"), options: .atomic)
        let result = try WorkbenchToolchainRequirementsReader.read(workspace: workspace)
        XCTAssertEqual(result.workspaceId, selected.descriptor.workspaceId)
        XCTAssertEqual(result.required.count, 1)
        XCTAssertEqual(result.required.first?.inventoryHash, pin)
        XCTAssertEqual(result.trust, "not_registered")
        XCTAssertEqual(result.installation, "not_assessed")
    }
}
#endif
