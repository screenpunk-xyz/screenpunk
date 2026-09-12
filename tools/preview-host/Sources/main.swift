import AppKit
import Foundation
import ScreenpunkCore
import WebKit

/// Hidden AppKit/WKWebView helper. Produces a real PNG or SNAPSHOT_UNAVAILABLE.
/// Never writes a placeholder image.
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var timedOut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let env = ProcessInfo.processInfo.environment
        guard env["SCREENPUNK_SNAPSHOT"] == "1" else {
            FileHandle.standardError.write(
                Data("preview-host bootstrap \(BrandIdentity.logomarkRevision)\n".utf8)
            )
            FileHandle.standardError.write(
                Data("set SCREENPUNK_SNAPSHOT=1 to attempt a hidden WKWebView snapshot\n".utf8)
            )
            NSApp.terminate(nil)
            return
        }
        startSnapshot()
    }

    private func startSnapshot() {
        let rect = NSRect(x: 0, y: 0, width: 390, height: 844)
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
        let webView = WKWebView(frame: rect, configuration: config)
        webView.navigationDelegate = self
        window.contentView = webView
        self.window = window
        self.webView = webView

        let html = """
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
        webView.loadHTMLString(html, baseURL: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.timedOut else { return }
            self.fail("timeout")
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 390, height: 844)
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
            let path = ProcessInfo.processInfo.environment["SCREENPUNK_SNAPSHOT_OUT"]
                ?? "/tmp/screenpunk-preview.png"
            do {
                try png.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Data("SNAPSHOT_OK path=\(path)\n".utf8))
                NSApp.terminate(nil)
            } catch {
                self.fail("write \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ reason: String) {
        if timedOut { return }
        timedOut = true
        FileHandle.standardError.write(Data("SNAPSHOT_UNAVAILABLE reason=\(reason)\n".utf8))
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
