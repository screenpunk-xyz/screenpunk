import XCTest
@testable import ScreenpunkCore

final class HomeAssistantServiceTests: XCTestCase {
    func configuration() -> HomeAssistantProvisioning {
        var config = HomeAssistantProvisioning(schemaVersion: 2, dashboardId: "screen", connectionId: "home",
            provisioningId: "provision", revision: "revision", origin: "https://ha.example", token: "fixture")
        config.serviceCalls = [.init(domain: "light", service: "turn_on", entityIds: ["light.a", "light.b"]),
                              .init(domain: "custom_integration", service: "new_action", allowUntargeted: true)]
        return config
    }
    func call(_ value: [String: Any], config: HomeAssistantProvisioning? = nil) throws -> (path: String, body: Data?) {
        try (config ?? configuration()).authorize(operation: "callService", parameters: [
            "call": String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)])
    }
    func testStructuredDataAndNewServicesNeedNoNativeActionList() throws {
        let result = try call(["domain": "light", "service": "turn_on", "target": ["entity_id": ["light.a", "light.b"]],
            "serviceData": ["rgb_color": [1, 2, 3], "transition": 2.5, "future_option": ["enabled": true, "values": [NSNull(), "x"]]]])
        XCTAssertEqual(result.path, "/api/services/light/turn_on")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body!) as? [String: Any])
        XCTAssertEqual(body["rgb_color"] as? [Int], [1, 2, 3])
        XCTAssertEqual(body["transition"] as? Double, 2.5)
        XCTAssertEqual(body["entity_id"] as? [String], ["light.a", "light.b"])
        XCTAssertEqual(try call(["domain": "custom_integration", "service": "new_action", "serviceData": ["message": "hello"]]).path,
                       "/api/services/custom_integration/new_action")
    }
    func testDestinationAndTargetEscapesAreRejected() throws {
        let valid: [String: Any] = ["domain": "light", "service": "turn_on", "target": ["entity_id": "light.a"], "serviceData": [:]]
        for change: [String: Any] in [["domain": "../api"], ["domain": "light\n"], ["target": ["entity_id": "light.a\n"]], ["service": "turn_off"], ["service": "turn_on?x=y"],
            ["target": ["entity_id": "all"]], ["target": ["entity_id": "light.c"]], ["target": ["entity_id": []]],
            ["target": ["entity_id": "light.a,light.b"]], ["target": ["area_id": "basement"]],
            ["target": ["entity_id": "light.a", "device_id": "other"]], ["origin": "https://evil.example"],
            ["serviceData": ["entity_id": "light.c"]], ["serviceData": ["target": ["entity_id": "all"]]],
            ["serviceData": ["label_id": "all"]]] {
            XCTAssertThrowsError(try call(valid.merging(change, uniquingKeysWith: { _, new in new })))
        }
        var untargeted = valid; untargeted.removeValue(forKey: "target")
        XCTAssertThrowsError(try call(untargeted))
        var legacy = configuration(); legacy.schemaVersion = 1; legacy.serviceCalls = nil
        XCTAssertThrowsError(try call(valid, config: legacy))
        XCTAssertThrowsError(try configuration().authorize(operation: "callService", parameters: ["call": "{}", "Authorization": "x"]))
    }
    func testPayloadBoundsAndGrantValidation() throws {
        XCTAssertThrowsError(try configuration().authorize(operation: "callService", parameters: ["call": "{bad-json"])) {
            XCTAssertEqual($0 as? ConnectionFailure, .validationFailed)
        }
        XCTAssertThrowsError(try configuration().authorize(operation: "callService", parameters: ["call": String(repeating: "x", count: 32769)])) {
            XCTAssertEqual($0 as? ConnectionFailure, .sizeLimit)
        }
        var payload: Any = "leaf"
        for _ in 0..<14 { payload = ["nested": payload] }
        for data: [String: Any] in [["large": String(repeating: "a", count: 8193)], ["deep": payload],
                                    ["many": Array(repeating: 1, count: 2049)],
                                    ["large": Array(repeating: String(repeating: "x", count: 8000), count: 5)]] {
            XCTAssertThrowsError(try call(["domain": "custom_integration", "service": "new_action", "serviceData": data]))
        }
        XCTAssertThrowsError(try HomeAssistantServiceGrant.validate([.init(domain: "light", service: "turn_on")]))
        XCTAssertThrowsError(try HomeAssistantServiceGrant.validate([.init(domain: "light", service: "turn_on", entityIds: ["*"])]))
        var config = configuration(); config.serviceCalls! += config.serviceCalls!
        XCTAssertThrowsError(try config.validate())
    }
    func testLegacyCompatibilityAndScopedAliasEnforcement() throws {
        var config = configuration(); config.schemaVersion = 1; config.serviceCalls = nil
        XCTAssertNoThrow(try config.authorize(operation: "mediaOn", parameters: ["entity_id": "media_player.a"]))
        XCTAssertNoThrow(try config.authorize(operation: "lightOn", parameters: ["entity_id": "light.a", "rgb_color": "[255,0,128]"]))
        XCTAssertThrowsError(try config.authorize(operation: "lightOn", parameters: ["entity_id": "light.a", "rgb_color": "[256,0,0]"]))
        XCTAssertNoThrow(try configuration().authorize(operation: "lightOn", parameters: ["entity_id": "light.a"]))
        XCTAssertThrowsError(try configuration().authorize(operation: "lightOn", parameters: ["entity_id": "light.c"]))
        XCTAssertThrowsError(try configuration().authorize(operation: "lightOff", parameters: ["entity_id": "light.a"]))
        let old = try JSONDecoder().decode(HomeAssistantProvisioning.self, from: JSONEncoder().encode(config))
        XCTAssertNil(old.serviceCalls)
        XCTAssertEqual(old.schemaVersion, 1)
    }
}
