import Foundation
import CoreFoundation
import ScreenpunkController

/// Ordinary MCP management calls. These are named client APIs, never a
/// method-string passthrough into the broker's trusted local-review channel.
extension LegacyBrokerAdapter {
    static let managementTools: Set<String> = [
        "get_workspace_coverage", "get_workspace_toolchain_requirements",
        "list_workspace_operations", "get_workspace_operation_status",
        "cancel_workspace_operation", "discover_devices", "get_pending_pairings",
        "begin_device_pairing", "confirm_device_pairing", "cancel_device_pairing"
    ]
    static let managementReadTools: Set<String> = [
        "get_workspace_coverage", "get_workspace_toolchain_requirements",
        "list_workspace_operations", "get_workspace_operation_status",
        "discover_devices", "get_pending_pairings"
    ]

    func managementCall(name: String, arguments: [String: Any]) throws -> (String, Bool) {
        try Self.validateManagement(name: name, arguments: arguments)
        switch name {
        case "get_workspace_coverage":
            return (try Self.json(client.workspaceCoverage(validate: arguments["validate"] as? Bool ?? false)), false)
        case "get_workspace_toolchain_requirements":
            return (try Self.json(client.toolchainRequirements()), false)
        case "list_workspace_operations":
            return (try Self.json(client.workspaceOperationList()), false)
        case "get_workspace_operation_status":
            return (try Self.json(client.workspaceOperationStatus(operationId: arguments["operationId"] as! String)), false)
        case "cancel_workspace_operation":
            return (try Self.json(client.requestWorkspaceOperationCancel(operationId: arguments["operationId"] as! String)), false)
        case "discover_devices":
            return (try Self.json(client.discoverDevices()), false)
        case "get_pending_pairings":
            return (try Self.json(client.pendingPairings()), false)
        case "begin_device_pairing":
            return (try Self.json(client.beginPairing(deviceId: arguments["deviceId"] as! String)), false)
        case "confirm_device_pairing":
            return (try Self.json(client.confirmPairing(pendingId: arguments["pendingId"] as! String,
                matchingCode: arguments["matchingCode"] as! String)), false)
        case "cancel_device_pairing":
            try client.cancelPairing(pendingId: arguments["pendingId"] as! String)
            return ("{\"cancelled\":true}", false)
        default: throw WorkbenchIPCError(.invalidRequest)
        }
    }

    static func validateManagement(name: String, arguments: [String: Any]) throws {
        let keys = Set(arguments.keys)
        func string(_ field: String) throws {
            guard let value = arguments[field] as? String, !value.isEmpty,
                  value.utf8.count <= 256 else { throw WorkbenchIPCError(.invalidRequest) }
        }
        switch name {
        case "get_workspace_coverage":
            guard keys.isEmpty || keys == ["validate"] else { throw WorkbenchIPCError(.invalidRequest) }
            if let value = arguments["validate"] {
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
            }
        case "get_workspace_toolchain_requirements", "list_workspace_operations",
             "discover_devices", "get_pending_pairings":
            guard keys.isEmpty else { throw WorkbenchIPCError(.invalidRequest) }
        case "get_workspace_operation_status", "cancel_workspace_operation":
            guard keys == ["operationId"] else { throw WorkbenchIPCError(.invalidRequest) }
            try string("operationId")
        case "begin_device_pairing":
            guard keys == ["deviceId"] else { throw WorkbenchIPCError(.invalidRequest) }
            try string("deviceId")
        case "confirm_device_pairing":
            guard keys == ["pendingId", "matchingCode"] else { throw WorkbenchIPCError(.invalidRequest) }
            try string("pendingId"); try string("matchingCode")
        case "cancel_device_pairing":
            guard keys == ["pendingId"] else { throw WorkbenchIPCError(.invalidRequest) }
            try string("pendingId")
        default: throw WorkbenchIPCError(.invalidRequest)
        }
    }

    static func managementSchema(_ name: String) -> JSONValue {
        let string: JSONValue = .object(["type": .string("string"), "minLength": .int(1),
                                          "maxLength": .int(256)])
        var fields: [String: JSONValue] = [:]
        var required: [String] = []
        switch name {
        case "get_workspace_coverage":
            fields = ["validate": .object(["type": .string("boolean")])]
        case "get_workspace_operation_status", "cancel_workspace_operation":
            fields = ["operationId": string]; required = ["operationId"]
        case "begin_device_pairing":
            fields = ["deviceId": string]; required = ["deviceId"]
        case "confirm_device_pairing":
            fields = ["pendingId": string, "matchingCode": string]
            required = ["pendingId", "matchingCode"]
        case "cancel_device_pairing":
            fields = ["pendingId": string]; required = ["pendingId"]
        default: break
        }
        return .object(["type": .string("object"), "properties": .object(fields),
                        "required": .array(required.map(JSONValue.string)),
                        "additionalProperties": .bool(false)])
    }
}
