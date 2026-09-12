import SwiftUI
import ScreenpunkCore

/// Host-owned Offline ring. Does not intercept dashboard taps.
public struct OfflineRingOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        let danger = GuideColor.danger(colorScheme: colorScheme)
        let onDanger = GuideColor.onDanger(colorScheme: colorScheme)
        let ring = CGFloat(OfflineOverlayLayout.ringPoints)
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Rectangle()
                    .strokeBorder(danger, lineWidth: ring)
                Text(OfflineOverlayLayout.label)
                    .font(.system(size: CGFloat(OfflineOverlayLayout.labelPoints), weight: .semibold))
                    .foregroundStyle(onDanger)
                    .padding(.horizontal, CGFloat(OfflineOverlayLayout.tabPaddingPoints))
                    .padding(.vertical, 6)
                    .background(danger, in: UnevenRoundedRectangle(
                        topLeadingRadius: 10,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 10
                    ))
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 8))
                    .accessibilityLabel(OfflineOverlayLayout.label)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
