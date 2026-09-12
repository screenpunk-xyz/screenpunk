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
        let danger = GuideColor.danger(colorScheme: colorScheme)
        let onDanger = GuideColor.onDanger(colorScheme: colorScheme)
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityLabel("Dismiss unlink")
            VStack(alignment: .leading, spacing: 16) {
                Text(UnlinkGestureSpec.explanation)
                    .font(.body)
                    .foregroundStyle(GuideColor.hex(colorScheme == .dark ? SemanticTokens.Dark.text : SemanticTokens.Light.text))
                    .fixedSize(horizontal: false, vertical: true)
                Button(UnlinkGestureSpec.actionTitle, action: onUnlink)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(onDanger)
                    .background(danger, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(UnlinkGestureSpec.actionTitle)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(
                GuideColor.hex(colorScheme == .dark ? SemanticTokens.Dark.surface : SemanticTokens.Light.surface),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .padding(24)
        }
        .accessibilityElement(children: .contain)
    }
}
