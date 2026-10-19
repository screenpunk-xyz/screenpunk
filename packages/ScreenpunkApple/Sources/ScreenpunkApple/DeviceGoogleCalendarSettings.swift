#if os(iOS)
import SwiftUI
import AuthenticationServices
import ScreenpunkCore

@MainActor
final class GoogleCalendarSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func authorize(_ oauth: GoogleCalendarOAuth) async throws -> URL {
        guard session == nil else { throw GoogleCalendarError.authorization }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: oauth.authorizationURL, callbackURLScheme: oauth.callbackScheme) { [weak self] url, error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.finish(url.map { .success($0) } ?? .failure(error ?? GoogleCalendarError.authorization))
                    }
                }
                self.session = session
                session.presentationContextProvider = self
                // Keep the system account chooser usable for adding multiple accounts.
                session.prefersEphemeralWebBrowserSession = true
                if !session.start() { finish(.failure(GoogleCalendarError.authorization)) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation; continuation = nil; session = nil
        pending?.resume(with: result)
    }
    func cancel() { session?.cancel(); finish(.failure(CancellationError())) }
}

@MainActor
struct DeviceGoogleCalendarSettings: View {
    let manifests: [DashboardManifest]
    let onChange: () -> Void
    @State private var state = GoogleCalendarState()
    @State private var message: String?
    @State private var busy = false
    @State private var pending: Task<Void, Never>?
    @State private var signIn = GoogleCalendarSignIn()
    private let service = GoogleCalendarDeviceService.shared
    private var clientID: String { Bundle.main.object(forInfoDictionaryKey: "ScreenpunkGoogleCalendarClientID") as? String ?? "" }
    private var configured: Bool {
        guard let oauth = try? GoogleCalendarOAuth(clientID: clientID),
              let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else { return false }
        return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(oauth.callbackScheme) == true }
    }
    private var calendarScreens: [DashboardManifest] {
        manifests.filter { $0.connections.contains { ["googleCalendar", "google-calendar"].contains($0.alias) } }
    }
    var body: some View {
        Form {
            Section {
                Text("Connect Google accounts on this device, then choose which calendars each screen can display.")
                Text("Connections stay on this device. No Screenpunk account or cloud service is needed.").foregroundStyle(.secondary)
            }
            Section("Google accounts") {
                ForEach(state.accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.email).font(.headline)
                        HStack {
                            Button("Refresh calendars") { run { try await service.reloadCalendars(accountID: account.id) } }
                            Spacer()
                            Button("Remove", role: .destructive) { run { try service.disconnect(accountID: account.id) } }
                        }.buttonStyle(.borderless)
                    }
                }
                Button(state.accounts.isEmpty ? "Connect Google Calendar" : "Connect or reconnect a Google account") {
                    run {
                        let oauth = try GoogleCalendarOAuth(clientID: clientID)
                        let expected = service.generation
                        let callback = try await signIn.authorize(oauth)
                        try await service.connect(oauth: oauth, code: oauth.code(from: callback), expected: expected)
                    }
                }.disabled(!configured)
                if !configured { Text("Google Calendar sign-in is not configured in this build.").foregroundStyle(.secondary) }
            }
            ForEach(calendarScreens, id: \.dashboardId) { screen in
                Section(screen.name) {
                    if state.accounts.isEmpty { Text("Connect an account to choose calendars.").foregroundStyle(.secondary) }
                    ForEach(state.accounts) { account in
                        ForEach(account.calendars) { calendar in
                            let selection = GoogleCalendarSelection(accountID: account.id, calendarID: calendar.id)
                            Toggle(isOn: Binding(get: { (state.selections[screen.dashboardId] ?? []).contains(selection) }, set: { enabled in
                                do { try service.select(dashboard: screen.dashboardId, selection: selection, enabled: enabled); reload(); onChange() }
                                catch { message = error.localizedDescription }
                            })) {
                                VStack(alignment: .leading) { Text(calendar.summary); Text(account.email).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            Section {
                Text("Removing an account here clears its data and calendar selections from this device. To revoke Screenpunk’s Google access across devices, manage your Google account connections.").font(.footnote).foregroundStyle(.secondary)
                Link("Manage access in Google", destination: URL(string: "https://myaccount.google.com/connections")!)
            }
            if busy { Section { ProgressView("Connecting to Google…") } }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .disabled(busy)
        .task { reload() }
        .onDisappear { pending?.cancel(); signIn.cancel() }
    }
    private func reload() {
        do { state = try service.snapshot() }
        catch { message = "Calendar accounts could not be loaded from this device’s secure storage." }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = nil
        pending = Task { @MainActor in
            defer { busy = false; reload(); onChange(); pending = nil }
            do { try await action() }
            catch is CancellationError { }
            catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { }
            catch { message = (error as? GoogleCalendarError)?.localizedDescription ?? "Could not connect to Google Calendar. Try again." }
        }
    }
}
#endif
