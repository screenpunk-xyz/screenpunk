import Foundation
import CoreFoundation
import ScreenpunkCore
#if canImport(WebKit)
import WebKit

/// The host owns this callback. It must validate its current presentation and
/// construct a fixed opaque-credential request; package JavaScript receives
/// only bounded service receipts. Server binding approval is always required.
public typealias CloudScreenServiceInvocation = @MainActor (UUID, UUID, String, String) async throws -> Data

@MainActor final class CloudScreenServiceBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let invoke: CloudScreenServiceInvocation
    private let declaredOperations: Set<String>
    private let lifetime: DeviceRuntimeLifetime
    private var active = true
    private var mounted = false
    private var retired = false
    func setMounted() { guard !retired, !lifetime.isRetired else { return }; mounted = true }
    private var pending = [UUID: Task<Void, Never>]()
    init(lifetime: DeviceRuntimeLifetime, declaredOperations: Set<String>, invoke: @escaping CloudScreenServiceInvocation) {
        self.lifetime = lifetime; self.invoke = invoke; self.declaredOperations = declaredOperations
    }
    func setActive(_ value: Bool) { active = value; if !value { for task in pending.values { task.cancel() } } }
    func retire() { retired = true; mounted = false; for task in pending.values { task.cancel() }; pending.removeAll() }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard !retired, active, mounted, !lifetime.isRetired, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == IsolationPolicy.customScheme,
              message.frameInfo.securityOrigin.host == IsolationPolicy.packageHost,
              pending.count < 16, let body = message.body as? [String: Any],
              Set(body.keys) == Set(["invocationId", "bindingId", "operation", "input"]),
              let invocationText = body["invocationId"] as? String, let invocation = UUID(uuidString: invocationText),
              let bindingText = body["bindingId"] as? String, let binding = UUID(uuidString: bindingText),
              let operation = body["operation"] as? String, declaredOperations.contains(operation),
              let input = body["input"] as? String, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.utf8.count <= (operation == "weather.read" ? 128 : 4096), pending[invocation] == nil else {
            replyHandler(nil, "service_request_denied"); return
        }
        pending[invocation] = Task { [weak self] in
            guard let self else { replyHandler(nil, "service_disconnected"); return }
            defer { self.pending[invocation] = nil }
            do {
                try Task.checkCancellation()
                let bytes = try await self.invoke(invocation, binding, operation, input)
                try Task.checkCancellation()
                guard self.active, !self.retired, !self.lifetime.isRetired, bytes.count <= 65536 else { throw CancellationError() }
                let receipt = try JSONSerialization.jsonObject(with: bytes)
                replyHandler(receipt, nil)
            } catch {
                let code = (error as? LocalizedError)?.errorDescription ?? "service_unavailable"
                let allowedCodes = ["service_offline", "service_quota_exhausted", "service_disconnected", "service_unavailable"]
                replyHandler(nil, self.lifetime.isRetired || error is CancellationError ? "service_disconnected" : (allowedCodes.contains(code) ? code : "service_unavailable"))
            }
        }
    }
    static func declaredOperations(_ bytes: Data?) -> Set<String> {
        guard let bytes, bytes.count <= 8192,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "requirements"]),
              let version = object["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let requirements = object["requirements"] as? [[String: Any]], requirements.count <= 16 else { return [] }
        var operations = Set<String>()
        for requirement in requirements {
            guard Set(requirement.keys) == Set(["service", "operation"]),
                  requirement["service"] as? String == "fixture.v1",
                  let operation = requirement["operation"] as? String,
                  ["weather.read", "ai.generate"].contains(operation) else { return [] }
            operations.insert(operation)
        }
        return operations
    }
    static let sdk = """
    (() => {
      const invoke = async (operation, input, options = {}) => {
        const invocationId = options.invocationId || crypto.randomUUID();
        const value = operation === 'weather.read' ? input.location : input.prompt;
        return window.webkit.messageHandlers.screenpunkServices.postMessage({
          invocationId, bindingId: options.bindingId, operation, input: value
        });
      };
      Object.defineProperty(window, 'screenpunkServices', {value:Object.freeze({invoke}), writable:false});
    })();
    """
}
#endif
