import Foundation
import SwiftUI
import ScreenpunkCore

/// Shared field controls: the installed dashboard supplies every selectable page
/// and event permission. Editing preferences never changes a dashboard package.
public struct DeviceSettingsEditor: View {
    @Binding public var settings: DeviceSettings
    public var manifest: DashboardManifest?

    public init(settings: Binding<DeviceSettings>, manifest: DashboardManifest?) {
        _settings = settings
        self.manifest = manifest
    }

    public var body: some View {
        Form {
            Section {
                if let manifest {
                    Picker("Starting page", selection: Binding(get: {
                        settings.startingPageByDashboard[manifest.dashboardId] ?? ""
                    }, set: {
                        settings.startingPageByDashboard[manifest.dashboardId] = $0.isEmpty ? nil : $0
                    })) {
                        Text("Dashboard default").tag("")
                        ForEach(manifest.resolvedPages) { page in Text(page.name).tag(page.id) }
                    }
                    if let saved = settings.startingPageByDashboard[manifest.dashboardId], !manifest.resolvedPages.contains(where: { $0.id == saved }) {
                        Text("The saved starting page is no longer available.").font(.caption).foregroundStyle(.secondary)
                        Button("Use dashboard starting page") { settings.startingPageByDashboard[manifest.dashboardId] = nil }
                    }
                    Text("The page within \(manifest.name) shown when Screenpunk opens. This does not select a different saved screen.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Page and event options appear when the current installed dashboard is available.")
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Starting page") }
            Section {
                Picker("Brightness", selection: $settings.brightness.mode) {
                    Text("Use system brightness").tag(DeviceBrightnessMode.system)
                    Text("Fixed level").tag(DeviceBrightnessMode.fixed)
                    Text("Time of day").tag(DeviceBrightnessMode.schedule)
                }
                if settings.brightness.mode == .fixed {
                    brightnessSlider("Level", value: $settings.brightness.fixedLevel)
                }
                if settings.brightness.mode == .schedule {
                    ForEach(settings.brightness.schedule.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                DatePicker("From", selection: scheduleTime(index), displayedComponents: .hourAndMinute)
                                Button(role: .destructive) { settings.brightness.schedule.remove(at: index) } label: {
                                    Image(systemName: "minus.circle")
                                }.accessibilityLabel("Remove brightness time")
                            }
                            brightnessSlider("Level", value: scheduleLevel(index))
                        }
                    }
                    Button("Add time", systemImage: "plus") {
                        let used = Set(settings.brightness.schedule.map(\.minuteOfDay))
                        if let minute = stride(from: 0, to: 1440, by: 30).first(where: { !used.contains($0) }) {
                            settings.brightness.schedule.append(.init(minuteOfDay: minute, level: 0.5))
                        }
                    }.disabled(settings.brightness.schedule.count >= 48)
                    Text("Times follow this device’s local time zone. The latest scheduled level continues overnight. Clock and daylight-saving changes are re-evaluated while Screenpunk is active.")
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.brightness.schedule.isEmpty {
                        Text("Add at least one time before saving.").font(.caption).foregroundStyle(.red)
                    }
                    if Set(settings.brightness.schedule.map(\.minuteOfDay)).count != settings.brightness.schedule.count {
                        Text("Each schedule time must be unique.").font(.caption).foregroundStyle(.red)
                    }
                }
                Text(settings.brightness.mode == .system
                     ? "Screenpunk leaves brightness to the device. System Auto-Brightness, if enabled in device Settings, may respond to ambient light."
                     : "Screenpunk requests this brightness while active and restores the prior level when inactive. It cannot turn off system Auto-Brightness or run brightness schedules while suspended.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Display") }
            if let manifest {
                Section {
                    let rules = manifest.eventRules ?? []
                    if rules.isEmpty {
                        Text("This dashboard has no external-event rules.").foregroundStyle(.secondary)
                    }
                    ForEach(rules) { rule in
                        eventRule(rule, manifest: manifest)
                    }
                    if settings.startingPageByDashboard[manifest.dashboardId] != nil || settings.eventRuleOverrides[manifest.dashboardId] != nil {
                        Button("Reset page and event preferences") {
                            settings.startingPageByDashboard[manifest.dashboardId] = nil
                            settings.eventRuleOverrides[manifest.dashboardId] = nil
                        }
                        Text("Use the current dashboard’s author defaults, including any updated or removed rules.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !rules.isEmpty {
                        Text("Manual navigation cancels an automatic return. A newer event of equal priority replaces the current event. Polling may miss brief events.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("External events") }
            }
        }
#if os(macOS)
        .formStyle(.grouped)
#endif
    }

    private func brightnessSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Slider(value: value, in: 0...1) { Text(label) }
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit().frame(minWidth: 42, alignment: .trailing)
        }
    }

    private func scheduleTime(_ index: Int) -> Binding<Date> {
        Binding(get: {
            let minute = settings.brightness.schedule.indices.contains(index) ? settings.brightness.schedule[index].minuteOfDay : 0
            return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: minute / 60, minute: minute % 60)) ?? Date()
        }, set: { date in
            guard settings.brightness.schedule.indices.contains(index) else { return }
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            settings.brightness.schedule[index].minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }

    private func scheduleLevel(_ index: Int) -> Binding<Double> {
        Binding(get: { settings.brightness.schedule.indices.contains(index) ? settings.brightness.schedule[index].level : 0.5 },
                set: { if settings.brightness.schedule.indices.contains(index) { settings.brightness.schedule[index].level = $0 } })
    }

    @ViewBuilder private func eventRule(_ rule: ManifestEventRule, manifest: DashboardManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(rule.name).font(.headline)
            Text(rule.source.mode == .live ? "Live subscription" : "Polling").font(.caption).foregroundStyle(.secondary)
            if rule.userConfigurable {
                Toggle("Enabled", isOn: ruleValue(rule, manifest: manifest, \.enabled))
                Picker("Show page", selection: ruleValue(rule, manifest: manifest, \.pageId)) {
                    ForEach(manifest.resolvedPages.filter { rule.allowedPageIds.contains($0.id) || $0.id == rule.defaults.pageId }) { page in
                        Text(page.name).tag(page.id)
                    }
                }
                Picker("After the event", selection: ruleValue(rule, manifest: manifest, \.returnBehavior)) {
                    ForEach(EventReturnBehavior.allCases.filter {
                        ($0 == rule.defaults.returnBehavior || rule.allowedReturnBehaviors.contains($0)) && ($0 != .conditionClear || rule.condition != nil)
                    }, id: \.self) { behavior in Text(Self.returnLabel(behavior)).tag(behavior) }
                }
                if ruleValue(rule, manifest: manifest, \.returnBehavior).wrappedValue == .timeout {
                    Stepper("Return after \(ruleValue(rule, manifest: manifest, \.timeoutSeconds).wrappedValue) seconds",
                            value: ruleValue(rule, manifest: manifest, \.timeoutSeconds), in: 1...3600)
                        .disabled(!rule.allowTimeoutOverride)
                }
                if rule.payload != nil {
                    Toggle("Allow permitted event overrides", isOn: ruleValue(rule, manifest: manifest, \.allowPayloadOverrides))
                        .disabled(!rule.defaults.allowPayloadOverrides)
                    Text("Events may change only the pages, return behavior and duration permitted by this dashboard.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.eventRuleOverrides[manifest.dashboardId]?[rule.id] != nil {
                    Button("Use dashboard defaults") {
                        settings.eventRuleOverrides[manifest.dashboardId]?[rule.id] = nil
                    }
                }
            } else {
                Text("\(Self.returnLabel(rule.defaults.returnBehavior)). Configured by the dashboard author.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }

    private func ruleValue<T>(_ rule: ManifestEventRule, manifest: DashboardManifest, _ keyPath: WritableKeyPath<EventRuleDefaults, T>) -> Binding<T> {
        Binding(get: { (settings.eventRuleOverrides[manifest.dashboardId]?[rule.id] ?? rule.defaults)[keyPath: keyPath] }, set: { value in
            var overrides = settings.eventRuleOverrides[manifest.dashboardId] ?? [:]
            var defaults = overrides[rule.id] ?? rule.defaults
            defaults[keyPath: keyPath] = value
            overrides[rule.id] = defaults
            settings.eventRuleOverrides[manifest.dashboardId] = overrides
        })
    }

    private static func returnLabel(_ behavior: EventReturnBehavior) -> String {
        switch behavior {
        case .stay: return "Stay until changed"
        case .timeout: return "Return after a timeout"
        case .conditionClear: return "Return when the condition clears"
        }
    }
}
