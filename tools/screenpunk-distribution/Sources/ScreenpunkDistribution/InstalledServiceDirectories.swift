import Foundation

extension InstallationPaths {
    /// Directory URL equality includes a trailing slash that can depend on
    /// whether the destination already exists. Compare the validated path
    /// spelling instead; this does not authorize a different or symlinked path.
    public func validateServiceDirectories(controllerHome: URL, runtimeDirectory: URL) throws {
        let expectedHome = machineState.appendingPathComponent("Controller").standardizedFileURL.path
        let expectedRuntime = machineState.appendingPathComponent("Runtime").standardizedFileURL.path
        guard controllerHome.isFileURL, runtimeDirectory.isFileURL,
              controllerHome.standardizedFileURL.path == expectedHome,
              runtimeDirectory.standardizedFileURL.path == expectedRuntime else {
            throw DistributionError.untrustedRelease
        }
    }
}
