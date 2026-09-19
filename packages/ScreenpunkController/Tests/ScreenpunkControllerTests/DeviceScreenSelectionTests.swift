import XCTest
@testable import ScreenpunkController

final class DeviceScreenSelectionTests: XCTestCase {
    func testSelectionModesPreserveOrderAndCollapseToPreview() throws {
        var selection = DeviceScreenSelection(ids: ["clock"])
        selection.choose("lights")
        XCTAssertEqual(selection.ids, ["lights"])
        selection.setMultiple(true, preferred: "lights")
        selection.choose("clock"); selection.choose("weather")
        XCTAssertEqual(selection.ids, ["lights", "clock", "weather"])
        selection.choose("clock")
        XCTAssertEqual(selection.ids, ["lights", "weather"])
        selection.setMultiple(false, preferred: "weather")
        XCTAssertEqual(selection.ids, ["weather"])
        XCTAssertFalse(selection.multiple)
    }
    func testLimitEmptySelectionAndRestoration() throws {
        var selection = DeviceScreenSelection(ids: (0..<12).map(String.init), multiple: true)
        XCTAssertFalse(selection.choose("overflow"))
        XCTAssertEqual(selection.ids.count, 12)
        let restored = try JSONDecoder().decode(DeviceScreenSelection.self, from: JSONEncoder().encode(selection))
        XCTAssertEqual(restored, selection)
        for id in selection.ids { selection.choose(id) }
        XCTAssertTrue(selection.ids.isEmpty)
        selection.setMultiple(false, preferred: nil)
        XCTAssertTrue(selection.ids.isEmpty)
        selection.choose("new")
        XCTAssertEqual(selection.ids, ["new"])
    }
    func testPreviewNavigationUsesOrderWithoutChangingSelection() {
        var selection = DeviceScreenSelection(ids: ["lights", "clock", "weather"], multiple: true)
        let original = selection
        XCTAssertEqual(selection.previewNeighbor(of: "clock", offset: -1), "lights")
        XCTAssertEqual(selection.previewNeighbor(of: "clock", offset: 1), "weather")
        XCTAssertNil(selection.previewNeighbor(of: "lights", offset: -1))
        XCTAssertNil(selection.previewNeighbor(of: "weather", offset: 1))
        XCTAssertEqual(selection, original)
        selection.choose("clock")
        XCTAssertNil(selection.previewNeighbor(of: "clock", offset: 1))
        XCTAssertEqual(selection.previewNeighbor(of: "lights", offset: 1), "weather")
        selection.setMultiple(false, preferred: "weather")
        XCTAssertNil(selection.previewNeighbor(of: "weather", offset: -1))
        XCTAssertNil(selection.previewNeighbor(of: nil, offset: 1))
    }
    func testFindAsYouTypeMatchesAllTermsIgnoringCaseAndDiacritics() {
        XCTAssertTrue(DeviceScreenSelection.matches(name: "Café Game Lights", query: "LIGHT cafe"))
        XCTAssertTrue(DeviceScreenSelection.matches(name: "Clock", query: "  "))
        XCTAssertFalse(DeviceScreenSelection.matches(name: "Clock", query: "clock lights"))
    }
}
