import XCTest
@testable import ScreenpunkController

final class PreviewPathTests: XCTestCase {
    func testPreviewReturnsImageContentNotAPath() throws {
        let service = try makeService(renderer: InjectedPreviewRenderer(capture: sampleCapture()))
        let created = try createDashboard(service, marker: "REV1")
        let router = MCPToolRouter(service: service)
        let result = router.call(
            name: "preview_dashboard",
            arguments: .object(["dashboardId": .string(created.manifest.dashboardId)])
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.filter(\.isImage).count, 1)
        if case .image(let data, let mime, let metadata) = result.content[0] {
            XCTAssertEqual(mime, "image/png")
            XCTAssertEqual(Data(base64Encoded: data)?.starts(with: PNGMagic.bytes), true)
            XCTAssertEqual(metadata?["revision"], created.manifest.revision)
            XCTAssertEqual(metadata?["live"], "true")
            XCTAssertNotEqual(metadata?["path"], created.packageDirectory.path)
        } else {
            XCTFail("expected image content")
        }
        if case .text(let text) = result.content[1] {
            XCTAssertTrue(text.contains("macOS-preview"))
            XCTAssertTrue(text.contains("\"live\":true") || text.contains("\"live\" : true"))
            XCTAssertFalse(text.contains(created.packageDirectory.path))
            XCTAssertTrue(text.contains("Live preview"))
        } else {
            XCTFail("expected metadata text")
        }
    }

    func testPreviewIsLiveByDefaultAndTwoRevisionsChangeIdentity() throws {
        let service = try makeService(renderer: InjectedPreviewRenderer(capture: sampleCapture()))
        let router = MCPToolRouter(service: service)
        let first = try createDashboard(service, marker: "ONE")
        let second = try service.updateDashboard(
            arguments: .object([
                "dashboardId": .string(first.manifest.dashboardId),
                "name": .string("Alpha"),
                "baseRevision": .string(first.manifest.revision),
                "files": .array([
                    .object(["path": .string("index.html"), "text": .string("<p>TWO</p>")])
                ])
            ])
        )
        XCTAssertNotEqual(first.manifest.revision, second.manifest.revision)

        let preview1 = router.call(
            name: "preview_dashboard",
            arguments: .object(["dashboardId": .string(first.manifest.dashboardId), "revision": .string(first.manifest.revision)])
        )
        let preview2 = router.call(
            name: "preview_dashboard",
            arguments: .object(["dashboardId": .string(second.manifest.dashboardId)])
        )
        guard
            case .image(_, _, let meta1) = preview1.content[0],
            case .image(_, _, let meta2) = preview2.content[0]
        else {
            return XCTFail("both previews must return image content")
        }
        XCTAssertEqual(meta1?["revision"], first.manifest.revision)
        XCTAssertEqual(meta2?["revision"], second.manifest.revision)
        XCTAssertNotEqual(meta1?["revision"], meta2?["revision"])
        XCTAssertEqual(meta1?["live"], "true")
    }

    func testFailedRenderNeverReturnsPlaceholderImage() throws {
        let service = try makeService(
            renderer: InjectedPreviewRenderer(error: .snapshotUnavailable(reason: "timeout"))
        )
        let created = try createDashboard(service, marker: "FAIL")
        let router = MCPToolRouter(service: service)
        let result = router.call(
            name: "preview_dashboard",
            arguments: .object(["dashboardId": .string(created.manifest.dashboardId)])
        )
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.errorCode, "snapshot_unavailable")
        XCTAssertFalse(result.content.contains(where: \.isImage))
        if case .text(let text) = result.content[0] {
            XCTAssertTrue(text.contains("SNAPSHOT_UNAVAILABLE"))
            XCTAssertFalse(text.contains("placeholder"))
        }
    }

    func testMissingHelperIsUnavailableNotAFakePNG() throws {
        let service = try makeService(renderer: nil)
        let created = try createDashboard(service, marker: "NOHELP")
        service.replaceRenderer(nil)
        let router = MCPToolRouter(service: service)
        let result = router.call(
            name: "preview_dashboard",
            arguments: .object(["dashboardId": .string(created.manifest.dashboardId)])
        )
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.errorCode, "snapshot_unavailable")
        XCTAssertFalse(result.content.contains(where: \.isImage))
    }

    func testProposeConnectionNeverSelfApproves() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-ctrl-\(UUID().uuidString)")
        let store = try! DashboardPackageStore(root: root)
        let service = ControllerService(store: store, renderer: nil)
        let router = MCPToolRouter(service: service)
        let result = router.call(name: "propose_connection", arguments: .object(["alias": .string("ha")]))
        XCTAssertFalse(result.isError)
        if case .text(let text) = result.content[0] {
            XCTAssertTrue(text.contains("permission_required"))
            XCTAssertTrue(text.contains("\"selfApproved\":false") || text.contains("\"selfApproved\" : false"))
        } else {
            XCTFail("expected JSON text")
        }
    }

    func testInteractPreviewDescribesLiveAction() throws {
        let service = try makeService(renderer: InjectedPreviewRenderer(capture: sampleCapture()))
        let created = try createDashboard(service, marker: "TAP")
        let router = MCPToolRouter(service: service)
        let result = router.call(
            name: "interact_preview",
            arguments: .object([
                "dashboardId": .string(created.manifest.dashboardId),
                "kind": .string("tap"),
                "x": .int(10),
                "y": .int(20)
            ])
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains(where: \.isImage))
        if case .text(let text) = result.content[1] {
            XCTAssertTrue(text.contains("tap"))
            XCTAssertTrue(text.lowercased().contains("live"))
        }
    }
}

private func makeService(renderer: PreviewRenderer?) throws -> ControllerService {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-ctrl-\(UUID().uuidString)")
    let store = try DashboardPackageStore(root: root)
    return ControllerService(store: store, renderer: renderer)
}

private func createDashboard(_ service: ControllerService, marker: String) throws -> DashboardRevisionRecord {
    try service.updateDashboard(
        arguments: .object([
            "name": .string("Alpha"),
            "files": .array([
                .object(["path": .string("index.html"), "text": .string("<p>\(marker)</p>")])
            ])
        ])
    )
}

private func sampleCapture() -> PreviewCapture {
    PreviewCapture(
        png: testPNG(),
        width: 390,
        height: 844,
        revision: "pending",
        digest: "pending",
        live: true,
        connectionHealth: "none",
        diagnostics: ["injected"]
    )
}
