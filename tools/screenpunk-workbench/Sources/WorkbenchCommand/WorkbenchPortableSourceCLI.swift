import Foundation
import ScreenpunkController

/// Argument grammar only. Work happens through the authenticated broker's
/// selection-bound authoring route in WorkbenchCommand.
enum WorkbenchPortableSourceCLI {
    static func route(_ words: [String]) throws -> WorkbenchAuthoringRecoveryCLI.Route? {
        guard words.count >= 2, words[0] == "project" else { return nil }
        let method: WorkbenchAuthoringRecoveryMethod
        var fields: [String: Any] = ["schemaVersion": 1]
        switch words[1] {
        case "export-source":
            guard words.count == 7, words[3] == "--source-version", words[5] == "--out" else {
                throw Options.usage("project export-source requires PROJECT_ID --source-version HASH --out ABSOLUTE_DESTINATION.")
            }
            method = .projectSourceExport
            fields["projectId"] = words[2]; fields["sourceVersion"] = words[4]
            fields["path"] = words[6]
        case "import-source":
            guard words.count == 3 || (words.count == 5 && words[3] == "--to") else {
                throw Options.usage("project import-source requires ABSOLUTE_ARCHIVE [--to Screens/NAME].")
            }
            method = .projectSourceImport; fields["path"] = words[2]
            if words.count == 5 { fields["name"] = try destinationName(words[4]) }
        case "open-external":
            guard words.count == 4, words[3] == "--external" else {
                throw Options.usage("project open-external requires ABSOLUTE_PROJECT_PATH --external.")
            }
            method = .projectOpenExternal; fields["path"] = words[2]
            fields["explicitExternal"] = true
        case "adopt":
            guard words.count == 7, words[3] == "--source-version", words[5] == "--to" else {
                throw Options.usage("project adopt requires PROJECT_ID --source-version HASH --to Screens/NAME.")
            }
            method = .projectAdoptExternal; fields["projectId"] = words[2]
            fields["expectedSourceVersion"] = words[4]
            fields["name"] = try destinationName(words[6])
        default: return nil
        }
        do { _ = try WorkbenchAuthoringRecoveryRequest.parse(method: method, params: fields) }
        catch { throw Options.usage("Invalid portable-source command input.") }
        return .init(method: method, params: fields)
    }

    private static func destinationName(_ relative: String) throws -> String {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Screens", !parts[1].isEmpty,
              !parts[1].hasPrefix("."), !parts[1].contains("\\") else {
            throw Options.usage("--to must name one contained folder as Screens/NAME.")
        }
        return String(parts[1])
    }
}
