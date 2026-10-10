/// The existing Mac Apply button is enabled only for a verified, offline,
/// selection-matched service session with no unresolved prior attempt.
enum MacBrokerApplyButtonGate {
    static func allows(verifiedGUI: Bool, busy: Bool, selectedDeviceMatches: Bool,
                       hasExactOfflinePackage: Bool,
                       prior: MacBrokerApplyJournal.Record?) -> Bool {
        verifiedGUI && !busy && selectedDeviceMatches && hasExactOfflinePackage &&
            prior?.blocksNewApply != true
    }
}
