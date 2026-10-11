/// All user-visible device context that can change between the pinned read
/// and the final Apply review. Observation time is intentionally excluded:
/// two equivalent fresh reads have different timestamps.
struct MacBrokerObservedContext<Profile: Equatable, Screen: Equatable>: Equatable {
    let deviceId: String
    let name: String
    let profile: Profile
    let screens: [Screen]
    let selectedDashboardId: String?
    let authority: String
}
