import Foundation

/// Byte ranges are used by WebKit/AVFoundation when loading package media.
/// Resolve the asset through PackageAssetStore before constructing a response.
struct PackageMediaResponse {
    let status: Int
    let headers: [String: String]
    let data: Data

    init(asset: PackageAsset, range: String?, method: String = "GET") {
        let count = asset.data.count
        var headers = ["Content-Type": asset.mime, "Accept-Ranges": "bytes"]
        var status = 200
        var data = asset.data
        if let range {
            if let bounds = Self.byteRange(range, count: count) {
                status = 206
                data = asset.data.subdata(in: bounds)
                headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(count)"
            } else {
                status = 416
                data = Data()
                headers["Content-Range"] = "bytes */\(count)"
            }
        }
        headers["Content-Length"] = String(data.count)
        self.status = status
        self.headers = headers
        self.data = method == "HEAD" ? Data() : data
    }

    private static func byteRange(_ value: String, count: Int) -> Range<Int>? {
        guard count > 0, value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        func number(_ value: Substring) -> Int? {
            guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int(value)
        }
        if parts[0].isEmpty {
            guard let suffix = number(parts[1]), suffix > 0 else { return nil }
            return max(0, count - suffix)..<count
        }
        guard let start = number(parts[0]), start < count else { return nil }
        if parts[1].isEmpty { return start..<count }
        guard let end = number(parts[1]), end >= start else { return nil }
        return start..<(min(end, count - 1) + 1)
    }
}
