import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class ConnectionAdapterTests: XCTestCase {
    func testDeviceRuntimeIsNotAMacProxy() {
        XCTAssertFalse(DeviceConnectionRuntime.macIsRuntimeProxy)
        XCTAssertFalse(DeviceConnectionRuntime.followsRedirects)
        XCTAssertFalse(DeviceConnectionRuntime.globalArbitraryLoads)
        XCTAssertFalse(DeviceConnectionRuntime.selfSignedHTTPSTrustedSilently)
    }

#if os(macOS)
    func testHTTPAgainstFixtureServer() async throws {
        let fixture = try FixtureServer.start()
        defer { fixture.stop() }

        let store = MemoryCredentialStore()
        try store.put(Data("fixture-token".utf8), for: "keychain:fixture-status")
        let runtime = DeviceConnectionRuntime.make(
            dashboardId: "dash",
            store: store,
            resolver: FixedResolver(["127.0.0.1"])
        )
        let grant = httpGrant(port: fixture.port)
        try await runtime.install(
            grant: grant,
            binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none)
        )
        let result = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(result.statusCode, 200)
        let body = try JSONSerialization.jsonObject(with: result.body) as? [String: Any]
        XCTAssertEqual(body?["fixture"] as? String, "SCREENPUNK_HTTP_FIXTURE_V1")
        XCTAssertFalse(result.diagnostic.contains("fixture-token"))
    }

    func testAuthenticatedHTTPUsesStoreSecret() async throws {
        let fixture = try FixtureServer.start(token: "fixture-token")
        defer { fixture.stop() }

        let store = MemoryCredentialStore()
        try store.put(Data("fixture-token".utf8), for: "keychain:fixture-status")
        let runtime = DeviceConnectionRuntime.make(
            dashboardId: "dash",
            store: store,
            resolver: FixedResolver(["127.0.0.1"])
        )
        let grant = httpGrant(port: fixture.port)
        try await runtime.install(
            grant: grant,
            binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer)
        )
        let result = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(result.statusCode, 200)
    }

    func testRedirectIsDenied() async throws {
        let fixture = try FixtureServer.start()
        defer { fixture.stop() }
        let runtime = DeviceConnectionRuntime.make(
            dashboardId: "dash",
            store: MemoryCredentialStore(),
            resolver: FixedResolver(["127.0.0.1"])
        )
        let grant = ConnectionGrant(
            schemaVersion: 1,
            id: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            alias: "redir",
            origin: "http://127.0.0.1:\(fixture.port)",
            transport: .http,
            authRef: "keychain:fixture-status",
            lan: true,
            allowInsecureHTTP: true,
            operations: [
                ConnectionOperation(
                    name: "bounce",
                    kind: .http,
                    method: .GET,
                    path: "/v1/redirect",
                    idempotent: true,
                    write: false
                )
            ]
        )
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))
        do {
            _ = try await runtime.request(alias: "redir", operation: "bounce", parameters: [:])
            XCTFail("redirect must not succeed")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .deniedEgress)
        }
    }

    func testOversizedResponseIsRejected() async throws {
        let fixture = try FixtureServer.start()
        defer { fixture.stop() }
        let runtime = DeviceConnectionRuntime.make(
            dashboardId: "dash",
            store: MemoryCredentialStore(),
            httpBounds: HTTPAdapterBounds(timeoutSeconds: 15, maxResponseBytes: 64),
            resolver: FixedResolver(["127.0.0.1"])
        )
        let grant = ConnectionGrant(
            schemaVersion: 1,
            id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            alias: "blob",
            origin: "http://127.0.0.1:\(fixture.port)",
            transport: .http,
            authRef: "keychain:fixture-status",
            lan: true,
            allowInsecureHTTP: true,
            operations: [
                ConnectionOperation(
                    name: "getBlob",
                    kind: .http,
                    method: .GET,
                    path: "/v1/blob",
                    idempotent: true,
                    write: false
                )
            ]
        )
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))
        do {
            _ = try await runtime.request(alias: "blob", operation: "getBlob", parameters: [:])
            XCTFail("oversize body must fail")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .sizeLimit)
        }
    }

    func testWebSocketAgainstFixtureServer() async throws {
        let fixture = try FixtureServer.start()
        defer { fixture.stop() }
        let runtime = DeviceConnectionRuntime.make(
            dashboardId: "dash",
            store: MemoryCredentialStore(),
            resolver: FixedResolver(["127.0.0.1"])
        )
        let grant = ConnectionGrant(
            schemaVersion: 1,
            id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            alias: "events",
            origin: "http://127.0.0.1:\(fixture.port)",
            transport: .ws,
            authRef: "keychain:fixture-events",
            lan: true,
            allowInsecureHTTP: true,
            operations: [
                ConnectionOperation(
                    name: "listen",
                    kind: .ws,
                    method: .GET,
                    path: "/v1/events",
                    idempotent: true,
                    write: false
                )
            ]
        )
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))
        let id = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        let message = try await runtime.receive(id: id)
        let body = try JSONSerialization.jsonObject(with: message) as? [String: Any]
        XCTAssertEqual(body?["fixture"] as? String, "SCREENPUNK_WS_FIXTURE_V1")
        await runtime.unsubscribe(id: id)
    }

    func testKeychainRoundTripIfAvailable() throws {
        let store = KeychainCredentialStore(service: "xyz.screenpunk.connections.tests")
        let ref = "test-\(UUID().uuidString)"
        do {
            try store.put(Data("unit".utf8), for: ref)
        } catch {
            throw XCTSkip("Keychain unavailable")
        }
        XCTAssertEqual(try store.secret(for: ref), Data("unit".utf8))
        try store.delete(ref)
        XCTAssertNil(try store.secret(for: ref))
    }

    private func httpGrant(port: Int) -> ConnectionGrant {
        ConnectionGrant(
            schemaVersion: 1,
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            alias: "status",
            origin: "http://127.0.0.1:\(port)",
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
#endif
}

#if os(macOS)
private struct FixtureServer {
    let process: Process
    let port: Int

    static func start(token: String? = nil) throws -> FixtureServer {
        let root = repoRoot()
        let script = root.appendingPathComponent("tools/fixture-server/server.mjs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SCREENPUNK_FIXTURE_PORT"] = "0"
        if let token {
            environment["SCREENPUNK_FIXTURE_TOKEN"] = token
        }
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        var line = ""
        let handle = pipe.fileHandleForReading
        while Date() < deadline && process.isRunning {
            let available = handle.availableData
            if available.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            line += String(decoding: available, as: UTF8.self)
            if line.contains("\n") { break }
        }
        let match = line.split(separator: "\n").first { $0.hasPrefix("fixture-server ") }
        guard let match, let port = Int(match.split(separator: " ").last ?? "") else {
            process.terminate()
            throw NSError(domain: "ScreenpunkFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "fixture-server did not start: \(line)"
            ])
        }
        return FixtureServer(process: process, port: port)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}

private func repoRoot(file: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: file)
    for _ in 0..<12 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("tools/fixture-server/server.mjs").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: file)
}
#endif
