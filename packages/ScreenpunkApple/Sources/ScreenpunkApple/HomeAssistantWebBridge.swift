import Foundation
@_spi(ManagedRender) import ScreenpunkCore
import WebKit

struct HomeAssistantBridgeTiming: Sendable {
    var qualificationNanoseconds: UInt64 = 8_000_000_000
    var requestNanoseconds: UInt64 = 14_000_000_000
    var longRequestNanoseconds: UInt64 = 44_000_000_000
    var sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
}

private final class BridgeQualificationPool: @unchecked Sendable {
    private let lock = NSLock()
    private var workers = 0
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard workers < 4 else { return false }; workers += 1; return true
    }
    func end() { lock.lock(); workers -= 1; lock.unlock() }
}

/// An uncooperative synchronous verifier must never hold the main actor, or make
/// cancellation wait for its worker. Late worker results lose this one-shot race.
private final class BridgeQualificationWait: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var workers: [Task<Void, Never>] = []
    private func checkPending() throws {
        lock.lock(); defer { lock.unlock() }
        if result != nil { throw CancellationError() }
    }
    private func finish(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let waiter = continuation; continuation = nil
        let pending = workers; workers = []; lock.unlock()
        pending.forEach { $0.cancel() }; waiter?.resume(with: value)
    }
    func run(timing: HomeAssistantBridgeTiming, pool: BridgeQualificationPool, verify: @escaping @Sendable () throws -> Void) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { waiter in
                lock.lock()
                if let result { lock.unlock(); waiter.resume(with: result); return }
                continuation = waiter; lock.unlock()
                // Timed-out workers can still be draining store locks. Keep their
                // slots until they actually finish, rather than allocate endlessly.
                guard pool.begin() else { finish(.failure(ConnectionFailure.sizeLimit)); return }
                // Verification is synchronous and can block on store locks. It
                // must not occupy the cooperative executor used by deadlines.
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { pool.end() }
                    do { try checkPending(); try verify(); try checkPending(); finish(.success(())) }
                    catch { finish(.failure(error)) }
                }
                let deadline = Task.detached { [self] in
                    do { try await timing.sleep(timing.qualificationNanoseconds); try Task.checkCancellation(); finish(.failure(ConnectionFailure.timeout)) }
                    catch { }
                }
                lock.lock()
                if result == nil { workers = [deadline]; lock.unlock() }
                else { lock.unlock(); deadline.cancel() }
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }
}

