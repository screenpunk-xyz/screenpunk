import Foundation
import ScreenpunkCore

/// Foreground-only device execution. The Mac is never an event proxy. Source
/// tasks and return timers outlive page reloads, but never dashboard replacement.
@MainActor
final class DashboardEventRuntime {
    let manifest: DashboardManifest
    private let homeAssistant: HomeAssistantDeviceRuntime?
    private let connections: ConnectionRuntime?
    private let revision: String
    private var engine: EventNavigationEngine
    private var settings: DeviceSettings
    private var tasks: [Task<Void, Never>] = []
    private var timer: Task<Void, Never>?
    private var epoch = UUID()
    private var unhealthySources = Set<String>()
    private(set) var running = false
    private(set) var settingsApplied = true
    var onPage: ((DashboardPage) -> Void)?
    var onStatus: (([String: Any]) -> Void)?
    var onHealth: ((Bool) -> Void)?

    init(manifest: DashboardManifest, revision: String, settings: DeviceSettings,
         homeAssistant: HomeAssistantDeviceRuntime?, connections: ConnectionRuntime?) throws {
        self.manifest = manifest; self.revision = revision
        self.homeAssistant = homeAssistant; self.connections = connections
        let reconciled = Self.reconciled(settings, manifest: manifest)
        self.settings = reconciled
        settingsApplied = Self.navigationPreferencesEqual(settings, reconciled, dashboardId: manifest.dashboardId)
        engine = try EventNavigationEngine(manifest: manifest,
            startingPageId: reconciled.startingPageByDashboard[manifest.dashboardId],
            overrides: reconciled.eventRuleOverrides[manifest.dashboardId] ?? [:])
    }

    var page: DashboardPage { manifest.resolvedPages.first { $0.id == engine.pageId } ?? manifest.resolvedPages[0] }
    var status: [String: Any] {
        var value: [String: Any] = ["pageId": engine.pageId]
        if let id = engine.activeRuleId { value["activeRuleId"] = id }
        if let date = engine.returnAt { value["returnAt"] = ISO8601DateFormatter().string(from: date) }
        return value
    }

    func update(settings value: DeviceSettings) {
        let reconciled = Self.reconciled(value, manifest: manifest)
        settingsApplied = Self.navigationPreferencesEqual(value, reconciled, dashboardId: manifest.dashboardId)
        let previousRules = settings.eventRuleOverrides[manifest.dashboardId] ?? [:]
        let nextRules = reconciled.eventRuleOverrides[manifest.dashboardId] ?? [:]
        // Brightness and starting-page edits cannot invalidate an active event's
        // return timer. Starting-page changes take effect on the next app launch.
        settings = reconciled
        guard previousRules != nextRules else { return }
        let currentPage = engine.pageId
        guard var replacement = try? EventNavigationEngine(manifest: manifest, startingPageId: currentPage,
                overrides: nextRules) else { settingsApplied = false; return }
        _ = replacement.manualNavigate(pageId: currentPage)
        let wasRunning = running
        stop(); engine = replacement
        if wasRunning { start() }
        publish(changed: false)
    }

    private static func navigationPreferencesEqual(_ lhs: DeviceSettings, _ rhs: DeviceSettings, dashboardId: String) -> Bool {
        lhs.startingPageByDashboard[dashboardId] == rhs.startingPageByDashboard[dashboardId]
            && (lhs.eventRuleOverrides[dashboardId] ?? [:]) == (rhs.eventRuleOverrides[dashboardId] ?? [:])
    }

    /// Author permission changes always win over saved user preferences. Drop
    /// only invalid overrides and keep the dashboard usable after an update.
    static func reconciled(_ settings: DeviceSettings, manifest: DashboardManifest) -> DeviceSettings {
        var result = settings
        if let page = result.startingPageByDashboard[manifest.dashboardId], !manifest.resolvedPages.contains(where: { $0.id == page }) {
            result.startingPageByDashboard.removeValue(forKey: manifest.dashboardId)
        }
        let overrides = settings.eventRuleOverrides[manifest.dashboardId] ?? [:]
        result.eventRuleOverrides[manifest.dashboardId] = overrides.filter { id, value in
            (try? EventNavigationEngine(manifest: manifest, overrides: [id: value])) != nil
        }
        return result
    }

