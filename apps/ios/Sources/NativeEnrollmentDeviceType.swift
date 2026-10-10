import UIKit

/// Device-reported enrollment metadata, not an installation credential or viewport profile.
/// Capture once for the original operation; never recompute it for a retry.
@MainActor
enum NativeEnrollmentDeviceType {
    static func currentProfile() -> String? {
        profile(idiom: UIDevice.current.userInterfaceIdiom, isIOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
    }

    static func profile(idiom: UIUserInterfaceIdiom, isIOSAppOnMac: Bool) -> String? {
        if isIOSAppOnMac { return "Mac" }
        switch idiom {
        case .phone: return "iPhone"
        case .pad: return "iPad"
        case .mac: return "Mac"
        default: return nil
        }
    }
}

/// Snapshot of values the OS exposes to this app. `name` may be a generic device
/// name on iOS 16+ without Apple's user-assigned-device-name entitlement.
/// It is a suggested display name, not device identity or enrollment authority.
@MainActor
struct NativeEnrollmentDeviceMetadata {
    let name: String
    let profile: String

    static func capture() -> Self? {
        guard let profile = NativeEnrollmentDeviceType.currentProfile() else { return nil }
        return .init(name: suggestedName(systemName: UIDevice.current.name, profile: profile), profile: profile)
    }

    static func suggestedName(systemName: String, profile: String) -> String {
        let scalars = systemName.unicodeScalars
        guard (1...128).contains(scalars.count),
              scalars.contains(where: { !$0.properties.isWhitespace }),
              !scalars.contains(where: { $0.properties.generalCategory == .control }) else { return profile }
        return systemName
    }
}
