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

    /// Same fixture as sdk/test/isolation.test.ts. Both evaluators must agree on every case.
    func testSharedAttackFixtureMatchesTypeScript() throws {
        let fixture = try RepoFixtures.decode(IsolationFixture.self, from: "tests/feasibility/isolation/attacks.json")
        XCTAssertEqual(fixture.scheme, IsolationPolicy.customScheme)
        XCTAssertTrue(IsolationPolicy.contentSecurityPolicy.contains(fixture.cspMustInclude))
        XCTAssertEqual(fixture.nativeNetworkingOnly, IsolationPolicy.nativeNetworkingOnly)
        XCTAssertEqual(fixture.contentProcessFailure, ContentProcessFailure.simulateTermination())
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 40)
        XCTAssertEqual(Set(fixture.cases.map(\.id)).count, fixture.cases.count, "case ids must be unique")

        var decisions = Set<IsolationDecision>()
        var kinds = Set<IsolationRequestKind>()
        for item in fixture.cases {
            guard let kind = IsolationRequestKind(rawValue: item.kind) else {
                XCTFail("\(item.id): unknown kind \(item.kind)")
                continue
            }
            guard let expected = IsolationDecision(rawValue: item.expect) else {
                XCTFail("\(item.id): unknown decision \(item.expect)")
                continue
            }
            let decision = IsolationEvaluator.decide(
                IsolationRequest(kind: kind, url: item.url, isMainFrame: item.isMainFrame)
            )
            XCTAssertEqual(decision, expected, item.id)
            decisions.insert(decision)
            kinds.insert(kind)
        }
        XCTAssertEqual(kinds, Set(IsolationRequestKind.allCases), "every request kind must have a fixture")
        for required: IsolationDecision in [
            .allowLocalAsset, .denyDirectEgress, .denyRemoteCode, .denyNavigation,
            .denyFrame, .denyTraversal, .denyBridgeSpoof, .denyFilePath
        ] {
            XCTAssertTrue(decisions.contains(required), "fixture must exercise \(required.rawValue)")
        }
    }

    func testCSPDeniesEveryEgressDirective() {
        let directives = IsolationPolicy.contentSecurityPolicy
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for name in ["default-src", "connect-src", "frame-src", "child-src", "worker-src", "object-src", "base-uri", "form-action", "media-src"] {
            XCTAssertTrue(directives.contains("\(name) 'none'"), "\(name) must be 'none'")
        }
        for name in ["script-src", "style-src", "img-src", "font-src"] {
            XCTAssertTrue(directives.contains("\(name) 'self'"), "\(name) must be 'self' only")
        }
        XCTAssertFalse(IsolationPolicy.contentSecurityPolicy.contains("unsafe-inline"))
        XCTAssertFalse(IsolationPolicy.contentSecurityPolicy.contains("unsafe-eval"))
        XCTAssertFalse(IsolationPolicy.contentSecurityPolicy.contains("http"))

        let rules = try? JSONSerialization.jsonObject(with: Data(IsolationPolicy.contentRuleListJSON.utf8)) as? [[String: Any]]
        let filters = (rules ?? []).compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        XCTAssertEqual(Set(filters), ["^https?://", "^wss?://", "^file://"])
        for rule in rules ?? [] {
            XCTAssertEqual((rule["action"] as? [String: Any])?["type"] as? String, "block")
        }
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

struct IsolationFixture: Decodable {
    struct Case: Decodable {
        var id: String
        var kind: String
        var url: String
        var isMainFrame: Bool
        var expect: String
    }

    var scheme: String
    var cspMustInclude: String
    var nativeNetworkingOnly: Bool
    var contentProcessFailure: String
    var cases: [Case]
}
