import Foundation

/// UI-side one-shot/expiry guard; the broker remains the approval authority.
struct BrokerLocalReviewState {
    enum Decision { case approve, deny }
    private(set) var intentId: String
    private(set) var reviewHandle: String
    private(set) var expiresAt: Date
    private(set) var consumed = false

    init(intentId: String, reviewHandle: String, expiresAt: Date) throws {
        guard !intentId.isEmpty, !reviewHandle.isEmpty else { throw BrokerLocalReviewError.invalid }
        self.intentId = intentId; self.reviewHandle = reviewHandle; self.expiresAt = expiresAt
    }

    mutating func consume(_ decision: Decision, at now: Date) throws {
        guard !consumed, now < expiresAt else { throw BrokerLocalReviewError.expiredOrConsumed }
        consumed = true
        _ = decision
    }

    mutating func close() { consumed = true }
}

enum BrokerLocalReviewError: Error { case invalid, expiredOrConsumed }
