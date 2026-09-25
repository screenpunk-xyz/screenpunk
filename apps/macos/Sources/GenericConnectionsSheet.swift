import SwiftUI
import ScreenpunkCore

struct GenericConnectionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MacWorkbenchModel
    let deviceID: String
    @StateObject private var editor = MacGenericConnectionsModel()
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(editor.deviceName) Connections").font(.title2.weight(.semibold))
                    Text("Connections used by screens on this iPad").foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close")
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CURRENT CONNECTIONS").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
                        ForEach(editor.connections) { connection in
                            Button { editor.selected = connection.id } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: connection.first.publicConnection == nil ? "link" : "cloud").frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(connection.first.name)
                                        Text(connection.first.kind).font(.caption).opacity(0.7)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .foregroundStyle(editor.selected == connection.id ? Color.white : Color.primary)
                                .background(rowColor(connection.id), in: RoundedRectangle(cornerRadius: 8))
                                .onHover { hovered = $0 ? connection.id : nil }
                        }
                    }.padding(12)
                }.frame(width: 240).background(.secondary.opacity(0.04))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let message = editor.message {
                            HStack { Text(message).foregroundStyle(.secondary); Button("Retry") { Task { await editor.refresh() } }.disabled(editor.busy) }
                        }
                        if let connection = editor.current { details(connection) }
                        else if editor.busy { ProgressView("Loading connections…") }
                        else if editor.message == nil { Text("No connections used by installed screens.").foregroundStyle(.secondary) }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                if editor.busy { ProgressView().controlSize(.small) }
                Spacer()
                if let connection = editor.current {
                    if connection.first.kind == "Service integration" {
                        Button("Configure connection") { editor.configure(connection) }.disabled(editor.busy)
                    }
                    Button("Test connection") { Task { await editor.test(connection) } }
                        .disabled(editor.statuses[connection.id] == "Testing")
                        .buttonStyle(.borderedProminent)
                }
            }.padding(16)
        }.frame(minWidth: 760, idealWidth: 980, maxWidth: 1100, minHeight: 480, idealHeight: 640, maxHeight: 760)
            .task { await editor.load(model: model, deviceID: deviceID) }
            .sheet(item: $editor.configuring, onDismiss: { editor.token = "" }) { _ in configuration }
    }
    private func rowColor(_ id: String) -> Color {
        if editor.selected == id { return Color.accentColor.opacity(hovered == id ? 0.85 : 1) }
        return hovered == id ? Color.primary.opacity(0.06) : .clear
    }
    private func details(_ connection: MacGenericConnectionsModel.Connection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(connection.first.name).font(.title2.bold())
                Spacer()
                Text(editor.statuses[connection.id] ?? "Not checked").font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .help(editor.diagnostics[connection.id] ?? "Test the source from this Mac.")
                    .accessibilityValue(editor.diagnostics[connection.id] ?? "Not checked from this Mac")
            }
            Text("Access details").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                detailRow("Destination", connection.first.origin)
                Divider()
                detailRow("Access", connection.entries.contains { $0.operations.contains { $0.write } } ? "Read and control" : "Read only")
                Divider()
                detailRow("Authentication", connection.first.authentication)
                Divider()
                detailRow("Used by", connection.screens)
            }.padding(.horizontal, 16).background(.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            Text("Operations").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(connection.entries.enumerated()), id: \.offset) { _, entry in
                    ForEach(Array(entry.operations.enumerated()), id: \.offset) { _, operation in
                        HStack(alignment: .top, spacing: 24) {
                            Text("\(operation.method) · \(operation.write ? "Makes changes" : "Read only")").foregroundStyle(.secondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(operation.name)
                                Text(entry.screen.name).font(.caption).foregroundStyle(.secondary)
                                Text(operation.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }.multilineTextAlignment(.trailing)
                        }.padding(.vertical, 12)
                        Divider()
                    }
                }
            }.padding(.horizontal, 16).background(.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(label).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.padding(.vertical, 12)
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Home Assistant").font(.title2.bold())
            TextField("Server address", text: $editor.address).textFieldStyle(.roundedBorder)
            SecureField("Access token — leave blank to keep saved token", text: $editor.token).textFieldStyle(.roundedBorder)
            Text("Save updates this iPad immediately. The iPad must be connected.").foregroundStyle(.secondary)
            if !editor.online { Text("iPad unavailable. Reconnect to save changes.").foregroundStyle(.orange) }
            if let error = editor.saveError { Text(error).foregroundStyle(.red) }
            HStack {
                if !editor.online { Button("Retry") { Task { await editor.refresh() } }.disabled(editor.busy) }
                Spacer()
                Button("Cancel") { editor.configuring = nil }.disabled(editor.busy)
                Button(editor.busy ? "Saving…" : "Save") { Task { await editor.save() } }
                    .disabled(!editor.online || editor.busy).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(editor.busy)
            .task {
                while !Task.isCancelled {
                    await editor.refresh()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }
}
