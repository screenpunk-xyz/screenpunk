import SwiftUI
import ScreenpunkController

struct ConnectionsView: View {
    let agents: [AgentPresence]
    @ObservedObject var store: ConnectionsStore
    let openAgent: (AgentSetupProfile) -> Void
    let openHomeAssistant: () -> Void
    @Binding var search: String
    private var installed: [String] { store.installedAgents.filter(matches) }
    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    private var liveNames: Set<String> { Set(agents.map { AgentSetupProfile.connectionName($0.name) }) }
    private let columns = [GridItem(.adaptive(minimum: 270), spacing: 24, alignment: .leading)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                section("Installed") {
                    if installed.isEmpty && !(store.homeAssistant != nil && matches("Home Assistant")) {
                        Text(search.isEmpty ? "Your connected agents and services appear here." : "No matching connections.")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(installed, id: \.self) { name in
                                connectionRow(name, subtitle: liveNames.contains(name) ? "Connected" : "Not connected",
                                              symbol: AgentSetupProfile.profile(forConnectionName: name)?.symbol ?? "sparkles",
                                              color: .primary, status: liveNames.contains(name)) {
                                    openAgent(AgentSetupProfile.profile(forConnectionName: name) ?? .generic)
                                }
                            }
                            if store.homeAssistant != nil && matches("Home Assistant") {
                                connectionRow("Home Assistant", subtitle: store.homeAssistantStatus, symbol: "house.fill", color: .cyan) { openHomeAssistant() }
                            }
                        }
                    }
                }
                section("Agents") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach([AgentSetupProfile.claude, .codex, .cursor, .generic].filter { matches($0.rawValue) }) { profile in
                            connectionRow(profile.rawValue, subtitle: profile == .generic ? "Connect a local MCP client" : "Create and update screens", symbol: profile.symbol, color: .primary) { openAgent(profile) }
                        }
                    }
                }
                section("Services") {
                    if matches("Home Assistant") {
                        LazyVGrid(columns: columns, alignment: .leading) {
                            connectionRow("Home Assistant", subtitle: "Connect your home", symbol: "house.fill", color: .cyan) { openHomeAssistant() }
                        }
                    }
                }
            }.padding(32).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onChange(of: agents.map { AgentSetupProfile.connectionName($0.name) }.sorted(), initial: true) { _, names in
            store.rememberAgents(names)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            Divider()
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func connectionRow(_ name: String, subtitle: String, symbol: String, color: Color, status: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ConnectionLogo(name: name)
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.system(size: 16, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 6) {
                        if let status { Circle().fill(status ? Color(nsColor: .systemGreen) : .secondary).frame(width: 6, height: 6) }
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(name + ", " + subtitle + ", connection settings")
    }
}
