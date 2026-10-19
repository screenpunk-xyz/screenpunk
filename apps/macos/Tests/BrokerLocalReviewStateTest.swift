import Foundation

@main
struct BrokerLocalReviewStateTest {
    private final class FakeService {
        var confirms = 0
        var denials = 0
        func confirm() { confirms += 1 }
        func deny() { denials += 1 }
    }
    static func main() throws {
        let service = FakeService()
        let t0 = Date(timeIntervalSince1970: 100)
        var review = try BrokerLocalReviewState(intentId: "intent-1", reviewHandle: "handle-1",
                                                expiresAt: t0.addingTimeInterval(30))
        try review.consume(.approve, at: t0.addingTimeInterval(5))
        service.confirm()
        do {
            try review.consume(.approve, at: t0.addingTimeInterval(6))
            service.confirm()
            preconditionFailure("Replay accepted")
        } catch BrokerLocalReviewError.expiredOrConsumed {}
        precondition(service.confirms == 1)
        var expired = try BrokerLocalReviewState(intentId: "intent-2", reviewHandle: "handle-2",
                                                 expiresAt: t0.addingTimeInterval(2))
        do {
            try expired.consume(.deny, at: t0.addingTimeInterval(3))
            service.deny()
            preconditionFailure("Expired review accepted")
        } catch BrokerLocalReviewError.expiredOrConsumed {}
        precondition(service.denials == 0)
        var denied = try BrokerLocalReviewState(intentId: "intent-3", reviewHandle: "handle-3",
                                                expiresAt: t0.addingTimeInterval(30))
        try denied.consume(.deny, at: t0.addingTimeInterval(1))
        service.deny()
        denied.close()
        precondition(service.denials == 1 && denied.consumed)
        print("BrokerLocalReviewStateTest passed")
    }
}
