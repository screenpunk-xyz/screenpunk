/// The displayed workspace identity and selection generation must still be
/// active immediately before presenting a plan and again before Apply.
enum MacBrokerReviewSelectionGate {
    static func matches(expectedId: String, expectedGeneration: Int,
                        state: String, currentId: String?, currentGeneration: Int?) -> Bool {
        state == "selected" && currentId == expectedId &&
            currentGeneration == expectedGeneration
    }
}
