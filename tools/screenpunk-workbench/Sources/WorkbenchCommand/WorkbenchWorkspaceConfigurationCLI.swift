import Foundation
import ScreenpunkController

enum WorkbenchWorkspaceConfigurationCLI {
    static func route(_ words: [String]) throws -> WorkbenchAuthoringRecoveryCLI.Route? {
        guard words.first == "workspace", words.count >= 2, words[1] == "config" else {
            return nil
        }
        guard words.count >= 3 else { throw Options.usage("workspace config requires get, path, set or unset.") }
        let method: WorkbenchAuthoringRecoveryMethod
        var params: [String: Any] = ["schemaVersion": 1]
        switch words[2] {
        case "get":
            guard words.count == 3 else { throw Options.usage("workspace config get takes no operands.") }
            method = .workspaceConfigGet
        case "path":
            guard words.count == 3 else { throw Options.usage("workspace config path takes no operands.") }
            method = .workspaceConfigPath
        case "set":
            guard words.count == 6, let generation = Int(words[5]) else {
                throw Options.usage("workspace config set requires KEY VALUE EXPECTED_GENERATION.")
            }
            method = .workspaceConfigSet
            params["key"] = words[3]; params["value"] = words[4]
            params["expectedGeneration"] = generation
        case "unset":
            guard words.count == 5, let generation = Int(words[4]) else {
                throw Options.usage("workspace config unset requires KEY EXPECTED_GENERATION.")
            }
            method = .workspaceConfigUnset
            params["key"] = words[3]; params["expectedGeneration"] = generation
        default:
            throw Options.usage("Unknown workspace config command.")
        }
        do { _ = try WorkbenchAuthoringRecoveryRequest.parse(method: method, params: params) }
        catch { throw Options.usage("Invalid workspace config key, value or generation.") }
        return .init(method: method, params: params)
    }
}