    func start() {
        guard !running else { return }; running = true; epoch = UUID()
        let currentEpoch = epoch
        // Share one subscription across rules for the same source, so condition
        // filters cannot replace each other's underlying socket.
        let rules = manifest.eventRules ?? []
        var groups: [String: [ManifestEventRule]] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for rule in rules {
            guard (settings.eventRuleOverrides[manifest.dashboardId]?[rule.id] ?? rule.defaults).enabled else { continue }
            guard let data = try? encoder.encode(rule.source) else { continue }
            groups[data.base64EncodedString(), default: []].append(rule)
        }
        for rules in groups.values {
            guard let source = rules.first?.source else { continue }
            tasks.append(Task { [weak self] in
                guard let self else { return }
                if source.mode == .poll { await self.poll(source, rules: rules, epoch: currentEpoch) }
                else { await self.listen(source, rules: rules, epoch: currentEpoch) }
            })
        }
        scheduleReturn()
    }

    func stop() {
        running = false; epoch = UUID()
        for task in tasks { task.cancel() }; tasks.removeAll()
        timer?.cancel(); timer = nil
    }

    @discardableResult func open(pageId: String) -> Bool {
        guard manifest.resolvedPages.contains(where: { $0.id == pageId }) else { return false }
        let changed = engine.manualNavigate(pageId: pageId)
        publish(changed: changed); return true
    }

    func manualNavigation(pageId: String) {
        _ = engine.manualNavigate(pageId: pageId)
        publish(changed: false)
    }

    private func isCurrent(_ value: UUID) -> Bool { running && epoch == value && !Task.isCancelled }

    private func poll(_ source: EventSource, rules: [ManifestEventRule], epoch: UUID) async {
        var baseline = true
        while isCurrent(epoch) {
            do {
                let result = try await read(source, operation: source.operation)
                guard isCurrent(epoch) else { return }
                reportHealth(source, healthy: !result.stale)
                if !result.stale {
                    consume(result.body, rules: rules, baseline: baseline, homeStates: source.alias == "home")
                    baseline = false
                } else { baseline = true }
            } catch {
                guard isCurrent(epoch) else { return }
                baseline = true; reportHealth(source, healthy: false)
            }
            try? await Task.sleep(nanoseconds: UInt64(max(5, source.pollIntervalSeconds ?? 30)) * 1_000_000_000)
        }
    }

    private func listen(_ source: EventSource, rules: [ManifestEventRule], epoch: UUID) async {
        var retrySeconds: UInt64 = 1
        while isCurrent(epoch) {
            do {
                if source.alias == "home", let homeAssistant {
                    let stream = try await homeAssistant.subscribeStates(revision: revision, alias: source.alias,
                        operation: source.operation, parameters: try parameters(source))
                    for try await update in stream {
                        guard isCurrent(epoch) else { return }
                        retrySeconds = 1; reportHealth(source, healthy: true)
                        consume(update.data, rules: rules, baseline: update.isSnapshot, homeStates: update.isSnapshot)
                    }
                } else if let connections {
                    let connectedAt = Date()
                    var needsBaseline = source.refreshOperation == nil
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let consumer = "navigation:" + (try encoder.encode(source)).base64EncodedString()
                    let id = try await connections.subscribe(alias: source.alias, operation: source.operation, parameters: try parameters(source), consumer: consumer)
                    do {
                        if let operation = source.refreshOperation {
                            let result = try await read(source, operation: operation, alias: source.refreshAlias ?? source.alias)
                            guard !result.stale else { throw ConnectionFailure.deviceOffline }
                            guard isCurrent(epoch) else { await connections.unsubscribe(id: id); return }
                            consume(result.body, rules: rules, baseline: true)
                        }
                        try await withTaskCancellationHandler(operation: {
                            while isCurrent(epoch) {
                                let data = try await connections.receive(id: id)
                                guard isCurrent(epoch) else { break }
                                retrySeconds = 1; reportHealth(source, healthy: true)
                                consume(data, rules: rules, baseline: needsBaseline, notBefore: connectedAt)
                                needsBaseline = false
                            }
                        }, onCancel: { Task { await connections.unsubscribe(id: id) } })
                        await connections.unsubscribe(id: id)
                    } catch { await connections.unsubscribe(id: id); throw error }
                } else { throw ConnectionFailure.permissionRequired }
            } catch {
                guard isCurrent(epoch) else { return }; reportHealth(source, healthy: false)
                // No credential / permission retries. Reprovisioning rebuilds the host.
                if error as? ConnectionFailure == .permissionRequired { return }
            }
            guard isCurrent(epoch) else { return }
            try? await Task.sleep(nanoseconds: (retrySeconds * 1_000_000_000) + UInt64.random(in: 0...250_000_000))
            retrySeconds = min(retrySeconds * 2, 60)
        }
    }

