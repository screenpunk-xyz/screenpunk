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
        config.websiteDataStore = .nonPersistent()
        if case .package(let directory) = mode {
            do {
                let store = try PackageAssetStore.load(directory: directory)
                config.setURLSchemeHandler(PackageSchemeHandler(store: store), forURLScheme: IsolationPolicy.customScheme)
                if ProcessInfo.processInfo.environment["SCREENPUNK_PREVIEW_LIVE"] == "1",
                   let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                   let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: data),
                   manifest.connections.contains(where: { $0.alias == "home" }) {
                    let input = FileHandle.standardInput.readData(ofLength: 16 * 1024)
                    if !input.isEmpty, input.count < 16 * 1024,
                       let provisioning = try? JSONDecoder().decode(HomeAssistantProvisioning.self, from: input),
                       provisioning.dashboardId == manifest.dashboardId, provisioning.revision == manifest.revision {
                        homeAssistantBridge = try HomeAssistantPreviewBridge(configuration: config, provisioning: provisioning)
                    }
                }
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

        let webView = WKWebView(frame: rect, configuration: config)
        homeAssistantBridge?.attach(to: webView)
        webView.navigationDelegate = self
        window.contentView = webView
        self.window = window
        self.webView = webView

        switch mode {
        case .fixture:
            webView.loadHTMLString(Self.fixtureHTML, baseURL: nil)
        case .package(let directory):
            let entry = Self.entrypoint(in: directory)
            if let url = URL(string: "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/\(entry)") {
                waitingForReady = true
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
            capture(webView)
        }
    }

    private func pollReady(webView: WKWebView, remaining: Int) {
        webView.evaluateJavaScript("window.__SCREENPUNK_READY === true") { [weak self] result, _ in
            guard let self, !self.finished else { return }
            if (result as? Bool) == true {
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
