import Foundation
import Darwin
import CoreServices
import ScreenpunkController

/// Only local events wake this loop. A parked failed request is retried by a new event/UUID,
/// never by a timer, and acknowledging an old request cannot remove a newer queued change.
enum WorkbenchCloudSyncEventLoop {
    enum Wake: Sendable { case request, localChange }
    static func run(events: AsyncStream<Wake>,
                    load: @escaping @Sendable () throws -> ControllerCloudScreenSyncRequest?,
                    localChange: @escaping @Sendable () async throws -> Void,
                    process: @escaping @Sendable (ControllerCloudScreenSyncRequest) async throws -> Bool,
                    acknowledge: @escaping @Sendable (String) throws -> Void,
                    idle: @escaping @Sendable () async -> Void = {},
                    failed: @escaping @Sendable () -> Void = {}) async {
        var lastAttempt: String?
        for await wake in events {
            if Task.isCancelled { break }
            do {
                // Production coalesces filesystem flags separately so a burst cannot drop a local change.
                _ = wake
                try await localChange()
                while !Task.isCancelled {
                    guard let request = try load() else { await idle(); break }
                    guard request.requestId != lastAttempt else { break }
                    let delay = request.notBefore.timeIntervalSinceNow
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(min(delay, 2) * 1_000_000_000))
                        continue // A concurrent writer may have extended debounce/unioned more IDs.
                    }
                    lastAttempt = request.requestId
                    if try await process(request) { try acknowledge(request.requestId) }
                    else { failed() }
                    // A failed unchanged request stays parked. A newer event remains eligible.
                }
            } catch is CancellationError { if Task.isCancelled { break }; await idle() }
            catch { failed() }
        }
    }
}

/// File descriptor wake for policy/outbox plus FSEvents for the selected local workspace.
/// No source bytes are read by this observer and no network operation is scheduled by a timer.
final class WorkbenchCloudSyncEventSource: @unchecked Sendable {
    private final class LocalFlag: @unchecked Sendable {
        private let lock = NSLock(); private var pending = false
        func set() { lock.lock(); pending = true; lock.unlock() }
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; let result = pending; pending = false; return result }
    }
    private final class Signal {
        let send: @Sendable () -> Void
        init(_ send: @escaping @Sendable () -> Void) { self.send = send }
    }
    let events: AsyncStream<WorkbenchCloudSyncEventLoop.Wake>
    private let continuation: AsyncStream<WorkbenchCloudSyncEventLoop.Wake>.Continuation
    private let localFlag = LocalFlag()
    private let queue = DispatchQueue(label: "xyz.screenpunk.cloud-sync.local-events")
    private var directorySource: DispatchSourceFileSystemObject?
    private var stream: FSEventStreamRef?
    private var workspacePath: String?
    private var policyObserver: (@Sendable () -> Void)?
    func observePolicy(_ callback: @escaping @Sendable () -> Void) { queue.sync { policyObserver = callback } }
    init(root: URL) throws {
        var continuation: AsyncStream<WorkbenchCloudSyncEventLoop.Wake>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
        self.continuation = continuation
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(root.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ControllerCloudError.invalidConfiguration }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in continuation.yield(.request); self?.policyObserver?() }
        source.setCancelHandler { close(fd) }
        directorySource = source; source.resume()
        continuation.yield(.request) // One startup catch-up for already durable requests, not a poll.
    }
    func takeLocalChange() -> Bool { localFlag.take() }
    func watchWorkspace(_ path: String?) {
        queue.sync {
            guard path != workspacePath else { return }
            if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
            stream = nil; workspacePath = path
            guard let path else { return }
            let continuation = self.continuation, flag = self.localFlag
            let signal = Signal { flag.set(); continuation.yield(.request) }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(signal).toOpaque(),
                retain: { pointer in guard let pointer else { return nil }; return UnsafeRawPointer(Unmanaged<Signal>.fromOpaque(pointer).retain().toOpaque()) },
                release: { pointer in if let pointer { Unmanaged<Signal>.fromOpaque(pointer).release() } }, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info, count > 0 else { return }
                // Ignore private settings/history churn unless it can affect a source/package Screen.
                let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                if changed.contains(where: { $0.contains("/Screens/") || $0.contains("/Workbench/History/") }) {
                    Unmanaged<Signal>.fromOpaque(info).takeUnretainedValue().send()
                }
            }
            guard let created = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); return }
            stream = created
        }
    }
    deinit {
        continuation.finish(); directorySource?.cancel()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
