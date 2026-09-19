import Foundation
import ScreenpunkCore

/// Opaque, per-WebView leases. Handles cannot be used by another WebView or after revocation.
public final class PublicRasterResources: @unchecked Sendable {
    private let lock = NSLock()
    private var assets: [String: PackageAsset] = [:]
    private var identities: [String: String] = [:]
    private var order: [String] = []
    private var references: [String: Int] = [:]
    private var pixels: [String: Int] = [:]
    private let isCurrent: @Sendable () -> Bool
    public init(isCurrent: @escaping @Sendable () -> Bool = { true }) { self.isCurrent = isCurrent }
    public func put(_ result: PublicReadResult) throws -> String {
        guard isCurrent(), let data = result.body, let mime = result.mime else { throw ConnectionFailure.permissionRequired }
        guard data.count <= 4 * 1024 * 1024 else { throw ConnectionFailure.sizeLimit }
        lock.lock(); defer { lock.unlock() }
        let identity = mime + ":" + PeerPin.hex(PeerPin.sha256(data))
        if let existing = identities[identity] { references[existing, default: 0] += 1; return "screenpunk://package/" + existing }
        let pixelCount = try PublicRasterValidator.validate(data, mime: mime)
        let path = "__native-raster/" + UUID().uuidString.lowercased()
        while assets.count >= 64 || pixels.values.reduce(0, +) + pixelCount > 16_777_216 || assets.values.reduce(0, { $0 + $1.data.count }) + data.count > 24 * 1024 * 1024 {
            guard let first = order.first else { break }
            remove(first)
        }
        assets[path] = .init(path: path, data: data, mime: mime); identities[identity] = path; references[path] = 1; pixels[path] = pixelCount; order.append(path)
        return "screenpunk://package/" + path
    }
    public func asset(url: String) throws -> PackageAsset {
        guard isCurrent(), url.hasPrefix("screenpunk://package/__native-raster/") else { throw ConnectionFailure.permissionRequired }
        lock.lock(); defer { lock.unlock() }
        guard let asset = assets[String(url.dropFirst("screenpunk://package/".count))] else { throw ConnectionFailure.permissionRequired }
        return asset
    }
    public func release(url: String) {
        lock.lock(); defer { lock.unlock() }
        guard url.hasPrefix("screenpunk://package/__native-raster/") else { return }
        let path = String(url.dropFirst("screenpunk://package/".count))
        if let count = references[path], count > 1 { references[path] = count - 1 } else { remove(path) }
    }
    public func clear() { lock.lock(); defer { lock.unlock() }; assets.removeAll(); identities.removeAll(); order.removeAll(); references.removeAll(); pixels.removeAll() }
    private func remove(_ path: String) {
        assets.removeValue(forKey: path); references.removeValue(forKey: path); pixels.removeValue(forKey: path); order.removeAll { $0 == path }; identities = identities.filter { $0.value != path }
    }
}
