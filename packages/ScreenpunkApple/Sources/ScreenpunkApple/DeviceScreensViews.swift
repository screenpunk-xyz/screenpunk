#if canImport(SwiftUI)
import SwiftUI

public struct DeviceScreensItem: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let thumbnail: Image?
    public init(id: String, title: String, subtitle: String, thumbnail: Image? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.thumbnail = thumbnail
    }
}

public enum DeviceScreensCatalogState: Equatable {
    case unavailable(message: String)
    case loading
    case loaded
    case failed(message: String)
}

/// The containing navigation stack owns destinations; this list emits native links to those values.
public struct DeviceScreensView<Destination: Hashable>: View {
    private let installed: [DeviceScreensItem]
    private let available: [DeviceScreensItem]
    private let catalog: DeviceScreensCatalogState
    private let destination: (DeviceScreensItem) -> Destination
    private let open: (String) -> Void
    private let remove: (String) -> Void
    private let removeAll: () -> Void
    private let retryCatalog: () -> Void
    public init(installed: [DeviceScreensItem], available: [DeviceScreensItem], catalog: DeviceScreensCatalogState,
                destination: @escaping (DeviceScreensItem) -> Destination, open: @escaping (String) -> Void,
                remove: @escaping (String) -> Void, removeAll: @escaping () -> Void,
                retryCatalog: @escaping () -> Void) {
        self.installed = installed; self.available = available; self.catalog = catalog
        self.destination = destination; self.open = open; self.remove = remove
        self.removeAll = removeAll; self.retryCatalog = retryCatalog
    }
    public var body: some View {
        List {
            Section {
                if installed.isEmpty { Text("No screens on this device").foregroundStyle(.secondary) }
                ForEach(installed) { item in
                    HStack(spacing: 8) {
                        Button { open(item.id) } label: { DeviceScreensRow(item: item) }.buttonStyle(.plain)
                        Button(role: .destructive) { remove(item.id) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red).font(.title3).frame(width: 44, height: 44)
                        }.buttonStyle(.borderless).accessibilityLabel("Remove \(item.title)")
                    }
                }
            } header: { Text("On this device") } footer: {
                Text("Screens can be removed even when this device is disconnected.")
            }
            if !installed.isEmpty {
                Section { Button("Remove all screens", role: .destructive, action: removeAll) }
            }
            Section("Available to add") {
                switch catalog {
                case .unavailable(let message): Text(message).foregroundStyle(.secondary)
                case .loading: ProgressView("Loading screens…")
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                    Button("Try again", action: retryCatalog)
                case .loaded:
                    if available.isEmpty { Text("No screens available yet").foregroundStyle(.secondary) }
                    ForEach(available) { item in
                        NavigationLink(value: destination(item)) { DeviceScreensRow(item: item) }
                    }
                }
            }
        }.navigationTitle("Your screens")
    }
}

public enum DeviceScreensInstallationState: Equatable {
    case ready
    case installing(progress: Double?)
    case failed(message: String)
    case installed
    case unavailable(message: String)
}

public struct DeviceScreensDetailView: View {
    private let item: DeviceScreensItem
    private let description: String
    private let state: DeviceScreensInstallationState
    private let install: () -> Void
    private let retry: () -> Void
    private let open: () -> Void
    public init(item: DeviceScreensItem, description: String, state: DeviceScreensInstallationState,
                install: @escaping () -> Void, retry: @escaping () -> Void, open: @escaping () -> Void) {
        self.item = item; self.description = description; self.state = state
        self.install = install; self.retry = retry; self.open = open
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DeviceScreensThumbnail(image: item.thumbnail).frame(height: 220)
                Text(item.title).font(.largeTitle.bold())
                Text(description).foregroundStyle(.secondary)
                switch state {
                case .ready:
                    Button("Add to this device", action: install).buttonStyle(.borderedProminent)
                case .installing(let progress):
                    if let progress, progress.isFinite {
                        ProgressView("Adding screen…", value: min(1, max(0, progress)), total: 1)
                    } else { ProgressView("Adding screen…") }
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                    Button("Try again", action: retry).buttonStyle(.borderedProminent)
                case .installed:
                    Label("On this device", systemImage: "checkmark.circle")
                    Button("Open screen", action: open).buttonStyle(.borderedProminent)
                case .unavailable(let message): Text(message).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 640, alignment: .leading).padding(24).frame(maxWidth: .infinity)
        }.navigationTitle(item.title)
    }
}

private struct DeviceScreensRow: View {
    let item: DeviceScreensItem
    var body: some View {
        HStack(spacing: 16) {
            DeviceScreensThumbnail(image: item.thumbnail).frame(width: 88, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}

private struct DeviceScreensThumbnail: View {
    let image: Image?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
            if let image { image.resizable().scaledToFit() }
            else { Image(systemName: "rectangle").font(.largeTitle).foregroundStyle(.secondary) }
        }.clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}
#endif
