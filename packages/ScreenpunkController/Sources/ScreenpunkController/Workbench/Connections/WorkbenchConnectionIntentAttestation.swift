import Foundation
import ScreenpunkCore
#if os(macOS)

/// Checks an ordinary returned intent against the complete typed declaration.
/// The redacted summary alone omits policy fields such as idempotence and
/// maximum age, so it cannot establish equivalence with the requested grant.
public enum WorkbenchConnectionIntentAttestation {
    /// The broker computes this from caller-controlled, nonsecret proposal
    /// fields before assigning its fresh credential reference. Only authRef
    /// is normalized; every operation policy field remains in the hash.
    public static func proposalScopeHash(deviceId: String, dashboardId: String,
                                         revision: String, grant: ConnectionGrant,
                                         auth: ConnectionAuthBinding) throws -> String {
        guard grant.authRef == auth.authRef else { throw WorkbenchIPCError(.invalidRequest) }
        var normalizedGrant = grant
        var normalizedAuth = auth
        normalizedGrant.authRef = ""
        normalizedAuth.authRef = ""
        let grantValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(normalizedGrant))
        let authValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(normalizedAuth))
        return try ToolchainCanonical.hash(domain: "ordinary-connection-proposal", value: [
            "deviceId": deviceId, "dashboardId": dashboardId, "revision": revision,
            "grant": grantValue, "auth": authValue
        ])
    }

    public static func declarationHash(dashboardId: String, revision: String,
                                       grant: ConnectionGrant,
                                       auth: ConnectionAuthBinding) throws -> String {
        try WorkbenchAuthorizationContext.declarationHash(grant: grant, auth: auth,
            dashboardId: dashboardId, revision: revision)
    }

    public static func matchesRequest(_ intent: WorkbenchConnectionIntentView,
                                      deviceId: String, dashboardId: String,
                                      revision: String, grant: ConnectionGrant,
                                      auth: ConnectionAuthBinding) -> Bool {
        guard let expectedHash = try? proposalScopeHash(deviceId: deviceId,
            dashboardId: dashboardId, revision: revision, grant: grant, auth: auth),
              intent.proposalScopeHash == expectedHash else { return false }
        let expected = WorkbenchConnectionSummary(bindingId: grant.id.uuidString.lowercased(),
            deviceId: deviceId, dashboardId: dashboardId, revision: revision,
            grant: grant, auth: auth, localStatus: "pending")
        return intent.summary == expected
    }
}
#endif
