import SwiftUI
@_spi(ManagedRender) import ScreenpunkCore
#if canImport(WebKit)
import WebKit
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

#if os(iOS)
public struct DashboardWebView: UIViewRepresentable {
    @Environment(\.deviceRuntimeLifetime) private var runtimeLifetime
    public var store: PackageAssetStore
    public var onReady: () -> Void
    public var onUnlinkHold: () -> Void
    public var homeAssistant: HomeAssistantDeviceRuntime?
    public var publicReads: PublicReadRuntime?
    public var rasterResources: PublicRasterResources?
    public var revision: String
    public var connections: ConnectionRuntime?
    public var settings: DeviceSettings
    public var active: Bool
    public var onSettingsApplied: (Bool) -> Void
    public var onConnectionHealth: (Bool) -> Void

    public init(store: PackageAssetStore, homeAssistant: HomeAssistantDeviceRuntime? = nil, publicReads: PublicReadRuntime? = nil, rasterResources: PublicRasterResources? = nil, revision: String = "", connections: ConnectionRuntime? = nil, settings: DeviceSettings = .init(), active: Bool = true, onSettingsApplied: @escaping (Bool) -> Void = { _ in }, onConnectionHealth: @escaping (Bool) -> Void = { _ in }, onReady: @escaping () -> Void = {}, onUnlinkHold: @escaping () -> Void) {
        self.store = store
        self.homeAssistant = homeAssistant
        self.publicReads = publicReads; self.rasterResources = rasterResources
        self.revision = revision
        self.connections = connections; self.settings = settings; self.active = active; self.onSettingsApplied = onSettingsApplied
        self.onConnectionHealth = onConnectionHealth
        self.onReady = onReady
        self.onUnlinkHold = onUnlinkHold
    }

    public func makeCoordinator() -> DashboardWebCoordinator {
        DashboardWebCoordinator(store: store, lifetime: runtimeLifetime ?? DeviceRuntimeLifetime(), homeAssistant: homeAssistant, publicReads: publicReads, rasterResources: rasterResources, revision: revision, connections: connections, settings: settings, active: active, onSettingsApplied: onSettingsApplied, onConnectionHealth: onConnectionHealth, onReady: onReady, onUnlinkHold: onUnlinkHold)
    }

    public func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    public static func dismantleUIView(_ view: WKWebView, coordinator: DashboardWebCoordinator) { coordinator.stop() }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onUnlinkHold = onUnlinkHold
        context.coordinator.update(settings: settings, active: active, onSettingsApplied: onSettingsApplied)
    }
}

#elseif os(macOS)
public struct DashboardWebView: NSViewRepresentable {
    @Environment(\.deviceRuntimeLifetime) private var runtimeLifetime
    public var store: PackageAssetStore
    public var onReady: () -> Void
    public var onUnlinkHold: () -> Void
    public var homeAssistant: HomeAssistantDeviceRuntime?
    public var publicReads: PublicReadRuntime?
    public var rasterResources: PublicRasterResources?
    public var revision: String
    public var connections: ConnectionRuntime?
    public var settings: DeviceSettings
    public var active: Bool
    public var onSettingsApplied: (Bool) -> Void
    public var onConnectionHealth: (Bool) -> Void

    public init(store: PackageAssetStore, homeAssistant: HomeAssistantDeviceRuntime? = nil, publicReads: PublicReadRuntime? = nil, rasterResources: PublicRasterResources? = nil, revision: String = "", connections: ConnectionRuntime? = nil, settings: DeviceSettings = .init(), active: Bool = true, onSettingsApplied: @escaping (Bool) -> Void = { _ in }, onConnectionHealth: @escaping (Bool) -> Void = { _ in }, onReady: @escaping () -> Void = {}, onUnlinkHold: @escaping () -> Void) {
        self.store = store
        self.homeAssistant = homeAssistant
        self.publicReads = publicReads; self.rasterResources = rasterResources
        self.revision = revision
        self.connections = connections; self.settings = settings; self.active = active; self.onSettingsApplied = onSettingsApplied
        self.onConnectionHealth = onConnectionHealth
        self.onReady = onReady
        self.onUnlinkHold = onUnlinkHold
    }

