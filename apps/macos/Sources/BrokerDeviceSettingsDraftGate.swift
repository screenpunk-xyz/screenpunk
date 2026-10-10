/// Tracks edits made after a settings reload began. The UI must ask before a
/// response can replace a newer user draft; an unchanged draft accepts a
/// positive refresh without interruption.
struct BrokerDeviceSettingsDraftGate {
    private(set) var revision: UInt64 = 0
    private(set) var savedRevision: UInt64 = 0

    mutating func edited() { revision &+= 1 }
    mutating func markLoaded() { savedRevision = revision }
    mutating func markSaved(submittedRevision: UInt64) { savedRevision = submittedRevision }
    var hasUnsavedEdits: Bool { revision != savedRevision }
    func requiresReplacementChoice(since startedAt: UInt64) -> Bool {
        hasUnsavedEdits || revision != startedAt
    }
    func acceptsReload(since startedAt: UInt64, explicitlyConfirmed: Bool) -> Bool {
        !requiresReplacementChoice(since: startedAt) || explicitlyConfirmed
    }
}
