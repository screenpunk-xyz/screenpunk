import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
final class WorkbenchRetainedRollbackSelectionTests: XCTestCase {
    private let profileHash = String(repeating: "b", count: 64)
    private let digest = String(repeating: "a", count: 64)
    private let previous = LANScreenSetEntry(dashboardId: "screen-old",
        revision: "prepared-old", name: "Old")
    private let current = LANScreenSetEntry(dashboardId: "screen-now",
        revision: "prepared-now", name: "Current")

    private func read(source: String = "source-old", capabilities: [String] = ["web-runtime"])
        -> WorkbenchRetainedDeploymentEvidenceRead {
        let evidence = WorkbenchRollbackEvidence(planId: "plan-old",
            workspaceId: "workspace-a", deviceId: "device-a",
            deviceProfileHash: profileHash, dashboardId: "screen-old",
            sourceRevision: source, preparedRevision: "prepared-old",
            digest: digest, declaredCapabilities: capabilities)
        return .init(workspaceId: "workspace-a", selectionGeneration: 2,
            deviceId: "device-a", packages: [.init(evidence)])
    }

    func testExactReceiptedEvidenceProducesOnlyPriorPackageAndCurrentRemoval() throws {
        let proposal = try WorkbenchRetainedRollbackSelection.resolve(read: read(),
            deviceProfileHash: profileHash, previous: [previous],
            previouslySelectedDashboardId: "screen-old", current: [current])
        XCTAssertEqual(proposal.packages.map(\.dashboardId), ["screen-old"])
        XCTAssertEqual(proposal.packages.map(\.sourceRevision), ["source-old"])
        XCTAssertEqual(proposal.packages.map(\.revision), ["prepared-old"])
        XCTAssertEqual(proposal.packages.map(\.digest), [digest])
        XCTAssertEqual(proposal.selectedDashboardId, "screen-old")
        XCTAssertEqual(proposal.removedDashboardIds, ["screen-now"])
    }

    func testMissingOrCapabilityBearingProvenanceFailsClosed() {
        let empty = WorkbenchRetainedDeploymentEvidenceRead(workspaceId: "workspace-a",
            selectionGeneration: 2, deviceId: "device-a", packages: [])
        XCTAssertThrowsError(try WorkbenchRetainedRollbackSelection.resolve(read: empty,
            deviceProfileHash: profileHash, previous: [previous],
            previouslySelectedDashboardId: "screen-old", current: [current]))
        XCTAssertThrowsError(try WorkbenchRetainedRollbackSelection.resolve(
            read: read(capabilities: ["home-assistant"]),
            deviceProfileHash: profileHash, previous: [previous],
            previouslySelectedDashboardId: "screen-old", current: [current])) {
                XCTAssertEqual($0 as? WorkbenchRollbackProvenanceError,
                    .unsupportedCapabilities)
        }
    }
}
#endif
