import XCTest
@testable import ScreenpunkCore

final class EventNavigationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func fixture(condition: Bool = false) throws -> DashboardManifest {
        var manifest = try JSONDecoder().decode(DashboardManifest.self, from: RepoFixtures.data("schemas/fixtures/valid/minimal.json"))
        manifest.pages = [DashboardPage(id: "home", name: "Home", path: "index.html"), DashboardPage(id: "door", name: "Front door", path: "index.html"), DashboardPage(id: "other", name: "Other", path: "index.html")]
        manifest.defaultPageId = "home"
        manifest.connections = [ManifestConnection(alias: "events", required: false, operations: [ManifestOperation(name: "changes", kind: "ws"), ManifestOperation(name: "read", kind: "http")])]
        manifest.eventRules = [ManifestEventRule(id: "doorbell", name: "Doorbell", source: EventSource(mode: .live, alias: "events", operation: "changes"), condition: condition ? EventCondition(field: ["active"], equals: .bool(true)) : nil, defaults: EventRuleDefaults(pageId: "door", returnBehavior: condition ? .conditionClear : .timeout), userConfigurable: true, allowedPageIds: ["other"], allowedReturnBehaviors: [.stay, .timeout], allowTimeoutOverride: true, payload: EventPayloadFields(pageId: ["page"], returnBehavior: ["behavior"], timeoutSeconds: ["seconds"], eventId: ["id"], occurredAt: ["time"]))]
        return manifest
    }
    func testDefaultAndStartingPagesAndLegacyManifest() throws {
        var manifest = try fixture()
        XCTAssertEqual(try EventNavigationEngine(manifest: manifest).pageId, "home")
        XCTAssertEqual(try EventNavigationEngine(manifest: manifest, startingPageId: "other").pageId, "other")
        XCTAssertThrowsError(try EventNavigationEngine(manifest: manifest, startingPageId: "outside"))
        manifest.pages = nil; manifest.defaultPageId = nil; manifest.eventRules = nil
        XCTAssertEqual(try EventNavigationEngine(manifest: manifest).pageId, "default")
    }
    func testTimeoutOverrideAndRootPreviousPageAcrossReplacement() throws {
        var engine = try EventNavigationEngine(manifest: fixture())
        XCTAssertTrue(engine.receive(ruleId: "doorbell", payload: [:], now: now))
        let old = engine.generation
        XCTAssertTrue(engine.receive(ruleId: "doorbell", payload: ["page": "other", "seconds": 60], now: now.addingTimeInterval(5)))
        XCTAssertFalse(engine.advance(now: now.addingTimeInterval(90), generation: old))
        XCTAssertEqual(engine.pageId, "other")
        XCTAssertTrue(engine.advance(now: now.addingTimeInterval(65), generation: engine.generation))
        XCTAssertEqual(engine.pageId, "home")
    }
    func testManualNavigationCancelsEvenWhenSamePage() throws {
        var engine = try EventNavigationEngine(manifest: fixture())
        engine.receive(ruleId: "doorbell", payload: [:], now: now)
        engine.manualNavigate(pageId: "door")
        XCTAssertNil(engine.returnAt)
        XCTAssertFalse(engine.advance(now: now.addingTimeInterval(100)))
        XCTAssertEqual(engine.pageId, "door")
    }
    func testInvalidPayloadCannotAddPageBehaviorOrUnboundedDuration() throws {
        var engine = try EventNavigationEngine(manifest: fixture())
        engine.receive(ruleId: "doorbell", payload: ["page": "https://evil.test", "behavior": "conditionClear", "seconds": 999999], now: now)
        XCTAssertEqual(engine.pageId, "door")
        XCTAssertEqual(engine.returnAt, now.addingTimeInterval(30))
        engine.receive(ruleId: "doorbell", payload: ["seconds": true], now: now)
        XCTAssertEqual(engine.returnAt, now.addingTimeInterval(30))
    }
    func testDedupAndPriorityDoNotInterruptCurrentEvent() throws {
        var manifest = try fixture()
        var second = manifest.eventRules![0]; second.id = "lower"; second.priority = -1; second.defaults.pageId = "other"
        manifest.eventRules!.append(second)
        var engine = try EventNavigationEngine(manifest: manifest)
        engine.receive(ruleId: "doorbell", payload: ["id": "one"], now: now)
        let generation = engine.generation
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: ["id": "one", "page": "other"], now: now))
        XCTAssertFalse(engine.receive(ruleId: "lower", payload: [:], now: now))
        XCTAssertEqual(engine.generation, generation)
        XCTAssertEqual(engine.pageId, "door")
    }
    func testConditionsTransitionClearAndReconnectBaseline() throws {
        var engine = try EventNavigationEngine(manifest: fixture(condition: true))
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: ["active": true], now: now, isBaseline: true))
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: ["active": true], now: now))
        engine.receive(ruleId: "doorbell", payload: ["active": false], now: now)
        XCTAssertTrue(engine.receive(ruleId: "doorbell", payload: ["active": true], now: now))
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: [:], now: now), "missing data is not a clear")
        XCTAssertEqual(engine.pageId, "door")
        XCTAssertTrue(engine.receive(ruleId: "doorbell", payload: ["active": false], now: now, isBaseline: true))
        XCTAssertEqual(engine.pageId, "home")
    }
    func testCorrelatedClearCannotClearAnotherLifecycle() throws {
        var manifest = try fixture(condition: true)
        manifest.eventRules![0].payload!.correlationId = ["correlation"]
        var engine = try EventNavigationEngine(manifest: manifest)
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: ["active": true], now: now))
        engine.receive(ruleId: "doorbell", payload: ["active": true, "correlation": "a"], now: now)
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: ["active": false, "correlation": "b"], now: now))
        XCTAssertEqual(engine.pageId, "door")
        XCTAssertTrue(engine.receive(ruleId: "doorbell", payload: ["active": false, "correlation": "a"], now: now))
    }
    func testSnapshotTransientNeverReplaysAndStayHasNoTimer() throws {
        var engine = try EventNavigationEngine(manifest: fixture())
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: [:], now: now, isBaseline: true))
        engine.receive(ruleId: "doorbell", payload: ["behavior": "stay"], now: now)
        XCTAssertNil(engine.returnAt)
        XCTAssertFalse(engine.advance(now: now.addingTimeInterval(1000)))
    }
    func testAuthorCapabilityBoundsAndPackageReferences() throws {
        var manifest = try fixture()
        var custom = manifest.eventRules![0].defaults
        custom.timeoutSeconds = 60
        XCTAssertNoThrow(try EventNavigationEngine(manifest: manifest, overrides: ["doorbell": custom]))
        manifest.eventRules![0].allowTimeoutOverride = false
        XCTAssertThrowsError(try EventNavigationEngine(manifest: manifest, overrides: ["doorbell": custom]))
        manifest.eventRules![0].source.operation = "writeWhatever"
        XCTAssertThrowsError(try PackageValidator.validate(manifest))
        manifest = try fixture(); manifest.pages![0].path = "../outside.html"
        XCTAssertThrowsError(try PackageValidator.validate(manifest))
        manifest = try fixture(); manifest.eventRules![0].defaults.returnBehavior = .conditionClear
        XCTAssertThrowsError(try PackageValidator.validate(manifest))
    }
    func testReplayedClearAndOversizedIDsCannotInterruptNewCondition() throws {
        var engine = try EventNavigationEngine(manifest: fixture(condition: true))
        engine.receive(ruleId: "doorbell", payload: ["active": true, "id": "a"], now: now)
        engine.receive(ruleId: "doorbell", payload: ["active": false, "id": "b"], now: now)
        engine.receive(ruleId: "doorbell", payload: ["active": true, "id": "c"], now: now)
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: ["active": false, "id": "b"], now: now))
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: ["active": false, "id": String(repeating: "x", count: 257)], now: now))
        XCTAssertEqual(engine.pageId, "door")
    }
    func testTransientReplayRequiresFreshSourceTimestamp() throws {
        var engine = try EventNavigationEngine(manifest: fixture())
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: ["time": 999], now: now, notBefore: now))
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: [:], now: now, notBefore: now))
        XCTAssertFalse(engine.receive(ruleId: "doorbell", payload: ["time": 2000], now: now, notBefore: now))
        XCTAssertTrue(engine.receive(ruleId: "doorbell", payload: ["time": 1000], now: now, notBefore: now))
    }
    func testPollNeedsConditionAndSafeInterval() throws {
        var manifest = try fixture(condition: true)
        manifest.eventRules![0].source = EventSource(mode: .poll, alias: "events", operation: "read", pollIntervalSeconds: 15)
        XCTAssertNoThrow(try PackageValidator.validate(manifest))
        manifest.eventRules![0].source.pollIntervalSeconds = 1
        XCTAssertThrowsError(try PackageValidator.validate(manifest))
    }
}
