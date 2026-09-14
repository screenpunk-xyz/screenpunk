import SwiftUI

@main
struct ScreenpunkApp: App {
    @StateObject private var model = MacWorkbenchModel()
    var body: some Scene {
        WindowGroup {
            MacWorkbenchView(model: model)
                .accentColor(WorkbenchPalette.accent)
                .frame(minWidth: 900, minHeight: 620)
                .task { model.start() }
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
