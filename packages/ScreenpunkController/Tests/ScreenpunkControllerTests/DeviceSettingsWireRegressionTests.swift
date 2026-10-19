import XCTest
@testable import ScreenpunkController
import ScreenpunkCore
final class DeviceSettingsWireRegressionTests: XCTestCase {
    func testDefaultNativeDeviceSettingsResponseIsAccepted() throws {
        let action = WorkbenchDeviceActionResult(kind: "settings", settings: DeviceSettingsSnapshot())
        let response = WorkbenchWireResponse(requestId: "fixture", deviceAction: action)
        let bytes = try WorkbenchSocket.encode(response)
        XCTAssertThrowsError(try WorkbenchWireJSON.object(bytes))
        XCTAssertNoThrow(try WorkbenchWireJSON.object(bytes, allowDeviceSettings: true))
        for method in [WorkbenchDeviceControlMethod.settingsGet, .settingsSet] {
            let decoder = JSONDecoder()
            decoder.userInfo[WorkbenchRPCResult.responseMethodKey] = method.rawValue
            let decoded = try decoder.decode(WorkbenchWireResponse.self, from: bytes)
            guard case .deviceAction(let value) = decoded.result else { return XCTFail("settings reply") }
            XCTAssertEqual(value.settings?.value.brightness.fixedLevel, 0.5)
            XCTAssertNoThrow(try value.validate(for: method))
        }
    }
    func testBrightnessScheduleAndSetRequestDecodeWithoutChangingIntegerFields() throws {
        var settings = DeviceSettings()
        settings.brightness = .init(mode: .schedule, fixedLevel: 0.35,
            schedule: [.init(minuteOfDay: 60, level: 0.125)])
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        let bytes = try JSONSerialization.data(withJSONObject: ["params": [
            "schemaVersion": 1, "deviceId": "fixture-device", "expectedRevision": "fixture-revision", "value": value]])
        let wire = try WorkbenchWireJSON.object(bytes, allowDeviceSettings: true)
        let request = try WorkbenchDeviceControlRequest.parse(method: .settingsSet, params: wire["params"] as! [String: Any])
        guard case .settingsSet(_, _, let decoded) = request else { return XCTFail("settings set request") }
        XCTAssertEqual(decoded, settings)
        XCTAssertNoThrow(try decoded.validate())
    }
    func testRelaxationIsLimitedToFiniteBoundedBrightnessAtKnownPaths() {
        let rejected = [
            #"{"params":{"generation":0.5}}"#,
            #"{"result":{"settings":{"value":{"brightness":{"fixedLevel":1.1}}}}}"#,
            #"{"params":{"value":{"brightness":{"fixedLevel":-0.1}}}}"#,
            #"{"params":{"value":{"brightness":{"fixedLevel":1e999}}}}"#,
            #"{"params":{"value":{"brightness":{"fixedLevel":.5}}}}"#,
            #"{"params":{"value":{"brightness":{"fixedLevel":01}}}}"#,
            #"{"params":{"value":{"brightness":{"fixedLevel":0.}}}}"#,
            #"{"params":{"value":{"brightness":{"fixedLevel":1e}}}}"#,
            #"{"params":{"value":{"brightness":{"fixedLevel":0.5,"fixed\u004cevel":0.4}}}}"#,
            #"{"params":{"value":{"brightness":{"schedule":[{"minuteOfDay":60.5,"level":0.2}]}}}}"#,
            #"{"unrelated":{"brightness":{"fixedLevel":0.5}}}"#
        ]
        for json in rejected { XCTAssertThrowsError(try WorkbenchWireJSON.object(Data(json.utf8), allowDeviceSettings: true), json) }
        XCTAssertNoThrow(try WorkbenchWireJSON.object(Data(#"{"params":{"value":{"brightness":{"fixedLevel":5e-1}}}}"#.utf8), allowDeviceSettings: true))
    }
}
