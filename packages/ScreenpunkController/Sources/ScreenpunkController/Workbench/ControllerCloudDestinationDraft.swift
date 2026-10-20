/// A workspace choice is a draft until the user confirms it. Refreshing this
/// value never creates a workspace, changes a binding, or starts synchronization.
public struct ControllerCloudDestinationDraft: Sendable {
    public private(set) var selectedID: String?
    private var accountID: String?
    private var availableIDs: [String] = []
    public init() {}
    public mutating func reconcile(accountID: String, availableIDs: [String], confirmedID: String?) {
        if self.accountID != accountID { selectedID = nil }
        self.accountID = accountID
        self.availableIDs = availableIDs
        if let selectedID, availableIDs.contains(selectedID) { return }
        selectedID = confirmedID.flatMap { availableIDs.contains($0) ? $0 : nil } ?? availableIDs.first
    }
    public mutating func choose(_ id: String) {
        guard availableIDs.contains(id) else { return }
        selectedID = id
    }
    public mutating func reset() { self = Self() }
}
