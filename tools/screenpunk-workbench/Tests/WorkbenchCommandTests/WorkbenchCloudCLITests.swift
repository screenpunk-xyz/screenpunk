import XCTest
import Foundation
import ScreenpunkController
@testable import WorkbenchCommand
final class WorkbenchCloudCLITests: XCTestCase {
    func testAutomaticLinkOnlyFollowsNewProjectResultsAndUsesTheirTrustedKind() throws {
        for method in [WorkbenchAuthoringRecoveryMethod.projectCreate, .projectClone, .projectSourceImport] {
            XCTAssertTrue(WorkbenchCloudCLI.automaticallyLinksNewProject(method))
        }
        for method in [WorkbenchAuthoringRecoveryMethod.projectOpenContained, .projectOpenExternal,
                       .projectRelocateContained, .projectUpgradeKit, .projectSourceExport] {
            XCTAssertFalse(WorkbenchCloudCLI.automaticallyLinksNewProject(method))
        }
        let value: [String: Any] = ["project": ["projectId": "local", "dashboardId": "screen", "name": "Clone",
            "location": ["kind": "workspace", "path": "Screens/local"], "collectionIds": [], "sortOrder": 0],
            "path": "/fixture/Screens/local", "sourceVersion": String(repeating: "a", count: 64),
            "sourceHashVersion": 1, "fileCount": 2, "includedBytes": 200]
        let project = try JSONDecoder().decode(WorkbenchSourceProject.self, from: JSONSerialization.data(withJSONObject: value))
        var document: [String: Any] = ["schemaVersion": 1, "projectId": "local", "dashboardId": "screen", "name": "Clone",
            "kind": "react", "kitVersion": "fixture", "entry": "main.tsx", "screenConfig": "screen.json"]
        XCTAssertEqual(try WorkbenchCloudCLI.sourceKindForNewProject(project,
            descriptor: JSONSerialization.data(withJSONObject: document)), "react")
        document["projectId"] = "another-project"
        XCTAssertThrowsError(try WorkbenchCloudCLI.sourceKindForNewProject(project,
            descriptor: JSONSerialization.data(withJSONObject: document)))
        document["projectId"] = "local"; document["dashboardId"] = "another-screen"
        XCTAssertThrowsError(try WorkbenchCloudCLI.sourceKindForNewProject(project,
            descriptor: JSONSerialization.data(withJSONObject: document)))
    }
    func testScreenSyncSetupKeepsCloudDestinationSeparateFromLocalWorkspace() throws {
        let parsed = try Options.parse(["cloud", "sync", "enable", "cloud-space", "--workspace", "/tmp/local"], environment: [:])
        XCTAssertEqual(parsed.workspace, "/tmp/local")
        XCTAssertEqual(try WorkbenchCloudCLI.parse(parsed.words), .syncEnable("cloud-space", nil))
        let bootstrap = try Options.parse(["cloud", "sync", "enable", "cloud-space", "--create-local-workspace", "/tmp/new"], environment: [:])
        XCTAssertEqual(try WorkbenchCloudCLI.parse(bootstrap.words), .syncEnable("cloud-space", "/tmp/new"))
        XCTAssertEqual(try WorkbenchCloudCLI.parse(["cloud", "sync", "disable"]), .syncDisable)
        XCTAssertEqual(try WorkbenchCloudCLI.parse(["cloud", "sync", "status"]), .syncStatus)
        XCTAssertEqual(try WorkbenchCloudCLI.parse(["cloud", "screens"]), .projects)
        XCTAssertThrowsError(try WorkbenchCloudCLI.parse(["cloud", "sync", "enable"]))
        XCTAssertThrowsError(try WorkbenchCloudCLI.parse(["cloud", "sync", "enable", "space", "--create-local-workspace", "relative"]))
        XCTAssertThrowsError(try WorkbenchCloudCLI.parse(["cloud", "sync", "disable", "unexpected"]))
    }

    func testCloudRoutesHaveExplicitSeparateSourceAndDeploymentActions() throws {
        XCTAssertEqual(try WorkbenchCloudCLI.parse(["cloud","link","local","remote"]),.link("local","remote"))
        XCTAssertEqual(try WorkbenchCloudCLI.parse(["cloud","sync","local"]),.sync("local"))
        XCTAssertEqual(try WorkbenchCloudCLI.parse(["cloud","resolve","local","remote"]),.resolve("local",false))
        XCTAssertEqual(try WorkbenchCloudCLI.parse(["cloud","deploy","review","publication","installation"]),.reviewDeployment("publication","installation"))
        XCTAssertEqual(try WorkbenchCloudCLI.parse(["cloud","deploy","apply"]),.applyDeployment)
        XCTAssertEqual(try WorkbenchCloudCLI.parse(["cloud","publish","local"]),.publish("local"))
        XCTAssertThrowsError(try WorkbenchCloudCLI.parse(["cloud","resolve","local","latest"]))
        XCTAssertThrowsError(try WorkbenchCloudCLI.parse(["cloud","sync","local","--deploy"]))
    }
}
