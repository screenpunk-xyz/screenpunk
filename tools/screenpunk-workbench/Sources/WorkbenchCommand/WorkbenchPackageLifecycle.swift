import Foundation
import Darwin
import ScreenpunkController
import ScreenpunkDistribution

enum WorkbenchPackageLifecycle {
    static func checked<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as DistributionError {
            let failure = WorkbenchLifecycleCLI.failure(error)
            throw CommandFailure(failure.code, failure.message, failure.exitStatus,
                nextActions: ["Inspect screenpunk service status, screenpunk service logs, and launchctl print gui/\(geteuid())/com.screenpunk.workbench before retrying.",
                              "If an interrupted Brew operation left the package fenced or incomplete, let active jobs finish, quit Screenpunk GUI consumers, and retry that operation or run brew reinstall --cask screenpunk-cli."],
                details: ["lifecycleError": String(describing: error)])
        }
    }

    static func context(root: URL, options: Options) throws -> PackageManagedInstallation {
        let paths = InstallationPaths(home: FileManager.default.homeDirectoryForCurrentUser)
        try paths.validateServiceDirectories(controllerHome: options.homeURL(), runtimeDirectory: options.runtimeURL())
        let manifest = try WorkbenchProductionTrust.verifyPackage(root)
        let launchctl = BoundedUserLaunchctl(paths: paths)
        let home = paths.machineState.appendingPathComponent("Controller")
        let runtime = try WorkbenchBrokerEnvironment(runtimeDirectory: paths.machineState.appendingPathComponent("Runtime"))
        let observation = WorkbenchBrokerLifecycleObservation(paths: paths, broker: runtime,
            controllerHome: home, identity: LaunchdProcessIdentityProbe(launchctl: launchctl,
                paths: paths, packageRoot: root), packageVersion: manifest.version)
        let service = LaunchdUserAdapter(observation: observation, paths: paths,
            controllerHome: home, runtimeDirectory: runtime.runtimeDirectory,
            logDirectory: paths.machineState.appendingPathComponent("Logs"), launchctl: launchctl,
            serviceExecutable: root.appendingPathComponent("libexec/screenpunk-service"))
        return PackageManagedInstallation(root: root, paths: paths, service: service,
            releaseTrust: ScreenpunkProductionReleaseTrust(), prepare: { root, manifest in
                try WorkbenchLegacyOwnerGate.assertNoKnownWriter()
                try WorkbenchProductionTrust.prepareVerifiedPayload(root: root, manifest: manifest, paths: paths)
            }, assertUnmanagedServiceAbsent: {
                try WorkbenchLegacyOwnerGate.assertNoKnownWriter()
                if FileManager.default.fileExists(atPath: home.path) {
                    return try WorkbenchServiceOwnerLock(home: home)
                }
                return nil
            }, assertStoppedRemovalSafe: {
                do { try WorkbenchGUIAbsenceProbe.production().assertAbsent() }
                catch { throw WorkbenchPackageRemovalRefusal.guiEvidenceUnavailable }
            }, commit: HomebrewCommitEvidence(root: root, version: manifest.version,
                metadata: URL(fileURLWithPath: "/opt/homebrew/Caskroom/screenpunk-cli/.metadata"),
                bin: URL(fileURLWithPath: "/opt/homebrew/bin")))
    }

    static func failure(_ error: WorkbenchPackageRemovalRefusal) -> CommandFailure {
        switch error {
        case .busy:
            return CommandFailure("homebrew_service_busy",
                "Screenpunk is busy. Package removal was refused without interrupting jobs.", 8,
                nextActions: ["Let active jobs finish and close Screenpunk GUI consumers, then retry the Brew operation.",
                              "Use screenpunk service status to inspect the service before retrying."])
        case .guiActive:
            return CommandFailure("homebrew_gui_active",
                "A Screenpunk GUI consumer is using the service. Package removal was refused.", 8,
                nextActions: ["Quit the Screenpunk GUI, then retry the Brew operation."])
        case .guiEvidenceUnavailable:
            return CommandFailure("homebrew_gui_absence_unverified",
                "Screenpunk could not verify that all GUI consumers are absent. Package removal was refused.", 8,
                nextActions: ["Quit Screenpunk GUI processes and retry when the process inventory is stable.",
                              "The service and user data are retained; do not bypass the removal guard."])
        }
    }

    static func failure(_ error: PackageActivationFailure) -> CommandFailure {
        func code(_ error: any Error) -> String {
            if let value = error as? DistributionError { return String(describing: value) }
            if let value = error as? WorkbenchIPCError { return value.code.rawValue }
            return "unavailable"
        }
        return CommandFailure(error.cleanup == nil ? "service_activation_failed" : "service_activation_recovery_required",
            "The Homebrew service could not start. Its package and user data are retained.", 9,
            nextActions: ["Inspect screenpunk service logs and launchctl print gui/\(geteuid())/com.screenpunk.workbench before retrying screenpunk service start."],
            details: ["activationError": code(error.activation),
                      "cleanupError": error.cleanup.map(code) ?? "none"])
    }

    static func failure(_ error: PackagePreparationFailure) -> CommandFailure {
        let reason: String
        if let cause = error.underlying as? DistributionError { reason = String(describing: cause) }
        else if let cause = error.underlying as? WorkbenchIPCError { reason = cause.code.rawValue }
        else { reason = WorkbenchInstalledReleaseTrust.preparationFailureReason(error.underlying) }
        let missingJournal = reason == "catalogStateMissing"
        return CommandFailure("offline_kit_preparation_failed",
            missingJournal
                ? "The saved catalog checkpoint has no matching catalog journal. The service was not activated."
                : "The verified offline kit could not be prepared. The service was not activated.", 9,
            nextActions: missingJournal
                ? ["Preserve the release-catalog Keychain checkpoint and restore its exact matching catalog journal."]
                : ["Inspect the offline kit preparation reason before retrying service startup."],
            details: ["preparationError": reason, "phase": "before_service_activation"])
    }
}
