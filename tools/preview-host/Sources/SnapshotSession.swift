import AppKit
import Foundation
import ScreenpunkApple
import ScreenpunkCore
import WebKit

enum SnapshotMode {
    case fixture
    case package(URL)
}

final class SnapshotSession: NSObject, WKNavigationDelegate {
    private let mode: SnapshotMode
    private let outputURL: URL
    private let timeout: TimeInterval
    private let width: CGFloat
    private let height: CGFloat
    private var window: NSWindow?
    private var webView: WKWebView?
    private var homeAssistantBridge: HomeAssistantPreviewBridge?
    private var finished = false
    private var waitingForReady = false
    // Read-only carousel imagery can capture a loaded page even without a runtime.ready call.
    private var documentThumbnail: Bool {
        ProcessInfo.processInfo.environment["SCREENPUNK_DOCUMENT_THUMBNAIL"] == "1"
            && ProcessInfo.processInfo.environment["SCREENPUNK_PREVIEW_LIVE"] != "1"
    }
    var onComplete: (() -> Void)?

    init(mode: SnapshotMode, output: String, timeout: TimeInterval, width: Int, height: Int) {
        self.mode = mode
        self.outputURL = URL(fileURLWithPath: output)
        self.timeout = timeout
        self.width = CGFloat(width)
        self.height = CGFloat(height)
    }

