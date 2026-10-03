import AuthenticationServices
import Combine
import GoogleSignIn
import SwiftUI
import UIKit

/// Resolves only the window containing this journey. It never searches global/key windows.
@MainActor
final class CloudProviderPresentation: ObservableObject {
    struct Context { let controller: UIViewController; let window: UIWindow }
    private weak var controller: UIViewController?
    private weak var scene: UIWindowScene?
    private var boundScene = false
    private let testResolve: (() throws -> Context)?
    init() { testResolve = nil }
    init(testResolve: @escaping () throws -> Context) { self.testResolve = testResolve }

    func bind(_ controller: UIViewController) {
        self.controller = controller
        if !boundScene, let scene = controller.viewIfLoaded?.window?.windowScene {
            self.scene = scene; boundScene = true
        }
    }
    func resolve() throws -> Context {
        if let testResolve { return try testResolve() }
        guard boundScene, let scene, scene.activationState == .foregroundActive,
              let window = controller?.viewIfLoaded?.window, window.windowScene === scene,
              !window.isHidden, let root = window.rootViewController else {
            throw CloudNativeIdentityError.providerFailed
        }
        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        guard !presenter.isBeingDismissed, !presenter.isBeingPresented,
              presenter.viewIfLoaded?.window === window else { throw CloudNativeIdentityError.providerFailed }
        return .init(controller: presenter, window: window)
    }
}

struct CloudPresentationAnchor: UIViewControllerRepresentable {
    let presentation: CloudProviderPresentation
    func makeUIViewController(context: Context) -> Capture {
        let controller = Capture(); controller.presentation = presentation
        return controller
    }
    func updateUIViewController(_ controller: Capture, context: Context) { presentation.bind(controller) }
    final class Capture: UIViewController {
        weak var presentation: CloudProviderPresentation?
        override func loadView() {
            let capture = WindowCaptureView()
            capture.didAttach = { [weak self] in
                guard let self else { return }
                self.presentation?.bind(self)
            }
            view = capture
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentation?.bind(self) }
    }
}

private final class WindowCaptureView: UIView {
    var didAttach: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { didAttach?() }
    }
}

/// Official native controls; rendering these does not start a provider flow.
struct CloudNativeProviderButtons: View {
    @Environment(\.colorScheme) private var colorScheme
    let enabled: Bool
    let apple: () -> Void
    let google: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            AppleControl(dark: colorScheme == .dark, enabled: enabled, action: apple)
                .frame(width: 230, height: 48).id(colorScheme)
            GoogleControl(dark: colorScheme == .dark, enabled: enabled, action: google)
                .frame(width: 230, height: 48)
        }.frame(maxWidth: .infinity).disabled(!enabled)
    }
    private struct AppleControl: UIViewRepresentable {
        let dark: Bool; let enabled: Bool; let action: () -> Void
        func makeCoordinator() -> ControlAction { ControlAction(action) }
        func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
            let control = ASAuthorizationAppleIDButton(type: .signIn, style: dark ? .white : .black)
            control.accessibilityLabel = "Sign in with Apple"; control.accessibilityIdentifier = "cloud.signIn.apple"
            control.addTarget(context.coordinator, action: #selector(ControlAction.invoke), for: .touchUpInside)
            return control
        }
        func updateUIView(_ control: ASAuthorizationAppleIDButton, context: Context) {
            control.isEnabled = enabled; control.alpha = enabled ? 1 : 0.5; context.coordinator.action = action; context.coordinator.enabled = enabled
        }
    }
    private struct GoogleControl: UIViewRepresentable {
        let dark: Bool; let enabled: Bool; let action: () -> Void
        func makeCoordinator() -> ControlAction { ControlAction(action) }
        func makeUIView(context: Context) -> GIDSignInButton {
            let control = GIDSignInButton(); control.style = .standard
            control.accessibilityHint = "Google account sign-in"; control.accessibilityIdentifier = "cloud.signIn.google"
            control.addTarget(context.coordinator, action: #selector(ControlAction.invoke), for: .touchUpInside)
            return control
        }
        func updateUIView(_ control: GIDSignInButton, context: Context) {
            control.colorScheme = dark ? .dark : .light
            control.isEnabled = enabled; control.alpha = enabled ? 1 : 0.5; context.coordinator.action = action; context.coordinator.enabled = enabled
            // The SDK draws its localized text from accessibilityLabel; leave it untouched.
            control.accessibilityHint = "Google account sign-in"
        }
    }
    @MainActor private final class ControlAction: NSObject {
        var action: () -> Void
        var enabled = false
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { if enabled { action() } }
    }
}
