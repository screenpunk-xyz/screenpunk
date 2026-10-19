import Foundation
import ScreenpunkController

enum WorkbenchProjectCloneCLI {
    static func route(_ words: [String]) throws -> WorkbenchAuthoringRecoveryCLI.Route? {
        guard words.prefix(2).elementsEqual(["project", "clone"]) else { return nil }
        guard (words.count == 5 || words.count == 7), words[3] == "--source-version",
              (words.count == 5 || words[5] == "--to") else {
            throw Options.usage("project clone requires PROJECT_ID --source-version HASH [--to Screens/NAME].")
        }
        var params: [String: Any] = ["schemaVersion": 1, "projectId": words[2],
            "expectedSourceVersion": words[4]]
        if words.count == 7 {
            let destination = words[6]
            guard destination.hasPrefix("Screens/"),
                  destination.split(separator: "/").count == 2 else {
                throw Options.usage("Clone destination must be Screens/NAME.")
            }
            params["name"] = String(destination.dropFirst("Screens/".count))
        }
        do { _ = try WorkbenchAuthoringRecoveryRequest.parse(method: .projectClone, params: params) }
        catch { throw Options.usage("Invalid project clone input.") }
        return .init(method: .projectClone, params: params)
    }
}
