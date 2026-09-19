import SwiftUI
import AppKit
import ScreenpunkCore
import ScreenpunkApple
import ScreenpunkController

struct MacWorkbenchView: View {
    @ObservedObject var model: MacWorkbenchModel
    @State private var windowIsActive = true
    @State private var connectionsSelected = false
    @State private var connectionSearch = ""
    @State private var agentProfile: AgentSetupProfile = .cursor
    @StateObject private var connectionsStore = ConnectionsStore()
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var screenPicker = false
    @State private var devicePresetPicker = false
    @State private var supportPicker = false
    @State private var confirmForget = false
    @State private var confirmDelete = false
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar.navigationSplitViewColumnWidth(min: 270, ideal: 290, max: 360)
        } detail: {
            detail
                .background(Color(nsColor: WorkbenchWindowColors.canvas(active: windowIsActive)))
                .toolbar { detailToolbar }
                .overlay(alignment: .bottom) {
                    if !connectionsSelected, let notice = model.notice {
                        HStack {
                            Text(notice).font(.callout)
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss")
                        }.padding(12).workbenchNotice().padding(20)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .workbenchWindowChrome()
        .background(ContinuousWindowCanvas(isActive: $windowIsActive))
        .sheet(item: $model.sheet) { item in
            switch item {
            case .manual: ManualDeviceSheet(model: model)
            case .editor: ScreenEditorSheet(model: model)
            case .agents: AgentConnectionSheet(profile: agentProfile)
            case .homeAssistant: HomeAssistantConnectionSheet(store: connectionsStore)
            case .rename: RenameDeviceSheet(model: model)
            case .renameScreen: RenameScreenSheet(model: model)
            case .screenIcon: ScreenIconSheet(model: model)
            case .deviceConnections:
                if let id = model.connectionsDeviceID { GenericConnectionsSheet(model: model, deviceID: id) }
            case .deviceSettings:
                if let editor = model.settingsEditor { MacDeviceSettingsSheet(editor: editor) { model.sheet = nil } }
            }
        }
        .alert("Screenpunk", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Forget \(model.title)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Device", role: .destructive) { model.forgetDevice() }
        } message: { Text("Its screen keeps running. To pair with a different Mac, hold two fingers on the device screen for five seconds to open the device menu, then choose Disconnect and confirm.") }
        .confirmationDialog("Delete this screen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Screen", role: .destructive) { model.deleteScreen() }
        } message: { Text("It will be removed from your library. Screens already running on devices keep running.") }
    }

    private var sidebar: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.section == "Devices" {
                        ForEach(model.nearby) { entry in
                            sidebarItem(id: entry.id, title: entry.title, subtitle: "Ready to pair", symbol: model.deviceSymbol(entry.title), rowID: "nearby:\(entry.id)") {
                                if model.selection != entry.id {
                                    Button { model.pair(entry) } label: { Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).frame(width: 24, height: 24) }
                                        .workbenchButton(prominent: true, circular: true).tint(Color(nsColor: .systemGreen))
                                        .accessibilityLabel("Pair \(entry.title)").disabled(model.busy)
                                }
                            }
                        }
                        sectionHeader("Devices", count: model.devices.count) {
                            circle("Refresh Devices", symbol: "arrow.clockwise") { model.refresh(probe: true) }
                            circle("Add Device", symbol: "plus") { model.sheet = .manual }
                        }.padding(.top, model.nearby.isEmpty ? 0 : 12)
                        ForEach(model.devices) { device in
                            sidebarItem(id: device.id, title: device.displayName ?? device.device.profile.name,
                                        subtitle: device.device.reachable ? "Connected" : "Offline",
                                        symbol: model.deviceSymbol(device.device.profile.name, landscape: device.device.profile.orientation == .landscape)) {
                                EmptyView()
                            }.contextMenu { deviceActions(device.id) }
                        }
                        if model.devices.isEmpty { Text("Your paired devices appear here.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8) }
                    } else {
                        sectionHeader("Screens", count: model.screens.count) {
                            circle("New Screen", symbol: "plus") { model.newScreen() }
                        }
                        ForEach(model.screens, id: \.dashboardId) { screen in
                            sidebarNavigationItem(screen.name, symbol: model.symbol(for: screen.dashboardId), selected: !connectionsSelected && model.selection == screen.dashboardId) {
                                connectionsSelected = false
                                if model.selection != screen.dashboardId { model.select(screen.dashboardId) }
                            }.id(screen.dashboardId)
                        }
                        if model.screens.isEmpty { Text("Save a screen, then use it on any device.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8) }
                    }
                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            }
            .focusable().focusEffectDisabled()
            .onKeyPress(.upArrow) { moveSidebarSelection(-1); return .handled }
            .onKeyPress(.downArrow) { moveSidebarSelection(1); return .handled }
            .onChange(of: model.selection) { _, id in
                if let id { proxy.scrollTo(model.section == "Devices" && model.nearby.contains(where: { $0.id == id }) ? "nearby:\(id)" : id) }
            }
        }
        .background(DesktopSidebarMaterial(isActive: windowIsActive).ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 20) {
            HStack(spacing: 4) {
                ForEach(["Devices", "Screens"], id: \.self) { section in
                    Button {
                        connectionsSelected = false
                        guard model.section != section else { return }
                        model.section = section
                        model.switchSection()
                    } label: {
                        Text(section).font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(model.section == section ? Color.primary.opacity(windowIsActive ? 0.22 : 0.12) : .clear, in: .capsule)
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(model.section == section ? .isSelected : [])
                }
            }.padding(4).workbenchSegmentSurface()
                .padding(.horizontal, 16).padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Divider()
                sidebarNavigationItem("Connections", symbol: "point.3.connected.trianglepath.dotted", selected: connectionsSelected) {
                    connectionsSelected = true
                }
            }.padding(16)
        }
    }

    private func sidebarNavigationItem(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular)).frame(width: 20)
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(selected && windowIsActive ? Color.white : windowIsActive ? Color.primary : Color.secondary)
            .background(selected ? (windowIsActive ? WorkbenchPalette.accent : Color.primary.opacity(0.12)) : .clear, in: .rect(cornerRadius: 12))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func moveSidebarSelection(_ offset: Int) {
        connectionsSelected = false
        let ids = model.section == "Devices" ? model.nearby.map(\.id) + model.devices.map(\.id) : model.screens.map(\.dashboardId)
        guard !ids.isEmpty else { return }
        let index = model.selection.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        model.select(ids[min(max(index + offset, 0), ids.count - 1)])
    }
    private func sidebarItem<Actions: View>(id: String, title: String, subtitle: String?, symbol: String, rowID: String? = nil, @ViewBuilder actions: () -> Actions) -> some View {
        let selected = !connectionsSelected && model.selection == id
        return HStack(spacing: 8) {
            Button {
                connectionsSelected = false
                if model.selection != id { model.select(id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol).font(.system(size: 24, weight: .regular)).frame(width: 32, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 14, weight: selected ? .semibold : .medium)).lineLimit(1).truncationMode(.tail)
                        if let subtitle { Text(subtitle).font(.system(size: 14)).foregroundStyle(selected && windowIsActive ? Color.white.opacity(0.85) : Color.secondary).lineLimit(1).truncationMode(.tail) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            actions()
        }
        .foregroundStyle(selected && windowIsActive ? Color.white : windowIsActive ? Color.primary : Color.secondary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? (windowIsActive ? WorkbenchPalette.accent : Color.primary.opacity(0.12)) : .clear, in: .rect(cornerRadius: 12))
        .id(rowID ?? id)
    }
    private func screenPickerRow(_ title: String, symbol: String, selected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 24, height: 24)
            Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "checkmark").opacity(selected ? 1 : 0).frame(width: 18)
        }.padding(8).contentShape(Rectangle())
    }

    private func sectionHeader<Actions: View>(_ label: String, count: Int, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 7) {
            Text(label.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(1.2)
            Text("\(count)").font(.caption.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: .rect(cornerRadius: 5))
            Spacer(minLength: 4)
            actions()
        }.foregroundStyle(.secondary).padding(.top, 5).padding(.bottom, 12)
    }
    private func circle(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16, weight: .regular)).frame(width: 24, height: 24) }
            .workbenchButton(circular: true).help(label).accessibilityLabel(label)
    }

    /// Both entry points use the same action builder and the clicked device ID.
    @ViewBuilder private func deviceActions(_ deviceID: String) -> some View {
        Button("Settings…", systemImage: "gearshape") { model.openDeviceSettings(deviceID) }
        Button("Connections…", systemImage: "network") { model.connectionsDeviceID = deviceID; model.sheet = .deviceConnections }
        Button("Rename Device…", systemImage: "pencil") {
            connectionsSelected = false
            model.select(deviceID)
            model.sheet = .rename
        }
        Divider()
        Button("Forget Device…", systemImage: "trash", role: .destructive) {
            connectionsSelected = false
            model.select(deviceID)
            confirmForget = true
        }
    }

    private var deviceOptions: some View {
        Menu {
            if let id = model.device?.id { deviceActions(id) }
        } label: {
            Image(systemName: "ellipsis").fontWeight(.medium).foregroundStyle(windowIsActive ? Color.primary : Color.secondary).frame(width: 24, height: 24)
        }
        .workbenchMenuStyle()
        .menuIndicator(.hidden)
        .frame(width: 36, height: 36)
        .workbenchMenuSurface()
        .help("Device Options").accessibilityLabel("Device Options")

    }

    private var screenOptions: some View {
        Menu {
            Button("Rename Screen…", systemImage: "pencil") { model.sheet = .renameScreen }
            Button("Change Icon…", systemImage: "square.grid.2x2") { model.sheet = .screenIcon }
            Button("Edit Code…", systemImage: "curlybraces") { model.editScreen() }
            Button("Duplicate Screen…", systemImage: "plus.square.on.square") { model.duplicateScreen() }
            Divider()
            Button("Delete Screen…", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: { Image(systemName: "ellipsis").fontWeight(.medium).foregroundStyle(windowIsActive ? Color.primary : Color.secondary).frame(width: 24, height: 24) }
            .workbenchMenuStyle().menuIndicator(.hidden).frame(width: 36, height: 36)
            .workbenchMenuSurface().help("Screen Options").accessibilityLabel("Screen Options")
    }

    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        if connectionsSelected {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search connections", text: $connectionSearch).textFieldStyle(.plain)
                        .accessibilityLabel("Search connections")
                }.padding(.horizontal, 12).frame(width: 340, height: 36)
                    .workbenchSegmentSurface()
            }.workbenchSeparateBackground()
        } else {
        if model.section == "Devices", model.device != nil {
            ToolbarItem(placement: .navigation) { deviceOptions }
                .workbenchSeparateBackground()
        } else if model.section == "Screens", model.selectedScreen != nil {
            ToolbarItem(placement: .navigation) { screenOptions }
                .workbenchSeparateBackground()
        }
        if model.section == "Devices", let deviceModel = model.device?.device.profile.model {
            ToolbarItem(placement: .navigation) {
                Text(deviceModel).font(.body.weight(.regular))
                    .foregroundStyle(windowIsActive ? Color.primary : Color.secondary).lineLimit(1)
            }.workbenchSeparateBackground()
        }
        if model.device != nil && model.section == "Devices" {
            ToolbarItem(placement: .principal) {
                Button { screenPicker.toggle() } label: {
                    HStack(spacing: 8) { Image(systemName: model.deviceScreens.multiple ? "rectangle.stack" : model.selectedScreen.map { model.symbol(for: $0) } ?? "rectangle"); Text(model.screenSelectorTitle).lineLimit(1); if model.hasUnappliedScreen { Text("Not Applied").font(.caption).foregroundStyle(.secondary) }; Image(systemName: "chevron.down").font(.caption.weight(.semibold)) }.frame(minHeight: 24)
                }
                .workbenchButton()
                .help(model.hasUnappliedScreen ? "Selected screen · Apply to send to device" : "Current screen")
                .popover(isPresented: $screenPicker, arrowEdge: .bottom) {
                    DeviceScreenPicker(model: model) { screenPicker = false }
                }
            }.workbenchSeparateBackground()
            ToolbarItemGroup(placement: .primaryAction) {
                orientationPicker
                Button { model.applyScreen() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.doc")
                        Text(model.applyLabel)
                    }.frame(minHeight: 24).foregroundStyle(.white)
                }
                .workbenchButton(prominent: true)
                .tint(WorkbenchPalette.accent)
                .controlSize(.large)
                .accessibilityLabel(model.applyLabel)
                .disabled(!model.canApply)
            }.workbenchSeparateBackground()
        } else if model.section == "Screens", model.selectedScreen != nil {
            ToolbarItem(placement: .principal) {
                Button { devicePresetPicker.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.screenPreviewProfile.symbol)
                        Text(model.screenPreviewProfile.name).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }.frame(minHeight: 24).frame(maxWidth: 220)
                }.workbenchButton().help("Choose preview device").accessibilityLabel("Preview device: " + model.screenPreviewProfile.name)
                    .popover(isPresented: $devicePresetPicker, arrowEdge: .bottom) {
                        DevicePresetPicker(selected: model.screenPreviewProfile) { profile in
                            model.screenPreviewProfile = profile
                            devicePresetPicker = false
                        }
                    }
            }.workbenchSeparateBackground()
            ToolbarItemGroup(placement: .primaryAction) {
                orientationPicker
                Button { supportPicker.toggle() } label: {
                    HStack(spacing: 8) {
                        Text(model.screenSupport == .both ? "Both orientations" : model.screenSupport == .portrait ? "Portrait only" : "Landscape only")
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }.frame(minHeight: 24)
                }.workbenchButton().help("Supported orientations").accessibilityLabel("Supported orientations").disabled(model.busy)
                    .popover(isPresented: $supportPicker, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Supports").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(8)
                            ForEach(ScreenOrientationSupport.allCases, id: \.self) { support in
                                Button {
                                    supportPicker = false
                                    model.setScreenSupport(support)
                                } label: {
                                    HStack {
                                        Text(support == .both ? "Both orientations" : support == .portrait ? "Portrait only" : "Landscape only")
                                        Spacer()
                                        if model.screenSupport == support { Image(systemName: "checkmark") }
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(8).frame(width: 210)
                    }
            }.workbenchSeparateBackground()
        }
        ToolbarItem(placement: .status) { if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") } }
    }
    }
    private var orientationPicker: some View {
        Picker("Orientation", selection: $model.orientation) {
            Image(systemName: "iphone.gen3").tag(DeviceOrientation.portrait).disabled(!model.supports(.portrait)).help("Portrait").accessibilityLabel("Portrait")
            Image(systemName: "iphone.gen3.landscape").tag(DeviceOrientation.landscape).disabled(!model.supports(.landscape)).help("Landscape").accessibilityLabel("Landscape")
        }.pickerStyle(.segmented).labelsHidden().controlSize(.extraLarge).frame(width: 72).disabled(model.busy)
            .modifier(GlassControlOutline())
    }

    @ViewBuilder private var detail: some View {
        if connectionsSelected {
            ConnectionsView(agents: model.agents, store: connectionsStore, openAgent: { profile in
                agentProfile = profile
                model.sheet = .agents
            }, openHomeAssistant: { model.sheet = .homeAssistant }, search: $connectionSearch)
        }
        else if model.pairing != nil { pairingState }
        else if model.detected != nil && model.section == "Devices" { pairingState }
        else if let store = model.preview {
            VStack(spacing: 0) {
                ScreenCanvas(store: store, size: model.previewSize, deviceFrame: model.section == "Devices", dashboardId: model.previewDashboardId, revision: model.previewRevision, usesHomeAssistant: model.previewUsesHomeAssistant).id(model.previewKey)
            }
        } else if model.device != nil {
            ContentUnavailableView {
                Label("Make This Device Useful Again", systemImage: "rectangle.on.rectangle")
            } description: { Text("Choose a saved screen above, or make something new.") } actions: {
                Button("New Screen", systemImage: "plus") { model.newScreen() }.workbenchButton()
            }
        } else if model.section == "Screens" {
            ContentUnavailableView {
                Label("A Home for Your Screens", systemImage: "sparkles")
            } description: { Text("Create a screen once. Use it on any paired device.") } actions: {
                HStack {
                    Button("New Screen", systemImage: "plus") { model.newScreen() }.workbenchButton(prominent: true)
                    Button("Import Screen…", systemImage: "square.and.arrow.down") { model.importScreen() }.workbenchButton()
                }
            }
        } else {
            ContentUnavailableView {
                Label("Give an Old Device a New Life", systemImage: "iphone.gen3")
            } description: { Text("Open Screenpunk on your iPhone or iPad.\nKeep both devices on the same Wi-Fi network, then select it in the sidebar.") } actions: {
                Button("Add by Address…", systemImage: "plus") { model.sheet = .manual }.workbenchButton()
            }
        }
    }
    private var pairingState: some View {
        VStack(spacing: 22) {
            Image(systemName: model.deviceSymbol(model.pairing?.deviceName ?? model.detected?.title ?? "iPhone")).font(.system(size: 72, weight: .ultraLight)).foregroundStyle(.secondary)
            if let pairing = model.pairing {
                Text("Match the Code").font(.largeTitle.weight(.semibold))
                Text(pairing.code).font(.system(size: 42, weight: .medium, design: .monospaced)).tracking(8)
                Text("Check that this code matches the one on your device.\nTap Confirm on the device to finish pairing.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { model.cancelPairing() }.workbenchButton()
                    ProgressView().controlSize(.small)
                    Text("Waiting for confirmation on your device…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Pair \(model.detected?.title ?? "Your Device")").font(.largeTitle.weight(.semibold))
                Text("Keep Screenpunk open on your device and stay on the same Wi-Fi network.\nStart pairing, compare the code on both screens, then confirm on your device.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
                Button { if let entry = model.detected { model.pair(entry) } } label: { Label("Start Pairing", systemImage: "plus").fontWeight(.semibold) }
                    .workbenchButton(prominent: true).tint(Color(nsColor: .systemGreen)).controlSize(.large).disabled(model.busy)
            }
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScreenCanvas: View {
    let store: PackageAssetStore
    let size: CGSize
    var deviceFrame = true
    var dashboardId = ""
    var revision = ""
    var usesHomeAssistant = false
    @State private var homeAssistant: HomeAssistantDeviceRuntime?
    var body: some View {
        GeometryReader { geometry in
            let scale = max(0.1, min((geometry.size.width - 72) / size.width, (geometry.size.height - 64) / size.height))
            ZStack {
                Canvas { context, canvas in
                    for x in stride(from: 12.0, to: canvas.width, by: 24) {
                        for y in stride(from: 12.0, to: canvas.height, by: 24) {
                            context.fill(Path(ellipseIn: CGRect(x: x,y: y,width: 1.5,height: 1.5)), with: .color(.primary.opacity(0.16)))
                        }
                    }
                }
                DashboardWebView(store: store, homeAssistant: homeAssistant, revision: revision, onUnlinkHold: {}).id(homeAssistant == nil ? "loading" : "live")
                    .frame(width: size.width, height: size.height)
                    .clipShape(.rect(cornerRadius: deviceFrame ? 28 : 0))
                    .overlay { if deviceFrame { RoundedRectangle(cornerRadius: 28).stroke(.primary.opacity(0.2), lineWidth: 5) } }
                    .scaleEffect(scale)
                    .frame(width: size.width * scale, height: size.height * scale)
                    .shadow(color: .black.opacity(0.16), radius: 20, y: 8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            guard usesHomeAssistant else { return }
            let id = dashboardId, rev = revision
            homeAssistant = try? await Task.detached { try MacHomeAssistantConnection.previewRuntime(dashboardId: id, revision: rev) }.value
        }
        .onDisappear { if let homeAssistant { Task { await homeAssistant.cancelPending() } } }
    }
}

struct ManualDeviceSheet: View {
    @ObservedObject var model: MacWorkbenchModel
    @State private var host = ""
    @State private var port = "7843"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Device").font(.title2.weight(.semibold))
            Text("Enter the address and port shown on your device’s Ready to pair screen.").foregroundStyle(.secondary)
            Form { TextField("Host or IP", text: $host); TextField("Port", text: $port) }
            HStack { Spacer(); Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction); Button("Add Device") { model.addManual(host: host, port: port) }.keyboardShortcut(.defaultAction).disabled(WorkbenchSidebar.normalizeHost(host) == nil || WorkbenchSidebar.parsePort(port) == nil) }
        }.padding(28).frame(width: 420)
    }
}

struct ScreenEditorSheet: View {
    @ObservedObject var model: MacWorkbenchModel
    @State private var file = "index.html"
    @State private var showingIconPicker = false
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(model.draft?.dashboardId == nil ? "New Screen" : "Edit Code").font(.title2.weight(.semibold)); Spacer()
            }
            HStack(spacing: 12) {
                Button { showingIconPicker = true } label: {
                    Image(systemName: model.draft?.symbol ?? "star")
                        .font(.system(size: 18, weight: .regular)).frame(width: 24, height: 24)
                }.workbenchButton(circular: true).accessibilityLabel("Change Icon").help("Change Icon")
                TextField("Screen name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0; model.persistDraft() })).textFieldStyle(.roundedBorder)
            }
            HStack {
                Picker("File", selection: $file) {
                    ForEach((model.draft?.files.keys.sorted() ?? []).filter { ["html","css","js","json","txt","svg"].contains(URL(fileURLWithPath: $0).pathExtension) }, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 300)
                Spacer(); Text("Local HTML, CSS and JavaScript").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: Binding(get: { String(data: model.draft?.files[file] ?? Data(), encoding: .utf8) ?? "" }, set: { model.draft?.files[file] = Data($0.utf8); model.persistDraft() }))
                .font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).padding(12)
                .background(.background, in: .rect(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            HStack {
                Text(model.section == "Screens" ? "Save your changes to update this screen’s preview." : "Save to preview. Apply sends the saved screen to the selected device.").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Button("Cancel") { model.discardDraft() }
                    .keyboardShortcut(.cancelAction).workbenchButton()
                Button("Save") { model.saveDraft() }
                    .keyboardShortcut(.defaultAction).workbenchButton(prominent: true)
                    .disabled(model.draft?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
        }.disabled(model.busy)
            .padding(24).frame(minWidth: 690, idealWidth: 820, minHeight: 560, idealHeight: 670)
            .interactiveDismissDisabled()
            .onAppear { model.persistDraft() }
            .sheet(isPresented: $showingIconPicker) {
                SymbolPickerSheet(initialSymbol: model.draft?.symbol ?? "star", onSave: { symbol in
                    model.draft?.symbol = symbol
                    model.persistDraft()
                    showingIconPicker = false
                }, onCancel: { showingIconPicker = false })
            }
    }
}

struct RenameDeviceSheet: View {
    @ObservedObject var model: MacWorkbenchModel
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename Device").font(.title2.weight(.semibold))
            Text("Choose a name that helps you recognize this device.").foregroundStyle(.secondary)
            TextField("Device name", text: $name).textFieldStyle(.roundedBorder).onSubmit { model.renameDevice(name) }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { model.renameDevice(name) }.keyboardShortcut(.defaultAction)
                    .disabled(DeviceDisplayName.sanitize(name) == nil || model.busy)
            }
        }.padding(28).frame(width: 420).onAppear { name = model.title }
    }
}
