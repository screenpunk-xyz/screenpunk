import SwiftUI
import ScreenpunkCore
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
        DashboardWebCoordinator(store: store, homeAssistant: homeAssistant, publicReads: publicReads, rasterResources: rasterResources, revision: revision, connections: connections, settings: settings, active: active, onSettingsApplied: onSettingsApplied, onConnectionHealth: onConnectionHealth, onReady: onReady, onUnlinkHold: onUnlinkHold)
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
        DashboardWebCoordinator(store: store, homeAssistant: homeAssistant, publicReads: publicReads, rasterResources: rasterResources, revision: revision, connections: connections, settings: settings, active: active, onSettingsApplied: onSettingsApplied, onConnectionHealth: onConnectionHealth, onReady: onReady, onUnlinkHold: onUnlinkHold)
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
    private var installedRules = false
    private var bridge: HomeAssistantWebBridge?
    private var events: DashboardEventRuntime?
    private weak var webView: WKWebView?
    private var active: Bool
    private var initialPath = "index.html"
    private var programmaticURL: String?
    private var onSettingsApplied: (Bool) -> Void
    private var settingsValid = true

    init(store: PackageAssetStore, homeAssistant: HomeAssistantDeviceRuntime? = nil, publicReads: PublicReadRuntime? = nil, rasterResources: PublicRasterResources? = nil, revision: String = "", connections: ConnectionRuntime? = nil, settings: DeviceSettings = .init(), active: Bool = true, onSettingsApplied: @escaping (Bool) -> Void = { _ in }, onConnectionHealth: @escaping (Bool) -> Void = { _ in }, onReady: @escaping () -> Void = {}, onUnlinkHold: @escaping () -> Void) {
        self.handler = PackageSchemeHandler(store: store, rasterResources: rasterResources)
        self.onReady = onReady
        self.onUnlinkHold = onUnlinkHold
        self.active = active; self.onSettingsApplied = onSettingsApplied
        if let data = store.assets["manifest.json"]?.data {
            do {
                let manifest = try JSONDecoder().decode(DashboardManifest.self, from: data)
                let events = try DashboardEventRuntime(manifest: manifest, revision: revision, settings: settings,
                                                       homeAssistant: homeAssistant, connections: connections)
                self.events = events; initialPath = events.page.path; settingsValid = events.settingsApplied
            } catch { settingsValid = false }
        }
        self.bridge = HomeAssistantWebBridge(runtime: homeAssistant, connections: connections, navigation: events,
                                              revision: revision, publicReads: publicReads, resources: rasterResources, onHealth: onConnectionHealth)
        super.init()
        events?.onPage = { [weak self] page in self?.load(path: page.path) }
        events?.onStatus = { [weak self] status in self?.bridge?.status(status) }
        events?.onHealth = onConnectionHealth
    }

    func update(settings: DeviceSettings, active: Bool, onSettingsApplied: @escaping (Bool) -> Void) {
        self.onSettingsApplied = onSettingsApplied
        events?.update(settings: settings)
        if let events { settingsValid = events.settingsApplied }
        self.active = active
        bridge?.setActive(active)
        if active { events?.start() } else { events?.stop(); bridge?.cancel() }
        // Defer callback to avoid publishing SwiftUI state during view update.
        let valid = settingsValid
        DispatchQueue.main.async { onSettingsApplied(valid) }
    }

    func stop() { bridge?.setActive(false); events?.stop(); bridge?.cancel() }

    private func load(path: String) {
        guard let url = URL(string: "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/\(path)") else { return }
        bridge?.cancel(); programmaticURL = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    deinit { let bridge = bridge; Task { @MainActor in bridge?.cancel() } }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        BundledAudio.configure(config)
        config.setURLSchemeHandler(handler, forURLScheme: IsolationPolicy.customScheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if let bridge {
            config.userContentController.add(bridge, name: "screenpunk")
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
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.onSettingsApplied(self.settingsValid) }
        return webView
    }

    private func installContentRules(on webView: WKWebView) {
        guard !installedRules else { return }
        installedRules = true
        let data = Data(IsolationPolicy.contentRuleListJSON.utf8)
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "screenpunk-isolation",
            encodedContentRuleList: String(data: data, encoding: .utf8) ?? "[]"
        ) { list, _ in
            if let list {
                webView.configuration.userContentController.add(list)
            }
        }
    }

    private func installUnlinkRecognizer(on webView: WKWebView) {
#if os(iOS)
        let recognizer = TwoFingerHoldRecognizer { [weak self] in
            self?.onUnlinkHold()
        }
        recognizer.cancelsTouchesInView = false
        webView.addGestureRecognizer(recognizer)
#elseif os(macOS)
        let recognizer = TwoFingerHoldRecognizer { [weak self] in
            self?.onUnlinkHold()
        }
        webView.addGestureRecognizer(recognizer)
#endif
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
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

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onReady() }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        bridge?.cancel()
        load(path: events?.page.path ?? initialPath)
    }
}

#if os(iOS)
extension DashboardWebCoordinator: UIScrollViewDelegate {
    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }

    public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
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
