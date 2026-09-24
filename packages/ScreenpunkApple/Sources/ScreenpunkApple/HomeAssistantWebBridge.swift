import Foundation
import ScreenpunkCore
import WebKit

/// Only the top-level package frame may invoke approved native operations. No
/// origin, credential, path or executable payload is accepted from JavaScript.
@MainActor
final class HomeAssistantWebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private let runtime: HomeAssistantDeviceRuntime?
    private let connections: ConnectionRuntime?
    private let navigation: DashboardEventRuntime?
    private let revision: String
    private let cameras: CameraPlaybackController?
    private let publicReads: PublicReadRuntime?
    private let resources: PublicRasterResources?
    private var publicTasks: [String: Task<Void, Never>] = [:]
    private let onHealth: (Bool) -> Void
    private var tasks: [String: Task<Void, Never>] = [:]
    private var documentGeneration = UUID()
    private var active = true
    private let googleTV = GoogleTVScreenConnection()
    private let googleTVADB = GoogleTVADBScreenConnection()
    private var voiceTapAt: TimeInterval?
    fileprivate func recordVoiceTap() { if active { voiceTapAt = ProcessInfo.processInfo.systemUptime } }
    func installVoiceTapGate(_ controller: WKUserContentController) {
        let world = WKContentWorld.world(name: "ScreenpunkVoiceTap")
        controller.add(GoogleTVTapHandler(self), contentWorld: world, name: "screenpunkVoiceTap")
        controller.addUserScript(WKUserScript(source: """
        document.addEventListener('click', function(event) {
          if (event.isTrusted) window.webkit.messageHandlers.screenpunkVoiceTap.postMessage('tap');
        }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value { voiceTapAt = nil; googleTV.close(); googleTVADB.close() }
        status(navigation?.status ?? [:])
    }

    init(runtime: HomeAssistantDeviceRuntime?, connections: ConnectionRuntime? = nil, navigation: DashboardEventRuntime? = nil,
         revision: String, publicReads: PublicReadRuntime? = nil, resources: PublicRasterResources? = nil, onHealth: @escaping (Bool) -> Void) {
        self.cameras = runtime.map { CameraPlaybackController(resolver: $0, revision: revision) }
        self.publicReads = publicReads; self.resources = resources
        self.runtime = runtime; self.connections = connections; self.navigation = navigation
        self.revision = revision; self.onHealth = onHealth
    }
    func attach(to webView: WKWebView) { self.webView = webView; cameras?.attach(webView) }
    func cancel() {
        voiceTapAt = nil; googleTV.close(); googleTVADB.close()
        documentGeneration = UUID()
        for task in publicTasks.values { task.cancel() }; publicTasks.removeAll(); resources?.clear()
        let reads = publicReads; Task { await reads?.cancel() }
        cameras?.stopAll()
        for task in tasks.values { task.cancel() }; tasks.removeAll()
    }

    func status(_ value: [String: Any]) {
        dispatch(["protocolVersion": 1, "id": "runtime-status", "kind": "event", "method": "runtime.onStatus",
                  "value": ["active": active, "navigation": value, "homeAssistantTransport": "websocket-with-http", "homeAssistantServiceCalls": 1, "cameraPlayback": 1, "publicReadHTTP": 1, "googleTVRemote": 1, "googleTVVoice": 1, "googleTVDirectChannels": 1, "googleTVDirectPower": 1, "macIsRuntimeProxy": false]])
    }

    deinit { let cameras = cameras; Task { @MainActor in cameras?.cancel() } }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url?.absoluteString,
              IsolationEvaluator.isLocalPackageURL(url),
              let body = message.body as? [String: Any], let id = body["id"] as? String, (1...128).contains(id.utf8.count),
              JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 64 * 1024 else { return }
        guard body["protocolVersion"] as? Int == 1, body["kind"] as? String == "request" else {
            reply(id: id, error: "validation_failed"); return
        }
        switch body["method"] as? String {
        case "runtime.ready": reply(id: id, value: NSNull())
        case "runtime.onStatus":
            reply(id: id, value: NSNull()); status(navigation?.status ?? [:])
        case "navigation.get": reply(id: id, value: navigation?.status ?? ["pageId": "default"])
        case "navigation.open":
            guard let parameters = body["parameters"] as? [String: String], parameters.count == 1,
                  let page = parameters["pageId"], let navigation,
                  navigation.manifest.resolvedPages.contains(where: { $0.id == page }) else {
                reply(id: id, error: "permission_required"); return
            }
            // Acknowledge in this document before starting its replacement load.
            reply(id: id, value: NSNull()); _ = navigation.open(pageId: page)
        case "state.get": reply(id: id, value: NSNull())
        case "connections.cancel":
            if let target = (body["parameters"] as? [String: String])?["requestId"] { publicTasks.removeValue(forKey: target)?.cancel(); tasks.removeValue(forKey: target)?.cancel() }
            reply(id: id, value: NSNull())
        case "connections.release":
            if let url = (body["parameters"] as? [String: String])?["resourceURL"] { resources?.release(url: url) }
            reply(id: id, value: NSNull())
        case "connections.unsubscribe":
            guard let parameters = body["parameters"] as? [String: String], let subscription = parameters["subscriptionId"] else {
                reply(id: id, error: "validation_failed"); return
            }
            tasks.removeValue(forKey: subscription)?.cancel(); reply(id: id, value: NSNull())
        case "connections.request", "connections.subscribe":
            guard let alias = body["alias"] as? String, let operation = body["operation"] as? String,
                  let parameters = body["parameters"] as? [String: String], tasks.count < 16, tasks[id] == nil else {
                reply(id: id, error: "validation_failed"); return
            }
            let subscribe = body["method"] as? String == "connections.subscribe"
            let generation = documentGeneration
            if !subscribe && alias == "googleTV" {
                guard active, let dashboardID = navigation?.manifest.dashboardId else { reply(id: id, error: "permission_required"); return }
                if operation == "voice" || operation == "launchChannel" || operation == "togglePower" {
                    let tap = voiceTapAt; voiceTapAt = nil
                    guard let tap, ProcessInfo.processInfo.systemUptime - tap <= 1 else {
                        reply(id: id, error: "Google TV voice, channel launch, and direct power require an explicit tap."); return
                    }
                }
                tasks[id] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { if self.documentGeneration == generation { self.tasks.removeValue(forKey: id) } }
                    do {
                        let value: [String: Any]
                        if operation == "launchChannel" { value = try await self.googleTVADB.launch(dashboard: dashboardID, parameters: parameters) }
                        else if operation == "togglePower" { value = try await self.googleTVADB.togglePower(dashboard: dashboardID, parameters: parameters) }
                        else { value = try await self.googleTV.request(dashboardID: dashboardID, operation: operation, parameters: parameters) }
                        guard self.current(generation) else { return }
                        self.reply(id: id, value: value)
                    } catch {
                        guard self.current(generation) else { return }
                        self.reply(id: id, error: error.localizedDescription)
                    }
                }
                return
            }
            if !subscribe, let publicReads, publicReads.aliases.contains(alias) {
                guard publicTasks.count < 16, publicTasks[id] == nil else { reply(id: id, error: "size_limit"); return }
                publicTasks[id] = Task { @MainActor [weak self] in
                    defer { if self?.documentGeneration == generation { self?.publicTasks.removeValue(forKey: id) } }
                    do {
                        let result = try await publicReads.request(alias: alias, operation: operation, parameters: parameters)
                        guard let self, self.current(generation) else { return }
                        var value: [String: Any] = ["state": result.state, "status": result.status]
                        if let date = result.fetchedAt { value["fetchedAt"] = ISO8601DateFormatter().string(from: date) }
                        if let valid = result.lastModified { value["lastModified"] = valid }
                        if let retry = result.retryAfter { value["retryAfterSeconds"] = retry }
                        if let code = result.code { value["code"] = code }
                        if let data = result.body {
                            if result.mime == "image/png" || result.mime == "image/jpeg" {
                                value["resourceURL"] = try self.resources?.put(result)
                            } else { value["data"] = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
                        }
                        self.onHealth(result.state == "fresh" || result.state == "unavailable")
                        self.reply(id: id, value: value, stale: result.state == "stale")
                    } catch {
                        guard self?.current(generation) == true else { return }
                        self?.reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline")
                    }
                }
                return
            }
            if !subscribe && alias == "home" && (operation == "cameraPresent" || operation == "cameraClose") {
                guard alias == "home", let cameras else { reply(id: id, error: "permission_required"); return }
                do { reply(id: id, value: try cameras.request(operation: operation, parameters: parameters)) }
                catch { reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline") }
                return
            }
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                defer { if self.documentGeneration == generation { self.tasks.removeValue(forKey: id) } }
                do {
                    if subscribe { try await self.subscribe(id: id, alias: alias, operation: operation, parameters: parameters, generation: generation) }
                    else {
                        let result: ConnectionHTTPResult
                        if alias == "home", let runtime = self.runtime {
                            result = try await runtime.request(revision: self.revision, alias: alias, operation: operation, parameters: parameters)
                        } else if let connections = self.connections {
                            result = try await connections.request(alias: alias, operation: operation, parameters: parameters)
                        } else { throw ConnectionFailure.permissionRequired }
                        guard self.current(generation) else { return }
                        let value = try JSONSerialization.jsonObject(with: result.body, options: .fragmentsAllowed)
                        self.onHealth(!result.stale); self.reply(id: id, value: value, stale: result.stale)
                    }
                } catch {
                    guard self.current(generation) else { return }
                    self.onHealth(false)
                    self.reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline")
                }
            }
        default: reply(id: id, error: "permission_required")
        }
    }

    private func current(_ generation: UUID) -> Bool { generation == documentGeneration && !Task.isCancelled }

    private func subscribe(id: String, alias: String, operation: String, parameters: [String: String], generation: UUID) async throws {
        if alias == "home", let runtime {
            let stream = try await runtime.subscribeStates(revision: revision, alias: alias, operation: operation, parameters: parameters)
            guard current(generation) else { return }
            reply(id: id, value: NSNull())
            for try await update in stream {
                guard current(generation) else { return }
                onHealth(true)
                event(id: id, alias: alias, operation: operation, data: update.data, snapshot: update.isSnapshot)
            }
        } else if let connections {
            let subscription = try await connections.subscribe(alias: alias, operation: operation, parameters: parameters)
            guard current(generation) else { await connections.unsubscribe(id: subscription); return }
            reply(id: id, value: NSNull())
            do {
                try await withTaskCancellationHandler(operation: {
                    while current(generation) {
                        let data = try await connections.receive(id: subscription)
                        guard current(generation) else { break }
                        onHealth(true); event(id: id, alias: alias, operation: operation, data: data, snapshot: false)
                    }
                }, onCancel: { Task { await connections.unsubscribe(id: subscription) } })
                await connections.unsubscribe(id: subscription)
            } catch { await connections.unsubscribe(id: subscription); throw error }
        } else { throw ConnectionFailure.permissionRequired }
    }

    private func event(id: String, alias: String, operation: String, data: Data, snapshot: Bool) {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return }
        dispatch(["protocolVersion": 1, "id": id, "kind": "event", "method": "connections.subscribe", "alias": alias,
                  "operation": operation, "value": value, "snapshot": snapshot])
    }

    private func reply(id: String, value: Any = NSNull(), stale: Bool = false, error: String? = nil) {
        var message: [String: Any] = ["protocolVersion": 1, "id": id, "kind": error == nil ? "response" : "error",
                                      "ok": error == nil, "stale": stale]
        if let error { message["code"] = error; message["message"] = error }
        else { message["value"] = value }
        dispatch(message)
    }

    private func dispatch(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.callAsyncJavaScript("if (typeof globalThis.__screenpunkDispatch === 'function') globalThis.__screenpunkDispatch(JSON.parse(message));",
                                    arguments: ["message": json], in: nil, in: .page, completionHandler: { _ in })
    }
}

/// Page JavaScript cannot invoke this handler in the isolated content world.
@MainActor
private final class GoogleTVTapHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: HomeAssistantWebBridge?
    init(_ bridge: HomeAssistantWebBridge) { self.bridge = bridge }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url?.absoluteString,
              IsolationEvaluator.isLocalPackageURL(url) else { return }
        bridge?.recordVoiceTap()
    }
}
