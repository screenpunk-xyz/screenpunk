import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct FakeRollbackEvidence: WorkbenchRollbackEvidenceProvider {
    var values: [WorkbenchRollbackEvidence]
    func retainedPackages(workspaceId: String, deviceId: String) throws -> [WorkbenchRollbackEvidence] {
        values
    }
}

final class WorkbenchRollbackProvenanceTests: XCTestCase {
    private let old = LANScreenSetEntry(dashboardId: "screen-a", revision: "prepared-a", name: "Old")
    private let current = LANScreenSetEntry(dashboardId: "screen-b", revision: "prepared-b", name: "New")

    private func evidence(source: String = "source-a", digest: String = String(repeating: "a", count: 64),
                          capabilities: [String] = []) -> WorkbenchRollbackEvidence {
        .init(planId: "plan-a", workspaceId: "workspace-a", deviceId: "device-a",
            deviceProfileHash: String(repeating: "b", count: 64), dashboardId: "screen-a",
            sourceRevision: source, preparedRevision: "prepared-a", digest: digest,
            declaredCapabilities: capabilities)
    }

    func testExactRetainedPackageResolvesPreviousSetAndRemovals() throws {
        let selection = try WorkbenchRollbackProvenance.resolve(workspaceId: "workspace-a",
            deviceId: "device-a", deviceProfileHash: String(repeating: "b", count: 64),
            previous: [old], previouslySelectedDashboardId: "screen-a", current: [current],
            provider: FakeRollbackEvidence(values: [evidence()]))
        XCTAssertEqual(selection.packages.map(\.dashboardId), ["screen-a"])
        XCTAssertEqual(selection.packages.map(\.sourceRevision), ["source-a"])
        XCTAssertEqual(selection.packages.map(\.revision), ["prepared-a"])
        XCTAssertEqual(selection.selectedDashboardId, "screen-a")
        XCTAssertEqual(selection.removedDashboardIds, ["screen-b"])
    }

    func testMissingOrAmbiguousHistoryFailsClosed() {
        XCTAssertThrowsError(try WorkbenchRollbackProvenance.resolve(workspaceId: "workspace-a",
            deviceId: "device-a", deviceProfileHash: String(repeating: "b", count: 64),
            previous: [old], previouslySelectedDashboardId: "screen-a", current: [current],
            provider: FakeRollbackEvidence(values: []))) {
            XCTAssertEqual($0 as? WorkbenchRollbackProvenanceError, .missingProvenance)
        }
        XCTAssertThrowsError(try WorkbenchRollbackProvenance.resolve(workspaceId: "workspace-a",
            deviceId: "device-a", deviceProfileHash: String(repeating: "b", count: 64),
            previous: [old], previouslySelectedDashboardId: "screen-a", current: [current],
            provider: FakeRollbackEvidence(values: [evidence(), evidence(source: "source-other")]))) {
            XCTAssertEqual($0 as? WorkbenchRollbackProvenanceError, .ambiguousProvenance)
        }
        XCTAssertThrowsError(try WorkbenchRollbackProvenance.resolve(workspaceId: "workspace-a",
            deviceId: "device-a", deviceProfileHash: String(repeating: "b", count: 64),
            previous: [old], previouslySelectedDashboardId: "screen-a", current: [current],
            provider: FakeRollbackEvidence(values: [evidence(capabilities: ["home-assistant"])]))) {
            XCTAssertEqual($0 as? WorkbenchRollbackProvenanceError, .unsupportedCapabilities)
        }
    }

    func testEmptyPreviousSetAndWrongDeviceAreNotInvented() {
        XCTAssertThrowsError(try WorkbenchRollbackProvenance.resolve(workspaceId: "workspace-a",
            deviceId: "device-a", deviceProfileHash: String(repeating: "b", count: 64),
            previous: [], previouslySelectedDashboardId: nil, current: [current],
            provider: FakeRollbackEvidence(values: [evidence()]))) {
            XCTAssertEqual($0 as? WorkbenchRollbackProvenanceError, .noPreviousSet)
        }
        XCTAssertThrowsError(try WorkbenchRollbackProvenance.resolve(workspaceId: "workspace-a",
            deviceId: "device-other", deviceProfileHash: String(repeating: "b", count: 64),
            previous: [old], previouslySelectedDashboardId: "screen-a", current: [current],
            provider: FakeRollbackEvidence(values: [evidence()]))) {
            XCTAssertEqual($0 as? WorkbenchRollbackProvenanceError, .missingProvenance)
        }
    }
}
#endif
