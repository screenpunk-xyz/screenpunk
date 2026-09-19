import XCTest
import AVFoundation
import CryptoKit
import CoreVideo
import ScreenpunkCore
@testable import ScreenpunkApple

final class CameraTests: XCTestCase {
    func testCarouselWrapsInBothDirections() {
        XCTAssertEqual(CameraGalleryNavigation.next(index: 2, count: 3, direction: 1), 0)
        XCTAssertEqual(CameraGalleryNavigation.next(index: 0, count: 3, direction: -1), 2)
        XCTAssertEqual(CameraGalleryNavigation.next(index: 1, count: 3, direction: 1), 2)
    }
    func testLiveStatusRequiresFreshDecodedFrames() {
        var progress = CameraPlaybackProgress()
        progress.observe(presentationTime: 5, now: 1)
        XCTAssertFalse(progress.isLive(now: 1))
        progress.observe(presentationTime: 5, now: 2)
        XCTAssertFalse(progress.isLive(now: 2))
        progress.observe(presentationTime: 6, now: 3)
        progress.observe(presentationTime: 7, now: 4)
        XCTAssertTrue(progress.isLive(now: 4))
        XCTAssertFalse(progress.isLive(now: 8))
        XCTAssertTrue(progress.timedOut(now: 20, startedAt: 0))
        XCTAssertTrue(CameraPlaybackProgress().timedOut(now: 76, startedAt: 0))
    }
    func testMediaURLCannotEscapeHAOrigin() throws {
        XCTAssertEqual(try HomeAssistantCameraHandshake.mediaURL(path: "/api/hls/abc_123/master_playlist.m3u8", origin: "http://192.0.2.10:8123").host, "192.0.2.10")
        for path in ["https://evil.example/a.m3u8", "//evil.example/a", "/api/hls/../secret", "/api/hls/x/master_playlist.m3u8?token=secret", "/api/hls/%2f/master_playlist.m3u8"] {
            XCTAssertThrowsError(try HomeAssistantCameraHandshake.mediaURL(path: path, origin: "https://ha.example"))
        }
    }
    func testCameraGrantValidation() throws {
        try CameraSource.validateEntities(["camera.deck", "camera.mudroom"])
        for ids in [["camera.*"], ["light.deck"], ["camera.deck", "camera.deck"], ["camera.x/../../secret"]] {
            XCTAssertThrowsError(try CameraSource.validateEntities(ids))
        }
        var config = HomeAssistantProvisioning(dashboardId: "screen", connectionId: "home", provisioningId: "p", revision: "r", origin: "https://ha.example", token: "fixture")
        config.cameraEntities = ["camera.deck"]
        XCTAssertThrowsError(try config.validate())
        config.schemaVersion = 3
        try config.validate()
        let encoded = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(HomeAssistantProvisioning.self, from: encoded).cameraEntities, ["camera.deck"])
    }
    func testUnprovisionedAndWrongSourceDeniedBeforeNetwork() async throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        var config = HomeAssistantProvisioning(schemaVersion: 3, dashboardId: "screen", connectionId: "home", provisioningId: "p", revision: "r", origin: "https://ha.example", token: "fixture")
        config.cameraEntities = ["camera.deck"]
        try vault.provision(config, owner: "owner")
        let runtime = HomeAssistantDeviceRuntime(vault: vault, scope: { .init(owner: "owner", revision: "r", dashboardId: "screen") })
        for source in [CameraSource(entityId: "camera.other"), CameraSource(kind: "direct", entityId: "camera.deck"), CameraSource(connection: "elsewhere", entityId: "camera.deck")] {
            do { _ = try await runtime.resolveCamera(source, revision: "r"); XCTFail("Should deny") }
            catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        }
        do { _ = try await runtime.resolveCamera(.init(entityId: "camera.deck"), revision: "old"); XCTFail("Should deny old revision") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }

#if os(macOS)
    /// Opt-in integration check against the owner's already configured HA connection.
    /// All credentials stay inside the same native provisioning path used by the app.
    @MainActor
    func testLiveCameraPlayback() async throws {
        guard ProcessInfo.processInfo.environment["SCREENPUNK_LIVE_CAMERA_TEST"] == "1" else {
            throw XCTSkip("Live camera check is opt-in")
        }
        var config = try MacHomeAssistantConnection.provisioning(dashboardId: "camera-validation", revision: "camera-validation", provisioningId: UUID().uuidString)
        config.schemaVersion = 3
        let entities = (ProcessInfo.processInfo.environment["SCREENPUNK_TEST_CAMERA_ENTITIES"] ?? "")
            .split(separator: ",").map(String.init)
        guard !entities.isEmpty else { throw XCTSkip("Set SCREENPUNK_TEST_CAMERA_ENTITIES to the test camera IDs") }
        try CameraSource.validateEntities(entities)
        config.cameraEntities = entities
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.provision(config, owner: "camera-validation")
        let runtime = HomeAssistantDeviceRuntime(vault: vault, scope: {
            .init(owner: "camera-validation", revision: "camera-validation", dashboardId: "camera-validation")
        })
        var players: [(entity: String, player: AVPlayer, output: AVPlayerItemVideoOutput)] = []
        defer { players.forEach { $0.player.pause(); $0.player.replaceCurrentItem(with: nil) } }
        for entity in config.cameraEntities! {
            let stream = try await runtime.resolveCamera(.init(entityId: entity), revision: "camera-validation")
            let player = AVPlayer(url: stream.url)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = true
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            player.currentItem?.add(output)
            players.append((entity, player, output))
            player.play()
            let valid = await stream.isAuthorized(); XCTAssertTrue(valid)
        }
        var lateFrames: [String: Set<String>] = [:]
        for second in 0..<75 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            for (entity, player, output) in players {
                guard second >= 45 else { continue }
                if let pixel = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    if let base = CVPixelBufferGetBaseAddress(pixel) {
                        let bytes = Data(bytes: base, count: CVPixelBufferGetDataSize(pixel))
                        lateFrames[entity, default: []].insert(SHA256.hash(data: bytes).description)
                    }
                    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                }
            }
        }
        for (entity, player, _) in players {
            let count = lateFrames[entity]?.count ?? 0
            print("Sustained camera probe: \(entity), uniqueFramesInFinal30Seconds=\(count), itemStatus=\(player.currentItem?.status.rawValue ?? -1)")
            XCTAssertGreaterThan(count, 20, "Video must keep changing beyond startup for \(entity)")
        }
        let stream = try await runtime.resolveCamera(.init(entityId: entities[0]), revision: "camera-validation")
        try vault.revoke()
        let valid = await stream.isAuthorized(); XCTAssertFalse(valid)
    }
#endif
}
