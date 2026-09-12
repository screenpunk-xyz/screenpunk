import ScreenpunkCore

/// Local per-user controller. macOS workbench/MCP will talk to this process.
public enum ControllerPlaceholder: Sendable {
    public static let socketName = "screenpunk-controller.sock"
    public static var schemaMajor: Int { PackageLimits.schemaMajor }
}
