import XCTest
@testable import ScreenpunkApple

final class GoogleTVChannelLaunchTests: XCTestCase {
    func testChannelCommandCannotInjectShellOrChangeTarget() throws {
        XCTAssertEqual(try GoogleTVChannelLaunch.command(channelID: "LXfrE81qMGA"),
            "am start -W -a android.intent.action.VIEW -d 'https://tv.youtube.com/watch/LXfrE81qMGA' -n com.google.android.youtube.tvunplugged/com.google.android.apps.youtube.tvunplugged.activity.ChrobaltMainActivity")
        for id in ["", "short", "abcdefghijkl", "abcdefghij;", "abcdefghij'", "abcdefghij\n", "$(whoami)xx", "https://tv.youtube.com/watch/LXfrE81qMGA", "LXfrE81qMGA?vp=1", "abcdefghijé"] {
            XCTAssertThrowsError(try GoogleTVChannelLaunch.command(channelID: id), id)
        }
    }

    func testDispatchRequiresActivityManagerSuccess() throws {
        try GoogleTVChannelLaunch.validateDispatch(exitCode: 0, output: "Starting: Intent { ... }\nStatus: ok\nComplete\n")
        for output in ["", "Starting: Intent { ... }", "Error: Activity class does not exist\nStatus: ok", "java.lang.SecurityException\nStatus: ok", String(repeating: "x", count: 16_385) + "\nStatus: ok"] {
            XCTAssertThrowsError(try GoogleTVChannelLaunch.validateDispatch(exitCode: 0, output: output))
        }
        XCTAssertThrowsError(try GoogleTVChannelLaunch.validateDispatch(exitCode: 1, output: "Status: ok"))
    }
}
