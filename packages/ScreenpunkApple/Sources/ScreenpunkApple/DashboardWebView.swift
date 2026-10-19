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
    public var serviceInvocation: CloudScreenServiceInvocation?

    public init(store: PackageAssetStore, homeAssistant: HomeAssistantDeviceRuntime? = nil, publicReads: PublicReadRuntime? = nil, rasterResources: PublicRasterResources? = nil, revision: String = "", connections: ConnectionRuntime? = nil, settings: DeviceSettings = .init(), active: Bool = true, onSettingsApplied: @escaping (Bool) -> Void = { _ in }, onConnectionHealth: @escaping (Bool) -> Void = { _ in }, onReady: @escaping () -> Void = {}, serviceInvocation: CloudScreenServiceInvocation? = nil, onUnlinkHold: @escaping () -> Void) {
        self.store = store
        self.homeAssistant = homeAssistant
        self.publicReads = publicReads; self.rasterResources = rasterResources
        self.revision = revision
        self.connections = connections; self.settings = settings; self.active = active; self.onSettingsApplied = onSettingsApplied
        self.onConnectionHealth = onConnectionHealth
        self.serviceInvocation = serviceInvocation
        self.onReady = onReady
        self.onUnlinkHold = onUnlinkHold
    }

    public func makeCoordinator() -> DashboardWebCoordinator {
        DashboardWebCoordinator(store: store, lifetime: runtimeLifetime ?? DeviceRuntimeLifetime(), homeAssistant: homeAssistant, publicReads: publicReads, rasterResources: rasterResources, revision: revision, connections: connections, settings: settings, active: active, onSettingsApplied: onSettingsApplied, onConnectionHealth: onConnectionHealth, onReady: onReady, serviceInvocation: serviceInvocation, onUnlinkHold: onUnlinkHold)
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
    public var serviceInvocation: CloudScreenServiceInvocation?

    public init(store: PackageAssetStore, homeAssistant: HomeAssistantDeviceRuntime? = nil, publicReads: PublicReadRuntime? = nil, rasterResources: PublicRasterResources? = nil, revision: String = "", connections: ConnectionRuntime? = nil, settings: DeviceSettings = .init(), active: Bool = true, onSettingsApplied: @escaping (Bool) -> Void = { _ in }, onConnectionHealth: @escaping (Bool) -> Void = { _ in }, onReady: @escaping () -> Void = {}, serviceInvocation: CloudScreenServiceInvocation? = nil, onUnlinkHold: @escaping () -> Void) {
        self.store = store
        self.homeAssistant = homeAssistant
        self.publicReads = publicReads; self.rasterResources = rasterResources
        self.revision = revision
        self.connections = connections; self.settings = settings; self.active = active; self.onSettingsApplied = onSettingsApplied
        self.onConnectionHealth = onConnectionHealth
        self.serviceInvocation = serviceInvocation
        self.onReady = onReady
        self.onUnlinkHold = onUnlinkHold
    }

    public func makeCoordinator() -> DashboardWebCoordinator {
        DashboardWebCoordinator(store: store, lifetime: runtimeLifetime ?? DeviceRuntimeLifetime(), homeAssistant: homeAssistant, publicReads: publicReads, rasterResources: rasterResources, revision: revision, connections: connections, settings: settings, active: active, onSettingsApplied: onSettingsApplied, onConnectionHealth: onConnectionHealth, onReady: onReady, serviceInvocation: serviceInvocation, onUnlinkHold: onUnlinkHold)
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
    private var managedRuntime: DeviceUnifiedManagedRuntime?
    var hasCapabilityBridge: Bool { bridge != nil }
    var hasEventRuntime: Bool { events != nil }
    private var retirementRegistration: UUID?
    private var suspensionRegistration: UUID?
    private(set) var isRetired = false
    private var installedRules = false
    private var bridge: HomeAssistantWebBridge?
    private var serviceBridge: CloudScreenServiceBridge?
    private var serviceMounted: (@MainActor () async throws -> Void)?
    private var serviceMountFailed: (@MainActor (String) async -> Void)?
    private var managedFailureReported = false
    private var serviceMountTask: Task<Void,Never>?
    private var events: DashboardEventRuntime?
    private weak var webView: WKWebView?
    private var active: Bool
    private let presentationAllowed: @Sendable () -> Bool
    private var presentationSuspended = false
    private var presentationEpoch = UUID()
    private var managedDidMount = false
    var isPresentationSuspended: Bool { presentationSuspended }
    var hasMountedPresentation: Bool { managedDidMount }
    private var initialPath = "index.html"
    private var programmaticURL: String?
    private(set) var currentNavigation: WKNavigation?
    private let navigationEpochs = NSMapTable<WKNavigation, NSUUID>.weakToStrongObjects()
    private var onSettingsApplied: (Bool) -> Void
    private var settingsValid = true
    private var allowsAudioAutoplay = false

    init(store: PackageAssetStore, lifetime: DeviceRuntimeLifetime = DeviceRuntimeLifetime(), preferenceStore: ScreenPreferenceStore? = nil, homeAssistant: HomeAssistantDeviceRuntime? = nil, publicReads: PublicReadRuntime? = nil, rasterResources: PublicRasterResources? = nil, revision: String = "", connections: ConnectionRuntime? = nil, settings: DeviceSettings = .init(), active: Bool = true, presentationAllowed: @escaping @Sendable () -> Bool = { true }, onSettingsApplied: @escaping (Bool) -> Void = { _ in }, onConnectionHealth: @escaping (Bool) -> Void = { _ in }, onReady: @escaping () -> Void = {}, serviceInvocation: CloudScreenServiceInvocation? = nil, onUnlinkHold: @escaping () -> Void) {
        self.lifetime = lifetime
        self.presentationAllowed = presentationAllowed
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
                                                       homeAssistant: homeAssistant, connections: connections, presentationAllowed: presentationAllowed)
                allowsAudioAutoplay = manifest.deviceBehavior?.allowsAudioAutoplay == true
                self.events = events; initialPath = events.page.path; settingsValid = events.settingsApplied
            } catch { settingsValid = false }
        }
        super.init()
        let health: (Bool) -> Void = { [weak self] value in
            guard let self, self.presentationIsOpen(), !self.isRetired, !self.lifetime.isRetired else { return }
            onConnectionHealth(value)
        }
        self.bridge = HomeAssistantWebBridge(runtime: homeAssistant, connections: connections, navigation: events,
                                              revision: revision, lifetime: lifetime, presentationAllowed: presentationAllowed, preferenceStore: preferenceStore ?? .shared, publicReads: publicReads, resources: rasterResources, onHealth: health)
        events?.onPage = { [weak self] page in self?.load(path: page.path) }
        events?.onStatus = { [weak self] status in self?.bridge?.status(status) }
        events?.onHealth = health
        if let serviceInvocation {
            let services = CloudScreenServiceBridge(lifetime: lifetime, declaredOperations: CloudScreenServiceBridge.declaredOperations(store.assets["screenpunk.services.json"]?.data), presentationAllowed: presentationAllowed, invoke: serviceInvocation)
            services.setMounted() // Authoring preview; never a device-runtime mount.
            serviceBridge = services
        }
        retirementRegistration = lifetime.register { [weak self] in self?.retireForReset() }
        suspensionRegistration = lifetime.registerSuspension { [weak self] in self?.pausePresentation() }
    }

    /// Non-authorizing, unmounted static transport. No capability bridge, preferences, event
    /// runtime, raster resources, mutable credentials or Local host are constructed in this path.
    init(managedStatic content: DeviceManagedStaticContent, lifetime: DeviceRuntimeLifetime, presentationAllowed: @escaping @Sendable () -> Bool = { true }, serviceInvocation: CloudScreenServiceInvocation? = nil, serviceMounted: (@MainActor () async throws -> Void)? = nil, serviceMountFailed: (@MainActor (String) async -> Void)? = nil) {
        self.presentationAllowed = presentationAllowed
        self.lifetime = lifetime; managedStaticContent = content
        self.serviceMounted = serviceMounted; self.serviceMountFailed = serviceMountFailed
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
        if let serviceInvocation { serviceBridge = CloudScreenServiceBridge(lifetime: lifetime, declaredOperations: CloudScreenServiceBridge.declaredOperations(content.assets.first(where: { $0.path == "screenpunk.services.json" })?.bytes), presentationAllowed: presentationAllowed, invoke: serviceInvocation) }
        retirementRegistration = lifetime.register { [weak self] in self?.retireForReset() }
        suspensionRegistration = lifetime.registerSuspension { [weak self] in self?.pausePresentation() }
    }
    /// Genuine common runtime issuance supplies private grant operations and the
    /// current-or-mounted inventory validator. The static initializer remains separate.
    init(managedRuntime runtime: DeviceUnifiedManagedRuntime, lifetime: DeviceRuntimeLifetime,
        presentationAllowed: @escaping @Sendable () -> Bool = { true }, settings: DeviceSettings = .init(), serviceInvocation: CloudScreenServiceInvocation? = nil,
        serviceMounted: (@MainActor () async throws -> Void)? = nil,
        serviceMountFailed: (@MainActor (String) async -> Void)? = nil) {
        let content = runtime.content
        managedRuntime = runtime
        self.presentationAllowed = presentationAllowed
        self.lifetime = lifetime; managedStaticContent = content
        self.serviceMounted = serviceMounted; self.serviceMountFailed = serviceMountFailed
        let valid = !lifetime.isRetired && (try? runtime.verifyResources()) != nil
        var assets: [String: PackageAsset] = [:]
        if valid { for asset in content.assets { assets[asset.path] = .init(path: asset.path, data: asset.bytes, mime: PackageAssetStore.mime(for: asset.path)) } }
        let resources = PublicRasterResources()
        handler = PackageSchemeHandler(store: .init(assets: assets), rasterResources: resources)
        onReady = {}; onUnlinkHold = {}; onSettingsApplied = { _ in }; active = valid
        initialPath = content.entrypoint; settingsValid = valid
        super.init()
        guard valid else { isRetired = true; return }
        do {
            let events = try DashboardEventRuntime(manifest: runtime.manifest, revision: content.revision,
                settings: settings, homeAssistant: nil, connections: nil, managedRuntime: runtime, presentationAllowed: presentationAllowed)
            self.events = events; initialPath = events.page.path; settingsValid = events.settingsApplied
            self.active = false // Hidden candidate cannot execute or play media before the bound mount receipt.
            allowsAudioAutoplay = runtime.manifest.deviceBehavior?.allowsAudioAutoplay == true
            let reads = try runtime.publicReads.map { provisioning in
                try PublicReadRuntime(provisioning: provisioning,
                    transport: runtime.guardedHTTP(HomeAssistantHTTPTransport()),
                    isCurrent: { presentationAllowed() && (try? runtime.verifyActive()) != nil })
            }
            bridge = HomeAssistantWebBridge(runtime: nil, managedRuntime: runtime, navigation: events,
                revision: content.revision, lifetime: lifetime, presentationAllowed: presentationAllowed, mapManifest: runtime.manifest, publicReads: reads, resources: resources,
                onHealth: { _ in })
            events.onPage = { [weak self] page in self?.load(path: page.path) }
            events.onStatus = { [weak self] status in self?.bridge?.status(status) }
            if let serviceInvocation {
                serviceBridge = CloudScreenServiceBridge(lifetime: lifetime,
                    declaredOperations: CloudScreenServiceBridge.declaredOperations(content.assets.first(where: { $0.path == "screenpunk.services.json" })?.bytes), presentationAllowed: presentationAllowed, invoke: serviceInvocation)
            }
            retirementRegistration = lifetime.register { [weak self] in
                self?.retireForReset(); Task { await runtime.cancel() }
            }
            suspensionRegistration = lifetime.registerSuspension { [weak self] in self?.pausePresentation() }
        } catch { retireForReset(); Task { await runtime.cancel() } }
    }
    /// SwiftUI may reuse a coordinator while replacing value-view properties. Never adopt new
    /// content or lifetime into an existing static renderer; the parent must recreate it explicitly.
    func updateManagedStatic(content: DeviceManagedStaticContent, lifetime: DeviceRuntimeLifetime,
        presentationAllowed: (@Sendable () -> Bool)? = nil) {
        guard let original = managedStaticContent, original === content, self.lifetime === lifetime else {
            retireForReset(); return
        }
        // The initializer's host gate is immutable and shared with every child.
        // A new value-view closure cannot replace one branch of that binding.
        _ = presentationAllowed
        // Same issued content/lifetime is a value-view update, not a fresh
        // admission. Scene owns the single drained, full resume validation.
        guard presentationIsOpen(), !isRetired, !lifetime.isRetired else { return }
        if presentationSuspended {
            presentationSuspended = false
            applyActivity(managedRuntime == nil || managedDidMount)
        }
    }
    private func presentationIsOpen() -> Bool {
        guard presentationAllowed() else { pausePresentation(); return false }
        return true
    }
    private func pausePresentation() {
        guard !isRetired, !presentationSuspended else { return }
        presentationSuspended = true; presentationEpoch = UUID()
        serviceMountTask?.cancel(); serviceMountTask = nil
        bridge?.suspendPresentation(); serviceBridge?.suspendPresentation()
        applyActivity(false)
    }
    private func applyActivity(_ value: Bool) {
        active = value
        serviceBridge?.setActive(value); bridge?.setActive(value)
        if value { events?.start() }
        else { events?.stop(); bridge?.cancel(); webView?.pauseAllMediaPlayback(completionHandler: nil) }
        if managedRuntime != nil { webView?.setAllMediaPlaybackSuspended(!value, completionHandler: nil) }
    }
    private func managedResourcesValid() -> Bool {
        guard presentationIsOpen() else { return false }
        guard let content = managedStaticContent else { return true } // Existing legacy path unchanged.
        do { try content.verifyResources(); return true }
        catch { retireForReset(); return false }
    }
    func update(settings: DeviceSettings, active: Bool, onSettingsApplied: @escaping (Bool) -> Void) {
        guard presentationIsOpen(), managedResourcesValid(), !isRetired, !lifetime.isRetired else { return }
        if presentationSuspended { presentationSuspended = false }
        self.onSettingsApplied = onSettingsApplied
        events?.update(settings: settings)
        if let events { settingsValid = events.settingsApplied }
        let executable = active && (managedRuntime == nil || (try? managedRuntime?.verifyActive()) != nil)
        applyActivity(executable)
        // Defer callback to avoid publishing SwiftUI state during view update.
        let valid = settingsValid, epoch = presentationEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationEpoch == epoch, self.presentationIsOpen(),
                  !self.isRetired, !self.lifetime.isRetired else { return }
            onSettingsApplied(valid)
        }
    }

    func retireForReset() {
        guard !isRetired else { return }
        presentationEpoch = UUID(); isRetired = true; active = false
        lifetime.unregister(retirementRegistration); retirementRegistration = nil
        lifetime.unregisterSuspension(suspensionRegistration); suspensionRegistration = nil
        serviceMountTask?.cancel(); serviceMountTask = nil; serviceMounted = nil; serviceMountFailed = nil
        serviceBridge?.retire()
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
        webView = nil; programmaticURL = nil; currentNavigation = nil; navigationEpochs.removeAllObjects()
    }

    func stop() { presentationEpoch = UUID(); serviceMountTask?.cancel(); serviceMountTask = nil; serviceBridge?.retire(); bridge?.setActive(false); events?.stop(); bridge?.cancel(); webView?.pauseAllMediaPlayback(completionHandler: nil) }

    private func load(path: String) {
        guard presentationIsOpen(), managedResourcesValid(), !isRetired, !lifetime.isRetired else { return }
        loadResourceChecked(path: path)
    }

    /// Only synchronous callers that just checked resources may enter here.
    /// Navigation policy and mount callbacks retain their own fresh checks.
    private func loadResourceChecked(path: String) {
        guard presentationIsOpen(), !isRetired, !lifetime.isRetired else { return }
        guard let url = URL(string: "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/\(path)") else { return }
        bridge?.cancel(); programmaticURL = url.absoluteString
        if let navigation = webView?.load(URLRequest(url: url)) {
            currentNavigation = navigation
            navigationEpochs.setObject(presentationEpoch as NSUUID, forKey:navigation)
        }
    }

    deinit {
        let bridge = bridge, lifetime = lifetime, registration = retirementRegistration, suspension = suspensionRegistration
        Task { @MainActor in lifetime.unregister(registration); lifetime.unregisterSuspension(suspension); bridge?.cancel() }
    }

    func makeWebView() -> WKWebView {
        guard presentationIsOpen(), managedResourcesValid(), !isRetired, !lifetime.isRetired else {
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
        if let serviceBridge {
            config.userContentController.addScriptMessageHandler(serviceBridge, contentWorld: .page, name: "screenpunkServices")
            config.userContentController.addUserScript(WKUserScript(source: CloudScreenServiceBridge.sdk, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        if managedRuntime != nil { webView.setAllMediaPlaybackSuspended(true, completionHandler: nil) }
        loadResourceChecked(path: initialPath)
        if active { events?.start() }
        DispatchQueue.main.async { [weak self] in guard let self, self.presentationIsOpen(), !self.isRetired, !self.lifetime.isRetired else { return }; self.onSettingsApplied(self.settingsValid) }
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
            guard let self else { return }
            _ = self.presentationIsOpen()
            // Isolation rules protect static bytes too; install even while paused.
            guard !self.isRetired, !self.lifetime.isRetired, let webView else { return }
            if let list {
                webView.configuration.userContentController.add(list)
            }
        }
    }

    private func installUnlinkRecognizer(on webView: WKWebView) {
#if os(iOS)
        let recognizer = TwoFingerHoldRecognizer { [weak self] in
            guard let self, self.presentationIsOpen(), !self.isRetired, !self.lifetime.isRetired else { return }
            self.onUnlinkHold()
        }
        recognizer.cancelsTouchesInView = false
        webView.addGestureRecognizer(recognizer)
#elseif os(macOS)
        let recognizer = TwoFingerHoldRecognizer { [weak self] in
            guard let self, self.presentationIsOpen(), !self.isRetired, !self.lifetime.isRetired else { return }
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
        let allowed = presentationIsOpen()
        guard self.webView === webView, !isRetired, !lifetime.isRetired else { decisionHandler(.cancel); return }
        let url = navigationAction.request.url?.absoluteString ?? ""
        guard IsolationEvaluator.isLocalPackageURL(url) else { decisionHandler(.cancel); return }
        guard allowed else {
            // Keep scheme-handler assets/subframes available, but preserve the
            // retained top-level document until its presentation is resumed.
            decisionHandler(navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel)
            return
        }
        guard managedResourcesValid() else { decisionHandler(.cancel); return }
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
        _ = presentationIsOpen()
        return nil
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard presentationIsOpen(), self.webView === webView, !isRetired, !lifetime.isRetired, let navigation else { return }
        // Programmatic loads are bound immediately from load()'s actual token.
        // Never rebind a known old navigation when a delayed callback arrives.
        guard navigationEpochs.object(forKey:navigation) == nil else { return }
        currentNavigation = navigation
        navigationEpochs.setObject(presentationEpoch as NSUUID, forKey:navigation)
    }
    private func isCurrentNavigation(_ navigation: WKNavigation?) -> Bool {
        guard let navigation, currentNavigation === navigation,
              let recorded = navigationEpochs.object(forKey:navigation) else { return false }
        return (recorded as UUID) == presentationEpoch
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard presentationIsOpen(), self.webView === webView, !isRetired, !lifetime.isRetired, !managedFailureReported,
              isCurrentNavigation(navigation) else { return }
        guard managedResourcesValid() else { return }
        onReady()
        if let serviceMounted, serviceMountTask == nil, !managedDidMount {
            let epoch = presentationEpoch
            serviceMountTask = Task { [weak self] in
                guard let self, self.presentationIsOpen(), self.presentationEpoch == epoch, !Task.isCancelled else { return }
                do {
                    try await serviceMounted(); try Task.checkCancellation()
                    guard self.presentationIsOpen(), self.presentationEpoch == epoch,
                          !self.isRetired, !self.lifetime.isRetired, self.managedResourcesValid() else { return }
                    if let runtime = self.managedRuntime { try runtime.verifyActive() }
                    self.managedDidMount = true
                    self.serviceBridge?.setMounted()
                    self.applyActivity(true)
                } catch {
                    // Lifecycle cancellation is reversible, never a mount failure.
                    guard self.presentationIsOpen(), self.presentationEpoch == epoch, !Task.isCancelled,
                          !(error is CancellationError) else { return }
                    self.reportManagedMountFailure("mount_validation_failed")
                }
            }
        }
    }

    private func reportManagedMountFailure(_ code: String, processLost: Bool = false) {
        let allowed = presentationIsOpen()
        guard allowed || processLost else { return }
        guard managedStaticContent != nil, !isRetired, !lifetime.isRetired, !managedFailureReported else { return }
        managedFailureReported = true; serviceBridge?.setActive(false)
        serviceMountTask?.cancel(); serviceMountTask = nil
        guard let callback = serviceMountFailed else { return }
        Task { [weak self] in
            guard let self, (self.presentationIsOpen() || processLost), !self.isRetired, !self.lifetime.isRetired else { return }
            await callback(code)
        }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard presentationIsOpen(), self.webView === webView, isCurrentNavigation(navigation), (error as NSError).code != NSURLErrorCancelled else { return }
        reportManagedMountFailure("navigation_failed")
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard presentationIsOpen(), self.webView === webView, isCurrentNavigation(navigation), (error as NSError).code != NSURLErrorCancelled else { return }
        reportManagedMountFailure("navigation_failed")
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        _ = presentationIsOpen()
        guard self.webView === webView, !isRetired, !lifetime.isRetired else { return }
        if managedStaticContent != nil { reportManagedMountFailure("render_process_terminated", processLost: true); return }
        bridge?.cancel()
        load(path: events?.page.path ?? initialPath)
    }
}

#if os(iOS)
extension DashboardWebCoordinator: UIScrollViewDelegate {
    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }

    public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard presentationIsOpen(), !isRetired, !lifetime.isRetired else { return }
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
