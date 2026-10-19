import Foundation
import Darwin
import ScreenpunkController

enum WorkbenchScreenMutationCLI {
    static let verbs: Set<String> = ["source-rename", "package-rename", "package-duplicate",
                                     "package-orientation", "icon-set", "archive", "react-source-associate"]

    static func run(words: [String], inputFile: String?, client: WorkbenchBrokerClient,
                    presentation: Presentation) throws {
        guard words.count == 2, let path = inputFile, WorkspacePath.isAbsolute(path) else {
            throw Options.usage("screen \(words.dropFirst().first ?? "mutation") requires --file ABSOLUTE_JSON (at most 4 KiB).")
        }
        let fields = try readClosedRequest(path)
        func encoded<T: Encodable>(_ applied: T) throws -> Data {
            do { return try JSONEncoder().encode(applied) }
            catch {
                throw CommandFailure("applied_display_failed",
                    "The screen mutation was acknowledged but its receipt could not be displayed.", 6,
                    nextActions: ["Inspect the selected catalog and package history before retrying."],
                    details: ["method": words[1]])
            }
        }
        let receipt: Data
        do {
            switch words[1] {
            case "source-rename": receipt = try encoded(client.renameScreenSource(params: fields))
            case "package-rename": receipt = try encoded(client.renameScreenPackage(params: fields))
            case "package-duplicate": receipt = try encoded(client.duplicateScreenPackage(params: fields))
            case "package-orientation": receipt = try encoded(client.setScreenPackageOrientation(params: fields))
            case "icon-set": receipt = try encoded(client.setScreenIcon(params: fields))
            case "archive": receipt = try encoded(client.archiveScreen(params: fields))
            case "react-source-associate": receipt = try encoded(client.associateReactSource(params: fields))
            default: throw Options.usage("Unknown screen mutation.")
            }
        } catch let error as WorkbenchIPCError where
            [.disconnected, .timedOut, .unavailable, .publicationOutcomeUnknown].contains(error.code) {
            throw CommandFailure("outcome_unknown",
                "The screen mutation may have been applied; inspect the selected catalog and package history before retrying.", 7,
                nextActions: ["Run screen history and inspect the affected source or package before another mutation."],
                details: ["method": words[1]])
        }
        do {
            let object = try JSONSerialization.jsonObject(with: receipt) as? [String: Any] ?? [:]
            try presentation.checkedSuccess(object, human: "Screen mutation applied: \(words[1]).")
        } catch {
            throw CommandFailure("applied_display_failed",
                "The screen mutation was acknowledged but its receipt could not be displayed.", 6,
                nextActions: ["Inspect the selected catalog and package history before retrying."],
                details: ["method": words[1]])
        }
    }

    private static func readClosedRequest(_ path: String) throws -> [String: Any] {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Options.usage("Screen mutation input must be a readable regular JSON file.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              (1...4_096).contains(info.st_size) else {
            throw Options.usage("Screen mutation input must be a regular JSON file of at most 4 KiB.")
        }
        var bytes = [UInt8](repeating: 0, count: 4_097)
        var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let readCount = bytes.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress!.advanced(by: count), remaining)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw Options.usage("Screen mutation input could not be read.")
            }
            count += readCount
        }
        guard (1...4_096).contains(count) else {
            throw Options.usage("Screen mutation input exceeds 4 KiB.")
        }
        do {
            guard let fields = try JSONSerialization.jsonObject(with: Data(bytes.prefix(count)))
                as? [String: Any] else {
                throw Options.usage("Screen mutation file must be one JSON object.")
            }
            return fields
        } catch {
            throw Options.usage("Screen mutation file must be one valid JSON object.")
        }
    }
}