    func start() {
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.collectionBehavior = [.ignoresCycle, .stationary]
        window.orderBack(nil)

        let config = WKWebViewConfiguration()
        BundledAudio.configure(config)
        config.websiteDataStore = .nonPersistent()
        if case .package(let directory) = mode {
            do {
                let store = try PackageAssetStore.load(directory: directory)
                if ProcessInfo.processInfo.environment["SCREENPUNK_PREVIEW_LIVE"] == "1" {
                    let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
                    let manifest = try JSONDecoder().decode(DashboardManifest.self, from: data)
                    // Bounded pipe input; provisioning never enters page assets or environment variables.
                    var input = Data()
                    while true {
                        let chunk = FileHandle.standardInput.readData(ofLength: 8192)
                        if chunk.isEmpty { break }
                        input.append(chunk)
                        guard input.count < 256 * 1024 else { throw ConnectionFailure.sizeLimit }
                    }
                    if !input.isEmpty {
                        let connections: NativePreviewConnections
                        if let envelope = try? JSONDecoder().decode(NativePreviewConnections.self, from: input),
                           envelope.homeAssistant != nil || envelope.publicReads != nil { connections = envelope }
                        else if let legacy = try? JSONDecoder().decode(HomeAssistantProvisioning.self, from: input) { connections = .init(homeAssistant: legacy) }
                        else { connections = .init() }
                        if let home = connections.homeAssistant {
                            guard home.dashboardId == manifest.dashboardId, home.revision == manifest.revision else { throw ConnectionFailure.permissionRequired }
                        }
                        if let publicReads = connections.publicReads {
                            let expected = try PublicReadProvisioning(manifest: manifest)
                            guard publicReads.dashboardId == expected.dashboardId, publicReads.revision == expected.revision,
                                  publicReads.connections.allSatisfy({ expected.connections.contains($0) }) else { throw ConnectionFailure.permissionRequired }
                        }
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["SCREENPUNK_PUBLIC_READ_FIXTURE"] == "1" {
                            homeAssistantBridge = try HomeAssistantPreviewBridge(configuration: config, connections: connections, revision: manifest.revision,
                                publicTransport: SyntheticPublicReadTransport(), publicResolver: FixedResolver(["203.0.113.10"]))
                        } else {
                            homeAssistantBridge = try HomeAssistantPreviewBridge(configuration: config, connections: connections, revision: manifest.revision)
                        }
#else
                        homeAssistantBridge = try HomeAssistantPreviewBridge(configuration: config, connections: connections, revision: manifest.revision)
#endif
                    }
                }
                config.setURLSchemeHandler(PackageSchemeHandler(store: store, rasterResources: homeAssistantBridge?.rasterResources), forURLScheme: IsolationPolicy.customScheme)
            } catch {
                fail("package_load_failed: \(error)")
                return
            }
        }
        let readyScript = WKUserScript(
            source: """
            window.__SCREENPUNK_READY = false;
            window.screenpunk = window.screenpunk || {};
            window.screenpunk.runtime = window.screenpunk.runtime || {};
            const nativeReady = window.screenpunk.runtime.ready;
            window.screenpunk.runtime.ready = function () {
                window.__SCREENPUNK_READY = true;
                return nativeReady ? nativeReady.call(window.screenpunk.runtime) : Promise.resolve();
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(readyScript)
#if DEBUG
        if ProcessInfo.processInfo.environment["SCREENPUNK_AUTHORING_PROBE"] == "1" {
            config.userContentController.addUserScript(WKUserScript(source: "window.__authoringViolations=[];addEventListener('securitypolicyviolation',e=>window.__authoringViolations.push(e.violatedDirective));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
#endif

        let webView = WKWebView(frame: rect, configuration: config)
        homeAssistantBridge?.attach(to: webView)
        webView.navigationDelegate = self
        window.contentView = webView
#if DEBUG
        if let appearance = ProcessInfo.processInfo.environment["SCREENPUNK_AUTHORING_APPEARANCE"] {
            window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
#endif
        self.window = window
        self.webView = webView

        switch mode {
        case .fixture:
            webView.loadHTMLString(Self.fixtureHTML, baseURL: nil)
        case .package(let directory):
            let entry = Self.entrypoint(in: directory)
            if let url = URL(string: "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/\(entry)") {
                waitingForReady = !documentThumbnail
                webView.load(URLRequest(url: url))
            } else {
                fail("missing_entrypoint")
                return
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            if self.waitingForReady {
                self.fail("not_ready")
            } else {
                self.fail("timeout")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("navigation \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail("provisional \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url?.absoluteString ?? ""
        if url.isEmpty || IsolationEvaluator.isLocalPackageURL(url) || url.hasPrefix("about:") {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyInteraction(on: webView)
        if waitingForReady {
            pollReady(webView: webView, remaining: Int(timeout * 10))
        } else {
            // Navigation completion includes local scripts/styles; allow a paint before capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak webView] in
                guard let self, let webView, !self.finished else { return }
                self.capture(webView)
            }
        }
    }

    private func pollReady(webView: WKWebView, remaining: Int) {
        webView.evaluateJavaScript("window.__SCREENPUNK_READY === true") { [weak self] result, _ in
            guard let self, !self.finished else { return }
            if (result as? Bool) == true {
#if DEBUG
                if ProcessInfo.processInfo.environment["SCREENPUNK_AUTHORING_PROBE"] == "1" {
                    self.probeAuthoring(webView)
                    return
                }
#endif
                self.capture(webView)
                return
            }
            if remaining <= 0 {
                self.fail("not_ready")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.pollReady(webView: webView, remaining: remaining - 1)
            }
        }
    }

#if DEBUG
    private func probeAuthoring(_ webView: WKWebView) {
        let script = """
        const readyMilliseconds=Math.round(performance.now());
        const pause=()=>new Promise(r=>setTimeout(r,100));
        await pause();
        const failures=[]; const check=(ok,name)=>{if(!ok)failures.push(name)};
        const button=text=>[...document.querySelectorAll('button')].find(b=>b.textContent.includes(text));
        check(!!document.querySelector('.recharts-surface'),'chart');
        const counter=button('Count');counter?.click();await pause();check(button('Count')?.textContent.includes('1'),'button');
        button('Details')?.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,button:0}));await pause();check(document.body.textContent.includes('Arrow keys'),'tabs');
        const trigger=button('Open dialog');trigger?.focus();trigger?.click();await pause();
        check(!!document.querySelector('[role=dialog]'),'dialog');
        check(document.querySelector('[role=dialog]')?.contains(document.activeElement),'dialog-focus');
        document.querySelector('[aria-label="Close dialog"]')?.click();await pause();
        check(!document.querySelector('[role=dialog]'),'dialog-close');
        check(document.activeElement===trigger,'focus-restoration');
        const select=document.querySelector('[role=combobox]');select?.focus();
        select?.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}));await pause();
        check(!!document.querySelector('[role=listbox]'),'select');
        document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await pause();
        button('Value')?.click();await pause();
        check(document.querySelector('th[aria-sort=ascending],th[aria-sort=descending]')!==null,'table-sort');
        const beforeSlide=document.querySelector('.sp-slides')?.style.transform;
        document.querySelector('[aria-label="Next slide"]')?.click();await pause();
        check(document.querySelector('.sp-slides')?.style.transform!==beforeSlide,'carousel');
        return {failures,violations:window.__authoringViolations,readyMilliseconds,probeFinishedMilliseconds:Math.round(performance.now()),width:innerWidth,height:innerHeight};
        """
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
                let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
                FileHandle.standardError.write(Data("AUTHORING_PROBE ".utf8) + data + Data("\n".utf8))
                self.capture(webView)
            } catch { self.fail("authoring_probe: \(error.localizedDescription)")
            }
        }
    }
#endif

    private func applyInteraction(on webView: WKWebView) {
        let env = ProcessInfo.processInfo.environment
        guard let kind = env["SCREENPUNK_INTERACT_KIND"], kind.isEmpty == false else { return }
        let x = env["SCREENPUNK_INTERACT_X"] ?? "0"
        let y = env["SCREENPUNK_INTERACT_Y"] ?? "0"
        let text = (env["SCREENPUNK_INTERACT_TEXT"] ?? "").replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let dy = env["SCREENPUNK_INTERACT_DY"] ?? "0"
        let js = """
        (function(){
          var x = \(x), y = \(y);
          var el = document.elementFromPoint(x, y) || document.body;
          if ('\(kind)' === 'tap' && el) { el.dispatchEvent(new MouseEvent('click', {bubbles:true, clientX:x, clientY:y})); }
          if ('\(kind)' === 'input' && el) {
            el.focus && el.focus();
            if ('value' in el) el.value = '\(text)';
            el.dispatchEvent(new Event('input', {bubbles:true}));
          }
          if ('\(kind)' === 'scroll') { window.scrollBy(0, \(dy)); }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func capture(_ webView: WKWebView) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self else { return }
            if let error {
                self.fail("snapshot \(error.localizedDescription)")
                return
            }
            guard
                let image,
                let tiff = image.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:]),
                png.count >= 8,
                png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            else {
                self.fail("no_image")
                return
            }
            do {
                try png.write(to: self.outputURL)
                FileHandle.standardError.write(Data("SNAPSHOT_OK path=\(self.outputURL.path)\n".utf8))
                self.finish()
            } catch {
                self.fail("write \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        FileHandle.standardError.write(Data("SNAPSHOT_UNAVAILABLE reason=\(reason)\n".utf8))
        finish()
    }

    private func finish() {
        finished = true
        onComplete?()
    }

    private static func entrypoint(in directory: URL) -> String {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if
            let data = try? Data(contentsOf: manifestURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entry = json["entrypoint"] as? String
        {
            return entry
        }
        return "index.html"
    }

    static let fixtureHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>SCREENPUNK_PREVIEW_FIXTURE_V1</title>
      <style>
        html, body { margin: 0; background: #F4EFE5; color: #15191C;
          font: 18px/1.4 system-ui, sans-serif; }
        main { padding: 48px 24px; }
      </style>
    </head>
    <body data-fixture="SCREENPUNK_PREVIEW_FIXTURE_V1">
      <main>
        <p>SCREENPUNK_PREVIEW_FIXTURE_V1</p>
        <p>Hidden WKWebView snapshot fixture. Not first-party product UI.</p>
      </main>
    </body>
    </html>
    """
}
