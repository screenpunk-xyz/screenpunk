import SwiftUI

enum WorkbenchPalette {
    static let accent = Color(red: 0, green: 0.48, blue: 1)
}


/// Share native control styles across toolbar, sidebar, and sheets. Glass is opt-in
/// at runtime so the same Apple-silicon binary also runs on macOS 14 and 15.
struct WorkbenchButtonStyle: ViewModifier {
    var prominent = false
    var circular = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(circular ? .circle : .capsule)
                    .controlSize(.large).modifier(GlassControlOutline(circular: circular))
            } else {
                content.tint(nil).buttonStyle(.glass).buttonBorderShape(circular ? .circle : .capsule)
                    .controlSize(.large).modifier(GlassControlOutline(circular: circular))
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).controlSize(.large)
        }
    }
}

/// Keep a quiet contour when macOS de-emphasizes a background window's glass.
/// This does not force enabled/active appearance or interfere with hit testing.
struct GlassControlOutline: ViewModifier {
    var circular = false
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.overlay {
            if #available(macOS 26, *) {
                RoundedRectangle(cornerRadius: circular ? 18 : 100)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.12), lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

extension View {
    @ViewBuilder func workbenchSegmentSurface() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
        }
    }

    func workbenchButton(prominent: Bool = false, circular: Bool = false) -> some View {
        modifier(WorkbenchButtonStyle(prominent: prominent, circular: circular))
    }
    @ViewBuilder func workbenchNotice() -> some View {
        if #available(macOS 26, *) { glassEffect(.regular, in: .rect(cornerRadius: 16)) }
        else { background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
    }
    @ViewBuilder func workbenchMenuStyle() -> some View {
        if #available(macOS 26, *) { menuStyle(.borderlessButton) }
        else { menuStyle(.borderedButton) }
    }
    @ViewBuilder func workbenchMenuSurface() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: .circle).modifier(GlassControlOutline(circular: true))
        } else { self }
    }
    @ViewBuilder func workbenchWindowChrome() -> some View {
        if #available(macOS 26, *) {
            toolbar(removing: .title).toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else { self }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder func workbenchSeparateBackground() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}
