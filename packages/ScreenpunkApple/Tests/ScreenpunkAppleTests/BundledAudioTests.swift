import XCTest
import WebKit
@testable import ScreenpunkApple
import ScreenpunkCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

final class BundledAudioTests: XCTestCase {
    func testAudioMIMETypes() {
        for (path, mime) in ["tone.WAV": "audio/wav", "tone.mp3": "audio/mpeg", "tone.m4a": "audio/mp4", "tone.aac": "audio/aac", "tone.aiff": "audio/aiff", "tone.caf": "audio/x-caf"] {
            XCTAssertEqual(PackageAssetStore.mime(for: path), mime)
        }
    }

    func testMediaByteRanges() {
        let asset = PackageAsset(path: "tone.wav", data: Data(0..<100), mime: "audio/wav")
        for (range, expected) in [("bytes=0-1", 0..<2), ("bytes=90-", 90..<100), ("bytes=-5", 95..<100), ("bytes=95-200", 95..<100)] {
            let response = PackageMediaResponse(asset: asset, range: range)
            XCTAssertEqual(response.status, 206)
            XCTAssertEqual(response.data, asset.data.subdata(in: expected))
            XCTAssertEqual(response.headers["Content-Length"], String(expected.count))
            XCTAssertEqual(response.headers["Content-Range"], "bytes \(expected.lowerBound)-\(expected.upperBound - 1)/100")
        }
        for range in ["bytes=100-", "bytes=2-1", "bytes=-0", "bytes=0-1,4-5", "bytes=bad", "bytes=0-999999999999999999999999"] {
            XCTAssertEqual(PackageMediaResponse(asset: asset, range: range).status, 416, range)
        }
        XCTAssertEqual(PackageMediaResponse(asset: asset, range: nil).data, asset.data)
        XCTAssertEqual(PackageMediaResponse(asset: asset, range: nil, method: "HEAD").headers["Content-Length"], "100")
        XCTAssertTrue(PackageMediaResponse(asset: asset, range: nil, method: "HEAD").data.isEmpty)
        let empty = PackageAsset(path: "empty.wav", data: Data(), mime: "audio/wav")
        XCTAssertEqual(PackageMediaResponse(asset: empty, range: "bytes=0-").status, 416)
    }

    /// Runs the real WKWebView scheme loader and decoder, not a browser mock.
    /// Timeline completion is not proof that a person heard the speakers.
    @MainActor
    func testNativeWebKitBundledWAVPlaybackAndIsolation() async throws {
#if os(macOS)
        _ = NSApplication.shared
#endif
        let store = PackageAssetStore(assets: [
            "index.html": PackageAsset(path: "index.html", data: Data("<html><body>Audio test<script src=probe.js></script></body></html>".utf8), mime: "text/html"),
            "probe.js": PackageAsset(path: "probe.js", data: Data("window.autoResult = 'pending'; window.autoTone = new Audio('tone.wav'); autoTone.play().then(() => autoResult = 'playing').catch(e => autoResult = e.name);".utf8), mime: "text/javascript"),
            "tone.wav": PackageAsset(path: "tone.wav", data: Self.tone(), mime: "audio/wav")
        ])
        let config = WKWebViewConfiguration()
        BundledAudio.configure(config)
        XCTAssertEqual(config.mediaTypesRequiringUserActionForPlayback, .all)
        config.setURLSchemeHandler(PackageSchemeHandler(store: store), forURLScheme: "screenpunk")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), configuration: config)
#if os(macOS)
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        defer { window.orderOut(nil) }
#elseif os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = web
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
#endif
        let navigation = NavigationWaiter()
        web.navigationDelegate = navigation
        web.load(URLRequest(url: URL(string: "screenpunk://package/index.html")!))
        await fulfillment(of: [navigation.loaded], timeout: 10)
        var autoResult = "pending"
        for _ in 0..<50 {
            autoResult = try await web.evaluateJavaScript("window.autoResult") as? String ?? "pending"
            if autoResult != "pending" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(autoResult, "NotAllowedError", "The shell must retain gesture protection")
        // evaluateJavaScript provides WebKit user activation, unlike an autoplay script.
        _ = try await web.evaluateJavaScript("""
        window.audioEvents = [];
        window.addEventListener('screenpunk:audio-error', e => audioEvents.push(e.detail.code));
        window.tone = new Audio('tone.wav');
        window.playResult = 'pending';
        tone.onended = () => window.playResult = 'ended';
        tone.play().then(() => { if (playResult !== 'ended') playResult = 'playing'; }).catch(e => playResult = e.name);
        true;
        """)
        var result = "pending"
        for _ in 0..<100 {
            result = try await web.evaluateJavaScript("window.playResult") as? String ?? "unknown"
            if result == "ended" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(result, "ended", "Native WAV playback failed: \(result)")
        let currentTime = try await web.evaluateJavaScript("tone.currentTime") as? Double ?? 0
        XCTAssertGreaterThan(currentTime, 0.1)
        _ = try await web.evaluateJavaScript("""
        window.missing = new Audio('missing.wav');
        missing.play().catch(() => {});
        true;
        """)
        var events: [String] = []
        for _ in 0..<50 {
            events = try await web.evaluateJavaScript("window.audioEvents") as? [String] ?? []
            if events.contains("AUDIO_UNSUPPORTED") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(events.contains("AUDIO_UNSUPPORTED"), "A screen's catch must not swallow host diagnostics: \(events)")
        _ = try await web.evaluateJavaScript("""
        window.audioEvents = [];
        window.blocked = new Audio('https://example.invalid/tone.wav');
        blocked.play().catch(() => {});
        true;
        """)
        for _ in 0..<50 {
            events = try await web.evaluateJavaScript("window.audioEvents") as? [String] ?? []
            if events.contains("AUDIO_POLICY_BLOCKED") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(events.contains("AUDIO_POLICY_BLOCKED"), "Remote audio must be blocked: \(events)")
    }

    // Original, generated 440 Hz PCM fixture; contains no third-party audio.
    static func tone() -> Data {
        let count = 8000
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(value & 65535)); u16(UInt16(value >> 16)) }
        ascii("RIFF"); u32(UInt32(36 + count * 2)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        ascii("data"); u32(UInt32(count * 2))
        for i in 0..<count {
            let sample = Int16(sin(Double(i) * 2 * .pi * 440 / 16000) * 2000)
            u16(UInt16(bitPattern: sample))
        }
        return data
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    let loaded = XCTestExpectation(description: "Package navigation")
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}
