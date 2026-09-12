import AppKit
import ScreenpunkCore

/// Hidden AppKit/WKWebView helper. Bootstrap stub only — no render loop yet.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FileHandle.standardError.write(
            Data("preview-host bootstrap \(BrandIdentity.logomarkRevision)\n".utf8)
        )
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
