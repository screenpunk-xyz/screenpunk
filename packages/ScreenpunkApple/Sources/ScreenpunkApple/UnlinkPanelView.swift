import SwiftUI
import ScreenpunkCore

/// Native Unlink panel. One action button. Tap outside dismisses.
public struct UnlinkPanelView: View {
    @Environment(\.colorScheme) private var colorScheme
    public var onUnlink: () -> Void
    public var onDismiss: () -> Void

    public init(onUnlink: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onUnlink = onUnlink
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityLabel("Dismiss unlink")
            VStack(alignment: .leading, spacing: 16) {
                Text(UnlinkGestureSpec.explanation)
                    .font(.body)
                    .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                // The style owns frame, fill, and content shape so the whole
                // pill is the hit target, not just the word.
                Button(UnlinkGestureSpec.actionTitle, action: onUnlink)
                    .buttonStyle(UnlinkActionButtonStyle(
                        fill: GuideColor.danger(colorScheme: colorScheme),
                        label: GuideColor.onDanger(colorScheme: colorScheme)
                    ))
                    .accessibilityLabel(UnlinkGestureSpec.actionTitle)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(
                GuideColor.surface(colorScheme: colorScheme),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .padding(24)
        }
        .accessibilityElement(children: .contain)
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
