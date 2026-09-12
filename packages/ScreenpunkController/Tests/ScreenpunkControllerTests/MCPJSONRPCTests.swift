import XCTest
@testable import ScreenpunkController

final class MCPJSONRPCTests: XCTestCase {
    func testInitializeListsToolsAndHelpResourceIncludesUnlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-ctrl-\(UUID().uuidString)")
        let store = try DashboardPackageStore(root: root)
        let service = ControllerService(store: store, renderer: InjectedPreviewRenderer(capture: sampleCapture()))
        let rpc = MCPJSONRPC(router: MCPToolRouter(service: service))

        let initLine = try rpc.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        XCTAssertTrue(initLine?.contains("screenpunk") == true)
        XCTAssertTrue(initLine?.contains("two fingers") == true)
        XCTAssertTrue(initLine?.contains("ten seconds") == true)

        let toolsLine = try rpc.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#) ?? ""
        XCTAssertTrue(toolsLine.contains("preview_dashboard"))
        XCTAssertTrue(toolsLine.contains("get_help"))
        XCTAssertTrue(toolsLine.contains("\"live\""))
        XCTAssertTrue(toolsLine.contains("readOnlyHint"))

        let helpLine = try rpc.handle(
            line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_help","arguments":{"topic":"unlink"}}}"#
        ) ?? ""
        XCTAssertTrue(helpLine.contains("two fingers"))
        XCTAssertTrue(helpLine.contains("Unlink"))
        XCTAssertTrue(helpLine.contains("does not erase"))

        let resource = try rpc.handle(
            line: #"{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"screenpunk://help/unlink"}}"#
        ) ?? ""
        XCTAssertTrue(resource.contains("ten seconds") || resource.contains("10 seconds"))
    }

    func testPreviewToolCallReturnsImageContentOverJSONRPC() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-ctrl-\(UUID().uuidString)")
        let store = try DashboardPackageStore(root: root)
        let service = ControllerService(store: store, renderer: InjectedPreviewRenderer(capture: sampleCapture()))
        let created = try service.updateDashboard(
            arguments: .object([
                "name": .string("RPC"),
                "files": .array([.object(["path": .string("index.html"), "text": .string("<p>RPC</p>")])])
            ])
        )
        let rpc = MCPJSONRPC(router: MCPToolRouter(service: service))
        let payload = """
        {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"preview_dashboard","arguments":{"dashboardId":"\(created.manifest.dashboardId)"}}}
        """
        let line = try rpc.handle(line: payload) ?? ""
        let content = try JSONValue.parse(Data(line.utf8))["result"]?["content"]?.array ?? []
        XCTAssertEqual(content.first?["type"]?.string, "image")
        XCTAssertEqual(content.first?["mimeType"]?.string, "image/png")
        XCTAssertEqual(Data(base64Encoded: content.first?["data"]?.string ?? "")?.starts(with: PNGMagic.bytes), true)
        XCTAssertEqual(content.first?["metadata"]?["revision"]?.string, created.manifest.revision)
        XCTAssertFalse(line.contains(created.packageDirectory.path))
        XCTAssertTrue(content.dropFirst().first?["text"]?.string?.contains(created.manifest.revision) == true)
    }
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
