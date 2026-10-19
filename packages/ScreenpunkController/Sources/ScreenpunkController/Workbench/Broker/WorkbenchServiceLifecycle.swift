import Foundation

#if os(macOS)
/// Service-owned evidence only. A socket client cannot claim a GUI consumer or
/// prove the absence of one; the default is deliberately unknown.
enum WorkbenchGUIConsumerEvidence: Equatable {
    case unknown
    case verified(Set<String>)
}

struct WorkbenchServiceLifecycleSnapshot: Equatable {
    enum State: String { case healthy, busy, draining }
    let state: State
    let activeJobIDs: [String]
    let authenticatedConnections: Int
    let guiConsumers: WorkbenchGUIConsumerEvidence
}

public struct WorkbenchServiceLifecycleResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: String
    public let state: String
    public let activeJobIDs: [String]
    public let interruptedJobIDs: [String]
    public let authenticatedConnections: Int
    public let guiConsumersKnown: Bool
    public let guiConsumers: [String]

    init(snapshot: WorkbenchServiceLifecycleSnapshot, interruptedJobIDs: [String] = [],
         drained: Bool = false) {
        schemaVersion = 1
        kind = drained ? "drain" : "status"
        state = drained ? "drained" : snapshot.state.rawValue
        activeJobIDs = snapshot.activeJobIDs
        self.interruptedJobIDs = interruptedJobIDs
        authenticatedConnections = snapshot.authenticatedConnections
        switch snapshot.guiConsumers {
        case .unknown:
            guiConsumersKnown = false; guiConsumers = []
        case .verified(let consumers):
            guiConsumersKnown = true; guiConsumers = consumers.sorted()
        }
    }

    func validate(for method: String) throws {
        guard schemaVersion == 1, activeJobIDs == activeJobIDs.sorted(),
              interruptedJobIDs == interruptedJobIDs.sorted(),
              Set(activeJobIDs).count == activeJobIDs.count,
              Set(interruptedJobIDs).count == interruptedJobIDs.count,
              guiConsumers == guiConsumers.sorted(),
              (guiConsumersKnown || guiConsumers.isEmpty),
              (0...128).contains(authenticatedConnections) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        switch method {
        case "service.lifecycle":
            guard kind == "status", ["healthy", "busy", "draining"].contains(state),
                  interruptedJobIDs.isEmpty else { throw WorkbenchIPCError(.invalidRequest) }
        case "service.drain", "service.prepareRemoval":
            guard kind == "drain", state == "drained", activeJobIDs.isEmpty else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            if method == "service.prepareRemoval", !interruptedJobIDs.isEmpty {
                throw WorkbenchIPCError(.invalidRequest)
            }
        default: throw WorkbenchIPCError(.invalidRequest)
        }
    }
}

enum WorkbenchServiceLifecycleError: Error, Equatable {
    case draining
    case duplicateJob
    case busy
}

enum WorkbenchJobCompletion: Equatable { case completed, interrupted }

