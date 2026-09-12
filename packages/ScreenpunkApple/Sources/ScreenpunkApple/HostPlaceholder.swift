import ScreenpunkCore

/// Shared Apple host loads validated packages in WKWebView over `screenpunk://`.
public enum AppleHostPlaceholder: Sendable {
    public static var customScheme: String { IsolationPolicy.customScheme }
    public static var iosDeploymentTarget: String { PlatformRequirements.iosMinimum }
    public static var nativeNetworkingOnly: Bool { IsolationPolicy.nativeNetworkingOnly }
    public static let offlineFixtureName = "offline-fixture"
    public static let entrypoint = "index.html"
}