    public func makeCoordinator() -> DashboardWebCoordinator {
        DashboardWebCoordinator(store: store, lifetime: runtimeLifetime ?? DeviceRuntimeLifetime(), homeAssistant: homeAssistant, publicReads: publicReads, rasterResources: rasterResources, revision: revision, connections: connections, settings: settings, active: active, onSettingsApplied: onSettingsApplied, onConnectionHealth: onConnectionHealth, onReady: onReady, onUnlinkHold: onUnlinkHold)
    }

    public func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    public static func dismantleNSView(_ view: WKWebView, coordinator: DashboardWebCoordinator) { coordinator.stop() }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onUnlinkHold = onUnlinkHold
        context.coordinator.update(settings: settings, active: active, onSettingsApplied: onSettingsApplied)
    }
}
#endif

@MainActor
public final class DashboardWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let handler: PackageSchemeHandler
    var onReady: () -> Void
    var onUnlinkHold: () -> Void
    private let lifetime: DeviceRuntimeLifetime
    private let managedStaticContent: DeviceManagedStaticContent?
    var hasCapabilityBridge: Bool { bridge != nil }
    var hasEventRuntime: Bool { events != nil }
    private var retirementRegistration: UUID?
    private(set) var isRetired = false
    private var installedRules = false
    private var bridge: HomeAssistantWebBridge?
    private var events: DashboardEventRuntime?
    private weak var webView: WKWebView?
    private var active: Bool
    private var initialPath = "index.html"
    private var programmaticURL: String?
    private var onSettingsApplied: (Bool) -> Void
    private var settingsValid = true
    private var allowsAudioAutoplay = false

    init(store: PackageAssetStore, lifetime: DeviceRuntimeLifetime = DeviceRuntimeLifetime(), preferenceStore: ScreenPreferenceStore? = nil, homeAssistant: HomeAssistantDeviceRuntime? = nil, publicReads: PublicReadRuntime? = nil, rasterResources: PublicRasterResources? = nil, revision: String = "", connections: ConnectionRuntime? = nil, settings: DeviceSettings = .init(), active: Bool = true, onSettingsApplied: @escaping (Bool) -> Void = { _ in }, onConnectionHealth: @escaping (Bool) -> Void = { _ in }, onReady: @escaping () -> Void = {}, onUnlinkHold: @escaping () -> Void) {
        self.lifetime = lifetime
        managedStaticContent = nil
        let rasterResources = rasterResources ?? PublicRasterResources()
        self.handler = PackageSchemeHandler(store: store, rasterResources: rasterResources)
        self.onReady = onReady
        self.onUnlinkHold = onUnlinkHold
        self.active = active; self.onSettingsApplied = onSettingsApplied
        guard !lifetime.isRetired else {
            super.init(); isRetired = true; self.active = false; self.onReady = {}; self.onUnlinkHold = {}; self.onSettingsApplied = { _ in }; return
        }
        if let data = store.assets["manifest.json"]?.data {
            do {
                let manifest = try JSONDecoder().decode(DashboardManifest.self, from: data)
                try manifest.deviceBehavior?.validate()
                let events = try DashboardEventRuntime(manifest: manifest, revision: revision, settings: settings,
                                                       homeAssistant: homeAssistant, connections: connections)
                allowsAudioAutoplay = manifest.deviceBehavior?.allowsAudioAutoplay == true
                self.events = events; initialPath = events.page.path; settingsValid = events.settingsApplied
            } catch { settingsValid = false }
        }
        super.init()
        let health: (Bool) -> Void = { [weak self] value in
            guard let self, !self.isRetired, !self.lifetime.isRetired else { return }
            onConnectionHealth(value)
        }
        self.bridge = HomeAssistantWebBridge(runtime: homeAssistant, connections: connections, navigation: events,
                                              revision: revision, preferenceStore: preferenceStore ?? .shared, publicReads: publicReads, resources: rasterResources, onHealth: health)
        events?.onPage = { [weak self] page in self?.load(path: page.path) }
        events?.onStatus = { [weak self] status in self?.bridge?.status(status) }
        events?.onHealth = health
        retirementRegistration = lifetime.register { [weak self] in self?.retireForReset() }
    }

    /// Non-authorizing, unmounted static transport. No capability bridge, preferences, event
    /// runtime, raster resources, mutable credentials or Local host are constructed in this path.
    init(managedStatic content: DeviceManagedStaticContent, lifetime: DeviceRuntimeLifetime) {
        self.lifetime = lifetime; managedStaticContent = content
        let valid = !lifetime.isRetired && (try? content.verifyResources()) != nil
        var assets: [String: PackageAsset] = [:]
        if valid {
            for asset in content.assets {
                assets[asset.path] = .init(path: asset.path, data: asset.bytes, mime: PackageAssetStore.mime(for: asset.path))
            }
        }
        handler = PackageSchemeHandler(store: .init(assets: assets), rasterResources: nil)
        onReady = {}; onUnlinkHold = {}; onSettingsApplied = { _ in }; active = valid
        initialPath = content.entrypoint; settingsValid = valid
        super.init()
        guard valid else { isRetired = true; return }
        retirementRegistration = lifetime.register { [weak self] in self?.retireForReset() }
    }
    /// SwiftUI may reuse a coordinator while replacing value-view properties. Never adopt new
    /// content or lifetime into an existing static renderer; the parent must recreate it explicitly.
    func updateManagedStatic(content: DeviceManagedStaticContent, lifetime: DeviceRuntimeLifetime) {
        guard let original = managedStaticContent, original === content, self.lifetime === lifetime else {
            retireForReset(); return
        }
        update(settings: .init(), active: true, onSettingsApplied: { _ in })
    }
    private func managedResourcesValid() -> Bool {
        guard let content = managedStaticContent else { return true } // Existing legacy path unchanged.
        do { try content.verifyResources(); return true }
        catch { retireForReset(); return false }
    }
    func update(settings: DeviceSettings, active: Bool, onSettingsApplied: @escaping (Bool) -> Void) {
        guard managedResourcesValid(), !isRetired, !lifetime.isRetired else { return }
        self.onSettingsApplied = onSettingsApplied
        events?.update(settings: settings)
        if let events { settingsValid = events.settingsApplied }
        self.active = active
        bridge?.setActive(active)
        if active { events?.start() } else { events?.stop(); bridge?.cancel(); webView?.pauseAllMediaPlayback(completionHandler: nil) }
        // Defer callback to avoid publishing SwiftUI state during view update.
        let valid = settingsValid
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRetired, !self.lifetime.isRetired else { return }
            onSettingsApplied(valid)
        }
    }

    func retireForReset() {
        guard !isRetired else { return }
        isRetired = true; active = false
        lifetime.unregister(retirementRegistration); retirementRegistration = nil
        bridge?.suspendForReset(); events?.stop()
        events?.onPage = nil; events?.onStatus = nil; events?.onHealth = nil
        onReady = {}; onUnlinkHold = {}; onSettingsApplied = { _ in }
        if let webView {
            webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
            webView.pauseAllMediaPlayback(completionHandler: nil)
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
#if os(iOS)
            webView.scrollView.delegate = nil
#endif
        }
        webView = nil; programmaticURL = nil
    }

    func stop() { bridge?.setActive(false); events?.stop(); bridge?.cancel(); webView?.pauseAllMediaPlayback(completionHandler: nil) }

    private func load(path: String) {
        guard managedResourcesValid(), !isRetired, !lifetime.isRetired else { return }
        guard let url = URL(string: "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/\(path)") else { return }
        bridge?.cancel(); programmaticURL = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    deinit {
        let bridge = bridge, lifetime = lifetime, registration = retirementRegistration
        Task { @MainActor in lifetime.unregister(registration); bridge?.cancel() }
    }

    func makeWebView() -> WKWebView {
        guard managedResourcesValid(), !isRetired, !lifetime.isRetired else {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            return WKWebView(frame: .zero, configuration: config)
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        BundledAudio.configure(config)
        if allowsAudioAutoplay { config.mediaTypesRequiringUserActionForPlayback = .video }
        config.setURLSchemeHandler(handler, forURLScheme: IsolationPolicy.customScheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if let bridge {
            config.userContentController.add(bridge, name: "screenpunk")
            bridge.installVoiceTapGate(config.userContentController)
            if let url = Bundle.module.url(forResource: "runtime-sdk", withExtension: "js"),
               let source = try? String(contentsOf: url) {
                config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        self.webView = webView
        bridge?.attach(to: webView)
        bridge?.setActive(active)
        webView.navigationDelegate = self
        webView.uiDelegate = self
#if os(iOS)
        webView.isOpaque = true
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.bouncesZoom = false
        // One-finger gestures belong to the dashboard; two fingers are native navigation.
        webView.scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.delegate = self
#endif
#if os(iOS)
        config.userContentController.addUserScript(WKUserScript(
            source: Self.fixedViewportScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
#endif
        installUnlinkRecognizer(on: webView)
        installContentRules(on: webView)
        load(path: initialPath)
        if active { events?.start() }
        DispatchQueue.main.async { [weak self] in guard let self, !self.isRetired, !self.lifetime.isRetired else { return }; self.onSettingsApplied(self.settingsValid) }
        return webView
    }

    private func installContentRules(on webView: WKWebView) {
        guard !isRetired, !lifetime.isRetired, !installedRules else { return }
        installedRules = true
        let data = Data(IsolationPolicy.contentRuleListJSON.utf8)
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "screenpunk-isolation",
            encodedContentRuleList: String(data: data, encoding: .utf8) ?? "[]"
        ) { [weak self, weak webView] list, _ in
            guard let self, !self.isRetired, !self.lifetime.isRetired, let webView else { return }
            if let list {
                webView.configuration.userContentController.add(list)
            }
        }
    }

    private func installUnlinkRecognizer(on webView: WKWebView) {
#if os(iOS)
        let recognizer = TwoFingerHoldRecognizer { [weak self] in
            guard let self, !self.isRetired, !self.lifetime.isRetired else { return }
            self.onUnlinkHold()
        }
        recognizer.cancelsTouchesInView = false
        webView.addGestureRecognizer(recognizer)
#elseif os(macOS)
        let recognizer = TwoFingerHoldRecognizer { [weak self] in
            guard let self, !self.isRetired, !self.lifetime.isRetired else { return }
            self.onUnlinkHold()
        }
        webView.addGestureRecognizer(recognizer)
#endif
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard managedResourcesValid(), !isRetired, !lifetime.isRetired else { decisionHandler(.cancel); return }
        let url = navigationAction.request.url?.absoluteString ?? ""
        guard IsolationEvaluator.isLocalPackageURL(url) else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true, let events {
            guard let path = navigationAction.request.url?.path.removingPercentEncoding,
                  let page = events.manifest.resolvedPages.first(where: { "/" + $0.path == path }) else {
                decisionHandler(.cancel); return
            }
            if url == programmaticURL { programmaticURL = nil }
            else { events.manualNavigation(pageId: page.id) }
            bridge?.cancel()
        }
        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { guard managedResourcesValid(), !isRetired, !lifetime.isRetired else { return }; onReady() }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isRetired, !lifetime.isRetired else { return }
        bridge?.cancel()
        load(path: events?.page.path ?? initialPath)
    }
}

#if os(iOS)
extension DashboardWebCoordinator: UIScrollViewDelegate {
    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }

    public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard !isRetired, !lifetime.isRetired else { return }
        scrollView.pinchGestureRecognizer?.isEnabled = false
    }

    // Viewport also suppresses double-tap and input-focus magnification while
    // leaving ordinary scrolling and the native accessibility system available.
    static let fixedViewportScript = """
    (() => {
      const value = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
      const apply = () => {
        let metas = [...document.querySelectorAll('meta[name="viewport"]')];
        if (!metas.length) {
          const meta = document.createElement('meta');
          meta.name = 'viewport';
          (document.head || document.documentElement).appendChild(meta);
          metas = [meta];
        }
        metas.forEach(meta => { if (meta.content !== value) meta.content = value; });
      };
      apply();
      new MutationObserver(apply).observe(document.head || document.documentElement,
        { childList: true, subtree: true, attributes: true, attributeFilter: ['content', 'name'] });
    })();
    """
}
#endif

#if os(iOS)
final class TwoFingerHoldRecognizer: UILongPressGestureRecognizer {
    private let fire: () -> Void

    init(fire: @escaping () -> Void) {
        self.fire = fire
        super.init(target: nil, action: nil)
        numberOfTouchesRequired = UnlinkGestureSpec.fingers
        minimumPressDuration = TimeInterval(UnlinkGestureSpec.holdSeconds)
        allowableMovement = 12
        addTarget(self, action: #selector(recognized))
    }

    @objc private func recognized() {
        guard state == .began else { return }
        fire()
    }
}

#elseif os(macOS)
final class TwoFingerHoldRecognizer: NSPressGestureRecognizer {
    private let fire: () -> Void

    init(fire: @escaping () -> Void) {
        self.fire = fire
        super.init(target: nil, action: nil)
        minimumPressDuration = TimeInterval(UnlinkGestureSpec.holdSeconds)
        buttonMask = 0x1
        target = self
        action = #selector(recognized)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func recognized() {
        fire()
    }
}
#endif
#endif
