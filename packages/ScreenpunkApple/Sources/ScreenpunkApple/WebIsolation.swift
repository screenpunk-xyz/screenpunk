import Foundation
import ScreenpunkCore
#if canImport(WebKit)
import WebKit
#endif

/// Native host isolation. Custom scheme serves package-local assets only.
public enum WebIsolation: Sendable {
    public static var customScheme: String { IsolationPolicy.customScheme }
    public static var contentSecurityPolicy: String { IsolationPolicy.contentSecurityPolicy }
    public static var contentRuleListJSON: String { IsolationPolicy.contentRuleListJSON }
    public static var nativeNetworkingOnly: Bool { IsolationPolicy.nativeNetworkingOnly }

    public static func evaluate(_ request: IsolationRequest) -> IsolationDecision {
        IsolationEvaluator.decide(request)
    }

    public static func recoverAfterContentProcessCrash() -> String {
        ContentProcessFailure.simulateTermination()
    }
}

#if canImport(WebKit)
public final class PackageSchemeHandler: NSObject, WKURLSchemeHandler {
    public let store: PackageAssetStore

    public init(store: PackageAssetStore) {
        self.store = store
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        let absolute = url?.absoluteString ?? ""
        do {
            let asset = try store.asset(forSchemeURL: absolute)
            guard let url else { throw PackageAssetError.denied }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": asset.mime,
                    "Content-Security-Policy": IsolationPolicy.contentSecurityPolicy,
                    "Cache-Control": "no-store"
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(asset.data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(URLError(.cannotOpenFile))
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
#endif
