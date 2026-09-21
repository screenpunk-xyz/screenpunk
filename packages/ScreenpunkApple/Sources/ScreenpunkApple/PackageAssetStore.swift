import Foundation
import ScreenpunkCore

public struct PackageAsset: Sendable, Equatable {
    public var path: String
    public var data: Data
    public var mime: String
}

public enum PackageAssetError: Error, Equatable {
    case missingBundle
    case missingFile
    case denied
}

public struct PackageAssetStore: Sendable, Equatable {
    public var assets: [String: PackageAsset]

    public init(assets: [String: PackageAsset] = [:]) {
        self.assets = assets
    }

    public static func mime(for path: String) -> String {
        let path = path.lowercased()
        if path.hasSuffix(".wav") { return "audio/wav" }
        if path.hasSuffix(".mp3") { return "audio/mpeg" }
        if path.hasSuffix(".m4a") { return "audio/mp4" }
        if path.hasSuffix(".aac") { return "audio/aac" }
        if path.hasSuffix(".aif") || path.hasSuffix(".aiff") { return "audio/aiff" }
        if path.hasSuffix(".caf") { return "audio/x-caf" }
        if path.hasSuffix(".html") { return "text/html" }
        if path.hasSuffix(".js") { return "text/javascript" }
        if path.hasSuffix(".css") { return "text/css" }
        if path.hasSuffix(".json") { return "application/json" }
        if path.hasSuffix(".svg") { return "image/svg+xml" }
        if path.hasSuffix(".png") { return "image/png" }
        if path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") { return "image/jpeg" }
        if path.hasSuffix(".woff") { return "font/woff" }
        if path.hasSuffix(".woff2") { return "font/woff2" }
        if path.hasSuffix(".txt") { return "text/plain" }
        return "application/octet-stream"
    }

    public static func load(directory: URL) throws -> PackageAssetStore {
        let directory = directory.resolvingSymlinksInPath()
        var assets: [String: PackageAsset] = [:]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let file = enumerator?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let resolvedPath = file.resolvingSymlinksInPath().path
            let prefix = directory.path + "/"
            guard resolvedPath.hasPrefix(prefix) else { throw PackageAssetError.denied }
            let rel = String(resolvedPath.dropFirst(prefix.count))
            let path = try hostRelativePath(rel)
            let data = try Data(contentsOf: file)
            assets[path] = PackageAsset(path: path, data: data, mime: mime(for: path))
        }
        return PackageAssetStore(assets: assets)
    }

    public static func bundledOfflineFixture() throws -> PackageAssetStore {
        let candidates = [
            BundledResources.bundle.url(forResource: "offline-fixture", withExtension: nil),
            Bundle.main.url(forResource: "offline-fixture", withExtension: nil)
        ]
        guard let dir = candidates.compactMap({ $0 }).first else {
            throw PackageAssetError.missingBundle
        }
        return try load(directory: dir)
    }

    public func asset(forSchemeURL url: String) throws -> PackageAsset {
        guard IsolationEvaluator.isLocalPackageURL(url) else { throw PackageAssetError.denied }
        let prefix = "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/"
        let path = try Self.hostRelativePath(String(url.dropFirst(prefix.count)))
        guard let asset = assets[path] else { throw PackageAssetError.missingFile }
        return asset
    }

    /// Host-local path check. PackagePath.normalize stays in Core; this host does not call it.
    static func hostRelativePath(_ path: String) throws -> String {
        let posix = path.replacingOccurrences(of: "\\", with: "/")
        if posix.hasPrefix("/")
            || posix.split(separator: "/").contains("..")
            || posix.lowercased().contains("%2e%2e")
            || posix.contains("\0")
        {
            throw PackageAssetError.denied
        }
        return posix
    }
}
