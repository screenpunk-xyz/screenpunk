import XCTest
@testable import ScreenpunkCore

final class IsolationTests: XCTestCase {
    func testAllowsLocalPackageAsset() {
        let request = IsolationRequest(
            kind: .script,
            url: "screenpunk://package/app.js"
        )
        XCTAssertEqual(IsolationEvaluator.decide(request), .allowLocalAsset)
        XCTAssertTrue(IsolationEvaluator.isLocalPackageURL("screenpunk://package/styles/theme.css"))
    }

    func testDeniesDirectEgress() {
        XCTAssertEqual(
            IsolationEvaluator.decide(IsolationRequest(kind: .fetch, url: "https://evil.example/api")),
            .denyDirectEgress
        )
        XCTAssertEqual(
            IsolationEvaluator.decide(IsolationRequest(kind: .xhr, url: "http://127.0.0.1/secret")),
            .denyDirectEgress
        )
        XCTAssertEqual(
            IsolationEvaluator.decide(IsolationRequest(kind: .websocket, url: "wss://evil.example/ws")),
            .denyDirectEgress
        )
    }

    func testDeniesRemoteCodeNavigationFramesAndTraversal() {
        XCTAssertEqual(
            IsolationEvaluator.decide(IsolationRequest(kind: .script, url: "https://cdn.example/x.js")),
            .denyRemoteCode
        )
        XCTAssertEqual(
            IsolationEvaluator.decide(IsolationRequest(kind: .navigation, url: "https://phish.example/")),
            .denyNavigation
        )
        XCTAssertEqual(
            IsolationEvaluator.decide(IsolationRequest(kind: .iframe, url: "screenpunk://package/ok.html")),
            .denyFrame
        )
        XCTAssertEqual(
            IsolationEvaluator.decide(IsolationRequest(kind: .traversal, url: "screenpunk://package/../Secrets")),
            .denyTraversal
        )
        XCTAssertEqual(
            IsolationEvaluator.decide(IsolationRequest(kind: .filePath, url: "file:///etc/passwd")),
            .denyFilePath
        )
        XCTAssertEqual(
            IsolationEvaluator.decide(
                IsolationRequest(
                    kind: .bridgeSpoof,
                    url: "screenpunk://package/index.html",
                    isMainFrame: false
                )
            ),
            .denyBridgeSpoof
        )
    }

    func testCSPAndProcessFailure() {
        XCTAssertTrue(IsolationPolicy.contentSecurityPolicy.contains("connect-src 'none'"))
        XCTAssertTrue(IsolationPolicy.nativeNetworkingOnly)
        XCTAssertEqual(IsolationPolicy.customScheme, "screenpunk")
        XCTAssertEqual(ContentProcessFailure.simulateTermination(), "content-process-terminated")
        XCTAssertTrue(ContentProcessFailure.unlinkGestureRemainsAvailable)
        XCTAssertTrue(IsolationPolicy.unlinkGestureSurvivesContentProcessDeath)
    }
}
