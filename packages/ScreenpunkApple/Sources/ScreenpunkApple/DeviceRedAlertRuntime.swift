import Foundation
import ScreenpunkCore

#if canImport(Network) && canImport(Security)
/// Separate from the WebView: a screen switch cannot dispose this subscription.
@MainActor final class DeviceRedAlertRuntime {
    private weak var server: DeviceLANServer?
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var scope: HomeAssistantDeviceRuntime.Scope?
    private var engine = RedAlertNavigation()
    private var enabled = false
    private var pendingSelection: String?
    private var service: HomeAssistantDeviceRuntime?
    private var checkpointURL: URL? { server?.store?.root.appendingPathComponent("red-alert.json") }
    private struct Checkpoint: Codable { var owner: String; var grantSet: String?; var target: String; var navigation: RedAlertNavigation; var pendingSelection: String? }

    init(server: DeviceLANServer) { self.server = server }

    func update(active: Bool) {
        enabled = active
        let next = server?.redAlertScope()
        if next != scope {
            stop(); scope = next; engine = .init(); pendingSelection = nil
            if let next, let url = checkpointURL, let data = try? Data(contentsOf: url),
               let saved = try? JSONDecoder().decode(Checkpoint.self, from: data),
               saved.owner == next.owner, saved.grantSet == next.grantSet, saved.target == next.dashboardId {
                engine = saved.navigation; pendingSelection = saved.pendingSelection
            }
        }
        guard active, let scope, let server else { stop(); return }
        apply { $0.expire(selected: server.screenSet?.selectedDashboardId ?? "", now: Date()) }
        guard task == nil else { return }
        let service = HomeAssistantDeviceRuntime(vault: server.homeAssistantVault) { [weak server] in server?.redAlertScope() }
        self.service = service
        task = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    let updates = try await service.subscribeStates(revision: scope.revision)
                    for try await update in updates {
                        guard !Task.isCancelled, let self, self.enabled, self.scope == scope else { return }
                        delay = 1
                        let object = try JSONSerialization.jsonObject(with: update.data)
                        let states: [[String: Any]]
                        if update.isSnapshot { states = object as? [[String: Any]] ?? [] }
                        else { states = [(object as? [String: Any])?["new_state"] as? [String: Any]].compactMap { $0 } }
                        for state in states {
                            self.receive(state: state, now: Date())
                        }
                    }
                } catch { if Task.isCancelled { return } }
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                delay = min(delay * 2, 60)
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.scope == scope else { return }
                self.apply { $0.expire(selected: server.screenSet?.selectedDashboardId ?? "", now: Date()) }
            }
        }
    }

    func receive(state: [String: Any], now: Date) {
        guard let scope, let server else { return }
        apply { $0.receive(state: state, target: scope.dashboardId, selected: server.screenSet?.selectedDashboardId ?? "", now: now) }
    }

    func expire(now: Date) {
        guard let server else { return }
        apply { $0.expire(selected: server.screenSet?.selectedDashboardId ?? "", now: now) }
    }

    func manualSelection() { pendingSelection = nil; apply { $0.manualSelection(); return nil } }

    private func apply(_ change: (inout RedAlertNavigation) -> String?) {
        guard let server, let scope, server.redAlertScope() == scope else { return }
        var next = engine
        let selection = change(&next)
        guard next != engine || selection != nil || pendingSelection != nil else { return }
        do {
            let pending = selection ?? pendingSelection
            if let url = checkpointURL {
                let saved = Checkpoint(owner: scope.owner, grantSet: scope.grantSet, target: scope.dashboardId, navigation: next, pendingSelection: pending)
                try JSONEncoder().encode(saved).write(to: url, options: .atomic)
            }
            engine = next; pendingSelection = pending
            if let selection = pending, server.screenSet?.screens.contains(where: { $0.revision.dashboardId == selection }) == true {
                try server.selectScreen(selection)
            }
            pendingSelection = nil
            if let url = checkpointURL {
                try JSONEncoder().encode(Checkpoint(owner: scope.owner, grantSet: scope.grantSet, target: scope.dashboardId, navigation: engine, pendingSelection: nil)).write(to: url, options: .atomic)
            }
        } catch { /* Preserve the old engine and retry on the next update/tick. */ }
    }

    private func stop() {
        task?.cancel(); task = nil; timer?.cancel(); timer = nil
        if let service { Task { await service.cancelPending() } }; service = nil
    }
    deinit { task?.cancel(); timer?.cancel() }
}
#endif
