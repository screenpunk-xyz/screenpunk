import Foundation
import ScreenpunkController
import ScreenpunkDistribution

struct CommandFailure: Error {
    let code: String
    let message: String
    let exitStatus: Int32
    let nextActions: [String]
    let details: [String: String]
    init(_ code: String, _ message: String, _ exitStatus: Int32, nextActions: [String] = [], details: [String: String] = [:]) {
        self.code = code; self.message = message; self.exitStatus = exitStatus; self.nextActions = nextActions; self.details = details
    }
}

struct Options {
    var json = false
    var runtime: String?
    var workspace: String?
    var home: String?
    var profile: String?
    var host: String?
    var port: Int?
    var expectedRevision: String?
    var inputFile: String?
    var secretStdin = false
    var noInput = false
    var approved = false
    var timeout: Double = 10
    var words: [String] = []
    var help = false
    var version = false

    static func parse(_ arguments: [String], environment: [String: String]) throws -> Options {
        var result = Options()
        result.runtime = environment["SCREENPUNK_RUNTIME_DIRECTORY"]
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            switch word {
            case "--json": result.json = true
            case "--no-input": result.noInput = true
            case "--approved": result.approved = true
            case "--verbose": break
            case "--secret-stdin": result.secretStdin = true
            case "--help", "-h": result.help = true
            case "--version": result.version = true
            case "--runtime-directory", "--timeout", "--workspace", "--home", "--profile", "--host", "--port", "--expected-revision", "--file":
                index += 1
                guard index < arguments.count else { throw usage("Missing option value.") }
                if word == "--runtime-directory" { result.runtime = arguments[index] }
                else if word == "--workspace" { result.workspace = arguments[index] }
                else if word == "--home" { result.home = arguments[index] }
                else if word == "--profile" { result.profile = arguments[index] }
                else if word == "--host" { result.host = arguments[index] }
                else if word == "--port" {
                    guard let port = Int(arguments[index]), (1...65535).contains(port) else { throw usage("--port must be between 1 and 65535.") }
                    result.port = port
                }
                else if word == "--expected-revision" { result.expectedRevision = arguments[index] }
                else if word == "--file" { result.inputFile = arguments[index] }
                else {
                    guard let seconds = Double(arguments[index]), seconds.isFinite, seconds > 0, seconds <= 10 else {
                        throw usage("--timeout must be greater than zero and at most 10 seconds for broker IPC.")
                    }
                    result.timeout = seconds
                }
            default:
                if word.hasPrefix("--") && !["--foreground", "--refresh", "--client",
                                            "--source-version", "--revision", "--generation", "--out", "--to", "--external",
                                            "--catalog-entry", "--kit-version", "--inventory",
                                            "--include-external", "--allow-incomplete", "--scope", "--required",
                                            "--watch"].contains(word) {
                    throw usage("Unknown option. Use screenpunk help.")
                }
                result.words.append(word)
            }
            index += 1
        }
        for (label, value) in [("workspace", result.workspace), ("home", result.home)] {
            if let value, !WorkspacePath.isAbsolute(value) { throw usage("--\(label) requires an absolute path without dot traversal.") }
        }
        if let profile = result.profile, !WorkspaceValidation.id(profile) {
            throw usage("--profile requires a valid portable profile name.")
        }
        return result
    }

    static func usage(_ message: String) -> CommandFailure { .init("usage", message, 2) }

    func runtimeURL() throws -> URL {
        let runtime = runtime ?? InstallationPaths(home: FileManager.default.homeDirectoryForCurrentUser)
            .machineState.appendingPathComponent("Runtime").path
        guard WorkspacePath.isAbsolute(runtime) else { throw Options.usage("Runtime path must be absolute without dot traversal.") }
        // Resolve only the known macOS /tmp alias. Other symlink components are rejected by the broker.
        let components = runtime.split(separator: "/", omittingEmptySubsequences: false)
        guard components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Options.usage("Runtime path must use explicit nonempty components without dot traversal.")
        }
        let canonical = runtime == "/tmp" ? "/private/tmp" : runtime.hasPrefix("/tmp/") ? "/private" + runtime : runtime
        return URL(fileURLWithPath: canonical, isDirectory: true)
    }

    func homeURL() -> URL {
        URL(fileURLWithPath: home ?? InstallationPaths(home: FileManager.default.homeDirectoryForCurrentUser)
            .machineState.appendingPathComponent("Controller").path, isDirectory: true)
    }
}

enum WorkspacePath {
    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func canonical(_ path: String) -> String {
        path == "/tmp" ? "/private/tmp" : path.hasPrefix("/tmp/") ? "/private" + path : path
    }
}
