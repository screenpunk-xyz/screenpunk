import Foundation
import ScreenpunkCore
import WebKit

/// Only the top-level package frame may invoke the native service. It never
/// accepts origins, headers, credentials, arbitrary paths. Service calls require owner-installed declarations.
@MainActor
final class HomeAssistantWebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private let runtime: HomeAssistantDeviceRuntime?
    private let revision: String
    private let cameras: CameraPlaybackController?
    private let publicReads: PublicReadRuntime?
    private let resources: PublicRasterResources?
    private var publicTasks: [String: Task<Void, Never>] = [:]
    private let onHealth: (Bool) -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(runtime: HomeAssistantDeviceRuntime?, revision: String, publicReads: PublicReadRuntime? = nil, resources: PublicRasterResources? = nil, onHealth: @escaping (Bool) -> Void) {
        self.cameras = runtime.map { CameraPlaybackController(resolver: $0, revision: revision) }
        self.publicReads = publicReads; self.resources = resources
        self.runtime = runtime; self.revision = revision; self.onHealth = onHealth
    }
    func attach(to webView: WKWebView) { self.webView = webView; cameras?.attach(webView) }
    func cancel() {
        for task in publicTasks.values { task.cancel() }; publicTasks.removeAll(); resources?.clear()
        let reads = publicReads; Task { await reads?.cancel() }
        cameras?.stopAll(); for task in tasks.values { task.cancel() }; tasks.removeAll() }


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
            reply(id: id, value: ["homeAssistantTransport": "http-polling", "homeAssistantServiceCalls": 1, "cameraPlayback": 1, "publicReadHTTP": 1, "macIsRuntimeProxy": false])
        case "state.get": reply(id: id, value: NSNull())
        case "connections.cancel":
            if let target = (body["parameters"] as? [String: String])?["requestId"] { publicTasks.removeValue(forKey: target)?.cancel() }
            reply(id: id, value: NSNull())
        case "connections.release":
            if let url = (body["parameters"] as? [String: String])?["resourceURL"] { resources?.release(url: url) }
            reply(id: id, value: NSNull())
        case "connections.request":
            guard let alias = body["alias"] as? String, let operation = body["operation"] as? String,
                  let parameters = body["parameters"] as? [String: String], tasks.count < 4 else {
                reply(id: id, error: "validation_failed"); return
            }
            if alias != "home", let publicReads {
                guard publicTasks.count < 16, publicTasks[id] == nil else { reply(id: id, error: "size_limit"); return }
                publicTasks[id] = Task { @MainActor [weak self] in
                    defer { self?.publicTasks.removeValue(forKey: id) }
                    do {
                        let result = try await publicReads.request(alias: alias, operation: operation, parameters: parameters)
                        guard !Task.isCancelled, let self else { return }
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
                        guard !Task.isCancelled else { return }
                        self?.reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline")
                    }
                }
                return
            }
            guard let runtime else { reply(id: id, error: "permission_required"); return }
            if operation == "cameraPresent" || operation == "cameraClose" {
                guard alias == "home", let cameras else { reply(id: id, error: "permission_required"); return }
                do { reply(id: id, value: try cameras.request(operation: operation, parameters: parameters)) }
                catch { reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline") }
                return
            }
            let taskId = UUID()
            tasks[taskId] = Task { @MainActor [weak self, runtime, revision] in
                do {
                    let result = try await runtime.request(revision: revision, alias: alias, operation: operation, parameters: parameters)
                    guard !Task.isCancelled, let self else { return }
                    let value = try JSONSerialization.jsonObject(with: result.body, options: .fragmentsAllowed)
                    self.onHealth(!result.stale)
                    self.reply(id: id, value: value, stale: result.stale)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.onHealth(false)
                    self.reply(id: id, error: (error as? ConnectionFailure)?.rawValue ?? "device_offline")
                }
                self?.tasks.removeValue(forKey: taskId)
            }
        default: reply(id: id, error: "permission_required")
        }
    }

    private func reply(id: String, value: Any = NSNull(), stale: Bool = false, error: String? = nil) {
        var message: [String: Any] = ["protocolVersion": 1, "id": id, "kind": error == nil ? "response" : "error",
                                      "ok": error == nil, "stale": stale]
        if let error { message["code"] = error; message["message"] = error }
        else { message["value"] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return }
        // JSON is an argument, never interpolated as executable JavaScript.
        webView?.callAsyncJavaScript("if (typeof globalThis.__screenpunkDispatch === 'function') globalThis.__screenpunkDispatch(JSON.parse(message));",
                                    arguments: ["message": json], in: nil, in: .page, completionHandler: { _ in })
    }
}
