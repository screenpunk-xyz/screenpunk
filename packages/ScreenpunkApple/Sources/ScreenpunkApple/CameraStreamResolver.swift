import Foundation
import ScreenpunkCore

/// Native-only stream descriptor. Never serialized across the JavaScript bridge.
/// Direct HLS adapters can reuse this; RTSP will need a separate decoding backend.
public struct CameraStream: Sendable {
    public let url: URL
    public let isAuthorized: @Sendable () async -> Bool
    public init(url: URL, isAuthorized: @escaping @Sendable () async -> Bool) {
        self.url = url; self.isAuthorized = isAuthorized
    }
}
public protocol CameraStreamResolver: Sendable {
    func resolveCamera(_ source: CameraSource, revision: String) async throws -> CameraStream
}

/// A short-lived authenticated HA websocket negotiates an HLS capability URL.
/// No bearer header is attached to media requests or returned to the screen.
enum HomeAssistantCameraHandshake {
    static func resolve(origin: String, token: String, entityId: String) async throws -> URL {
        guard var components = URLComponents(string: origin) else { throw ConnectionFailure.validationFailed }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/websocket"
        guard let url = components.url else { throw ConnectionFailure.validationFailed }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RedirectDenyingDelegate(), delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 64 * 1024
        socket.resume()
        let deadline = Task {
            try await Task.sleep(nanoseconds: 12_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler(operation: {
            func receive() async throws -> [String: Any] {
                let message = try await socket.receive()
                let data: Data
                switch message { case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: throw ConnectionFailure.validationFailed }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionFailure.validationFailed }
                return object
            }
            func send(_ object: [String: Any]) async throws {
                let data = try JSONSerialization.data(withJSONObject: object)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            }
            let hello = try await receive()
            guard hello["type"] as? String == "auth_required" else { throw ConnectionFailure.permissionRequired }
            try await send(["type": "auth", "access_token": token])
            let auth = try await receive()
            guard auth["type"] as? String == "auth_ok" else { throw ConnectionFailure.permissionRequired }
            try await send(["id": 1, "type": "camera/stream", "entity_id": entityId, "format": "hls"])
            let response = try await receive()
            guard response["id"] as? Int == 1, response["success"] as? Bool == true,
                  let result = response["result"] as? [String: Any], let path = result["url"] as? String else {
                throw ConnectionFailure.deviceOffline
            }
            return try mediaURL(path: path, origin: origin)
        }, onCancel: { socket.cancel(with: .goingAway, reason: nil) })
    }

    static func mediaURL(path: String, origin: String) throws -> URL {
        // Only HA's relative HLS endpoint, never arbitrary URLs returned by a server.
        guard path.utf8.count <= 2048,
              path.range(of: "^/api/hls/[A-Za-z0-9_-]+/master_playlist\\.m3u8$", options: .regularExpression) != nil,
              let base = URL(string: origin), let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw ConnectionFailure.deniedEgress
        }
        return url
    }
}
