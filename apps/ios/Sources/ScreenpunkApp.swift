import SwiftUI
import UIKit
import ScreenpunkApple

@main
struct ScreenpunkApp: App {
    @UIApplicationDelegateAdaptor(ScreenpunkOrientationAppDelegate.self) private var orientationDelegate
    var body: some Scene {
        WindowGroup {
            CloudSceneRoot()
        }
    }
}

/// Window-scoped, overlapping onboarding leases never change the app's runtime orientation list.
@MainActor
final class ScreenpunkOnboardingOrientationPolicy {
    static let shared = ScreenpunkOnboardingOrientationPolicy()
    private struct Entry { weak var window: UIWindow? }
    private var entries: [UUID: Entry] = [:]
    func acquire(window: UIWindow, idiom: UIUserInterfaceIdiom, requestRotation: Bool = true) -> UUID? {
        guard idiom == .phone else { return nil }
        let token = UUID(); entries[token] = Entry(window: window)
        if requestRotation {
            invalidate(window)
            window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
        return token
    }
    func release(_ token: UUID?, notify: Bool = true) {
        guard let token, let entry = entries.removeValue(forKey: token), let window = entry.window else { return }
        if notify { invalidate(window) }
    }
    func supportedOrientations(window: UIWindow?, idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
        if idiom == .phone, let window, entries.values.contains(where: { $0.window === window }) { return .portrait }
        return idiom == .phone ? .allButUpsideDown : .all
    }
    private func invalidate(_ window: UIWindow) {
        var controller = window.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}

@MainActor
final class ScreenpunkOrientationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ScreenpunkOnboardingOrientationPolicy.shared.supportedOrientations(window: window,
            idiom: window?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom)
    }
}

/// Capture the actual attached window, rather than another scene's global key window.
struct ScreenpunkOnboardingWindowProbe: UIViewRepresentable {
    let portraitActive: Bool
    let sizeChanged: (CGSize) -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.portraitActive = portraitActive; view.sizeChanged = sizeChanged
        view.updateAttachment()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.retire() }
    final class Probe: UIView {
        var portraitActive = false
        var sizeChanged: ((CGSize) -> Void)?
        private weak var attachedWindow: UIWindow?
        private var token: UUID?
        private var lastSize: CGSize?
        override func didMoveToWindow() { super.didMoveToWindow(); updateAttachment() }
        override func layoutSubviews() { super.layoutSubviews(); updateAttachment() }
        func updateAttachment() {
            guard let window else { retire(); return }
            if attachedWindow !== window { retire(); attachedWindow = window }
            if portraitActive, token == nil {
                token = ScreenpunkOnboardingOrientationPolicy.shared.acquire(window: window, idiom: window.traitCollection.userInterfaceIdiom)
            } else if !portraitActive, token != nil {
                ScreenpunkOnboardingOrientationPolicy.shared.release(token); token = nil
            }
            let size = CGSize(width: window.bounds.width,
                height: window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom)
            if size != lastSize {
                lastSize = size
                DispatchQueue.main.async { [weak self] in self?.sizeChanged?(size) }
            }
        }
        func retire() {
            ScreenpunkOnboardingOrientationPolicy.shared.release(token); token = nil; attachedWindow = nil; lastSize = nil
        }
    }
}
