import AppKit
import SwiftUI

struct AgentConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentSetupProfile
    init(profile: AgentSetupProfile = .cursor) { _agent = State(initialValue: profile) }
    @State private var copied = false
    private var configuration: String {
        agent.configuration(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/screenpunk-mcp").path)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) { ConnectionLogo(name: agent.rawValue, size: 36); Text("Connect an Agent").font(.title2.weight(.semibold)) }
            Text("Connect your agent to Screenpunk on this Mac to create, preview, and apply screens.").foregroundStyle(.secondary)
            Picker("Agent Type", selection: $agent) {
                ForEach(AgentSetupProfile.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).controlSize(.large)
                .onChange(of: agent) { _, _ in copied = false }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(agent.instructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                        Text(instruction).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(agent.configurationLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("Setup Guide ↗", destination: agent.documentationURL).font(.caption)
            }
            ScrollView {
                Text(configuration).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.frame(height: 190).background(.quaternary, in: .rect(cornerRadius: 12)).id(agent)
            Text("Install Screenpunk in Applications and reopen this sheet before copying, so the command uses a permanent path. Your agent appears in Connections → Installed after it connects and requests Screenpunk’s tools.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).workbenchButton()
                Button(copied ? "Copied" : "Copy Configuration", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configuration, forType: .string)
                    copied = true
                }.workbenchButton(prominent: true)
            }
        }.padding(28).frame(width: 610)
    }
}
