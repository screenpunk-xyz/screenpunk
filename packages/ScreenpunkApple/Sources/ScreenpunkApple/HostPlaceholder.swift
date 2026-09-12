import ScreenpunkCore

/// Shared Apple host will load validated packages in WKWebView.
/// Milestone 0 — isolation policy is real; first-party chrome is still a stub.
public enum AppleHostPlaceholder: Sendable {
    public static var customScheme: String { IsolationPolicy.customScheme }
    public static var iosDeploymentTarget: String { PlatformRequirements.iosMinimum }
    public static var nativeNetworkingOnly: Bool { IsolationPolicy.nativeNetworkingOnly }
}
