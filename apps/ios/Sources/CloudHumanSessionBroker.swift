import Combine
import SwiftUI

/// Process-local ownership of the shared Firebase/GID human session. Dormant until
/// explicit acquisition; it is not installation authority or restart durability.
@MainActor
final class CloudHumanSessionBroker: ObservableObject {
    static let shared = CloudHumanSessionBroker()
    enum State: Equatable { case vacant, reserving, attached, settling, retiring, cleanupFailed }
    enum Failure: Error { case occupied, staleOwnership }
    @Published private(set) var state: State = .vacant

    @MainActor final class Lease {
        fileprivate weak var broker: CloudHumanSessionBroker?
        fileprivate let generation = UUID()
        fileprivate let owner: UUID
        fileprivate init(broker: CloudHumanSessionBroker, owner: UUID) { self.broker = broker; self.owner = owner }
        func checkConstruction() throws { try checkedBroker().validate(self, construction: true) }
        func checkHumanAction() throws { try checkedBroker().validate(self, human: true) }
        func checkSettlement() throws { try checkedBroker().validate(self) }
        var isCurrent: Bool { broker?.owns(self) == true }
        private func checkedBroker() throws -> CloudHumanSessionBroker {
            guard let broker else { throw Failure.staleOwnership }; return broker
        }
    }
    @MainActor private final class Slot {
        let lease: Lease
        var session: CloudHumanSession?
        var retirement = false
        var settledSuccessfully = false
        var monitor: Task<Void, Never>?
        var observation: AnyCancellable?
        init(_ lease: Lease) { self.lease = lease }
    }
    private var slot: Slot?

    func acquire(owner: UUID, factory: (Lease) throws -> CloudHumanSession) throws -> Lease {
        guard slot == nil else { throw Failure.occupied }
        let lease = Lease(broker: self, owner: owner), current = Slot(lease)
        slot = current; state = .reserving
        do {
            let session = try factory(lease)
            try validate(lease, construction: true)
            current.session = session
            session.bind(lease)
            state = .attached
            current.observation = session.coordinator?.$signOutState.sink { [weak self, weak lease] value in
                guard value == .pending || value == .succeeded, let lease,
                      let self, self.owns(lease), let current = self.slot else { return }
                current.settledSuccessfully = value == .succeeded
                if !current.retirement { self.state = .settling }
                // Actor delivery happens after the coordinator has stored its settlement task.
                Task { @MainActor [weak self, weak lease] in
                    guard let self, let lease, self.owns(lease) else { return }
                    _ = self.settle(lease, retrying: false)
                }
            }
            return lease
        } catch {
            if owns(lease) { slot = nil; state = .vacant }
            throw error
        }
    }
    func session(for lease: Lease) -> CloudHumanSession? {
        guard owns(lease), slot?.retirement == false else { return nil }; return slot?.session
    }
    /// URL transport is process-wide; it grants the delivering scene no ownership.
    /// The attached identity still validates provider, configuration and active attempt.
    func dispatchGoogleCallback(_ url: URL) -> Bool {
        guard state == .attached, let current = slot, !current.retirement,
              owns(current.lease), let session = current.session else { return false }
        let accepted = session.handleCallback(url)
        guard slot === current, owns(current.lease), state == .attached,
              !current.retirement else { return false }
        return accepted
    }
    func owns(_ lease: Lease) -> Bool { slot?.lease === lease && lease.broker === self }
    private func validate(_ lease: Lease, construction: Bool = false, human: Bool = false) throws {
        guard owns(lease) else { throw Failure.staleOwnership }
        if construction { guard state == .reserving else { throw Failure.staleOwnership } }
        if human { guard state == .attached, slot?.retirement == false else { throw Failure.staleOwnership } }
    }
    func cancel(_ lease: Lease) {
        guard owns(lease), slot?.retirement == false else { return }
        slot?.session?.cancel()
    }
    @discardableResult func signOut(_ lease: Lease) -> Task<Void, Never>? {
        guard owns(lease) else { return nil }; return settle(lease, retrying: false)
    }
    @discardableResult func retrySignOut(_ lease: Lease) -> Task<Void, Never>? {
        guard owns(lease) else { return nil }; return settle(lease, retrying: true)
    }
    @discardableResult func retire(_ lease: Lease) -> Task<Void, Never>? {
        guard owns(lease), let current = slot else { return nil }
        current.retirement = true; state = .retiring
        if current.session?.coordinator == nil { // Internal fake context has no SDK session.
            current.session?.cancel(); slot = nil; state = .vacant; return nil
        }
        return settle(lease, retrying: false)
    }
    /// A later scene can explicitly repair retired cleanup, never acquire around it.
    @discardableResult func retryRetiredCleanup() -> Task<Void, Never>? {
        guard let current = slot, current.retirement, state == .cleanupFailed else { return nil }
        return settle(current.lease, retrying: true)
    }
    private func settle(_ lease: Lease, retrying: Bool) -> Task<Void, Never>? {
        guard owns(lease), let current = slot, let session = current.session else { return nil }
        if let monitor = current.monitor { return monitor }
        if session.coordinator?.signOutState == .failed && !retrying { state = .cleanupFailed; return nil }
        state = current.retirement ? .retiring : .settling
        let operation = retrying ? session.retrySignOut() : session.signOut()
        let monitor = Task { [self, current] in
            await operation?.value
            guard owns(lease) else { return }
            current.monitor = nil
            if current.settledSuccessfully {
                // SDK settlement has returned; invalidate every old closure before a successor.
                slot = nil; state = .vacant
            } else { state = .cleanupFailed }
        }
        current.monitor = monitor
        return monitor
    }
}
