import SwiftUI
import ScreenpunkCore

/// Host-owned unpaired surface. Pairing codes appear in `PairingCodeView`.
/// Also used, with `paired: true`, for a paired device that has no dashboard
/// yet, so it does not invite a second pairing.
public struct UnpairedHostView: View {
    @Environment(\.colorScheme) private var colorScheme
    public var detail: String?
    public var paired: Bool

    public init(detail: String? = nil, paired: Bool = false) {
        self.detail = detail
        self.paired = paired
    }

    public var body: some View {
        let canvas = GuideColor.hex(colorScheme == .dark ? SemanticTokens.Dark.canvas : SemanticTokens.Light.canvas)
        let text = GuideColor.hex(colorScheme == .dark ? SemanticTokens.Dark.text : SemanticTokens.Light.text)
        let secondary = GuideColor.hex(
            colorScheme == .dark ? SemanticTokens.Dark.textSecondary : SemanticTokens.Light.textSecondary
        )
        let headline = paired ? UnpairedHostCopy.pairedHeadline : UnpairedHostCopy.headline
        let instructions = paired ? UnpairedHostCopy.pairedInstructions : UnpairedHostCopy.instructions
        VStack(spacing: 16) {
            Text(headline)
                .font(.title2.weight(.semibold))
                .foregroundStyle(text)
                .multilineTextAlignment(.center)
            Text(instructions)
                .font(.body)
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(secondary)
                    .accessibilityLabel(detail)
            }
            Text(UnlinkGestureSpec.explanation)
                .font(.footnote)
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvas.ignoresSafeArea())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
        .accessibilityHint(instructions)
    }
}

enum UnpairedHostCopy {
    static let headline = "Ready to pair"
    static let instructions =
        "Open Screenpunk on your Mac to discover this device. Confirm the matching code on both screens. Local-network permission is required."
    static let pairedHeadline = "Paired with your Mac"
    static let pairedInstructions =
        "No dashboard yet. Press Deploy in Screenpunk on the Mac and it appears here."
}
