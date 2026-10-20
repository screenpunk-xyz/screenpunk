import Foundation
import ScreenpunkCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HomeAssistantConnectionSetup {
    enum SetupError: LocalizedError {
        case address, token, http, authentication, response, unreachable
        var errorDescription: String? {
            switch self {
            case .address: return "Enter your Home Assistant hostname or IP address, with its port if needed."
            case .token: return "Paste or scan a Home Assistant long-lived access token."
            case .http: return "Enable Allow HTTP on my local network to use this address."
            case .authentication: return "Home Assistant rejected this token. Create a new long-lived access token and try again."
            case .response: return "This address did not return the Home Assistant API. Check the address and port."
            case .unreachable: return "Could not reach Home Assistant. Check the address, Wi-Fi and local network permission. If your server uses HTTP, enable Allow HTTP on my local network."
            }
        }
    }
    static func origins(_ input: String, allowHTTP: Bool) throws -> [String] {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitScheme = value.contains("://")
        guard !value.isEmpty, value.utf8.count <= 2048,
              var parts = URLComponents(string: explicitScheme ? value : "https://" + value),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { throw SetupError.address }
        parts.scheme = parts.scheme?.lowercased(); parts.path = ""
        guard let origin = parts.url?.absoluteString else { throw SetupError.address }
        if parts.scheme == "http" && !allowHTTP { throw SetupError.http }
        var candidates = [origin]
        if !explicitScheme && allowHTTP { parts.scheme = "http"; if let http = parts.url?.absoluteString { candidates.append(http) } }
        return candidates
    }
    static func scannedToken(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // HA tokens are JWTs. Never open a scanned URL or send it to another app.
        guard value.utf8.count <= 8192, value.split(separator: ".", omittingEmptySubsequences: false).count == 3,
              value.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw SetupError.token }
        return value
    }
    static func verify(address: String, token: String, allowHTTP: Bool, transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> String {
        let candidates = try origins(address, allowHTTP: allowHTTP)
        guard !token.isEmpty, token.utf8.count <= 8192,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { throw SetupError.token }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for (index, origin) in candidates.enumerated() {
            var request = URLRequest(url: URL(string: origin + "/api/")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            do {
                let result: (Data, URLResponse)
                if let transport { result = try await transport(request) }
                else { result = try await session.data(for: request) }
                let (data, response) = result
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw SetupError.response }
                if response.statusCode == 401 || response.statusCode == 403 { throw SetupError.authentication }
                guard response.statusCode == 200, data.count < 16_384,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      body["message"] == "API running." else { throw SetupError.response }
                return origin
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                let mayTryHTTP = [.cannotConnectToHost, .secureConnectionFailed, .timedOut, .networkConnectionLost].contains(error.code)
                if index + 1 < candidates.count && mayTryHTTP { continue }
                throw SetupError.unreachable
            }
        }
        throw SetupError.unreachable
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
