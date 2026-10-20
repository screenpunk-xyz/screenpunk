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
    private let presentationAllowed: @Sendable () -> Bool
    private var effectEpoch = UUID()
    private var mounted = false
    private var retired = false
    func setMounted() { guard presentationAllowed(), !retired, !lifetime.isRetired else { return }; mounted = true }
    private var pending = [UUID: Task<Void, Never>]()
    private var pendingReplies = [UUID: (Any?, String?) -> Void]()
    init(lifetime: DeviceRuntimeLifetime, declaredOperations: Set<String>, presentationAllowed: @escaping @Sendable () -> Bool = { true }, invoke: @escaping CloudScreenServiceInvocation) {
        self.presentationAllowed = presentationAllowed; self.lifetime = lifetime; self.invoke = invoke; self.declaredOperations = declaredOperations
    }
    func suspendPresentation() { setActive(false, settlePendingForSuspension:true) }
    func setActive(_ value: Bool, settlePendingForSuspension: Bool = false) {
        let next = value && presentationAllowed()
        guard active != next || (settlePendingForSuspension && !pending.isEmpty) else { return }; active = next
        if !next {
            effectEpoch = UUID()
            let replies = settlePendingForSuspension && !retired && !lifetime.isRetired ? Array(pendingReplies.values) : []
            for task in pending.values { task.cancel() }; pending.removeAll(); pendingReplies.removeAll()
            for reply in replies { reply(nil,"service_disconnected") }
        }
    }
    func retire() { effectEpoch = UUID(); retired = true; mounted = false; for task in pending.values { task.cancel() }; pending.removeAll(); pendingReplies.removeAll() }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard presentationAllowed() else { suspendPresentation(); replyHandler(nil, "service_request_denied"); return }
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
        let epoch = effectEpoch
        var replied = false
        let settle: (Any?, String?) -> Void = { value, error in
            guard !replied else { return }; replied = true; replyHandler(value,error)
        }
        pendingReplies[invocation] = settle
        pending[invocation] = Task { [weak self] in
            guard let self else { settle(nil, "service_disconnected"); return }
            defer { if self.effectEpoch == epoch { self.pending[invocation] = nil; self.pendingReplies[invocation] = nil } }
            guard self.presentationAllowed() else { self.suspendPresentation(); settle(nil, "service_disconnected"); return }
            guard self.active, self.effectEpoch == epoch else { settle(nil, "service_disconnected"); return }
            do {
                try Task.checkCancellation()
                let bytes = try await self.invoke(invocation, binding, operation, input)
                try Task.checkCancellation()
                guard self.presentationAllowed(), self.effectEpoch == epoch, self.active, !self.retired, !self.lifetime.isRetired, bytes.count <= 65536 else { throw CancellationError() }
                let receipt = try JSONSerialization.jsonObject(with: bytes)
                settle(receipt, nil)
            } catch {
                guard self.presentationAllowed(), self.effectEpoch == epoch, self.active, !self.retired else { settle(nil, "service_disconnected"); return }
                let code = (error as? LocalizedError)?.errorDescription ?? "service_unavailable"
                let allowedCodes = ["service_offline", "service_quota_exhausted", "service_disconnected", "service_unavailable"]
                settle(nil, self.lifetime.isRetired || error is CancellationError ? "service_disconnected" : (allowedCodes.contains(code) ? code : "service_unavailable"))
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
