#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import AuthenticationServices
#endif

/// Presentation only. The owner supplies enrollment state and commits authority changes.
public enum DeviceOnboardingLocalState: Equatable {
    case waiting
    case request(macName: String, code: String)
    case approving
    case failed(message: String)
    case completed(macName: String)
}

public struct DeviceOnboardingWelcomeView: View {
    private let appIcon: Image?
    private let cloud: () -> Void
    private let local: () -> Void
    public init(appIcon: Image? = nil, cloud: @escaping () -> Void, local: @escaping () -> Void) {
        self.appIcon = appIcon; self.cloud = cloud; self.local = local
    }
    public var body: some View {
        DeviceOnboardingLayout {
            if let appIcon {
                appIcon.resizable().scaledToFit().frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityHidden(true)
            }
            Text("Welcome to Screenpunk").font(.largeTitle.bold())
            Text("Choose where you’ll pair this device and create your screens.").font(.title3).foregroundStyle(.secondary)
            VStack(spacing: 16) {
                route("Screenpunk Cloud", detail: "Pair with Screenpunk Cloud to create and send screens using agents like ChatGPT. No Mac needed.", icon: "cloud", action: cloud)
                route("Local Screenpunk", detail: "Pair with the Screenpunk app on your Mac. Create and send screens locally. No cloud account needed.", icon: "desktopcomputer", action: local)
            }
            Text("You can change how this device connects later in Settings.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func route(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }.multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(20).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}

/// Google artwork must be an official, localized provider asset supplied by the integration.
public struct DeviceOnboardingCloudView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let googleArtwork: Image?
    private let apple: (() -> Void)?
    private let google: (() -> Void)?
    private let cancel: () -> Void
    private let busy: Bool
    private let message: String?
    public init(googleArtwork: Image? = nil, apple: (() -> Void)? = nil,
                google: (() -> Void)? = nil, busy: Bool = false,
                message: String? = nil, cancel: @escaping () -> Void) {
        self.googleArtwork = googleArtwork; self.apple = apple; self.google = google
        self.busy = busy; self.message = message; self.cancel = cancel
    }
    public var body: some View {
        DeviceOnboardingLayout {
            Image(systemName: "cloud").font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
            Text("Connect to Screenpunk Cloud").font(.largeTitle.bold())
            Text("Pair this device with your Screenpunk account to create and send screens using agents like ChatGPT.").font(.title3).foregroundStyle(.secondary)
            VStack(spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { providerButtons }
                    VStack(spacing: 12) { providerButtons }
                }
                if apple == nil && (google == nil || googleArtwork == nil) {
                    Text("Cloud sign-in is not configured on this device.").font(.callout).foregroundStyle(.secondary)
                }
                if busy { ProgressView("Connecting…") }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Button("Cancel", action: cancel).frame(minHeight: 44)
            }.padding(.top, 20)
        }
    }
    @ViewBuilder private var providerButtons: some View {
#if os(iOS)
        DeviceOnboardingAppleButton(dark: colorScheme == .dark, action: { apple?() })
            .frame(width: 205.09, height: 48).id(colorScheme)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(colorScheme == .dark ? Color.gray : .clear, lineWidth: 1))
            .disabled(apple == nil || busy).opacity(apple == nil || busy ? 0.5 : 1)
#endif
        if let googleArtwork {
            Button { google?() } label: {
                googleArtwork.resizable().scaledToFit().frame(width: 205.09, height: 48)
            }.buttonStyle(.plain).disabled(google == nil || busy).accessibilityLabel("Sign in with Google")
        }
    }

}

public struct DeviceOnboardingLocalView: View {
    private let state: DeviceOnboardingLocalState
    private let confirm: () -> Void
    private let decline: () -> Void
    private let retry: () -> Void
    private let cancel: () -> Void
    private let done: () -> Void
    public init(state: DeviceOnboardingLocalState, confirm: @escaping () -> Void,
                decline: @escaping () -> Void, retry: @escaping () -> Void,
                cancel: @escaping () -> Void, done: @escaping () -> Void) {
        self.state = state; self.confirm = confirm; self.decline = decline
        self.retry = retry; self.cancel = cancel; self.done = done
    }
    public var body: some View {
        DeviceOnboardingLayout {
            Image(systemName: "desktopcomputer").font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
            Text("Pair with your Mac").font(.largeTitle.bold())
            switch state {
            case .waiting:
                Text("Open Screenpunk on your Mac and add this device. You’ll compare the matching code and confirm here.").foregroundStyle(.secondary)
                ProgressView("Waiting for your Mac…")
                Button("Cancel", action: cancel)
            case .request(let name, let code):
                Text("Connect to \(name)?").font(.title2)
                Text("Confirm only if you recognize this Mac and the code matches the one shown there.").foregroundStyle(.secondary)
                Text(code).font(.largeTitle.monospaced().bold()).textSelection(.enabled).accessibilityLabel("Matching code \(code)")
                Button("Confirm", action: confirm).buttonStyle(.borderedProminent)
                Button("Decline", role: .cancel, action: decline)
            case .approving:
                ProgressView("Completing connection…")
                Button("Cancel", action: cancel)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
                Button("Try again", action: retry).buttonStyle(.borderedProminent)
                Button("Cancel", action: cancel)
            case .completed(let name):
                Label("Connected to \(name)", systemImage: "checkmark.circle").font(.title2)
                Button("Done", action: done).buttonStyle(.borderedProminent)
            }
        }
    }
}

public struct DeviceOnboardingConnectedView: View {
    private let connectionDescription: String
    private let hasScreens: Bool
    private let screens: () -> Void
    private let settings: () -> Void
    public init(connectionDescription: String, hasScreens: Bool = false, screens: @escaping () -> Void, settings: @escaping () -> Void) {
        self.connectionDescription = connectionDescription; self.hasScreens = hasScreens; self.screens = screens; self.settings = settings
    }
    public var body: some View {
        DeviceOnboardingLayout {
            Text("Connected").font(.largeTitle.bold())
            Text(connectionDescription).font(.title3).foregroundStyle(.secondary)
            if !hasScreens { Text("Keep Screenpunk open to receive your first screen.").foregroundStyle(.secondary) }
            Button("Your screens", action: screens).buttonStyle(.borderedProminent).controlSize(.large)
            Button("Settings", action: settings).frame(minHeight: 44)
        }
    }
}

private struct DeviceOnboardingLayout<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24, content: content)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28).padding(.vertical, 36)
                    .padding(.bottom, min(80, geometry.size.height * 0.08))
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
    }
}

#if os(iOS)
private struct DeviceOnboardingAppleButton: UIViewRepresentable {
    let dark: Bool
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: dark ? .black : .whiteOutline)
        button.cornerRadius = 4
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pressed() { action() }
    }
}
#endif
#endif
