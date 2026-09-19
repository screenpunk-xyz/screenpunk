#if os(macOS)
import Foundation
import WebKit
import ScreenpunkCore

/// Reuses the phone's native bridge for the hidden, local Mac preview host.
@MainActor
public final class HomeAssistantPreviewBridge {
    private let bridge: HomeAssistantWebBridge
    private var publicSession: PublicReadSession?
    public convenience init(configuration: WKWebViewConfiguration, provisioning: HomeAssistantProvisioning) throws {
        try self.init(configuration: configuration, connections: .init(homeAssistant: provisioning), revision: provisioning.revision)
    }
    public init(configuration: WKWebViewConfiguration, connections: NativePreviewConnections, revision: String, publicTransport: any HTTPTransport = HomeAssistantHTTPTransport(), publicResolver: any DestinationResolver = LiteralOrResolvedDestinationResolver()) throws {
        let runtime: HomeAssistantDeviceRuntime?
        if let provisioning = connections.homeAssistant {
            let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
            try vault.provision(provisioning, owner: "native-preview")
            runtime = HomeAssistantDeviceRuntime(vault: vault, scope: {
                .init(owner: "native-preview", revision: provisioning.revision, dashboardId: provisioning.dashboardId)
            })
        } else { runtime = nil }
        if let provisioning = connections.publicReads { publicSession = try PublicReadSession(provisioning: provisioning, transport: publicTransport, resolver: publicResolver) }
        bridge = HomeAssistantWebBridge(runtime: runtime, revision: revision, publicReads: publicSession?.runtime,
                                        resources: publicSession?.resources, onHealth: { _ in })
        guard let url = Bundle.module.url(forResource: "runtime-sdk", withExtension: "js") else { throw CocoaError(.fileNoSuchFile) }
        let source = try String(contentsOf: url)
        configuration.userContentController.add(bridge, name: "screenpunk")
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    public var rasterResources: PublicRasterResources? { publicSession?.resources }
    public func attach(to webView: WKWebView) { bridge.attach(to: webView) }
    deinit { let bridge = bridge; Task { @MainActor in bridge.cancel() } }
}
#endif
