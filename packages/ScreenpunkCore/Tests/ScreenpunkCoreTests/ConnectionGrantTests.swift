import XCTest
@testable import ScreenpunkCore

final class ConnectionGrantTests: XCTestCase {
    func testDecodesCommittedHTTPGrant() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("schemas/fixtures/valid/connection-grant.json"))
        let grant = try ConnectionGrantValidator.decode(data)
        XCTAssertEqual(grant.alias, "status")
        XCTAssertEqual(grant.transport, .http)
        XCTAssertEqual(grant.operations.first?.path, "/v1/status")
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("Bearer") == true)
    }

    func testDecodesWSGrant() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("schemas/fixtures/valid/connection-grant-ws.json"))
        let grant = try ConnectionGrantValidator.decode(data)
        XCTAssertEqual(grant.transport, .ws)
        XCTAssertEqual(grant.operations.first?.path, "/v1/events")
    }

    func testRejectsSecretLikeAuthRef() {
        var grant = sampleGrant()
        grant.authRef = "Bearer super-secret"
        XCTAssertThrowsError(try ConnectionGrantValidator.validate(grant)) { error in
            XCTAssertEqual(error as? ConnectionFailure, .validationFailed)
        }
    }

    func testMacIsNotARuntimeProxy() {
        XCTAssertFalse(ConnectionRuntime.macIsRuntimeProxy)
        XCTAssertFalse(TransportExceptions.macIsRuntimeProxy)
        XCTAssertFalse(TransportExceptions.followsRedirects)
        XCTAssertFalse(TransportExceptions.globalArbitraryLoads)
        XCTAssertFalse(TransportExceptions.selfSignedHTTPSTrustedSilently)
    }

    private func sampleGrant() -> ConnectionGrant {
        ConnectionGrant(
            schemaVersion: 1,
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            alias: "status",
            origin: "http://127.0.0.1:4173",
            transport: .http,
            authRef: "keychain:fixture-status",
            lan: true,
            allowInsecureHTTP: true,
            operations: [
                ConnectionOperation(
                    name: "getStatus",
                    kind: .http,
                    method: .GET,
                    path: "/v1/status",
                    idempotent: true,
                    write: false,
                    maxAgeSeconds: 45
                )
            ]
        )
    }

    private func repoRoot(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("schemas/connection-grant.schema.json").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: file)
    }
}
