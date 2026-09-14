import Foundation

/// Both the app and its embedded command-line agent use Resources in the app bundle.
enum BundledResources {
    static var bundle: Bundle {
        let name = "ScreenpunkApple_ScreenpunkApple.bundle"
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/" + name),
            executable.deletingLastPathComponent().appendingPathComponent(name)
        ]
        for url in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.module
    }
}
