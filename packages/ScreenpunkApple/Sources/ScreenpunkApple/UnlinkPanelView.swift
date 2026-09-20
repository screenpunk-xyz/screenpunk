import SwiftUI
import ScreenpunkCore
#if os(iOS)
import UIKit
#endif

/// Native device menu. Disconnect is never performed by opening the menu.
public struct UnlinkPanelView: View {
    @State private var confirmingDisconnect = false
    public var onUnlink: () -> Void
    public var onDismiss: () -> Void
    public var screens: [LANScreenSetEntry]
    public var selectedDashboardId: String?
    public var onSelect: (String) -> Void
    public var onSettings: (() -> Void)?

    public init(onUnlink: @escaping () -> Void, onDismiss: @escaping () -> Void,
                screens: [LANScreenSetEntry] = [], selectedDashboardId: String? = nil,
                onSettings: (() -> Void)? = nil,
                onSelect: @escaping (String) -> Void = { _ in }) {
        self.onUnlink = onUnlink; self.onDismiss = onDismiss
        self.onSettings = onSettings
        self.screens = screens; self.selectedDashboardId = selectedDashboardId; self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { geometry in
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: onDismiss)
                .accessibilityLabel("Close device menu")
            VStack(alignment: .leading, spacing: 18) {
                Text(confirmingDisconnect ? "Disconnect this device?" : "Device menu")
                    .font(.title3.bold())
                if confirmingDisconnect {
                    Text("This removes all deployed screens, pairing, and saved connection credentials from this device.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Cancel") { confirmingDisconnect = false }
                            .buttonStyle(UnlinkActionButtonStyle(fill: DeviceMenuColors.secondaryButton,
                                label: .primary))
                        Button("Disconnect", action: onUnlink)
                            .buttonStyle(UnlinkActionButtonStyle(fill: DeviceMenuColors.destructive,
                                label: .white))
                    }
                } else {
                    if let onSettings {
                        Button(action: onSettings) { Label("Settings", systemImage: "gearshape") }
                            .buttonStyle(UnlinkActionButtonStyle(fill: DeviceMenuColors.secondaryButton, label: .primary))
                    }
                    if screens.count > 1 {
                        Text("Choose a screen").font(.subheadline).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(Array(screens.enumerated()), id: \.element.dashboardId) { index, screen in
                                    Button { onSelect(screen.dashboardId) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "rectangle.stack").font(.title2)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(screen.name).font(.headline)
                                                Text("\(index + 1) of \(screens.count)").font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if selectedDashboardId == screen.dashboardId { Image(systemName: "checkmark.circle.fill").foregroundStyle(DeviceMenuColors.primaryButton) }
                                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                        .accessibilityValue(selectedDashboardId == screen.dashboardId ? "Current screen" : "")
                                }
                            }
                        }.frame(maxHeight: min(320, max(80, geometry.size.height - 250)))
                        Divider()
                    }
                    HStack(spacing: 12) {
                        Button("Disconnect…") { confirmingDisconnect = true }
                            .buttonStyle(UnlinkActionButtonStyle(fill: DeviceMenuColors.secondaryButton,
                                label: DeviceMenuColors.destructive))
                        Button("Close", action: onDismiss)
                            .buttonStyle(UnlinkActionButtonStyle(fill: DeviceMenuColors.primaryButton,
                                label: .white))
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(24).frame(maxWidth: 420)
            .background(DeviceMenuColors.surface, in: RoundedRectangle(cornerRadius: 20))
            .padding(24)
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
        }
    }
}

/// Full-width danger pill. Pressing darkens and shrinks the whole pill.
struct UnlinkActionButtonStyle: ButtonStyle {
    var fill: Color
    var label: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: UnlinkPanelLayout.actionCornerRadius, style: .continuous)
        return configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: UnlinkPanelLayout.actionMinimumHeight)
            .foregroundStyle(label)
            .background(fill, in: shape)
            .overlay {
                shape.fill(Color.black.opacity(UnlinkPanelLayout.pressedDim(configuration.isPressed)))
            }
            .scaleEffect(UnlinkPanelLayout.pressedScale(configuration.isPressed))
            .contentShape(shape)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Geometry and pressed-state values for the Unlink action, asserted by tests.
public enum UnlinkPanelLayout: Sendable {
    /// Minimum tappable height of the action; the fill and the hit target share it.
    public static let actionMinimumHeight: CGFloat = 44
    public static let actionCornerRadius: CGFloat = 10

    /// Opacity of the black overlay drawn on the pill while pressed.
    public static func pressedDim(_ pressed: Bool) -> Double {
        pressed ? 0.22 : 0
    }

    public static func pressedScale(_ pressed: Bool) -> CGFloat {
        pressed ? 0.97 : 1
    }
}

/// Platform semantic colors follow appearance and accessibility contrast settings.
private enum DeviceMenuColors {
#if os(iOS)
    static let primaryButton = Color(uiColor: .systemBlue)
    static let destructive = Color(uiColor: .systemRed)
    static let secondaryButton = Color(uiColor: .tertiarySystemFill)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
#else
    static let primaryButton = Color.blue
    static let destructive = Color.red
    static let secondaryButton = Color.primary.opacity(0.08)
    static let surface = Color(nsColor: .windowBackgroundColor)
#endif
}
