#if os(iOS)
import XCTest
import SwiftUI
import ScreenpunkCore
@_spi(ManagedRender) @testable import ScreenpunkApple

@MainActor final class DeviceConnectorCatalogTests: XCTestCase {
    private func manifest(_ id: String, connections: [ManifestConnection] = []) -> DashboardManifest {
        .init(schemaVersion: 1, dashboardId: id, name: id, revision: "fixture", entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "fixture", width: 390, height: 844, scale: 1, orientation: "portrait"), connections: connections, files: [])
    }
    private func catalog(_ manifests: [DashboardManifest], basic: GoogleTVConfiguration = .init(), developer: GoogleTVADBConfiguration = .init()) -> DeviceConnectorCatalog {
        .init(manifests: manifests, basic: basic, developer: developer)
    }
    func testManagedSnapshotIncludesUnselectedScreenAndNeverReadsLegacyOnEmptySnapshot() {
        let ordinary = manifest("selected"), tv = manifest("other", connections: [.init(alias: "googleTV", required: false)])
        var legacyReads = 0
        let managed = DeviceConnectorCatalog.sourceManifests(managed: [ordinary, tv], legacy: { legacyReads += 1; return [] })
        XCTAssertEqual(managed.map(\.dashboardId), ["selected", "other"])
        XCTAssertTrue(catalog(managed).showsTV); XCTAssertNil(catalog(managed).missing(for: "other"))
        let unavailable = DeviceConnectorCatalog.sourceManifests(managed: [], legacy: { legacyReads += 1; return [tv] })
        XCTAssertTrue(unavailable.isEmpty); XCTAssertFalse(catalog(unavailable).showsTV); XCTAssertEqual(legacyReads, 0)
        let legacy = DeviceConnectorCatalog.sourceManifests(managed: nil, legacy: { legacyReads += 1; return [tv] })
        XCTAssertTrue(catalog(legacy).showsTV); XCTAssertEqual(legacyReads, 1)
    }
    func testExactDeclarationsAndSavedUnusedConfigurationControlVisibilityWithoutInferringNames() {
        XCTAssertFalse(catalog([manifest("google-tv-test")]).showsTV)
        XCTAssertFalse(catalog([manifest("other", connections: [.init(alias: "google-tv", required: false)])]).showsTV)
        let tv = manifest("tv", connections: [.init(alias: "googleTV", required: false)])
        XCTAssertTrue(catalog([tv, manifest("another", connections: tv.connections)]).usesTV)
        XCTAssertNil(catalog([tv]).missing(for: "tv"))
        var basic = GoogleTVConfiguration(); basic.host = "saved-fixture"
        XCTAssertTrue(catalog([], basic: basic).showsTV); XCTAssertFalse(catalog([], basic: basic).usesTV)
        var developer = GoogleTVADBConfiguration(); developer.host = "saved-developer-fixture"
        XCTAssertTrue(catalog([], developer: developer).showsTV)
    }
    func testRequiredOperationsKeepBasicAndDeveloperPairingIndependent() {
        let basicScreen = manifest("basic", connections: [.init(alias: "googleTV", required: true, operations: [.init(name: "status", kind: "http")])])
        let directScreen = manifest("direct", connections: [.init(alias: "googleTV", required: true, operations: [.init(name: "launchChannel", kind: "http"), .init(name: "togglePower", kind: "http")])])
        var basic = GoogleTVConfiguration(); basic.pin = Data(repeating: 1, count: 32)
        var developer = GoogleTVADBConfiguration(); developer.serverPin = Data(repeating: 2, count: 32)
        XCTAssertEqual(catalog([basicScreen, directScreen]).missing(for: "basic"), .googleTV)
        XCTAssertNil(catalog([basicScreen, directScreen], basic: basic).missing(for: "basic"))
        XCTAssertEqual(catalog([basicScreen, directScreen], basic: basic).missing(for: "direct"), .googleTV)
        XCTAssertNil(catalog([basicScreen, directScreen], developer: developer).missing(for: "direct"))
        XCTAssertEqual(catalog([basicScreen, directScreen], developer: developer).missing(for: "basic"), .googleTV)
    }
    func testCloudMenuRetainsExactQualifiedManifestInputAndDefaultsToUnknownEmpty() {
        let tv = manifest("installed", connections: [.init(alias: "googleTV", required: false)])
        let input = DeviceCloudMenuContent(deviceName: "Fixture", connectionDescription: "Local", screenSummary: "Fixture", screenCount: 1,
            installedManifests: [tv], settings: EmptyView(), screens: EmptyView())
        XCTAssertEqual(input.installedManifests.map(\.dashboardId), ["installed"])
        XCTAssertTrue(catalog(input.installedManifests).showsTV)
        let unknown = DeviceCloudMenuContent(deviceName: "Fixture", connectionDescription: "Local", screenSummary: "Unknown", screenCount: nil,
            settings: EmptyView(), screens: EmptyView())
        XCTAssertTrue(unknown.installedManifests.isEmpty)
    }
}
#endif
