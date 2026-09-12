import SwiftUI
import ScreenpunkCore

/// Shared iOS 16 + Mac root: offline fixture, native chrome, Unlink back to unpaired.
public struct AppleHostRootView: View {
    @State private var session: HostSession

    public init(session: HostSession) {
        _session = State(initialValue: session)
    }

    public static func offlineFixture() throws -> AppleHostRootView {
        AppleHostRootView(session: try HostSession.offlineFixture())
    }

    public var body: some View {
        Group {
            switch session.phase {
            case .dashboard:
                if let store = session.store {
                    DashboardRuntimeView(store: store, connectionCount: 0, requiredFailedOrStale: false) {
                        session.unlink()
                    }
                } else {
                    UnpairedHostView()
                }
            case .unpaired:
                UnpairedHostView()
            }
        }
        .accessibilityLabel(
            "Screenpunk \(AppleHostPlaceholder.customScheme)"
        )
    }
}
