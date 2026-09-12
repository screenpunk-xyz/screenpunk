import SwiftUI
import ScreenpunkApple
import ScreenpunkController
import ScreenpunkCore

@main
struct ScreenpunkApp: App {
    @StateObject private var model = WorkbenchModel()
    private let store = ControllerStore(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Screenpunk")
    )

    var body: some Scene {
        WindowGroup {
            WorkbenchRootView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    if let loaded = try? store.load() {
                        model.session.drafts = loaded.drafts
                        model.session.devices = loaded.devices
                        model.session.selectedDeviceId = loaded.selectedDeviceId
                        model.session.selectedRevision = loaded.selectedRevision
                    }
                }
                .onReceive(model.$session) { session in
                    try? store.save(session)
                }
        }
    }
}
