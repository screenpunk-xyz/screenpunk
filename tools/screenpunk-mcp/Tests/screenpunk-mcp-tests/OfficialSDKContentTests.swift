import Foundation
import XCTest
import ScreenpunkController
@testable import screenpunk_mcp

final class OfficialSDKContentTests: XCTestCase {
    func testSDKUpgradePreservesOpaqueImageMetadataAndTextWireShape() throws {
        let content = OfficialMCPServer.mcpContent([.text("Preview"),
            .image(dataBase64: "aGVsbG8=", mimeType: "image/png", metadata: ["codex/imageDetail": "original"]),
            .image(dataBase64: "aA==", mimeType: "image/png", metadata: nil)])
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [[String: Any]])
        XCTAssertEqual(wire[0]["type"] as? String, "text")
        XCTAssertEqual(wire[0]["text"] as? String, "Preview")
        XCTAssertEqual(wire[1]["type"] as? String, "image")
        XCTAssertEqual(wire[1]["data"] as? String, "aGVsbG8=")
        XCTAssertEqual(wire[1]["mimeType"] as? String, "image/png")
        XCTAssertEqual((wire[1]["_meta"] as? [String: String])?["codex/imageDetail"], "original")
        XCTAssertNil(wire[2]["_meta"])
    }
}
