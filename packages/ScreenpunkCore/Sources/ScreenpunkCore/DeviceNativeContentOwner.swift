import Foundation

/// Stable provenance vocabulary only. Neither case proves current authority.
/// Installation identity is never a PairingIdentity or a credential generation.
enum DeviceNativeContentOwner: Equatable, Sendable {
    case localController(PairingIdentity)
    case nativeInstallation(DeviceNativeInstallationContentOwner)
}
struct DeviceNativeInstallationContentOwner: Equatable, Sendable {
    let installationID: UUID
    let accountID: UUID
    let locationID: UUID?
    let transitionID: UUID
}
