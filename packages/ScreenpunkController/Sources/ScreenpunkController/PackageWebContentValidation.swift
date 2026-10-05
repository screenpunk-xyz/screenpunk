import Foundation
import ScreenpunkCore

enum PackageWebContentValidation {
    static func requireCompatible(_ files: [String: Data]) throws {
        let issues = PackageWebContentDiagnostics.inspect(files: files)
        guard issues.isEmpty else {
            throw ControllerError.validationFailed(detail: "Package HTML conflicts with the native host CSP. " +
                issues.map(\.message).joined(separator: "\n") +
                "\nUse get_help(topic: authoring). Validation is static authoring guidance; preview and inspect the exact revision before approval.")
        }
    }
}
