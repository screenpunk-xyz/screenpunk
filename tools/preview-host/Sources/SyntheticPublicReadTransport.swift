#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScreenpunkCore

/// Deterministic debug-only preview integration fixture. Never consults personal files or the network.
actor SyntheticPublicReadTransport: HTTPTransport {
    private var timelineReads = 0
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        guard request.url.host == "data.example.org", request.method == "GET", request.headers["Authorization"] == nil else { throw ConnectionFailure.deniedEgress }
        if request.url.path == "/timeline" {
            timelineReads += 1
            if timelineReads > 1 { return .init(status: 503, body: Data(), headers: ["retry-after": "10"]) }
            return .init(status: 200, body: Data("{\"frames\":[\"daily-one~orig.png\",\"daily-two.png\"],\"validTimes\":[\"synthetic A\",\"synthetic B\"]}".utf8), headers: ["content-type": "application/json"])
        }
        guard ["/frames/daily-one~orig.png", "/frames/daily-two.png"].contains(request.url.path) else { return .init(status: 404, body: Data()) }
        let context = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.15, blue: 0.25, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.65, alpha: 1))
        context.fillEllipse(in: CGRect(x: request.url.path.contains("daily-one") ? 40 : 180, y: 60, width: 80, height: 80))
        let data = NSMutableData(); let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConnectionFailure.validationFailed }
        return .init(status: 200, body: data as Data, headers: ["content-type": "image/png"])
    }
}
#endif
