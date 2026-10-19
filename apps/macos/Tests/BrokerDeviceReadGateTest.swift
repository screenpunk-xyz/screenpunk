import Foundation

@main
struct BrokerDeviceReadGateTest {
    static func main() {
        var gate = BrokerDeviceReadGate()
        gate.select("device-a")
        let aStatus = gate.begin(.status)!
        let aSettings = gate.begin(.settings)!
        gate.select("device-b")
        precondition(!gate.accepts(aStatus) && !gate.accepts(aSettings))
        let bStatus = gate.begin(.status)!
        let bSettings = gate.begin(.settings)!
        let bInventory = gate.begin(.inventory)!
        precondition(gate.accepts(bStatus) && gate.accepts(bSettings) && gate.accepts(bInventory))
        let newerBSettings = gate.begin(.settings)!
        precondition(!gate.accepts(bSettings) && gate.accepts(newerBSettings))
        precondition(gate.accepts(bStatus) && gate.accepts(bInventory))
        gate.select(nil)
        precondition(!gate.accepts(bStatus) && !gate.accepts(newerBSettings) && !gate.accepts(bInventory))
        print("BrokerDeviceReadGateTest passed")
    }
}
