import Foundation
import XCTest
import UIKit
@testable import Screenpunk

@MainActor
final class CloudDeviceMetadataSnapshotTests: XCTestCase {
    private func snapshot(identifier: String? = "iPhone18,1", model: String? = "iPhone 17 Pro", name: String? = " My screen ",
                          screen: CGSize? = CGSize(width: 852.5, height: 393.25), viewport: CGSize? = CGSize(width: 600.5, height: 400.25),
                          orientation: CloudDeviceMetadataSnapshot.InterfaceOrientation? = .landscapeLeft,
                          provenance: CloudDeviceMetadataSnapshot.Provenance = .nativeDevice) throws -> CloudDeviceMetadataSnapshot {
        try CloudDeviceMetadataCollector.snapshot(.init(modelIdentifier: identifier, mappedModelName: model, deviceName: name,
            screenSize: screen, contentSize: viewport, orientation: orientation, capturedAt: Date(timeIntervalSince1970: 0), provenance: provenance))
    }
    private func object(_ value: CloudDeviceMetadataSnapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
    }
    private func decode(_ value: [String: Any]) throws -> CloudDeviceMetadataSnapshot {
        try .decode(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    func testKnownPhoneTabletNamesAreExplicitInputsAndUnknownRawSurvives() throws {
        let phone = try snapshot(); XCTAssertEqual(phone.modelIdentifier, "iPhone18,1"); XCTAssertEqual(phone.modelName, "iPhone 17 Pro")
        let tablet = try snapshot(identifier: "iPad17,4", model: "iPad Pro 13-inch (M5)")
        XCTAssertEqual(tablet.modelName, "iPad Pro 13-inch (M5)")
        let unknown = try snapshot(identifier: "iPhone999,77", model: nil)
        XCTAssertEqual(unknown.modelIdentifier, "iPhone999,77"); XCTAssertNil(unknown.modelName)
        XCTAssertEqual(try CloudDeviceMetadataSnapshot.decode(unknown.encoded()), unknown)
    }
    func testMissingFieldsEmitCompleteNullsWithoutDefaultsOrIPhoneFallback() throws {
        let missing = try snapshot(identifier: nil, model: nil, name: nil, screen: nil, viewport: nil, orientation: nil)
        let encoded = try object(missing)
        for key in ["modelIdentifier", "modelName", "deviceName", "screen", "viewport", "interfaceOrientation"] {
            XCTAssertTrue(encoded[key] is NSNull, key)
        }
        XCTAssertEqual(missing.observedAt, "1970-01-01T00:00:00.000Z")
        var absent = encoded
        for key in ["modelIdentifier", "modelName", "deviceName", "screen", "viewport", "interfaceOrientation"] { absent.removeValue(forKey: key) }
        XCTAssertEqual(try decode(absent), missing)
    }
    func testFullScreenPointsAndFractionalWindowViewportAreSeparate() throws {
        let value = try snapshot()
        XCTAssertEqual(value.screen?.width, 393.25); XCTAssertEqual(value.screen?.height, 852.5)
        XCTAssertEqual(value.viewport?.width, 600.5); XCTAssertEqual(value.viewport?.height, 400.25)
        XCTAssertEqual(value.screen?.basis, .screen); XCTAssertEqual(value.viewport?.basis, .viewport)
        XCTAssertEqual(value.screen?.unit, "points"); XCTAssertEqual(value.interfaceOrientation, .landscapeLeft)
        let encoded = try object(value)
        XCTAssertNil(encoded["aspect"]); XCTAssertNil(encoded["deviceId"]); XCTAssertNil(encoded["accountId"])
        XCTAssertEqual(try CloudDeviceMetadataSnapshot.decode(value.encoded()), value)
    }
    func testZeroUnattachedGeometryIsNotReportedAndOrientationIsIndependent() throws {
        let value = try snapshot(screen: CGSize(width: 0, height: 0), viewport: CGSize(width: 0, height: 100), orientation: nil)
        XCTAssertNil(value.screen); XCTAssertNil(value.viewport); XCTAssertNil(value.interfaceOrientation)
        for orientation in [CloudDeviceMetadataSnapshot.InterfaceOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight] {
            let value = try snapshot(orientation: orientation)
            XCTAssertEqual(try CloudDeviceMetadataSnapshot.decode(value.encoded()).interfaceOrientation, orientation)
            XCTAssertEqual(value.screen?.width, 393.25) // Orientation does not mutate the normalized screen.
        }
    }
    func testNonfiniteNegativeAndOversizedAxesRejectWithoutDefaulting() throws {
        for size in [CGSize(width: -1, height: 100), CGSize(width: CGFloat.infinity, height: 0), CGSize(width: CGFloat.nan, height: 100),
                     CGSize(width: 16384.5, height: 100), CGSize(width: 100, height: -1)] {
            XCTAssertThrowsError(try snapshot(screen: size))
            XCTAssertThrowsError(try snapshot(viewport: size))
        }
        XCTAssertNoThrow(try snapshot(screen: CGSize(width: 16384, height: 1)))
    }
    func testObservedNamesAreSanitizedButRawIdentifierNeverGuessed() throws {
        let value = try snapshot(identifier: "Unknown123,4", model: nil, name: "  My\nScreen\u{0001}  ")
        XCTAssertEqual(value.deviceName, "MyScreen"); XCTAssertEqual(value.modelIdentifier, "Unknown123,4")
        XCTAssertNil(try snapshot(name: " \n ").deviceName)
        XCTAssertThrowsError(try snapshot(identifier: "")); XCTAssertThrowsError(try snapshot(identifier: "bad\nidentifier"))
        XCTAssertThrowsError(try snapshot(identifier: String(repeating: "x", count: 129)))
        XCTAssertThrowsError(try snapshot(model: String(repeating: "x", count: 129)))
    }
    func testSimulatorIsExplicitProvenanceNotPhysicalVerification() throws {
        let value = try snapshot(identifier: "iPad17,4", model: nil, provenance: .simulator)
        XCTAssertEqual(value.provenance, .simulator); XCTAssertNil(value.modelName)
        XCTAssertEqual(try object(value)["provenance"] as? String, "simulator")
        var invalid = try object(value); invalid["provenance"] = "verified"
        XCTAssertThrowsError(try decode(invalid))
    }
    func testClosedVersionedKeysUnitsAndMeasurementRelationships() throws {
        let original = try object(snapshot())
        for mutation in ["extra", "version", "unit", "basis", "nested-extra", "screen-axis", "orientation"] {
            var value = original
            switch mutation {
            case "extra": value["credential"] = "not-allowed"
            case "version": value["schemaVersion"] = 2
            case "orientation": value["interfaceOrientation"] = "faceUp"
            default:
                var screen = try XCTUnwrap(value["screen"] as? [String: Any])
                if mutation == "unit" { screen["unit"] = "pixels" }
                if mutation == "basis" { screen["basis"] = "window-content-bounds" }
                if mutation == "nested-extra" { screen["scale"] = 3 }
                if mutation == "screen-axis" { screen["width"] = 900 }
                value["screen"] = screen
            }
            XCTAssertThrowsError(try decode(value), mutation)
        }
    }
    func testBoundedUTCReportingTimestampValidatesGregorianCalendar() throws {
        var value = try object(snapshot())
        for timestamp in ["2024-02-29T23:59:59Z", "2026-10-05T12:34:56.123456789Z"] {
            value["observedAt"] = timestamp; XCTAssertNoThrow(try decode(value))
        }
        for timestamp in ["2025-02-29T00:00:00Z", "0000-01-01T00:00:00Z", "2026-10-05t12:34:56z", "2026-10-05 12:34:56Z",
                          "2026-10-05T12:34:60Z", "2026-10-05T12:34:56+00:00", "2026-10-05T12:34:56." + String(repeating: "1", count: 220) + "Z"] {
            value["observedAt"] = timestamp; XCTAssertThrowsError(try decode(value))
        }
    }
    func testCodecRejectsDuplicateEscapedKeysInvalidUTF8AndOverCapacity() throws {
        let data = try snapshot().encoded(); let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        let duplicate = "{\"schemaVersion\":1," + String(string.dropFirst())
        XCTAssertThrowsError(try CloudDeviceMetadataSnapshot.decode(Data(duplicate.utf8)))
        let escaped = "{\"schema\\u0056ersion\":1," + String(string.dropFirst())
        XCTAssertThrowsError(try CloudDeviceMetadataSnapshot.decode(Data(escaped.utf8)))
        XCTAssertThrowsError(try CloudDeviceMetadataSnapshot.decode(Data([0xFF])))
        XCTAssertThrowsError(try CloudDeviceMetadataSnapshot.decode(Data(repeating: 32, count: 4097)))
        XCTAssertThrowsError(try CloudDeviceMetadataSnapshot.decode(Data((string + "false").utf8)))
    }
    func testMalformedSurrogatesAndDeepObjectsFailBeforeTypedObservation() throws {
        let surrogate = "{\"schemaVersion\":1,\"modelName\":\"\\uD800\",\"observedAt\":\"2026-10-05T00:00:00Z\",\"provenance\":\"native-device\"}"
        XCTAssertThrowsError(try CloudDeviceMetadataSnapshot.decode(Data(surrogate.utf8)))
        let deep = String(repeating: "{\"extra\":", count: 10) + "null" + String(repeating: "}", count: 10)
        XCTAssertThrowsError(try CloudDeviceMetadataSnapshot.decode(Data(deep.utf8)))
    }
    func testDeterministicBoundedSnapshotHasNoIndependentAspectOrAuthority() throws {
        let first = try snapshot(); let second = try snapshot()
        XCTAssertEqual(try first.encoded(), try second.encoded()); XCTAssertLessThanOrEqual(try first.encoded().count, 4096)
        XCTAssertEqual(Set(try object(first).keys), Set(["schemaVersion", "modelIdentifier", "modelName", "deviceName", "screen", "viewport", "interfaceOrientation", "observedAt", "provenance"]))
    }
}
