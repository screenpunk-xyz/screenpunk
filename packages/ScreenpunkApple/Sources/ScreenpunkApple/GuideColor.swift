import SwiftUI
import ScreenpunkCore

enum GuideColor {
    static func hex(_ value: String) -> Color {
        var hex = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if hex.count == 6 { hex = "FF" + hex }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a = Double((int >> 24) & 0xFF) / 255
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    static func danger(colorScheme: ColorScheme) -> Color {
        hex(colorScheme == .dark ? OfflineOverlayLayout.darkDangerHex : OfflineOverlayLayout.lightDangerHex)
    }

    static func onDanger(colorScheme: ColorScheme) -> Color {
        hex(colorScheme == .dark ? OfflineOverlayLayout.darkLabelHex : OfflineOverlayLayout.lightLabelHex)
    }

    static func canvas(colorScheme: ColorScheme) -> Color {
        hex(colorScheme == .dark ? SemanticTokens.Dark.canvas : SemanticTokens.Light.canvas)
    }

    static func surface(colorScheme: ColorScheme) -> Color {
        hex(colorScheme == .dark ? SemanticTokens.Dark.surface : SemanticTokens.Light.surface)
    }

    static func text(colorScheme: ColorScheme) -> Color {
        hex(colorScheme == .dark ? SemanticTokens.Dark.text : SemanticTokens.Light.text)
    }

    static func secondary(colorScheme: ColorScheme) -> Color {
        hex(colorScheme == .dark ? SemanticTokens.Dark.textSecondary : SemanticTokens.Light.textSecondary)
    }

    static func action(colorScheme: ColorScheme) -> Color {
        hex(colorScheme == .dark ? SemanticTokens.Dark.action : SemanticTokens.Light.action)
    }

    static func onAction(colorScheme: ColorScheme) -> Color {
        hex(colorScheme == .dark ? SemanticTokens.Dark.onAction : SemanticTokens.Light.onAction)
    }
}
