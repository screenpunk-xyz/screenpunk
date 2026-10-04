import SwiftUI
@_spi(ManagedRender) import ScreenpunkCore
#if canImport(WebKit)
import WebKit

/// NON-AUTHORIZING and unmounted. A future genuine installation-admitted owner must gate whether
/// this view exists. Opaque resource content is not Cloud authority, activation or a Local lease.
/// The view uses the explicitly supplied presentation lifetime; its future admitted owner must
/// retire that lifetime on revocation. Asset requests use the immutable snapshot, not per-request
/// store admission. It never creates a LAN host or shared mutable services.
#if os(iOS)
@_spi(ManagedRender) public struct DeviceManagedRenderView:UIViewRepresentable {
    private let content:DeviceManagedStaticContent
    private let lifetime:DeviceRuntimeLifetime
    public init(content:DeviceManagedStaticContent,lifetime:DeviceRuntimeLifetime){self.content=content;self.lifetime=lifetime}
    public func makeCoordinator()->DashboardWebCoordinator{.init(managedStatic:content,lifetime:lifetime)}
    public func makeUIView(context:Context)->WKWebView{context.coordinator.makeWebView()}
    public func updateUIView(_ view:WKWebView,context:Context){context.coordinator.updateManagedStatic(content:content,lifetime:lifetime)}
    public static func dismantleUIView(_ view:WKWebView,coordinator:DashboardWebCoordinator){coordinator.retireForReset()}
}
#elseif os(macOS)
@_spi(ManagedRender) public struct DeviceManagedRenderView:NSViewRepresentable {
    private let content:DeviceManagedStaticContent
    private let lifetime:DeviceRuntimeLifetime
    public init(content:DeviceManagedStaticContent,lifetime:DeviceRuntimeLifetime){self.content=content;self.lifetime=lifetime}
    public func makeCoordinator()->DashboardWebCoordinator{.init(managedStatic:content,lifetime:lifetime)}
    public func makeNSView(context:Context)->WKWebView{context.coordinator.makeWebView()}
    public func updateNSView(_ view:WKWebView,context:Context){context.coordinator.updateManagedStatic(content:content,lifetime:lifetime)}
    public static func dismantleNSView(_ view:WKWebView,coordinator:DashboardWebCoordinator){coordinator.retireForReset()}
}
#endif
#endif
