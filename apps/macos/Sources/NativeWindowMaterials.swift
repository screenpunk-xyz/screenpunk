import AppKit
import SwiftUI

enum WorkbenchWindowColors {
    static func canvas(active: Bool) -> NSColor {
        let base = NSColor.windowBackgroundColor
        return active ? base : (base.blended(withFraction: 0.035, of: .white) ?? base)
    }
}

/// Native behind-window vibrancy samples the desktop, respecting accessibility settings.
struct DesktopSidebarMaterial: NSViewRepresentable {
    var isActive: Bool
    final class SidebarView: NSVisualEffectView {
        private let tint = NSView()
        var isActive = true { didSet { updateTint() } }
        override init(frame: NSRect) {
            super.init(frame: frame)
            material = .underWindowBackground
            blendingMode = .behindWindow
            state = .followsWindowActiveState
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            addSubview(tint)
            updateTint()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() { super.layout(); tint.frame = bounds }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateTint()
        }
        func updateTint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                // Music uses a deeper sidebar surface than the default active List.
                // Retain native desktop sampling beneath a semantic background tint.
                let alpha = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1.0 : 0.78
                let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let color: NSColor
                if isDark {
                    color = NSColor.textBackgroundColor.blended(withFraction: isActive ? 0.4 : 0.06, of: isActive ? .black : .white) ?? .textBackgroundColor
                } else {
                    color = isActive ? .textBackgroundColor : (NSColor.textBackgroundColor.blended(withFraction: 0.1, of: .white) ?? .textBackgroundColor)
                }
                tint.layer?.backgroundColor = color.withAlphaComponent(alpha).cgColor
            }
        }
    }
    func makeNSView(context: Context) -> SidebarView { let view = SidebarView(frame: .zero); view.isActive = isActive; return view }
    func updateNSView(_ nsView: SidebarView, context: Context) { nsView.isActive = isActive }
}

/// Keep window chrome native while letting toolbar controls float above the canvas.
struct ContinuousWindowCanvas: NSViewRepresentable {
    @Binding var isActive: Bool
    final class WindowObserver: NSView {
        var isActive = true { didSet { updateCanvas() } }
        var onFocusChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        func updateCanvas() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                window?.backgroundColor = WorkbenchWindowColors.canvas(active: isActive)
            }
        }
        private func updateFocus() {
            // AppKit notifications can arrive while SwiftUI is updating this view.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let active = NSApp.isActive && (self.window?.isMainWindow == true || self.window?.isKeyWindow == true)
                self.isActive = active
                self.onFocusChange?(active)
            }
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateCanvas() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateFocus() })
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in self?.updateFocus() })
            }
            updateFocus()
        }
    }
    func makeNSView(context: Context) -> WindowObserver {
        let view = WindowObserver()
        view.isActive = isActive
        view.onFocusChange = { isActive = $0 }
        return view
    }
    func updateNSView(_ nsView: WindowObserver, context: Context) {
        nsView.onFocusChange = { isActive = $0 }
        nsView.isActive = isActive
    }
}
