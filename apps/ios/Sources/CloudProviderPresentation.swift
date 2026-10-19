import AuthenticationServices
import Combine
import CoreText
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

/// Provider presentation only; rendering these does not start a provider flow.
struct CloudNativeProviderButtons: View {
    @Environment(\.colorScheme) private var colorScheme
    let enabled: Bool
    let apple: () -> Void
    let google: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            AppleControl(dark: colorScheme == .dark, enabled: enabled, action: apple)
                .frame(height: 52).id(colorScheme)
            googleButton
                .frame(height: 52)
        }.frame(maxWidth: .infinity).disabled(!enabled)
    }
    private struct AppleControl: UIViewRepresentable {
        let dark: Bool; let enabled: Bool; let action: () -> Void
        func makeCoordinator() -> ControlAction { ControlAction(action) }
        func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
            let control = ASAuthorizationAppleIDButton(type: .continue, style: dark ? .white : .black)
            control.cornerRadius = 12
            control.accessibilityLabel = "Continue with Apple"; control.accessibilityIdentifier = "cloud.signIn.apple"
            control.addTarget(context.coordinator, action: #selector(ControlAction.invoke), for: .touchUpInside)
            return control
        }
        func updateUIView(_ control: ASAuthorizationAppleIDButton, context: Context) {
            control.isEnabled = enabled; control.alpha = enabled ? 1 : 0.72; context.coordinator.action = action; context.coordinator.enabled = enabled
        }
    }
    // Custom presentation uses Google's official mark and documented light/dark colors.
    // The existing explicit Google action still owns all authentication and scope checks.
    private var googleButton: some View {
        Button { if enabled { google() } } label: {
            HStack(spacing: 12) {
                Image("GoogleSignInMark")
                    .resizable().scaledToFit().frame(width: 20, height: 20)
                Text("Continue with Google")
                    .font(Self.googleFont)
                    .foregroundColor(colorScheme == .dark
                        ? Color(red: 0.89, green: 0.89, blue: 0.89)
                        : Color(red: 0.12, green: 0.12, blue: 0.12))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(colorScheme == .dark
                ? Color(red: 0.89, green: 0.89, blue: 0.89)
                : Color(red: 0.12, green: 0.12, blue: 0.12))
            .background(colorScheme == .dark
                ? Color(red: 0.075, green: 0.075, blue: 0.078) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(colorScheme == .dark
                    ? Color(red: 0.56, green: 0.57, blue: 0.56)
                    : Color(red: 0.45, green: 0.47, blue: 0.46), lineWidth: 1))
            .opacity(enabled ? 1 : 0.85)
        }
        .buttonStyle(GoogleProviderButtonStyle())
        .disabled(!enabled)
        .accessibilityIdentifier("cloud.signIn.google")
        .accessibilityHint(enabled ? "Google account sign-in" : "Sign-in is unavailable until Cloud is configured")
    }
    private struct GoogleProviderButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
    private static let googleFont: Font = {
        if let url = Bundle.main.url(forResource: "GoogleSans", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return .custom("GoogleSans-Regular", size: 17, relativeTo: .body).weight(.medium)
    }()
    @MainActor private final class ControlAction: NSObject {
        var action: () -> Void
        var enabled = false
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { if enabled { action() } }
    }
}
