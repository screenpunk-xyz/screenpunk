import SwiftUI
import ScreenpunkCore

struct GenericConnectionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MacWorkbenchModel
    let deviceID: String
    @StateObject private var editor = MacGenericConnectionsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(editor.deviceName) Connections").font(.title2.weight(.semibold))
            Text("Approve network access for the dashboard currently installed on this device.").foregroundStyle(.secondary)
            if let dashboard = editor.dashboardID, let revision = editor.revision {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dashboard: \(dashboard)")
                    Text("Revision: \(revision)").font(.caption).foregroundStyle(.secondary)
                }.textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if editor.reviewed {
                        Text("This replaces all generic connection permissions for this dashboard revision. Review every destination and operation before approving.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        if editor.approvals.isEmpty {
                            Text("No connections. Approving will remove this dashboard revision’s generic connection permissions.")
                        }
                        ForEach($editor.approvals) { $approval in
                            approvalCard($approval)
                        }
                    } else {
                        Text("Paste proposed ConnectionGrant JSON (one object or an array). Include all connections this dashboard needs. This proposal does not grant permission until you review and approve it.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text("Do not paste credentials here. Enter them in the secure fields after review. Use an empty array [] to remove all grants for this revision.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $editor.proposal).font(.system(.body, design: .monospaced))
                            .frame(minHeight: 210).border(.secondary.opacity(0.3))
                    }
                }
            }.disabled(editor.busy)
            if let message = editor.message {
                Text(message).font(.callout).foregroundStyle(editor.failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Connections run directly on the active device. Credentials are sent only over its paired, encrypted connection; they are not saved in a dashboard or on this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh Device") { editor.refreshTarget() }.disabled(editor.busy)
                if editor.reviewed { Button("Edit Proposal") { editor.editProposal() }.disabled(editor.busy) }
                if editor.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(editor.busy)
                if editor.reviewed {
                    Button("Approve and Replace") { editor.approve() }.disabled(!editor.canApprove)
                } else {
                    Button("Review Permissions") { editor.review() }.disabled(editor.busy || editor.proposal.isEmpty)
                }
            }
        }.padding(24).frame(width: 720, height: 730).interactiveDismissDisabled(editor.busy)
            .task { editor.load(model: model, deviceID: deviceID) }
    }

    private func approvalCard(_ binding: Binding<MacGenericConnectionsModel.Approval>) -> some View {
        let approval = binding.wrappedValue
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(approval.grant.alias).font(.headline)
                Text(approval.grant.origin).textSelection(.enabled)
                Text("Transport: \(approval.grant.transport == .ws ? "WebSocket subscription" : "HTTP request / polling")")
                Text("Local network: \(approval.grant.lan ? "Allowed" : "Not allowed") · Unencrypted HTTP / WebSocket: \(approval.grant.allowInsecureHTTP ? "Allowed" : "Not allowed")")
                    .font(.callout).foregroundStyle(approval.grant.allowInsecureHTTP ? Color.orange : Color.secondary)
                ForEach(approval.grant.operations, id: \.name) { operation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(operation.name) · \(operation.method.rawValue) \(operation.path)").font(.system(.callout, design: .monospaced))
                        Text("\(operation.write ? "Write operation" : "Read operation") · \(operation.idempotent ? "Idempotent" : "Not idempotent")").font(.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
                Divider()
                Picker("Authentication", selection: binding.placement) {
                    Text("None").tag(ConnectionAuthPlacement.none)
                    Text("Bearer token").tag(ConnectionAuthPlacement.bearer)
                    Text("Custom header").tag(ConnectionAuthPlacement.header)
                    Text("Query parameter").tag(ConnectionAuthPlacement.query)
                }
                if approval.placement == .header || approval.placement == .query {
                    TextField(approval.placement == .header ? "Header name" : "Query parameter name", text: binding.fieldName)
                        .textFieldStyle(.roundedBorder)
                }
                if approval.placement != .none {
                    SecureField("Credential for \(approval.grant.authRef)", text: binding.secret).textFieldStyle(.roundedBorder)
                }
                if approval.placement == .query {
                    Text("Query credentials are included in the request URL and may be recorded by the destination service.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}
