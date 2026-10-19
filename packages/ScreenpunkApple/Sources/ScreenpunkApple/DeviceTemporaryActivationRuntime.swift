import Foundation
import ScreenpunkCore

#if canImport(Network) && canImport(Security)
/// Separate from the WebView: a screen switch cannot dispose this subscription.
@MainActor final class DeviceTemporaryActivationRuntime {
    private weak var server: DeviceLANServer?
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var scope: HomeAssistantDeviceRuntime.Scope?
    private var engine = TemporaryActivationNavigation()
    private var enabled = false
    private(set) var isSuspendedForReset = false
    private var generation = UUID()
    private var status = DeviceTemporaryActivationStatus() {
        didSet { if !isSuspendedForReset { try? server?.updateTemporaryActivationStatus(status) } }
    }
    private var pendingSelection: String?
    private var service: HomeAssistantDeviceRuntime?
    private var checkpointURL: URL? { server?.store?.root.appendingPathComponent("temporary-activation.json") }
    private struct Checkpoint: Codable { var owner: String; var grantSet: String?; var target: String; var configuration: TemporaryActivationConfiguration; var navigation: TemporaryActivationNavigation; var pendingSelection: String? }

    private let makeService: (DeviceLANServer) -> HomeAssistantDeviceRuntime
    private let pollNanoseconds: UInt64
    init(server: DeviceLANServer, pollNanoseconds: UInt64 = 2_000_000_000,
         makeService: @escaping (DeviceLANServer) -> HomeAssistantDeviceRuntime = { server in
             HomeAssistantDeviceRuntime(vault: server.homeAssistantVault) { [weak server] in server?.temporaryActivationScope() }
         }) {
        self.server = server; self.pollNanoseconds = pollNanoseconds; self.makeService = makeService
    }

    func update(active: Bool) {
        guard !isSuspendedForReset else { return }
        enabled = active
        status.foreground = active
        let next = server?.temporaryActivationScope()
        if next != scope {
            stop(); scope = next; engine = .init(); pendingSelection = nil
            if let next, let url = checkpointURL, let data = try? Data(contentsOf: url),
               let saved = try? JSONDecoder().decode(Checkpoint.self, from: data),
               saved.owner == next.owner, saved.grantSet == next.grantSet, saved.target == next.dashboardId, saved.configuration == next.temporaryActivation {
                engine = saved.navigation; pendingSelection = saved.pendingSelection
            }
        }
        status.targetDashboardId = scope?.dashboardId
        guard active, let scope, let server else {
            status.phase = active ? "missing_target_or_grant" : "inactive"
            stop(); return
        }
        apply { $0.expire(selected: server.screenSet?.selectedDashboardId ?? "", now: Date()) }
        guard task == nil else { return }
        let service = makeService(server)
        self.service = service
        let pollNanoseconds = self.pollNanoseconds
        let generation = self.generation
        task = Task { [weak self] in
            var retrySeconds: UInt64 = 1
            while !Task.isCancelled {
                guard self?.current(generation) == true, self?.enabled == true, self?.scope == scope else { return }
                var wait = pollNanoseconds
                do {
                    self?.status.phase = "checking"
                    let data = try await service.readTemporaryActivationState(revision: scope.revision)
                    guard let self, self.current(generation), self.enabled, self.scope == scope else { return }
                    let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    self.receive(state: state, now: Date())
                    retrySeconds = 1
                } catch {
                    guard let self, self.current(generation) else { return }
                    self.status.phase = "retrying"
                    let e = error as NSError
                    self.status.lastError = "\(e.domain):\(e.code)"
                    wait = retrySeconds * 1_000_000_000
                    retrySeconds = min(retrySeconds * 2, 30)
                }
                do { try await Task.sleep(nanoseconds: wait) } catch { return }
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.current(generation), self.scope == scope else { return }
                self.apply { $0.expire(selected: server.screenSet?.selectedDashboardId ?? "", now: Date()) }
            }
        }
    }

    func receive(state: [String: Any], now: Date) {
        guard !isSuspendedForReset, let scope, let configuration = scope.temporaryActivation, let server else { return }
        guard state["entity_id"] as? String == configuration.entityId else { return }
        status.phase = "receiving"; status.lastReceivedAt = now
        status.lastState = state["state"] as? String; status.lastError = nil; status.receivedCount += 1
        apply { $0.receive(state: state, configuration: configuration, target: scope.dashboardId, selected: server.screenSet?.selectedDashboardId ?? "", now: now) }
    }

    func expire(now: Date) {
        guard !isSuspendedForReset, let server else { return }
        apply { $0.expire(selected: server.screenSet?.selectedDashboardId ?? "", now: now) }
    }

    func manualSelection() { guard !isSuspendedForReset else { return }; pendingSelection = nil; apply { $0.manualSelection(); return nil } }

    private func apply(_ change: (inout TemporaryActivationNavigation) -> String?) {
        guard !isSuspendedForReset, let server, let scope, let configuration = scope.temporaryActivation, server.temporaryActivationScope() == scope else { return }
        let generation = self.generation
        var next = engine
        let selection = change(&next)
        guard next != engine || selection != nil || pendingSelection != nil else { return }
        do {
            let pending = selection ?? pendingSelection
            let selected = try server.commitTemporaryActivationSelection(pending, expectedScope: scope, beforeSelection: checkpointMutation {
                if let url = self.checkpointURL {
                    let saved = Checkpoint(owner: scope.owner, grantSet: scope.grantSet, target: scope.dashboardId, configuration: configuration, navigation: next, pendingSelection: pending)
                    try JSONEncoder().encode(saved).write(to: url, options: .atomic)
                }
                self.engine = next; self.pendingSelection = pending
            }, afterSelection: checkpointMutation {
                self.pendingSelection = nil
                if let url = self.checkpointURL {
                    try JSONEncoder().encode(Checkpoint(owner: scope.owner, grantSet: scope.grantSet, target: scope.dashboardId, configuration: configuration, navigation: self.engine, pendingSelection: nil)).write(to: url, options: .atomic)
                }
            })
            if current(generation), selected { status.selectionCount += 1 }
        } catch {
            guard current(generation) else { return }
            status.phase = "selection_failed"
            let e = error as NSError; status.lastError = "\(e.domain):\(e.code)"
        }
    }

    /// Terminal local writer fence; a new runtime instance is required after reset.
    func suspendForReset() {
        guard !isSuspendedForReset else { return }
        isSuspendedForReset = true; generation = UUID(); enabled = false
        stop(); scope = nil; pendingSelection = nil; engine = .init()
    }

    private func current(_ generation: UUID) -> Bool {
        !isSuspendedForReset && self.generation == generation && !Task.isCancelled
    }
    /// Each callback carries the lifetime in which it was prepared.
    func checkpointMutation(_ operation: @escaping () throws -> Void) -> () throws -> Void {
        let generation = self.generation
        return { [weak self] in
            guard let self, self.current(generation) else { throw ConnectionFailure.permissionRequired }
            try operation()
        }
    }

    private func stop() {
        task?.cancel(); task = nil; timer?.cancel(); timer = nil
        if let service { Task { await service.cancelPending() } }; service = nil
    }
    deinit { task?.cancel(); timer?.cancel() }
}
#endif
