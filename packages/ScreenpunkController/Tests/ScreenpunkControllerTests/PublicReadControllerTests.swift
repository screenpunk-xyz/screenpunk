import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class PublicReadControllerTests: XCTestCase {
    func testApprovalPersistsForExactRevisionAndPreviewGetsOnlyApprovedAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-approval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let service = ControllerService(store: try DashboardPackageStore(root: root), renderer: recorder)
        var connection = ManifestConnection(alias: "jsonData", required: true)
        connection.publicHTTP = .init(origin: "https://data.example.org", operations: [.init(name: "timeline", path: "/timeline", response: "json")])
        var raster = ManifestConnection(alias: "rasterData", required: false)
        raster.publicHTTP = .init(origin: "https://images.example.org", operations: [.init(name: "frame", path: "/photos/{filename}", response: "raster", parameters: ["filename": .init(location: "path", pathSegment: .init(maxLength: 128))])])
        let record = try service.store.putDashboard(dashboardId: nil, name: "Public fixture", baseRevision: nil,
            target: service.defaultTarget(), connections: [connection,raster], files: [.init(path: "index.html", text: "<p>Fixture</p>")])
        XCTAssertThrowsError(try service.approvedPublicConnections(record.manifest))
        XCTAssertThrowsError(try service.approvePublicConnections(dashboardId: record.manifest.dashboardId, revision: record.manifest.revision, approved: false))
        let approved = try service.approvePublicConnections(dashboardId: record.manifest.dashboardId, revision: record.manifest.revision, approved: true, aliases: ["jsonData"])
        XCTAssertEqual(approved.connections.map(\.alias), ["jsonData"])
        _ = try service.previewDashboard(dashboardId: record.manifest.dashboardId, revision: record.manifest.revision)
        XCTAssertEqual(recorder.request?.nativePublicReads, approved)
        XCTAssertNil(recorder.request?.nativeHomeAssistant)
        _ = try service.previewDashboard(dashboardId: record.manifest.dashboardId, revision: record.manifest.revision, live: false)
        XCTAssertNil(recorder.request?.nativePublicReads)
        let reopened = ControllerService(store: try DashboardPackageStore(root: root))
        XCTAssertEqual(try reopened.approvedPublicConnections(record.manifest), approved)
        var changed = record.manifest; changed.revision = UUID().uuidString
        XCTAssertThrowsError(try reopened.approvedPublicConnections(changed))
        let all = try service.approvePublicConnections(dashboardId: record.manifest.dashboardId, revision: record.manifest.revision, approved: true, aliases: ["rasterData"])
        XCTAssertEqual(all.connections.count, 2)
        XCTAssertTrue(all.requiresDynamicPaths)
        _ = try service.previewDashboard(dashboardId: record.manifest.dashboardId, revision: record.manifest.revision)
        XCTAssertEqual(recorder.request?.nativePublicReads, all)
        var widened = record.manifest
        widened.connections[1].publicHTTP?.operations[0].parameters["filename"]?.pathSegment?.maxLength = 256
        XCTAssertThrowsError(try service.approvedPublicConnections(widened))
        let inspect = try XCTUnwrap(JSONSerialization.jsonObject(with: service.inspectPublicConnections(dashboardId: record.manifest.dashboardId, revision: nil)) as? [String: Any])
        XCTAssertEqual(inspect["approved"] as? Bool, true)
    }
    func testDevicePreparationCarriesOnlyApprovedAliasesAndPreservesSourceIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-approval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ControllerService(store: try DashboardPackageStore(root: root))
        var json = ManifestConnection(alias: "jsonData", required: true)
        json.publicHTTP = .init(origin: "https://data.example.org", operations: [.init(name: "timeline", path: "/timeline", response: "json")])
        var raster = ManifestConnection(alias: "rasterData", required: false)
        raster.publicHTTP = .init(origin: "https://images.example.org", operations: [.init(name: "frame", path: "/photos/{filename}", response: "raster", parameters: ["filename": .init(location: "path", pathSegment: .init(maxLength: 128))])])
        let source = try service.store.putDashboard(dashboardId: nil, name: "Public fixture", baseRevision: nil,
            target: service.defaultTarget(), connections: [json, raster], files: [.init(path: "index.html", text: "<p>Fixture</p>")])
        let device = DeviceProfile(deviceId: "ipad", name: "iPad", width: 768, height: 1024)
        XCTAssertThrowsError(try service.prepareDashboardForDevice(dashboardId: source.manifest.dashboardId, revision: source.manifest.revision, device: device, orientation: .landscape))
        let approved = try service.approvePublicConnections(dashboardId: source.manifest.dashboardId, revision: source.manifest.revision, approved: true, aliases: ["jsonData"])
        let prepared = try service.prepareDashboardForDevice(dashboardId: source.manifest.dashboardId, revision: source.manifest.revision, device: device, orientation: .landscape)
        XCTAssertNotEqual(prepared.manifest.revision, source.manifest.revision)
        XCTAssertEqual(prepared.manifest.target.width, 1024)
        XCTAssertEqual(prepared.files, source.files)
        let transferred = try XCTUnwrap(service.approvedPublicConnections(prepared.manifest))
        XCTAssertEqual(transferred.dashboardId, source.manifest.dashboardId)
        XCTAssertEqual(transferred.revision, prepared.manifest.revision)
        XCTAssertEqual(transferred.connections, approved.connections)
        XCTAssertEqual(try service.approvedPublicConnections(source.manifest), approved)
        let reopened = ControllerService(store: try DashboardPackageStore(root: root))
        XCTAssertEqual(try reopened.approvedPublicConnections(prepared.manifest), transferred)
        // A raw prepared revision has no inherited authorization.
        let raw = try ScreenPackagePreparation.prepare(source, for: device, orientation: .portrait, root: root)
        XCTAssertThrowsError(try service.approvedPublicConnections(raw.manifest))
        // Changing declarations invalidates even the prepared revision's approval.
        var tampered = prepared.manifest
        tampered.connections[0].publicHTTP?.origin = "https://other.example.org"
        XCTAssertThrowsError(try service.approvedPublicConnections(tampered))
        // Same dashboard and declarations do not authorize a new source revision.
        let edited = try service.store.putDashboard(dashboardId: source.manifest.dashboardId, name: source.manifest.name,
            baseRevision: source.manifest.revision, target: source.manifest.target, connections: source.manifest.connections,
            files: [.init(path: "index.html", text: "<p>Changed code</p>")])
        XCTAssertThrowsError(try service.prepareDashboardForDevice(dashboardId: edited.manifest.dashboardId, revision: edited.manifest.revision, device: device, orientation: .landscape))
        let duplicate = try service.store.putDashboard(dashboardId: nil, name: source.manifest.name, baseRevision: nil,
            target: source.manifest.target, connections: source.manifest.connections, files: [.init(path: "index.html", text: "<p>Fixture</p>")])
        XCTAssertThrowsError(try service.prepareDashboardForDevice(dashboardId: duplicate.manifest.dashboardId, revision: duplicate.manifest.revision, device: device, orientation: .landscape))
        // On-disk byte changes cannot inherit approval from the original file hashes.
        try Data("<p>Tampered source</p>".utf8).write(to: source.packageDirectory.appendingPathComponent("index.html"))
        XCTAssertThrowsError(try service.prepareDashboardForDevice(dashboardId: source.manifest.dashboardId, revision: source.manifest.revision, device: device, orientation: .landscape))
    }

    func testMCPContractContainsApprovalAndInspection() {
        let approval = MCPToolSchemas.inputSchema(for: "approve_public_connections")
        XCTAssertEqual(approval["properties"]?["approved"]?["type"]?.string, "boolean")
        XCTAssertEqual(approval["properties"]?["aliases"]?["type"]?.string, "array")
    }
    final class Recorder: PreviewRenderer, @unchecked Sendable {
        var request: PreviewRequest?
        func render(_ request: PreviewRequest) throws -> PreviewCapture {
            self.request = request
            return PreviewCapture(png: Data([137,80,78,71,13,10,26,10]), width: request.width, height: request.height, revision: request.revision, digest: request.digest, live: request.live, connectionHealth: "fixture", diagnostics: [])
        }
    }
}
