import SwiftUI
import AppKit

enum MacGUIRuntime {
    static let testBundleID = "xyz.screenpunk.macos.gui-test"
    static var isTestApp: Bool { Bundle.main.bundleIdentifier == testBundleID }

    static var isolatedTestPaths: (home: URL, runtime: URL)? {
        guard isTestApp,
              ProcessInfo.processInfo.environment["SCREENPUNK_GUI_TEST_ISOLATED"] == "1",
              let homePath = ProcessInfo.processInfo.environment["SCREENPUNK_CONTROLLER_HOME"],
              let runtimePath = ProcessInfo.processInfo.environment["SCREENPUNK_RUNTIME_DIRECTORY"],
              homePath.hasPrefix("/private/tmp/screenpunk-gui-test-"),
              runtimePath.hasPrefix("/private/tmp/screenpunk-gui-test-"),
              homePath != runtimePath else { return nil }
        let home = URL(fileURLWithPath: homePath, isDirectory: true).resolvingSymlinksInPath()
        let runtime = URL(fileURLWithPath: runtimePath, isDirectory: true).resolvingSymlinksInPath()
        guard home.path.hasPrefix("/private/tmp/screenpunk-gui-test-"),
              runtime.path.hasPrefix("/private/tmp/screenpunk-gui-test-"),
              home.path != runtime.path else { return nil }
        return (home, runtime)
    }

    static var runtimeDirectory: URL {
        if let isolatedTestPaths { return isolatedTestPaths.runtime }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("xyz.screenpunk.workbench", isDirectory: true)
    }

    static var guiStateDirectory: URL {
        if let isolatedTestPaths {
            return isolatedTestPaths.runtime.appendingPathComponent("gui", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("xyz.screenpunk.gui", isDirectory: true)
    }
}

@main
struct ScreenpunkApp: App {
    @StateObject private var model = MacWorkbenchModel()
    @StateObject private var brokerModel = BrokerWorkbench()
    private let brokerPreview = ProcessInfo.processInfo.environment["SCREENPUNK_BROKER_GUI_PREVIEW"] == "1"
    var body: some Scene {
        WindowGroup {
            Group {
                if MacGUIRuntime.isTestApp && MacGUIRuntime.isolatedTestPaths == nil {
                    ContentUnavailableView("Isolated Test Data Required", systemImage: "externaldrive.badge.exclamationmark",
                        description: Text("This test app opens only with SCREENPUNK_GUI_TEST_ISOLATED=1 and separate SCREENPUNK_CONTROLLER_HOME and SCREENPUNK_RUNTIME_DIRECTORY paths under /private/tmp/screenpunk-gui-test-*."))
                } else if MacGUIRuntime.isTestApp {
                    TabView {
                        BrokerWorkbenchView(model: brokerModel)
                            .tabItem { Label("Workspace", systemImage: "square.grid.2x2") }
                        Group {
                            if model.brokerMode {
                                MacWorkbenchView(model: model)
                            } else {
                                ContentUnavailableView {
                                    Label("Isolated Service Required", systemImage: "network")
                                } description: {
                                    Text(model.controllerBlockedReason ?? "Connecting to the isolated Screenpunk service…")
                                } actions: {
                                    Button("Reconnect") { model.startBrokerOnly() }
                                }
                                .task { model.startBrokerOnly() }
                            }
                        }
                        .tabItem { Label("Device Preview & Apply", systemImage: "iphone.and.arrow.forward") }
                    }
                } else if brokerPreview {
                    BrokerWorkbenchView(model: brokerModel)
                } else if let reason = model.controllerBlockedReason, !model.brokerMode {
                    VStack(spacing: 16) {
                        ContentUnavailableView("Controller in use", systemImage: "network",
                            description: Text(reason))
                        if model.compatibleBrokerAvailable {
                            Text("A compatible service answered for this controller home. The existing workbench can show its selected packages and devices. Apply remains unavailable until this Mac passes GUI verification.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 540)
                            Button("Open Compatible Workbench") { model.activateCompatibleBroker() }
                        }
                    }
                } else {
                    MacWorkbenchView(model: model)
                        .task { model.start() }
                        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                            model.refresh(probe: true)
                        }
                        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                            model.refresh(probe: true)
                        }
                }
            }
            .accentColor(WorkbenchPalette.accent)
            .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Cloud") {
                SettingsLink { Text("Cloud Account and Project Sync…") }
            }
            CommandGroup(replacing: .newItem) {
                if brokerPreview || MacGUIRuntime.isTestApp {
                    Button("New Project…") { brokerModel.createProject() }.keyboardShortcut("n")
                    Button("Open Workspace…") { brokerModel.openWorkspace() }.keyboardShortcut("o")
                } else {
                    Button("New Screen") { model.newScreen() }.keyboardShortcut("n")
                        .disabled(model.brokerMode)
                    Button("Import Screen…") { model.importScreen() }.keyboardShortcut("o")
                        .disabled(model.brokerMode)
                }
            }
        }
        Settings { CloudControllerView() }
    }
}
