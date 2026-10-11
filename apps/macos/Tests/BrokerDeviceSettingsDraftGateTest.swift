@main
struct BrokerDeviceSettingsDraftGateTest {
    static func main() {
        var draft = BrokerDeviceSettingsDraftGate()
        let firstReload = draft.revision
        precondition(draft.acceptsReload(since: firstReload, explicitlyConfirmed: false))
        draft.edited(); draft.markLoaded() // A clean positive device refresh.
        precondition(!draft.hasUnsavedEdits)
        let delayedReload = draft.revision
        draft.edited() // The person types while the device response is in flight.
        precondition(draft.requiresReplacementChoice(since: delayedReload))
        precondition(!draft.acceptsReload(since: delayedReload, explicitlyConfirmed: false))
        precondition(draft.acceptsReload(since: delayedReload, explicitlyConfirmed: true))
        // A draft already dirty when reload starts also needs an explicit choice.
        precondition(!draft.acceptsReload(since: draft.revision, explicitlyConfirmed: false))
        // A successful save uses the current draft; it does not erase another
        // edit made after that save request began.
        let submittedRevision = draft.revision
        draft.edited()
        draft.markSaved(submittedRevision: submittedRevision)
        precondition(draft.hasUnsavedEdits)
        precondition(!draft.acceptsReload(since: submittedRevision, explicitlyConfirmed: false))
        print("BrokerDeviceSettingsDraftGateTest passed")
    }
}
