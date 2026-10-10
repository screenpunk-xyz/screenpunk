import Foundation

/// Pure monotonic timing for a broker-minted connection-bound GUI lease.
struct BrokerGUILeaseSchedule {
    private(set) var consumerId: String
    private(set) var expiresAt: TimeInterval
    private(set) var renewAt: TimeInterval
    private(set) var released = false

    init(consumerId: String, leaseSeconds: Int, now: TimeInterval) throws {
        guard UUID(uuidString: consumerId) != nil, leaseSeconds > 0, leaseSeconds <= 300,
              now.isFinite else { throw BrokerGUILeaseError.invalidLease }
        self.consumerId = consumerId
        expiresAt = now + Double(leaseSeconds)
        renewAt = now + Double(leaseSeconds) / 2
    }

    var active: Bool { !released }
    func due(at now: TimeInterval) -> Bool { active && now >= renewAt && now < expiresAt }
    func expired(at now: TimeInterval) -> Bool { !active || now >= expiresAt }

    mutating func renewed(consumerId: String, leaseSeconds: Int, now: TimeInterval) throws {
        guard active, !expired(at: now), consumerId == self.consumerId else {
            throw BrokerGUILeaseError.invalidLease
        }
        self = try .init(consumerId: consumerId, leaseSeconds: leaseSeconds, now: now)
    }

    mutating func release() { released = true }
}

enum BrokerGUILeaseError: Error { case invalidLease }
