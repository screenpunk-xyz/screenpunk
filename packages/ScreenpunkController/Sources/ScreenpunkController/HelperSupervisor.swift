import Foundation

/// Locates and, when possible, launches the hidden preview helper.
/// Closing the workbench must not be required for MCP preview.
public struct HelperSupervisor: Sendable {
    public var searchPaths: [URL]

    public init(searchPaths: [URL] = []) {
        self.searchPaths = searchPaths
    }

    public static let socketName = "screenpunk-preview-helper.sock"

    public func resolveExecutable() -> URL? {
        if let override = ProcessInfo.processInfo.environment["SCREENPUNK_PREVIEW_HOST"], override.isEmpty == false {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
            let nested = url.appendingPathComponent("Contents/MacOS/ScreenpunkPreviewHost")
            if FileManager.default.isExecutableFile(atPath: nested.path) {
                return nested
            }
        }

        for candidate in searchPaths + defaultCandidates() {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public func makeRenderer() -> PreviewRenderer? {
        guard let executable = resolveExecutable() else { return nil }
        return ProcessPreviewRenderer(executableURL: executable)
    }

    public func defaultCandidates() -> [URL] {
        var urls: [URL] = []
        if let argv0 = ProcessInfo.processInfo.arguments.first {
            let mcp = URL(fileURLWithPath: argv0)
            let contents = mcp.deletingLastPathComponent()
            urls.append(contents.appendingPathComponent("ScreenpunkPreviewHost"))
            urls.append(
                contents
                    .deletingLastPathComponent()
                    .appendingPathComponent("Helpers/ScreenpunkPreviewHost.app/Contents/MacOS/ScreenpunkPreviewHost")
            )
            urls.append(
                contents
                    .deletingLastPathComponent()
                    .appendingPathComponent("MacOS/ScreenpunkPreviewHost")
            )
        }
        urls.append(
            URL(fileURLWithPath: "/Applications/Screenpunk.app/Contents/Helpers/ScreenpunkPreviewHost.app/Contents/MacOS/ScreenpunkPreviewHost")
        )
        urls.append(
            URL(fileURLWithPath: "/Applications/Screenpunk.app/Contents/MacOS/ScreenpunkPreviewHost")
        )
        return urls
    }
}

public enum ControllerPaths {
    public static let socketName = ControllerPlaceholder.socketName
    public static var schemaMajor: Int { ControllerPlaceholder.schemaMajor }
}
