import Foundation

private final class ControllerResourceAnchor {}

/// App bundles, SwiftPM products, and the signed CLI distribution have different
/// resource layouts. Resolve the executable before looking beside it so Homebrew's
/// public binary links cannot redirect resource lookup to /opt/homebrew/bin.
enum BundledResources {
    static func url(forResource name: String, withExtension ext: String,
                    executable: URL? = Bundle.main.executableURL,
                    mainResourceURL: URL? = Bundle.main.resourceURL,
                    mainBundleURL: URL = Bundle.main.bundleURL,
                    containingBundleURL: URL? = Bundle(for: ControllerResourceAnchor.self).bundleURL) -> URL? {
        let bundleName = "ScreenpunkController_ScreenpunkController.bundle"
        let executableDirectory = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
        let resources = executableDirectory?.deletingLastPathComponent().appendingPathComponent("Resources")
        // These flat JSON members are measured by the signed release manifest.
        if let directory = resources?.appendingPathComponent("help"),
           let url = file(name, ext: ext, in: directory) { return url }
        let bundles = [
            resources?.appendingPathComponent(bundleName),
            mainResourceURL?.appendingPathComponent(bundleName),
            executableDirectory?.appendingPathComponent(bundleName),
            mainBundleURL.appendingPathComponent(bundleName),
            // SwiftPM test bundles sit beside their resource bundles.
            containingBundleURL?.deletingLastPathComponent().appendingPathComponent(bundleName)
        ]
        for url in bundles.compactMap({ $0 }) {
            if let bundle = Bundle(url: url),
               let resource = bundle.url(forResource: name, withExtension: ext) { return resource }
        }
        // Bundle.module traps if neither its invocation-relative bundle nor its
        // generated build-host path exists. Missing optional help/catalog data
        // must instead allow the callers' existing fallback content.
        return nil
    }

    private static func file(_ name: String, ext: String, in directory: URL) -> URL? {
        let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
}
