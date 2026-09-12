import AppKit
import Foundation
import ScreenpunkCore

/// Hidden AppKit/WKWebView helper. Produces a real PNG or SNAPSHOT_UNAVAILABLE.
/// Never writes a placeholder image. Does not activate a workbench window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var session: SnapshotSession?

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

        let output = env["SCREENPUNK_SNAPSHOT_OUT"] ?? "/tmp/screenpunk-preview.png"
        let timeout = TimeInterval(env["SCREENPUNK_READY_TIMEOUT"] ?? "20") ?? 20
        let width = Int(env["SCREENPUNK_VIEWPORT_WIDTH"] ?? "390") ?? 390
        let height = Int(env["SCREENPUNK_VIEWPORT_HEIGHT"] ?? "844") ?? 844
        let mode: SnapshotMode
        if let package = env["SCREENPUNK_PACKAGE_DIR"], package.isEmpty == false {
            mode = .package(URL(fileURLWithPath: package, isDirectory: true))
        } else {
            mode = .fixture
        }

        let session = SnapshotSession(
            mode: mode,
            output: output,
            timeout: timeout,
            width: width,
            height: height
        )
        session.onComplete = { NSApp.terminate(nil) }
        self.session = session
        session.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
