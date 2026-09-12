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

public struct PackageAssetStore: Sendable {
    public var assets: [String: PackageAsset]

    public init(assets: [String: PackageAsset] = [:]) {
        self.assets = assets
    }

    public static func mime(for path: String) -> String {
        if path.hasSuffix(".html") { return "text/html" }
        if path.hasSuffix(".js") { return "text/javascript" }
        if path.hasSuffix(".css") { return "text/css" }
        if path.hasSuffix(".json") { return "application/json" }
        if path.hasSuffix(".svg") { return "image/svg+xml" }
        if path.hasSuffix(".png") { return "image/png" }
        return "application/octet-stream"
    }

    public static func load(directory: URL) throws -> PackageAssetStore {
        var assets: [String: PackageAsset] = [:]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let file = enumerator?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let rel = file.path.replacingOccurrences(of: directory.path + "/", with: "")
            let path = try PackagePath.normalize(rel)
            let data = try Data(contentsOf: file)
            assets[path] = PackageAsset(path: path, data: data, mime: mime(for: path))
        }
        return PackageAssetStore(assets: assets)
    }

    public static func bundledOfflineFixture() throws -> PackageAssetStore {
        let candidates = [
            Bundle.module.url(forResource: "offline-fixture", withExtension: nil),
            Bundle.main.url(forResource: "offline-fixture", withExtension: nil)
        ]
        guard let dir = candidates.compactMap({ $0 }).first else {
            throw PackageAssetError.missingBundle
        }
        return try load(directory: dir)
    }

    public func asset(forSchemeURL url: String) throws -> PackageAsset {
        let prefix = "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/"
        guard url.hasPrefix(prefix) else { throw PackageAssetError.denied }
        let path = try PackagePath.normalize(String(url.dropFirst(prefix.count)))
        guard IsolationEvaluator.isLocalPackageURL(url) else { throw PackageAssetError.denied }
        guard let asset = assets[path] else { throw PackageAssetError.missingFile }
        return asset
    }
}
