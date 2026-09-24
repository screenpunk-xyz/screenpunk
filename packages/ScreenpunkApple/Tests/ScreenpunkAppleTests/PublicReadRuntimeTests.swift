import XCTest
import ImageIO
import UniformTypeIdentifiers
import ScreenpunkCore
@testable import ScreenpunkApple

final class PublicReadRuntimeTests: XCTestCase {
    final class Clock: PairingClock, @unchecked Sendable {
        let lock = NSLock(); private var date = Date(timeIntervalSince1970: 1000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: Double) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
    }
    actor Transport: HTTPTransport {
        var requests: [AuthorizedHTTPRequest] = []
        var response = HTTPTransportResponse(status: 200, body: Data("{\"frames\":[1000,2000]}".utf8), headers: ["content-type": "application/json"])
        var delay: UInt64 = 0
        func set(_ response: HTTPTransportResponse, delay: UInt64 = 0) { self.response = response; self.delay = delay }
        func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
            requests.append(request)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            return response
        }
        func count() -> Int { requests.count }
    }
    func provisioning() throws -> PublicReadProvisioning {
        var connection = ManifestConnection(alias: "publicData", required: true)
        connection.publicHTTP = .init(origin: "https://data.example.org", operations: [
            .init(name: "timeline", path: "/timeline", response: "json", maxAgeSeconds: 1, staleSeconds: 10),
            .init(name: "frame", path: "/frames/{timestamp}.png", response: "raster", parameters: ["timestamp": .init(location: "path", minimum: 1000, maximum: 3000)], maxAgeSeconds: 1, staleSeconds: 10)])
        return try .init(manifest: .init(schemaVersion: 1, dashboardId: "synthetic", name: "Synthetic", revision: "revision-one", entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "fixture", width: 400, height: 400, scale: 1, orientation: "portrait"), connections: [connection], files: []))
    }
    func raster(width: Int = 2, height: Int = 2, jpeg: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testChangingDynamicRasterNamesUseNativeResourcesAndRejectURLInjection() async throws {
        let transport = Transport(); let clock = Clock()
        var config = try provisioning()
        config.connections[0].publicHTTP!.operations[1] = .init(name: "frame", path: "/uploads/{filename}", response: "raster", parameters: ["filename": .init(location: "path", pathSegment: .init(maxLength: 128))])
        let runtime = try PublicReadRuntime(provisioning: config, transport: transport, resolver: FixedResolver(["203.0.113.10"]), clock: clock)
        let resources = PublicRasterResources()
        for (i, name) in ["day-one~orig.png", "day-two.png"].enumerated() {
            clock.advance(1)
            let bytes = try raster(width: i + 2)
            await transport.set(.init(status: 200, body: bytes, headers: ["content-type": "image/png"]))
            let result = try await runtime.request(alias: "publicData", operation: "frame", parameters: ["filename": name])
            XCTAssertEqual(result.state, "fresh")
            let handle = try resources.put(result)
            XCTAssertEqual(try resources.asset(url: handle).data, bytes)
            resources.release(url: handle)
            XCTAssertThrowsError(try resources.asset(url: handle))
        }
        for value in ["https://evil.example/a.png", "../a.png", "%2Fother.png"] {
            do { _ = try await runtime.request(alias: "publicData", operation: "frame", parameters: ["filename":value]); XCTFail("accepted injection") }
            catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url.absoluteString }, ["https://data.example.org/uploads/day-one~orig.png", "https://data.example.org/uploads/day-two.png"])
        clock.advance(1)
        await transport.set(.init(status: 302, body: Data(), headers: ["location":"https://evil.example/a.png"]))
        let redirected = try await runtime.request(alias: "publicData", operation: "frame", parameters: ["filename":"redirect.png"])
        XCTAssertEqual(redirected.state, "error"); XCTAssertNil(redirected.body)
        XCTAssertEqual(redirected.code, ConnectionFailure.deniedEgress.rawValue)
        let count = await transport.count(); XCTAssertEqual(count, 3, "No follow-up to redirect destination")
        let denied = try PublicReadRuntime(provisioning: config, transport: transport, resolver: FixedResolver(["127.0.0.1"]))
        let local = try await denied.request(alias: "publicData", operation: "frame", parameters: ["filename":"private.png"])
        XCTAssertEqual(local.code, ConnectionFailure.deniedEgress.rawValue)
        let after = await transport.count(); XCTAssertEqual(after, count)
    }

    func testCacheIdentityDeduplicationNoCredentialsAndCachedReplay() async throws {
        let transport = Transport(); let clock = Clock()
        await transport.set(.init(status: 200, body: try raster(), headers: ["content-type": "image/png", "last-modified": "Mon, 14 Sep 2026 10:00:00 GMT"]), delay: 30_000_000)
        let runtime = try PublicReadRuntime(provisioning: provisioning(), transport: transport, resolver: FixedResolver(["203.0.113.10"]), clock: clock)
        async let a = runtime.request(alias: "publicData", operation: "frame", parameters: ["timestamp": "1000"])
        async let b = runtime.request(alias: "publicData", operation: "frame", parameters: ["timestamp": "1000"])
        let results = try await [a,b]
        XCTAssertEqual(results[0].state, "fresh"); XCTAssertEqual(results[1].lastModified, "Mon, 14 Sep 2026 10:00:00 GMT")
        let count1 = await transport.count(); XCTAssertEqual(count1, 1)
        _ = try await runtime.request(alias: "publicData", operation: "frame", parameters: ["timestamp": "1000"])
        let count2 = await transport.count(); XCTAssertEqual(count2, 1)
        clock.advance(0.2)
        _ = try await runtime.request(alias: "publicData", operation: "frame", parameters: ["timestamp": "2000"])
        let sent = await transport.requests; XCTAssertEqual(sent.count, 2)
        XCTAssertNotEqual(sent[0].url, sent[1].url)
        XCTAssertNil(sent[0].headers["Authorization"]); XCTAssertEqual(sent[0].headers["User-Agent"], "Screenpunk/1 (public data reader)")
        XCTAssertEqual(sent[0].method, "GET"); XCTAssertNil(sent[0].body)
    }
    func testStaleBackoffExpirationAndNoCoverageAreDistinct() async throws {
        let transport = Transport(); let clock = Clock()
        let runtime = try PublicReadRuntime(provisioning: provisioning(), transport: transport, resolver: FixedResolver(["203.0.113.10"]), clock: clock)
        let first = try await runtime.request(alias: "publicData", operation: "timeline", parameters: [:]); XCTAssertEqual(first.state, "fresh")
        clock.advance(2)
        await transport.set(.init(status: 429, body: Data(), headers: ["retry-after": "20"]))
        let stale = try await runtime.request(alias: "publicData", operation: "timeline", parameters: [:]); XCTAssertEqual(stale.state, "stale"); XCTAssertEqual(stale.fetchedAt, first.fetchedAt); XCTAssertEqual(stale.retryAfter, 20)
        _ = try await runtime.request(alias: "publicData", operation: "timeline", parameters: [:]); let count = await transport.count(); XCTAssertEqual(count, 2)
        clock.advance(30)
        let expired = try await runtime.request(alias: "publicData", operation: "timeline", parameters: [:]); XCTAssertEqual(expired.state, "error"); XCTAssertNil(expired.body)
        clock.advance(30)
        await transport.set(.init(status: 404, body: Data()))
        let absent = try await runtime.request(alias: "publicData", operation: "frame", parameters: ["timestamp": "1000"])
        XCTAssertEqual(absent.state, "unavailable"); XCTAssertEqual(absent.code, "no_coverage"); XCTAssertNil(absent.body)
    }
    func testValidationLimitsAndResourceScopeCleanup() throws {
        let png = try raster(); let jpeg = try raster(jpeg: true)
        try PublicRasterValidator.validate(png, mime: "image/png"); try PublicRasterValidator.validate(jpeg, mime: "image/jpeg")
        XCTAssertThrowsError(try PublicRasterValidator.validate(png, mime: "image/jpeg"))
        XCTAssertThrowsError(try PublicRasterValidator.validate(Data("<svg></svg>".utf8), mime: "image/png"))
        XCTAssertThrowsError(try PublicRasterValidator.validate(Data(png.prefix(24)), mime: "image/png"))
        XCTAssertThrowsError(try PublicRasterValidator.validate(Data(repeating: 0, count: 4 * 1024 * 1024 + 1), mime: "image/png"))
        XCTAssertThrowsError(try PublicRasterValidator.validate(raster(width: 4097, height: 1), mime: "image/png"))
        let one = PublicRasterResources(), two = PublicRasterResources()
        let result = PublicReadResult(state: "fresh", body: png, mime: "image/png", status: 200)
        let handle = try one.put(result); XCTAssertEqual(try one.put(result), handle)
        XCTAssertEqual(try one.asset(url: handle).data, png); XCTAssertThrowsError(try two.asset(url: handle))
        one.release(url: handle); XCTAssertNoThrow(try one.asset(url: handle))
        one.release(url: handle); XCTAssertThrowsError(try one.asset(url: handle))
        let replacement = try one.put(result); XCTAssertNotEqual(handle, replacement)
        one.clear(); XCTAssertThrowsError(try one.asset(url: replacement))
    }
    func testCancellationAndSessionRevocation() async throws {
        let transport = Transport(); await transport.set(.init(status: 200, body: Data("{}".utf8), headers: ["content-type": "application/json"]), delay: 10_000_000_000)
        let session = try PublicReadSession(provisioning: provisioning(), transport: transport, resolver: FixedResolver(["203.0.113.10"]))
        let pending = Task { try await session.runtime.request(alias: "publicData", operation: "timeline", parameters: [:]) }
        while await transport.count() == 0 { await Task.yield() }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled request completed") } catch { XCTAssertTrue(error is CancellationError) }
        let handle = try session.resources.put(.init(state: "fresh", body: raster(), mime: "image/png", status: 200))
        session.cancel(); XCTAssertThrowsError(try session.resources.asset(url: handle))
        do { _ = try await session.runtime.request(alias: "publicData", operation: "timeline", parameters: [:]); XCTFail("revoked scope") } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }
    func testConcurrencyBoundAndIndependentDeduplicatedCancellation() async throws {
        let transport = Transport()
        await transport.set(.init(status: 200, body: Data("{}".utf8), headers: ["content-type": "application/json"]), delay: 150_000_000)
        var config = try provisioning()
        config.connections = (0..<5).map { index in
            var c = config.connections[0]; c.alias = "data\(index)"; c.publicHTTP?.origin = "https://data\(index).example.org"; return c
        }
        let runtime = try PublicReadRuntime(provisioning: config, transport: transport, resolver: FixedResolver(["203.0.113.10"]))
        let first = Task { try await runtime.request(alias: "data0", operation: "timeline", parameters: [:]) }
        while await transport.count() < 1 { await Task.yield() }
        let shared = Task { try await runtime.request(alias: "data0", operation: "timeline", parameters: [:]) }
        let others = (1..<4).map { index in Task { try await runtime.request(alias: "data\(index)", operation: "timeline", parameters: [:]) } }
        while await transport.count() < 4 { await Task.yield() }
        let limited = try await runtime.request(alias: "data4", operation: "timeline", parameters: [:])
        XCTAssertEqual(limited.code, "busy")
        first.cancel()
        let result = try await shared.value; XCTAssertEqual(result.state, "fresh")
        for other in others { _ = try await other.value }
        let count = await transport.count(); XCTAssertEqual(count, 4)
        do { _ = try await first.value; XCTFail("cancelled waiter") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testResourceEvictionAndExpiredHandlesCannotBeReused() throws {
        let resources = PublicRasterResources()
        let initial = try resources.put(.init(state: "fresh", body: raster(width: 1), mime: "image/png", status: 200))
        for width in 2...66 {
            _ = try resources.put(.init(state: "fresh", body: raster(width: width), mime: "image/png", status: 200))
        }
        XCTAssertThrowsError(try resources.asset(url: initial))
        let again = try resources.put(.init(state: "fresh", body: raster(width: 1), mime: "image/png", status: 200))
        XCTAssertNotEqual(initial, again)
        resources.clear(); XCTAssertThrowsError(try resources.asset(url: again))
    }

    func testVaultOwnerRevisionAndGenerationScoping() throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore()); var config = try provisioning()
        config.connections[0].publicHTTP!.operations[1] = .init(name: "frame", path: "/photos/{filename}", response: "raster", parameters: ["filename": .init(location: "path", pathSegment: .init(maxLength: 128))])
        try vault.stagePublic([config], owner: "owner-a", generation: "set-a")
        XCTAssertEqual(try vault.publicConfiguration(owner: "owner-a", dashboardId: config.dashboardId, revision: config.revision, generation: "set-a"), config)
        for (owner, id, revision, generation) in [("owner-b",config.dashboardId,config.revision,"set-a"),("owner-a","other",config.revision,"set-a"),("owner-a",config.dashboardId,"new-revision","set-a"),("owner-a",config.dashboardId,config.revision,"set-b")] {
            XCTAssertThrowsError(try vault.publicConfiguration(owner: owner, dashboardId: id, revision: revision, generation: generation))
        }
        try vault.revoke()
        XCTAssertNoThrow(try vault.publicConfiguration(owner: "owner-a", dashboardId: config.dashboardId, revision: config.revision, generation: "set-a"))
        try vault.revokePublic(); XCTAssertThrowsError(try vault.publicConfiguration(owner: "owner-a", dashboardId: config.dashboardId, revision: config.revision, generation: "set-a"))
    }
}
