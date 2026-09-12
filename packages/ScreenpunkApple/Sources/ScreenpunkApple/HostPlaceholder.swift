import ScreenpunkCore

/// Shared Apple host will load validated packages in WKWebView.
/// Milestone 0 bootstrap only — no first-party UI.
public enum AppleHostPlaceholder: Sendable {
    public static let customScheme = "screenpunk"
    public static var iosDeploymentTarget: String { PlatformRequirements.iosMinimum }
}
