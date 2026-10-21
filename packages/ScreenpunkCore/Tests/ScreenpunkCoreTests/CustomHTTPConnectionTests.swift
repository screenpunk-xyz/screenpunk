import XCTest
@testable import ScreenpunkCore

final class CustomHTTPConnectionTests: XCTestCase {
    func declaration() -> CustomHTTPDeclaration {
        .init(name: "Desk service", authentication: "bearer", operations: [.init(name: "status", method: "GET", path: "/status"), .init(name: "power", method: "POST", path: "/power", parameters: ["state": ["on", "off"]])])
    }
    func testRejectsUnboundedDestinationsAndCredentialOverrides() throws {
        try declaration().validate(alias: "desk")
        for alias in ["home", "googleTV", "a/b"] { XCTAssertThrowsError(try declaration().validate(alias: alias)) }
        for path in ["//evil.example", "/../secret", "/x?token=y", "/%2e%2e/secret"] {
            var d = declaration(); d.operations[0].path = path; XCTAssertThrowsError(try d.validate(alias: "desk"))
        }
        for key in ["token", "headers", "url", "Authorization"] {
            var d = declaration(); d.operations[0].parameters = [key: ["value"]]; XCTAssertThrowsError(try d.validate(alias: "desk"))
        }
        var d = declaration(); d.authentication = "apiKey"; d.headerName = "Host"
        XCTAssertThrowsError(try d.validate(alias: "desk"))
    }
    func testNativeAuthenticationAndParameterRestriction() async throws {
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: "screen", name: "Screen", revision: "r1", entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "iPad", width: 800, height: 600, scale: 1, orientation: "landscape"), connections: [], files: [])
        var m = manifest; var connection = ManifestConnection(alias: "desk", required: true); connection.customHTTP = declaration(); m.connections = [connection]
        let transport = MockHTTPTransport(response: .init(status: 200, body: Data("{\"state\":\"on\"}".utf8)))
        let runtime = DeviceCustomHTTPRuntime(installationID: UUID(), manifest: m, provider: { _, _, _ in .init(origin: "https://service.example.com", secret: "fixture-only", allowLocalNetwork: false, allowInsecureHTTP: false) }, http: transport, webSocket: MockWebSocketTransport(messages: []), resolver: CustomResolver(), validate: {})
        _ = try await runtime.request(alias: "desk", operation: "power", parameters: ["state": "on"], readOnly: false)
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer fixture-only")
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "https://service.example.com/power")
        XCTAssertEqual(transport.lastRequest?.method, "POST")
        do { _ = try await runtime.request(alias: "desk", operation: "power", parameters: ["state": "arbitrary"], readOnly: false); XCTFail() } catch {}
        do { _ = try await runtime.request(alias: "desk", operation: "power", parameters: ["state": "on"], readOnly: true); XCTFail() } catch {}
        XCTAssertEqual(transport.lastRequest?.headers["Content-Type"], "application/json")
        transport.response = .init(status: 204, body: Data())
        let empty = try await runtime.request(alias: "desk", operation: "power", parameters: ["state": "off"], readOnly: false)
        XCTAssertEqual(empty.body, Data("null".utf8))
        transport.response = .init(status: 302, body: Data())
        do { _ = try await runtime.request(alias: "desk", operation: "status", parameters: [:], readOnly: false); XCTFail() } catch {}
    }
}
private struct CustomResolver: DestinationResolver { func addresses(for host: String) throws -> [String] { ["93.184.216.34"] } }
