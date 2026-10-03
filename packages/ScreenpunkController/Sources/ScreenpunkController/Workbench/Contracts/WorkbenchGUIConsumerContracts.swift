import Foundation
import CoreFoundation

#if os(macOS)
public enum WorkbenchGUIConsumerMethod: String, CaseIterable, Sendable {
    case register = "gui.register"
    case renew = "gui.renew"
    case release = "gui.release"

    static func parse(_ method: Self, params: [String: Any]) throws {
        guard Set(params.keys) == ["schemaVersion"],
              let version = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}

public struct WorkbenchGUIConsumerResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: String
    public let consumerId: String
    public let leaseSeconds: Int

    init(method: WorkbenchGUIConsumerMethod, consumerId: String) {
        schemaVersion = 1; kind = method.rawValue
        self.consumerId = consumerId
        leaseSeconds = method == .release ? 0 : 30
    }
    func validate(for method: WorkbenchGUIConsumerMethod) throws {
        guard schemaVersion == 1, kind == method.rawValue,
              UUID(uuidString: consumerId) != nil,
              leaseSeconds == (method == .release ? 0 : 30) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}
#endif
