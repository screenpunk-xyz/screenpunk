import Foundation
import XCTest

/// A missing shared fixture is a failure, never a skip: Swift and TypeScript must read the same files.
struct FixtureMissing: Error, CustomStringConvertible {
    var path: String
    var searchedFrom: String

    var description: String {
        "fixture \(path) not found walking up from \(searchedFrom)"
    }
}

enum RepoFixtures {
    static func url(_ relativePath: String, file: String = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<12 {
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }
        throw FixtureMissing(path: relativePath, searchedFrom: file)
    }

    static func data(_ relativePath: String, file: String = #filePath) throws -> Data {
        try Data(contentsOf: url(relativePath, file: file))
    }

    static func decode<T: Decodable>(_ type: T.Type, from relativePath: String, file: String = #filePath) throws -> T {
        try JSONDecoder().decode(type, from: data(relativePath, file: file))
    }
}