/// Tracks jobs admitted by the broker and supports a bounded, cooperative
/// drain. A timed-out drain stays closed to new jobs and never reports success.
/// The caller must stop the broker only after drain succeeds.
final class WorkbenchServiceLifecycle {
    private struct Job {
        let token: UUID
        let cancel: () -> Void
    }
    private let condition = NSCondition()
    private let uptime: () -> TimeInterval
    private var jobs: [String: Job] = [:]
    private var interruptedJobIDs = Set<String>()
    private var draining = false
    private var removalReservation: (owner: UUID, deadline: TimeInterval)?
    private var removalCommitted = false
    private var exclusiveWorkspaceJob: (id: String, token: UUID)?
    private var connections = 0
    private var guiConsumers: WorkbenchGUIConsumerEvidence = .unknown
    private var guiLeases: [String: TimeInterval] = [:]
    private var observedVerifiedGUIRegistration = false
    private var lastActivity: TimeInterval

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
        lastActivity = uptime()
    }

    func beginJob(id: String, cancel: @escaping () -> Void) throws -> UUID {
        condition.lock(); defer { condition.unlock() }
        expireRemovalReservation()
        guard !draining, exclusiveWorkspaceJob == nil else {
            throw WorkbenchServiceLifecycleError.draining
        }
        // A broker job key may contain a maximum-length wire request ID and
        // its 37-byte per-session suffix. Standalone host jobs remain valid.
        guard !id.isEmpty, id.utf8.count <= 137,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || [45, 46, 95].contains($0) }),
              jobs[id] == nil else { throw WorkbenchServiceLifecycleError.duplicateJob }
        let token = UUID()
        jobs[id] = Job(token: token, cancel: cancel)
        lastActivity = uptime()
        return token
    }

    /// Snapshot and relocation must not copy while another admitted broker
    /// operation can still publish workspace state. Reserve admission first,
    /// then wait for every earlier job to finish before entering the domain.
    func beginExclusiveWorkspaceJob(id: String, token: UUID,
                                    timeout: TimeInterval = 30) throws {
        guard timeout > 0, timeout <= 30 else { throw WorkbenchServiceLifecycleError.busy }
        condition.lock(); defer { condition.unlock() }
        guard !draining, exclusiveWorkspaceJob == nil,
              jobs[id]?.token == token else { throw WorkbenchServiceLifecycleError.busy }
        exclusiveWorkspaceJob = (id, token)
        let deadline = uptime() + timeout
        while jobs.count != 1 {
            if draining || jobs[id]?.token != token || uptime() >= deadline {
                exclusiveWorkspaceJob = nil
                condition.broadcast()
                throw WorkbenchServiceLifecycleError.busy
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(0.1,
                max(0, deadline - uptime()))))
        }
    }

    func endExclusiveWorkspaceJob(id: String, token: UUID) {
        condition.lock(); defer { condition.unlock() }
        if exclusiveWorkspaceJob?.id == id && exclusiveWorkspaceJob?.token == token {
            exclusiveWorkspaceJob = nil
            condition.broadcast()
        }
    }

    func finishJob(id: String, token: UUID, completion: WorkbenchJobCompletion = .completed) {
        condition.lock(); defer { condition.unlock() }
        guard jobs[id]?.token == token else { return }
        jobs[id] = nil
        if exclusiveWorkspaceJob?.id == id && exclusiveWorkspaceJob?.token == token {
            exclusiveWorkspaceJob = nil
        }
        if draining && completion == .interrupted { interruptedJobIDs.insert(id) }
        lastActivity = uptime()
        condition.broadcast()
    }

    func authenticatedConnectionOpened() {
        condition.lock(); defer { condition.unlock() }
        connections += 1
        lastActivity = uptime()
    }

    func authenticatedConnectionClosed() {
        condition.lock(); defer { condition.unlock() }
        connections = max(0, connections - 1)
        lastActivity = uptime()
        condition.broadcast()
    }

    /// Called only by a future trusted host-owned GUI identity adapter. No
    /// wire method or caller-supplied PID is accepted as consumer evidence.
    func setGUIConsumerEvidence(_ evidence: WorkbenchGUIConsumerEvidence) {
        condition.lock(); defer { condition.unlock() }
        guiConsumers = evidence
        lastActivity = uptime()
    }

    func registerVerifiedGUIConsumer(_ id: String) throws {
        condition.lock(); defer { condition.unlock() }
        expireRemovalReservation()
        expireGUILeases()
        guard !draining else { throw WorkbenchIPCError(.serviceBusy) }
        guard UUID(uuidString: id) != nil, guiLeases[id] == nil,
              guiLeases.count < 128 else { throw WorkbenchIPCError(.invalidRequest) }
        guiLeases[id] = uptime() + 30
        observedVerifiedGUIRegistration = true
        guiConsumers = .verified(Set(guiLeases.keys))
        lastActivity = uptime()
        condition.broadcast()
    }

    func renewVerifiedGUIConsumer(_ id: String) throws {
        condition.lock(); defer { condition.unlock() }
        expireRemovalReservation()
        expireGUILeases()
        guard !draining else { throw WorkbenchIPCError(.serviceBusy) }
        guard guiLeases[id] != nil else { throw WorkbenchIPCError(.incompatibleOwner) }
        guiLeases[id] = uptime() + 30
        lastActivity = uptime()
    }

    func releaseVerifiedGUIConsumer(_ id: String) {
        condition.lock(); defer { condition.unlock() }
        guiLeases[id] = nil
        if observedVerifiedGUIRegistration { guiConsumers = .verified(Set(guiLeases.keys)) }
        lastActivity = uptime()
        condition.broadcast()
    }

    private func expireGUILeases() {
        let now = uptime()
        guiLeases = guiLeases.filter { $0.value > now }
        if observedVerifiedGUIRegistration { guiConsumers = .verified(Set(guiLeases.keys)) }
    }

    func snapshot() -> WorkbenchServiceLifecycleSnapshot {
        condition.lock(); defer { condition.unlock() }
        expireRemovalReservation()
        expireGUILeases()
        return .init(state: draining ? .draining : (jobs.isEmpty && guiLeases.isEmpty ? .healthy : .busy),
                     activeJobIDs: jobs.keys.sorted(), authenticatedConnections: connections,
                     guiConsumers: guiConsumers)
    }

    var cancelRequested: Bool {
        condition.lock(); defer { condition.unlock() }
        expireRemovalReservation()
        return draining
    }

    /// Reserve only idle admission. Unlike drain, this never requests job
    /// cancellation. Native process evidence is checked by the package caller
    /// while this connection-owned, bounded reservation is held.
    func prepareRemoval(owner: UUID) throws {
        condition.lock(); defer { condition.unlock() }
        expireRemovalReservation()
        expireGUILeases()
        guard !draining, jobs.isEmpty, exclusiveWorkspaceJob == nil,
              guiLeases.isEmpty else { throw WorkbenchServiceLifecycleError.busy }
        draining = true
        removalReservation = (owner, uptime() + 10)
    }

    /// Only the reserving connection can commit, and an expired reservation
    /// never falls back to a cancelling drain.
    func commitRemoval(owner: UUID) throws {
        condition.lock(); defer { condition.unlock() }
        expireRemovalReservation()
        expireGUILeases()
        guard removalReservation?.owner == owner, !removalCommitted,
              jobs.isEmpty, guiLeases.isEmpty else { throw WorkbenchServiceLifecycleError.busy }
        removalCommitted = true
    }

    func cancelPreparedRemoval(owner: UUID) {
        condition.lock(); defer { condition.unlock() }
        // The server calls this only while shutdown has not been requested,
        // including failure to encode/send the committed stop response.
        guard removalReservation?.owner == owner else { return }
        removalReservation = nil
        removalCommitted = false
        draining = false
        lastActivity = uptime()
        condition.broadcast()
    }

    private func expireRemovalReservation() {
        if let reservation = removalReservation, !removalCommitted, uptime() >= reservation.deadline {
            removalReservation = nil
            draining = false
            lastActivity = uptime()
            condition.broadcast()
        }
    }

    func drain(timeout: TimeInterval) throws -> [String] {
        guard timeout > 0, timeout <= 30 else { throw WorkbenchServiceLifecycleError.busy }
        condition.lock()
        expireRemovalReservation()
        guard removalReservation == nil else {
            condition.unlock()
            throw WorkbenchServiceLifecycleError.busy
        }
        draining = true
        let cancellations = jobs.values.map(\.cancel)
        condition.unlock()
        for cancel in cancellations { DispatchQueue.global(qos: .utility).async(execute: cancel) }
        let deadline = uptime() + timeout
        condition.lock(); defer { condition.unlock() }
        expireGUILeases()
        while !jobs.isEmpty || !guiLeases.isEmpty {
            let remaining = deadline - uptime()
            guard remaining > 0 else { throw WorkbenchServiceLifecycleError.busy }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.1)))
            expireGUILeases()
        }
        let interrupted = interruptedJobIDs.sorted()
        interruptedJobIDs.removeAll()
        return interrupted
    }

    /// A service-owned timer may exit only after a verified empty consumer
    /// inventory, no authenticated clients, no jobs, and a full quiet interval.
    func mayExitIdle(after quietSeconds: TimeInterval) -> Bool {
        guard quietSeconds >= 30 else { return false }
        condition.lock(); defer { condition.unlock() }
        expireGUILeases()
        guard !draining, jobs.isEmpty, connections == 0,
              guiConsumers == .verified([]) else { return false }
        return uptime() - lastActivity >= quietSeconds
    }
}
#endif
