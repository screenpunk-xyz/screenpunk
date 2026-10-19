import Foundation
import SwiftUI
import ScreenpunkCore

/// The management owner supplies live status and an action. The form never
/// infers enrollment or changes authority itself.
struct DeviceGeneralConnection {
    var title: String
    var detail: String
    var actionTitle: String?
    var isWorking: Bool
    var action: (() -> Void)?

    init(title: String, detail: String, actionTitle: String? = nil,
         isWorking: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.isWorking = isWorking
        self.action = action
    }
}

struct DeviceGeneralSettingsForm: View {
    @Binding var settings: DeviceSettings
    var manifest: DashboardManifest?
    var defaultName: String
    var connection: DeviceGeneralConnection
    var editingDisabled = false

    var body: some View {
        Form {
            Section("Device name") {
                TextField(defaultName, text: Binding(
                    get: { settings.displayName ?? "" },
                    set: { settings.displayName = $0 }
                ))
                .accessibilityLabel("Device name")
                .accessibilityIdentifier("device-general-name")
                if DeviceDisplayName.sanitize(DeviceGeneralName.savedValue(settings.displayName)) != DeviceGeneralName.savedValue(settings.displayName) {
                    Text("Use up to \(DeviceDisplayName.maxLength) characters without line breaks or control characters.")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("The name shown for this device in Screenpunk. Leave blank to use \(defaultName).")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(editingDisabled)
            Section("Screenpunk connection") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.title)
                    Text(connection.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                if let title = connection.actionTitle, let action = connection.action {
                    Button(action: action) {
                        HStack {
                            Text(title)
                            if connection.isWorking { Spacer(); ProgressView() }
                        }
                    }.disabled(connection.isWorking)
                }
            }
            DeviceSettingsEditor(settings: $settings, manifest: manifest)
                .sections.disabled(editingDisabled)
        }
#if os(macOS)
        .formStyle(.grouped)
#endif
    }
}

/// Whitespace-only input restores the profile name. Other invalid characters
/// and overlong input remain intact so settings validation rejects them.
enum DeviceGeneralName {
    static func savedValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
