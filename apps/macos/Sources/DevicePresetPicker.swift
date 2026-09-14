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

/// The list scrolls independently of the selection mode and creation actions.
struct DeviceScreenPicker: View {
    @ObservedObject var model: MacWorkbenchModel
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool
    private var results: [DashboardSummary] {
        model.screens.filter { DeviceScreenSelection.matches(name: $0.name, query: query) }
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a screen", text: $query).textFieldStyle(.plain)
                    .focused($searchFocused).accessibilityLabel("Find a screen")
                    .onSubmit { if let id = highlighted ?? results.first?.dashboardId { choose(id) } }
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Toggle("Multiple Screens", isOn: Binding(get: { model.deviceScreens.multiple }, set: { model.setMultipleScreens($0) }))
                .toggleStyle(.switch).controlSize(.small).padding(.horizontal, 4)
            if results.isEmpty {
                ContentUnavailableView.search(text: query).frame(height: 240)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results, id: \.dashboardId) { screen in
                                Button { choose(screen.dashboardId) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: model.symbol(for: screen.dashboardId)).font(.system(size: 20)).frame(width: 28)
                                        Text(screen.name).lineLimit(1).truncationMode(.tail)
                                        Spacer(minLength: 4)
                                        Image(systemName: model.deviceScreens.multiple
                                              ? (model.deviceScreens.ids.contains(screen.dashboardId) ? "checkmark.square.fill" : "square")
                                              : "checkmark")
                                            .foregroundStyle(WorkbenchPalette.accent)
                                            .opacity(model.deviceScreens.multiple || model.deviceScreens.ids.contains(screen.dashboardId) ? 1 : 0)
                                            .frame(width: 20)
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(highlighted == screen.dashboardId ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(screen.dashboardId)
                                    .disabled(model.deviceScreens.multiple && model.deviceScreens.ids.count >= DeviceScreenSelection.limit && !model.deviceScreens.ids.contains(screen.dashboardId))
                                    .accessibilityLabel(screen.name)
                                    .accessibilityValue(model.deviceScreens.ids.contains(screen.dashboardId) ? "Selected" : "Not selected")
                            }
                        }
                    }.frame(height: 320)
                        .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                        .onAppear { if let id = model.selectedScreen { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            if model.deviceScreens.multiple {
                VStack(spacing: 3) {
                    Text("\(model.deviceScreens.ids.count) of 12 selected")
                    Text("Two-finger swipe on your device to switch")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(spacing: 2) {
                Button { dismiss(); model.duplicateScreen() } label: { footerRow("Duplicate Screen…", symbol: "plus.square.on.square") }
                    .disabled(!model.canDuplicate)
                Button { dismiss(); model.newScreen() } label: { footerRow("New Screen…", symbol: "plus") }
            }.buttonStyle(.plain)
        }.padding(12).frame(width: 360).disabled(model.busy)
            .onAppear { highlighted = model.selectedScreen; searchFocused = true }
            .onChange(of: query) { _, _ in highlighted = results.first?.dashboardId }
    }
    private func footerRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 28)
            Text(title)
            Spacer()
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func choose(_ id: String) {
        guard results.contains(where: { $0.dashboardId == id }) else { return }
        model.chooseScreen(id)
        if !model.deviceScreens.multiple { dismiss() }
    }
    private func moveHighlight(_ step: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.dashboardId == highlighted } ?? (step > 0 ? -1 : results.count)
        highlighted = results[min(max(index + step, 0), results.count - 1)].dashboardId
    }
}
