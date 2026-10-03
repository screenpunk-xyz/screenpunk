import Foundation
import ScreenpunkController

/// Explicit machine-local rebinding of an already registered external project.
/// No source bytes are copied and no portable catalog location is rewritten.
enum WorkbenchExternalRebindCLI {
    static func route(_ words: [String]) throws -> WorkbenchAuthoringRecoveryCLI.Route? {
        guard words.prefix(2).elementsEqual(["project", "relocate"]),
              words.last == "--external" else { return nil }
        guard words.count == 8, words[3] == "--source-version",
              words[5] == "--to", words[7] == "--external" else {
            throw Options.usage("project relocate requires PROJECT_ID --source-version HASH --to ABSOLUTE_PATH --external.")
        }
        let params: [String: Any] = ["schemaVersion": 1, "projectId": words[2],
            "expectedSourceVersion": words[4], "path": words[6], "explicitExternal": true]
        do {
            _ = try WorkbenchAuthoringRecoveryRequest.parse(
                method: .projectRelocateExternal, params: params)
        } catch { throw Options.usage("Invalid external project relocation input.") }
        return .init(method: .projectRelocateExternal, params: params)
    }
}
