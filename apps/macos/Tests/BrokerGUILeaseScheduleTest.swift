import Foundation

@main
struct BrokerGUILeaseScheduleTest {
    private final class FakeLeaseService {
        let consumerId: String
        var renewals = 0
        var releases = 0
        init(consumerId: String) { self.consumerId = consumerId }
        func renew() -> (String, Int) { renewals += 1; return (consumerId, 30) }
        func release() { releases += 1 }
    }
    static func main() throws {
        let id = UUID().uuidString
        let service = FakeLeaseService(consumerId: id)
        var lease = try BrokerGUILeaseSchedule(consumerId: id, leaseSeconds: 30, now: 100)
        precondition(!lease.due(at: 114) && lease.due(at: 115))
        precondition(!lease.expired(at: 129) && lease.expired(at: 130))
        let renewed = service.renew()
        try lease.renewed(consumerId: renewed.0, leaseSeconds: renewed.1, now: 115)
        precondition(lease.expiresAt == 145 && lease.renewAt == 130)
        do {
            try lease.renewed(consumerId: UUID().uuidString, leaseSeconds: 30, now: 130)
            preconditionFailure("A different broker consumer ID was accepted")
        } catch BrokerGUILeaseError.invalidLease {}
        lease.release()
        service.release()
        precondition(!lease.due(at: 130) && lease.expired(at: 130) &&
                     service.renewals == 1 && service.releases == 1)
        print("BrokerGUILeaseScheduleTest passed")
    }
}
