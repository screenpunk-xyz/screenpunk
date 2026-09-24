import Foundation

/// Native-only command construction. Screens supply an approved channel ID,
/// never an executable, component, URI, host, port, or shell expression.
enum GoogleTVChannelLaunch {
    static let package = "com.google.android.youtube.tvunplugged"
    static let component = package + "/com.google.android.apps.youtube.tvunplugged.activity.ChrobaltMainActivity"

    static func validID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func command(channelID: String) throws -> String {
        guard validID(channelID) else {
            throw GoogleTVError.message("Use the 11-character YouTube TV watch ID approved in native settings.")
        }
        return "am start -W -a android.intent.action.VIEW -d 'https://tv.youtube.com/watch/\(channelID)' -n \(component)"
    }

    /// Activity Manager success establishes dispatch, never live playback.
    static func validateDispatch(exitCode: Int, output: String) throws {
        guard exitCode == 0, output.utf8.count <= 16_384,
              !output.localizedCaseInsensitiveContains("error:"),
              !output.localizedCaseInsensitiveContains("exception"),
              output.components(separatedBy: .newlines).contains(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Status: ok"
              }) else {
            throw GoogleTVError.message("YouTube TV did not confirm the channel launch. Check the installed app and debugging connection.")
        }
    }
}
