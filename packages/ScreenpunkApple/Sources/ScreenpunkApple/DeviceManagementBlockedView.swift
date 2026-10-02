import SwiftUI
import ScreenpunkCore

public struct DeviceManagementBlockedView: View {
    private let snapshot: DeviceRetainedContentSnapshot
    private let retry: () -> Void
    @State private var selectedID: String?
    public init(snapshot: DeviceRetainedContentSnapshot, retry: @escaping () -> Void) {
        self.snapshot = snapshot; self.retry = retry
        _selectedID = State(initialValue: snapshot.selectedID)
    }
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let screen = snapshot.screens.first(where: { $0.id == selectedID }) ?? snapshot.screens.first {
                DashboardRuntimeView(store: screen.package, revision: screen.revision, settings: snapshot.settings, screenName: screen.name)
                    .id(screen.id)
                    .deviceScreenSwipes(screens: snapshot.screens.map { .init(dashboardId: $0.id, revision: $0.revision, name: $0.name) },
                                        selectedID: selectedID, enabled: snapshot.screens.count > 1) { advance(by: $0) }
                    .accessibilityAction(named: "Next screen") { advance(by: 1) }
                    .accessibilityAction(named: "Previous screen") { advance(by: -1) }
            }
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    Text("Device connection needs attention").font(.headline)
                    Button("Retry", action: retry).buttonStyle(.borderedProminent)
                }
                .padding(20).frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding()
            }
        }
    }
    private func advance(by offset: Int) {
        guard let index = snapshot.screens.firstIndex(where: { $0.id == selectedID }), !snapshot.screens.isEmpty else { return }
        guard let next = ScreenCarousel.index(from: index, offset: offset, count: snapshot.screens.count) else { return }
        selectedID = snapshot.screens[next].id
    }
}