/// Only the top-level package frame may invoke approved native operations. No
/// origin, credential, path or executable payload is accepted from JavaScript.
@MainActor
final class HomeAssistantWebBridge: NSObject, WKScriptMessageHandler {
    private struct RequestIdentity: Equatable {
        let document: UUID
        let token = UUID()
    }
    private struct RegisteredTask {
        let identity: RequestIdentity
        let task: Task<Void, Never>
    }
    private weak var webView: WKWebView?
    private let runtime: HomeAssistantDeviceRuntime?
    private let connections: ConnectionRuntime?
    private let managedRuntime: DeviceUnifiedManagedRuntime?
    private let navigation: DashboardEventRuntime?
    private let revision: String
    private let cameras: CameraPlaybackController?
    private let publicReads: PublicReadRuntime?
    private let resources: PublicRasterResources?
    private var publicTasks: [String: RegisteredTask] = [:]
    private let onHealth: (Bool) -> Void
    private var tasks: [String: RegisteredTask] = [:]
    private var admissions: [String: RegisteredTask] = [:]
    private var requestTokens: [String: RequestIdentity] = [:]
    private var requestDeadlines: [String: Task<Void, Never>] = [:]
    private var tvRequests: [String: RequestIdentity] = [:]
    private let qualification: (@Sendable (Bool) throws -> Void)?
    private let qualificationPool = BridgeQualificationPool()
    private let timing: HomeAssistantBridgeTiming
    private let fixtureGoogleTVRequest: (@MainActor (String, String, [String: String]) async throws -> [String: Any])?
    private let observeReply: (([String: Any]) -> Void)?
    private let observeOperationCompletion: ((String, Bool) -> Void)?
    private var documentGeneration = UUID()
    private var active = true
    private var presentationSuspended = false
    private let presentationAllowed: @Sendable () -> Bool
    private let lifetime: DeviceRuntimeLifetime?
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
    fileprivate func recordVoiceTap() { if presentationIsOpen(), !isSuspendedForReset, active { voiceTapAt = ProcessInfo.processInfo.systemUptime } }
    func installVoiceTapGate(_ controller: WKUserContentController) {
        guard presentationIsOpen(), !isSuspendedForReset else { return }
        let world = WKContentWorld.world(name: "ScreenpunkVoiceTap")
        controller.add(GoogleTVTapHandler(self), contentWorld: world, name: "screenpunkVoiceTap")
        controller.addUserScript(WKUserScript(source: """
        document.addEventListener('click', function(event) {
          if (event.isTrusted) window.webkit.messageHandlers.screenpunkVoiceTap.postMessage('tap');
        }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }
    private func presentationIsOpen() -> Bool {
        guard presentationAllowed() else { suspendPresentation(); return false }
        return lifetime?.isRetired != true
    }
    func setActive(_ value: Bool) {
        let next = value && presentationAllowed() && lifetime?.isRetired != true
        guard !isSuspendedForReset, active != next else { return }
        active = next
        if next { presentationSuspended = false }
        if !next { voiceTapAt = nil; googleTV.close(); googleTVADB.close(); cameras?.stopAll() }
        status(navigation?.status ?? [:])
    }

    init(runtime: HomeAssistantDeviceRuntime?, connections: ConnectionRuntime? = nil, managedRuntime: DeviceUnifiedManagedRuntime? = nil, navigation: DashboardEventRuntime? = nil,
         revision: String, lifetime: DeviceRuntimeLifetime? = nil, presentationAllowed: @escaping @Sendable () -> Bool = { true }, mapManifest: DashboardManifest? = nil, preferenceStore: ScreenPreferenceStore? = nil, calendarService: GoogleCalendarDeviceService? = nil, stateReadOnly: Bool = false, publicReads: PublicReadRuntime? = nil, resources: PublicRasterResources? = nil,
         additionalQualification: (@Sendable (Bool) throws -> Void)? = nil, timing: HomeAssistantBridgeTiming = .init(),
         fixtureGoogleTVRequest: (@MainActor (String, String, [String: String]) async throws -> [String: Any])? = nil,
         observeReply: (([String: Any]) -> Void)? = nil, observeOperationCompletion: ((String, Bool) -> Void)? = nil, onHealth: @escaping (Bool) -> Void) {
        self.presentationAllowed = presentationAllowed; self.lifetime = lifetime
        // Fixture callbacks cannot replace qualification or TV dispatch on a genuine runtime.
        precondition(managedRuntime == nil || fixtureGoogleTVRequest == nil)
        self.fixtureGoogleTVRequest = fixtureGoogleTVRequest; self.timing = timing; self.observeReply = observeReply
        self.observeOperationCompletion = observeOperationCompletion
        if let managedRuntime {
            qualification = { requireActive in
                if requireActive { try managedRuntime.verifyActive() } else { try managedRuntime.verifyResources() }
                try additionalQualification?(requireActive)
            }
        } else { qualification = additionalQualification }
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
    func attach(to webView: WKWebView) { guard presentationIsOpen(), !isSuspendedForReset else { return }; self.webView = webView; cameras?.attach(webView); interactiveMaps.attach(webView)
        interactiveMaps.onTap = { [weak self] id in
            guard let self, self.presentationIsOpen(), !self.isSuspendedForReset, self.active else { return }
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

    func suspendPresentation() {
        guard !isSuspendedForReset, lifetime?.isRetired != true, !presentationSuspended else { return }
        presentationSuspended = true; active = false
        cancel(settlePendingForSuspension: true)
    }
    func cancel(settlePendingForSuspension: Bool = false) {
        let pendingIDs = settlePendingForSuspension && !isSuspendedForReset && lifetime?.isRetired != true ? Set(tasks.keys).union(publicTasks.keys).union(requestTokens.keys) : []
        voiceTapAt = nil; googleTV.close(); googleTVADB.close(); maps.cancel(); interactiveMaps.close()
        documentGeneration = UUID()
        for task in publicTasks.values { task.task.cancel() }; publicTasks.removeAll(); resources?.clear()
        let reads = publicReads; Task { await reads?.cancel() }
        cameras?.stopAll()
        for task in tasks.values { task.task.cancel() }; tasks.removeAll()
        for task in admissions.values { task.task.cancel() }; admissions.removeAll()
        for task in requestDeadlines.values { task.cancel() }; requestDeadlines.removeAll()
        requestTokens.removeAll(); tvRequests.removeAll()
        // Only a nonterminal pause settles known pending IDs in the retained
        // document. Navigation/reset cancellation keeps its existing behavior.
        for id in pendingIDs { denySuspendedRequest(id) }
    }
    private func denySuspendedRequest(_ id: String) {
        dispatch(["protocolVersion":1,"id":id,"kind":"error","ok":false,"stale":false,
                  "code":"device_offline","message":"device_offline"], suspensionDenial:true)
    }

    func status(_ value: [String: Any]) {
        guard presentationIsOpen() else { return }
        dispatch(["protocolVersion": 1, "id": "runtime-status", "kind": "event", "method": "runtime.onStatus",
                  "value": ["active": active, "navigation": value, "homeAssistantTransport": "websocket-with-http", "homeAssistantServiceCalls": 1, "cameraPlayback": 1, "publicReadHTTP": 1, "googleCalendar": 1, "appleMaps": 1, "appleMapsInteractive": 1, "appleMapsTap": 1, "appleMapsLocation": 1, "persistentState": 1, "persistentStateWritable": stateReadOnly ? 0 : 1, "googleTVRemote": 1, "googleTVVoice": 1, "googleTVDirectChannels": 1, "googleTVDirectPower": 1, "macIsRuntimeProxy": false]])
    }

    deinit { let cameras = cameras; let interactiveMaps = interactiveMaps; Task { @MainActor in cameras?.cancel(); interactiveMaps.cancel() } }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let allowed = presentationIsOpen()
        guard !isSuspendedForReset, message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url?.absoluteString,
              IsolationEvaluator.isLocalPackageURL(url),
              let body = message.body as? [String: Any], let id = body["id"] as? String, (1...128).contains(id.utf8.count),
              JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 64 * 1024 else { return }
        guard allowed else { denySuspendedRequest(id); return }
        handleValidatedBody(body, id: id)
    }

    // Frame/origin/size validation remains at the sole script-message entry point.
    func handleValidatedBody(_ body: [String: Any], id: String) {
        guard presentationIsOpen() else { denySuspendedRequest(id); return }
        guard !isSuspendedForReset else { return }
        let method = body["method"] as? String ?? ""
        let reducesAuthority = ["connections.cancel", "connections.unsubscribe", "connections.release"].contains(method)
        guard requestTokens[id] == nil, tasks[id] == nil, publicTasks[id] == nil, admissions[id] == nil else { return }
        guard reducesAuthority || requestTokens.count < 16 else {
            dispatch(["protocolVersion":1,"id":id,"kind":"error","ok":false,"stale":false,"code":"size_limit","message":"size_limit"]); return
        }
        let identity = RequestIdentity(document: documentGeneration)
        requestTokens[id] = identity
        guard body["protocolVersion"] as? Int == 1, body["kind"] as? String == "request" else {
            reply(id: id, identity: identity, error: "validation_failed"); return
        }
        // Cancellation only reduces authority. It must not queue behind the graph
        // check it is meant to stop, and still uses the frame/lifetime fences.
        if reducesAuthority {
            handleAdmittedBody(body, id: id, identity: identity, trustedTVTap: false); return
        }
        let explicitTV = method == "connections.request" && body["alias"] as? String == "googleTV" && ["voice", "launchChannel", "togglePower"].contains(body["operation"] as? String ?? "")
        let trustedTVTap = explicitTV && voiceTapAt.map { ProcessInfo.processInfo.systemUptime - $0 <= 1 } == true
        if explicitTV { voiceTapAt = nil }
        guard let qualification else { handleAdmittedBody(body, id: id, identity: identity, trustedTVTap: trustedTVTap); return }
        let requiresActive = !["runtime.ready", "runtime.onStatus"].contains(method)
        if body["alias"] as? String == "googleTV" { tvRequests[id] = identity }
        let timing = timing
        requestDeadlines[id] = Task { [weak self] in
            do { try await timing.sleep(explicitTV ? timing.longRequestNanoseconds : timing.requestNanoseconds); try Task.checkCancellation() }
            catch { return }
            guard let self else { return }
            self.cancelRequest(id, identity: identity, error: "timeout")
        }
        admissions[id] = RegisteredTask(identity: identity, task: Task { [weak self] in
            guard let self else { return }
            defer { self.removeAdmission(id, identity: identity) }
            do {
                try await BridgeQualificationWait().run(timing: timing, pool: self.qualificationPool) { try qualification(requiresActive) }
                guard self.requestTokens[id] == identity, self.isCurrent(identity, requiresActive: requiresActive) else { return }
                self.handleAdmittedBody(body, id: id, identity: identity, trustedTVTap: trustedTVTap)
            } catch {
                guard self.requestTokens[id] == identity, self.isCurrent(identity, requiresActive: requiresActive) else { return }
                self.reply(id: id, identity: identity, error: (error as? ConnectionFailure)?.rawValue ?? "permission_required")
            }
        })
    }

    private func removeAdmission(_ id: String, identity: RequestIdentity) {
        if admissions[id]?.identity == identity { admissions[id] = nil }
    }
    private func removeOperation(_ id: String, identity: RequestIdentity, isPublic: Bool = false) {
        let removed: Bool
        if isPublic {
            removed = publicTasks[id]?.identity == identity
            if removed { publicTasks[id] = nil }
        } else {
            removed = tasks[id]?.identity == identity
            if removed { tasks[id] = nil }
        }
        observeOperationCompletion?(id, removed)
    }
    private func owns(_ id: String, identity: RequestIdentity) -> Bool {
        requestTokens[id] == identity || tasks[id]?.identity == identity || publicTasks[id]?.identity == identity || admissions[id]?.identity == identity
    }
    private func cancelRequest(_ id: String, identity expected: RequestIdentity? = nil, error: String) {
        guard let identity = expected ?? requestTokens[id] ?? tasks[id]?.identity ?? publicTasks[id]?.identity ?? admissions[id]?.identity,
            owns(id, identity: identity) else { return }
        if admissions[id]?.identity == identity { admissions.removeValue(forKey: id)?.task.cancel() }
        if publicTasks[id]?.identity == identity { publicTasks.removeValue(forKey: id)?.task.cancel() }
        if tasks[id]?.identity == identity { tasks.removeValue(forKey: id)?.task.cancel() }
        if tvRequests[id] == identity { googleTV.close(); googleTVADB.close() }
        reply(id: id, identity: identity, error: error)
    }

    private func handleAdmittedBody(_ body: [String: Any], id: String, identity: RequestIdentity, trustedTVTap: Bool) {
        guard owns(id, identity: identity), isCurrent(identity, requiresActive: false) else { return }
        switch body["method"] as? String {
        case "runtime.ready": reply(id: id, identity: identity, value: NSNull())
        case "runtime.onStatus":
            reply(id: id, identity: identity, value: ["publicReadHTTP": 1, "appleMaps": 1, "appleMapsInteractive": 1, "appleMapsTap": 1, "appleMapsLocation": 1, "persistentState": 1, "persistentStateWritable": stateReadOnly ? 0 : 1]); status(navigation?.status ?? [:])
        case "navigation.get": reply(id: id, identity: identity, value: navigation?.status ?? ["pageId": "default"])
        case "navigation.open":
            guard let parameters = body["parameters"] as? [String: String], parameters.count == 1,
                  let page = parameters["pageId"], let navigation,
                  navigation.manifest.resolvedPages.contains(where: { $0.id == page }) else {
                reply(id: id, identity: identity, error: "permission_required"); return
            }
            // Acknowledge in this document before starting its replacement load.
            reply(id: id, identity: identity, value: NSNull()); _ = navigation.open(pageId: page)
        case "state.get", "state.set", "state.remove":
            guard active, let dashboard = (navigation?.manifest ?? mapManifest)?.dashboardId else {
                reply(id: id, identity: identity, error: "permission_required"); return
            }
            guard let method = body["method"] as? String, let key = body["key"] as? String,
                  Set(body.keys).isSubset(of: ["protocolVersion", "kind", "id", "method", "key", "value", "parameters"]),
                  body["parameters"] == nil || body["parameters"] is NSNull,
                  method == "state.set" ? body["value"] != nil : body["value"] == nil else {
                reply(id: id, identity: identity, error: "validation_failed"); return
            }
            guard let generation = preferenceGeneration else { reply(id: id, identity: identity, error: "device_offline"); return }
            do {
                if method == "state.get" {
                    reply(id: id, identity: identity, value: try preferenceStore.get(dashboard: dashboard, key: key, generation: generation))
                } else {
                    guard !stateReadOnly else { throw ConnectionFailure.permissionRequired }
                    if method == "state.set" { try preferenceStore.set(dashboard: dashboard, key: key, value: body["value"]!, generation: generation) }
                    else { try preferenceStore.remove(dashboard: dashboard, key: key, generation: generation) }
                    reply(id: id, identity: identity, value: NSNull())
                }
            } catch { reply(id: id, identity: identity, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline") }
        case "connections.cancel":
            if let target = (body["parameters"] as? [String: String])?["requestId"] { cancelRequest(target, error: "device_offline") }
            reply(id: id, identity: identity, value: NSNull())
        case "connections.release":
            if let url = (body["parameters"] as? [String: String])?["resourceURL"] { resources?.release(url: url) }
            reply(id: id, identity: identity, value: NSNull())
        case "connections.unsubscribe":
            guard let parameters = body["parameters"] as? [String: String], let subscription = parameters["subscriptionId"] else {
                reply(id: id, identity: identity, error: "validation_failed"); return
            }
            cancelRequest(subscription, error: "device_offline"); reply(id: id, identity: identity, value: NSNull())
        case "connections.request", "connections.subscribe":
            guard let alias = body["alias"] as? String, let operation = body["operation"] as? String,
                  let parameters = body["parameters"] as? [String: String], tasks.count < 16, tasks[id] == nil else {
                reply(id: id, identity: identity, error: "validation_failed"); return
            }
            let subscribe = body["method"] as? String == "connections.subscribe"
            if alias == "appleMaps" {
                guard !subscribe, active, let manifest = navigation?.manifest ?? mapManifest,
                      AppleMapPreview.isDeclared(in: manifest, operation: operation),
                      let resources else { reply(id: id, identity: identity, error: "permission_required"); return }
                if operation != "snapshot" {
                    do {
                        try InteractiveMapController.validate(operation: operation, parameters: parameters)
                        if operation == "present", !mapApproval.allowed(dashboard: manifest.dashboardId, revision: manifest.revision, view: webView) {
                            reply(id: id, identity: identity, error: "permission_required"); return
                        }
                        reply(id: id, identity: identity, value: try interactiveMaps.request(operation: operation, parameters: parameters))
                    } catch { reply(id: id, identity: identity, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline") }
                    return
                }
                let request: MapPreviewRequest
                do { request = try MapPreviewRequest(parameters) }
                catch { reply(id: id, identity: identity, error: "validation_failed"); return }
                guard mapApproval.allowed(dashboard: manifest.dashboardId, revision: manifest.revision, view: webView) else {
                    reply(id: id, identity: identity, error: "permission_required"); return
                }
                tasks[id] = RegisteredTask(identity: identity, task: Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.removeOperation(id, identity: identity) }
                    guard await self.current(identity, requestID: id) else { return }
                    let deadline = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 12_000_000_000)
                        if self.isCurrent(identity), self.owns(id, identity: identity) { self.maps.cancel() }
                    }
                    defer { deadline.cancel() }
                    do {
                        let (data, state) = try await self.maps.render(request)
                        guard await self.current(identity, requestID: id), self.active else { return }
                        var value: [String: Any] = ["state": data == nil ? "unavailable" : "fresh", "status": 200, "code": state]
                        if let data {
                            value["resourceURL"] = try resources.put(.init(state: "fresh", body: data, mime: "image/png", status: 200))
                        }
                        self.reply(id: id, identity: identity, value: value)
                    } catch {
                        guard await self.current(identity, requestID: id), self.active else { return }
                        self.reply(id: id, identity: identity, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline")
                    }
                })
                return
            }
            if ["googleCalendar", "google-calendar"].contains(alias) {
                guard !subscribe, active, operation == "events", let manifest = navigation?.manifest,
                      manifest.connections.contains(where: { $0.alias == alias && ($0.operations == nil || $0.operations?.contains(where: { $0.name == "events" && $0.kind == "http" }) == true) }) else {
                    reply(id: id, identity: identity, error: "permission_required"); return
                }
                let service = calendarService
                let accessGeneration = service.generation
                tasks[id] = RegisteredTask(identity: identity, task: Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.removeOperation(id, identity: identity) }
                    guard await self.current(identity, requestID: id) else { return }
                    do {
                        let result = try await service.events(dashboard: manifest.dashboardId, parameters: parameters)
                        guard await self.current(identity, requestID: id), self.active, service.generation == accessGeneration else { return }
                        self.onHealth(!result.stale)
                        self.reply(id: id, identity: identity, value: result.value, stale: result.stale)
                    } catch {
                        guard await self.current(identity, requestID: id), self.active else { return }
                        self.reply(id: id, identity: identity, error: (error as? GoogleCalendarError)?.rawValue ?? "device_offline")
                    }
                })
                return
            }
            if !subscribe && alias == "googleTV" {
                guard active, let dashboardID = navigation?.manifest.dashboardId else { reply(id: id, identity: identity, error: "permission_required"); return }
                if operation == "voice" || operation == "launchChannel" || operation == "togglePower" {
                    guard trustedTVTap else {
                        reply(id: id, identity: identity, error: "Google TV voice, channel launch, and direct power require an explicit tap."); return
                    }
                }
                tasks[id] = RegisteredTask(identity: identity, task: Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.removeOperation(id, identity: identity) }
                    guard await self.current(identity, requestID: id) else { return }
                    do {
                        let value: [String: Any]
                        if let fixture = self.fixtureGoogleTVRequest { value = try await fixture(dashboardID, operation, parameters) }
                        else if operation == "launchChannel" { value = try await self.googleTVADB.launch(dashboard: dashboardID, parameters: parameters) }
                        else if operation == "togglePower" { value = try await self.googleTVADB.togglePower(dashboard: dashboardID, parameters: parameters) }
                        else { value = try await self.googleTV.request(dashboardID: dashboardID, operation: operation, parameters: parameters) }
                        guard await self.current(identity, requestID: id) else { return }
                        self.reply(id: id, identity: identity, value: value)
                    } catch {
                        guard await self.current(identity, requestID: id) else { return }
                        self.reply(id: id, identity: identity, error: error.localizedDescription)
                    }
                })
                return
            }
            if !subscribe, let publicReads, publicReads.aliases.contains(alias) {
                guard publicTasks.count < 16, publicTasks[id] == nil else { reply(id: id, identity: identity, error: "size_limit"); return }
                publicTasks[id] = RegisteredTask(identity: identity, task: Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.removeOperation(id, identity: identity, isPublic: true) }
                    guard await self.current(identity, requestID: id) else { return }
                    do {
                        let result = try await publicReads.request(alias: alias, operation: operation, parameters: parameters)
                        guard await self.current(identity, requestID: id) else { return }
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
                        self.reply(id: id, identity: identity, value: value, stale: result.state == "stale")
                    } catch {
                        guard await self.current(identity, requestID: id) else { return }
                        self.reply(id: id, identity: identity, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline")
                    }
                })
                return
            }
            if !subscribe && alias == "home" && (operation == "cameraPresent" || operation == "cameraClose") {
                guard alias == "home", let cameras else { reply(id: id, identity: identity, error: "permission_required"); return }
                do { reply(id: id, identity: identity, value: try cameras.request(operation: operation, parameters: parameters)) }
                catch { reply(id: id, identity: identity, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline") }
                return
            }
            tasks[id] = RegisteredTask(identity: identity, task: Task { [weak self] in
                guard let self else { return }
                defer { self.removeOperation(id, identity: identity) }
                guard await self.current(identity, requestID: id) else { return }
                do {
                    if subscribe { try await self.subscribe(id: id, alias: alias, operation: operation, parameters: parameters, identity: identity) }
                    else {
                        let result: ConnectionHTTPResult
                        if let managedRuntime = self.managedRuntime {
                            result = try await managedRuntime.request(alias: alias, operation: operation, parameters: parameters)
                        } else if alias == "home", let runtime = self.runtime {
                            result = try await runtime.request(revision: self.revision, alias: alias, operation: operation, parameters: parameters)
                        } else if let connections = self.connections {
                            result = try await connections.request(alias: alias, operation: operation, parameters: parameters)
                        } else { throw ConnectionFailure.permissionRequired }
                        guard await self.current(identity, requestID: id) else { return }
                        let value = try JSONSerialization.jsonObject(with: result.body, options: .fragmentsAllowed)
                        self.onHealth(!result.stale); self.reply(id: id, identity: identity, value: value, stale: result.stale)
                    }
                } catch {
                    guard await self.current(identity, requestID: id) else { return }
                    self.onHealth(false)
                    self.reply(id: id, identity: identity, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline")
                }
            })
        default: reply(id: id, identity: identity, error: "permission_required")
        }
    }

    private func isCurrent(_ identity: RequestIdentity, requiresActive: Bool = true) -> Bool {
        presentationIsOpen() && !isSuspendedForReset && (!requiresActive || active) && identity.document == documentGeneration && !Task.isCancelled
    }
    private func current(_ identity: RequestIdentity, requestID: String) async -> Bool {
        guard isCurrent(identity), owns(requestID, identity: identity) else { return false }
        guard let qualification else { return true }
        do { try await BridgeQualificationWait().run(timing: timing, pool: qualificationPool) { try qualification(true) } }
        catch {
            if isCurrent(identity), owns(requestID, identity: identity) {
                reply(id: requestID, identity: identity, error: (error as? ConnectionFailure)?.rawValue ?? "permission_required")
            }
            return false
        }
        return isCurrent(identity) && owns(requestID, identity: identity)
    }

    private func subscribe(id: String, alias: String, operation: String, parameters: [String: String], identity: RequestIdentity) async throws {
        guard await current(identity, requestID: id) else { return }
        if let managedRuntime {
            let stream = try await managedRuntime.subscribe(alias: alias, operation: operation, parameters: parameters)
            guard await current(identity, requestID: id) else { return }; reply(id: id, identity: identity, value: NSNull())
            for try await update in stream {
                guard await current(identity, requestID: id) else { return }; onHealth(true)
                event(id: id, identity: identity, alias: alias, operation: operation, data: update.data, snapshot: update.isSnapshot)
            }
        } else if alias == "home", let runtime {
            let stream = try await runtime.subscribeStates(revision: revision, alias: alias, operation: operation, parameters: parameters)
            guard await current(identity, requestID: id) else { return }
            reply(id: id, identity: identity, value: NSNull())
            for try await update in stream {
                guard await current(identity, requestID: id) else { return }
                onHealth(true)
                event(id: id, identity: identity, alias: alias, operation: operation, data: update.data, snapshot: update.isSnapshot)
            }
        } else if let connections {
            let subscription = try await connections.subscribe(alias: alias, operation: operation, parameters: parameters)
            guard await current(identity, requestID: id) else { await connections.unsubscribe(id: subscription); return }
            reply(id: id, identity: identity, value: NSNull())
            do {
                try await withTaskCancellationHandler(operation: {
                    while await current(identity, requestID: id) {
                        let data = try await connections.receive(id: subscription)
                        guard await current(identity, requestID: id) else { break }
                        onHealth(true); event(id: id, identity: identity, alias: alias, operation: operation, data: data, snapshot: false)
                    }
                }, onCancel: { Task { await connections.unsubscribe(id: subscription) } })
                await connections.unsubscribe(id: subscription)
            } catch { await connections.unsubscribe(id: subscription); throw error }
        } else { throw ConnectionFailure.permissionRequired }
    }

    private func event(id: String, identity: RequestIdentity, alias: String, operation: String, data: Data, snapshot: Bool) {
        guard isCurrent(identity), owns(id, identity: identity) else { return }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return }
        dispatch(["protocolVersion": 1, "id": id, "kind": "event", "method": "connections.subscribe", "alias": alias,
                  "operation": operation, "value": value, "snapshot": snapshot])
    }

    private func reply(id: String, identity: RequestIdentity, value: Any = NSNull(), stale: Bool = false, error: String? = nil) {
        guard presentationIsOpen(), !isSuspendedForReset, identity.document == documentGeneration, requestTokens[id] == identity else { return }
        requestTokens[id] = nil
        requestDeadlines.removeValue(forKey: id)?.cancel()
        if tvRequests[id] == identity { tvRequests[id] = nil }
        removeAdmission(id, identity: identity)
        var message: [String: Any] = ["protocolVersion": 1, "id": id, "kind": error == nil ? "response" : "error",
                                      "ok": error == nil, "stale": stale]
        if let error { message["code"] = error; message["message"] = error }
        else { message["value"] = value }
        dispatch(message)
    }

    private func dispatch(_ message: [String: Any], suspensionDenial: Bool = false) {
        let allowed = presentationAllowed()
        guard allowed || suspensionDenial else { suspendPresentation(); return }
        guard !isSuspendedForReset, lifetime?.isRetired != true else { return }
        observeReply?(message)
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
