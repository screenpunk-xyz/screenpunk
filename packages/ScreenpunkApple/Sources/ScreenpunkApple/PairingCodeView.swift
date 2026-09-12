import SwiftUI
import ScreenpunkCore

public struct PairingCodeView: View {
    @Environment(\.colorScheme) private var colorScheme
    public var code: String
    public var onConfirm: () -> Void

    public init(code: String, onConfirm: @escaping () -> Void) {
        self.code = code
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Match this code on both screens")
                .font(.headline)
                .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
            Text(code)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
                .accessibilityLabel("Pairing code \(code)")
            Button("Confirm", action: onConfirm)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(GuideColor.hex(colorScheme == .dark ? SemanticTokens.Dark.onAction : SemanticTokens.Light.onAction))
                .background(GuideColor.action(colorScheme: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(20)
        .background(GuideColor.surface(colorScheme: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
