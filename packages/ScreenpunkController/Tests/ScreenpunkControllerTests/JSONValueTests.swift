import Foundation
import CoreFoundation
import XCTest
@testable import ScreenpunkController

final class JSONValueTests: XCTestCase {
    func testJSONNumbersAndBooleansKeepTheirTypes() throws {
        let expected: JSONValue = .array([.int(0), .int(1), .bool(true), .bool(false), .int(2), .int(-1), .double(1.5)])
        XCTAssertEqual(try JSONValue.parse(Data("[0,1,true,false,2,-1,1.5]".utf8)), expected)
        XCTAssertEqual(try JSONValue.from([NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: true), NSNumber(value: false), NSNumber(value: 2), NSNumber(value: -1), NSNumber(value: 1.5)]), expected)
        XCTAssertEqual(try JSONValue.from([0, 1, true, false, 2, -1, 1.5] as [Any]), expected)
        XCTAssertEqual(try JSONValue.parse(expected.data()), expected)
    }

    func testFallbackRepliesKeepZeroAndOneRequestIDsNumeric() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("json-id-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ControllerService(store: try DashboardPackageStore(root: root))
        let rpc = MCPJSONRPC(router: MCPToolRouter(service: service))
        for id in [0, 1] {
            let line = try XCTUnwrap(rpc.handle(line: "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"ping\",\"params\":{}}"))
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let number = try XCTUnwrap(reply["id"] as? NSNumber)
            XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID())
            XCTAssertEqual(number.intValue, id)
        }
    }

    func testFallbackUpdatePreservesNestedPublicHTTPZeroOneBoundsAndBooleans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("json-bounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ControllerService(store: try DashboardPackageStore(root: root))
        let rpc = MCPJSONRPC(router: MCPToolRouter(service: service))
        let input = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_dashboard","arguments":{"name":"Synthetic bounds","connections":[{"alias":"publicData","required":true,"publicHTTP":{"origin":"https://data.example.org","userAgent":"Screenpunk/1","operations":[{"name":"sample","path":"/sample","response":"json","parameters":{"index":{"location":"query","minimum":0,"maximum":1}},"maxAgeSeconds":1,"staleSeconds":0}]}}],"files":[{"path":"index.html","text":"<p>Fixture</p>"}]}}}"#
        let line = try XCTUnwrap(rpc.handle(line: input))
        let reply = try JSONValue.parse(Data(line.utf8))
        XCTAssertEqual(reply["id"], .int(1))
        XCTAssertNotEqual(reply["result"]?["isError"]?.bool, true)
        let text = try XCTUnwrap(reply["result"]?["content"]?.array?.first?["text"]?.string)
        let record = try JSONValue.parse(Data(text.utf8))
        let id = try XCTUnwrap(record["dashboardId"]?.string)
        let manifest = try service.getDashboard(dashboardId: id, revision: nil).manifest
        XCTAssertEqual(manifest.connections.first?.required, true)
        let operation = try XCTUnwrap(manifest.connections.first?.publicHTTP?.operations.first)
        XCTAssertEqual(operation.parameters["index"]?.minimum, 0)
        XCTAssertEqual(operation.parameters["index"]?.maximum, 1)
        XCTAssertEqual(operation.maxAgeSeconds, 1)
        XCTAssertEqual(operation.staleSeconds, 0)
    }
}
