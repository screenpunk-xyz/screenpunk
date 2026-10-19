import XCTest
import Foundation
@testable import ScreenpunkController
#if os(macOS)
final class ControllerCloudSyncProgressTests: XCTestCase {
    func testCurrentLocalEditIsPendingAfterOldSuccessAndFailurePreservesSuccessTime() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-progress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ControllerCloudSyncProgressStore(root: root, scope: .init(accountId: "account", workspaceId: UUID().uuidString, localWorkspaceId: UUID().uuidString))
        try store.screen("screen", state: "synced", signature: "revision-a", acknowledge: true)
        let old = try XCTUnwrap(store.read().entries["screen"])
        XCTAssertNotNil(old.status.lastSuccessfulSyncAt)
        XCTAssertEqual(ControllerCloudSyncProgressStore.display(old, signature: "revision-b", enabled: true, active: false).state, "pending")
        try store.screen("screen", state: "syncing", signature: "revision-b")
        try store.screen("screen", state: "error", signature: "revision-b")
        let failed = try XCTUnwrap(store.read().entries["screen"])
        XCTAssertEqual(failed.status.lastSuccessfulSyncAt, old.status.lastSuccessfulSyncAt)
        XCTAssertEqual(ControllerCloudSyncProgressStore.display(failed, signature: "revision-b", enabled: true, active: false).state, "error")
        XCTAssertEqual(ControllerCloudSyncProgressStore.display(failed, signature: "revision-c", enabled: true, active: false).state, "pending")
        XCTAssertEqual(ControllerCloudSyncProgressStore.display(failed, signature: "revision-b", enabled: false, active: false).state, "off")
    }
    func testSourceDownloadAndPackageSignaturesAcknowledgeOnlySuccessfulCurrentRevision() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-progress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ControllerCloudSyncProgressStore(root: root, scope: .init(accountId: "a", workspaceId: UUID().uuidString, localWorkspaceId: UUID().uuidString))
        try store.screen("downloaded-source", state: "synced", signature: "new-local-revision", acknowledge: true)
        let package = ControllerCloudSyncProgressStore.signature(["immutable-digest-a"])
        try store.screen("package-only", state: "synced", signature: package, acknowledge: true)
        let rows = try store.read().entries
        XCTAssertEqual(ControllerCloudSyncProgressStore.display(rows["downloaded-source"], signature: "new-local-revision", enabled: true, active: false).state, "synced")
        XCTAssertEqual(ControllerCloudSyncProgressStore.display(rows["package-only"], signature: ControllerCloudSyncProgressStore.signature(["immutable-digest-a", "immutable-digest-b"]), enabled: true, active: false).state, "pending")
    }
    private actor CallbackGate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait(_ entered: @Sendable () -> Void) async {
            await withCheckedContinuation { continuation = $0; entered() }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    func testSuspendedListenerCannotWriteAfterConsentOwnerReplacement() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-sync-callback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = UUID().uuidString, local = UUID().uuidString
        try ControllerCloudPersistence.write(JSONSerialization.data(withJSONObject: ["accountId": "a", "workspaceId": workspace, "localWorkspaceId": local]), to: root.appendingPathComponent("selection.json"))
        func policy(_ epoch: String, _ client: String) throws {
            try ControllerCloudPersistence.write(JSONEncoder().encode(ControllerCloudSyncPolicy(accountId: "a", workspaceId: workspace, localWorkspaceId: local, enabled: true, epoch: epoch, clientId: client)), to: root.appendingPathComponent("screen-sync-policy.json"))
        }
        try policy("old", "screenpunk-mac")
        let store = ControllerCloudSyncRequestStore(root: root)
        try store.enqueue(trigger: .enabled, dashboardId: nil)
        let old = try XCTUnwrap(store.pending()), gate = CallbackGate(), entered = expectation(description: "old listener suspended")
        let callback = Task {
            await gate.wait { entered.fulfill() }
            try store.enqueue(trigger: .remoteInvalidation, dashboardId: nil, authorizedBy: old)
        }
        await fulfillment(of: [entered], timeout: 2)
        try policy("new", "screenpunk-cli")
        try store.enqueue(trigger: .enabled, dashboardId: nil)
        let replacement = try Data(contentsOf: store.file)
        await gate.release()
        do { try await callback.value; XCTFail("stale callback admitted") } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: store.file), replacement)
        XCTAssertEqual(try store.pending()?.clientId, "screenpunk-cli")
    }
    func testPolicyChangeBetweenAdmissionAndConstructionNeverRetargetsOldCallback() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-sync-interleave-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = UUID().uuidString, local = UUID().uuidString
        try ControllerCloudPersistence.write(JSONSerialization.data(withJSONObject: ["accountId": "a", "workspaceId": workspace, "localWorkspaceId": local]), to: root.appendingPathComponent("selection.json"))
        func policy(_ epoch: String, _ client: String) throws {
            try ControllerCloudPersistence.write(JSONEncoder().encode(ControllerCloudSyncPolicy(accountId: "a", workspaceId: workspace, localWorkspaceId: local, enabled: true, epoch: epoch, clientId: client)), to: root.appendingPathComponent("screen-sync-policy.json"))
        }
        try policy("old", "screenpunk-mac")
        let store = ControllerCloudSyncRequestStore(root: root)
        try store.enqueue(trigger: .enabled, dashboardId: nil)
        let old = try XCTUnwrap(store.pending())
        try store.enqueue(trigger: .remoteInvalidation, dashboardId: nil, authorizedBy: old, afterAdmission: { try policy("new", "screenpunk-cli") })
        let raw = try JSONDecoder().decode(ControllerCloudScreenSyncRequest.self, from: Data(contentsOf: store.file))
        XCTAssertEqual(raw.epoch, "old"); XCTAssertEqual(raw.clientId, "screenpunk-mac")
        XCTAssertNil(try store.pending(), "obsolete captured scope is ignored rather than retargeted")
        try store.enqueue(trigger: .enabled, dashboardId: nil)
        XCTAssertEqual(try store.pending()?.epoch, "new"); XCTAssertEqual(try store.pending()?.clientId, "screenpunk-cli")
    }
    func testRequestCoalescingPreservesTwoScreensAndNewRequestDuringAcknowledgement() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-sync-request-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = UUID().uuidString, local = UUID().uuidString
        try ControllerCloudPersistence.write(JSONSerialization.data(withJSONObject: ["accountId": "a", "workspaceId": workspace, "localWorkspaceId": local]), to: root.appendingPathComponent("selection.json"))
        try ControllerCloudPersistence.write(JSONEncoder().encode(ControllerCloudSyncPolicy(accountId: "a", workspaceId: workspace, localWorkspaceId: local, enabled: true, epoch: "consent", clientId: "screenpunk-mac")), to: root.appendingPathComponent("screen-sync-policy.json"))
        let store = ControllerCloudSyncRequestStore(root: root), a = UUID().uuidString, b = UUID().uuidString
        try store.enqueue(trigger: .localChanged, dashboardId: a)
        let claimed = try XCTUnwrap(store.pending())
        try store.enqueue(trigger: .localChanged, dashboardId: b)
        try store.acknowledge(claimed.requestId)
        let current = try XCTUnwrap(store.pending())
        XCTAssertEqual(Set(current.dashboardIds), [a, b])
        XCTAssertNotEqual(current.requestId, claimed.requestId)
        try store.enqueue(trigger: .appOpened, dashboardId: nil)
        try store.enqueue(trigger: .localChanged, dashboardId: a)
        XCTAssertTrue(try XCTUnwrap(store.pending()).requiresFullCheck)
        XCTAssertEqual(current.clientId, "screenpunk-mac")
        // A suspended old listener cannot enqueue into the next consent epoch or another client.
        try ControllerCloudPersistence.write(JSONEncoder().encode(ControllerCloudSyncPolicy(accountId: "a", workspaceId: workspace, localWorkspaceId: local, enabled: true, epoch: "next", clientId: "screenpunk-cli")), to: root.appendingPathComponent("screen-sync-policy.json"))
        let before = try Data(contentsOf: store.file)
        XCTAssertThrowsError(try store.enqueue(trigger: .remoteInvalidation, dashboardId: nil, authorizedBy: claimed))
        XCTAssertEqual(try Data(contentsOf: store.file), before)
        try ControllerCloudPersistence.write(JSONEncoder().encode(ControllerCloudSyncPolicy(accountId: "a", workspaceId: workspace, localWorkspaceId: local, enabled: false, epoch: "revoked")), to: root.appendingPathComponent("screen-sync-policy.json"))
        XCTAssertNil(try store.pending())
    }
}
#endif
