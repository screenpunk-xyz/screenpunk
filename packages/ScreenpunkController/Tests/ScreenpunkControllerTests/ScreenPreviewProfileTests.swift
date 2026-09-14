import XCTest
@testable import ScreenpunkController

final class ScreenPreviewProfileTests: XCTestCase {
    func testCatalogHasUniqueUsablePresetsAcrossPhoneTabletAndFoldableFamilies() {
        let all = ScreenPreviewProfile.all
        XCTAssertGreaterThan(all.count, 200)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(all.allSatisfy { $0.width > 0 && $0.width <= $0.height && $0.height < 2000 })
        XCTAssertEqual(ScreenPreviewProfile.defaultProfile.name, "iPhone 13")
        XCTAssertEqual(Set(all.map(\.brand)), ["Apple", "Samsung", "Google", "OnePlus", "Xiaomi", "Motorola"])
    }
    func testFindAsYouTypeMatchesEveryTermWithoutCaseOrOrderingRequirements() {
        XCTAssertEqual(ScreenPreviewProfile.matching(" MINI 13 apple ").map(\.name), ["iPhone 13 mini"])
        XCTAssertTrue(ScreenPreviewProfile.matching("samsung ultra").contains { $0.name == "Galaxy S24 Ultra" })
        XCTAssertTrue(ScreenPreviewProfile.matching("google 3").contains { $0.name == "Pixel 3" })
        XCTAssertTrue(ScreenPreviewProfile.matching("unlisted-device-xyz").isEmpty)
        XCTAssertEqual(ScreenPreviewProfile.matching(" "), ScreenPreviewProfile.all)
    }
    func testKnownViewportsAndFoldableDisplaysRemainDistinct() throws {
        let mini = try XCTUnwrap(ScreenPreviewProfile.matching("13 mini").first)
        XCTAssertEqual(mini.width, 375)
        XCTAssertEqual(mini.height, 812)
        let ipad = try XCTUnwrap(ScreenPreviewProfile.matching("ipad mini 6th").first)
        XCTAssertEqual(ipad.width, 744)
        XCTAssertEqual(ipad.height, 1133)
        let outer = try XCTUnwrap(ScreenPreviewProfile.matching("pixel 10 fold outer").first)
        let inner = try XCTUnwrap(ScreenPreviewProfile.matching("pixel 10 fold inner").first)
        XCTAssertNotEqual(inner.id, outer.id)
        XCTAssertLessThan(Double(inner.height) / Double(inner.width), Double(outer.height) / Double(outer.width))
    }
}
