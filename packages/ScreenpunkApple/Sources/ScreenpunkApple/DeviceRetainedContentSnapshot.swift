import Foundation
import ScreenpunkCore

/// Read-only committed content. Contains no management or connector services.
public struct DeviceRetainedContentSnapshot {
    public struct Screen: Identifiable {
        public let id: String
        public let revision: String
        public let name: String
        public let package: PackageAssetStore
    }
    public let screens: [Screen]
    public let selectedID: String?
    public let settings: DeviceSettings
    public static let empty = Self(screens: [], selectedID: nil, settings: .init())

    public static func load(store: DeviceStateStore) -> Self {
        guard let state = store.load() else { return .empty }
        let candidates: [(String, String, String, String)]
        if let set = state.screenSet {
            candidates = set.screens.map { ($0.revision.dashboardId, $0.revision.revision, $0.name, $0.packageDirectory) }
        } else if let revision = state.activeStoredRevision, state.activeRevision == revision.revision {
            candidates = [(revision.dashboardId, revision.revision, "Screen", "package")]
        } else { return .empty }
        var screens: [Screen] = [], seen = Set<String>()
        for (id, revision, name, directory) in candidates {
            guard seen.insert(id).inserted,
                  directory == "package" || (directory.hasPrefix("package.staging-") && !directory.contains("/") && !directory.contains("..")),
                  let files = try? store.loadPackageFiles(directory: directory), !files.isEmpty else { continue }
            var assets: [String: PackageAsset] = [:]
            var valid = true
            for file in files {
                guard let path = try? PackageAssetStore.hostRelativePath(file.path), assets[path] == nil else { valid = false; break }
                assets[path] = .init(path: path, data: file.data, mime: PackageAssetStore.mime(for: path))
            }
            guard valid, assets["index.html"] != nil else { continue }
            if let data = assets["manifest.json"]?.data {
                guard let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: data),
                      manifest.dashboardId == id, manifest.revision == revision,
                      (try? PackageValidator.validate(manifest)) != nil else { continue }
                do { if let behavior = manifest.deviceBehavior { try behavior.validate() } } catch { continue }
            }
            screens.append(.init(id: id, revision: revision, name: name, package: .init(assets: assets)))
        }
        let selected = state.screenSet?.selectedDashboardId
        return .init(screens: screens, selectedID: screens.contains { $0.id == selected } ? selected : screens.first?.id,
                     settings: state.settings?.value ?? .init())
    }
}
