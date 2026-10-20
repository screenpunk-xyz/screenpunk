import SwiftUI
@_spi(ManagedRender) import ScreenpunkCore
#if canImport(WebKit)
import WebKit
#if os(iOS)
@_spi(ManagedRender) public struct DeviceManagedRuntimeView: UIViewRepresentable {
    private let runtime: DeviceUnifiedManagedRuntime
    private let lifetime: DeviceRuntimeLifetime
    private let mounted: (@MainActor () async throws -> Void)?
    private let failed: (@MainActor (String) async -> Void)?
    private let invoke: CloudScreenServiceInvocation?
    private let presentationAllowed: @Sendable () -> Bool
    public init(runtime: DeviceUnifiedManagedRuntime, lifetime: DeviceRuntimeLifetime,
        presentationAllowed: @escaping @Sendable () -> Bool = { true },
        serviceInvocation: CloudScreenServiceInvocation? = nil,
        mounted: (@MainActor () async throws -> Void)? = nil, failed: (@MainActor (String) async -> Void)? = nil) {
        self.runtime = runtime; self.lifetime = lifetime; self.presentationAllowed = presentationAllowed; self.invoke = serviceInvocation; self.mounted = mounted; self.failed = failed
    }
    public func makeCoordinator() -> DashboardWebCoordinator { .init(managedRuntime: runtime, lifetime: lifetime, presentationAllowed: presentationAllowed, serviceInvocation: invoke, serviceMounted: mounted, serviceMountFailed: failed) }
    public func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    public func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.updateManagedStatic(content: runtime.content, lifetime: lifetime, presentationAllowed: presentationAllowed) }
    public static func dismantleUIView(_ view: WKWebView, coordinator: DashboardWebCoordinator) { coordinator.retireForReset() }
}
#elseif os(macOS)
@_spi(ManagedRender) public struct DeviceManagedRuntimeView: NSViewRepresentable {
    private let runtime: DeviceUnifiedManagedRuntime
    private let lifetime: DeviceRuntimeLifetime
    private let mounted: (@MainActor () async throws -> Void)?
    private let failed: (@MainActor (String) async -> Void)?
    private let invoke: CloudScreenServiceInvocation?
    private let presentationAllowed: @Sendable () -> Bool
    public init(runtime: DeviceUnifiedManagedRuntime, lifetime: DeviceRuntimeLifetime,
        presentationAllowed: @escaping @Sendable () -> Bool = { true },
        serviceInvocation: CloudScreenServiceInvocation? = nil,
        mounted: (@MainActor () async throws -> Void)? = nil, failed: (@MainActor (String) async -> Void)? = nil) {
        self.runtime = runtime; self.lifetime = lifetime; self.presentationAllowed = presentationAllowed; self.invoke = serviceInvocation; self.mounted = mounted; self.failed = failed
    }
    public func makeCoordinator() -> DashboardWebCoordinator { .init(managedRuntime: runtime, lifetime: lifetime, presentationAllowed: presentationAllowed, serviceInvocation: invoke, serviceMounted: mounted, serviceMountFailed: failed) }
    public func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    public func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.updateManagedStatic(content: runtime.content, lifetime: lifetime, presentationAllowed: presentationAllowed) }
    public static func dismantleNSView(_ view: WKWebView, coordinator: DashboardWebCoordinator) { coordinator.retireForReset() }
}
#endif
#endif
