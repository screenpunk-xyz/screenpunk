import Foundation
import ScreenpunkCore
#if canImport(WebKit)
import WebKit
#endif

/// Native host isolation scaffolding. No designed first-party UI.
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
/// Custom-scheme load of package-local assets. HTTP(S) is not handled here.
public final class PackageSchemeHandler: NSObject, WKURLSchemeHandler {
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url?.absoluteString,
              IsolationEvaluator.isLocalPackageURL(url)
        else {
            urlSchemeTask.didFailWithError(URLError(.appTransportSecurityRequiresSecureConnection))
            return
        }
        let denied = URLError(.dataNotAllowed)
        urlSchemeTask.didFailWithError(denied)
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
#endif
