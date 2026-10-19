import Foundation
import ScreenpunkCore

@main
struct BrokerConnectionScopeProposalTest {
    static func main() throws {
        let draft = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "Kitchen",
            origin: "https://example.local", transport: .http, authRef: "",
            lan: true, allowInsecureHTTP: false,
            operations: [
                .init(name: "read", kind: .http, method: .GET, path: "/api/read",
                    idempotent: true, write: false),
                .init(name: "write", kind: .http, method: .POST, path: "/api/write",
                    idempotent: false, write: true)])
        let proposal = try BrokerConnectionScopeProposal.prepare(grant: draft,
            alias: "KitchenScoped", paths: ["/api/read?view=room", "/api/write"],
            enabled: [true, false])
        precondition(proposal.authRef.isEmpty)
        precondition(proposal.alias == "KitchenScoped")
        precondition(proposal.operations.count == 1 &&
                     proposal.operations[0].path == "/api/read?view=room")
        let encoded = try JSONEncoder().encode(proposal)
        precondition(String(decoding: encoded, as: UTF8.self).contains("\"authRef\":\"\""))
        for (alias, paths, enabled) in [
            ("bad alias", ["/api/read", "/api/write"], [true, false]),
            ("Kitchen", ["/api/read?token=secret", "/api/write"], [true, false]),
            ("Kitchen", ["/api/read", "/api/write"], [false, false])
        ] {
            do {
                _ = try BrokerConnectionScopeProposal.prepare(grant: draft,
                    alias: alias, paths: paths, enabled: enabled)
                preconditionFailure("Invalid scope accepted")
            } catch BrokerConnectionScopeProposal.Failure.invalidEdit {}
        }
        print("BrokerConnectionScopeProposalTest passed")
    }
}
