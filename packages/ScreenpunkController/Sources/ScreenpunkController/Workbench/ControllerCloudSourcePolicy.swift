import Foundation
#if os(macOS)
/// Deterministic backup policy. These members remain local across incoming source updates.
public enum ControllerCloudSourcePolicy {
    public static func excludes(_ path: String) -> Bool {
        if WorkspaceFiles.fixedSourceExcludes(path) { return true }
        let parts = path.split(separator:"/").map { WorkspaceValidation.portableKey(String($0)) }
        let directories: Set<String> = ["build","cache","caches","deriveddata","target","dependencies","deps","bower_components"]
        if parts.dropLast().contains(where: { directories.contains($0) }) { return true }
        guard let filename = parts.last else { return true }
        if ["credentials.json","credentials","secrets.json","secrets","tokens.json","token.json"].contains(filename) { return true }
        return [".pem",".key",".p12",".pfx",".keystore",".keychain",".keychain-db",".jks"].contains { filename.hasSuffix($0) }
    }
}
#endif
