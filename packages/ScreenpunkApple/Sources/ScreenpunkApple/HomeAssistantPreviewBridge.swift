#if os(macOS)
import Foundation
import WebKit
import ScreenpunkCore

/// Reuses the phone's native bridge for the hidden, local Mac preview host.
public final class HomeAssistantPreviewBridge {
    private let bridge: HomeAssistantWebBridge
    public init(configuration: WKWebViewConfiguration, provisioning: HomeAssistantProvisioning) throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.provision(provisioning, owner: "native-preview")
        let runtime = HomeAssistantDeviceRuntime(vault: vault, scope: {
            .init(owner: "native-preview", revision: provisioning.revision, dashboardId: provisioning.dashboardId)
        })
        let revision = provisioning.revision
        bridge = HomeAssistantWebBridge(runtime: runtime, revision: revision, onHealth: { _ in })
        guard let url = Bundle.module.url(forResource: "runtime-sdk", withExtension: "js") else { throw CocoaError(.fileNoSuchFile) }
        let source = try String(contentsOf: url)
        configuration.userContentController.add(bridge, name: "screenpunk")
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    public func attach(to webView: WKWebView) { bridge.attach(to: webView) }
    deinit { bridge.cancel() }
}
#endif
