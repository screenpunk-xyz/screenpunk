import Foundation
import ScreenpunkCore
import WebKit

/// Only the top-level package frame may invoke the native service. It never
/// accepts origins, headers, credentials, arbitrary paths, or arbitrary services.
final class HomeAssistantWebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private let runtime: HomeAssistantDeviceRuntime
    private let revision: String
    private let onHealth: (Bool) -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(runtime: HomeAssistantDeviceRuntime, revision: String, onHealth: @escaping (Bool) -> Void) {
        self.runtime = runtime; self.revision = revision; self.onHealth = onHealth
    }
    func attach(to webView: WKWebView) { self.webView = webView }
    func cancel() { for task in tasks.values { task.cancel() }; tasks.removeAll() }
    deinit { cancel() }

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
            reply(id: id, value: ["homeAssistantTransport": "http-polling", "macIsRuntimeProxy": false])
        case "state.get": reply(id: id, value: NSNull())
        case "connections.request":
            guard let alias = body["alias"] as? String, let operation = body["operation"] as? String,
                  let parameters = body["parameters"] as? [String: String], tasks.count < 4 else {
                reply(id: id, error: "validation_failed"); return
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
