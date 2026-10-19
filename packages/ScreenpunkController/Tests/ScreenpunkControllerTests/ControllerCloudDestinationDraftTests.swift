import XCTest
@testable import ScreenpunkController
final class ControllerCloudDestinationDraftTests: XCTestCase {
    func testOnlyWorkspaceIsDefaultDraft() {
        var draft = ControllerCloudDestinationDraft()
        draft.reconcile(accountID: "account", availableIDs: ["studio"], confirmedID: nil)
        XCTAssertEqual(draft.selectedID, "studio")
    }
    func testMultipleWorkspacesDefaultToFirstInDisplayedOrder() {
        var draft = ControllerCloudDestinationDraft()
        draft.reconcile(accountID: "account", availableIDs: ["top", "other"], confirmedID: nil)
        XCTAssertEqual(draft.selectedID, "top")
    }
    func testExistingConfirmedDestinationIsPreferred() {
        var draft = ControllerCloudDestinationDraft()
        draft.reconcile(accountID: "account", availableIDs: ["top", "confirmed"], confirmedID: "confirmed")
        XCTAssertEqual(draft.selectedID, "confirmed")
    }
    func testRefreshPreservesUnconfirmedUserChoice() {
        var draft = ControllerCloudDestinationDraft()
        draft.reconcile(accountID: "account", availableIDs: ["top", "other"], confirmedID: "top")
        draft.choose("other")
        draft.reconcile(accountID: "account", availableIDs: ["top", "other", "new"], confirmedID: "top")
        XCTAssertEqual(draft.selectedID, "other")
    }
    func testAccountSwitchDoesNotReuseAnotherAccountsChoice() {
        var draft = ControllerCloudDestinationDraft()
        draft.reconcile(accountID: "first", availableIDs: ["same", "other"], confirmedID: nil)
        draft.choose("other")
        draft.reconcile(accountID: "second", availableIDs: ["same", "other"], confirmedID: nil)
        XCTAssertEqual(draft.selectedID, "same")
    }
    func testRemovedWorkspaceFallsBackAndUnknownChoiceIsIgnored() {
        var draft = ControllerCloudDestinationDraft()
        draft.reconcile(accountID: "account", availableIDs: ["top", "other"], confirmedID: nil)
        draft.choose("other")
        draft.reconcile(accountID: "account", availableIDs: ["top"], confirmedID: nil)
        draft.choose("unlisted")
        XCTAssertEqual(draft.selectedID, "top")
    }
    func testEmptyListAndResetHaveNoDestination() {
        var draft = ControllerCloudDestinationDraft()
        draft.reconcile(accountID: "account", availableIDs: [], confirmedID: nil)
        XCTAssertNil(draft.selectedID)
        draft.reconcile(accountID: "account", availableIDs: ["studio"], confirmedID: nil)
        draft.reset()
        XCTAssertNil(draft.selectedID)
    }
}
