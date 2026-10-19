import Foundation

@main
struct MacBrokerApplyJournalTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenpunk-apply-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MacBrokerApplyJournal(url: root.appendingPathComponent("attempt.json"))
        let initiallyLoaded = try journal.load()
        precondition(initiallyLoaded == nil)
        var record = MacBrokerApplyJournal.Record(workspaceId: "workspace-a", selectionGeneration: 3,
            deviceId: "device-a",
            planId: "plan-a", planHash: "hash-a", idempotencyKey: "same-key",
            operationId: nil, phase: .submitting)
        try journal.begin(record)
        let submitting = try journal.load()
        precondition(submitting == record && record.blocksNewApply)
        let initial = record
        record.phase = .unknown
        try journal.transition(from: initial, to: record)
        let unknown = try journal.load()
        precondition(unknown == record && record.blocksNewApply)
        let uncertain = record
        record.operationId = "operation-a"; record.phase = .sending
        try journal.transition(from: uncertain, to: record)
        let sending = try journal.load()
        precondition(sending == record && record.blocksNewApply)
        let inFlight = record
        record.phase = .active
        try journal.transition(from: inFlight, to: record)
        let active = try journal.load()
        precondition(active == record && !record.blocksNewApply)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: journal.url)
        try FileManager.default.createSymbolicLink(at: journal.url, withDestinationURL: outside)
        do { _ = try journal.load(); fatalError("symlink read accepted") }
        catch MacBrokerApplyJournal.Failure.unsafePath { }
        do { try journal.begin(record); fatalError("symlink write accepted") }
        catch MacBrokerApplyJournal.Failure.unsafePath { }
        let outsideText = try String(contentsOf: outside, encoding: .utf8)
        precondition(outsideText == "untouched")

        let shared = root.appendingPathComponent("two-processes.json")
        let first = MacBrokerApplyJournal(url: shared)
        let second = MacBrokerApplyJournal(url: shared)
        let firstBefore = try first.load(), secondBefore = try second.load()
        precondition(firstBefore == nil && secondBefore == nil)
        let firstAttempt = MacBrokerApplyJournal.Record(workspaceId: "workspace-a", selectionGeneration: 3,
            deviceId: "device-a", planId: "first", planHash: "first-hash", idempotencyKey: "first-key",
            operationId: nil, phase: .submitting)
        var secondAttempt = firstAttempt
        secondAttempt.planId = "second"; secondAttempt.idempotencyKey = "second-key"
        try first.begin(firstAttempt)
        do { try second.begin(secondAttempt); fatalError("second GUI overwrote unresolved Apply") }
        catch MacBrokerApplyJournal.Failure.conflict { }
        let afterConflict = try first.load()
        precondition(afterConflict == firstAttempt)
        var terminal = firstAttempt
        terminal.operationId = "operation-first"; terminal.phase = .active
        try first.transition(from: firstAttempt, to: terminal)
        try second.begin(secondAttempt)
        do { try first.transition(from: firstAttempt, to: terminal); fatalError("stale status overwrote second Apply") }
        catch MacBrokerApplyJournal.Failure.conflict { }
        let afterStale = try second.load()
        precondition(afterStale == secondAttempt)

        // Independent instances race after both have observed an empty slot.
        let concurrentURL = root.appendingPathComponent("concurrent.json")
        let ready = DispatchSemaphore(value: 0), start = DispatchSemaphore(value: 0)
        let group = DispatchGroup(), resultLock = NSLock()
        var admitted = 0, conflicts = 0
        for attempt in [firstAttempt, secondAttempt] {
            group.enter()
            DispatchQueue.global().async {
                let instance = MacBrokerApplyJournal(url: concurrentURL)
                ready.signal(); start.wait()
                do {
                    try instance.begin(attempt)
                    resultLock.lock(); admitted += 1; resultLock.unlock()
                } catch MacBrokerApplyJournal.Failure.conflict {
                    resultLock.lock(); conflicts += 1; resultLock.unlock()
                } catch { fatalError("unexpected concurrent journal error: \(error)") }
                group.leave()
            }
        }
        ready.wait(); ready.wait(); start.signal(); start.signal(); group.wait()
        precondition(admitted == 1 && conflicts == 1)
        print("MacBrokerApplyJournalTest passed")
    }
}
