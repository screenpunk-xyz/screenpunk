import XCTest
@testable import ScreenpunkApple

final class DeviceCloudAccountRequestTests: XCTestCase {
    func testCoverRequestWaitsForActualDismissalAndDeliversOnce() {
        var delivery = DeviceCloudAccountRequestDelivery()
        XCTAssertFalse(delivery.request(onboardingPresented: true))
        XCTAssertTrue(delivery.pending)
        XCTAssertFalse(delivery.request(onboardingPresented: true))
        XCTAssertTrue(delivery.onboardingDismissed())
        XCTAssertFalse(delivery.pending)
        XCTAssertFalse(delivery.onboardingDismissed())
    }
    func testInlineWelcomeDeliversDirectlyWithoutPendingCover() {
        var delivery = DeviceCloudAccountRequestDelivery()
        XCTAssertTrue(delivery.request(onboardingPresented: false))
        XCTAssertFalse(delivery.pending)
        XCTAssertFalse(delivery.onboardingDismissed())
    }
    func testOrdinaryCloseHasNoQueuedCloudAction() {
        var delivery = DeviceCloudAccountRequestDelivery()
        XCTAssertFalse(delivery.onboardingDismissed())
    }
}

#if os(iOS)
import SwiftUI
import UIKit

@MainActor
private final class CloudCoverHarness: ObservableObject {
    @Published var presented = false
    var delivery = DeviceCloudAccountRequestDelivery()
    var externalActions = 0
    func request() { _ = delivery.request(onboardingPresented: true); presented = false }
    func dismissed() { if delivery.onboardingDismissed() { externalActions += 1 } }
}
private struct CloudCoverHarnessView: View {
    @ObservedObject var model: CloudCoverHarness
    var body: some View {
        Text("Fixture welcome").fullScreenCover(isPresented: $model.presented, onDismiss: model.dismissed) {
            Text("Fixture onboarding")
        }
    }
}
extension DeviceCloudAccountRequestTests {
    @MainActor
    private func waitForCoverEvent(_ event: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard condition() else {
            XCTFail("Timed out waiting for " + event)
            throw NSError(domain: "CloudCoverHostedFixture", code: 1)
        }
    }
    @MainActor
    func testHostedCoverDefersExternalActionUntilActualOnDismissExactlyOnce() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow), model = CloudCoverHarness()
        let host = UIHostingController(rootView: CloudCoverHarnessView(model: model)), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded(); model.presented = true
        try await waitForCoverEvent("cover presentation") { host.presentedViewController != nil }
        XCTAssertEqual(model.externalActions, 0)
        model.request()
        XCTAssertEqual(model.externalActions, 0, "Setting presentation false does not deliver the external action")
        try await waitForCoverEvent("onDismiss delivery") { model.externalActions == 1 }
        try await waitForCoverEvent("cover dismissal") { host.presentedViewController == nil }
        XCTAssertEqual(model.externalActions, 1)
        model.dismissed(); XCTAssertEqual(model.externalActions, 1)
    }
}
#endif
