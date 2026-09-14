import SwiftUI
import ScreenpunkCore

public struct PairingCodeView: View {
    @Environment(\.colorScheme) private var colorScheme
    public var code: String
    /// The owner confirmed; the Mac completes the handshake automatically.
    public var waiting: Bool
    public var onConfirm: () -> Void
    public var onCancel: (() -> Void)?

    public init(code: String, waiting: Bool = false, onCancel: (() -> Void)? = nil, onConfirm: @escaping () -> Void) {
        self.onCancel = onCancel
        self.code = code
        self.waiting = waiting
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text(PairingCodeCopy.headline)
                .font(.headline)
                .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
            Text(code)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
                .accessibilityLabel("Pairing code \(code)")
            // Frame, padding, and background live on the label so the whole
            // pill is the hit target, not just the word.
            Button(action: onConfirm) {
                Text(waiting ? PairingCodeCopy.waiting : PairingCodeCopy.confirm)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(GuideColor.hex(colorScheme == .dark ? SemanticTokens.Dark.onAction : SemanticTokens.Light.onAction))
                    .background(GuideColor.action(colorScheme: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(waiting)
            .opacity(waiting ? 0.6 : 1)
            .accessibilityLabel(waiting ? PairingCodeCopy.waiting : PairingCodeCopy.confirm)
            if let onCancel, !waiting {
                Button("Cancel", action: onCancel).buttonStyle(.plain)
            }
            if waiting {
                Text(PairingCodeCopy.waitingDetail)
                    .font(.footnote)
                    .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .background(GuideColor.surface(colorScheme: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

enum PairingCodeCopy {
    static let headline = "Match this code on both screens"
    static let confirm = "Confirm"
    static let waiting = "Connecting…"
    static let waitingDetail = "Your Mac will finish pairing automatically."
}
