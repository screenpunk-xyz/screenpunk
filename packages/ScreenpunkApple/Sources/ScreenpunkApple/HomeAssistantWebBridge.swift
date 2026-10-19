import Foundation
@_spi(ManagedRender) import ScreenpunkCore
import WebKit

/// Only the top-level package frame may invoke approved native operations. No
/// origin, credential, path or executable payload is accepted from JavaScript.
@MainActor
final class HomeAssistantWebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private let runtime: HomeAssistantDeviceRuntime?
    private let connections: ConnectionRuntime?
    private let managedRuntime: DeviceUnifiedManagedRuntime?
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
    private(set) var isSuspendedForReset = false
    private let maps = AppleMapPreview()
    private let interactiveMaps = InteractiveMapController()
    private let mapApproval = MapPreviewApproval()
    private let mapManifest: DashboardManifest?
    let calendarService: GoogleCalendarDeviceService
    private let preferenceStore: ScreenPreferenceStore
    private let preferenceGeneration: UUID?
    private let stateReadOnly: Bool
    private let googleTV = GoogleTVScreenConnection()
    private let googleTVADB = GoogleTVADBScreenConnection()
    private var voiceTapAt: TimeInterval?
    fileprivate func recordVoiceTap() { if !isSuspendedForReset, active { voiceTapAt = ProcessInfo.processInfo.systemUptime } }
    func installVoiceTapGate(_ controller: WKUserContentController) {
        guard !isSuspendedForReset else { return }
        let world = WKContentWorld.world(name: "ScreenpunkVoiceTap")
        controller.add(GoogleTVTapHandler(self), contentWorld: world, name: "screenpunkVoiceTap")
        controller.addUserScript(WKUserScript(source: """
        document.addEventListener('click', function(event) {
          if (event.isTrusted) window.webkit.messageHandlers.screenpunkVoiceTap.postMessage('tap');
        }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }
    func setActive(_ value: Bool) {
        guard !isSuspendedForReset, active != value else { return }
        active = value
        if !value { voiceTapAt = nil; googleTV.close(); googleTVADB.close(); cameras?.stopAll() }
        status(navigation?.status ?? [:])
    }

    init(runtime: HomeAssistantDeviceRuntime?, connections: ConnectionRuntime? = nil, managedRuntime: DeviceUnifiedManagedRuntime? = nil, navigation: DashboardEventRuntime? = nil,
         revision: String, mapManifest: DashboardManifest? = nil, preferenceStore: ScreenPreferenceStore? = nil, calendarService: GoogleCalendarDeviceService? = nil, stateReadOnly: Bool = false, publicReads: PublicReadRuntime? = nil, resources: PublicRasterResources? = nil, onHealth: @escaping (Bool) -> Void) {
        if let managedRuntime {
            self.cameras = CameraPlaybackController(resolver: DeviceUnifiedCameraResolver(runtime: managedRuntime), revision: revision)
        } else { self.cameras = runtime.map { CameraPlaybackController(resolver: $0, revision: revision) } }
        self.publicReads = publicReads; self.resources = resources
        self.runtime = runtime; self.connections = connections; self.managedRuntime = managedRuntime; self.navigation = navigation
        self.mapManifest = mapManifest
        let preferenceStore = preferenceStore ?? .shared
        self.calendarService = calendarService ?? .shared
        self.preferenceStore = preferenceStore; self.stateReadOnly = stateReadOnly
        self.preferenceGeneration = try? preferenceStore.generation()
        self.revision = revision; self.onHealth = onHealth
    }
    func attach(to webView: WKWebView) { guard !isSuspendedForReset else { return }; self.webView = webView; cameras?.attach(webView); interactiveMaps.attach(webView)
        interactiveMaps.onTap = { [weak self] id in
            guard let self, !self.isSuspendedForReset, self.active else { return }
            self.webView?.callAsyncJavaScript(
                "window.dispatchEvent(new CustomEvent('screenpunk:appleMapsTap', {detail: {id: id}}));",
                arguments: ["id": id], in: nil, in: .page, completionHandler: { _ in })
        }
    }
    /// Terminal writer fence. Navigation cancellation cannot reactivate this bridge.
    func suspendForReset() {
        guard !isSuspendedForReset else { return }
        isSuspendedForReset = true; active = false
        cancel(); interactiveMaps.onTap = nil; webView = nil
    }

    func cancel() {
        voiceTapAt = nil; googleTV.close(); googleTVADB.close(); maps.cancel(); interactiveMaps.close()
        documentGeneration = UUID()
        for task in publicTasks.values { task.cancel() }; publicTasks.removeAll(); resources?.clear()
        let reads = publicReads; Task { await reads?.cancel() }
        cameras?.stopAll()
        for task in tasks.values { task.cancel() }; tasks.removeAll()
    }

    func status(_ value: [String: Any]) {
        dispatch(["protocolVersion": 1, "id": "runtime-status", "kind": "event", "method": "runtime.onStatus",
                  "value": ["active": active, "navigation": value, "homeAssistantTransport": "websocket-with-http", "homeAssistantServiceCalls": 1, "cameraPlayback": 1, "publicReadHTTP": 1, "googleCalendar": 1, "appleMaps": 1, "appleMapsInteractive": 1, "appleMapsTap": 1, "appleMapsLocation": 1, "persistentState": 1, "persistentStateWritable": stateReadOnly ? 0 : 1, "googleTVRemote": 1, "googleTVVoice": 1, "googleTVDirectChannels": 1, "googleTVDirectPower": 1, "macIsRuntimeProxy": false]])
    }

    deinit { let cameras = cameras; let interactiveMaps = interactiveMaps; Task { @MainActor in cameras?.cancel(); interactiveMaps.cancel() } }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isSuspendedForReset, message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url?.absoluteString,
              IsolationEvaluator.isLocalPackageURL(url),
              let body = message.body as? [String: Any], let id = body["id"] as? String, (1...128).contains(id.utf8.count),
              JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 64 * 1024 else { return }
        handleValidatedBody(body, id: id)
    }

    // Frame/origin/size validation remains at the sole script-message entry point.
    func handleValidatedBody(_ body: [String: Any], id: String) {
        guard !isSuspendedForReset, managedRuntime == nil || (try? managedRuntime?.verifyResources()) != nil else { return }
        guard body["protocolVersion"] as? Int == 1, body["kind"] as? String == "request" else {
            reply(id: id, error: "validation_failed"); return
        }
        if let managedRuntime, !["runtime.ready", "runtime.onStatus"].contains(body["method"] as? String ?? ""),
            (try? managedRuntime.verifyActive()) == nil { reply(id: id, error: "permission_required"); return }
        switch body["method"] as? String {
        case "runtime.ready": reply(id: id, value: NSNull())
        case "runtime.onStatus":
            reply(id: id, value: ["publicReadHTTP": 1, "appleMaps": 1, "appleMapsInteractive": 1, "appleMapsTap": 1, "appleMapsLocation": 1, "persistentState": 1, "persistentStateWritable": stateReadOnly ? 0 : 1]); status(navigation?.status ?? [:])
        case "navigation.get": reply(id: id, value: navigation?.status ?? ["pageId": "default"])
        case "navigation.open":
            guard let parameters = body["parameters"] as? [String: String], parameters.count == 1,
                  let page = parameters["pageId"], let navigation,
                  navigation.manifest.resolvedPages.contains(where: { $0.id == page }) else {
                reply(id: id, error: "permission_required"); return
            }
            // Acknowledge in this document before starting its replacement load.
            reply(id: id, value: NSNull()); _ = navigation.open(pageId: page)
        case "state.get", "state.set", "state.remove":
            guard active, let dashboard = (navigation?.manifest ?? mapManifest)?.dashboardId else {
                reply(id: id, error: "permission_required"); return
            }
            guard let method = body["method"] as? String, let key = body["key"] as? String,
                  Set(body.keys).isSubset(of: ["protocolVersion", "kind", "id", "method", "key", "value", "parameters"]),
                  body["parameters"] == nil || body["parameters"] is NSNull,
                  method == "state.set" ? body["value"] != nil : body["value"] == nil else {
                reply(id: id, error: "validation_failed"); return
            }
            guard let generation = preferenceGeneration else { reply(id: id, error: "device_offline"); return }
            do {
                if method == "state.get" {
                    reply(id: id, value: try preferenceStore.get(dashboard: dashboard, key: key, generation: generation))
                } else {
                    guard !stateReadOnly else { throw ConnectionFailure.permissionRequired }
                    if method == "state.set" { try preferenceStore.set(dashboard: dashboard, key: key, value: body["value"]!, generation: generation) }
                    else { try preferenceStore.remove(dashboard: dashboard, key: key, generation: generation) }
                    reply(id: id, value: NSNull())
                }
            } catch { reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline") }
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
            if alias == "appleMaps" {
                guard !subscribe, active, let manifest = navigation?.manifest ?? mapManifest,
                      AppleMapPreview.isDeclared(in: manifest, operation: operation),
                      let resources else { reply(id: id, error: "permission_required"); return }
                if operation != "snapshot" {
                    do {
                        try InteractiveMapController.validate(operation: operation, parameters: parameters)
                        if operation == "present", !mapApproval.allowed(dashboard: manifest.dashboardId, revision: manifest.revision, view: webView) {
                            reply(id: id, error: "permission_required"); return
                        }
                        reply(id: id, value: try interactiveMaps.request(operation: operation, parameters: parameters))
                    } catch { reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline") }
                    return
                }
                let request: MapPreviewRequest
                do { request = try MapPreviewRequest(parameters) }
                catch { reply(id: id, error: "validation_failed"); return }
                guard mapApproval.allowed(dashboard: manifest.dashboardId, revision: manifest.revision, view: webView) else {
                    reply(id: id, error: "permission_required"); return
                }
                tasks[id] = Task { @MainActor [weak self] in
                    guard let self, self.current(generation) else { return }
                    defer { if self.documentGeneration == generation { self.tasks.removeValue(forKey: id) } }
                    let deadline = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 12_000_000_000)
                        if !Task.isCancelled { self.maps.cancel() }
                    }
                    defer { deadline.cancel() }
                    do {
                        let (data, state) = try await self.maps.render(request)
                        guard self.current(generation), self.active else { return }
                        var value: [String: Any] = ["state": data == nil ? "unavailable" : "fresh", "status": 200, "code": state]
                        if let data {
                            value["resourceURL"] = try resources.put(.init(state: "fresh", body: data, mime: "image/png", status: 200))
                        }
                        self.reply(id: id, value: value)
                    } catch {
                        guard self.current(generation), self.active else { return }
                        self.reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline")
                    }
                }
                return
            }
            if ["googleCalendar", "google-calendar"].contains(alias) {
                guard !subscribe, active, operation == "events", let manifest = navigation?.manifest,
                      manifest.connections.contains(where: { $0.alias == alias && ($0.operations == nil || $0.operations?.contains(where: { $0.name == "events" && $0.kind == "http" }) == true) }) else {
                    reply(id: id, error: "permission_required"); return
                }
                let service = calendarService
                let accessGeneration = service.generation
                tasks[id] = Task { @MainActor [weak self] in
                    guard let self, self.current(generation) else { return }
                    defer { if self.documentGeneration == generation { self.tasks.removeValue(forKey: id) } }
                    do {
                        let result = try await service.events(dashboard: manifest.dashboardId, parameters: parameters)
                        guard self.current(generation), self.active, service.generation == accessGeneration else { return }
                        self.onHealth(!result.stale)
                        self.reply(id: id, value: result.value, stale: result.stale)
                    } catch {
                        guard self.current(generation), self.active else { return }
                        self.reply(id: id, error: (error as? GoogleCalendarError)?.rawValue ?? "device_offline")
                    }
                }
                return
            }
            if !subscribe && alias == "googleTV" {
                guard active, let dashboardID = navigation?.manifest.dashboardId else { reply(id: id, error: "permission_required"); return }
                if operation == "voice" || operation == "launchChannel" || operation == "togglePower" {
                    let tap = voiceTapAt; voiceTapAt = nil
                    guard let tap, ProcessInfo.processInfo.systemUptime - tap <= 1 else {
                        reply(id: id, error: "Google TV voice, channel launch, and direct power require an explicit tap."); return
                    }
                }
                tasks[id] = Task { @MainActor [weak self] in
                    guard let self, self.current(generation) else { return }
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
                    guard let self, self.current(generation) else { return }
                    defer { if self.documentGeneration == generation { self.publicTasks.removeValue(forKey: id) } }
                    do {
                        let result = try await publicReads.request(alias: alias, operation: operation, parameters: parameters)
                        guard self.current(generation) else { return }
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
                        guard self.current(generation) else { return }
                        self.reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline")
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
                guard let self, self.current(generation) else { return }
                defer { if self.documentGeneration == generation { self.tasks.removeValue(forKey: id) } }
                do {
                    if subscribe { try await self.subscribe(id: id, alias: alias, operation: operation, parameters: parameters, generation: generation) }
                    else {
                        let result: ConnectionHTTPResult
                        if let managedRuntime = self.managedRuntime {
                            result = try await managedRuntime.request(alias: alias, operation: operation, parameters: parameters)
                        } else if alias == "home", let runtime = self.runtime {
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

    private func current(_ generation: UUID) -> Bool {
        guard !isSuspendedForReset, generation == documentGeneration, !Task.isCancelled else { return false }
        if let managedRuntime { return (try? managedRuntime.verifyActive()) != nil }; return true
    }

    private func subscribe(id: String, alias: String, operation: String, parameters: [String: String], generation: UUID) async throws {
        guard current(generation) else { return }
        if let managedRuntime {
            let stream = try await managedRuntime.subscribe(alias: alias, operation: operation, parameters: parameters)
            guard current(generation) else { return }; reply(id: id, value: NSNull())
            for try await update in stream {
                guard current(generation) else { return }; onHealth(true)
                event(id: id, alias: alias, operation: operation, data: update.data, snapshot: update.isSnapshot)
            }
        } else if alias == "home", let runtime {
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
        guard !isSuspendedForReset else { return }
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
