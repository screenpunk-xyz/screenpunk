import SwiftUI
@_spi(ManagedRender) import ScreenpunkCore
#if canImport(WebKit)
import WebKit

/// Opaque resource content is not installation authority, activation or a Local lease.
/// An installation-admitted owner gates this view and handles mount acknowledgements.
/// The view uses the explicitly supplied presentation lifetime; its admitted owner must
/// retire that lifetime on revocation. Asset requests use the immutable snapshot, not per-request
/// store admission. It never creates a LAN host or shared mutable services.
#if os(iOS)
@_spi(ManagedRender) public struct DeviceManagedRenderView:UIViewRepresentable {
    private let content:DeviceManagedStaticContent
    private let lifetime:DeviceRuntimeLifetime
    private let serviceInvocation:CloudScreenServiceInvocation?
    // Throw only for local qualified-mount validation. The host retains a valid
    // mounted display and pending receipt when acknowledgement networking fails.
    private let serviceMounted:(@MainActor () async throws -> Void)?
    private let serviceMountFailed:(@MainActor (String) async -> Void)?
    public init(content:DeviceManagedStaticContent,lifetime:DeviceRuntimeLifetime,serviceInvocation:CloudScreenServiceInvocation? = nil,serviceMounted:(@MainActor () async throws -> Void)? = nil,serviceMountFailed:(@MainActor (String) async -> Void)? = nil){self.content=content;self.lifetime=lifetime;self.serviceInvocation=serviceInvocation;self.serviceMounted=serviceMounted;self.serviceMountFailed=serviceMountFailed}
    public func makeCoordinator()->DashboardWebCoordinator{.init(managedStatic:content,lifetime:lifetime,serviceInvocation:serviceInvocation,serviceMounted:serviceMounted,serviceMountFailed:serviceMountFailed)}
    public func makeUIView(context:Context)->WKWebView{context.coordinator.makeWebView()}
    public func updateUIView(_ view:WKWebView,context:Context){context.coordinator.updateManagedStatic(content:content,lifetime:lifetime)}
    public static func dismantleUIView(_ view:WKWebView,coordinator:DashboardWebCoordinator){coordinator.retireForReset()}
}
#elseif os(macOS)
@_spi(ManagedRender) public struct DeviceManagedRenderView:NSViewRepresentable {
    private let content:DeviceManagedStaticContent
    private let lifetime:DeviceRuntimeLifetime
    private let serviceInvocation:CloudScreenServiceInvocation?
    // Throw only for local qualified-mount validation. The host retains a valid
    // mounted display and pending receipt when acknowledgement networking fails.
    private let serviceMounted:(@MainActor () async throws -> Void)?
    private let serviceMountFailed:(@MainActor (String) async -> Void)?
    public init(content:DeviceManagedStaticContent,lifetime:DeviceRuntimeLifetime,serviceInvocation:CloudScreenServiceInvocation? = nil,serviceMounted:(@MainActor () async throws -> Void)? = nil,serviceMountFailed:(@MainActor (String) async -> Void)? = nil){self.content=content;self.lifetime=lifetime;self.serviceInvocation=serviceInvocation;self.serviceMounted=serviceMounted;self.serviceMountFailed=serviceMountFailed}
    public func makeCoordinator()->DashboardWebCoordinator{.init(managedStatic:content,lifetime:lifetime,serviceInvocation:serviceInvocation,serviceMounted:serviceMounted,serviceMountFailed:serviceMountFailed)}
    public func makeNSView(context:Context)->WKWebView{context.coordinator.makeWebView()}
    public func updateNSView(_ view:WKWebView,context:Context){context.coordinator.updateManagedStatic(content:content,lifetime:lifetime)}
    public static func dismantleNSView(_ view:WKWebView,coordinator:DashboardWebCoordinator){coordinator.retireForReset()}
}
#endif
#endif