    private func read(_ source: EventSource, operation: String, alias: String? = nil) async throws -> ConnectionHTTPResult {
        let alias = alias ?? source.alias
        if alias == "home", let homeAssistant {
            guard operation == "getStates" else { throw ConnectionFailure.permissionRequired }
            return try await homeAssistant.request(revision: revision, alias: alias, operation: operation, parameters: try parameters(source))
        }
        guard let connections else { throw ConnectionFailure.permissionRequired }
        return try await connections.requestRead(alias: alias, operation: operation, parameters: try parameters(source))
    }

    private func parameters(_ source: EventSource) throws -> [String: String] {
        try source.parameters.mapValues { value in
            switch value {
            case .string(let string): return string
            case .number(let number): guard number.isFinite else { throw ConnectionFailure.validationFailed }; return String(number)
            case .bool(let flag): return flag ? "true" : "false"
            case .null: throw ConnectionFailure.validationFailed
            }
        }
    }

    private func consume(_ data: Data, rules: [ManifestEventRule], baseline: Bool, homeStates: Bool = false, notBefore: Date? = nil) {
        guard data.count <= 1024 * 1024, let object = try? JSONSerialization.jsonObject(with: data) else { return }
        let payloads: [[String: Any]]
        if homeStates, let states = object as? [[String: Any]] {
            payloads = states.compactMap { state in
                guard let entity = state["entity_id"] as? String else { return nil }
                return ["entity_id": entity, "new_state": state, "old_state": NSNull()]
            }
        } else if let array = object as? [[String: Any]] { payloads = array }
        else if let object = object as? [String: Any] { payloads = [object] }
        else { return }
        var changed = false
        for payload in payloads {
            for rule in rules {
                changed = engine.receive(ruleId: rule.id, payload: payload, now: Date(), isBaseline: baseline && (rule.condition != nil || notBefore == nil), notBefore: notBefore) || changed
            }
        }
        publish(changed: changed)
    }

    private func reportHealth(_ source: EventSource, healthy: Bool) {
        guard manifest.connections.first(where: { $0.alias == source.alias })?.required == true else { return }
        let key = source.alias + ":" + source.operation
        if healthy { unhealthySources.remove(key) } else { unhealthySources.insert(key) }
        onHealth?(unhealthySources.isEmpty)
    }

    private func publish(changed: Bool) {
        if changed { onPage?(page) }
        onStatus?(status); scheduleReturn()
    }

    private func scheduleReturn() {
        timer?.cancel(); timer = nil
        guard running, let date = engine.returnAt else { return }
        let generation = engine.generation, expectedEpoch = epoch
        timer = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.isCurrent(expectedEpoch) else { return }
            self.publish(changed: self.engine.advance(now: Date(), generation: generation))
        }
    }
}
