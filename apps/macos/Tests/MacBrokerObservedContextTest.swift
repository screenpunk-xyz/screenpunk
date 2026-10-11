@main
struct MacBrokerObservedContextTest {
    static func main() {
        typealias Context = MacBrokerObservedContext<String, String>
        let original = Context(deviceId: "device-a", name: "Kitchen", profile: "portrait",
            screens: ["screen-a@rev-1"], selectedDashboardId: "screen-a",
            authority: "fresh-pinned-owned-screen-set-v1")
        precondition(original == original)
        precondition(original != Context(deviceId: "device-a", name: "Kitchen", profile: "landscape",
            screens: ["screen-a@rev-1"], selectedDashboardId: "screen-a",
            authority: original.authority))
        precondition(original != Context(deviceId: "device-a", name: "Kitchen", profile: "portrait",
            screens: ["screen-a@rev-1"], selectedDashboardId: nil,
            authority: original.authority))
        precondition(original != Context(deviceId: "device-a", name: "Kitchen", profile: "portrait",
            screens: ["screen-a@rev-2"], selectedDashboardId: "screen-a",
            authority: original.authority))
        precondition(original != Context(deviceId: "device-b", name: "Kitchen", profile: "portrait",
            screens: ["screen-a@rev-1"], selectedDashboardId: "screen-a",
            authority: original.authority))
        print("MacBrokerObservedContextTest passed")
    }
}
