import SwiftUI
import ScreenpunkController
import ScreenpunkCore

struct DevicePresetPicker: View {
    let selected: ScreenPreviewProfile
    let choose: (ScreenPreviewProfile) -> Void
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool
    private var results: [ScreenPreviewProfile] { ScreenPreviewProfile.matching(query) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a device", text: $query).textFieldStyle(.plain)
                    .focused($searchFocused).accessibilityLabel("Find preview device")
                    .onSubmit { if let profile = results.first(where: { $0.id == highlighted }) ?? results.first { choose(profile) } }
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            if results.isEmpty {
                ContentUnavailableView.search(text: query).frame(height: 220)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results) { profile in
                                DevicePresetRow(profile: profile, selected: profile.id == selected.id,
                                    highlighted: profile.id == highlighted) { choose(profile) }.id(profile.id)
                            }
                        }
                    }.frame(height: 360)
                    .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
                }
            }
            Text(results.count == 1 ? "1 device" : "\(results.count) devices").font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(width: 360)
            .onAppear { highlighted = selected.id; searchFocused = true }
            .onChange(of: query) { _, _ in highlighted = results.first?.id }
    }
    private func moveHighlight(_ direction: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == highlighted } ?? (direction > 0 ? -1 : results.count)
        highlighted = results[min(max(index + direction, 0), results.count - 1)].id
    }
}

struct RenameScreenSheet: View {
    @ObservedObject var model: MacWorkbenchModel
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename Screen").font(.title2.weight(.semibold))
            TextField("Screen name", text: $name).textFieldStyle(.roundedBorder).onSubmit { model.renameScreen(name) }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { model.renameScreen(name) }.keyboardShortcut(.defaultAction)
                    .disabled(DeviceDisplayName.sanitize(name) == nil || model.busy)
            }
        }.padding(28).frame(width: 420).onAppear { name = model.title }
    }
}

private struct DevicePresetRow: View {
    let profile: ScreenPreviewProfile
    let selected: Bool
    let highlighted: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: profile.symbol).font(.system(size: 20)).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).lineLimit(1)
                    Text(profile.brand + " · " + profile.dimensions).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").foregroundStyle(WorkbenchPalette.accent) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(highlighted ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(profile.name + ", " + profile.brand + ", " + profile.dimensions)
    }
}
