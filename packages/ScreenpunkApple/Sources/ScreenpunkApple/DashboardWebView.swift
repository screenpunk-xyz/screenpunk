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
    public var onUnlinkHold: () -> Void

    public init(store: PackageAssetStore, onUnlinkHold: @escaping () -> Void) {
        self.store = store
        self.onUnlinkHold = onUnlinkHold
    }

    public func makeCoordinator() -> DashboardWebCoordinator {
        DashboardWebCoordinator(store: store, onUnlinkHold: onUnlinkHold)
    }

    public func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onUnlinkHold = onUnlinkHold
    }
}

#elseif os(macOS)
public struct DashboardWebView: NSViewRepresentable {
    public var store: PackageAssetStore
    public var onUnlinkHold: () -> Void

    public init(store: PackageAssetStore, onUnlinkHold: @escaping () -> Void) {
        self.store = store
        self.onUnlinkHold = onUnlinkHold
    }

    public func makeCoordinator() -> DashboardWebCoordinator {
        DashboardWebCoordinator(store: store, onUnlinkHold: onUnlinkHold)
    }

    public func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onUnlinkHold = onUnlinkHold
    }
}
#endif

public final class DashboardWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let handler: PackageSchemeHandler
    var onUnlinkHold: () -> Void
    private var installedRules = false

    init(store: PackageAssetStore, onUnlinkHold: @escaping () -> Void) {
        self.handler = PackageSchemeHandler(store: store)
        self.onUnlinkHold = onUnlinkHold
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: IsolationPolicy.customScheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
#if os(iOS)
        webView.isOpaque = true
#endif
        installUnlinkRecognizer(on: webView)
        installContentRules(on: webView)
        if let url = URL(string: "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/index.html") {
            webView.load(URLRequest(url: url))
        }
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
        if IsolationEvaluator.isLocalPackageURL(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = URL(string: "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/index.html") {
            webView.load(URLRequest(url: url))
        }
    }
}

#if os(iOS)
final class TwoFingerHoldRecognizer: UIGestureRecognizer {
    private var timer: Timer?
    private let fire: () -> Void

    init(fire: @escaping () -> Void) {
        self.fire = fire
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        refresh(event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        refresh(event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        refresh(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        clear()
    }

    private func refresh(_ event: UIEvent) {
        let count = event.allTouches?.filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary }.count ?? 0
        if count == UnlinkGestureSpec.fingers {
            if timer == nil {
                timer = Timer.scheduledTimer(
                    withTimeInterval: TimeInterval(UnlinkGestureSpec.holdSeconds),
                    repeats: false
                ) { [weak self] _ in
                    self?.state = .recognized
                    self?.fire()
                    self?.clear()
                }
            }
        } else {
            clear()
        }
    }

    private func clear() {
        timer?.invalidate()
        timer = nil
        state = .possible
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
