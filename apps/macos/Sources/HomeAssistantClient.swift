import Foundation

enum HomeAssistantSetupError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Use only the entered server; never forward its bearer credential to a redirect target.
private final class HomeAssistantRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum HomeAssistantClient {
    static func baseURL(_ address: String) throws -> URL {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw HomeAssistantSetupError.message("Enter an http:// or https:// Home Assistant address without credentials or query parameters.")
        }
        guard parts.path.isEmpty || parts.path == "/" else {
            throw HomeAssistantSetupError.message("Use the Home Assistant origin, such as http://homeassistant.local:8123, without a URL path.")
        }
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw HomeAssistantSetupError.message("Enter a valid Home Assistant address.") }
        return url
    }
    static func verify(baseURL: URL, token: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: HomeAssistantRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/"))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw HomeAssistantSetupError.message("Home Assistant did not return an HTTP response.") }
        if response.statusCode == 401 || response.statusCode == 403 { throw HomeAssistantSetupError.message("Home Assistant rejected this token. Check the token and try again.") }
        if (300..<400).contains(response.statusCode) { throw HomeAssistantSetupError.message("This address redirects. Enter the final Home Assistant address and try again.") }
        guard response.statusCode == 200 else { throw HomeAssistantSetupError.message("Home Assistant returned HTTP \(response.statusCode). Check its address and try again.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16_384 else { throw HomeAssistantSetupError.message("This address did not return the expected Home Assistant response.") }
            data.append(byte)
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: String], value["message"] == "API running." else {
            throw HomeAssistantSetupError.message("This address does not appear to be the Home Assistant API.")
        }
    }
}
