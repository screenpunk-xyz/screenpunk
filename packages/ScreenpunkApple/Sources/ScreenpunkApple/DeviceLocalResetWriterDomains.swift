import Foundation
import ScreenpunkCore

/// Calendar/preferences only. Does not prove host, WebView, bridge or temporary-runtime suspension.
@MainActor final class DeviceLocalResetWriterRetirement {
    let scopeDigest: String
    let bundleID: UUID
    let preferenceRoot: URL
    let preferenceGeneration: UUID
    let calendarDomain: GoogleCalendarSuspensionDomain
    fileprivate init(scope: DeviceLocalResetScope, bundleID: UUID, preferences: ScreenPreferenceStore, calendar: GoogleCalendarDeviceService) {
        scopeDigest = scope.digest; self.bundleID = bundleID; preferenceRoot = preferences.canonicalRoot
        preferenceGeneration = preferences.writerGeneration; calendarDomain = calendar.suspension
    }
}

/// Default-provider seam for isolated tests; only the production provider may replace globals.
@MainActor final class DeviceLocalResetWriterProvider {
    static let production = DeviceLocalResetWriterProvider(productionCalendar: .shared, preferences: .shared)
    private(set) var calendar: GoogleCalendarDeviceService
    private(set) var preferences: ScreenPreferenceStore
    fileprivate let isProduction: Bool
    private init(productionCalendar: GoogleCalendarDeviceService, preferences: ScreenPreferenceStore) {
        calendar = productionCalendar; self.preferences = preferences; isProduction = true
    }
    init(calendar: GoogleCalendarDeviceService, preferences: ScreenPreferenceStore) throws {
        guard calendar.suspension !== GoogleCalendarSuspensionDomain.production,
              preferences.canonicalRoot != ScreenPreferenceStore.shared.canonicalRoot else { throw DeviceLocalResetWriterDomains.Failure.binding }
        self.calendar = calendar; self.preferences = preferences; isProduction = false
    }
    fileprivate func install(calendar: GoogleCalendarDeviceService, preferences: ScreenPreferenceStore,
                             capability: DeviceLocalResetReopeningCapability, retirement: DeviceLocalResetWriterRetirement) {
        precondition(capability.isConsuming(retirement))
        if isProduction {
            GoogleCalendarSuspensionDomain.install(calendar.suspension, capability: capability, retirement: retirement)
            GoogleCalendarDeviceService.installShared(calendar, capability: capability, retirement: retirement)
            ScreenPreferenceStore.installShared(preferences, capability: capability, retirement: retirement)
        }
        self.calendar = calendar; self.preferences = preferences
    }
}

/// Atomic process-local reopening; old objects retain their retired generation permanently.
/// No production reset caller is installed. Root lifecycle must separately retire all other writers.
@MainActor final class DeviceLocalResetWriterDomains {
    enum Failure: Error { case binding, staleGeneration }
    private let scope: DeviceLocalResetScope
    private let identity = UUID()
    private let provider: DeviceLocalResetWriterProvider?
    private(set) var calendar: GoogleCalendarDeviceService
    private(set) var preferences: ScreenPreferenceStore
    private var retirement: DeviceLocalResetWriterRetirement?

    init(scope: DeviceLocalResetScope, calendar: GoogleCalendarDeviceService? = nil, preferences: ScreenPreferenceStore? = nil, provider: DeviceLocalResetWriterProvider? = nil) throws {
        let defaults = provider ?? .production
        let calendar = calendar ?? defaults.calendar, preferences = preferences ?? defaults.preferences
        let defaultCalendar = calendar === defaults.calendar, defaultPreferences = preferences === defaults.preferences
        guard defaultCalendar == defaultPreferences,
              calendar.suspension !== defaults.calendar.suspension || (defaultCalendar && defaultPreferences),
              preferences.canonicalRoot != defaults.preferences.canonicalRoot || (defaultCalendar && defaultPreferences),
              preferences.canonicalRoot != ScreenPreferenceStore.shared.canonicalRoot || defaults.isProduction,
              calendar.suspension !== GoogleCalendarSuspensionDomain.production || defaults.isProduction else { throw Failure.binding }
        try scope.validateCurrentPaths()
        guard scope.preferencesRoot == preferences.canonicalRoot,
              scope.credentialItems.contains(.init(service: GoogleCalendarDeviceService.storageService, account: GoogleCalendarDeviceService.storageKey)) else { throw Failure.binding }
        self.scope = scope; self.calendar = calendar; self.preferences = preferences
        self.provider = defaultCalendar && defaultPreferences ? defaults : nil
    }
    func retireForReset() throws -> DeviceLocalResetWriterRetirement {
        try scope.validateCurrentPaths()
        if let retirement {
            guard retirement.calendarDomain === calendar.suspension, retirement.preferenceGeneration == preferences.writerGeneration,
                  preferences.isRetired, calendar.suspension.suspended else { throw Failure.staleGeneration }
            return retirement
        }
        guard preferences.isCurrentWriter else { throw Failure.staleGeneration }
        calendar.suspendForReset(); preferences.suspendForReset()
        guard calendar.suspension.suspended, preferences.isRetired else { throw Failure.staleGeneration }
        let evidence = DeviceLocalResetWriterRetirement(scope: scope, bundleID: identity, preferences: preferences, calendar: calendar)
        retirement = evidence
        return evidence
    }
    func open(_ capability: DeviceLocalResetReopeningCapability) throws {
        try scope.validateCurrentPaths()
        guard let retirement, retirement.bundleID == identity, retirement.scopeDigest == scope.digest,
              retirement.preferenceRoot == preferences.canonicalRoot,
              retirement.preferenceGeneration == preferences.writerGeneration,
              retirement.calendarDomain === calendar.suspension,
              calendar.suspension.suspended, preferences.isRetired else { throw Failure.staleGeneration }
        if let provider {
            guard provider.calendar === calendar, provider.preferences === preferences else { throw Failure.staleGeneration }
            if provider.isProduction {
                guard GoogleCalendarDeviceService.shared === calendar, ScreenPreferenceStore.shared === preferences,
                      GoogleCalendarSuspensionDomain.production === retirement.calendarDomain else { throw Failure.staleGeneration }
            }
        }
        let nextDomain = GoogleCalendarSuspensionDomain()
        let nextCalendar = calendar.fresh(in: nextDomain)
        let nextPreferences = preferences.preparedFreshStore()
        try capability.consume(retirement: retirement) {
            try preferences.reopen(capability: capability, retirement: retirement, nextGeneration: nextPreferences.writerGeneration) {
                provider?.install(calendar: nextCalendar, preferences: nextPreferences, capability: capability, retirement: retirement)
                calendar = nextCalendar; preferences = nextPreferences
                self.retirement = nil
            }
        }
    }
}
