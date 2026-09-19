import SwiftUI
import AppKit

@main
struct ScreenpunkApp: App {
    @StateObject private var model = MacWorkbenchModel()
    var body: some Scene {
        WindowGroup {
            MacWorkbenchView(model: model)
                .accentColor(WorkbenchPalette.accent)
                .frame(minWidth: 900, minHeight: 620)
                .task { model.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refresh(probe: true)
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    model.refresh(probe: true)
                }
        }
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Screen") { model.newScreen() }.keyboardShortcut("n")
                Button("Import Screen…") { model.importScreen() }.keyboardShortcut("o")
            }
        }
    }
}
