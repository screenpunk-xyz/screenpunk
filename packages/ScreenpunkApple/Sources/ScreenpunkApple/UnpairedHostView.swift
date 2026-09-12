import SwiftUI
import ScreenpunkCore

/// Host-owned unpaired surface after Unlink. Pairing codes arrive in Milestone 3.
public struct UnpairedHostView: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        let canvas = GuideColor.hex(colorScheme == .dark ? SemanticTokens.Dark.canvas : SemanticTokens.Light.canvas)
        let text = GuideColor.hex(colorScheme == .dark ? SemanticTokens.Dark.text : SemanticTokens.Light.text)
        let secondary = GuideColor.hex(
            colorScheme == .dark ? SemanticTokens.Dark.textSecondary : SemanticTokens.Light.textSecondary
        )
        VStack(spacing: 16) {
            Text(UnpairedHostCopy.headline)
                .font(.title2.weight(.semibold))
                .foregroundStyle(text)
                .multilineTextAlignment(.center)
            Text(UnpairedHostCopy.instructions)
                .font(.body)
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(UnlinkGestureSpec.explanation)
                .font(.footnote)
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvas.ignoresSafeArea())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(UnpairedHostCopy.headline)
        .accessibilityHint(UnpairedHostCopy.instructions)
    }
}

enum UnpairedHostCopy {
    static let headline = "Ready to pair"
    static let instructions =
        "Open Screenpunk on your Mac to discover this device. Confirm the matching code on both screens. Local-network permission is required."
}
