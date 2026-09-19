import AVFoundation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
final class CameraOverlayModel: ObservableObject {
    @Published var state = "loading"
    @Published var expanded = false
    @Published var label = "Camera"
    var action: (String) -> Void = { _ in }
}

struct CameraGalleryNavigation {
    static func next(index: Int, count: Int, direction: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + direction) % count + count) % count
    }
}

private struct CameraOverlay: View {
    @ObservedObject var model: CameraOverlayModel
    private var title: String {
        switch model.state {
        case "playing": return "Live"
        case "failed": return "Offline"
        case "stopped": return "Paused"
        default: return "Connecting"
        }
    }
    private var statusColor: Color {
        switch model.state {
        case "playing": return Color(red: 52/255, green: 199/255, blue: 89/255)
        case "failed": return .red
        case "stopped": return .gray
        default: return .orange
        }
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.001).contentShape(Rectangle())
                .onTapGesture { if !model.expanded { model.action("expand") } }
                .gesture(DragGesture(minimumDistance: 35).onEnded { value in
                    guard model.expanded, abs(value.translation.width) > 50,
                          abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    model.action(value.translation.width < 0 ? "next" : "previous")
                })
                .accessibilityLabel(model.label)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Expand camera") { model.action("expand") }
                .accessibilityAction(named: "Next camera") { model.action("next") }
                .accessibilityAction(named: "Previous camera") { model.action("previous") }
            #if compiler(>=6.2)
            if #available(iOS 26, macOS 26, *) {
                GlassEffectContainer { controls }
            } else { controls }
            #else
            controls
            #endif
        }.preferredColorScheme(.dark)
    }
    private var controls: some View {
        VStack {
            HStack {
                Spacer()
                if model.expanded { glassButton("arrow.down.right.and.arrow.up.left", label: "Collapse camera", action: "collapse") }
            }
            Spacer(minLength: 0)
            HStack(alignment: .center) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(statusColor.gradient, in: Capsule())
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                    .allowsHitTesting(false)
                Spacer()
                glassButton("arrow.clockwise", label: "Refresh \(model.label)", action: "refresh")
            }
        }.padding(16)
    }
    @ViewBuilder private func glassButton(_ symbol: String, label: String, action: String) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, macOS 26, *) {
            Button { model.action(action) } label: {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
            }.buttonStyle(.plain).foregroundStyle(.white)
                .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: Circle())
                .accessibilityLabel(label)
        } else {
            materialButton(symbol, label: label, action: action)
        }
        #else
        materialButton(symbol, label: label, action: action)
        #endif
    }
    private func materialButton(_ symbol: String, label: String, action: String) -> some View {
        Button { model.action(action) } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        }.buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel(label)
    }
}

#if os(iOS)
@MainActor
final class CameraVideoSurface: UIView {
    let model = CameraOverlayModel()
    private var overlay: UIHostingController<CameraOverlay>?
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init() { super.init(frame: .zero); clipsToBounds = true; isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func setControlsVisible(_ visible: Bool) {
        isUserInteractionEnabled = visible
        if visible && overlay == nil {
            let host = UIHostingController(rootView: CameraOverlay(model: model))
            host.view.backgroundColor = .clear
            addSubview(host.view); overlay = host
        }
        overlay?.view.isHidden = !visible
        overlay?.view.frame = bounds
    }
    override func layoutSubviews() { super.layoutSubviews(); overlay?.view.frame = bounds }
}
#else
@MainActor
final class CameraVideoSurface: NSView {
    let model = CameraOverlayModel()
    private var overlay: NSHostingView<CameraOverlay>?
    private var interactive = false
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init() { super.init(frame: .zero); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func setControlsVisible(_ visible: Bool) {
        interactive = visible
        if visible && overlay == nil {
            let host = NSHostingView(rootView: CameraOverlay(model: model))
            addSubview(host); overlay = host
        }
        overlay?.isHidden = !visible
        overlay?.frame = bounds
    }
    override func layout() { super.layout(); overlay?.frame = bounds }
    // NSHostingView hit testing loses the preview scale for nested glass controls.
    // Route pointer events in the video surface coordinate space instead.
    private var pointerStart: NSPoint?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactive, !isHidden, frame.contains(point) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) { pointerStart = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start = pointerStart else { return }
        pointerStart = nil
        let dx = point.x - start.x, dy = point.y - start.y
        if model.expanded && abs(dx) > 50 && abs(dx) > abs(dy) * 1.5 {
            model.action(dx < 0 ? "next" : "previous")
        } else if abs(dx) < 20 && abs(dy) < 20 {
            if point.x >= bounds.maxX - 64 && point.y <= bounds.minY + 64 {
                model.action("refresh")
            } else if model.expanded && point.x >= bounds.maxX - 64 && point.y >= bounds.maxY - 64 {
                model.action("collapse")
            } else if !model.expanded { model.action("expand") }
        }
    }
}
#endif
